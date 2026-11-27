import SwiftUI
import UniformTypeIdentifiers

let cardColor = Color(nsColor: .textBackgroundColor)
let stripHeight: CGFloat = 42
/// Height of tabs, the space capsule and strip buttons; they're centred on the window buttons.
let stripItemHeight: CGFloat = 30

struct MacBrowserView: View {
    @Environment(BrowserStore.self) private var store
    @Environment(\.colorScheme) private var colorScheme
    /// The Chat panel's width, set by dragging its left edge (double-click resets it).
    @AppStorage("chatPanelWidth") private var chatWidth = ChatResizeHandle.defaultWidth

    var body: some View {
        @Bindable var store = store
        let space = store.currentSpace

        // Docked tabs take their own space; auto-hidden ones slide in over the page from the edge.
        let docked = !store.autoHideTabs
        HStack(spacing: 0) {
        if docked && store.tabsInSidebar { TabSidebar() }
        VStack(spacing: 0) {
            if docked && !store.tabsInSidebar {
                TabStrip()
                    .zIndex(1)
            }
            HStack(spacing: 6) {
                VStack(spacing: 0) {
                    VStack(spacing: 0) {
                        // Tabs hidden: 30 pt tall from 6 pt down, centred on the window buttons' line (21 pt), and
                        // starting after them.
                        NavigationBar(tab: store.selectedTab, height: docked ? 38 : 30)
                            .padding(.leading, docked ? 0 : 72)
                        if store.showBookmarksBar && !store.currentBookmarks.isEmpty {
                            BookmarksBar()
                        }
                    }
                    .siteColored(store.siteColor)
                    if let pending = store.pendingLogin, pending.tabID == store.selectedTab?.id {
                        SaveLoginBar(pending: pending)
                        Divider().opacity(0.5)
                    }
                    if store.siteColor == nil {
                        Divider().opacity(0.5)
                    }
                    ZStack {
                        if let selected = store.selectedSplit {
                            SplitContentView(split: selected.split, tabs: selected.tabs) { tab in
                                if tab.isInternalPage { HistoryPage(tab: tab) } else { StartPage() }
                            }
                        } else if let tab = store.selectedTab, tab.isInternalPage {
                            HistoryPage(tab: tab)
                        } else if let tab = store.selectedTab, !store.isBlank(tab) {
                            WebContainer(tab: tab)
                        } else {
                            StartPage()
                        }
                    }
                }
                .background(cardColor)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .shadow(color: .black.opacity(0.12), radius: 1, y: 0.5)
                if store.isChatOpen {
                    ChatPanelView()
                        .frame(width: chatWidth)
                        .overlay(alignment: .leading) { ChatResizeHandle(width: $chatWidth).offset(x: -6) }
                        .background(cardColor)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .shadow(color: .black.opacity(0.12), radius: 1, y: 0.5)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.18), value: store.isChatOpen)
            // Tabs hidden or in the sidebar: an even 6 pt rim all round, so the card's corners follow the window's.
            .padding(.top, !docked || store.tabsInSidebar ? 6 : 0)
            .padding(.leading, docked && store.tabsInSidebar ? 0 : 6)
            .padding([.trailing, .bottom], 6)
        }
        }
        .overlay(alignment: store.tabsInSidebar ? .leading : .top) {
            if !docked { AutoHidingTabs() }
        }
        .animation(.snappy(duration: 0.25), value: store.autoHideTabs)
        .background {
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                space.color.opacity(0.22)
            }
            .animation(.easeInOut(duration: 0.25), value: space.colorHex)
        }
        .ignoresSafeArea()
        .overlay {
            if let state = store.commandBar {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.12)
                        .ignoresSafeArea()
                        .onTapGesture { store.commandBar = nil }
                    CommandBarView(initialText: state.text, opensInNewTab: state.opensInNewTab) { store.commandBar = nil }
                        .id(state.id)
                        .frame(width: 640)
                        .background(store.isPrivate ? AnyShapeStyle(Color(white: 0.3)) : AnyShapeStyle(.regularMaterial),
                                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.separator))
                        .shadow(color: .black.opacity(0.25), radius: 30, y: 12)
                        .padding(.top, 110)
                }
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: store.commandBar?.id)
        .tint(space.color)
        .sheet(item: $store.spaceEditor) { SpaceEditorView(state: $0) }
        .sheet(isPresented: $store.isImporting) { ImportView() }
        .sheet(isPresented: $store.showsWelcome, onDismiss: { store.finishWelcome() }) { WelcomeView() }
        // Private browsing: dark chrome, like Safari's private windows.
        .environment(\.colorScheme, store.isPrivate ? .dark : colorScheme)
        // The window buttons stay on the tabs' centre line in every layout. With the tabs hidden they sit in the
        // page card's corner (the address bar is shortened to share that line), as far in from its edge as below its top.
        .background(TrafficLightAligner(centerY: stripItemCenterY, shiftX: store.autoHideTabs ? 5 : 0))
        .onAppear {
            store.applyAppearance()
            store.applyAppIcon()
            MiddleClickHandler.install(store: store)
            // Demo (screenshots): a 1440 × 900 window, a size the Mac App Store accepts.
            if BrowserStore.isDemo {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    guard let window = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) }) else { return }
                    window.setContentSize(NSSize(width: 1440, height: 900))
                    // On the main display (where test input reaches it), centred.
                    if let screen = NSScreen.screens.first?.visibleFrame {
                        window.setFrameOrigin(NSPoint(x: screen.midX - window.frame.width / 2, y: screen.midY - window.frame.height / 2))
                    }
                }
            }
        }
    }
}

/// Vertical centre of the space pill and tabs, measured from the top of the window.
let stripItemCenterY: CGFloat = 21

/// Moves the close/minimise/zoom buttons down so they sit on the same line as the space pill and
/// tabs, like Dia. AppKit re-lays out the title bar on resize, so the position is re-applied then.
private struct TrafficLightAligner: NSViewRepresentable {
    let centerY: CGFloat
    /// Extra distance from the left, on top of where macOS puts the buttons.
    var shiftX: CGFloat = 0

