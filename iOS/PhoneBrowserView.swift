import SwiftUI

struct PhoneBrowserView: View {
    @Environment(BrowserStore.self) private var store
    @State private var showingTabs = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        @Bindable var store = store
        let space = store.currentSpace
        // Only tint the status bar area when its text stays readable (light site in light mode, dark in dark).
        let siteColor = store.siteColor.flatMap { $0.colorScheme == colorScheme ? $0 : nil }

        // Compact width (Duo closed, iPhone): address bar at the bottom. Regular width (Duo open,
        // iPad): Dia-style toolbar and tab strip. Tabs own their web views, so folding or unfolding
        // keeps the page, scroll position and anything typed.
        GeometryReader { proxy in
            // iPhone Duo puts the status bar in a strip down the side: a wide side inset, little top inset.
            let insets = proxy.safeAreaInsets
            let hasSideStatusStrip = max(insets.leading, insets.trailing) >= 44 && insets.top < 20
            let useToolbar = switch store.addressBarPosition {
            case .top: true
            case .bottom: false
            case .automatic: sizeClass == .regular
            }
            // Debug: `-DewForceDuoLayout YES` shows the Duo layout on other devices (simulator testing).
            let isDuo = hasSideStatusStrip || UserDefaults.standard.bool(forKey: "DewForceDuoLayout")
            // Where the address editor's field goes: where the address bar is.
            let editorAtBottom = isDuo ? store.addressBarPosition == .bottom : !useToolbar
            let layout: BrowserLayout = isDuo ? .duo : useToolbar ? .toolbar : .bottomBar
            ZStack {
            if isDuo {
                // iPhone Duo (folded or open): menu icons down the right edge, address top or bottom.
                DuoBrowserView(showingTabs: $showingTabs)
            } else if useToolbar {
                ToolbarBrowserView(showingTabs: $showingTabs)
            } else {
                VStack(spacing: 0) {
                    ZStack {
                        if let tab = store.selectedTab, !store.isBlank(tab) {
                            WebContainer(tab: tab)
                        } else {
                            PhoneStartPage()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    BottomBar(showingTabs: $showingTabs)
                }
            }
            if let state = store.commandBar {
                AddressEditor(state: state, atBottom: editorAtBottom)
                    .id(state.id)
                    .transition(.opacity)
            }
            }
            .animation(.easeOut(duration: 0.15), value: store.commandBar?.id)
            .onAppear { store.activeLayout = layout }
            .onChange(of: layout) { store.activeLayout = layout }
        }
        // Fills whichever edge holds the status bar: the top on iPhone, the side strip on iPhone Duo.
        .background((siteColor?.color ?? space.color.opacity(store.isPrivate ? 0.6 : 0.12)).ignoresSafeArea()
            .animation(.easeInOut(duration: 0.25), value: siteColor))
        // Private browsing: dark chrome.
        .environment(\.colorScheme, store.isPrivate ? .dark : colorScheme)
        .tint(store.isPrivate ? Color.white : space.color)  // private's grey accent would look disabled
        // While the tab grid is up it presents the editor itself.
        .sheet(item: showingTabs ? .constant(nil) : $store.spaceEditor) { state in
            SpaceEditorView(state: state)
                .presentationDetents([.medium, .large])
                .environment(store)
        }
        .sheet(isPresented: showingTabs ? .constant(false) : $store.isManagingSpaces) {
            SettingsSheet().environment(store)
        }
        .sheet(isPresented: $store.showsWelcome, onDismiss: { store.finishWelcome() }) {
            WelcomeView().environment(store)
        }
        // Narrow screens (Duo folded, iPhone): Chat is a sheet, full height so the keyboard leaves room for the
        // conversation; drag it down to half. Wide screens show it as a panel beside the page instead.
        .sheet(isPresented: Binding(get: { store.isChatOpen && sizeClass == .compact && !showingTabs },
                                    set: { if !$0 && sizeClass == .compact { store.isChatOpen = false } })) {
            ChatSheet().environment(store)
        }
        .alert(store.pendingLogin?.isUpdate == true ? "Update saved password?" : "Save password?",
               isPresented: Binding(get: { store.pendingLogin != nil && store.pendingLogin?.tabID == store.selectedTab?.id },
                                    set: { if !$0 { store.pendingLogin = nil } })) {
            Button(store.pendingLogin?.isUpdate == true ? "Update" : "Save") { store.resolvePendingLogin(save: true) }
            Button("Never for This Site") { store.resolvePendingLogin(save: false, never: true) }
            Button("Not Now", role: .cancel) { store.resolvePendingLogin(save: false) }
        } message: {
            if let pending = store.pendingLogin {
                Text(pending.username.isEmpty ? pending.host : "\(pending.username) on \(pending.host)")
            }
        }
        .task {
            // Debug: `-DewShowTabs YES` opens the tab view at launch (device/simulator testing).
            if UserDefaults.standard.bool(forKey: "DewShowTabs") { showingTabs = true }
        }
        #if DEBUG
        // Debug: `-DewPreviewStartPage YES` shows the new tab page over everything (no tab is created).
        .overlay {
            if UserDefaults.standard.bool(forKey: "DewPreviewStartPage") {
                PhoneStartPage().background(Color(uiColor: .systemBackground)).ignoresSafeArea(edges: .bottom)
            }
        }
        // Debug: `-DewPreviewStylePicker YES` shows the space colour/icon picker sheet (device testing).
        .sheet(isPresented: .constant(UserDefaults.standard.bool(forKey: "DewPreviewStylePicker"))) {
            SpaceStylePicker(colorHex: .constant(space.colorHex), symbol: .constant(space.symbol))
                .presentationDetents([.height(300)])
                .presentationDragIndicator(.visible)
        }
        #endif
        .fullScreenCover(isPresented: $showingTabs) {
            TabGridView().environment(store)
        }
    }
}

private struct BottomBar: View {
    @Environment(BrowserStore.self) private var store
    @Binding var showingTabs: Bool
    @AppStorage(ButtonPlacement.bottom.defaultsKey) private var bottomButtons = ButtonPlacement.bottom.defaultValue

