import SwiftUI

@main
struct DewMacApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var store = BrowserStore()

    var body: some Scene {
        Window("Dew", id: "browser") {
            MacBrowserView()
                .environment(store)
                .frame(minWidth: 640, minHeight: 420)
                .onOpenURL { store.newTab(url: $0) }
                .modifier(OpenSettingsOnLaunch())
                .onAppear { appDelegate.store = store }
                .modifier(SettingsOpener(store: store))
                .modifier(HandoffModifier(store: store))
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    store.saveNow()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 820)
        .commands { BrowserCommands(store: store) }

        Window("History", id: "history") {
            HistoryWindow().environment(store)
        }
        .defaultSize(width: 760, height: 560)
        .keyboardShortcut("y")

        Settings {
            SettingsView().environment(store)
        }
    }
}

/// Settings, laid out like Dia's: a fixed 778 × 600 window with a sidebar of outline icons, so
/// switching sections never resizes it.
struct SettingsView: View {
    @AppStorage("settingsTab") private var selection = "general"

    private struct Section: Identifiable {
        let id: String
        let title: String
        let symbol: String
    }

    private let sections = [
        Section(id: "general", title: "General", symbol: "gearshape"),
        Section(id: "appearance", title: "Appearance", symbol: "paintbrush"),
        Section(id: "spaces", title: "Spaces", symbol: "person.2"),
        Section(id: "passwords", title: "Passwords", symbol: "key"),
        Section(id: "privacy", title: "Privacy", symbol: "hand.raised"),
        Section(id: "ai", title: "AI Chat", symbol: "sparkles"),
        Section(id: "shortcuts", title: "Shortcuts", symbol: "keyboard"),
    ]

    var body: some View {
        NavigationSplitView {
            List(sections, selection: Binding(get: { Optional(selection) }, set: { if let value = $0 { selection = value } })) { section in
                Label {
                    Text(section.title)
                } icon: {
                    // Monochrome outline icons, like Dia (white on the blue selection).
                    Image(systemName: section.symbol)
                        .foregroundStyle(selection == section.id ? Color.white : Color.secondary)
                }
                .tag(section.id)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(196)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            Group {
                switch selection {
                case "spaces": SpacesListView()
                case "passwords": PasswordsSettingsView()
                case "privacy": PrivacySettingsView()
                case "ai": AISettingsView()
                case "appearance": AppearanceSettingsView()
                case "shortcuts": ShortcutsSettingsView()
                default: GeneralSettingsView()
                }
            }
            .navigationTitle(sections.first { $0.id == selection }?.title ?? "General")
        }
        .frame(width: 778, height: 600)
    }
}

/// Read-only list of keyboard shortcuts, including each space's.
private struct ShortcutsSettingsView: View {
    @Environment(BrowserStore.self) private var store

    private let groups: [(String, [(String, String)])] = [
        ("Tabs", [("New tab", "⌘T"), ("Close tab", "⌘W"), ("Reopen closed tab", "⇧⌘T"), ("Next / previous tab", "⌃⇥  ⌃⇧⇥"),
                  ("Go to tab 1–8 / last tab", "⌘1–⌘8  ⌘9"), ("Pin / unpin tab", "⌥⌘P"), ("New split tab", "⌥⌘T"), ("Close tab", "Middle-click")]),
        ("Pages", [("Open location", "⌘L"), ("Back / forward", "⌘[  ⌘]"), ("Reload", "⌘R"), ("Zoom in / out / actual size", "⌘+  ⌘−  ⌘0"),
                   ("Copy link", "⇧⌘C"), ("Open link in background tab", "⌘-click")]),
        ("Bookmarks & history", [("Bookmark this page", "⌘D"), ("Show bookmarks bar", "⇧⌘B"), ("Show all history", "⌘Y")]),
        ("Spaces", [("Next / previous space", "⌃⌥→  ⌃⌥←"), ("Switch space with the mouse", "Side buttons over tabs"), ("New space", "⌥⌘N"), ("New private tab", "⇧⌘N")]),
    ]

