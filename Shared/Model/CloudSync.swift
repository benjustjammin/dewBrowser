import CloudKit
import CryptoKit
import Observation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// A device's open tabs, grouped by space, as published to iCloud.
struct DeviceSession: Codable, Identifiable, Equatable {
    struct SpaceTabs: Codable, Equatable {
        var name: String
        var colorHex: String
        var tabs: [SyncedTab]
    }

    struct SyncedTab: Codable, Equatable, Hashable {
        var url: URL
        var title: String
        var faviconURL: URL?
    }

    var id: String            // device ID
    var name: String
    var platform: String      // "mac" or "ios"
    var updated: Date
    var spaces: [SpaceTabs]

    var symbol: String { platform == "mac" ? "laptopcomputer" : "iphone" }
    var tabCount: Int { spaces.reduce(0) { $0 + $1.tabs.count } }
}

/// A bookmark as stored in iCloud (one record each, keyed by space name + URL).
struct SyncedBookmark: Equatable {
    var spaceName: String
    var spaceColor: String
    var spaceSymbol: String
    var title: String
    var url: URL
    var faviconURL: URL?
    var order: Double
    var modified: Date

    var key: String {
        let digest = SHA256.hash(data: Data("\(spaceName.lowercased())|\(url.absoluteString)".utf8))
        return "bm-" + digest.prefix(20).map { String(format: "%02x", $0) }.joined()
    }
}

/// "Tabs from your other devices" over iCloud (CloudKit private database, the user's own account).
/// Each device writes one record with its open tabs (never private ones) and reads everyone else's.
/// Records live in a custom zone and are fetched as zone changes, so no CloudKit indexes are needed.
@MainActor @Observable
final class CloudSync {
    static let containerID = "iCloud.com.local.dew"
    private static let zoneID = CKRecordZone.ID(zoneName: "DewSync", ownerName: CKCurrentUserDefaultName)
    private static let recordType = "DeviceSession"
    private static let bookmarkType = "Bookmark"