    func makeNSView(context: Context) -> AlignerView {
        let view = AlignerView()
        view.centerY = centerY
        view.shiftX = shiftX
        return view
    }

    func updateNSView(_ view: AlignerView, context: Context) {
        view.centerY = centerY
        view.shiftX = shiftX
        view.align()
    }

    final class AlignerView: NSView {
        var centerY: CGFloat = 19
        var shiftX: CGFloat = 0
        /// Each button's own x position, so the shift is applied from there rather than adding up.
        private var baseX: [NSWindow.ButtonType: CGFloat] = [:]
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            let names: [Notification.Name] = [NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification,
                                              NSWindow.didExitFullScreenNotification, NSWindow.didBecomeKeyNotification,
                                              NSWindow.didResignKeyNotification, NSWindow.didChangeScreenNotification]
            for name in names {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.align() }
                })
            }
            DispatchQueue.main.async { [weak self] in self?.align() }
        }

        func align() {
            guard let window, !window.styleMask.contains(.fullScreen) else { return }
            for type: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
                guard let button = window.standardWindowButton(type), let container = button.superview else { continue }
                let height = button.frame.height
                let y = container.isFlipped ? centerY - height / 2 : container.bounds.height - centerY - height / 2
                let base = baseX[type] ?? button.frame.origin.x
                baseX[type] = base
                let x = base + shiftX
                if abs(button.frame.origin.y - y) > 0.5 || abs(button.frame.origin.x - x) > 0.5 {
                    button.setFrameOrigin(NSPoint(x: x, y: y))
                }
            }
        }
    }
}

// MARK: - Tab strip

struct TabStrip: View {
    @Environment(BrowserStore.self) private var store

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Color.clear.frame(width: store.autoHideTabs ? 75 : 70, height: 1) // traffic lights (nudged in when auto-hiding)
            SpaceCapsule()
            TabRow()
            TabListMenu()
        }
        .padding(.top, stripItemCenterY - stripItemHeight / 2)
        .padding(.trailing, 10)
        .frame(height: stripHeight, alignment: .top)
        .onHover { store.isPointerInTabStrip = $0 }
        .background { WindowDragArea() }
    }
}

/// Dia-style capsule: the current space's name (in its colour) followed by its pinned tabs.
/// Clicking the name lists every space with its keyboard shortcut.
/// The space menu: switch space, private browsing, next/previous, rename, new and manage spaces (with their
/// shortcuts). Used by the space pill in the tab strip and the space header in the sidebar.
struct SpaceMenuContent: View {
    @Environment(BrowserStore.self) private var store

    var body: some View {
        let space = store.currentSpace
        Section("Spaces") {
            ForEach(Array(store.spaces.enumerated()), id: \.element.id) { index, item in
                Toggle(isOn: Binding(get: { item.id == store.selectedSpaceID },
                                     set: { _ in store.selectSpace(item.id) })) {
                    Label(item.name, systemImage: item.symbol)
                }
                .keyboardShortcut(index < 9 ? KeyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .control) : nil)
            }
        }
        Divider()
        if store.isPrivate {
            Button("Leave Private Browsing") { store.exitPrivate() }
            Button("Close All Private Tabs") { store.closeAllPrivateTabs() }
        } else {
            Button("New Private Tab") { store.enterPrivate(); store.newBlankTab() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
        }
        Divider()
        Button("Next Space") { store.selectAdjacentSpace(1) }
            .keyboardShortcut(.rightArrow, modifiers: [.control, .option])
        Button("Previous Space") { store.selectAdjacentSpace(-1) }
            .keyboardShortcut(.leftArrow, modifiers: [.control, .option])
        Divider()
        Button("Rename “\(space.name)”…") { store.beginEditing(space) }
        Button("New Space…") { store.beginNewSpace() }
            .keyboardShortcut("n", modifiers: [.command, .option])
        SettingsLink { Text("Manage Spaces…") }
    }
}

private struct SpaceCapsule: View {
    @Environment(BrowserStore.self) private var store

    var body: some View {
        let space = store.currentSpace
        let pinned = store.pinnedTabs
        HStack(spacing: 0) {
            if store.isPrivate {
                Image(systemName: "eye.slash")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(white: 0.92))
                    .padding(.leading, 10)
            }
            Menu {
                SpaceMenuContent()
            } label: {
                // Plain text: AppKit dims icons/labels drawn inside menu buttons.
                Text(space.name)
                    .font(.system(size: 13, weight: store.isPrivate ? .semibold : .medium))
                    .foregroundStyle(store.isPrivate ? Color(white: 0.92) : space.color)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .padding(.leading, store.isPrivate ? 4 : 11)
            .padding(.trailing, 11)
            .frame(height: stripItemHeight)
            .help("Switch space")

            ForEach(pinned) { tab in
                let selected = store.isSelected(tab)
                FaviconView(url: tab.faviconURL, page: tab.url, size: 16)
                    .frame(width: 32, height: stripItemHeight - 6)
                    .background(selected ? store.siteColor?.color ?? cardColor : .clear,
                                in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .contentShape(Rectangle())
                    .onTapGesture { store.select(tab) }
                    .help(tab.displayTitle)
                    .contextMenu { TabMenu(tab: tab) }
                    .tabDragAndDrop(tab)
            }
        }
        .padding(.trailing, pinned.isEmpty ? 0 : 3)
        .frame(height: stripItemHeight)
        // Two-finger swipe sideways over the pill switches space (handled in MiddleClickHandler).
        .onHover { store.isPointerOnSpacePill = $0 }
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(.primary.opacity(0.13), lineWidth: 1))
    }
}

/// The ⌄ at the far right, like Dia's: search, open tabs, recently closed and history.
private struct TabListMenu: View {
    @State private var isShowing = false

    var body: some View {
        Button { isShowing.toggle() } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 12, weight: .medium))
                .frame(width: 28, height: stripItemHeight - 4)
        }
        .buttonStyle(StripButtonStyle())
        .frame(height: stripItemHeight)
        .help("Tabs and history")
        .popover(isPresented: $isShowing, arrowEdge: .bottom) {
            HistoryPopover { isShowing = false }
        }
    }
}

