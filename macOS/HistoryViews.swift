import SwiftUI

/// The ⌄ at the end of the tab strip, like Dia's: search, open tabs, recently closed, recent
/// history, and "Show All History" at the bottom.
struct HistoryPopover: View {
    @Environment(BrowserStore.self) private var store
    var dismiss: () -> Void

    @State private var query = ""
    @State private var showAllTabs = false
    @State private var showAllClosed = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        let tabs = store.orderedTabs.filter { matches($0.displayTitle, $0.url) }
        let closed = store.recentlyClosed.filter { matches($0.title, $0.url) }
        let history = store.history(in: store.selectedSpaceID, matching: query, limit: query.isEmpty ? 8 : 40)

        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search tabs and history", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if !tabs.isEmpty {
                        SectionHeader(title: "Open Tabs")
                        ForEach(showAllTabs ? tabs : Array(tabs.prefix(4))) { tab in
                            Row(icon: tab.faviconURL, title: tab.displayTitle, detail: URLInput.displayHost(tab.url),
                                isCurrent: store.isSelected(tab)) {
                                store.select(tab)
                                dismiss()
                            }
                        }
                        if tabs.count > 4 && !showAllTabs {
                            MoreButton(title: "Show all \(tabs.count) tabs") { showAllTabs = true }
                        }
                    }
                    if !closed.isEmpty {
                        SectionHeader(title: "Recently Closed")
                        ForEach(showAllClosed ? closed : Array(closed.prefix(4)), id: \.id) { record in
                            Row(icon: record.faviconURL, page: record.url, title: record.title.isEmpty ? (URLInput.displayHost(record.url) ?? "Tab") : record.title,
                                detail: URLInput.displayHost(record.url), trailingSymbol: "arrow.uturn.backward") {
                                store.reopen(record)
                                dismiss()
                            }
                        }
                        if closed.count > 4 && !showAllClosed {
                            MoreButton(title: "Show more") { showAllClosed = true }
                        }
                    }
                    if !store.cloudSync.remoteDevices.isEmpty {
                        SectionHeader(title: "From Your Other Devices")
                        RemoteTabsView(query: query, limitPerSpace: query.isEmpty ? 4 : 20) { dismiss() }
                    }
                    if !history.isEmpty {
                        SectionHeader(title: "History")
                        ForEach(history) { entry in
                            Row(icon: nil, page: entry.url, title: entry.title.isEmpty ? entry.url.absoluteString : entry.title,
                                detail: entry.lastVisited.formatted(.relative(presentation: .named))) {
                                store.open(entry.url, inNewTab: true)
                                dismiss()
                            }
                        }
                    }
                    if tabs.isEmpty && closed.isEmpty && history.isEmpty {
                        Text(query.isEmpty ? "No history yet" : "No matches")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: 420)
            .scrollBounceBehavior(.basedOnSize)

            Divider()
            Button {
                store.showHistory()
                dismiss()
            } label: {
                HStack {
                    Text("Show All History")
                    Spacer()
                    Text("⌘Y").foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .frame(height: 36)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(width: 360)
        .onAppear { searchFocused = true }
    }

    private func matches(_ title: String, _ url: URL?) -> Bool {
        query.isEmpty || title.localizedCaseInsensitiveContains(query)
            || (url?.absoluteString.localizedCaseInsensitiveContains(query) ?? false)
    }
}

private struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }
}

private struct Row: View {
    let icon: URL?
    var page: URL?
    let title: String
    var detail: String?
    var isCurrent = false
    var trailingSymbol: String?
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                FaviconView(url: icon, page: page, size: 16)
                Text(title).lineLimit(1)
                Spacer(minLength: 8)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if let trailingSymbol {
                    Image(systemName: trailingSymbol).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(isHovering ? Color.primary.opacity(0.07) : isCurrent ? Color.primary.opacity(0.04) : .clear,
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

private struct MoreButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(.callout).foregroundStyle(.tint).padding(.horizontal, 8).frame(height: 26)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - History tab (⌘Y)

/// Full history as a tab of its own (`dew://history`): searchable, by day, for any space. Clicking an entry
/// opens it in this tab, like Chrome's history page; ⌘-click opens it in a background tab.
struct HistoryPage: View {
    @Environment(BrowserStore.self) private var store
    let tab: BrowserTab
    @State private var query = ""
    @State private var spaceID: UUID?
    @State private var confirmingClear = false

    var body: some View {
        let space = store.spaces.first { $0.id == (spaceID ?? tab.spaceID) } ?? store.currentSpace
        let entries = store.history(in: space.id, matching: query, limit: 2_000)
        let days = Dictionary(grouping: entries) { Calendar.current.startOfDay(for: $0.lastVisited) }
            .sorted { $0.key > $1.key }

        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                header(space)
                if entries.isEmpty {
                    ContentUnavailableView(query.isEmpty ? "No History" : "No Matches", systemImage: "clock")
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                }
                ForEach(days, id: \.key) { day, items in
                    Section {
                        ForEach(items) { entry in HistoryPageRow(entry: entry, tab: tab) }
                    } header: {
                        Text(dayTitle(day))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.top, 18)
                            .padding(.bottom, 6)
                            .background(cardColor)
                    }
                }
            }
            .frame(maxWidth: 760)
            .padding(.horizontal, 32)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity)
        }
        .background(cardColor)
        .confirmationDialog("Clear history for “\(space.name)”?", isPresented: $confirmingClear) {
            Button("Clear History", role: .destructive) { store.clearHistory(for: space.id) }
        } message: {
            Text("Other spaces aren't affected.")
        }
    }

    private func header(_ space: Space) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("History").font(.system(size: 28, weight: .bold))
                Spacer()
                Menu {
                    ForEach(store.spaces) { option in
                        Button(option.name, systemImage: option.symbol) { spaceID = option.id }
                    }
                } label: {
                    Text(space.name).font(.system(size: 13, weight: .medium)).foregroundStyle(space.color)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Show another space's history")
                Button("Clear History…") { confirmingClear = true }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 12)
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search history", text: $query).textFieldStyle(.plain)
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .padding(.top, 36)
        .padding(.horizontal, 10)
    }

    private func dayTitle(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return "Today" }
        if Calendar.current.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(date: .complete, time: .omitted)
    }
}

private struct HistoryPageRow: View {
    @Environment(BrowserStore.self) private var store
    let entry: HistoryEntry
    let tab: BrowserTab
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 12) {
            Text(entry.lastVisited.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 58, alignment: .leading)
            FaviconView(url: nil, page: entry.url, size: 16)
            Text(entry.title.isEmpty ? entry.url.absoluteString : entry.title)
                .font(.system(size: 13))
                .lineLimit(1)
            Spacer(minLength: 12)
            Text(URLInput.displayHost(entry.url) ?? "")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Button { store.deleteHistory(entry) } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).frame(width: 18, height: 18)
            }
            .buttonStyle(.borderless)
            .opacity(isHovering ? 1 : 0)
            .help("Delete from History")
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(isHovering ? Color.primary.opacity(0.05) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture {
            if NSEvent.modifierFlags.contains(.command) {
                store.newTab(url: entry.url, in: tab.spaceID, after: tab, select: false)
            } else {
                tab.load(entry.url)
            }
        }
        .contextMenu {
            Button("Open in New Tab") { store.newTab(url: entry.url, in: tab.spaceID, after: tab) }
            Button("Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.url.absoluteString, forType: .string)
            }
            Divider()
            Button("Delete from History") { store.deleteHistory(entry) }
        }
    }
}
