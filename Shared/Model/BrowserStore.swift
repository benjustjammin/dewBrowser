import SwiftUI
import WebKit
import Observation
#if os(macOS)
import AppKit
#else
import UIKit
import WidgetKit
#endif

/// Light, dark, or following the system (Settings → Appearance).
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

struct HistoryEntry: Codable, Identifiable {
    var id: String { "\(spaceID)|\(url.absoluteString)" }
    let spaceID: UUID
    let url: URL
    var title: String
    var lastVisited: Date
    var visitCount: Int
}

struct CommandBarState: Identifiable {
    let id = UUID()
    var text: String = ""
    var opensInNewTab: Bool
}

enum Suggestion: Identifiable {
    case go(URL, label: String, isSearch: Bool)
    case tab(BrowserTab)
    case history(HistoryEntry)
    case bookmark(Bookmark)

    var id: String {
        switch self {
        case .go(let url, _, _): "go|\(url.absoluteString)"
        case .tab(let tab): "tab|\(tab.id)"
        case .history(let entry): "history|\(entry.id)"
        case .bookmark(let bookmark): "bookmark|\(bookmark.id)"
        }
    }
}

/// All browser state: spaces, tabs, selection, history. Persisted as a single small JSON file.
@MainActor @Observable
final class BrowserStore {
    var spaces: [Space] = []
    private(set) var tabs: [BrowserTab] = []
    private(set) var selectedSpaceID = UUID()
    private var selectedTabIDs: [UUID: UUID] = [:]
    private(set) var history: [HistoryEntry] = []
    private(set) var bookmarks: [Bookmark] = []
    private(set) var splits: [TabSplit] = []

    var commandBar: CommandBarState?
    var spaceEditor: SpaceEditorState?
    var isEditingAddress = false
    var isManagingSpaces = false
    var isImporting = false
    /// Asks the app to open Settings at a tab (Mac); iOS shows its settings sheet.
    @ObservationIgnored var openSettingsTab: ((String) -> Void)?

    /// iOS: the browser layout on screen, so Settings can offer the right options (e.g. Duo side buttons).
    var activeLayout: BrowserLayout = .toolbar

    /// iOS: the page Settings should open at (consumed when it opens), e.g. "spaces".
    var settingsPage: String?

    /// Opens Settings at its top level, or at a page ("general", "appearance", "spaces", "passwords", "privacy", "ai").
    func openSettings(_ page: String? = nil) {
        if let openSettingsTab {
            openSettingsTab(page ?? "general")   // Mac: the Settings window
        } else {
            settingsPage = page
            isManagingSpaces = true
        }
    }

    func showPasswordSettings() { openSettings("passwords") }
    /// What's under the pointer in the tab strip / bookmarks bar, for middle-click handling.
    @ObservationIgnored var hoveredTabID: UUID?
    @ObservationIgnored var hoveredBookmarkID: UUID?
    @ObservationIgnored var isPointerInTabStrip = false
    /// Mac: the pointer is over the space pill (a sideways swipe there switches space).
    @ObservationIgnored var isPointerOnSpacePill = false
    static let historyLimit = 20_000
    let downloads = DownloadManager()
    let contentBlocker = ContentBlocker()
    let passwords = PasswordStore()
    let cloudSync = CloudSync()
    /// The Chat panel's conversation (one per window; never saved).
    let chat = ChatSession()
    var isChatOpen = false
    var pendingLogin: PendingLogin?

    /// iOS: where the address bar goes (automatic = toolbar on iPhone Duo and iPad, bottom bar on iPhone).
    var addressBarPosition = AddressBarPosition(rawValue: UserDefaults.standard.string(forKey: "addressBarPosition") ?? "") ?? .automatic {
        didSet { UserDefaults.standard.set(addressBarPosition.rawValue, forKey: "addressBarPosition") }
    }

    /// iPhone Duo: draw the page under the right-edge status strip (the clock and buttons float over it).
    var pageUnderStatusStrip = UserDefaults.standard.bool(forKey: "pageUnderStatusStrip") {
        didSet { UserDefaults.standard.set(pageUnderStatusStrip, forKey: "pageUnderStatusStrip") }
    }

    /// Ask the search engine for suggestions as you type (Google and DuckDuckGo).
    var searchSuggestionsEnabled = UserDefaults.standard.object(forKey: "searchSuggestions") as? Bool ?? true {
        didSet { UserDefaults.standard.set(searchSuggestionsEnabled, forKey: "searchSuggestions") }
    }

    /// Cookie banners: leave them, or click Reject / Accept automatically.
    var cookieBannerMode = CookieBannerMode(rawValue: UserDefaults.standard.string(forKey: "cookieBannerMode") ?? "") ?? .reject {
        didSet {
            UserDefaults.standard.set(cookieBannerMode.rawValue, forKey: "cookieBannerMode")
            reinstallUserScripts()
        }
    }

    let defaultBrowser = DefaultBrowser()

