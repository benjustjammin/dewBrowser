import SwiftUI

/// iPhone Duo, folded or open. The browser's buttons are primary toolbar actions, which iOS puts in
/// the Duo's right-edge column (under the status strip), like HALVoIP and Apple's apps. There's no
/// tab bar: the Tabs button in that column opens the tab grid, and Settings is in the space menu.
/// The address bar lives in the page area, top or bottom (Settings → General), so moving it never
/// moves the menu icons.
struct DuoBrowserView: View {
    @Environment(BrowserStore.self) private var store
    @Binding var showingTabs: Bool

    var body: some View {
        DuoBrowsePane {
            Task {
                await store.selectedTab?.captureThumbnail()
                showingTabs = true
            }
        }
    }
}

private struct DuoBrowsePane: View {
    @Environment(BrowserStore.self) private var store
    @Environment(\.horizontalSizeClass) private var sizeClass
    let showTabs: () -> Void

    private func stripOnLeading(_ safe: EdgeInsets) -> Bool { safe.leading > safe.trailing }

    /// Chat's share of the width on the open Duo (drag the handle between the panes).
    @AppStorage("duoChatFraction") private var chatFraction = 0.4
    @State private var dragStartFraction: Double?
    @State private var keyboard = KeyboardObserver()

    var body: some View {
        let tab = store.selectedTab
        // Automatic keeps the address at the top on the Duo; Bottom moves only the address bar.
        let addressAtBottom = store.addressBarPosition == .bottom
        // Open Duo: Chat sits beside the page like split view (two panes and a handle). Folded, it's a sheet.
        let chatPane = sizeClass == .regular && store.isChatOpen
        NavigationStack {
            GeometryReader { proxy in
                // The page fills the screen edge to edge; the address capsule floats over it.
                let capsuleArea: CGFloat = 44 + 16
                let safe = proxy.safeAreaInsets
                // As panes, the page sits inside the safe area, so it needn't reserve room for it.
                let top = chatPane ? 0 : safe.top
                let bottom = chatPane ? 0 : safe.bottom
                let obscured = UIEdgeInsets(top: addressAtBottom ? top : top + capsuleArea, left: 0,
                                            bottom: addressAtBottom ? bottom + capsuleArea : bottom, right: 0)
                let divider: CGFloat = 10
                let panesWidth = proxy.size.width - 8 - divider
                let chatWidth = panesWidth * min(max(chatFraction, 0.28), 0.62)
                HStack(spacing: 0) {
                    ZStack(alignment: addressAtBottom ? .bottom : .top) {
                        Group {
                            if sizeClass == .regular, let selected = store.selectedSplit {
                                SplitContentView(split: selected.split, tabs: selected.tabs) { _ in PhoneStartPage() }
                                    .padding(.top, top)
                                    .padding(.bottom, bottom + (addressAtBottom ? capsuleArea : 0))
                            } else if let tab, !store.isBlank(tab) {
                                WebContainer(tab: tab, obscuredInsets: obscured)
                            } else {
                                PhoneStartPage()
                                    .padding(.top, top)
                                    .padding(.bottom, bottom)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        // Optionally run the page under the right-edge status strip too.
                        .ignoresSafeArea(edges: chatPane ? [] : store.pageUnderStatusStrip
                                         ? Edge.Set.vertical.union(stripOnLeading(safe) ? .leading : .trailing) : .vertical)

                        if addressAtBottom && keyboard.isVisible {
                            // Typing on the page: a small pill just above the keyboard, like Quiche, instead of
                            // the full capsule landing on top of the field being typed in.
                            DuoAddressField(compact: true)
                                .padding(.bottom, max(keyboard.height - safe.bottom, 0) + 6)
                                .transition(.opacity)
                        } else {
                            DuoAddressField()
                                .padding(.horizontal, chatPane ? 10 : 16)
                                .padding(.vertical, 8)
                        }
                    }
                    .modifier(PaneShape(active: chatPane))
                    if chatPane {
                        SplitDivider()
                            .frame(width: divider)
                            .gesture(
                                DragGesture(minimumDistance: 1)
                                    .onChanged { value in
                                        let start = dragStartFraction ?? chatFraction
                                        dragStartFraction = start
                                        chatFraction = min(max(start - Double(value.translation.width / panesWidth), 0.28), 0.62)
                                    }
                                    .onEnded { _ in dragStartFraction = nil }
                            )
                        NavigationStack {
                            ChatPanelView().toolbar(.hidden, for: .navigationBar)
                        }
                        .frame(width: chatWidth)
                        // The layout ignores the keyboard, so lift Chat's text box above it here.
                        .padding(.bottom, max(keyboard.height - safe.bottom, 0))
                        .background(Color(uiColor: .systemBackground))
                        .modifier(PaneShape(active: true))
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .padding(chatPane ? 4 : 0)
                .animation(.easeOut(duration: 0.22), value: chatPane)
                // The buttons, anchored to the bottom of the Duo's right-edge status strip and growing
                // upward (iOS's own toolbar placement starts at the top and leaves a gap at the bottom).
                // The strip is on the right in portrait and moves to the left in landscape; follow it.
                .overlay(alignment: stripOnLeading(safe) ? .bottomLeading : .bottomTrailing) {
                    let leading = stripOnLeading(safe)
                    let strip = leading ? safe.leading : safe.trailing
                    DuoControls(showTabs: showTabs)
                        .frame(width: max(strip, 56))
                        .offset(x: leading ? -strip : strip)
                        .padding(.bottom, 8)
                }
                .animation(.easeOut(duration: 0.2), value: keyboard.isVisible)
            }
            // The keyboard doesn't push the layout up: the page and side buttons stay put (WebKit scrolls the
            // field into view itself). Without this, the address capsule and buttons jumped up by the
            // keyboard's height, over the page and the clock.
            .ignoresSafeArea(.keyboard)
            .toolbar(.hidden, for: .navigationBar)
        }
    }
}

/// A pane in the open Duo's split: rounded, with a hairline edge, like split view's panes.
private struct PaneShape: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        if active {
            content
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
        } else {
            content
        }
    }
}

/// The browser's buttons as a vertical glass capsule. Which buttons, and their order, are set in
/// Settings → General → Side Buttons.
private struct DuoControls: View {
    @Environment(BrowserStore.self) private var store
    @AppStorage(SideButton.defaultsKey) private var saved = SideButton.defaultValue
    let showTabs: () -> Void

    private var tabsSymbol: String {
        let count = store.orderedTabs.count
        return count == 0 ? "square.on.square" : "\(min(count, 50)).square"
    }

    var body: some View {
        let tab = store.selectedTab
        VStack(spacing: 4) {
            ForEach(SideButton.decode(saved)) { button in
                switch button {
                case .back:
                    control("Back", "chevron.backward", enabled: tab?.canGoBack == true) { tab?.goBack() }
                case .forward:
                    control("Forward", "chevron.forward", enabled: tab?.canGoForward == true) { tab?.goForward() }
                case .reload:
                    control(tab?.isLoading == true ? "Stop" : "Reload", tab?.isLoading == true ? "xmark" : "arrow.clockwise",
                            enabled: !store.isBlank(tab)) { tab?.reload() }
                case .tabs:
                    control("Tabs", tabsSymbol, enabled: true) { showTabs() }
                case .newTab:
                    control("New Tab", "plus", enabled: true) { store.showCommandBar(newTab: true) }
                case .chat:
                    control("Chat", "sparkles", enabled: true) {
                        store.isChatOpen.toggle()
                    }
                case .bookmark:
                    let bookmarked = tab.map { store.isBookmarked($0) } ?? false
                    control(bookmarked ? "Remove Bookmark" : "Bookmark", bookmarked ? "star.fill" : "star",
                            enabled: tab?.url != nil && !store.isPrivate) { if let tab { store.toggleBookmark(for: tab) } }
                case .share:
                    if let url = tab?.url {
                        ShareLink(item: url) { Image(systemName: "square.and.arrow.up").frame(width: 44, height: 44) }
                            .buttonStyle(.plain)
                            .foregroundStyle(.tint)
                            .accessibilityLabel("Share")
                    } else {
                        control("Share", "square.and.arrow.up", enabled: false) {}
                    }
                case .space:
                    SpaceMenu().frame(width: 44, height: 44)
                case .settings:
                    control("Settings", "gearshape", enabled: true) { store.openSettings() }
                case .more:
                    MoreMenu().frame(width: 44, height: 44)
                }
            }
        }
        .font(.system(size: 19, weight: .medium))
        .padding(.vertical, 8)
        .frame(width: 52)
        .modifier(GlassCapsule())
    }

    private func control(_ title: String, _ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
        .disabled(!enabled)
        .accessibilityLabel(title)
    }
}

/// Liquid Glass on iOS 26+, a material capsule before that.
private struct GlassCapsule: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: Capsule())
        } else {
            content
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.primary.opacity(0.08)))
                .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
        }
    }
}

