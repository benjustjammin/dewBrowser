import Foundation
import SQLite3

/// Reads bookmarks and history from Dia (a Chromium-based browser). Each Dia profile lives in
/// "~/Library/Application Support/Dia/User Data/<Profile N>" with a `Bookmarks` JSON file and
/// `History` / `Favicons` SQLite databases. Cookies and passwords are encrypted with a key in Dia's
/// own Keychain item, which a sandboxed app can't read, so they aren't imported.
enum DiaImporter {
    struct Profile: Identifiable, Hashable, Sendable {
        let id: String        // folder name, e.g. "Profile 2"
        let name: String      // name shown in Dia
        let folder: URL
        let bookmarkCount: Int
    }

    /// Dia's data folder in the real home directory (the sandboxed home is the app's container).
    static var defaultDataFolder: URL {
        let home = getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        return URL(fileURLWithPath: home).appending(path: "Library/Application Support/Dia/User Data", directoryHint: .isDirectory)
    }

    /// Accepts either the "Dia" folder or its "User Data" subfolder.
    static func profiles(in folder: URL) -> [Profile] {
        let root = FileManager.default.fileExists(atPath: folder.appending(path: "Local State").path)
            ? folder : folder.appending(path: "User Data", directoryHint: .isDirectory)
        guard let data = try? Data(contentsOf: root.appending(path: "Local State")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cache = (json["profile"] as? [String: Any])?["info_cache"] as? [String: [String: Any]] else { return [] }
        return cache.compactMap { key, info in
            let folder = root.appending(path: key, directoryHint: .isDirectory)
            guard FileManager.default.fileExists(atPath: folder.path) else { return nil }
            return Profile(id: key, name: info["name"] as? String ?? key, folder: folder,
                           bookmarkCount: readBookmarks(in: folder).count)
        }
        .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    /// Bookmarks bar contents (folders flattened, in order) plus history, with Dia's own favicons.
    static func load(_ profile: Profile, historyLimit: Int = 5_000) -> ImportedProfileData {
        let icons = readFavicons(in: profile.folder)
        let bookmarks = readBookmarks(in: profile.folder).map { item in
            ImportedProfileData.Item(title: item.title, url: item.url,
                                     faviconURL: icons[item.url.absoluteString] ?? item.url.faviconGuess)
        }
        return ImportedProfileData(bookmarks: bookmarks, history: readHistory(in: profile.folder, limit: historyLimit))
    }

    // MARK: Bookmarks (JSON)

    private static func readBookmarks(in folder: URL) -> [(title: String, url: URL)] {
        guard let data = try? Data(contentsOf: folder.appending(path: "Bookmarks")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let roots = json["roots"] as? [String: Any],
              let bar = roots["bookmark_bar"] as? [String: Any] else { return [] }
        var results: [(String, URL)] = []
        func walk(_ node: [String: Any]) {
            if node["type"] as? String == "url",
               let string = node["url"] as? String, let url = URL(string: string), url.scheme?.hasPrefix("http") == true {
                let name = node["name"] as? String ?? ""
                results.append((name.isEmpty ? (URLInput.displayHost(url) ?? string) : name, url))
            }
            for child in node["children"] as? [[String: Any]] ?? [] { walk(child) }
        }
        walk(bar)
        return results
    }

    // MARK: History & favicons (SQLite)

    private static func readHistory(in folder: URL, limit: Int) -> [ImportedProfileData.Visit] {
        var visits: [ImportedProfileData.Visit] = []
        query(database: folder.appending(path: "History"), sql: """
            SELECT url, title, visit_count, last_visit_time FROM urls
            WHERE hidden = 0 AND url LIKE 'http%' ORDER BY last_visit_time DESC LIMIT \(limit)
            """) { row in
            guard let string = column(row, 0), let url = URL(string: string) else { return }
            // Chromium time: microseconds since 1601-01-01.
            let date = Date(timeIntervalSince1970: Double(sqlite3_column_int64(row, 3)) / 1_000_000 - 11_644_473_600)
            visits.append(.init(url: url, title: column(row, 1) ?? "", visitCount: Int(sqlite3_column_int(row, 2)), lastVisited: date))
        }
        return visits
    }

    private static func readFavicons(in folder: URL) -> [String: URL] {
        var icons: [String: URL] = [:]
        query(database: folder.appending(path: "Favicons"), sql: """
            SELECT m.page_url, f.url FROM icon_mapping m JOIN favicons f ON f.id = m.icon_id
            """) { row in
            // Dia stores some icons inline as data: URLs (e.g. Portainer's), which load fine too.
            guard let page = column(row, 0), let icon = column(row, 1).flatMap(URL.init(string:)),
                  icon.scheme?.hasPrefix("http") == true || icon.scheme == "data" else { return }
            icons[page] = icon
        }
        return icons
    }

    /// Dia keeps its databases open, so read a private copy (including the write-ahead log).
    private static func query(database: URL, sql: String, row handle: (OpaquePointer) -> Void) {
        let copy = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: copy) }
        do {
            try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
            let target = copy.appending(path: database.lastPathComponent)
            try FileManager.default.copyItem(at: database, to: target)
            for suffix in ["-wal", "-shm"] {
                let side = URL(fileURLWithPath: database.path + suffix)
                if FileManager.default.fileExists(atPath: side.path) {
                    try? FileManager.default.copyItem(at: side, to: URL(fileURLWithPath: target.path + suffix))
                }
            }
            var db: OpaquePointer?
            guard sqlite3_open_v2(target.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else { return }
            defer { sqlite3_close(db) }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return }
            defer { sqlite3_finalize(statement) }
            while sqlite3_step(statement) == SQLITE_ROW { handle(statement) }
        } catch {
            return
        }
    }

    private static func column(_ row: OpaquePointer, _ index: Int32) -> String? {
        sqlite3_column_text(row, index).map { String(cString: $0) }
    }
}