/// Lays tabs out like Dia: equal widths up to a maximum; as tabs are added the others shrink
/// (down to favicon-only) while the selected tab stays wide enough to read. Scrolls only when
/// even favicon-only tabs no longer fit.
private struct TabRow: View {
    @Environment(BrowserStore.self) private var store
    /// New-tab button plus an empty strip on the right so the window can always be dragged.
    private static let reserved: CGFloat = 30 + 6 + 40

    var body: some View {
        GeometryReader { proxy in
            let layout = StripLayout.layout(store)
            // Size per visible tab (a split counts as its tabs), then give each item the sum of its tabs' widths.
            let sizing = TabSizing(count: layout.visibleTabs.count, selectedIndex: layout.visibleTabs.firstIndex { store.isSelected($0) },
                                   available: proxy.size.width - Self.reserved - layout.labelsWidth, spacing: 0)
            let row = HStack(spacing: 0) {
                ForEach(layout.segments) { segment in
                    switch segment {
                    case .item(let item):
                        tabView(item, layout: layout, sizing: sizing)
                    case .group(let group, let items):
                        // Like Dia: the group's label and tabs inside one soft tray.
                        HStack(spacing: 0) {
                            GroupLabel(group: group).frame(height: stripItemHeight)
                            ForEach(items, id: \.id) { tabView($0, layout: layout, sizing: sizing) }
                        }
                        .modifier(GroupTray())
                        .environment(\.inGroupTray, true)
                        .padding(.horizontal, 3)
                    }
                }
                Button { store.newBlankTab() } label: {
                    Image(systemName: "plus").font(.system(size: 13, weight: .regular)).frame(width: 30, height: stripItemHeight - 4)
                }
                .buttonStyle(StripButtonStyle())
                .padding(.leading, 6)
                .help("New Tab (⌘T)")
            }
            .animation(.snappy(duration: 0.2), value: sizing.widths)

            if sizing.overflows {
                ScrollViewReader { scroller in
                    ScrollView(.horizontal, showsIndicators: false) { row }
                        .frame(width: proxy.size.width - 40, alignment: .leading)
                        .onChange(of: store.selectedTab?.id, initial: true) { _, id in
                            guard let id else { return }
                            withAnimation { scroller.scrollTo(id) }
                        }
                }
            } else {
                row
            }
        }
        .frame(height: stripItemHeight)
    }

    /// A tab or split, at its share of the width (nothing if it's hidden in a collapsed group).
    @ViewBuilder private func tabView(_ item: StripItem, layout: StripLayout.Layout, sizing: TabSizing) -> some View {
        if let start = layout.offsets[item.id] {
            let widths = Array(sizing.widths[start..<(start + item.tabs.count)])
            switch item {
            case .tab(let tab): TabItem(tab: tab, width: widths[0]).id(tab.id)
            case .split(_, let members): SplitTabItem(tabs: members, widths: widths).id(members[0].id)
            }
        }
    }
}

/// The tab order as the strip and sidebar show it: tabs and splits, with each group's run gathered together.
@MainActor
enum StripLayout {
    enum Segment: Identifiable {
        case item(StripItem)
        case group(TabGroup, [StripItem])
        var id: UUID {
            switch self {
            case .item(let item): item.id
            case .group(let group, _): group.id
            }
        }
    }

    struct Layout {
        var segments: [Segment] = []
        /// The tabs that are drawn (not hidden in a collapsed group), for sizing.
        var visibleTabs: [BrowserTab] = []
        /// Each drawn item's first tab's index among `visibleTabs`.
        var offsets: [UUID: Int] = [:]
        var labelsWidth: CGFloat = 0
    }

    /// Tabs and splits in order, with each group's run of them gathered into one segment.
    static func layout(_ store: BrowserStore) -> Layout {
        var layout = Layout()
        for item in StripItem.items(for: store.unpinnedTabs, store: store) {
            if !item.tabs.allSatisfy({ store.isHiddenInCollapsedGroup($0) }) {
                layout.offsets[item.id] = layout.visibleTabs.count
                layout.visibleTabs += item.tabs
            }
            guard let group = store.group(containing: item.tabs[0].id) else {
                layout.segments.append(.item(item))
                continue
            }
            if case .group(let current, let items) = layout.segments.last, current.id == group.id {
                layout.segments[layout.segments.count - 1] = .group(group, items + [item])
            } else {
                layout.segments.append(.group(group, [item]))
                layout.labelsWidth += GroupLabel.width(for: group) + 6
            }
        }
        return layout
    }
}

struct TabSizing {
    static let maxWidth: CGFloat = 190
    static let minWidth: CGFloat = 34
    static let selectedMinWidth: CGFloat = 160

    let widths: [CGFloat]
    let overflows: Bool

    init(count: Int, selectedIndex: Int?, available: CGFloat, spacing: CGFloat) {
        guard count > 0 else {
            widths = []
            overflows = false
            return
        }
        let usable = max(0, available - spacing * CGFloat(count - 1))
        let even = (usable / CGFloat(count)).rounded(.down)
        if even >= Self.selectedMinWidth || selectedIndex == nil || count == 1 {
            let width = min(Self.maxWidth, max(Self.minWidth, even))
            widths = Array(repeating: width, count: count)
            overflows = width * CGFloat(count) > usable + 1
            return
        }
        // Keep the selected tab readable; the rest share what's left.
        let selectedWidth = min(Self.selectedMinWidth, usable)
        let others = ((usable - selectedWidth) / CGFloat(count - 1)).rounded(.down)
        var result = Array(repeating: max(Self.minWidth, others), count: count)
        result[selectedIndex!] = selectedWidth
        widths = result
        overflows = others < Self.minWidth
    }
}

