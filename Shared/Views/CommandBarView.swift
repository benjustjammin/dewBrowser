import SwiftUI

/// The Dia-style command bar: type a URL or search, or jump to an open tab or something from history.
struct CommandBarView: View {
    @Environment(BrowserStore.self) private var store
    let opensInNewTab: Bool
    var onDismiss: () -> Void = {}
    /// Show recent history before anything is typed (off on the new tab page, which stays clean).
    var showsRecentWhenEmpty = true

    @State private var text: String
    @State private var selection: TextSelection?
    @State private var highlighted = 0
    @FocusState private var isFocused: Bool

    init(initialText: String = "", opensInNewTab: Bool, showsRecentWhenEmpty: Bool = true, onDismiss: @escaping () -> Void = {}) {
        self.opensInNewTab = opensInNewTab
        self.showsRecentWhenEmpty = showsRecentWhenEmpty
        self.onDismiss = onDismiss
        _text = State(initialValue: initialText)
        _selection = State(initialValue: initialText.isEmpty ? nil : TextSelection(range: initialText.startIndex..<initialText.endIndex))
    }

    /// Live suggestions from the search engine, after your tabs/bookmarks/history (same as iOS).
    @State private var engineItems: [Suggestion] = []

    private var items: [Suggestion] {
        if !showsRecentWhenEmpty && text.trimmingCharacters(in: .whitespaces).isEmpty { return [] }
        return store.suggestions(for: text)
    }

    var body: some View {
        let local = items
        let items = local + engineItems
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: store.isPrivate ? "eye.slash" : "magnifyingglass")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField(store.isPrivate ? "Private search or address" : "Search or enter address", text: $text, selection: $selection)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17))
                    .focused($isFocused)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.webSearch)
                    .submitLabel(.go)
                    #endif
                    .onSubmit { activate(items.indices.contains(highlighted) ? items[highlighted] : nil) }
                    .onKeyPress(.downArrow) { move(1, count: items.count) }
                    .onKeyPress(.upArrow) { move(-1, count: items.count) }
                    .onKeyPress(.escape) { onDismiss(); return .handled }
                if !text.isEmpty {
                    Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 52)

            if !items.isEmpty {
                Divider()
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            if index == local.count {
                                Text("\(SearchEngine.current.name) Suggestions")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 10)
                                    .padding(.top, local.isEmpty ? 4 : 10)
                                    .padding(.bottom, 2)
                            }
                            SuggestionRow(item: item, isHighlighted: index == highlighted, tint: store.currentSpace.color)
                                .contentShape(Rectangle())
                                .onTapGesture { activate(item) }
                                #if os(macOS)
                                .onHover { if $0 { highlighted = index } }
                                #endif
                        }
                    }
                    .padding(6)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(height: min(CGFloat(items.count) * 42 + (engineItems.isEmpty ? 12 : 40), 420))
            }
        }
        .onChange(of: text) { highlighted = 0 }
        .task(id: text) { await loadEngineSuggestions() }
        .onAppear {
            isFocused = true
            // The page you were on can still hold the keyboard as a new tab appears; take it again once it's gone.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { isFocused = true }
        }
    }

    private func loadEngineSuggestions() async {
        let query = text.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty, URLInput.resolve(query)?.isSearch == true, store.searchSuggestionsEnabled else {
            engineItems = []
            return
        }
        try? await Task.sleep(for: .milliseconds(180))   // wait for a pause in typing
        guard !Task.isCancelled else { return }
        let results = await SearchSuggestions.fetch(query, engine: SearchEngine.current)
        guard !Task.isCancelled else { return }
        engineItems = results
            .filter { $0.caseInsensitiveCompare(query) != .orderedSame }
            .prefix(6)
            .compactMap { suggestion in URLInput.searchURL(for: suggestion).map { .go($0, label: suggestion, isSearch: true) } }
    }

    private func move(_ delta: Int, count: Int) -> KeyPress.Result {
        guard count > 0 else { return .ignored }
        highlighted = (highlighted + delta + count) % count
        return .handled
    }

    private func activate(_ item: Suggestion?) {
        switch item {
        case .go(let url, _, _): store.open(url, inNewTab: opensInNewTab)
        case .tab(let tab): store.select(tab); store.commandBar = nil
        case .history(let entry): store.open(entry.url, inNewTab: opensInNewTab)
        case .bookmark(let bookmark): store.open(bookmark.url, inNewTab: opensInNewTab)
        case nil: return
        }
        onDismiss()
    }
}

private struct SuggestionRow: View {
    let item: Suggestion
    let isHighlighted: Bool
    let tint: Color

    var body: some View {
        HStack(spacing: 10) {
            icon.frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).lineLimit(1)
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 8)
            if let hint {
                Text(hint).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 36)
        .background(isHighlighted ? tint.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @ViewBuilder private var icon: some View {
        switch item {
        case .go(_, _, let isSearch):
            Image(systemName: isSearch ? "magnifyingglass" : "arrow.up.right").foregroundStyle(.secondary)
        case .tab(let tab): FaviconView(url: tab.faviconURL)
        case .history: Image(systemName: "clock").foregroundStyle(.secondary)
        case .bookmark(let bookmark): FaviconView(url: bookmark.faviconURL, page: bookmark.url)
        }
    }

    private var title: String {
        switch item {
        case .go(_, let label, _): label
        case .tab(let tab): tab.displayTitle
        case .history(let entry): entry.title.isEmpty ? entry.url.absoluteString : entry.title
        case .bookmark(let bookmark): bookmark.title
        }
    }

    private var subtitle: String? {
        switch item {
        case .go: nil
        case .tab(let tab): URLInput.displayHost(tab.url)
        case .history(let entry): URLInput.displayHost(entry.url)
        case .bookmark(let bookmark): URLInput.displayHost(bookmark.url)
        }
    }

    private var hint: String? {
        switch item {
        case .go(_, _, let isSearch): isSearch ? "Search" : "Open"
        case .tab: "Switch to Tab"
        case .history: nil
        case .bookmark: "Bookmark"
        }
    }
}