    var showBookmarksBar = UserDefaults.standard.object(forKey: "showBookmarksBar") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showBookmarksBar, forKey: "showBookmarksBar") }
    }

    /// Dia-style clean bar: favicons only, names in tooltips.
    var bookmarksIconsOnly = UserDefaults.standard.object(forKey: "bookmarksIconsOnly") as? Bool ?? true {
        didSet { UserDefaults.standard.set(bookmarksIconsOnly, forKey: "bookmarksIconsOnly") }
    }

    /// iOS Search widget: the space it opens in (a space's ID), or nil for whichever space you're in.
    var widgetSpaceID: UUID? = UserDefaults.standard.string(forKey: "widgetSpaceID").flatMap(UUID.init(uuidString:)) {
        didSet { UserDefaults.standard.set(widgetSpaceID?.uuidString, forKey: "widgetSpaceID") }
    }

    /// `dew://search` (the Search widget): a new tab with the search box ready, in the widget's space.
    func handleAppURL(_ url: URL) {
        guard url.host() == "search" else { return }
        if let id = widgetSpaceID, spaces.contains(where: { $0.id == id }) {
            selectSpace(id)
        } else if isPrivate {
            exitPrivate()   // "current space" never means private browsing from a widget
        }
        isChatOpen = false
        isManagingSpaces = false
        showCommandBar(newTab: true)
    }

    /// Light or dark, or follow the system. Applies to the whole app, including web pages that have a dark version.
    var appearanceMode = AppearanceMode(rawValue: BrowserStore.appearanceDefaults.string(forKey: "appearanceMode")
                                        ?? UserDefaults.standard.string(forKey: "appearanceMode") ?? "") ?? .system {
        didSet {
            Self.appearanceDefaults.set(appearanceMode.rawValue, forKey: "appearanceMode")
            applyAppearance()
            #if os(iOS)
            WidgetCenter.shared.reloadAllTimelines()   // the widget highlights the current choice
            #endif
        }
    }

    /// Where the appearance choice is kept. On iOS it's the App Group shared with the Search widget, whose
    /// Light / Dark / Auto buttons change it; on the Mac, the app's own settings.
    static let appearanceDefaults: UserDefaults = {
        #if os(iOS)
        UserDefaults(suiteName: "group.com.automate.dew") ?? .standard
        #else
        .standard
        #endif
    }()

    /// iOS: picks up a choice made on the widget while Dew was in the background.
    func reloadAppearance() {
        let saved = AppearanceMode(rawValue: Self.appearanceDefaults.string(forKey: "appearanceMode") ?? "") ?? .system
        if saved != appearanceMode { appearanceMode = saved } else { applyAppearance() }
    }

    /// When Dew is dark, show light pages (ones without their own dark mode) dark too. Updates open tabs in place.
    var darkenPages = UserDefaults.standard.bool(forKey: "darkenPages") {
        didSet {
            UserDefaults.standard.set(darkenPages, forKey: "darkenPages")
            reinstallUserScripts()   // pages loaded from now on
            let enabled = darkenPages
            for tab in tabs {
                guard let webView = tab.loadedWebView else { continue }
                Task {
                    _ = try? await webView.callAsyncJavaScript("window.__dewDarkSet && window.__dewDarkSet(v)",
                                                               arguments: ["v": enabled], contentWorld: .defaultClient)
                }
            }
        }
    }

    /// Applies `appearanceMode` app-wide: the Mac's app appearance (every window, menu and web view), or on iOS
    /// each window's interface style (so sheets follow too). Private browsing stays dark either way.
    func applyAppearance() {
        #if os(macOS)
        NSApp.appearance = switch appearanceMode {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
        #else
        let style: UIUserInterfaceStyle = switch appearanceMode {
        case .system: .unspecified
        case .light: .light
        case .dark: .dark
        }
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows { window.overrideUserInterfaceStyle = style }
        }
        #endif
    }

    /// Colour the selected tab and toolbar to match the website, like Dia.
    var matchSiteColor = UserDefaults.standard.object(forKey: "matchSiteColor") as? Bool ?? true {
        didSet { UserDefaults.standard.set(matchSiteColor, forKey: "matchSiteColor") }
    }

    /// Release the web views of tabs you haven't looked at for this long (they reload when you return).
    var tabSuspension = TabSuspension(rawValue: UserDefaults.standard.integer(forKey: "tabSuspensionMinutes")) ?? .never {
        didSet {
            UserDefaults.standard.set(tabSuspension.rawValue, forKey: "tabSuspensionMinutes")
            startSuspensionTimer()
        }
    }

    /// The selected tab's site colour, if matching is on and the page has reported one.
    var siteColor: RGBColor? { matchSiteColor ? selectedTab?.themeColor : nil }

    @ObservationIgnored private lazy var themeHandler = ThemeColorHandler(store: self)
    @ObservationIgnored private lazy var autofillHandler = PasswordAutofillHandler(store: self)

    private(set) var closedTabs: [TabRecord] = []
    @ObservationIgnored private var dataStores: [UUID: WKWebsiteDataStore] = [:]
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    /// Debug: `-DewDemo YES` starts with example spaces, tabs and bookmarks for screenshots. Nothing is loaded
    /// from or saved to disk, websites get private (non-persistent) storage, and iCloud sync stays off, so
    /// your real browsing is never shown or touched.
    static let isDemo = UserDefaults.standard.bool(forKey: "DewDemo")

    init() {
        if Self.isDemo { loadDemo() } else { load() }
        if spaces.isEmpty {
            spaces = Space.makeDefault()
            selectedSpaceID = spaces[0].id
        }
        if !spaces.contains(where: { $0.id == selectedSpaceID }) { selectedSpaceID = spaces[0].id }
        passwords.loadIfNeeded()
        chat.store = self
        isChatOpen = UserDefaults.standard.bool(forKey: "DewOpenChat")   // debug: `-DewOpenChat YES`
        if UserDefaults.standard.bool(forKey: "DewChatSample") { chat.loadSample() }
        cloudSync.snapshot = { [weak self] in self?.syncSnapshot() ?? [] }
        cloudSync.reconcileBookmarks = { [weak self] remote in self?.reconcileBookmarks(remote: remote) }
        cloudSync.commitBookmarkKeys = { [weak self] keys in self?.commitSyncedBookmarkKeys(keys) }
        if !Self.isDemo { cloudSync.start() }
        defaultBrowser.refresh()
        contentBlocker.onChange = { [weak self] reload in self?.applyContentBlocking(reload: reload) }
        startSuspensionTimer()
        Task {
            await runAutoClear(.launch)
            await contentBlocker.start()
        }
    }

    // MARK: Queries

    var currentSpace: Space {
        if isPrivate { return Self.privateSpace }
        return spaces.first { $0.id == selectedSpaceID } ?? spaces[0]
    }

    // MARK: Private browsing

    /// Private browsing is a built-in space that's never saved: its tabs use an in-memory WebKit store
    /// (wiped when the last private tab closes), and it records no history or recently closed tabs.
    static let privateSpaceID = UUID(uuidString: "00000000-0000-0000-0000-00000000DE00")!
    static let privateSpace = Space(id: privateSpaceID, name: "Private", colorHex: "#48484A", symbol: "eye.slash")

    var isPrivate: Bool { selectedSpaceID == Self.privateSpaceID }
    func isPrivate(_ spaceID: UUID) -> Bool { spaceID == Self.privateSpaceID }
    var hasPrivateTabs: Bool { tabs.contains { isPrivate($0.spaceID) } }

    @ObservationIgnored private var lastNormalSpaceID: UUID?

    /// Switches to private browsing, opening a blank private tab if there isn't one.
    func enterPrivate() {
        if !isPrivate { lastNormalSpaceID = selectedSpaceID }
        selectedSpaceID = Self.privateSpaceID
        commandBar = nil
        if !hasPrivateTabs { newTab(url: nil, in: Self.privateSpaceID) }
    }

    func exitPrivate() {
        selectSpace(lastNormalSpaceID.flatMap { id in spaces.first { $0.id == id }?.id } ?? spaces[0].id)
    }

    /// Closes every private tab, which also wipes private cookies and site data.
    func closeAllPrivateTabs() {
        for tab in tabs where isPrivate(tab.spaceID) { close(tab) }
        if isPrivate { exitPrivate() }
    }

    func orderedTabs(in spaceID: UUID) -> [BrowserTab] {
        let inSpace = tabs.filter { $0.spaceID == spaceID }
        return inSpace.filter(\.isPinned) + inSpace.filter { !$0.isPinned }
    }

    var orderedTabs: [BrowserTab] { orderedTabs(in: selectedSpaceID) }
    var pinnedTabs: [BrowserTab] { tabs.filter { $0.spaceID == selectedSpaceID && $0.isPinned } }
    var unpinnedTabs: [BrowserTab] { tabs.filter { $0.spaceID == selectedSpaceID && !$0.isPinned } }

    var selectedTab: BrowserTab? {
        guard let id = selectedTabIDs[selectedSpaceID] else { return nil }
        return tabs.first { $0.id == id }
    }

    func isSelected(_ tab: BrowserTab) -> Bool { selectedTabIDs[tab.spaceID] == tab.id && tab.spaceID == selectedSpaceID }

    func suggestions(for query: String) -> [Suggestion] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            return history.lazy.filter { $0.spaceID == self.selectedSpaceID }.prefix(6).map(Suggestion.history)
        }
        var results: [Suggestion] = []
        if let resolved = URLInput.resolve(query) {
            let label = resolved.isSearch ? query : resolved.url.absoluteString
            results.append(.go(resolved.url, label: label, isSearch: resolved.isSearch))
        }
        let matches = { (title: String, url: URL?) in
            title.localizedCaseInsensitiveContains(query) || (url?.absoluteString.localizedCaseInsensitiveContains(query) ?? false)
        }
        let openTabs = orderedTabs.filter { matches($0.title, $0.url) }.prefix(4)
        results += openTabs.map(Suggestion.tab)
        var openURLs = Set(openTabs.compactMap(\.url))
        let marks = currentBookmarks.filter { !openURLs.contains($0.url) && matches($0.title, $0.url) }.prefix(4)
        results += marks.map(Suggestion.bookmark)
        openURLs.formUnion(marks.map(\.url))
        let past = history
            .filter { $0.spaceID == selectedSpaceID && !openURLs.contains($0.url) && matches($0.title, $0.url) }
            .sorted { ($0.visitCount, $0.lastVisited) > ($1.visitCount, $1.lastVisited) }
            .prefix(6)
        results += past.map(Suggestion.history)
        return results
    }

    // MARK: Tabs

    @discardableResult
    func newTab(url: URL?, in spaceID: UUID? = nil, after anchor: BrowserTab? = nil, select: Bool = true) -> BrowserTab {
        let tab = BrowserTab(spaceID: spaceID ?? selectedSpaceID, url: url, store: self)
        insert(tab, after: anchor)
        if select { self.select(tab) }
        setNeedsSave()
        return tab
    }

    /// Opens Dew's new tab page in a fresh tab (or stays on the current one if it's already blank).
    func newBlankTab() {
        commandBar = nil
        if let tab = selectedTab, tab.url == nil, tab.loadedWebView == nil { return }
        newTab(url: nil)
    }

    func isBlank(_ tab: BrowserTab?) -> Bool {
        guard let tab else { return true }
        return tab.url == nil && tab.loadedWebView == nil
    }

    func openPopup(configuration: WKWebViewConfiguration, from opener: BrowserTab) -> BrowserTab {
        let tab = BrowserTab(spaceID: opener.spaceID, url: nil, store: self, popupConfiguration: configuration)
        tab.openerID = opener.id
        insert(tab, after: opener)
        select(tab)
        return tab
    }

    private func insert(_ tab: BrowserTab, after anchor: BrowserTab?) {
        if let anchor, let index = tabs.firstIndex(where: { $0 === anchor }) {
            tabs.insert(tab, at: index + 1)
        } else {
            tabs.append(tab)
        }
    }

    // MARK: Tab suspension

    @ObservationIgnored private var suspensionTask: Task<Void, Never>?

    private func startSuspensionTimer() {
        suspensionTask?.cancel()
        guard let limit = tabSuspension.interval else { return }
        suspensionTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                await self?.suspendIdleTabs(olderThan: limit)
            }
        }
    }

    /// Tabs being shown right now: the selected tab, plus the rest of its split.
    private var visibleTabIDs: Set<UUID> {
        guard let tab = selectedTab else { return [] }
        return Set(split(containing: tab.id)?.tabIDs ?? [tab.id])
    }

    func suspendIdleTabs(olderThan limit: TimeInterval) async {
        let now = Date()
        let visible = visibleTabIDs
        for tab in tabs where tab.loadedWebView != nil {
            if visible.contains(tab.id) { tab.lastActive = now; continue }
            guard now.timeIntervalSince(tab.lastActive) > limit else { continue }
            await tab.suspendIfIdle()
        }
    }

    func select(_ tab: BrowserTab) {
        // The tabs being left count as active until now, so the idle clock starts from here.
        let leaving = visibleTabIDs
        for other in tabs where leaving.contains(other.id) { other.lastActive = Date() }
        if selectedSpaceID != tab.spaceID { selectedSpaceID = tab.spaceID }
        selectedTabIDs[tab.spaceID] = tab.id
        isEditingAddress = false
        setNeedsSave()
    }

    func open(_ url: URL, inNewTab: Bool) {
        if !inNewTab, let tab = selectedTab { tab.load(url) } else { newTab(url: url) }
        commandBar = nil
        isEditingAddress = false
    }

    func close(_ tab: BrowserTab, remember: Bool = true) {
        guard let index = tabs.firstIndex(where: { $0 === tab }) else { return }
        let splitMates = split(containing: tab.id)?.tabIDs.filter { $0 != tab.id } ?? []
        removeFromSplit(tab)
        if selectedTabIDs[tab.spaceID] == tab.id, let mate = splitMates.first {
            selectedTabIDs[tab.spaceID] = mate
        } else if selectedTabIDs[tab.spaceID] == tab.id {
            let ordered = orderedTabs(in: tab.spaceID)
            let position = ordered.firstIndex { $0 === tab } ?? 0
            let opener = tab.openerID.flatMap { id in ordered.first { $0.id == id } }
            let neighbour = ordered.indices.contains(position + 1) ? ordered[position + 1]
                : ordered.indices.contains(position - 1) ? ordered[position - 1] : nil
            selectedTabIDs[tab.spaceID] = (opener ?? neighbour)?.id
        }
        if remember && tab.url != nil && !isPrivate(tab.spaceID) {
            closedTabs.append(tab.record)
            if closedTabs.count > 50 { closedTabs.removeFirst() }
        }
        tabs.remove(at: index)
        tab.tearDown()
        // Last private tab closed: drop the in-memory store, so the next private tab starts clean.
        // Closing the last one also leaves private browsing, like closing a private window.
        if isPrivate(tab.spaceID) && !hasPrivateTabs {
            dataStores[Self.privateSpaceID] = nil
            if isPrivate { exitPrivate() }
        }
        setNeedsSave()
    }

    func closeSelectedTab() {
        if commandBar != nil { commandBar = nil } else if let tab = selectedTab { close(tab) }
    }

    func reopenClosedTab() {
        while let record = closedTabs.popLast() {
            guard spaces.contains(where: { $0.id == record.spaceID }) else { continue }
            let tab = BrowserTab(id: record.id, spaceID: record.spaceID, url: record.url, title: record.title,
                                 faviconURL: record.faviconURL, isPinned: record.isPinned, themeColor: record.themeColor, store: self)
            tabs.append(tab)
            select(tab)
            return
        }
    }

    /// Brings back particular closed tabs (Chat's Undo), in place of reopening the most recent one.
    func reopen(_ records: [TabRecord]) {
        for record in records {
            guard spaces.contains(where: { $0.id == record.spaceID }), !tabs.contains(where: { $0.id == record.id }) else { continue }
            closedTabs.removeAll { $0.id == record.id }
            tabs.append(BrowserTab(id: record.id, spaceID: record.spaceID, url: record.url, title: record.title,
                                   faviconURL: record.faviconURL, isPinned: record.isPinned, themeColor: record.themeColor, store: self))
        }
        setNeedsSave()
    }

    func togglePin(_ tab: BrowserTab) {
        removeFromSplit(tab)
        tab.isPinned.toggle()
        setNeedsSave()
    }

    func duplicate(_ tab: BrowserTab) {
        newTab(url: tab.url, in: tab.spaceID, after: tab)
    }

    /// Spaces don't share cookies, so "moving" a tab means reopening its URL in the other space.
    func open(_ tab: BrowserTab, inSpace spaceID: UUID) {
        newTab(url: tab.url, in: spaceID)
    }

    func selectTab(number: Int) {
        let ordered = orderedTabs
        guard !ordered.isEmpty else { return }
        select(number >= 9 ? ordered[ordered.count - 1] : ordered[min(number, ordered.count) - 1])
    }

    func selectAdjacentTab(_ offset: Int) {
        let ordered = orderedTabs
        guard !ordered.isEmpty else { return }
        let current = selectedTab.flatMap { tab in ordered.firstIndex { $0 === tab } } ?? 0
        select(ordered[(current + offset + ordered.count) % ordered.count])
    }

    func moveTab(_ tab: BrowserTab, before target: BrowserTab) {
        guard tab !== target, let from = tabs.firstIndex(where: { $0 === tab }) else { return }
        tabs.remove(at: from)
        let to = tabs.firstIndex { $0 === target } ?? tabs.count
        tabs.insert(tab, at: to)
        tab.isPinned = target.isPinned
        setNeedsSave()
    }

    // MARK: Split view

    func split(containing tabID: UUID) -> TabSplit? {
        splits.first { $0.tabIDs.contains(tabID) }
    }

    /// The split being shown (the one containing the selected tab), with its tabs in order.
    var selectedSplit: (split: TabSplit, tabs: [BrowserTab])? {
        guard let tab = selectedTab, let split = split(containing: tab.id) else { return nil }
        let members = split.tabIDs.compactMap { id in tabs.first { $0.id == id } }
        return members.count >= 2 ? (split, members) : nil
    }

    func canSplit(_ tab: BrowserTab, beside anchor: BrowserTab?) -> Bool {
        guard let anchor, tab !== anchor, tab.spaceID == anchor.spaceID, !anchor.isPinned else { return false }
        if let existing = split(containing: anchor.id) {
            return !existing.tabIDs.contains(tab.id) && existing.tabIDs.count < TabSplit.maxPanes
        }
        return true
    }

    /// Shows `tab` beside `anchor` (joining the anchor's split, or making a new one) and focuses it.
    func addToSplit(_ tab: BrowserTab, beside anchor: BrowserTab) {
        guard canSplit(tab, beside: anchor) else { return }
        removeFromSplit(tab)
        tab.isPinned = false
        if let index = splits.firstIndex(where: { $0.tabIDs.contains(anchor.id) }) {
            let position = (splits[index].tabIDs.firstIndex(of: anchor.id) ?? splits[index].tabIDs.count - 1) + 1
            splits[index].tabIDs.insert(tab.id, at: position)
            splits[index].fractions = TabSplit.equal(splits[index].tabIDs.count)
        } else {
            splits.append(TabSplit(tabIDs: [anchor.id, tab.id], fractions: TabSplit.equal(2)))
        }
        // Keep the split's tabs next to each other in the strip.
        if let from = tabs.firstIndex(where: { $0 === tab }) {
            tabs.remove(at: from)
            let to = (tabs.firstIndex { $0 === anchor } ?? tabs.count - 1) + 1
            tabs.insert(tab, at: min(to, tabs.count))
        }
        select(tab)
        setNeedsSave()
    }

    func removeFromSplit(_ tab: BrowserTab) {
        guard let index = splits.firstIndex(where: { $0.tabIDs.contains(tab.id) }) else { return }
        splits[index].tabIDs.removeAll { $0 == tab.id }
        if splits[index].tabIDs.count < 2 {
            splits.remove(at: index)
        } else {
            splits[index].fractions = TabSplit.equal(splits[index].tabIDs.count)
        }
        setNeedsSave()
    }

    func separateSplit(containing tab: BrowserTab) {
        splits.removeAll { $0.tabIDs.contains(tab.id) }
        setNeedsSave()
    }

    /// Opens a blank tab beside the current one.
    func newSplitTab() {
        guard let anchor = selectedTab, !anchor.isPinned else { newBlankTab(); return }
        let tab = BrowserTab(spaceID: anchor.spaceID, url: nil, store: self)
        tabs.append(tab)
        addToSplit(tab, beside: anchor)
    }

    func setFractions(_ fractions: [Double], for splitID: UUID) {
        guard let index = splits.firstIndex(where: { $0.id == splitID }) else { return }
        splits[index].fractions = fractions
        setNeedsSave()
    }

    // MARK: iCloud tabs & Handoff

    /// This device's open tabs per space, for iCloud (private browsing is never included).
    func syncSnapshot() -> [DeviceSession.SpaceTabs] {
        spaces.compactMap { space in
            let tabs = orderedTabs(in: space.id).compactMap { tab -> DeviceSession.SyncedTab? in
                guard let url = tab.url, url.scheme?.hasPrefix("http") == true else { return nil }
                return DeviceSession.SyncedTab(url: url, title: tab.displayTitle, faviconURL: tab.faviconURL)
            }
            return tabs.isEmpty ? nil : DeviceSession.SpaceTabs(name: space.name, colorHex: space.colorHex, tabs: tabs)
        }
    }

    /// Where a tab from another device opens: the space with the same name here, else the current one.
    private func spaceID(matching name: String) -> UUID {
        if isPrivate { return selectedSpaceID }
        return spaces.first { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }?.id ?? selectedSpaceID
    }

    func openRemote(_ tab: DeviceSession.SyncedTab, fromSpace spaceName: String) {
        let target = spaceID(matching: spaceName)
        let new = newTab(url: tab.url, in: target)
        new.title = tab.title
        new.faviconURL = tab.faviconURL
    }

    /// Opens a whole space's tabs from another device.
    func openAll(_ space: DeviceSession.SpaceTabs) {
        let target = spaceID(matching: space.name)
        var last: BrowserTab?
        for tab in space.tabs {
            let new = newTab(url: tab.url, in: target, select: false)
            new.title = tab.title
            new.faviconURL = tab.faviconURL
            last = new
        }
        if let last { select(last) }
    }

    /// The page to offer via Handoff (never in private browsing).
    var handoffURL: URL? {
        guard !isPrivate, let url = selectedTab?.url, url.scheme?.hasPrefix("http") == true else { return nil }
        return url
    }

    static let handoffActivityType = "com.local.dew.page"

    // MARK: iCloud bookmark sync

    /// Bookmarks as iCloud sees them, keyed by space name + URL (space IDs differ between devices).
    private func syncedBookmarks() -> [SyncedBookmark] {
        var result: [SyncedBookmark] = []
        for space in spaces {
            for (order, bookmark) in bookmarks.filter({ $0.spaceID == space.id }).enumerated() {
                result.append(SyncedBookmark(spaceName: space.name, spaceColor: space.colorHex, spaceSymbol: space.symbol,
                                             title: bookmark.title, url: bookmark.url, faviconURL: bookmark.faviconURL,
                                             order: Double(order), modified: bookmark.modified ?? .distantPast))
            }
        }
        return result
    }

    private var syncedBookmarkKeys: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "syncedBookmarkKeys") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "syncedBookmarkKeys") }
    }

    /// Merges iCloud's bookmarks with ours. A bookmark missing on one side counts as deleted only if
    /// this device had already confirmed syncing it (`syncedBookmarkKeys`); otherwise it's new and is
    /// copied across. Returns what to upload/delete and the keys to remember once that succeeds.
    func reconcileBookmarks(remote: [SyncedBookmark]) -> (save: [SyncedBookmark], delete: [String], keys: Set<String>) {
        let known = syncedBookmarkKeys
        let remoteByKey = Dictionary(remote.map { ($0.key, $0) }, uniquingKeysWith: { a, b in a.modified >= b.modified ? a : b })
        var localByKey = Dictionary(syncedBookmarks().map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        var save: [SyncedBookmark] = []
        var delete: [String] = []
        var changed = false

        for item in remoteByKey.values.sorted(by: { $0.order < $1.order }) {
            if let local = localByKey[item.key] {
                guard local.title != item.title || local.faviconURL != item.faviconURL else { continue }
                if item.modified > local.modified {
                    updateLocalBookmark(item)
                    localByKey[item.key] = item
                    changed = true
                } else {
                    save.append(local)
                }
            } else if known.contains(item.key) {
                delete.append(item.key)                  // deleted on this device
            } else {
                addLocalBookmark(item)                    // new from another device
                localByKey[item.key] = item
                changed = true
            }
        }
        for (key, local) in localByKey where remoteByKey[key] == nil {
            if known.contains(key) {
                removeLocalBookmark(local)                // deleted on another device
                localByKey[key] = nil
                changed = true
            } else {
                save.append(local)                        // new here
            }
        }
        if changed { setNeedsSave() }
        return (save, delete, Set(localByKey.keys))
    }

    func commitSyncedBookmarkKeys(_ keys: Set<String>) { syncedBookmarkKeys = keys }

    private func space(named name: String, color: String, symbol: String) -> Space {
        if let existing = spaces.first(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) { return existing }
        let space = Space(name: name, colorHex: color, symbol: symbol)
        spaces.append(space)
        return space
    }

    private func addLocalBookmark(_ item: SyncedBookmark) {
        let target = space(named: item.spaceName, color: item.spaceColor, symbol: item.spaceSymbol)
        bookmarks.append(Bookmark(spaceID: target.id, title: item.title, url: item.url,
                                  faviconURL: item.faviconURL, modified: item.modified))
    }

    private func updateLocalBookmark(_ item: SyncedBookmark) {
        guard let space = spaces.first(where: { $0.name.localizedCaseInsensitiveCompare(item.spaceName) == .orderedSame }),
              let index = bookmarks.firstIndex(where: { $0.spaceID == space.id && $0.url == item.url }) else { return }
        bookmarks[index].title = item.title
        bookmarks[index].faviconURL = item.faviconURL ?? bookmarks[index].faviconURL
        bookmarks[index].modified = item.modified
    }

    private func removeLocalBookmark(_ item: SyncedBookmark) {
        guard let space = spaces.first(where: { $0.name.localizedCaseInsensitiveCompare(item.spaceName) == .orderedSame }) else { return }
        bookmarks.removeAll { $0.spaceID == space.id && $0.url == item.url }
    }

    // MARK: Command bar

    func showCommandBar(newTab: Bool) {
        let text = newTab ? "" : selectedTab?.url?.absoluteString ?? ""
        commandBar = CommandBarState(text: text, opensInNewTab: newTab || selectedTab == nil)
    }

    func focusAddress() {
        if selectedTab == nil { showCommandBar(newTab: true) } else { isEditingAddress = true }
    }

    // MARK: Spaces

    func selectSpace(_ id: UUID) {
        guard spaces.contains(where: { $0.id == id }) || isPrivate(id) else { return }
        if isPrivate(id) && !isPrivate { lastNormalSpaceID = selectedSpaceID }
        selectedSpaceID = id
        commandBar = nil
        isEditingAddress = false
        setNeedsSave()
    }

    func selectAdjacentSpace(_ offset: Int) {
        guard let index = spaces.firstIndex(where: { $0.id == selectedSpaceID }) else {
            selectSpace(spaces[0].id)   // from private browsing, go back to the first space
            return
        }
        selectSpace(spaces[(index + offset + spaces.count) % spaces.count].id)
    }

    func rename(_ spaceID: UUID, to name: String) {
        guard let index = spaces.firstIndex(where: { $0.id == spaceID }) else { return }
        spaces[index].name = name
        setNeedsSave()
    }

    func moveSpaces(from source: IndexSet, to destination: Int) {
        spaces.move(fromOffsets: source, toOffset: destination)
        setNeedsSave()
    }

    func tab(for webView: WKWebView) -> BrowserTab? {
        tabs.first { $0.loadedWebView === webView }
    }

    func selectSpace(number: Int) {
        guard spaces.indices.contains(number - 1) else { return }
        selectSpace(spaces[number - 1].id)
    }

    func beginNewSpace() {
        let color = Space.palette.first { hex in !spaces.contains { $0.colorHex == hex } } ?? Space.palette[0]
        spaceEditor = SpaceEditorState(space: Space(name: "", colorHex: color, symbol: "star.fill"), isNew: true)
    }

    func beginEditing(_ space: Space) {
        spaceEditor = SpaceEditorState(space: space, isNew: false)
    }

    func save(_ space: Space) {
        if let index = spaces.firstIndex(where: { $0.id == space.id }) {
            spaces[index] = space
        } else {
            spaces.append(space)
            selectSpace(space.id)
        }
        setNeedsSave()
    }

    /// Deletes the space, its tabs and history, and wipes its cookies/logins from disk.
    func delete(_ space: Space) {
        guard spaces.count > 1 else { return }
        for tab in tabs where tab.spaceID == space.id { tab.tearDown() }
        let removedIDs = Set(tabs.filter { $0.spaceID == space.id }.map(\.id))
        splits.removeAll { !removedIDs.isDisjoint(with: $0.tabIDs) }
        tabs.removeAll { $0.spaceID == space.id }
        history.removeAll { $0.spaceID == space.id }
        bookmarks.removeAll { $0.spaceID == space.id }
        passwords.deleteAll(in: space.id)
        closedTabs.removeAll { $0.spaceID == space.id }
        selectedTabIDs[space.id] = nil
        spaces.removeAll { $0.id == space.id }
        if selectedSpaceID == space.id { selectedSpaceID = spaces[0].id }
        dataStores[space.id] = nil
        setNeedsSave()
        Task {
            // The store can only be removed once no web view uses it; give WebKit a moment to release it.
            try? await Task.sleep(for: .seconds(1))
            try? await WKWebsiteDataStore.remove(forIdentifier: space.id)
        }
    }

    func dataStore(for spaceID: UUID) -> WKWebsiteDataStore {
        if let store = dataStores[spaceID] { return store }
        let store = isPrivate(spaceID) || Self.isDemo ? WKWebsiteDataStore.nonPersistent() : WKWebsiteDataStore(forIdentifier: spaceID)
        dataStores[spaceID] = store
        return store
    }

    func makeConfiguration(for spaceID: UUID) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore(for: spaceID)
        configuration.applicationNameForUserAgent = Self.safariUserAgentSuffix
        configuration.preferences.isElementFullscreenEnabled = true
        let content = WKUserContentController()
        installUserScripts(into: content)
        content.add(themeHandler, contentWorld: .defaultClient, name: ThemeColorHandler.name)
        content.add(autofillHandler, contentWorld: .defaultClient, name: PasswordAutofillHandler.name)
        #if os(macOS)
        content.add(ContextLinkHandler(), contentWorld: .defaultClient, name: ContextLinkHandler.name)
        #endif
        if let list = contentBlocker.activeRuleList { content.add(list) }
        configuration.userContentController = content
        #if os(iOS)
        configuration.allowsInlineMediaPlayback = true
        #endif
        return configuration
    }

    /// Dew's page scripts (site colour, password autofill, cookie banners), all in Dew's own JS world.
    private func installUserScripts(into content: WKUserContentController) {
        content.addUserScript(WKUserScript(source: ThemeColorHandler.script, injectionTime: .atDocumentEnd,
                                           forMainFrameOnly: true, in: .defaultClient))
        content.addUserScript(WKUserScript(source: PasswordAutofillHandler.script, injectionTime: .atDocumentEnd,
                                           forMainFrameOnly: true, in: .defaultClient))
        // Darken pages: at document start, so it's ready before the page first paints.
        content.addUserScript(WKUserScript(source: DarkPages.script(enabled: darkenPages), injectionTime: .atDocumentStart,
                                           forMainFrameOnly: true, in: .defaultClient))
        #if os(macOS)
        // All frames, so links inside iframes get Dew's right-click actions too.
        content.addUserScript(WKUserScript(source: ContextLinkHandler.script, injectionTime: .atDocumentStart,
                                           forMainFrameOnly: false, in: .defaultClient))
        #endif
        if let cookies = CookieBanners.script(mode: cookieBannerMode) {
            // All frames: some consent banners live in iframes.
            content.addUserScript(WKUserScript(source: cookies, injectionTime: .atDocumentEnd,
                                               forMainFrameOnly: false, in: .defaultClient))
        }
    }

    /// Applies a changed cookie-banner setting to open tabs (from their next page load).
    private func reinstallUserScripts() {
        for tab in tabs {
            guard let content = tab.loadedWebView?.configuration.userContentController else { continue }
            content.removeAllUserScripts()
            installUserScripts(into: content)
        }
    }

    /// Without "Version/x Safari/x" some sites (Google sign-in among them) treat WKWebView as an unsupported browser.
    private static let safariUserAgentSuffix: String = {
        let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        #if os(macOS)
        let safari = major >= 26 ? major : major + 3
        #else
        let safari = major
        #endif
        return "Version/\(safari).0 Safari/605.1.15"
    }()

    // MARK: History

    func recordVisit(_ tab: BrowserTab) {
        guard !isPrivate(tab.spaceID), let url = tab.url, url.scheme?.hasPrefix("http") == true else { return }
        if let index = history.firstIndex(where: { $0.spaceID == tab.spaceID && $0.url == url }) {
            var entry = history.remove(at: index)
            entry.title = tab.title.isEmpty ? entry.title : tab.title
            entry.lastVisited = .now
            entry.visitCount += 1
            history.insert(entry, at: 0)
        } else {
            history.insert(HistoryEntry(spaceID: tab.spaceID, url: url, title: tab.title, lastVisited: .now, visitCount: 1), at: 0)
            if history.count > Self.historyLimit { history.removeLast(history.count - Self.historyLimit) }
        }
        setNeedsSave()
    }

    var recentlyClosed: [TabRecord] { closedTabs.reversed().filter { $0.spaceID == selectedSpaceID } }

    func reopen(_ record: TabRecord) {
        closedTabs.removeAll { $0.id == record.id }
        let tab = BrowserTab(id: record.id, spaceID: record.spaceID, url: record.url, title: record.title,
                             faviconURL: record.faviconURL, isPinned: false, themeColor: record.themeColor, store: self)
        tabs.append(tab)
        select(tab)
    }

    func history(in spaceID: UUID, matching query: String = "", limit: Int = .max) -> [HistoryEntry] {
        let query = query.trimmingCharacters(in: .whitespaces)
        var results: [HistoryEntry] = []
        for entry in history where entry.spaceID == spaceID {
            if query.isEmpty || entry.title.localizedCaseInsensitiveContains(query)
                || entry.url.absoluteString.localizedCaseInsensitiveContains(query) {
                results.append(entry)
                if results.count >= limit { break }
            }
        }
        return results
    }

    func deleteHistory(_ entry: HistoryEntry) {
        history.removeAll { $0.id == entry.id }
        setNeedsSave()
    }

    // MARK: Import

    /// Adds imported bookmarks and history to a space (creating it when `spaceID` is nil).
    @discardableResult
    func importData(_ data: ImportedProfileData, into spaceID: UUID?, newSpaceName: String) -> (bookmarks: Int, history: Int) {
        let targetID: UUID
        if let spaceID, spaces.contains(where: { $0.id == spaceID }) {
            targetID = spaceID
        } else {
            let color = Space.palette.first { hex in !spaces.contains { $0.colorHex == hex } } ?? Space.palette[0]
            let space = Space(name: newSpaceName, colorHex: color, symbol: "person.fill")
            spaces.append(space)
            targetID = space.id
        }

        var addedBookmarks = 0
        var existingBookmarks = Set(bookmarks.filter { $0.spaceID == targetID }.map(\.url))
        // Re-importing also fixes icons on bookmarks you already have.
        for item in data.bookmarks where existingBookmarks.contains(item.url) {
            guard let icon = item.faviconURL, icon != item.url.faviconGuess,
                  let index = bookmarks.firstIndex(where: { $0.spaceID == targetID && $0.url == item.url }) else { continue }
            bookmarks[index].faviconURL = icon
        }
        for item in data.bookmarks where !existingBookmarks.contains(item.url) {
            bookmarks.append(Bookmark(spaceID: targetID, title: item.title, url: item.url, faviconURL: item.faviconURL, modified: .now))
            existingBookmarks.insert(item.url)
            addedBookmarks += 1
        }

        var positions = Dictionary(history.enumerated().filter { $0.element.spaceID == targetID }.map { ($0.element.url, $0.offset) },
                                   uniquingKeysWith: { first, _ in first })
        for item in data.history {
            if let index = positions[item.url] {
                history[index].visitCount += item.visitCount
                history[index].lastVisited = max(history[index].lastVisited, item.lastVisited)
            } else {
                history.append(HistoryEntry(spaceID: targetID, url: item.url, title: item.title,
                                            lastVisited: item.lastVisited, visitCount: item.visitCount))
                positions[item.url] = history.count - 1
            }
        }
        history.sort { $0.lastVisited > $1.lastVisited }
        if history.count > Self.historyLimit { history.removeLast(history.count - Self.historyLimit) }
        setNeedsSave()
        return (addedBookmarks, data.history.count)
    }

    func clearHistory(for spaceID: UUID) {
        history.removeAll { $0.spaceID == spaceID }
        closedTabs.removeAll { $0.spaceID == spaceID }
        setNeedsSave()
    }

    /// Removes cookies, logins, local storage, caches etc. for one space only, then reloads its open tabs.
    func clearWebsiteData(for spaceID: UUID) async {
        await dataStore(for: spaceID).removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        for tab in tabs where tab.spaceID == spaceID { tab.loadedWebView?.reload() }
    }

    func updatePrivacy(of spaceID: UUID, _ change: (inout PrivacySettings) -> Void) {
        guard let index = spaces.firstIndex(where: { $0.id == spaceID }) else { return }
        var settings = spaces[index].privacySettings
        let oldSchedule = settings.schedule
        change(&settings)
        // A new period starts counting from now.
        if settings.schedule != oldSchedule { settings.lastCleared = .now }
        spaces[index].privacySettings = settings
        setNeedsSave()
    }

    enum AutoClearTrigger { case launch, quit, periodic }

    var needsClearOnQuit: Bool {
        spaces.contains { $0.privacySettings.schedule == .onQuit }
    }

    /// Applies each space's automatic clearing. "When Dew quits" also runs at launch, so it still
    /// happens if the app was force-quit or (on iOS) closed by the system.
    func runAutoClear(_ trigger: AutoClearTrigger) async {
        let now = Date()
        for space in spaces {
            let settings = space.privacySettings
            let due: Bool
            switch settings.schedule {
            case .never: due = false
            case .onQuit: due = trigger != .periodic
            case .daily, .weekly, .monthly:
                due = now.timeIntervalSince(settings.lastCleared ?? now) >= settings.schedule.interval ?? .infinity
            }
            guard due, settings.clearHistory || settings.clearCookies else { continue }
            if settings.clearHistory { clearHistory(for: space.id) }
            if settings.clearCookies { await clearWebsiteData(for: space.id) }
            if let index = spaces.firstIndex(where: { $0.id == space.id }) { spaces[index].privacySettings.lastCleared = now }
        }
        saveNow()
    }

    // MARK: Ad blocking

    func applyContentBlocking(reload: Bool) {
        for tab in tabs {
            guard let controller = tab.loadedWebView?.configuration.userContentController else { continue }
            controller.removeAllContentRuleLists()
            if let list = contentBlocker.activeRuleList { controller.add(list) }
        }
        if reload, selectedTab?.url != nil { selectedTab?.loadedWebView?.reload() }
    }

    // MARK: Passwords

    func fill(_ login: SavedLogin, in tab: BrowserTab) async {
        guard let webView = tab.loadedWebView else { return }
        _ = try? await webView.callAsyncJavaScript("window.__dewFill && window.__dewFill(u, p)",
                                                   arguments: ["u": login.username, "p": login.password],
                                                   contentWorld: .defaultClient)
        passwords.markUsed(login)
    }

    /// Usernames (only) for the page's suggestion dropdown.
    func sendSuggestions(_ logins: [SavedLogin], to tab: BrowserTab, pageHost: String? = nil) async {
        guard let webView = tab.loadedWebView else { return }
        let page = PasswordStore.normalize(pageHost ?? webView.url?.host() ?? "")
        // The site label is only shown when the login belongs to a different subdomain, like Dia.
        let list = logins.map { login -> [String: String] in
            let site = PasswordStore.normalize(login.host)
            return ["id": login.id.uuidString, "username": login.username, "site": site == page ? "" : site]
        }
        _ = try? await webView.callAsyncJavaScript("window.__dewSetLogins && window.__dewSetLogins(list)",
                                                   arguments: ["list": list], contentWorld: .defaultClient)
    }

    func resolvePendingLogin(save: Bool, never: Bool = false) {
        guard let pending = pendingLogin else { return }
        if save {
            passwords.save(host: pending.host, username: pending.username, password: pending.password, spaceID: pending.spaceID)
            if let tab = tabs.first(where: { $0.id == pending.tabID }) {
                let logins = passwords.logins(forHost: pending.host, in: pending.spaceID)
                Task { await sendSuggestions(logins, to: tab) }
            }
        } else if never {
            passwords.neverSave(host: pending.host, spaceID: pending.spaceID)
        }
        pendingLogin = nil
    }

    // MARK: Bookmarks

    var currentBookmarks: [Bookmark] { bookmarks.filter { $0.spaceID == selectedSpaceID } }

    func bookmark(for url: URL?, in spaceID: UUID) -> Bookmark? {
        guard let url else { return nil }
        return bookmarks.first { $0.spaceID == spaceID && $0.url == url }
    }

    func isBookmarked(_ tab: BrowserTab?) -> Bool {
        guard let tab else { return false }
        return bookmark(for: tab.url, in: tab.spaceID) != nil
    }

    func toggleBookmark(for tab: BrowserTab?) {
        guard let tab, let url = tab.url, !isPrivate(tab.spaceID) else { return }
        if let existing = bookmark(for: url, in: tab.spaceID) {
            removeBookmark(existing)
        } else {
            addBookmark(for: tab)
        }
    }

    func addBookmark(for tab: BrowserTab, before target: Bookmark? = nil) {
        guard let url = tab.url, bookmark(for: url, in: tab.spaceID) == nil else { return }
        let bookmark = Bookmark(spaceID: tab.spaceID, title: tab.displayTitle, url: url, faviconURL: tab.faviconURL, modified: .now)
        if let target, let index = bookmarks.firstIndex(where: { $0.id == target.id }) {
            bookmarks.insert(bookmark, at: index)
        } else {
            bookmarks.append(bookmark)
        }
        setNeedsSave()
    }

    /// When a page's real icon is found, give it to bookmarks for the same site (scheme, host and port).
    /// Fixes icons that need a login to fetch (e.g. Radarr), which the bookmark couldn't get on its own.
    func learnFavicon(_ icon: URL, for pageURL: URL, in spaceID: UUID) {
        guard let origin = pageURL.originURL else { return }
        var changed = false
        for index in bookmarks.indices where bookmarks[index].spaceID == spaceID
            && bookmarks[index].url.originURL == origin && bookmarks[index].faviconURL != icon {
            bookmarks[index].faviconURL = icon
            changed = true
        }
        if changed { setNeedsSave() }
    }

    func removeBookmark(_ bookmark: Bookmark) {
        bookmarks.removeAll { $0.id == bookmark.id }
        setNeedsSave()
    }

    func renameBookmark(_ bookmark: Bookmark, to title: String) {
        guard let index = bookmarks.firstIndex(where: { $0.id == bookmark.id }) else { return }
        bookmarks[index].title = title
        bookmarks[index].modified = .now
        setNeedsSave()
    }

    func moveBookmark(_ bookmark: Bookmark, before target: Bookmark) {
        guard bookmark.id != target.id, let from = bookmarks.firstIndex(where: { $0.id == bookmark.id }) else { return }
        let moved = bookmarks.remove(at: from)
        let to = bookmarks.firstIndex { $0.id == target.id } ?? bookmarks.count
        bookmarks.insert(moved, at: to)
        setNeedsSave()
    }

    func open(_ bookmark: Bookmark, inNewTab: Bool = false, select: Bool = true) {
        if inNewTab || selectedTab == nil {
            newTab(url: bookmark.url, in: bookmark.spaceID, select: select)
        } else {
            selectedTab?.load(bookmark.url)
        }
    }

    // MARK: Persistence

    private struct SavedState: Codable {
        var spaces: [Space]
        var tabs: [TabRecord]
        var selectedSpaceID: UUID
        var selectedTabIDs: [UUID: UUID]
        var history: [HistoryEntry]
        var bookmarks: [Bookmark]?
        var splits: [TabSplit]?
    }

    private static var stateURL: URL {
        let directory = URL.applicationSupportDirectory.appending(path: "Dew", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "state.json")
    }

    /// Example content for screenshots (see `isDemo`).
    private func loadDemo() {
        let personal = Space(name: "Personal", colorHex: "#D6336C", symbol: "person.fill")
        let work = Space(name: "Work", colorHex: "#1C7ED6", symbol: "briefcase.fill")
        spaces = [personal, work]
        selectedSpaceID = personal.id
        func open(_ address: String, _ title: String, in space: Space) -> BrowserTab {
            let tab = BrowserTab(spaceID: space.id, url: URL(string: address), title: title, store: self)
            tabs.append(tab)
            return tab
        }
        let dew = open("https://en.wikipedia.org/wiki/Dew", "Dew - Wikipedia", in: personal)
        _ = open("https://www.apple.com/", "Apple", in: personal)
        _ = open("https://www.python.org/", "Welcome to Python.org", in: personal)
        let repo = open("https://github.com/benjustjammin/dewBrowser", "dewBrowser", in: work)
        _ = open("https://developer.apple.com/documentation/webkit", "WebKit | Apple Developer", in: work)
        selectedTabIDs[personal.id] = dew.id
        selectedTabIDs[work.id] = repo.id
        // `-DewDemoTab 2` shows the space's third tab instead (Python.org: a coloured page, so the toolbar matches it).
        let pick = UserDefaults.standard.integer(forKey: "DewDemoTab")
        let personalTabs = tabs.filter { $0.spaceID == personal.id }
        if personalTabs.indices.contains(pick) { selectedTabIDs[personal.id] = personalTabs[pick].id }
        // `-DewDemoURL <address>` adds a tab and shows it (to pick a page with a strong colour for screenshots).
        if let address = UserDefaults.standard.string(forKey: "DewDemoURL") {
            selectedTabIDs[personal.id] = open(address, "", in: personal).id
        }
        let marks: [(String, String, Space)] = [
            ("Wikipedia", "https://en.wikipedia.org/", personal), ("YouTube", "https://www.youtube.com/", personal),
            ("Apple", "https://www.apple.com/", personal), ("Python", "https://www.python.org/", personal),
            ("GitHub", "https://github.com/", work), ("Apple Developer", "https://developer.apple.com/", work),
        ]
        bookmarks = marks.map { Bookmark(spaceID: $0.2.id, title: $0.0, url: URL(string: $0.1)!, modified: .now) }
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.stateURL),
              let state = try? JSONDecoder().decode(SavedState.self, from: data), !state.spaces.isEmpty else { return }
        spaces = state.spaces
        selectedSpaceID = state.selectedSpaceID
        selectedTabIDs = state.selectedTabIDs
        history = state.history
        bookmarks = state.bookmarks ?? []
        // Repair icons saved by an older version that dropped the port (http://192.168.1.20/favicon.ico).
        for index in bookmarks.indices where bookmarks[index].faviconURL != nil
            && bookmarks[index].faviconURL == bookmarks[index].url.legacyFaviconGuess {
            bookmarks[index].faviconURL = bookmarks[index].url.faviconGuess
        }
        tabs = state.tabs.map {
            BrowserTab(id: $0.id, spaceID: $0.spaceID, url: $0.url, title: $0.title,
                       faviconURL: $0.faviconURL, isPinned: $0.isPinned, themeColor: $0.themeColor, store: self)
        }
        // Splits are checked against the restored tabs, so this must come after them.
        let tabIDs = Set(tabs.map(\.id))
        splits = (state.splits ?? []).compactMap { split in
            var split = split
            split.tabIDs = split.tabIDs.filter(tabIDs.contains)
            guard split.tabIDs.count >= 2 else { return nil }
            if split.fractions.count != split.tabIDs.count { split.fractions = TabSplit.equal(split.tabIDs.count) }
            return split
        }
    }

    func setNeedsSave() {
        guard !Self.isDemo else { return }
        cloudSync.setNeedsPush()
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            saveNow()
        }
    }

    func saveNow() {
        guard !Self.isDemo else { return }
        saveTask?.cancel()
        // Private browsing is never written to disk.
        let savedTabs = tabs.filter { !isPrivate($0.spaceID) }
        let state = SavedState(spaces: spaces, tabs: savedTabs.map(\.record),
                               selectedSpaceID: isPrivate ? (lastNormalSpaceID ?? spaces[0].id) : selectedSpaceID,
                               selectedTabIDs: selectedTabIDs.filter { !isPrivate($0.key) }, history: history,
                               bookmarks: bookmarks, splits: splits.filter { split in savedTabs.contains { split.tabIDs.contains($0.id) } })
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: Self.stateURL, options: .atomic)
    }
}