private struct TabItem: View {
    @Environment(BrowserStore.self) private var store
    let tab: BrowserTab
    let width: CGFloat
    @State private var isHovering = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let selected = store.isSelected(tab)
        let siteColor = selected ? store.siteColor : nil
        let compact = width < 60 && !selected
        let showsClose = isHovering && width >= 72
        HStack(spacing: 8) {
            ZStack {
                if tab.isLoading && tab.faviconURL == nil {
                    ProgressView().controlSize(.mini)
                } else {
                    FaviconView(url: tab.faviconURL, page: tab.url, size: 16)
                }
            }
            .frame(width: 16, height: 16)
            if !compact {
                FadingText(text: tab.displayTitle, fade: showsClose ? 14 : 22)
                    .foregroundStyle(Color.primary.opacity(selected ? 1 : 0.72))
            }
        }
        .padding(.leading, compact ? 0 : 15)   // ~10 pt inside the hover highlight, like Dia
        // With the ✕ showing, the title stops (and fades) just before it instead of running underneath.
        .padding(.trailing, compact ? 0 : showsClose ? Self.closeButtonRoom : 15)
        .frame(width: width, height: stripItemHeight, alignment: compact ? .center : .leading)
        .overlay(alignment: .trailing) {
            if showsClose {
                Button { store.close(tab) } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).frame(width: 18, height: 18)
                }
                .buttonStyle(StripButtonStyle())
                .padding(.trailing, 11)
            }
        }
        .environment(\.colorScheme, siteColor?.colorScheme ?? colorScheme)
        .background(alignment: .top) {
            if selected {
                // Taller than other tabs: reaches near the top of the window and flows into the page, like Dia.
                ActiveTabShape(radius: 12, flare: 14)
                    .fill(siteColor?.color ?? cardColor)
                    .animation(.easeInOut(duration: 0.25), value: siteColor)
                    .frame(height: stripHeight - 3)
                    .offset(y: 3 - (stripItemCenterY - stripItemHeight / 2))
            } else if isHovering {
                TabHoverShape(colorScheme: colorScheme).transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .contentShape(Rectangle())
        .onTapGesture { store.select(tab) }
        .onHover { hovering in
            isHovering = hovering
            if hovering { store.hoveredTabID = tab.id } else if store.hoveredTabID == tab.id { store.hoveredTabID = nil }
        }
        .help(tab.displayTitle)
        .contextMenu { TabMenu(tab: tab) }
        .tabDragAndDrop(tab)
        .animation(.easeOut(duration: 0.12), value: showsClose)
    }

    /// The ✕ (18 pt) sits 11 pt from the tab's edge; the title ends 5 pt before it.
    private static let closeButtonRoom: CGFloat = 11 + 18 + 5
}

/// A split in the tab strip: its tabs joined into one item with thin dividers between them.
private struct SplitTabItem: View {
    @Environment(BrowserStore.self) private var store
    let tabs: [BrowserTab]
    let widths: [CGFloat]
    @State private var isHovering = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let containsSelected = tabs.contains { store.isSelected($0) }
        let siteColor = containsSelected ? store.siteColor : nil
        HStack(spacing: 0) {
            ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                if index > 0 {
                    Rectangle().fill(Color.primary.opacity(0.15)).frame(width: 1, height: 14)
                }
                SplitSegment(tab: tab, width: widths[index] - (index > 0 ? 1 : 0))
            }
        }
        .environment(\.colorScheme, siteColor?.colorScheme ?? colorScheme)
        .background(alignment: .top) {
            if containsSelected {
                ActiveTabShape(radius: 12, flare: 14)
                    .fill(siteColor?.color ?? cardColor)
                    .frame(height: stripHeight - 3)
                    .offset(y: 3 - (stripItemCenterY - stripItemHeight / 2))
            } else if isHovering {
                TabHoverShape(colorScheme: colorScheme)
            } else {
                // A faint outline so the joined tabs read as one split.
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                    .padding(.horizontal, 2)
                    .padding(.vertical, 1)
            }
        }
        .onHover { isHovering = $0 }
    }
}

private struct SplitSegment: View {
    @Environment(BrowserStore.self) private var store
    let tab: BrowserTab
    let width: CGFloat

    var body: some View {
        let selected = store.isSelected(tab)
        HStack(spacing: 7) {
            FaviconView(url: tab.faviconURL, page: tab.url, size: 15)
            if width >= 60 {
                FadingText(text: tab.displayTitle, fade: 18)
                    .foregroundStyle(Color.primary.opacity(selected ? 1 : 0.62))
            }
        }
        .padding(.horizontal, width >= 60 ? 10 : 0)
        .frame(width: max(width, 20), height: stripItemHeight, alignment: width >= 60 ? .leading : .center)
        .contentShape(Rectangle())
        .onTapGesture { store.select(tab) }
        .onHover { hovering in
            if hovering { store.hoveredTabID = tab.id } else if store.hoveredTabID == tab.id { store.hoveredTabID = nil }
        }
        .help(tab.displayTitle)
        .contextMenu { TabMenu(tab: tab) }
    }
}

/// Extra mouse buttons (SwiftUI has no gestures for them, so this watches mouse events):
/// - middle-click closes the tab under the pointer, or opens a bookmark in a background tab;
/// - side buttons (back/forward) switch space over the tab strip, like Dia, and go back/forward elsewhere;
/// - a two-finger sideways swipe (or horizontal scroll) over the space pill switches space, once per swipe.
@MainActor
enum MiddleClickHandler {
    private static var monitor: Any?
    private static var swipeMonitor: Any?
    /// Sideways distance scrolled in the current swipe, and whether this swipe has already switched space.
    private static var swipeDistance: CGFloat = 0
    private static var swipeUsed = false

