import AppKit
import SwiftUI
import WebKit

/// An installed extension: its package in Application Support/Dew/Extensions (a ZIP from the Chrome Web Store, or a
/// copied folder or ZIP), and the user's choices for it.
struct InstalledExtension: Codable, Identifiable, Equatable {
    /// Also the extension context's unique identifier, so its storage survives relaunches.
    let id: String
    /// The Chrome Web Store ID, for store installs.
    var storeID: String?
    var fileName: String
    /// Remembered so Settings can name it while it's turned off.
    var name = ""
    var isEnabled = true
    var showsInToolbar = true
}

/// Chrome (WebExtension) support on the Mac, through WebKit's own WKWebExtension: installs from the Chrome Web Store
/// or a folder/ZIP, loads enabled extensions into every non-private tab, and acts as the "browser" they talk to
/// (one window holding Dew's tabs). Private tabs never run extensions, like Chrome's default.
@MainActor @Observable
final class ExtensionManager: NSObject, WKWebExtensionControllerDelegate {
    private(set) var installed: [InstalledExtension] = []
    /// Loaded contexts by `InstalledExtension.id`.
    private(set) var contexts: [String: WKWebExtensionContext] = [:]
    /// Bumped when an extension's toolbar action changes (icon, badge, title), so the buttons redraw.
    private(set) var actionsVersion = 0
    /// Problems from loading, by extension, shown in Settings.
    private(set) var problems: [String: String] = [:]
    var isInstalling = false

    @ObservationIgnored let controller: WKWebExtensionController
    @ObservationIgnored let window = ExtensionWindow()
    /// Toolbar buttons register here, so an extension's popup can point at its button.
    @ObservationIgnored var anchors: [String: NSView] = [:]
    @ObservationIgnored private weak var store: BrowserStore?
    @ObservationIgnored private var keyMonitor: Any?

    private static let defaultsKey = "extensions"
    /// Demo runs use a throwaway folder, so they never touch real installs.
    private nonisolated static let folder = UserDefaults.standard.bool(forKey: "DewDemo")
        ? URL.temporaryDirectory.appending(path: "DewDemoExtensions", directoryHint: .isDirectory)
        : URL.applicationSupportDirectory.appending(path: "Dew/Extensions", directoryHint: .isDirectory)