    var body: some View {
        let tab = store.selectedTab
        VStack(spacing: 8) {
            Button { store.showCommandBar(newTab: tab == nil) } label: {
                HStack(spacing: 6) {
                    if let tab {
                        FaviconView(url: tab.faviconURL, size: 14)
                        Text(URLInput.displayHost(tab.url) ?? tab.displayTitle).lineLimit(1)
                    } else {
                        Image(systemName: "magnifyingglass")
                        Text("Search or enter address").foregroundStyle(.secondary)
                    }
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity)
                .frame(height: 42)
                .background(store.isPrivate ? AnyShapeStyle(Color(white: 0.3)) : AnyShapeStyle(.background), in: Capsule())
                .overlay(alignment: .bottom) {
                    if let tab, tab.isLoading {
                        GeometryReader { proxy in
                            Capsule().fill(store.currentSpace.color)
                                .frame(width: proxy.size.width * max(tab.progress, 0.05), height: 2.5)
                                .frame(maxHeight: .infinity, alignment: .bottom)
                        }
                        .padding(.horizontal, 14)
                    }
                }
                .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
            }
            .buttonStyle(.plain)

            // Your choice of buttons (Settings → Appearance & Layout → Bottom Bar Buttons), spaced evenly.
            HStack {
                let buttons = SideButton.decode(bottomButtons)
                ForEach(Array(buttons.enumerated()), id: \.element) { index, button in
                    if index > 0 { Spacer() }
                    bottomButton(button, tab: tab)
                }
            }
            .font(.system(size: 18, weight: .medium))
            .padding(.horizontal, 8)
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .background(.bar)
        // Swipe sideways along the bottom bar to switch space.
        .simultaneousGesture(DragGesture(minimumDistance: 30).onEnded { value in
            guard abs(value.translation.width) > 80, abs(value.translation.height) < 50 else { return }
            withAnimation(.snappy) { store.selectAdjacentSpace(value.translation.width < 0 ? 1 : -1) }
        })
    }

    @ViewBuilder private func bottomButton(_ button: SideButton, tab: BrowserTab?) -> some View {
        switch button {
        case .back: barButton("chevron.left", enabled: tab?.canGoBack == true) { tab?.goBack() }
        case .forward: barButton("chevron.right", enabled: tab?.canGoForward == true) { tab?.goForward() }
        case .reload:
            barButton(tab?.isLoading == true ? "xmark" : "arrow.clockwise", enabled: !store.isBlank(tab)) { tab?.reload() }
        case .tabs:
            Button {
                Task {
                    await store.selectedTab?.captureThumbnail()
                    showingTabs = true
                }
            } label: {
                Text("\(store.orderedTabs.count)")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 22, height: 22)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(lineWidth: 1.8))
                    .frame(width: 44, height: 36)
            }
            .accessibilityLabel("Tabs")
        case .newTab: barButton("plus", enabled: true) { store.showCommandBar(newTab: true) }
        case .chat: barButton("sparkles", enabled: true) { store.isChatOpen = true }
        case .bookmark:
            let bookmarked = tab.map { store.isBookmarked($0) } ?? false
            barButton(bookmarked ? "star.fill" : "star", enabled: tab?.url != nil && !store.isPrivate) {
                if let tab { store.toggleBookmark(for: tab) }
            }
        case .share:
            if let url = tab?.url {
                ShareLink(item: url) { Image(systemName: "square.and.arrow.up").frame(width: 44, height: 36) }
            } else {
                barButton("square.and.arrow.up", enabled: false) {}
            }
        case .space: SpaceMenu()
        case .settings: barButton("gearshape", enabled: true) { store.openSettings() }
        case .more: MoreMenu()
        }
    }