    static func install(store: BrowserStore) {
        guard monitor == nil else { return }
        swipeMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak store] event in
            guard let store, store.isPointerOnSpacePill else { return event }
            // A new swipe starts: forget the last one. Momentum (the glide after lifting) never switches.
            if event.phase == .began || (event.phase == [] && event.momentumPhase == [] && !event.hasPreciseScrollingDeltas) {
                swipeDistance = 0
                swipeUsed = false
            }
            guard event.momentumPhase == [], abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else {
                return event.momentumPhase == [] ? event : nil
            }
            swipeDistance += event.scrollingDeltaX
            let threshold: CGFloat = event.hasPreciseScrollingDeltas ? 40 : 1   // trackpad vs mouse wheel ticks
            if !swipeUsed && abs(swipeDistance) >= threshold {
                swipeUsed = true
                // Fingers moving left (content moving left) goes to the next space, like the iPhone's bar.
                withAnimation(.snappy(duration: 0.2)) { store.selectAdjacentSpace(swipeDistance < 0 ? 1 : -1) }
            }
            if event.phase == .ended || event.phase == .cancelled { swipeDistance = 0; swipeUsed = false }
            return nil
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseUp) { [weak store] event in
            guard let store else { return event }
            if event.buttonNumber == 3 || event.buttonNumber == 4 {
                let forward = event.buttonNumber == 4
                if store.isPointerInTabStrip {
                    withAnimation(.snappy(duration: 0.2)) { store.selectAdjacentSpace(forward ? 1 : -1) }
                } else if forward {
                    store.selectedTab?.goForward()
                } else {
                    store.selectedTab?.goBack()
                }
                return nil
            }
            guard event.buttonNumber == 2 else { return event }
            if let id = store.hoveredTabID, let tab = store.tabs.first(where: { $0.id == id }) {
                store.close(tab)
                store.hoveredTabID = nil
                return nil
            }
            if let id = store.hoveredBookmarkID, let bookmark = store.bookmarks.first(where: { $0.id == id }) {
                if store.middleClickAddsToGroup, let source = store.selectedTab, source.url != nil {
                    store.openInGroup(bookmark.url, from: source)
                } else {
                    store.open(bookmark, inNewTab: true, select: false)
                }
                return nil
            }
            return event
        }
    }
}

/// Single-line text that fades out at the trailing edge instead of ending with "…", like Dia's tabs.
private struct FadingText: View {
    let text: String
    var fade: CGFloat = 22

    var body: some View {
        // A flexible clear box takes exactly the space the tab gives it; the text sits on top at its
        // natural width and is clipped + faded to that box, so it can never spill into the next tab.
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: 18)
            .overlay(alignment: .leading) {
                Text(text)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .clipped()
            .mask {
                HStack(spacing: 0) {
                    Rectangle()
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: fade)
                }
            }
            .animation(.easeOut(duration: 0.12), value: fade)
    }
}

extension EnvironmentValues {
    /// Tabs inside a group's tray keep their hover highlight within it.
    @Entry var inGroupTray = false
}

/// Hover highlight for an inactive tab, like Dia's: starts at the same top edge as the active tab
/// and uses the same corner radius, filling the tab with just a small gap to its neighbours.
private struct TabHoverShape: View {
    let colorScheme: ColorScheme
    @Environment(\.inGroupTray) private var inGroupTray

    var body: some View {
        let fill = Color.white.opacity(colorScheme == .dark ? 0.12 : 0.55)
        if inGroupTray {
            // Inset in the tray, its corners concentric with the tray's 9 pt radius.
            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(fill).padding(3)
        } else {
            freeHover(fill)
        }
    }

    private func freeHover(_ fill: Color) -> some View {
        // Measured from Dia: the hover sits 2 pt inside the active tab's top edge, is 32 pt tall and
        // has a 10 pt radius against the active tab's 12, so the two curves follow each other.
        let activeRise = stripItemCenterY - stripItemHeight / 2 - 3   // active tab top, above the tab's frame
        let rise = activeRise - 2
        return RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(fill)
            .frame(height: 32)
            .offset(y: -rise)
            .padding(.horizontal, 5)   // even ~6 pt gap to the active tab, like Dia
            .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// Rounded top corners plus concave "flares" at the bottom, so the selected tab curves
/// smoothly into the content card on both sides. The flares draw just outside the tab's bounds.
private struct ActiveTabShape: Shape {
    var radius: CGFloat
    var flare: CGFloat

    /// Top corners are rounded; the bottom flares out with true quarter circles (measured from Dia: a gentle
    /// ~14 pt curve, so the gap to a hovered neighbour stays even all the way down).
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let (minX, maxX, minY, maxY) = (rect.minX, rect.maxX, rect.minY, rect.maxY)
        path.move(to: CGPoint(x: minX - flare, y: maxY))
        path.addArc(tangent1End: CGPoint(x: minX, y: maxY), tangent2End: CGPoint(x: minX, y: minY), radius: flare)
        path.addArc(tangent1End: CGPoint(x: minX, y: minY), tangent2End: CGPoint(x: maxX, y: minY), radius: radius)
        path.addArc(tangent1End: CGPoint(x: maxX, y: minY), tangent2End: CGPoint(x: maxX, y: maxY), radius: radius)
        path.addArc(tangent1End: CGPoint(x: maxX, y: maxY), tangent2End: CGPoint(x: maxX + flare, y: maxY), radius: flare)
        path.addLine(to: CGPoint(x: maxX + flare, y: maxY))
        path.closeSubpath()
        return path
    }
}

private struct SiteColored: ViewModifier {
    let color: RGBColor?
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .environment(\.colorScheme, color?.colorScheme ?? colorScheme)
            .background(color?.color ?? .clear)
            .animation(.easeInOut(duration: 0.25), value: color)
    }
}

private extension View {
    func siteColored(_ color: RGBColor?) -> some View { modifier(SiteColored(color: color)) }
}

struct TabMenu: View {
    @Environment(BrowserStore.self) private var store
    let tab: BrowserTab

    var body: some View {
        Button(tab.isPinned ? "Unpin Tab" : "Pin Tab") { store.togglePin(tab) }
        Button("Duplicate Tab") { store.duplicate(tab) }
        Button("Reload") { tab.loadedWebView?.reload() }
        if let url = tab.url {
            Button("Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
            }
        }
        let otherSpaces = store.spaces.filter { $0.id != tab.spaceID }
        if !otherSpaces.isEmpty, tab.url != nil {
            Menu("Open in Space") {
                ForEach(otherSpaces) { space in
                    Button(space.name) { store.open(tab, inSpace: space.id) }
                }
            }
        }
        Divider()
        if let current = store.selectedTab, store.canSplit(tab, beside: current) {
            Button("Show Beside Current Tab") { store.addToSplit(tab, beside: current) }
        }
        if store.split(containing: tab.id) != nil {
            Button("Remove from Split View") { store.removeFromSplit(tab) }
            Button("Separate Split View") { store.separateSplit(containing: tab) }
        }
        Divider()
        TabGroupMenuItems(tab: tab)
        Divider()
        Button("Close Tab") { store.close(tab) }
    }
}