private struct DuoAddressField: View {
    @Environment(BrowserStore.self) private var store
    /// The small pill shown above the keyboard while typing on the page.
    var compact = false

    var body: some View {
        if compact { pill } else { capsule }
    }

    /// Above the keyboard: just the site, small, so the page stays visible.
    private var pill: some View {
        let tab = store.selectedTab
        return Button { store.showCommandBar(newTab: tab == nil) } label: {
            HStack(spacing: 5) {
                if let tab, !store.isBlank(tab) {
                    FaviconView(url: tab.faviconURL, size: 12)
                    Text(URLInput.displayHost(tab.url) ?? tab.displayTitle).lineLimit(1)
                } else {
                    Image(systemName: "magnifyingglass")
                    Text("Search").foregroundStyle(.secondary)
                }
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(store.isPrivate ? AnyShapeStyle(Color(white: 0.3)) : AnyShapeStyle(.regularMaterial), in: Capsule())
            .overlay(Capsule().strokeBorder(.primary.opacity(0.08)))
            .shadow(color: .black.opacity(0.1), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
    }

    private var capsule: some View {
        let tab = store.selectedTab
        return Button { store.showCommandBar(newTab: tab == nil) } label: {
            HStack(spacing: 6) {
                if let tab, !store.isBlank(tab) {
                    FaviconView(url: tab.faviconURL, size: 14)
                    Text(URLInput.displayHost(tab.url) ?? tab.displayTitle).lineLimit(1)
                } else {
                    Image(systemName: store.isPrivate ? "eye.slash" : "magnifyingglass")
                    Text(store.isPrivate ? "Private — search or enter address" : "Search or enter address")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            // Grey in private browsing, so it's obvious.
            .background(store.isPrivate ? AnyShapeStyle(Color(white: 0.3)) : AnyShapeStyle(.regularMaterial), in: Capsule())
            .overlay(Capsule().strokeBorder(.primary.opacity(0.08)))
            .overlay(alignment: .bottom) {
                // Loading progress along the capsule's bottom edge.
                if let tab, tab.isLoading {
                    GeometryReader { proxy in
                        Capsule().fill(store.currentSpace.color)
                            .frame(width: proxy.size.width * max(tab.progress, 0.05), height: 2.5)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                    }
                    .padding(.horizontal, 18)
                }
            }
            .shadow(color: .black.opacity(0.14), radius: 14, y: 4)
        }
        .buttonStyle(.plain)
    }
}

/// Tracks the on-screen keyboard's height (0 when hidden), for layouts that don't let it push them around.
@MainActor @Observable
final class KeyboardObserver {
    private(set) var height: CGFloat = 0
    var isVisible: Bool { height > 0 }
    @ObservationIgnored private var tokens: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        tokens.append(center.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main) { [weak self] note in
            guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            MainActor.assumeIsolated {
                let screen = (note.object as? UIScreen)?.bounds
                    ?? UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen.bounds }.first ?? .zero
                self?.height = max(screen.maxY - frame.minY, 0)
            }
        })
        tokens.append(center.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.height = 0 }
        })
    }

    deinit { tokens.forEach(NotificationCenter.default.removeObserver) }
}
