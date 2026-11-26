import SwiftUI

/// Tabs side by side, like Dia's split view. Each pane has a slim header (site, title, remove from
/// split); clicking or tapping a pane focuses it, so the address bar and navigation act on it.
/// Drag the handles between panes to resize.
struct SplitContentView<BlankPage: View>: View {
    @Environment(BrowserStore.self) private var store
    let split: TabSplit
    let tabs: [BrowserTab]
    /// What to show in a pane whose tab hasn't loaded anything yet (the new tab page).
    @ViewBuilder let blankPage: (BrowserTab) -> BlankPage

    @State private var dragStart: [Double]?
    private static var dividerWidth: CGFloat { 10 }

    var body: some View {
        GeometryReader { proxy in
            let available = max(proxy.size.width - Self.dividerWidth * CGFloat(tabs.count - 1), 1)
            let fractions = normalized(split.fractions)
            HStack(spacing: 0) {
                ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                    // Fixed width + clip, so wide content (e.g. the new tab page) can't push other panes.
                    SplitPane(tab: tab, isFocused: store.isSelected(tab), blankPage: blankPage)
                        .frame(width: available * fractions[index])
                        .clipped()
                    if index < tabs.count - 1 {
                        SplitDivider()
                            .frame(width: Self.dividerWidth)
                            .gesture(
                                DragGesture(minimumDistance: 1)
                                    .onChanged { value in
                                        let start = dragStart ?? fractions
                                        dragStart = start
                                        store.setFractions(resized(start, at: index, by: Double(value.translation.width / available)),
                                                           for: split.id)
                                    }
                                    .onEnded { _ in dragStart = nil }
                            )
                    }
                }
            }
        }
        .padding(4)
    }

    private func normalized(_ fractions: [Double]) -> [Double] {
        guard fractions.count == tabs.count else { return TabSplit.equal(tabs.count) }
        let total = fractions.reduce(0, +)
        return total > 0 ? fractions.map { $0 / total } : TabSplit.equal(tabs.count)
    }

    /// Moves the boundary after pane `index`, keeping both neighbours at least `minFraction` wide.
    private func resized(_ start: [Double], at index: Int, by delta: Double) -> [Double] {
        var result = start
        let pair = start[index] + start[index + 1]
        let left = min(max(start[index] + delta, TabSplit.minFraction), pair - TabSplit.minFraction)
        result[index] = left
        result[index + 1] = pair - left
        return result
    }
}

private struct SplitPane<BlankPage: View>: View {
    @Environment(BrowserStore.self) private var store
    let tab: BrowserTab
    let isFocused: Bool
    let blankPage: (BrowserTab) -> BlankPage

    var body: some View {
        VStack(spacing: 0) {
            header
            Group {
                if store.isBlank(tab) {
                    blankPage(tab)
                        .contentShape(Rectangle())
                        .simultaneousGesture(TapGesture().onEnded { focus() })
                } else {
                    WebContainer(tab: tab, onInteract: { focus() }, takesFocus: isFocused)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(isFocused ? store.currentSpace.color.opacity(0.7) : Color.primary.opacity(0.1),
                              lineWidth: isFocused ? 2 : 1)
        }
        .animation(.easeOut(duration: 0.15), value: isFocused)
    }

    private var header: some View {
        HStack(spacing: 7) {
            FaviconView(url: tab.faviconURL, size: 13)
            Text(store.isBlank(tab) ? "New Tab" : (URLInput.displayHost(tab.url) ?? tab.displayTitle))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isFocused ? .primary : .secondary)
                .lineLimit(1)
            if !tab.title.isEmpty {
                Text(tab.title)
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Button { store.removeFromSplit(tab) } label: {
                Image(systemName: "rectangle.split.2x1.slash")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 24, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Remove from split view")
            Button { store.close(tab) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 24, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Close tab")
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .frame(height: 28)
        .background(isFocused ? store.currentSpace.color.opacity(0.08) : Color.primary.opacity(0.03))
        .contentShape(Rectangle())
        .onTapGesture { focus() }
    }

    private func focus() {
        if !store.isSelected(tab) { store.select(tab) }
    }
}

/// The grab handle between panes (split view, and Chat beside the page on the open Duo).
struct SplitDivider: View {
    @State private var isHovering = false

    var body: some View {
        ZStack {
            Color.clear.contentShape(Rectangle())
            Capsule()
                .fill(Color.primary.opacity(isHovering ? 0.35 : 0.15))
                .frame(width: 4, height: 40)
        }
        .onHover { hovering in
            isHovering = hovering
            #if os(macOS)
            if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            #endif
        }
        .accessibilityLabel("Resize split view")
    }
}

/// One entry in the tab strip: a single tab, or a split shown as one joined tab (like Dia).
enum StripItem: Identifiable {
    case tab(BrowserTab)
    case split(TabSplit, [BrowserTab])

    var id: UUID {
        switch self {
        case .tab(let tab): tab.id
        case .split(let split, _): split.id
        }
    }

    var tabs: [BrowserTab] {
        switch self {
        case .tab(let tab): [tab]
        case .split(_, let members): members
        }
    }

    @MainActor static func items(for tabs: [BrowserTab], store: BrowserStore) -> [StripItem] {
        var items: [StripItem] = []
        var seen = Set<UUID>()
        for tab in tabs where !seen.contains(tab.id) {
            if let split = store.split(containing: tab.id) {
                let members = split.tabIDs.compactMap { id in tabs.first { $0.id == id } }
                if members.count >= 2 {
                    items.append(.split(split, members))
                    seen.formUnion(split.tabIDs)
                    continue
                }
            }
            items.append(.tab(tab))
            seen.insert(tab.id)
        }
        return items
    }
}