    var body: some View {
        Form {
            ForEach(groups, id: \.0) { title, rows in
                SwiftUI.Section(title) {
                    ForEach(rows, id: \.0) { name, keys in
                        LabeledContent(name) { Text(keys).monospaced().foregroundStyle(.secondary) }
                    }
                    if title == "Spaces" {
                        ForEach(Array(store.spaces.prefix(9).enumerated()), id: \.element.id) { index, space in
                            LabeledContent("Switch to “\(space.name)”") { Text("⌃\(index + 1)").monospaced().foregroundStyle(.secondary) }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var store: BrowserStore?
    private var hasReplied = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // SwiftUI's own "Close" (⌘W) would close the whole window; ⌘W closes the tab instead.
        DispatchQueue.main.async {
            guard let fileMenu = NSApp.mainMenu?.item(withTitle: "File")?.submenu else { return }
            for item in fileMenu.items where item.title == "Close" || item.title == "Close All" {
                fileMenu.removeItem(item)
            }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard let store else { return }
        Task { await store.runAutoClear(.periodic) }
        Task { await store.cloudSync.refresh() }
        store.defaultBrowser.refresh()
    }

    /// Spaces set to "clear when Dew quits" are cleared before the app exits (with a safety timeout).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store, store.needsClearOnQuit else { return .terminateNow }
        hasReplied = false
        Task { @MainActor in
            await store.runAutoClear(.quit)
            self.reply(sender)
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            self.reply(sender)
        }
        return .terminateLater
    }

    @MainActor private func reply(_ sender: NSApplication) {
        guard !hasReplied else { return }
        hasReplied = true
        sender.reply(toApplicationShouldTerminate: true)
    }
}

struct BrowserCommands: Commands {
    let store: BrowserStore

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            MenuItem("New Tab", systemImage: "plus.square.on.square") { store.newBlankTab() }
                .keyboardShortcut("t")
            MenuItem("New Private Tab", systemImage: "eye.slash") {
                store.enterPrivate()
                store.newBlankTab()
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            MenuItem("New Space…", systemImage: "rectangle.stack.badge.plus") { store.beginNewSpace() }
                .keyboardShortcut("n", modifiers: [.command, .option])
            Divider()
            MenuItem("Open Location…", systemImage: "link") { store.focusAddress() }
                .keyboardShortcut("l")
            MenuItem("Close Tab", systemImage: "xmark.square") { store.closeSelectedTab() }
                .keyboardShortcut("w")
            MenuItem("Reopen Closed Tab", systemImage: "arrow.uturn.backward") { store.reopenClosedTab() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
            Divider()
            MenuItem("Import from Dia…", systemImage: "square.and.arrow.down") { store.isImporting = true }
        }

        // Removes SwiftUI's Close / Close All (⌘W closes the tab; closing the window isn't needed).
        CommandGroup(replacing: .saveItem) {}

        CommandGroup(after: .toolbar) {
            MenuItem("Reload Page", systemImage: "arrow.clockwise") { store.selectedTab?.loadedWebView?.reload() }
                .keyboardShortcut("r")
            Divider()
            MenuItem("Zoom In", systemImage: "plus.magnifyingglass") { zoom(by: 0.1) }.keyboardShortcut("+")
            MenuItem("Zoom Out", systemImage: "minus.magnifyingglass") { zoom(by: -0.1) }.keyboardShortcut("-")
            MenuItem("Actual Size", systemImage: "1.magnifyingglass") { store.selectedTab?.setZoom(nil) }.keyboardShortcut("0")
            Divider()
            MenuItem(store.isChatOpen ? "Hide Chat" : "Show Chat", systemImage: "sparkles") { store.isChatOpen.toggle() }
                .keyboardShortcut("e")
            MenuItem(store.tabsInSidebar ? "Show Tabs at the Top" : "Show Tabs in Sidebar", systemImage: "sidebar.left") {
                withAnimation(.snappy(duration: 0.25)) { store.tabsInSidebar.toggle() }
            }
            .keyboardShortcut("s")
            MenuItem(store.autoHideTabs ? "Always Show Tabs" : "Auto-hide Tabs", systemImage: "rectangle.dashed") {
                withAnimation(.snappy(duration: 0.25)) { store.autoHideTabs.toggle() }
            }
            .keyboardShortcut("s", modifiers: [.command, .option])
            Divider()
            MenuItem(store.matchSiteColor ? "Stop Matching Website Colour" : "Match Toolbar to Website Colour", systemImage: "paintpalette") {
                store.matchSiteColor.toggle()
            }
            Divider()
        }

        CommandMenu("Bookmarks") {
            MenuItem(store.isBookmarked(store.selectedTab) ? "Remove Bookmark" : "Bookmark This Page",
                   systemImage: store.isBookmarked(store.selectedTab) ? "star.slash" : "star") {
                store.toggleBookmark(for: store.selectedTab)
            }
            .keyboardShortcut("d")
            .disabled(store.selectedTab?.url == nil)
            MenuItem(store.showBookmarksBar ? "Hide Bookmarks Bar" : "Show Bookmarks Bar", systemImage: "menubar.rectangle") {
                store.showBookmarksBar.toggle()
            }
            .keyboardShortcut("b", modifiers: [.command, .shift])
            MenuItem(store.bookmarksIconsOnly ? "Show Bookmark Names" : "Show Bookmark Icons Only",
                   systemImage: store.bookmarksIconsOnly ? "textformat" : "square.grid.3x1.below.line.grid.1x2") {
                store.bookmarksIconsOnly.toggle()
            }
            if !store.currentBookmarks.isEmpty {
                Divider()
                ForEach(store.currentBookmarks) { bookmark in
                    Button(bookmark.title) { store.open(bookmark) }
                }
            }
        }

        CommandMenu("History") {
            MenuItem("Back", systemImage: "chevron.backward") { store.selectedTab?.goBack() }.keyboardShortcut("[")
            MenuItem("Forward", systemImage: "chevron.forward") { store.selectedTab?.goForward() }.keyboardShortcut("]")
            Divider()
            let closed = store.recentlyClosed
            Menu("Recently Closed", systemImage: "clock.arrow.circlepath") {
                ForEach(closed.prefix(15), id: \.id) { record in
                    Button(record.title.isEmpty ? (URLInput.displayHost(record.url) ?? "Tab") : record.title) { store.reopen(record) }
                }
            }
            .disabled(closed.isEmpty)
            Divider()
            ForEach(store.history(in: store.selectedSpaceID, limit: 10)) { entry in
                Button(entry.title.isEmpty ? entry.url.absoluteString : entry.title) { store.open(entry.url, inNewTab: true) }
            }
        }

        CommandMenu("Tabs") {
            MenuItem("Show Next Tab", systemImage: "arrow.right.square") { store.selectAdjacentTab(1) }.keyboardShortcut(.tab, modifiers: .control)
            MenuItem("Show Previous Tab", systemImage: "arrow.left.square") { store.selectAdjacentTab(-1) }.keyboardShortcut(.tab, modifiers: [.control, .shift])
            Divider()
            MenuItem(store.selectedTab?.isPinned == true ? "Unpin Tab" : "Pin Tab",
                   systemImage: store.selectedTab?.isPinned == true ? "pin.slash" : "pin") {
                if let tab = store.selectedTab { store.togglePin(tab) }
            }
            .keyboardShortcut("p", modifiers: [.command, .option])
            MenuItem("New Split Tab", systemImage: "rectangle.split.2x1") { store.newSplitTab() }
                .keyboardShortcut("t", modifiers: [.command, .option])
            MenuItem("Separate Split View", systemImage: "rectangle.split.2x1.slash") {
                if let tab = store.selectedTab { store.separateSplit(containing: tab) }
            }
            .disabled(store.selectedSplit == nil)
            Divider()
            MenuItem("Duplicate Tab", systemImage: "plus.square.on.square") { if let tab = store.selectedTab { store.duplicate(tab) } }
            MenuItem("Copy Link", systemImage: "doc.on.doc") { copySelectedURL() }.keyboardShortcut("c", modifiers: [.command, .shift])
            Divider()
            ForEach(1...9, id: \.self) { number in
                Button(number == 9 ? "Last Tab" : "Tab \(number)") { store.selectTab(number: number) }
                    .keyboardShortcut(KeyEquivalent(Character("\(number)")), modifiers: .command)
            }
        }

        CommandMenu("Spaces") {
            ForEach(Array(store.spaces.enumerated()), id: \.element.id) { index, space in
                Button(space.name, systemImage: space.symbol) { store.selectSpace(space.id) }
                    .keyboardShortcut(KeyEquivalent(Character("\(min(index + 1, 9))")), modifiers: .control)
            }
            Divider()
            MenuItem("Next Space", systemImage: "arrow.right.circle") { store.selectAdjacentSpace(1) }
                .keyboardShortcut(.rightArrow, modifiers: [.control, .option])
            MenuItem("Previous Space", systemImage: "arrow.left.circle") { store.selectAdjacentSpace(-1) }
                .keyboardShortcut(.leftArrow, modifiers: [.control, .option])
            Divider()
            MenuItem("Rename “\(store.currentSpace.name)”…", systemImage: "pencil") { store.beginEditing(store.currentSpace) }
            MenuItem("New Space…", systemImage: "rectangle.stack.badge.plus") { store.beginNewSpace() }
            SettingsLink { Label("Manage Spaces…", systemImage: "gearshape") }
            Divider()
            MenuItem("Clear History for “\(store.currentSpace.name)”…", systemImage: "clock.badge.xmark") {
                let space = store.currentSpace
                if confirm("Clear history for “\(space.name)”?", detail: "Other spaces aren't affected.", action: "Clear History") {
                    store.clearHistory(for: space.id)
                }
            }
            MenuItem("Clear Cookies for “\(store.currentSpace.name)”…", systemImage: "trash") {
                let space = store.currentSpace
                if confirm("Clear cookies and site data for “\(space.name)”?",
                           detail: "You'll be signed out of every site in this space. Other spaces aren't affected.",
                           action: "Clear Cookies") {
                    Task { await store.clearWebsiteData(for: space.id) }
                }
            }
        }

        // Shown as actions (like Safari's "Hide Bookmarks Bar") so they keep their icons; a toggle's
        // checkmark would take the icon's place in the menu.
        CommandGroup(replacing: .help) {
            MenuItem("Welcome to Dew", systemImage: "hand.wave") { store.showsWelcome = true }
        }

        CommandGroup(before: .systemServices) {
            if store.defaultBrowser.isDefault == false {
                MenuItem("Set Dew as Default Browser…", systemImage: "globe") { store.defaultBrowser.makeDefault() }
            }
            let blocker = store.contentBlocker
            Button {
                blocker.isEnabled.toggle()
            } label: {
                Label(blocker.isEnabled ? "Turn Off Ad Blocking" : "Turn On Ad Blocking",
                      systemImage: blocker.isEnabled ? "shield.slash" : "shield.lefthalf.filled")
                    .labelStyle(.titleAndIcon)
            }
            Divider()
        }
    }

    private func confirm(_ message: String, detail: String, action: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: action).hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func zoom(by delta: CGFloat) {
        guard let tab = store.selectedTab, let webView = tab.loadedWebView else { return }
        tab.setZoom(webView.pageZoom + delta)
    }

    private func copySelectedURL() {
        guard let url = store.selectedTab?.url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }
}

/// `-DewOpenSettings YES` opens Settings at launch (handy for screenshots/UI work).
private struct OpenSettingsOnLaunch: ViewModifier {
    @Environment(\.openSettings) private var openSettings

    func body(content: Content) -> some View {
        content.task {
            if UserDefaults.standard.bool(forKey: "DewOpenSettings") { openSettings() }
        }
    }
}

/// Lets non-view code (e.g. "Manage Passwords…" in a page's login dropdown) open Settings at a tab.
private struct SettingsOpener: ViewModifier {
    let store: BrowserStore
    @Environment(\.openSettings) private var openSettings

    func body(content: Content) -> some View {
        content.onAppear {
            store.openSettingsTab = { tab in
                UserDefaults.standard.set(tab, forKey: "settingsTab")
                openSettings()
            }
        }
    }
}

/// A menu-bar item that keeps its icon (SwiftUI drops Button icons in menu-bar menus unless the
/// label asks for title and icon).
struct MenuItem: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    init(_ title: String, systemImage: String, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage).labelStyle(.titleAndIcon)
        }
    }
}