    private func barButton(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 44, height: 36) }
            .disabled(!enabled)
    }
}

struct SpaceMenu: View {
    @Environment(BrowserStore.self) private var store

    var body: some View {
        Menu {
            ForEach(store.spaces) { space in
                Button {
                    store.selectSpace(space.id)
                } label: {
                    Label(space.name, systemImage: space.id == store.currentSpace.id ? "checkmark" : space.symbol)
                }
            }
            Divider()
            if store.isPrivate {
                Button("Leave Private Browsing", systemImage: "eye") { store.exitPrivate() }
                Button("Close All Private Tabs", systemImage: "xmark.square", role: .destructive) { store.closeAllPrivateTabs() }
            } else {
                Button(store.hasPrivateTabs ? "Private Browsing" : "New Private Tab", systemImage: "eye.slash") {
                    store.enterPrivate()
                    if store.isBlank(store.selectedTab) { store.showCommandBar(newTab: false) }
                }
            }
            Divider()
            Button("New Space…", systemImage: "plus") { store.beginNewSpace() }
            Button("Rename “\(store.currentSpace.name)”…", systemImage: "pencil") { store.beginEditing(store.currentSpace) }
            Button("Manage Spaces…", systemImage: "square.stack.3d.up") { store.openSettings("spaces") }
        } label: {
            SpaceBadge(space: store.currentSpace, size: 28).frame(width: 44, height: 36)
        }
    }
}

/// The ⋯ menu: page actions as a row of icons, then grouped commands, in a fixed order (iOS would
/// otherwise reverse it when the menu opens upwards from a bottom button). Kept short so it never needs
/// scrolling; "Set as Default Browser" and the rest of the options live in Settings.
struct MoreMenu: View {
    @Environment(BrowserStore.self) private var store
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        let tab = store.selectedTab
        Menu {
            if let tab, !store.isBlank(tab) {
                // Page actions, side by side.
                ControlGroup {
                    if let url = tab.url {
                        ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
                    }
                    if tab.url != nil && !store.isPrivate {
                        let bookmarked = store.isBookmarked(tab)
                        Button(bookmarked ? "Bookmarked" : "Bookmark", systemImage: bookmarked ? "star.fill" : "star") {
                            store.toggleBookmark(for: tab)
                        }
                    }
                    Button("Find", systemImage: "doc.text.magnifyingglass") {
                        tab.loadedWebView?.findInteraction?.presentFindNavigator(showingReplace: false)
                    }
                    Button(tab.isLoading ? "Stop" : "Reload", systemImage: tab.isLoading ? "xmark" : "arrow.clockwise") { tab.reload() }
                }
            }
            Section {
                Button("Chat", systemImage: "sparkles") { store.isChatOpen = true }
                Button("New Tab", systemImage: "plus") { store.showCommandBar(newTab: true) }
                Button("New Private Tab", systemImage: "eye.slash") {
                    store.enterPrivate()
                    store.newBlankTab()
                    store.showCommandBar(newTab: false)
                }
                if sizeClass == .regular {
                    if let tab = store.selectedTab, store.selectedSplit != nil {
                        Button("Separate Split View", systemImage: "rectangle.split.2x1.slash") { store.separateSplit(containing: tab) }
                    } else {
                        Button("New Split Tab", systemImage: "rectangle.split.2x1") {
                            store.newSplitTab()
                            store.showCommandBar(newTab: false)
                        }
                    }
                }
            }
            Section {
                if let tab {
                    Button(tab.isPinned ? "Unpin Tab" : "Pin Tab", systemImage: tab.isPinned ? "pin.slash" : "pin") { store.togglePin(tab) }
                    if let host = tab.url?.host() {
                        let logins = store.passwords.logins(forHost: host, in: tab.spaceID)
                        if !logins.isEmpty {
                            Menu("Fill Password", systemImage: "key") {
                                ForEach(logins) { login in
                                    Button(login.username.isEmpty ? "Password" : login.username) { Task { await store.fill(login, in: tab) } }
                                }
                            }
                        }
                    }
                }
                Button("Reopen Closed Tab", systemImage: "arrow.uturn.backward") { store.reopenClosedTab() }
                if !store.downloads.items.isEmpty {
                    Button("Downloads", systemImage: "arrow.down.circle") {
                        let path = DownloadManager.directory.path(percentEncoded: true)
                        if let url = URL(string: "shareddocuments://" + path) { UIApplication.shared.open(url) }
                    }
                }
            }
            Section {
                Toggle("Block Ads", systemImage: "shield.lefthalf.filled", isOn: Bindable(store.contentBlocker).isEnabled)
                Button("Settings…", systemImage: "gearshape") { store.openSettings() }
            }
        } label: {
            Image(systemName: "ellipsis.circle").frame(width: 44, height: 36)
        }
        .menuOrder(.fixed)
    }
}

