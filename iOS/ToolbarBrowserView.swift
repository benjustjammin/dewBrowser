import SwiftUI

/// Toolbar layout: address and controls at the top in the system navigation bar, with a strip of
/// tabs under it (Dia-style). Used on iPhone Duo (folded and open), iPad, and when the address bar
/// is set to Top. The system bar lets iOS place the buttons, including in the Duo's status strip.
/// With regular width (Duo open, iPad) split views show side by side.
struct ToolbarBrowserView: View {
    @Environment(BrowserStore.self) private var store
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Binding var showingTabs: Bool

    var body: some View {
        let tab = store.selectedTab
        let isWide = sizeClass == .regular
        NavigationStack {
            HStack(spacing: 0) {
                ZStack {
                    if isWide, let selected = store.selectedSplit {
                        SplitContentView(split: selected.split, tabs: selected.tabs) { _ in PhoneStartPage() }
                    } else if let tab, !store.isBlank(tab) {
                        WebContainer(tab: tab)
                    } else {
                        PhoneStartPage()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Wide screens: Chat is a panel beside the page (narrow ones use a sheet).
                if isWide && store.isChatOpen {
                    ChatSidePanel(width: 400)
                        .padding(.vertical, 4)
                        .padding(.trailing, 4)
                        .padding(.leading, 2)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.22), value: store.isChatOpen)
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    if !isWide {
                        // Narrow screens: iOS drops a crowded toolbar's centre item, so the address
                        // gets its own row (the buttons stay in the toolbar / Duo status strip).
                        AddressPill(expands: true)
                            .padding(.horizontal, 12)
                            .padding(.top, 6)
                    }
                    // Wide screens (iPad) keep a tab strip; narrow ones use the tabs button.
                    if isWide { RegularTabStrip() }
                    if let tab, tab.isLoading {
                        ProgressView(value: max(tab.progress, 0.05))
                            .progressViewStyle(.linear)
                            .tint(store.currentSpace.color)
                            .frame(height: 2)
                    } else {
                        Divider()
                    }
                }
                .background(.bar)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    Button { tab?.goBack() } label: { Image(systemName: "chevron.backward") }
                        .disabled(tab?.canGoBack != true)
                    Button { tab?.goForward() } label: { Image(systemName: "chevron.forward") }
                        .disabled(tab?.canGoForward != true)
                    if isWide {
                        Button { tab?.reload() } label: { Image(systemName: tab?.isLoading == true ? "xmark" : "arrow.clockwise") }
                            .disabled(tab == nil)
                    }
                }
                if isWide {
                    ToolbarItem(placement: .principal) {
                        AddressPill()
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if isWide, let tab, tab.url != nil {
                        Button { store.toggleBookmark(for: tab) } label: {
                            Image(systemName: store.isBookmarked(tab) ? "star.fill" : "star")
                        }
                    }
                    SpaceMenu()
                    Button {
                        Task {
                            await store.selectedTab?.captureThumbnail()
                            showingTabs = true
                        }
                    } label: { Image(systemName: "square.on.square") }
                    MoreMenu()
                }
            }
        }
    }
}

/// The address shown in the toolbar; tapping opens the command bar.
private struct AddressPill: View {
    @Environment(BrowserStore.self) private var store
    var expands = false

    var body: some View {
        let tab = store.selectedTab
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
            .padding(.horizontal, 14)
            .frame(minWidth: 120, idealWidth: 360, maxWidth: expands ? .infinity : 420)
            .frame(height: 36)
            .background(store.isPrivate ? AnyShapeStyle(Color(white: 0.3)) : AnyShapeStyle(.quaternary.opacity(0.6)), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Horizontal tabs for the current space, like the Mac's strip but touch-sized.
private struct RegularTabStrip: View {
    @Environment(BrowserStore.self) private var store

    var body: some View {
        ScrollViewReader { scroller in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(StripItem.items(for: store.orderedTabs, store: store)) { item in
                        switch item {
                        case .tab(let tab):
                            RegularTabChip(tab: tab).id(tab.id)
                        case .split(_, let members):
                            // A split: its tabs joined in one outlined group.
                            HStack(spacing: 2) {
                                ForEach(members) { RegularTabChip(tab: $0).id($0.id) }
                            }
                            .padding(2)
                            .overlay(Capsule().strokeBorder(store.currentSpace.color.opacity(0.35), lineWidth: 1))
                        }
                    }
                    Button { store.showCommandBar(newTab: true) } label: {
                        Image(systemName: "plus").frame(width: 36, height: 34)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .onChange(of: store.selectedTab?.id, initial: true) { _, id in
                guard let id else { return }
                withAnimation { scroller.scrollTo(id, anchor: .center) }
            }
        }
    }
}

private struct RegularTabChip: View {
    @Environment(BrowserStore.self) private var store
    let tab: BrowserTab

    var body: some View {
        let selected = store.isSelected(tab)
        HStack(spacing: 7) {
            FaviconView(url: tab.faviconURL, size: 15)
            if !tab.isPinned {
                Text(tab.displayTitle)
                    .font(.footnote.weight(selected ? .semibold : .regular))
                    .lineLimit(1)
                    .frame(maxWidth: 150, alignment: .leading)
            }
            if selected {
                Button { store.close(tab) } label: {
                    Image(systemName: "xmark").font(.caption2.bold()).frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, selected ? 4 : 10)
        .frame(height: 34)
        .background(selected ? AnyShapeStyle(.background) : AnyShapeStyle(.quaternary.opacity(0.35)), in: Capsule())
        .overlay(Capsule().strokeBorder(selected ? store.currentSpace.color.opacity(0.5) : .clear, lineWidth: 1))
        .contentShape(Capsule())
        .onTapGesture { store.select(tab) }
        .contextMenu {
            if let current = store.selectedTab, store.canSplit(tab, beside: current) {
                Button("Show Beside Current Tab", systemImage: "rectangle.split.2x1") { store.addToSplit(tab, beside: current) }
            }
            if store.split(containing: tab.id) != nil {
                Button("Remove from Split View", systemImage: "rectangle.split.2x1.slash") { store.removeFromSplit(tab) }
            }
            Button(tab.isPinned ? "Unpin" : "Pin", systemImage: "pin") { store.togglePin(tab) }
            Button("Duplicate", systemImage: "plus.square.on.square") { store.duplicate(tab) }
            Button("Close", systemImage: "xmark", role: .destructive) { store.close(tab) }
        }
    }
}