// MARK: - Site colour

/// Receives the colour sampled from the top of each page by `script` (runs in an isolated JS world).
@MainActor
final class ThemeColorHandler: NSObject, WKScriptMessageHandler {
    static let name = "dewTheme"
    private weak var store: BrowserStore?

    init(store: BrowserStore) { self.store = store }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let webView = message.webView,
              let values = message.body as? [NSNumber], values.count == 3,
              let tab = store?.tab(for: webView) else { return }
        let color = RGBColor(r: values[0].doubleValue, g: values[1].doubleValue, b: values[2].doubleValue)
        if tab.themeColor != color { tab.themeColor = color }
    }

    /// Samples the background at the very top of the page (left, middle, right; majority wins),
    /// walking up from the element under each point until something has an opaque background.
    static let script = """
    (() => {
      let last = '';
      const parse = (c) => {
        const m = c && c.match(/rgba?\\(([^)]+)\\)/);
        if (!m) return null;
        const p = m[1].split(/[\\s,\\/]+/).filter(Boolean).map(parseFloat);
        if (p.length >= 4 && p[3] < 0.85) return null;
        return p.slice(0, 3);
      };
      const colorAt = (x, y) => {
        let el = document.elementFromPoint(x, y);
        while (el && el !== document.documentElement) {
          const c = parse(getComputedStyle(el).backgroundColor);
          if (c) return c;
          el = el.parentElement;
        }
        return parse(getComputedStyle(document.documentElement).backgroundColor)
          || (matchMedia('(prefers-color-scheme: dark)').matches && getComputedStyle(document.documentElement).colorScheme.includes('dark') ? [30, 30, 30] : [255, 255, 255]);
      };
      const sample = () => {
        if (!document.body) return;
        const w = innerWidth;
        const keys = [0.08, 0.5, 0.92].map(f => colorAt(w * f, 1).map(Math.round).join(','));
        const counts = {};
        keys.forEach(k => counts[k] = (counts[k] || 0) + 1);
        let best = keys.slice().sort((a, b) => counts[b] - counts[a])[0];
        // Darkened page (Darken pages): match the colour as it now appears, with its lightness flipped.
        if (document.getElementById('__dew_dark_pages')) best = darkened(best.split(',').map(Number)).join(',');
        if (best !== last) {
          last = best;
          window.webkit.messageHandlers.\(name).postMessage(best.split(',').map(Number));
        }
      };
      // Same hue and saturation, lightness flipped: what invert + hue-rotate(180°) does to a colour.
      const darkened = ([r, g, b]) => {
        r /= 255; g /= 255; b /= 255;
        const max = Math.max(r, g, b), min = Math.min(r, g, b), l = (max + min) / 2, d = max - min;
        let h = 0, s = 0;
        if (d) {
          s = d / (1 - Math.abs(2 * l - 1));
          h = max === r ? ((g - b) / d) % 6 : max === g ? (b - r) / d + 2 : (r - g) / d + 4;
        }
        const L = 1 - l, C = (1 - Math.abs(2 * L - 1)) * s, X = C * (1 - Math.abs(h % 2 - 1)), m = L - C / 2;
        const [r1, g1, b1] = h < 1 ? [C, X, 0] : h < 2 ? [X, C, 0] : h < 3 ? [0, C, X] : h < 4 ? [0, X, C] : h < 5 ? [X, 0, C] : [C, 0, X];
        return [r1 + m, g1 + m, b1 + m].map(v => Math.round(Math.max(0, Math.min(1, v)) * 255));
      };
      let pending = false;
      const schedule = () => {
        if (pending) return;
        pending = true;
        setTimeout(() => { pending = false; sample(); }, 120);
      };
      window.__dewThemeResample = schedule;   // Darken pages calls this when it turns on or off
      sample();
      setTimeout(sample, 600);
      addEventListener('load', schedule);
      addEventListener('scroll', schedule, { passive: true });
      addEventListener('resize', schedule);
      addEventListener('popstate', schedule);
      matchMedia('(prefers-color-scheme: dark)').addEventListener('change', schedule);
    })();
    """
}

