import SwiftUI

struct TabGridView: View {
    @Environment(BrowserStore.self) private var store
    @Environment(\.dismiss) private var dismissSheet
    /// When shown as a tab (iPhone Duo): called instead of dismissing, and there's no Done button.
    var onFinish: (() -> Void)?

    private func dismiss() {
        if let onFinish { onFinish() } else { dismissSheet() }
    }

    var body: some View {
        let space = store.currentSpace
        NavigationStack {
            ScrollView {
                TabDeck(tint: space.color) { tab in
                    store.select(tab)
                    dismiss()
                } menu: { tab in
                    Group {
                                Button(tab.isPinned ? "Unpin" : "Pin", systemImage: "pin") { store.togglePin(tab) }
                                Button("Duplicate", systemImage: "plus.square.on.square") { store.duplicate(tab) }
                                let others = store.spaces.filter { $0.id != tab.spaceID }
                                if !others.isEmpty {
                                    Menu("Open in Space") {
                                        ForEach(others) { other in Button(other.name) { store.open(tab, inSpace: other.id) } }
                                    }
                                }
                                Button("Close", systemImage: "xmark", role: .destructive) { store.close(tab) }
                    }
                }
                if !store.cloudSync.remoteDevices.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("From Your Other Devices").font(.headline).padding(.horizontal, 8)
                        RemoteTabsView(onOpen: { dismiss() })
                    }
                    .padding(12)
                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
                }
            }
            .safeAreaInset(edge: .top) { SpaceChips() }
            .background(space.color.opacity(0.08))
            .navigationTitle(space.name)
            .navigationBarTitleDisplayMode(.inline)
            // Primary actions: on iPhone Duo iOS puts these in the right-edge column; ✓ sits beside +.
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button("New Tab", systemImage: "plus") {
                        dismiss()
                        store.showCommandBar(newTab: true)
                    }
                    if onFinish == nil {
                        Button("Done", systemImage: "checkmark") { dismiss() }
                    }
                }
            }
        }
        .tint(store.isPrivate ? Color.white : space.color)  // private's grey accent would look disabled
    }
}

private struct SpaceChips: View {
    @Environment(BrowserStore.self) private var store

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(store.spaces) { space in
                    let selected = space.id == store.currentSpace.id
                    HStack(spacing: 6) {
                        SpaceBadge(space: space, size: 20)
                        Text(space.name).font(.subheadline.weight(.semibold))
                        Text("\(store.orderedTabs(in: space.id).count)").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 34)
                    .background(selected ? space.color.opacity(0.22) : Color.secondary.opacity(0.1), in: Capsule())
                    .onTapGesture { withAnimation(.snappy) { store.selectSpace(space.id) } }
                    .onLongPressGesture { store.beginEditing(space) }
                }
                if store.hasPrivateTabs || store.isPrivate {
                    HStack(spacing: 6) {
                        Image(systemName: "eye.slash").font(.caption.weight(.semibold))
                        Text("Private").font(.subheadline.weight(.semibold))
                        Text("\(store.orderedTabs(in: BrowserStore.privateSpaceID).count)").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 34)
                    .background(store.isPrivate ? Color.gray.opacity(0.35) : Color.secondary.opacity(0.1), in: Capsule())
                    .onTapGesture { withAnimation(.snappy) { store.selectSpace(BrowserStore.privateSpaceID) } }
                }
                Button { store.beginNewSpace() } label: {
                    Image(systemName: "plus").frame(width: 34, height: 34).background(Color.secondary.opacity(0.1), in: Circle())
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
        }
        .background(.bar)
        .sheet(item: Bindable(store).spaceEditor) { SpaceEditorView(state: $0).presentationDetents([.medium, .large]) }
    }
}

private struct TabCard: View {
    @Environment(BrowserStore.self) private var store
    let tab: BrowserTab
    let isSelected: Bool
    let tint: Color

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                FaviconView(url: tab.faviconURL, size: 14)
                Text(tab.displayTitle).font(.caption.weight(.medium)).lineLimit(1)
                Spacer(minLength: 0)
                if tab.isPinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary) }
                Button { withAnimation { store.close(tab) } } label: {
                    Image(systemName: "xmark").font(.caption2.bold()).frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(.leading, 10)
            .padding(.trailing, 4)
            .frame(height: 32)
            // A fixed-size box with the thumbnail laid over it, so a wide screenshot can't stretch the card.
            Color(uiColor: .secondarySystemBackground)
                .frame(maxWidth: .infinity)
                .frame(height: 180)
                .overlay(alignment: .top) {
                    if let thumbnail = tab.thumbnail {
                        Image(uiImage: thumbnail).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        FaviconView(url: tab.faviconURL, size: 36).frame(maxHeight: .infinity)
                    }
                }
                .clipped()
        }
        .background(Color(uiColor: .systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(isSelected ? tint : .clear, lineWidth: 2.5))
        .shadow(color: .black.opacity(0.16), radius: 12, x: -2, y: 4)
    }
}

/// Tabs as an overlapping deck of cards (current tab on top), scrolling sideways and always inside the
/// screen edges. Tap a card to switch to it; long-press for more.
private struct TabDeck<Menu: View>: View {
    @Environment(BrowserStore.self) private var store
    @Environment(\.horizontalSizeClass) private var sizeClass
    let tint: Color
    let open: (BrowserTab) -> Void
    @ViewBuilder let menu: (BrowserTab) -> Menu

    var body: some View {
        let tabs = store.orderedTabs
        let selectedIndex = tabs.firstIndex { store.isSelected($0) } ?? 0
        let cardWidth: CGFloat = sizeClass == .regular ? 300 : 220
        // Each card covers the previous one by a quarter of its width.
        let overlap = cardWidth * 0.25
        ScrollViewReader { scroller in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: -overlap) {
                    ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                        TabCard(tab: tab, isSelected: index == selectedIndex, tint: tint)
                            .frame(width: cardWidth)
                            .zIndex(Double(tabs.count - abs(index - selectedIndex)))
                            .onTapGesture { open(tab) }
                            .contextMenu { menu(tab) }
                            .id(tab.id)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
                .animation(.snappy, value: tabs.map(\.id))
            }
            .onAppear {
                if tabs.indices.contains(selectedIndex) { scroller.scrollTo(tabs[selectedIndex].id, anchor: .center) }
            }
        }
    }
}