    init(store: BrowserStore) {
        self.store = store
        controller = WKWebExtensionController(configuration: BrowserStore.isDemo ? .nonPersistent() : .default())
        super.init()
        window.store = store
        controller.delegate = self
        // Tabs restored at launch were opened before this existed: introduce them, or extensions can't act on them.
        controller.didOpenWindow(window)
        for tab in store.tabs where canSee(tab) { controller.didOpenTab(tab) }
        if let selected = store.selectedTab, canSee(selected) { controller.didActivateTab(selected, previousActiveTab: nil) }
        controller.didFocusWindow(window)
        if !BrowserStore.isDemo, let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode([InstalledExtension].self, from: data) {
            installed = saved
        }
        Task {
            for item in installed where item.isEnabled { await load(item) }
            becomeReady()
        }
        // Never hold pages up for long, even if an extension is slow to load.
        Task { try? await Task.sleep(for: .seconds(1)); becomeReady() }
        // Extensions' keyboard shortcuts (the "commands" in their manifest).
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.contexts.values.contains { $0.performCommand(for: event) } ? nil : event
        }
    }

    // MARK: Startup

    @ObservationIgnored private var isReady = false
    @ObservationIgnored private var waiting: [() -> Void] = []

    /// Runs `body` once installed extensions have loaded (at most a second after launch), so pages restored at
    /// launch get their content scripts, as in Chrome.
    func whenReady(_ body: @escaping () -> Void) {
        if isReady { body() } else { waiting.append(body) }
    }

    private func becomeReady() {
        guard !isReady else { return }
        isReady = true
        waiting.forEach { $0() }
        waiting = []
    }

    // MARK: Installing

    /// The Chrome Web Store ID if `url` is an extension's store page.
    static func storeID(in url: URL?) -> String? {
        guard let url, url.host() == "chromewebstore.google.com", url.pathComponents.count >= 3,
              url.pathComponents[1] == "detail" else { return nil }
        let id = url.pathComponents.last ?? ""
        return id.count == 32 && id.allSatisfy({ ("a"..."p").contains($0) }) ? id : nil
    }

    func isInstalled(storeID: String) -> Bool { installed.contains { $0.storeID == storeID } }

    /// Downloads an extension from the Chrome Web Store and installs it after the user agrees to its permissions.
    func installFromStore(_ storeID: String) async {
        guard !isInstalling else { return }
        isInstalling = true
        defer { isInstalling = false }
        let query = "response=redirect&prodversion=140.0&acceptformat=crx2,crx3&x=id%3D\(storeID)%26installsource%3Dondemand%26uc"
        do {
            let (data, _) = try await URLSession.shared.data(from: URL(string: "https://clients2.google.com/service/update2/crx?\(query)")!)
            guard let zip = Self.zipPayload(ofCRX: data) else { throw InstallError.notAnExtension }
            let item = InstalledExtension(id: storeID, storeID: storeID, fileName: "\(storeID).zip")
            let staged = try Self.staging(item)
            try zip.write(to: staged, options: .atomic)
            await finishInstall(item, staged: staged)
        } catch {
            alert("Couldn't add this extension", error.localizedDescription)
        }
    }

    /// Installs an unpacked extension folder or a ZIP the user picks (a copy is kept, so the original can move).
    func installFromDisk() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [.zip, .folder]
        panel.message = "Choose an extension folder (with a manifest.json) or a ZIP"
        panel.prompt = "Add"
        guard panel.runModal() == .OK, let source = panel.url else { return }
        let id = UUID().uuidString
        let item = InstalledExtension(id: id, fileName: source.hasDirectoryPath ? id : "\(id).zip")
        do {
            let staged = try Self.staging(item)
            try FileManager.default.copyItem(at: source, to: staged)
            Task { await finishInstall(item, staged: staged) }
        } catch {
            alert("Couldn't add this extension", error.localizedDescription)
        }
    }

    /// Asks the user, then moves the staged package into place (replacing an earlier install of it) and loads it.
    /// Cancelling leaves any earlier install untouched.
    private func finishInstall(_ item: InstalledExtension, staged: URL) async {
        let fileManager = FileManager.default
        defer { try? fileManager.removeItem(at: staged) }
        do {
            let webExtension = try await WKWebExtension(resourceBaseURL: staged)
            guard confirmInstall(webExtension) else { return }
            if let old = contexts.removeValue(forKey: item.id) { try? controller.unload(old) }
            let destination = Self.folder.appending(path: item.fileName)
            try? fileManager.removeItem(at: destination)
            try fileManager.moveItem(at: staged, to: destination)
            var item = item
            item.name = webExtension.displayName ?? ""
            installed.removeAll { $0.id == item.id }
            installed.append(item)
            save()
            await load(item)
        } catch {
            alert("Couldn't add this extension", error.localizedDescription)
        }
    }

    /// Where a package waits while the user decides (next to where it will go, so moving it in is instant).
    private static func staging(_ item: InstalledExtension) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let staged = folder.appending(path: "staged-" + item.fileName)
        try? FileManager.default.removeItem(at: staged)
        return staged
    }

    /// Chrome's "Add …?" dialog: what the extension will be able to do.
    private func confirmInstall(_ webExtension: WKWebExtension) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Add “\(webExtension.displayName ?? "this extension")” to Dew?"
        let access = Self.describe(webExtension)
        alert.informativeText = access.isEmpty ? "It doesn't ask for any special access." : "It can:\n" + access.map { "• \($0)" }.joined(separator: "\n")
        alert.icon = webExtension.icon(for: CGSize(width: 64, height: 64))
        alert.addButton(withTitle: "Add Extension")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Plain-language access, like Chrome's install prompt.
    static func describe(_ webExtension: WKWebExtension) -> [String] {
        var lines: [String] = []
        let patterns = webExtension.requestedPermissionMatchPatterns.union(webExtension.allRequestedMatchPatterns)
        if patterns.contains(where: \.matchesAllHosts) {
            lines.append("Read and change your data on all websites")
        } else {
            let hosts = Set(patterns.compactMap(\.host)).sorted()
            if !hosts.isEmpty { lines.append("Read and change your data on " + hosts.prefix(4).joined(separator: ", ") + (hosts.count > 4 ? " and more" : "")) }
        }
        let permissions = webExtension.requestedPermissions
        if permissions.contains(.tabs) || permissions.contains(.webNavigation) { lines.append("Read your browsing history") }
        if permissions.contains(.cookies) { lines.append("Read and change cookies") }
        if permissions.contains(.clipboardWrite) { lines.append("Change what you copy and paste") }
        if permissions.contains(.declarativeNetRequest) || permissions.contains(.declarativeNetRequestWithHostAccess) { lines.append("Block content on any page") }
        if permissions.contains(.nativeMessaging) { lines.append("Talk to apps on your Mac") }
        return lines
    }

    /// The ZIP inside a Chrome Web Store package (CRX2 or CRX3: a signed header, then the ZIP).
    static func zipPayload(ofCRX data: Data) -> Data? {
        guard data.count > 16, data.prefix(4) == Data("Cr24".utf8) else {
            return data.prefix(2) == Data("PK".utf8) ? data : nil   // already a ZIP
        }
        func uint32(_ offset: Int) -> Int { data.subdata(in: offset..<offset + 4).withUnsafeBytes { Int($0.loadUnaligned(as: UInt32.self).littleEndian) } }
        let start: Int
        switch uint32(4) {
        case 2: start = 16 + uint32(8) + uint32(12)
        case 3: start = 12 + uint32(8)
        default: return nil
        }
        return start < data.count ? data.subdata(in: start..<data.count) : nil
    }

    enum InstallError: LocalizedError {
        case notAnExtension
        var errorDescription: String? { "The Chrome Web Store didn't return an extension package." }
    }

    // MARK: Loading

    private func load(_ item: InstalledExtension) async {
        do {
            let file = Self.folder.appending(path: item.fileName)
            let webExtension = try await WKWebExtension(resourceBaseURL: file)
            let context = WKWebExtensionContext(for: webExtension)
            context.uniqueIdentifier = item.id
            context.isInspectable = true
            // Demo runs keep everything in throwaway (non-persistent) stores, which WebKit treats as private.
            context.hasAccessToPrivateData = BrowserStore.isDemo
            // Granted at install (the user agreed to them); optional ones are asked for when the extension wants them.
            for permission in webExtension.requestedPermissions { context.setPermissionStatus(.grantedExplicitly, for: permission) }
            for pattern in webExtension.requestedPermissionMatchPatterns.union(webExtension.allRequestedMatchPatterns)
                where !webExtension.optionalPermissionMatchPatterns.contains(pattern) {
                context.setPermissionStatus(.grantedExplicitly, for: pattern)
            }
            try controller.load(context)
            contexts[item.id] = context
            problems[item.id] = nil
        } catch {
            problems[item.id] = error.localizedDescription
        }
    }

    func setEnabled(_ enabled: Bool, for id: String) {
        guard let index = installed.firstIndex(where: { $0.id == id }) else { return }
        installed[index].isEnabled = enabled
        save()
        if enabled {
            Task { await load(installed[index]) }
        } else if let context = contexts.removeValue(forKey: id) {
            try? controller.unload(context)
        }
    }

    func setShowsInToolbar(_ shows: Bool, for id: String) {
        guard let index = installed.firstIndex(where: { $0.id == id }) else { return }
        installed[index].showsInToolbar = shows
        save()
    }

    func remove(_ id: String) {
        guard let index = installed.firstIndex(where: { $0.id == id }) else { return }
        if let context = contexts.removeValue(forKey: id) {
            // Its stored data (settings, caches) goes too, then it's unloaded.
            Task {
                let types = WKWebExtensionController.allExtensionDataTypes
                if let record = await controller.dataRecord(ofTypes: types, for: context) {
                    await controller.removeData(ofTypes: types, from: [record])
                }
                try? controller.unload(context)
            }
        }
        try? FileManager.default.removeItem(at: Self.folder.appending(path: installed[index].fileName))
        installed.remove(at: index)
        problems[id] = nil
        save()
    }

    /// The web view configuration for one of an extension's own pages (nil for anything else).
    func configuration(for url: URL) -> WKWebViewConfiguration? {
        guard url.scheme == "webkit-extension" else { return nil }
        return controller.extensionContext(for: url)?.webViewConfiguration
    }

    /// The extension's name, shown in the address bar for its pages instead of its internal ID.
    func name(for url: URL) -> String? {
        guard url.scheme == "webkit-extension" else { return nil }
        return controller.extensionContext(for: url)?.webExtension.displayName
    }

    func openOptions(for id: String) {
        guard let url = contexts[id]?.optionsPageURL else { return }
        store?.newTab(url: url)
    }

    private func save() {
        guard !BrowserStore.isDemo, let data = try? JSONEncoder().encode(installed) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }

    private func alert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    // MARK: Telling extensions what the tabs are doing

    func didOpen(_ tab: BrowserTab) {
        guard canSee(tab) else { return }
        controller.didOpenTab(tab)
    }

    func didClose(_ tab: BrowserTab) {
        guard canSee(tab) else { return }
        controller.didCloseTab(tab, windowIsClosing: false)
    }

    func didActivate(_ tab: BrowserTab, previous: BrowserTab?) {
        guard canSee(tab) else { return }
        controller.didActivateTab(tab, previousActiveTab: previous.flatMap { canSee($0) ? $0 : nil })
    }

    func didChange(_ properties: WKWebExtension.TabChangedProperties, of tab: BrowserTab) {
        guard canSee(tab), !contexts.isEmpty else { return }
        controller.didChangeTabProperties(properties, for: tab)
    }

    /// Extensions never see private tabs.
    func canSee(_ tab: BrowserTab) -> Bool { !(store?.isPrivate(tab.spaceID) ?? true) }

    // MARK: WKWebExtensionControllerDelegate

    func webExtensionController(_ controller: WKWebExtensionController, openWindowsFor extensionContext: WKWebExtensionContext) -> [any WKWebExtensionWindow] {
        [window]
    }

    func webExtensionController(_ controller: WKWebExtensionController, focusedWindowFor extensionContext: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        NSApp.isActive ? window : nil
    }

    func webExtensionController(_ controller: WKWebExtensionController, openNewTabUsing configuration: WKWebExtension.TabConfiguration,
                                for extensionContext: WKWebExtensionContext) async throws -> (any WKWebExtensionTab)? {
        guard let store else { return nil }
        let space = store.isPrivate ? store.spaces.first?.id : store.selectedSpaceID
        let tab = store.newTab(url: configuration.url, in: space, select: configuration.shouldBeActive)
        if configuration.shouldBePinned { store.togglePin(tab) }
        return tab
    }

    func webExtensionController(_ controller: WKWebExtensionController, openNewWindowUsing configuration: WKWebExtension.WindowConfiguration,
                                for extensionContext: WKWebExtensionContext) async throws -> (any WKWebExtensionWindow)? {
        // Dew has one window: the "new window" opens as tabs in it.
        for url in configuration.tabURLs { store?.newTab(url: url) }
        if configuration.tabURLs.isEmpty { store?.newBlankTab() }
        return window
    }

    func webExtensionController(_ controller: WKWebExtensionController, openOptionsPageFor extensionContext: WKWebExtensionContext) async throws {
        if let url = extensionContext.optionsPageURL { store?.newTab(url: url) }
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissions permissions: Set<WKWebExtension.Permission>,
                                in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext) async -> (Set<WKWebExtension.Permission>, Date?) {
        let names = permissions.map(\.rawValue).sorted().joined(separator: ", ")
        return (ask(extensionContext, "would like more access: \(names).") ? permissions : [], nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionToAccess urls: Set<URL>,
                                in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext) async -> (Set<URL>, Date?) {
        let hosts = Set(urls.compactMap { $0.host() }).sorted().joined(separator: ", ")
        return (ask(extensionContext, "would like to read and change your data on \(hosts).") ? urls : [], nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>,
                                in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext) async -> (Set<WKWebExtension.MatchPattern>, Date?) {
        let all = matchPatterns.contains(where: \.matchesAllHosts)
        let sites = all ? "all websites" : Set(matchPatterns.compactMap(\.host)).sorted().joined(separator: ", ")
        return (ask(extensionContext, "would like to read and change your data on \(sites).") ? matchPatterns : [], nil)
    }

    private func ask(_ context: WKWebExtensionContext, _ request: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "“\(context.webExtension.displayName ?? "An extension")” \(request)"
        alert.icon = context.webExtension.icon(for: CGSize(width: 64, height: 64))
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Don't Allow")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func webExtensionController(_ controller: WKWebExtensionController, didUpdate action: WKWebExtension.Action,
                                forExtensionContext context: WKWebExtensionContext) {
        actionsVersion &+= 1
    }

    func webExtensionController(_ controller: WKWebExtensionController, presentActionPopup action: WKWebExtension.Action,
                                for context: WKWebExtensionContext) async throws {
        guard let popover = action.popupPopover else { return }
        let id = context.uniqueIdentifier
        let anchor = anchors[id].flatMap { $0.window == nil ? nil : $0 } ?? anchors["menu"] ?? NSApp.keyWindow?.contentView
        guard let anchor else { return }
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
    }
}

/// Dew's one window, as extensions see it: every non-private tab, the selected one active.
@MainActor
final class ExtensionWindow: NSObject, WKWebExtensionWindow {
    weak var store: BrowserStore?

    private var tabs: [BrowserTab] {
        guard let store else { return [] }
        return store.spaces.flatMap { store.orderedTabs(in: $0.id) }
    }

    private var nsWindow: NSWindow? { NSApp.windows.first { $0.isVisible && $0.styleMask.contains(.fullSizeContentView) } }

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] { tabs }

    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        guard let tab = store?.selectedTab, store?.isPrivate == false else { return nil }
        return tab
    }

    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType { .normal }

    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState {
        guard let nsWindow else { return .normal }
        return nsWindow.isMiniaturized ? .minimized : nsWindow.styleMask.contains(.fullScreen) ? .fullscreen : .normal
    }

    func isPrivate(for context: WKWebExtensionContext) -> Bool { false }

    func frame(for context: WKWebExtensionContext) -> CGRect { nsWindow?.frame ?? .null }

    func screenFrame(for context: WKWebExtensionContext) -> CGRect { nsWindow?.screen?.frame ?? NSScreen.main?.frame ?? .null }

    func focus(for context: WKWebExtensionContext) async throws {
        NSApp.activate()
        nsWindow?.makeKeyAndOrderFront(nil)
    }

    func index(of tab: BrowserTab) -> Int { tabs.firstIndex { $0 === tab } ?? 0 }
}