// MARK: - Downloads

@MainActor @Observable
final class DownloadManager: NSObject, WKDownloadDelegate {
    struct Item: Identifiable, Codable {
        var id = UUID()
        var filename: String
        var fileURL: URL
        var progress: Double = 0
        var finished = false
        var failed = false
    }

    /// Finished downloads are remembered across launches (like Dia); ones whose file is gone are dropped.
    private(set) var items: [Item] = [] {
        didSet { save() }
    }

    override init() {
        super.init()
        if let data = UserDefaults.standard.data(forKey: "downloads"),
           let saved = try? JSONDecoder().decode([Item].self, from: data) {
            items = saved.filter { $0.finished && FileManager.default.fileExists(atPath: $0.fileURL.path) }
        }
    }

    private func save() {
        let finished = items.filter(\.finished).prefix(50)
        UserDefaults.standard.set(try? JSONEncoder().encode(Array(finished)), forKey: "downloads")
    }
    @ObservationIgnored private var itemIDs: [ObjectIdentifier: UUID] = [:]
    @ObservationIgnored private var progressObservations: [UUID: NSKeyValueObservation] = [:]

    static var directory: URL {
        #if os(macOS)
        URL.downloadsDirectory
        #else
        URL.documentsDirectory
        #endif
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
        let destination = Self.uniqueURL(for: suggestedFilename)
        let item = Item(filename: destination.lastPathComponent, fileURL: destination)
        items.insert(item, at: 0)
        itemIDs[ObjectIdentifier(download)] = item.id
        progressObservations[item.id] = download.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            let fraction = progress.fractionCompleted
            Task { @MainActor in self?.update(item.id) { $0.progress = fraction } }
        }
        return destination
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let id = itemIDs.removeValue(forKey: ObjectIdentifier(download)) else { return }
        progressObservations[id] = nil
        update(id) { $0.finished = true; $0.progress = 1 }
        #if os(macOS)
        if let item = items.first(where: { $0.id == id }) {
            // Makes the Downloads stack in the Dock bounce, like Safari.
            DistributedNotificationCenter.default().post(name: .init("com.apple.DownloadFileFinished"), object: item.fileURL.path)
        }
        #endif
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let id = itemIDs.removeValue(forKey: ObjectIdentifier(download)) else { return }
        progressObservations[id] = nil
        update(id) { $0.failed = true }
    }

    func clearFinished() {
        items.removeAll { $0.finished || $0.failed }
    }

    private func update(_ id: UUID, _ change: (inout Item) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
    }

    private static func uniqueURL(for filename: String) -> URL {
        let name = filename.isEmpty ? "download" : filename
        var url = directory.appending(path: name)
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appending(path: ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)")
            counter += 1
        }
        return url
    }
}