extension View {
    /// Drag a tab onto another to reorder (works between pinned and regular tabs too).
    func tabDragAndDrop(_ tab: BrowserTab) -> some View {
        modifier(TabDragAndDrop(tab: tab))
    }
}

private struct TabDragAndDrop: ViewModifier {
    @Environment(BrowserStore.self) private var store
    let tab: BrowserTab

    func body(content: Content) -> some View {
        content
            .onDrag { NSItemProvider(object: tab.id.uuidString as NSString) }
            .onDrop(of: [.plainText], isTargeted: nil) { providers in
                guard let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                    guard let string = object as? String, let id = UUID(uuidString: string) else { return }
                    Task { @MainActor in
                        guard let dragged = store.tabs.first(where: { $0.id == id }), dragged.spaceID == tab.spaceID else { return }
                        withAnimation(.snappy(duration: 0.2)) { store.moveTab(dragged, before: tab) }
                    }
                }
                return true
            }
    }
}

struct StripButtonStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.secondary)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.primary.opacity(configuration.isPressed ? 0.14 : isHovering ? 0.08 : 0))
            )
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
    }
}

// MARK: - Navigation bar

private struct NavigationBar: View {
    @Environment(BrowserStore.self) private var store
    let tab: BrowserTab?
    var height: CGFloat = 38

    var body: some View {
        HStack(spacing: 2) {
            navButton("chevron.left", help: "Back (⌘[)", enabled: tab?.canGoBack == true) { tab?.goBack() }
            navButton("chevron.right", help: "Forward (⌘])", enabled: tab?.canGoForward == true) { tab?.goForward() }
            navButton(tab?.isLoading == true ? "xmark" : "arrow.clockwise", help: "Reload (⌘R)", enabled: tab != nil) { tab?.reload() }
            AddressField(tab: tab)
                .padding(.leading, 8)
            Spacer(minLength: 8)
            if !store.downloads.items.isEmpty {
                DownloadsButton()
            }
            if let tab, let host = tab.url?.host() {
                let logins = store.passwords.logins(forHost: host, in: tab.spaceID)
                if !logins.isEmpty {
                    Menu {
                        ForEach(logins) { login in
                            Button("Fill \(login.username.isEmpty ? "password" : login.username)") {
                                Task { await store.fill(login, in: tab) }
                            }
                        }
                        Divider()
                        SettingsLink { Text("Manage Passwords…") }
                    } label: {
                        Image(systemName: "key.fill")
                            .font(.system(size: 13, weight: .medium))
                            .imageScale(.large)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .frame(width: 28, height: 26)
                    .help("Saved passwords for \(host)")
                }
            }
            if let storeID = ExtensionManager.storeID(in: tab?.url) {
                AddExtensionButton(storeID: storeID).padding(.trailing, 4)
            }
            ExtensionButtons()
            let blocker = store.contentBlocker
            Button { blocker.isEnabled.toggle() } label: {
                Image(systemName: blocker.isEnabled ? "shield.lefthalf.filled" : "shield.slash")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 28, height: 26)
            }
            .buttonStyle(StripButtonStyle())
            .help(blocker.isEnabled ? "Ad blocking is on. Click to turn off." : "Ad blocking is off. Click to turn on.")
            if let tab, tab.url != nil, !tab.isInternalPage, !store.isPrivate(tab.spaceID) {
                let bookmarked = store.isBookmarked(tab)
                Button { store.toggleBookmark(for: tab) } label: {
                    Image(systemName: bookmarked ? "star.fill" : "star")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 28, height: 26)
                }
                .buttonStyle(StripButtonStyle())
                .help(bookmarked ? "Remove bookmark (⌘D)" : "Bookmark this page (⌘D)")
            }
            Button { store.isChatOpen.toggle() } label: {
                Image(systemName: "sparkles").foregroundStyle(store.isChatOpen ? AnyShapeStyle(store.currentSpace.color) : AnyShapeStyle(.primary))
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 28, height: 26)
            }
            .buttonStyle(StripButtonStyle())
            .help(store.isChatOpen ? "Hide Chat (⌘E)" : "Chat with this tab (⌘E)")
        }
        .padding(.horizontal, 8)
        .frame(height: height)
        .overlay(alignment: .bottom) {
            if let tab, tab.isLoading {
                GeometryReader { proxy in
                    Rectangle().fill(store.currentSpace.color)
                        .frame(width: proxy.size.width * max(tab.progress, 0.05))
                        .animation(.easeOut(duration: 0.2), value: tab.progress)
                }
                .frame(height: 2)
            }
        }
    }

    private func navButton(_ symbol: String, help: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium)).frame(width: 28, height: 26)
        }
        .buttonStyle(StripButtonStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .help(help)
    }
}

/// Shows "host / Page title" like Dia; click (or ⌘L) to edit the full URL in place.
private struct AddressField: View {
    @Environment(BrowserStore.self) private var store
    let tab: BrowserTab?
    @State private var draft = ""
    @State private var selection: TextSelection?
    @FocusState private var focused: Bool

    var body: some View {
        if store.isEditingAddress, tab != nil {
            TextField("Search or enter address", text: $draft, selection: $selection)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focused)
                .onAppear {
                    draft = tab?.url?.absoluteString ?? ""
                    selection = TextSelection(range: draft.startIndex..<draft.endIndex)
                    focused = true
                }
                .onSubmit {
                    if let resolved = URLInput.resolve(draft) { store.open(resolved.url, inNewTab: false) }
                    store.isEditingAddress = false
                }
                .onExitCommand { store.isEditingAddress = false }
                .onChange(of: focused) { if !focused { store.isEditingAddress = false } }
        } else {
            HStack(spacing: 0) {
                if let tab {
                    if tab.url?.scheme == "http" {
                        Image(systemName: "exclamationmark.triangle").font(.system(size: 10)).foregroundStyle(.orange).padding(.trailing, 5)
                    }
                    // An extension's own pages show its name, not their internal ID.
                    Text(tab.url.flatMap(store.extensions.name(for:)) ?? URLInput.displayHost(tab.url) ?? "")
                        .foregroundStyle(.primary)
                    if !tab.title.isEmpty || tab.isInternalPage {
                        Text(" / " + tab.displayTitle).foregroundStyle(.tertiary)
                    }
                } else {
                    Text("New Tab").foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 13))
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { store.focusAddress() }
        }
    }
}