// MARK: - Tabs, as extensions see them

extension BrowserTab: WKWebExtensionTab {
    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { store?.extensions.window }
    func indexInWindow(for context: WKWebExtensionContext) -> Int { store?.extensions.window.index(of: self) ?? 0 }
    func webView(for context: WKWebExtensionContext) -> WKWebView? { loadedWebView }
    func title(for context: WKWebExtensionContext) -> String? { displayTitle }
    func isPinned(for context: WKWebExtensionContext) -> Bool { isPinned }
    func url(for context: WKWebExtensionContext) -> URL? { url }
    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { !isLoading }
    func isSelected(for context: WKWebExtensionContext) -> Bool { store?.isSelected(self) ?? false }
    /// Clicking an extension's button counts as using it on this page ("activeTab").
    func shouldGrantPermissionsOnUserGesture(for context: WKWebExtensionContext) -> Bool { true }

    func setPinned(_ pinned: Bool, for context: WKWebExtensionContext) async throws {
        if pinned != isPinned { store?.togglePin(self) }
    }

    func activate(for context: WKWebExtensionContext) async throws { store?.select(self) }
    func close(for context: WKWebExtensionContext) async throws { store?.close(self) }
    func loadURL(_ url: URL, for context: WKWebExtensionContext) async throws { load(url) }
    func reload(fromOrigin: Bool, for context: WKWebExtensionContext) async throws {
        if fromOrigin { loadedWebView?.reloadFromOrigin() } else { loadedWebView?.reload() }
    }
    func goBack(for context: WKWebExtensionContext) async throws { goBack() }
    func goForward(for context: WKWebExtensionContext) async throws { goForward() }

