import SwiftUI

/// Tabs down the left (Settings → Appearance → Tabs → Side, or ⌘S): the space's name and menu, pinned tabs as
/// icon tiles, then tabs, splits and groups in order, and the spaces along the bottom.
struct TabSidebar: View {
    @Environment(BrowserStore.self) private var store
    static let width: CGFloat = 240

    var body: some View {
        let space = store.currentSpace
        VStack(alignment: .leading, spacing: 0) {
            // Room for the window buttons; the window drags from here.
            HStack {
                Spacer()
                Button { store.tabsInSidebar = false } label: {
                    Image(systemName: "sidebar.left").font(.system(size: 13, weight: .medium)).frame(width: 28, height: 26)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Show Tabs at the Top (⌘S)")
            }
            .padding(.trailing, 8)
            .frame(height: stripHeight)
            .background { WindowDragArea() }

            Menu { SpaceMenuContent() } label: {
                Text(space.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(space.color)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .padding(.horizontal, 14)
            .padding(.bottom, 8)

            if !store.pinnedTabs.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 40), spacing: 6)], spacing: 6) {
                    ForEach(store.pinnedTabs) { PinnedTile(tab: $0) }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            }

            ScrollView {
                VStack(spacing: 1) {
                    rows
                    Button { store.newBlankTab() } label: {
                        Label("New Tab", systemImage: "plus").font(.system(size: 13))
                            .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                            .padding(.horizontal, 10)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 6)
            }

            HStack(spacing: 6) {
                ForEach(store.spaces) { item in
                    Button { store.selectSpace(item.id) } label: {
                        SpaceBadge(space: item, size: 22)
                            .opacity(item.id == store.selectedSpaceID ? 1 : 0.45)
                    }
                    .buttonStyle(.plain)
                    .help(item.name)
                }
                Spacer()
            }
            .padding(12)
        }
        .frame(width: Self.width)
        .onHover { store.isPointerInTabStrip = $0 }
    }

    /// Tabs and splits in order; a group is its label and tabs in a soft tray, like Dia's.
    @ViewBuilder private var rows: some View {
        ForEach(StripLayout.layout(store).segments) { segment in
            switch segment {
            case .item(let item):
                SidebarRow(tabs: item.tabs)
            case .group(let group, let items):
                VStack(spacing: 1) {
                    HStack { GroupLabel(group: group); Spacer(minLength: 0) }
                        .frame(height: 30)
                    ForEach(items, id: \.id) { item in
                        if !item.tabs.allSatisfy({ store.isHiddenInCollapsedGroup($0) }) { SidebarRow(tabs: item.tabs) }
                    }
                }
                .padding(3)
                .modifier(GroupTray())
                .padding(.vertical, 2)
            }
        }
    }
}

/// One tab, or a split shown as its tabs side by side, in the sidebar.
private struct SidebarRow: View {
    @Environment(BrowserStore.self) private var store
    let tabs: [BrowserTab]
    @State private var isHovering = false

    var body: some View {
        let selected = tabs.contains { store.isSelected($0) }
        HStack(spacing: 0) {
            ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                if index > 0 { Rectangle().fill(.primary.opacity(0.15)).frame(width: 1, height: 14).padding(.horizontal, 6) }
                HStack(spacing: 8) {
                    FaviconView(url: tab.faviconURL, page: tab.url, size: 16)
                    Text(tab.displayTitle).lineLimit(1).font(.system(size: 13))
                        .foregroundStyle(.primary.opacity(selected ? 1 : 0.75))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { store.select(tab) }
                .contextMenu { TabMenu(tab: tab) }
                .tabDragAndDrop(tab)
            }
            if isHovering, let last = tabs.last {
                Button { for tab in tabs { store.close(tab) } } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).frame(width: 18, height: 18)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help(tabs.count > 1 ? "Close Tabs" : "Close Tab")
                .id(last.id)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? AnyShapeStyle(store.siteColor?.color ?? cardColor) : AnyShapeStyle(.primary.opacity(isHovering ? 0.06 : 0)))
                .shadow(color: .black.opacity(selected ? 0.08 : 0), radius: 1, y: 0.5)
        }
        .environment(\.colorScheme, selected ? (store.siteColor?.colorScheme ?? colorScheme) : colorScheme)
        .onHover { hovering in
            isHovering = hovering
            if hovering { store.hoveredTabID = tabs.first?.id } else if store.hoveredTabID == tabs.first?.id { store.hoveredTabID = nil }
        }
        .help(tabs.map(\.displayTitle).joined(separator: " | "))
    }

    @Environment(\.colorScheme) private var colorScheme
}

/// A pinned tab as an icon tile.
private struct PinnedTile: View {
    @Environment(BrowserStore.self) private var store
    let tab: BrowserTab

    var body: some View {
        let selected = store.isSelected(tab)
        FaviconView(url: tab.faviconURL, page: tab.url, size: 18)
            .frame(maxWidth: .infinity, minHeight: 36)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(selected ? AnyShapeStyle(cardColor) : AnyShapeStyle(.primary.opacity(0.05))))
            .contentShape(Rectangle())
            .onTapGesture { store.select(tab) }
            .help(tab.displayTitle)
            .contextMenu { TabMenu(tab: tab) }
            .tabDragAndDrop(tab)
    }
}

/// Auto-hidden tabs: an invisible strip along the window's left edge (sidebar) or top edge (top tabs); when the
/// pointer reaches it, the tabs slide in over the page, and slide away again shortly after it leaves them.
struct AutoHidingTabs: View {
    @Environment(BrowserStore.self) private var store
    @State private var isShown = false
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        let side = store.tabsInSidebar
        ZStack(alignment: side ? .leading : .top) {
            Color.clear
                .frame(width: side ? 6 : nil, height: side ? nil : 6)
                .frame(maxWidth: side ? nil : .infinity, maxHeight: side ? .infinity : nil)
                .contentShape(Rectangle())
                .onHover { if $0 { show() } }
            if isShown {
                Group {
                    if side { TabSidebar().frame(maxHeight: .infinity) } else { TabStrip() }
                }
                .background {
                    ZStack {
                        Color(nsColor: .windowBackgroundColor)
                        store.currentSpace.color.opacity(0.22)
                    }
                }
                .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: side ? 0 : 10, bottomTrailingRadius: 10,
                                                  topTrailingRadius: side ? 10 : 0, style: .continuous))
                .shadow(color: .black.opacity(0.2), radius: 14, x: side ? 4 : 0, y: side ? 0 : 4)
                .onHover { $0 ? show() : hideSoon() }
                .transition(.move(edge: side ? .leading : .top).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.22), value: isShown)
    }

    private func show() {
        hideTask?.cancel()
        isShown = true
    }

    /// A short pause before hiding, so moving into a menu or back again doesn't make the tabs flicker.
    private func hideSoon() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            isShown = false
        }
    }
}

/// Lets the window be dragged (and zoomed with a double-click) from an otherwise empty area.
struct WindowDragArea: View {
    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(WindowDragGesture())
            .allowsWindowActivationEvents(true)
            .onTapGesture(count: 2) { NSApp.keyWindow?.zoom(nil) }
    }
}