/// The new tab page, matching the Mac: the Dew drop, a note in private browsing, and the space's
/// bookmarks as tiles. Recent pages and suggestions appear when you tap the address bar.
struct PhoneStartPage: View {
    @Environment(BrowserStore.self) private var store

    var body: some View {
        let bookmarks = store.currentBookmarks
        ScrollView {
            VStack(spacing: 0) {
                BouncingDewMark(size: 52, style: store.appIcon.markStyle)
                    .padding(.top, 56)
                    .padding(.bottom, 22)
                if store.isPrivate {
                    Label("Private browsing: pages aren't saved to history, and cookies are deleted when you close your last private tab.",
                          systemImage: "eye.slash")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)
                        .padding(.bottom, 18)
                }
                if !bookmarks.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 72, maximum: 84), spacing: 14)], spacing: 16) {
                        ForEach(bookmarks) { bookmark in
                            Button { store.open(bookmark) } label: {
                                VStack(spacing: 7) {
                                    FaviconView(url: bookmark.faviconURL, page: bookmark.url, size: 24)
                                        .frame(width: 52, height: 52)
                                        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                                        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(.separator.opacity(0.6)))
                                    Text(bookmark.title).font(.caption).lineLimit(1).foregroundStyle(.secondary)
                                }
                                .frame(width: 72)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Open in New Tab", systemImage: "plus.square.on.square") { store.open(bookmark, inNewTab: true) }
                                Button("Delete Bookmark", systemImage: "trash", role: .destructive) { store.removeBookmark(bookmark) }
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }
}

struct SettingsSheet: View {
    @Environment(BrowserStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    /// Shown as a tab (iPhone Duo) rather than a sheet: no Done button.
    var embedded = false
    @State private var path: [String] = []

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    row("general", "General", "gearshape.fill", .gray)
                    row("appearance", "Appearance & Layout", "paintbrush.fill", .blue)
                }
                Section {
                    row("spaces", "Spaces", "square.stack.3d.up.fill", .indigo)
                    row("passwords", "Passwords", "key.fill", .orange)
                    row("privacy", "Privacy & Ad Blocking", "hand.raised.fill", .green)
                }
                Section {
                    row("ai", "AI Chat", "sparkles", .pink)
                }
                Section {
                    Button("Welcome to Dew") {
                        dismiss()
                        // Once Settings has closed, so the welcome sheet can open.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { store.showsWelcome = true }
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: String.self) { page in
                switch page {
                case "spaces": SpacesListView().navigationTitle("Spaces").toolbar { EditButton() }
                case "passwords": PasswordsSettingsView().navigationTitle("Passwords")
                case "privacy": PrivacySettingsView().navigationTitle("Privacy & Ad Blocking")
                case "ai": AISettingsView().navigationTitle("AI Chat")
                case "appearance": AppearanceSettingsView().navigationTitle("Appearance & Layout")
                case "sidebuttons": SideButtonsSettingsView()
                default: GeneralSettingsView().navigationTitle("General")
                }
            }
            .toolbar {
                if !embedded {
                    ToolbarItem(placement: .primaryAction) { Button("Done", systemImage: "checkmark") { dismiss() } }
                }
            }
        }
        .onAppear {
            // Opened at a page (e.g. "Manage Spaces…"): go straight there, once.
            if let page = store.settingsPage {
                path = page == "sidebuttons" ? ["appearance", page] : [page]
                store.settingsPage = nil
            }
        }
    }

    /// A settings row with a coloured icon tile, like the iPhone's Settings app.
    private func row(_ page: String, _ title: String, _ symbol: String, _ color: Color) -> some View {
        NavigationLink(value: page) {
            Label {
                Text(title)
            } icon: {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 29, height: 29)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(color.gradient))
            }
        }
    }
}

/// Chat as a sheet on narrow screens. Its own navigation stack lets setup open AI settings inside it.
private struct ChatSheet: View {
    @State private var detent: PresentationDetent = .large

    var body: some View {
        NavigationStack {
            ChatPanelView().toolbar(.hidden, for: .navigationBar)
        }
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
        .presentationContentInteraction(.scrolls)
    }
}

/// Chat beside the page on iPad (toolbar layout): a pane like split view's, the full height of the page.
struct ChatSidePanel: View {
    let width: CGFloat

    var body: some View {
        NavigationStack {
            ChatPanelView().toolbar(.hidden, for: .navigationBar)
        }
        .frame(width: width)
        .background(Color(uiColor: .systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
    }
}