/// Bookmarks and history read from another browser profile.
struct ImportedProfileData: Sendable {
    struct Item: Sendable {
        let title: String
        let url: URL
        let faviconURL: URL?
    }

    struct Visit: Sendable {
        let url: URL
        let title: String
        let visitCount: Int
        let lastVisited: Date
    }

    var bookmarks: [Item] = []
    var history: [Visit] = []
}

extension URL {
    /// Best-effort icon for a page we haven't loaded: the site's /favicon.ico.
    var faviconGuess: URL? {
        guard let origin = originURL else { return nil }
        return URL(string: "/favicon.ico", relativeTo: origin)?.absoluteURL
    }

    /// scheme://host[:port]/ — e.g. http://192.168.1.20:7878/ (the port matters for local devices).
    var originURL: URL? {
        guard let scheme, scheme.hasPrefix("http"), let host else { return nil }
        let portPart = port.map { ":\($0)" } ?? ""
        return URL(string: "\(scheme)://\(host)\(portPart)/")
    }

    /// The old, port-less guess (used to repair bookmarks saved before the fix).
    var legacyFaviconGuess: URL? {
        guard let scheme, scheme.hasPrefix("http"), let host, port != nil else { return nil }
        return URL(string: "\(scheme)://\(host)/favicon.ico")
    }
}