    var isEnabled = UserDefaults.standard.object(forKey: "iCloudTabSync") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "iCloudTabSync")
            if isEnabled { Task { await refresh() } } else { remoteDevices = [] }
        }
    }
    private(set) var remoteDevices: [DeviceSession] = []
    private(set) var status: String?
    private(set) var lastSync: Date?

    @ObservationIgnored private lazy var container = CKContainer(identifier: Self.containerID)
    @ObservationIgnored private var database: CKDatabase { container.privateCloudDatabase }
    @ObservationIgnored private var zoneReady = false
    @ObservationIgnored private var pushTask: Task<Void, Never>?
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var lastPushed: DeviceSession?
    /// Supplies this device's current tabs.
    @ObservationIgnored var snapshot: (() -> [DeviceSession.SpaceTabs])?
    /// Merge iCloud's bookmarks into the store; returns what to upload/delete and the keys to remember.
    @ObservationIgnored var reconcileBookmarks: (([SyncedBookmark]) -> (save: [SyncedBookmark], delete: [String], keys: Set<String>)?)?
    @ObservationIgnored var commitBookmarkKeys: ((Set<String>) -> Void)?

    var syncBookmarks = UserDefaults.standard.object(forKey: "iCloudBookmarkSync") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(syncBookmarks, forKey: "iCloudBookmarkSync")
            if syncBookmarks { Task { await refresh() } }
        }
    }

    static let deviceID: String = {
        if let id = UserDefaults.standard.string(forKey: "deviceID") { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: "deviceID")
        return id
    }()

    private static var deviceName: String {
        #if os(macOS)
        Host.current().localizedName ?? "Mac"
        #else
        UIDevice.current.model   // iOS only reveals the generic model name without an extra entitlement
        #endif
    }

    private static var platform: String {
        #if os(macOS)
        "mac"
        #else
        "ios"
        #endif
    }

    func start() {
        guard timer == nil else { return }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                // Retry soon after an error (e.g. a brand-new container still propagating), else every 2 min.
                let failed = self?.status != nil
                try? await Task.sleep(for: .seconds(failed ? 10 : 120))
            }
        }
    }

    /// Call when tabs change; publishes a few seconds later (coalescing bursts of changes).
    func setNeedsPush() {
        guard isEnabled else { return }
        pushTask?.cancel()
        pushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            await self?.refresh()   // tabs, plus any bookmark changes
        }
    }

    /// Publishes this device's tabs, then fetches the other devices'.
    func refresh() async {
        guard isEnabled else { return }
        await push()
        await fetch()
    }

    private func ensureReady() async -> Bool {
        do {
            let account = try await container.accountStatus()
            guard account == .available else {
                status = account == .noAccount ? "Sign in to iCloud to see tabs from your other devices." : "iCloud isn't available right now."
                return false
            }
            if !zoneReady {
                _ = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: Self.zoneID)], deleting: [])
                zoneReady = true
            }
            return true
        } catch {
            status = "iCloud: \(error.localizedDescription)"
            return false
        }
    }

    private func push() async {
        guard isEnabled, let snapshot, await ensureReady() else { return }
        let session = DeviceSession(id: Self.deviceID, name: Self.deviceName, platform: Self.platform,
                                    updated: .now, spaces: snapshot())
        // Skip if nothing changed (apart from the timestamp) since the last push.
        if var last = lastPushed {
            last.updated = session.updated
            if last == session { return }
        }
        let record = CKRecord(recordType: Self.recordType,
                              recordID: CKRecord.ID(recordName: Self.deviceID, zoneID: Self.zoneID))
        record["name"] = session.name
        record["platform"] = session.platform
        record["updated"] = session.updated
        record["payload"] = try? JSONEncoder().encode(session.spaces)
        do {
            // This device owns its record, so simply overwrite whatever is on the server.
            _ = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys)
            lastPushed = session
            status = nil
        } catch {
            status = "iCloud: \(error.localizedDescription)"
        }
    }

    private func fetch() async {
        guard isEnabled, await ensureReady() else { return }
        do {
            var devices: [DeviceSession] = []
            var remoteBookmarks: [SyncedBookmark] = []
            var token: CKServerChangeToken?
            var moreComing = true
            while moreComing {
                let changes = try await database.recordZoneChanges(inZoneWith: Self.zoneID, since: token)
                for (_, result) in changes.modificationResultsByID {
                    guard case .success(let modification) = result else { continue }
                    let record = modification.record
                    if record.recordType == Self.bookmarkType {
                        if let bookmark = Self.bookmark(from: record) { remoteBookmarks.append(bookmark) }
                        continue
                    }
                    guard record.recordID.recordName != Self.deviceID,
                          let payload = record["payload"] as? Data,
                          let spaces = try? JSONDecoder().decode([DeviceSession.SpaceTabs].self, from: payload) else { continue }
                    let updated = record["updated"] as? Date ?? record.modificationDate ?? .distantPast
                    // Ignore devices not seen for 30 days.
                    guard Date().timeIntervalSince(updated) < 30 * 86_400 else { continue }
                    devices.append(DeviceSession(id: record.recordID.recordName,
                                                 name: record["name"] as? String ?? "Device",
                                                 platform: record["platform"] as? String ?? "ios",
                                                 updated: updated, spaces: spaces))
                }
                token = changes.changeToken
                moreComing = changes.moreComing
            }
            remoteDevices = devices.filter { $0.tabCount > 0 }.sorted { $0.updated > $1.updated }
            if syncBookmarks { try await syncBookmarks(remoteBookmarks) }
            lastSync = .now
            status = nil
        } catch {
            status = "iCloud: \(error.localizedDescription)"
        }
    }

    // MARK: Bookmarks

    private func syncBookmarks(_ remote: [SyncedBookmark]) async throws {
        guard let result = reconcileBookmarks?(remote) else { return }
        if !result.save.isEmpty || !result.delete.isEmpty {
            let records = result.save.map(record(for:))
            let ids = result.delete.map { CKRecord.ID(recordName: $0, zoneID: Self.zoneID) }
            // Small batches stay well inside CloudKit's per-request limits.
            for start in stride(from: 0, to: max(records.count, ids.count), by: 200) {
                _ = try await database.modifyRecords(saving: Array(records.dropFirst(start).prefix(200)),
                                                     deleting: Array(ids.dropFirst(start).prefix(200)),
                                                     savePolicy: .allKeys)
            }
        }
        // Only after iCloud has the changes do we remember these keys as synced.
        commitBookmarkKeys?(result.keys)
    }

    private func record(for bookmark: SyncedBookmark) -> CKRecord {
        let record = CKRecord(recordType: Self.bookmarkType, recordID: CKRecord.ID(recordName: bookmark.key, zoneID: Self.zoneID))
        record["spaceName"] = bookmark.spaceName
        record["spaceColor"] = bookmark.spaceColor
        record["spaceSymbol"] = bookmark.spaceSymbol
        record["title"] = bookmark.title
        record["url"] = bookmark.url.absoluteString
        record["faviconURL"] = bookmark.faviconURL?.absoluteString
        record["order"] = bookmark.order
        record["modified"] = bookmark.modified
        return record
    }

    private static func bookmark(from record: CKRecord) -> SyncedBookmark? {
        guard let spaceName = record["spaceName"] as? String,
              let url = (record["url"] as? String).flatMap(URL.init(string:)) else { return nil }
        return SyncedBookmark(spaceName: spaceName,
                              spaceColor: record["spaceColor"] as? String ?? "#868E96",
                              spaceSymbol: record["spaceSymbol"] as? String ?? "star.fill",
                              title: record["title"] as? String ?? url.absoluteString,
                              url: url,
                              faviconURL: (record["faviconURL"] as? String).flatMap(URL.init(string:)),
                              order: record["order"] as? Double ?? 0,
                              modified: record["modified"] as? Date ?? record.modificationDate ?? .distantPast)
    }
}