// MARK: - Save password

private struct SaveLoginBar: View {
    @Environment(BrowserStore.self) private var store
    let pending: PendingLogin

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "key.fill").foregroundStyle(.secondary)
            Text(pending.isUpdate ? "Update the saved password for " : "Save password for ")
                + Text(pending.username.isEmpty ? pending.host : pending.username).bold()
                + Text(pending.username.isEmpty ? "?" : " on \(pending.host)?")
            Spacer(minLength: 8)
            Button("Never for This Site") { store.resolvePendingLogin(save: false, never: true) }
                .buttonStyle(.borderless)
            Button("Not Now") { store.resolvePendingLogin(save: false) }
            Button(pending.isUpdate ? "Update" : "Save") { store.resolvePendingLogin(save: true) }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
        .font(.callout)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .frame(height: 38)
    }
}

// MARK: - Bookmarks bar

private struct BookmarksBar: View {
    @Environment(BrowserStore.self) private var store

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: store.bookmarksIconsOnly ? 4 : 2) {
                ForEach(store.currentBookmarks) { bookmark in
                    BookmarkItem(bookmark: bookmark, iconOnly: store.bookmarksIconsOnly)
                }
            }
            .padding(.horizontal, 8)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: 30)
        .padding(.bottom, 2)
        .contentShape(Rectangle())
        .contextMenu {
            Toggle("Show Names", isOn: Bindable(store).bookmarksIconsOnly.inverted)
            Button("Hide Bookmarks Bar") { store.showBookmarksBar = false }
        }
    }
}

private struct BookmarkItem: View {
    @Environment(BrowserStore.self) private var store
    let bookmark: Bookmark
    var iconOnly = false
    @State private var isHovering = false
    @State private var isRenaming = false
    @State private var draft = ""

    var body: some View {
        HStack(spacing: 5) {
            FaviconView(url: bookmark.faviconURL, page: bookmark.url, size: iconOnly ? 16 : 14)
            if !iconOnly {
                Text(bookmark.title)
                    .font(.system(size: 12))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, iconOnly ? 0 : 7)
        .frame(width: iconOnly ? 28 : nil, height: 24)
        .frame(maxWidth: 170)
        .fixedSize(horizontal: true, vertical: false)
        .background(.primary.opacity(isHovering ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
            if hovering { store.hoveredBookmarkID = bookmark.id } else if store.hoveredBookmarkID == bookmark.id { store.hoveredBookmarkID = nil }
        }
        .onTapGesture {
            // ⌘-click opens in a background tab, like links.
            let commandDown = NSEvent.modifierFlags.contains(.command)
            store.open(bookmark, inNewTab: commandDown, select: !commandDown)
        }
        .help(bookmark.url.absoluteString)
        .contextMenu {
            Button("Open in New Tab") { store.open(bookmark, inNewTab: true) }
            Button("Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(bookmark.url.absoluteString, forType: .string)
            }
            Button("Rename…") {
                draft = bookmark.title
                isRenaming = true
            }
            Divider()
            Button("Delete Bookmark") { store.removeBookmark(bookmark) }
            Divider()
            Toggle("Show Names", isOn: Bindable(store).bookmarksIconsOnly.inverted)
        }
        .popover(isPresented: $isRenaming, arrowEdge: .bottom) {
            TextField("Name", text: $draft)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
                .padding(12)
                .onSubmit {
                    let title = draft.trimmingCharacters(in: .whitespaces)
                    if !title.isEmpty { store.renameBookmark(bookmark, to: title) }
                    isRenaming = false
                }
        }
        // Drag to reorder; drop a tab here to bookmark it.
        .onDrag { NSItemProvider(object: "bookmark:\(bookmark.id.uuidString)" as NSString) }
        .onDrop(of: [.plainText], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                guard let string = object as? String else { return }
                Task { @MainActor in
                    if string.hasPrefix("bookmark:"), let id = UUID(uuidString: String(string.dropFirst(9))),
                       let dragged = store.bookmarks.first(where: { $0.id == id }) {
                        withAnimation(.snappy(duration: 0.2)) { store.moveBookmark(dragged, before: bookmark) }
                    } else if let id = UUID(uuidString: string), let tab = store.tabs.first(where: { $0.id == id }) {
                        withAnimation(.snappy(duration: 0.2)) { store.addBookmark(for: tab, before: bookmark) }
                    }
                }
            }
            return true
        }
    }
}

/// Toolbar button, same size as the others; a ring shows progress while something downloads.
private struct DownloadsButton: View {
    @Environment(BrowserStore.self) private var store
    @State private var isShowing = false

    var body: some View {
        let items = store.downloads.items
        let active = items.filter { !$0.finished && !$0.failed }
        let progress = active.isEmpty ? nil : active.map(\.progress).reduce(0, +) / Double(active.count)
        Button { isShowing.toggle() } label: {
            ZStack {
                if let progress {
                    Circle().stroke(Color.primary.opacity(0.15), lineWidth: 2).frame(width: 17, height: 17)
                    Circle().trim(from: 0, to: max(progress, 0.04))
                        .stroke(store.currentSpace.color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 17, height: 17)
                    Image(systemName: "arrow.down").font(.system(size: 8.5, weight: .bold))
                } else {
                    Image(systemName: "arrow.down.circle").font(.system(size: 13, weight: .medium))
                }
            }
            .frame(width: 28, height: 26)
        }
        .buttonStyle(StripButtonStyle())
        .help("Downloads")
        .popover(isPresented: $isShowing, arrowEdge: .bottom) {
            DownloadsPanel()
        }
    }
}

/// Dia-style downloads panel: each file with its icon, size or progress, and quick actions.
private struct DownloadsPanel: View {
    @Environment(BrowserStore.self) private var store

