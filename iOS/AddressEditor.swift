import SwiftUI

/// Tapping the address bar on iOS, like Safari: the address becomes a text field in place (just
/// above the keyboard when the bar is at the bottom) with a round ✕ to cancel, and suggestions fill
/// the screen: your tabs, bookmarks and history, then live suggestions from the search engine.
/// In private browsing the field is grey with an eye, so it's obvious.
struct AddressEditor: View {
    @Environment(BrowserStore.self) private var store
    let state: CommandBarState
    var atBottom: Bool

    @State private var text: String
    @State private var selection: TextSelection?
    @State private var engineSuggestions: [String] = []
    @FocusState private var focused: Bool

    init(state: CommandBarState, atBottom: Bool) {
        self.state = state
        self.atBottom = atBottom
        _text = State(initialValue: state.text)
        _selection = State(initialValue: state.text.isEmpty ? nil : TextSelection(range: state.text.startIndex..<state.text.endIndex))
    }

    private var engine: SearchEngine { SearchEngine.current }

    var body: some View {
        VStack(spacing: 0) {
            if !atBottom { field.padding(.top, 8) }
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    let local = store.suggestions(for: text)
                    ForEach(local) { item in row(for: item) }
                    if !engineSuggestions.isEmpty {
                        Text("\(engine.name) Suggestions")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 20)
                            .padding(.top, local.isEmpty ? 8 : 18)
                            .padding(.bottom, 4)
                        ForEach(engineSuggestions, id: \.self) { suggestion in
                            SuggestionLine(symbol: "magnifyingglass", title: suggestion, detail: nil) {
                                if let url = URLInput.searchURL(for: suggestion) { go(url) }
                            }
                        }
                    }
                }
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollDismissesKeyboard(.interactively)
            if atBottom { field.padding(.bottom, 8) }
        }
        .background {
            Rectangle().fill(.regularMaterial).ignoresSafeArea()
                .onTapGesture { store.commandBar = nil }
        }
        .onAppear { focused = true }
        .task(id: text) { await loadEngineSuggestions() }
    }

    // MARK: Field

    private var field: some View {
        let isPrivate = store.isPrivate
        return HStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: isPrivate ? "eye.slash" : "magnifyingglass")
                    .foregroundStyle(isPrivate ? Color.white.opacity(0.75) : Color.secondary)
                TextField(isPrivate ? "Private search or address" : "Search or enter address", text: $text, selection: $selection)
                    .focused($focused)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.webSearch)
                    .submitLabel(.go)
                    .foregroundStyle(isPrivate ? .white : .primary)
                    .onSubmit { submit() }
                if !text.isEmpty {
                    Button { text = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(isPrivate ? Color.white.opacity(0.6) : Color.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .font(.body)
            .padding(.horizontal, 16)
            .frame(height: 50)
            .background(isPrivate ? AnyShapeStyle(Color(white: 0.3)) : AnyShapeStyle(.thickMaterial), in: Capsule())
            .overlay(Capsule().strokeBorder(isPrivate ? Color.white.opacity(0.2) : store.currentSpace.color.opacity(0.45), lineWidth: 1.5))

            Button { store.commandBar = nil } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 50, height: 50)
                    .background(.thickMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel")
        }
        .padding(.horizontal, 14)
    }

    // MARK: Rows

    @ViewBuilder private func row(for item: Suggestion) -> some View {
        switch item {
        case .go(let url, let label, let isSearch):
            SuggestionLine(symbol: isSearch ? "magnifyingglass" : "arrow.up.right", title: label,
                           detail: isSearch ? engine.name : nil) { go(url) }
        case .tab(let tab):
            SuggestionLine(icon: tab.faviconURL, page: tab.url, title: tab.displayTitle, detail: "Switch to Tab") {
                store.select(tab)
                store.commandBar = nil
            }
        case .bookmark(let bookmark):
            SuggestionLine(icon: bookmark.faviconURL, page: bookmark.url, title: bookmark.title,
                           detail: URLInput.displayHost(bookmark.url)) { go(bookmark.url) }
        case .history(let entry):
            SuggestionLine(icon: nil, page: entry.url, title: entry.title.isEmpty ? entry.url.absoluteString : entry.title,
                           detail: URLInput.displayHost(entry.url)) { go(entry.url) }
        }
    }

    private func submit() {
        if let resolved = URLInput.resolve(text) { go(resolved.url) }
    }

    private func go(_ url: URL) {
        store.open(url, inNewTab: state.opensInNewTab)
    }

    private func loadEngineSuggestions() async {
        let query = text.trimmingCharacters(in: .whitespaces)
        // Don't send things that are clearly addresses, and wait for a pause in typing.
        guard !query.isEmpty, URLInput.resolve(query)?.isSearch == true, store.searchSuggestionsEnabled else {
            engineSuggestions = []
            return
        }
        try? await Task.sleep(for: .milliseconds(180))
        guard !Task.isCancelled else { return }
        let results = await SearchSuggestions.fetch(query, engine: engine)
        guard !Task.isCancelled else { return }
        engineSuggestions = Array(results.filter { $0.caseInsensitiveCompare(query) != .orderedSame }.prefix(8))
    }
}

private struct SuggestionLine: View {
    var symbol: String?
    var icon: URL?
    var page: URL?
    let title: String
    let detail: String?
    let action: () -> Void

    init(symbol: String, title: String, detail: String?, action: @escaping () -> Void) {
        self.symbol = symbol
        self.title = title
        self.detail = detail
        self.action = action
    }

    init(icon: URL?, page: URL?, title: String, detail: String?, action: @escaping () -> Void) {
        self.icon = icon
        self.page = page
        self.title = title
        self.detail = detail
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Group {
                    if let symbol {
                        Image(systemName: symbol).foregroundStyle(.secondary)
                    } else {
                        FaviconView(url: icon, page: page, size: 20)
                    }
                }
                .frame(width: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).lineLimit(1).foregroundStyle(.primary)
                    if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .frame(minHeight: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