/// iOS browser layouts: iPhone Duo (buttons in the side column), iPhone bottom bar, or toolbar at the top.
enum BrowserLayout { case duo, bottomBar, toolbar }

enum TabSuspension: Int, CaseIterable, Identifiable {
    case never = 0, fifteenMinutes = 15, thirtyMinutes = 30, oneHour = 60, fourHours = 240, oneDay = 1440

    var id: Int { rawValue }
    var interval: TimeInterval? { self == .never ? nil : TimeInterval(rawValue * 60) }
    var title: String {
        switch self {
        case .never: "Never"
        case .fifteenMinutes: "After 15 minutes"
        case .thirtyMinutes: "After 30 minutes"
        case .oneHour: "After 1 hour"
        case .fourHours: "After 4 hours"
        case .oneDay: "After 1 day"
        }
    }
}

/// Tabs shown side by side, like Dia's split view.
struct TabSplit: Codable, Identifiable, Equatable {
    static let maxPanes = 4
    static let minFraction = 0.15

    var id = UUID()
    var tabIDs: [UUID]
    /// Width of each pane as a fraction of the total; same order as `tabIDs`.
    var fractions: [Double]

    static func equal(_ count: Int) -> [Double] { Array(repeating: 1 / Double(count), count: count) }
}

enum AddressBarPosition: String, CaseIterable, Identifiable {
    case automatic, top, bottom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .top: "Top"
        case .bottom: "Bottom"
        }
    }
}