    var body: some View {
        let items = Array(store.downloads.items.prefix(20))
        VStack(spacing: 0) {
            HStack {
                Text("Downloads").font(.system(size: 13, weight: .semibold))
                Spacer()
                if items.contains(where: { $0.finished || $0.failed }) {
                    Button("Clear") { store.downloads.clearFinished() }
                        .buttonStyle(.borderless)
                        .font(.system(size: 12))
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 38)
            if items.isEmpty {
                Text("No downloads").foregroundStyle(.secondary).font(.callout).padding(.vertical, 28)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(items) { DownloadRow(item: $0) }
                    }
                    .padding(6)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: 360)
            }
            Button {
                NSWorkspace.shared.open(DownloadManager.directory)
            } label: {
                HStack {
                    Image(systemName: "folder")
                    Text("Open Downloads Folder")
                    Spacer()
                }
                .font(.system(size: 13))
                .padding(.horizontal, 14)
                .frame(height: 36)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(width: 340)
    }
}

private struct DownloadRow: View {
    let item: DownloadManager.Item
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.finished ? item.fileURL.path : item.fileURL.deletingLastPathComponent().path)
                .withFileType(item.fileURL.pathExtension, finished: item.finished))
                .resizable()
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.filename)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if item.failed {
                    Text("Failed").font(.caption).foregroundStyle(.red)
                } else if item.finished {
                    Text(sizeText).font(.caption).foregroundStyle(.secondary)
                } else {
                    ProgressView(value: item.progress).progressViewStyle(.linear).controlSize(.small)
                    Text("\(Int(item.progress * 100))%").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            if item.finished && isHovering {
                Button { NSWorkspace.shared.activateFileViewerSelecting([item.fileURL]) } label: {
                    Image(systemName: "magnifyingglass.circle.fill").font(.system(size: 17))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Show in Finder")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(isHovering ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture(count: 2) { if item.finished { NSWorkspace.shared.open(item.fileURL) } }
        .help(item.finished ? "Double-click to open" : item.filename)
    }

    private var sizeText: String {
        let bytes = (try? item.fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? nil
        return bytes.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "Done"
    }
}

private extension NSImage {
    /// While downloading the file doesn't exist yet, so use the icon for its type instead.
    func withFileType(_ ext: String, finished: Bool) -> NSImage {
        guard !finished, !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return self }
        return NSWorkspace.shared.icon(for: type)
    }
}

// MARK: - Start page

/// Dew's new tab page: the drop hovering over water, a big search box, and the space's bookmarks.
private struct StartPage: View {
    @Environment(BrowserStore.self) private var store

    var body: some View {
        let space = store.currentSpace
        let bookmarks = Array(store.currentBookmarks.prefix(10))
        ZStack {
            VStack(spacing: 0) {
                Spacer(minLength: 20)
                BouncingDewMark(size: 56, style: store.appIcon.markStyle)
                    .padding(.bottom, 22)
                if store.isPrivate {
                    Label("Private browsing: pages aren't saved to history, and cookies are deleted when you close your last private tab.",
                          systemImage: "eye.slash")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 520)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 18)
                }
                // The search box keeps a fixed slot; its suggestions drop down over the bookmarks, like a menu,
                // instead of pushing the page down and re-centring it as you type.
                Color.clear
                    .frame(maxWidth: 600)
                    .frame(height: 52)
                    .overlay(alignment: .top) {
                        CommandBarView(opensInNewTab: store.selectedTab == nil, showsRecentWhenEmpty: false)
                            .id(store.selectedTab?.id ?? space.id)
                            .fixedSize(horizontal: false, vertical: true)
                            // Grey in private browsing, like iOS.
                            .background(store.isPrivate ? Color(white: 0.3) : Color(nsColor: .controlBackgroundColor),
                                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.separator))
                            .shadow(color: .black.opacity(0.07), radius: 18, y: 6)
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 4)
                    .zIndex(1)
                if !bookmarks.isEmpty {
                    // Wraps onto more rows when space is narrow (e.g. a split-view pane).
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 72, maximum: 84), spacing: 14)], spacing: 16) {
                        ForEach(bookmarks) { bookmark in
                            StartBookmarkTile(bookmark: bookmark)
                        }
                    }
                    .frame(maxWidth: CGFloat(min(bookmarks.count, 6)) * 98)
                    .padding(.horizontal, 24)
                    .padding(.top, 28)
                }
                Spacer()
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct StartBookmarkTile: View {
    @Environment(BrowserStore.self) private var store
    let bookmark: Bookmark
    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 7) {
            FaviconView(url: bookmark.faviconURL, page: bookmark.url, size: 22)
                .frame(width: 48, height: 48)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(.separator.opacity(0.6)))
                .shadow(color: .black.opacity(isHovering ? 0.12 : 0.04), radius: isHovering ? 8 : 3, y: 2)
                .scaleEffect(isHovering ? 1.06 : 1)
            Text(bookmark.title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 64)
        }
        .animation(.snappy(duration: 0.15), value: isHovering)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture { store.open(bookmark) }
        .help(bookmark.url.absoluteString)
    }
}

extension Binding where Value == Bool {
    /// The opposite of a Bool binding, e.g. "Show Names" ↔ `bookmarksIconsOnly`.
    var inverted: Binding<Bool> {
        Binding(get: { !wrappedValue }, set: { wrappedValue = !$0 })
    }
}

/// Drag handle in the gap left of the Chat panel: drag to resize the panel, double-click to reset it.
private struct ChatResizeHandle: View {
    static let defaultWidth: Double = 360
    static let range: ClosedRange<Double> = 300...820
    @Binding var width: Double
    @State private var startWidth: Double?
    @State private var isHovering = false

    var body: some View {
        Capsule()
            .fill(.secondary.opacity(isHovering || startWidth != nil ? 0.5 : 0))
            .frame(width: 3, height: 36)
            .frame(width: 8)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { inside in
                isHovering = inside
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = startWidth ?? width
                        if startWidth == nil { startWidth = width }
                        // Dragging left makes the panel wider.
                        width = min(max(start - value.translation.width, Self.range.lowerBound), Self.range.upperBound)
                    }
                    .onEnded { _ in startWidth = nil }
            )
            .onTapGesture(count: 2) { width = Self.defaultWidth }
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .help("Drag to resize Chat; double-click to reset")
    }
}