    func duplicate(using configuration: WKWebExtension.TabConfiguration, for context: WKWebExtensionContext) async throws -> (any WKWebExtensionTab)? {
        store?.newTab(url: url, in: spaceID, after: self, select: configuration.shouldBeActive)
    }
}

// MARK: - Toolbar

/// The extensions' buttons in the address bar: icon, badge, and popup (or the action) on click. Ones hidden in
/// Settings are in a puzzle-piece menu after them.
struct ExtensionButtons: View {
    @Environment(BrowserStore.self) private var store

    var body: some View {
        let manager = store.extensions
        let _ = manager.actionsVersion
        let tab = store.selectedTab.flatMap { store.isPrivate($0.spaceID) ? nil : $0 }
        let loaded = manager.installed.filter { manager.contexts[$0.id] != nil }
        ForEach(loaded.filter(\.showsInToolbar)) { item in
            if let context = manager.contexts[item.id] {
                ExtensionButton(id: item.id, context: context, tab: tab)
            }
        }
        let hidden = loaded.filter { !$0.showsInToolbar }
        if !hidden.isEmpty {
            Menu {
                ForEach(hidden) { item in
                    if let context = manager.contexts[item.id] {
                        Button(context.webExtension.displayName ?? "Extension") { context.performAction(for: tab) }
                    }
                }
                Divider()
                Button("Manage Extensions…") { store.openSettings("extensions") }
            } label: {
                Image(systemName: "puzzlepiece.extension").font(.system(size: 13, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .tint(.primary)   // like the other toolbar icons, not the accent colour
            .fixedSize()
            .frame(width: 28, height: 26)
            .background(AnchorView(id: "menu"))
            .help("Extensions")
        }
    }
}

private struct ExtensionButton: View {
    @Environment(BrowserStore.self) private var store
    let id: String
    let context: WKWebExtensionContext
    let tab: BrowserTab?

    var body: some View {
        let action = context.action(for: tab)
        let name = action?.label.isEmpty == false ? action!.label : (context.webExtension.displayName ?? "Extension")
        Button { context.performAction(for: tab) } label: {
            Group {
                if let icon = action?.icon(for: CGSize(width: 16, height: 16)) ?? context.webExtension.actionIcon(for: CGSize(width: 16, height: 16)) {
                    Image(nsImage: icon).resizable().interpolation(.high).frame(width: 16, height: 16)
                } else {
                    Image(systemName: "puzzlepiece.extension").font(.system(size: 13, weight: .medium))
                }
            }
            .frame(width: 28, height: 26)
            .opacity(action?.isEnabled == false ? 0.4 : 1)
            .overlay(alignment: .bottomTrailing) {
                if let badge = action?.badgeText, !badge.isEmpty {
                    Text(badge)
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 3)
                        .frame(minWidth: 13, minHeight: 12)
                        .background(Color.accentColor, in: Capsule())
                        .offset(x: 1, y: 0)
                }
            }
        }
        .buttonStyle(StripButtonStyle())
        .background(AnchorView(id: id))
        .help(name)
        .contextMenu {
            if context.optionsPageURL != nil { Button("Options") { store.extensions.openOptions(for: id) } }
            Button("Hide from Toolbar") { store.extensions.setShowsInToolbar(false, for: id) }
            Button("Manage Extensions…") { store.openSettings("extensions") }
        }
    }
}

/// Registers a toolbar button's view, so the extension's popup can hang from it.
private struct AnchorView: NSViewRepresentable {
    @Environment(BrowserStore.self) private var store
    let id: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        store.extensions.anchors[id] = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) { store.extensions.anchors[id] = view }
}

/// "Add to Dew" on a Chrome Web Store extension page.
struct AddExtensionButton: View {
    @Environment(BrowserStore.self) private var store
    let storeID: String

    var body: some View {
        let manager = store.extensions
        let added = manager.isInstalled(storeID: storeID)
        Button { Task { await manager.installFromStore(storeID) } } label: {
            HStack(spacing: 5) {
                if manager.isInstalling {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: added ? "checkmark" : "plus")
                }
                Text(added ? "Added to Dew" : "Add to Dew")
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(added ? AnyShapeStyle(.secondary) : AnyShapeStyle(.white))
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(added ? AnyShapeStyle(.quaternary) : AnyShapeStyle(store.currentSpace.color), in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(added || manager.isInstalling)
        .help(added ? "This extension is in Dew (Settings → Extensions)" : "Install this extension in Dew")
    }
}

// MARK: - Settings

struct ExtensionsSettingsView: View {
    @Environment(BrowserStore.self) private var store

    var body: some View {
        let manager = store.extensions
        Form {
            Section {
                if manager.installed.isEmpty {
                    Text("No extensions yet.").foregroundStyle(.secondary)
                }
                ForEach(manager.installed) { item in
                    ExtensionRow(item: item)
                }
            } footer: {
                Text("Most Chrome extensions work in Dew. Open one in the Chrome Web Store and click Add to Dew in the address bar. Extensions don't run in private browsing.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Button("Open Chrome Web Store") { store.newTab(url: URL(string: "https://chromewebstore.google.com/category/extensions")!) }
                    Button("Add from Folder or ZIP…") { manager.installFromDisk() }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct ExtensionRow: View {
    @Environment(BrowserStore.self) private var store
    let item: InstalledExtension

    var body: some View {
        let manager = store.extensions
        let webExtension = manager.contexts[item.id]?.webExtension
        HStack(alignment: .top, spacing: 12) {
            Group {
                if let icon = webExtension?.icon(for: CGSize(width: 32, height: 32)) {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: "puzzlepiece.extension").font(.system(size: 20)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(webExtension?.displayName ?? (item.name.isEmpty ? "Extension" : item.name)).font(.headline)
                    if let version = webExtension?.displayVersion { Text(version).font(.caption).foregroundStyle(.secondary) }
                }
                if let about = webExtension?.displayDescription, !about.isEmpty {
                    Text(about).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
                if let problem = manager.problems[item.id] {
                    Label(problem, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                }
                HStack(spacing: 14) {
                    Toggle("Show in toolbar", isOn: Binding(get: { item.showsInToolbar },
                                                            set: { manager.setShowsInToolbar($0, for: item.id) }))
                        .toggleStyle(.checkbox)
                        .fixedSize()
                        .disabled(!item.isEnabled)
                    if manager.contexts[item.id]?.optionsPageURL != nil {
                        Button("Options") { manager.openOptions(for: item.id) }.buttonStyle(.link)
                    }
                    Button("Remove") { manager.remove(item.id) }.buttonStyle(.link)
                }
                .font(.callout)
                .controlSize(.small)
                .padding(.top, 2)
            }
            Spacer()
            Toggle("", isOn: Binding(get: { item.isEnabled }, set: { manager.setEnabled($0, for: item.id) }))
                .toggleStyle(.switch)
                .labelsHidden()
        }
        .padding(.vertical, 4)
    }
}
