import Foundation

/// A tool call the model made, in a provider-neutral form.
struct ChatToolCall {
    let id: String
    let name: String
    /// Parsed arguments; nil if the model's JSON didn't parse.
    let arguments: [String: Any]?
    /// The raw JSON text of the arguments, as the model produced it.
    let argumentsJSON: String
}

/// The answer Dew sends back for one tool call.
struct ChatToolResult {
    let callID: String
    let name: String
    let content: String
    let isError: Bool
}

/// Something Chat did in the browser, shown in the conversation (with Undo where it makes sense).
struct ChatAction: Identifiable {
    enum Kind { case opened, closed, switched, read, searched, split, grouped, failed }
    let id = UUID()
    let kind: Kind
    let text: String
    /// Tab to show when the row is clicked (opened / switched / read).
    var tabID: UUID?
    /// Closed tabs, for Undo.
    var closedRecords: [TabRecord] = []
    var undone = false

    var symbol: String {
        switch kind {
        case .opened: "plus.square.on.square"
        case .closed: "xmark.square"
        case .switched: "arrow.right.square"
        case .read: "doc.text.magnifyingglass"
        case .searched: "clock.arrow.circlepath"
        case .split: "rectangle.split.2x1"
        case .grouped: "folder"
        case .failed: "exclamationmark.triangle"
        }
    }
}

/// The browser actions Chat can take: list, read, open, close and switch tabs, search history and
/// bookmarks, and show tabs side by side. Tabs are named to the model by a short ID (the first 8
/// characters of the tab's UUID).
@MainActor
enum ChatTools {
    struct Spec {
        let name: String
        let description: String
        let parameters: [String: Any]
    }

    static let specs: [Spec] = [
        Spec(name: "list_tabs",
             description: "List the user's open tabs: ID, title, URL, space, and whether each is the current tab, pinned, or shared in this chat. Call this before acting on tabs you haven't been given IDs for.",
             parameters: object([:], required: [])),
        Spec(name: "read_tab",
             description: "Read the visible text of an open tab (loading it first if needed). Use when the user asks about a tab that isn't already shared in the conversation.",
             parameters: object(["tab_id": string("The tab's ID from list_tabs.")], required: ["tab_id"])),
        Spec(name: "open_tab",
             description: "Open a web address, or search the web for some words, in a new tab. By default the new tab is shown; set background to true to open it without switching to it (for example when opening several).",
             parameters: object([
                "url": string("A full URL, a domain like example.com, or search words."),
                "background": ["type": "boolean", "description": "Open without switching to it. Defaults to false."],
             ], required: ["url"])),
        Spec(name: "close_tabs",
             description: "Close one or more tabs. The user can undo this from the chat.",
             parameters: object(["tab_ids": ["type": "array", "items": ["type": "string"], "description": "IDs from list_tabs."]], required: ["tab_ids"])),
        Spec(name: "switch_to_tab",
             description: "Show an open tab (switching space if it's in another one).",
             parameters: object(["tab_id": string("The tab's ID from list_tabs.")], required: ["tab_id"])),
        Spec(name: "search_history",
             description: "Search the user's browsing history and bookmarks in the current space by words in the title or address. Returns the most recent matches.",
             parameters: object([
                "query": string("Words to look for. Empty returns the most recent pages."),
                "limit": ["type": "integer", "description": "Most results to return (default 15, at most 50)."],
             ], required: ["query"])),
        Spec(name: "group_tabs",
             description: "Put tabs in a named tab group (shown together and collapsible). Use for requests like 'group my shopping tabs'. Tabs already in another group move to this one.",
             parameters: object([
                "tab_ids": ["type": "array", "items": ["type": "string"], "description": "IDs from list_tabs, all in the same space."],
                "name": string("A short name for the group, like 'Shopping' or 'Trip'."),
             ], required: ["tab_ids", "name"])),
        Spec(name: "show_side_by_side",
             description: "Show 2 to 4 tabs from the same space side by side in split view.",
             parameters: object(["tab_ids": ["type": "array", "items": ["type": "string"], "description": "2 to 4 tab IDs from list_tabs, in left-to-right order."]], required: ["tab_ids"])),
    ]

    private static func object(_ properties: [String: Any], required: [String]) -> [String: Any] {
        ["type": "object", "properties": properties, "required": required, "additionalProperties": false]
    }

    private static func string(_ description: String) -> [String: Any] {
        ["type": "string", "description": description]
    }

    static func shortID(_ tab: BrowserTab) -> String { String(tab.id.uuidString.lowercased().prefix(8)) }

    /// Tabs Chat may see and act on: private tabs only while you're in private browsing.
    private static func visibleTabs(_ store: BrowserStore) -> [BrowserTab] {
        store.tabs.filter { store.isPrivate || !store.isPrivate($0.spaceID) }
    }

    private static func tab(_ id: Any?, in store: BrowserStore) -> BrowserTab? {
        guard let id = (id as? String)?.lowercased().trimmingCharacters(in: .whitespaces), id.count >= 4 else { return nil }
        return visibleTabs(store).first { $0.id.uuidString.lowercased().hasPrefix(id) }
    }

    private static func spaceName(_ spaceID: UUID, in store: BrowserStore) -> String {
        store.isPrivate(spaceID) ? "Private" : store.spaces.first { $0.id == spaceID }?.name ?? "?"
    }

    /// Runs one tool call. Returns what to tell the model and, for visible changes, an action to show.
    static func run(_ call: ChatToolCall, store: BrowserStore, sharedTabIDs: Set<UUID>) async -> (ChatToolResult, ChatAction?) {
        func fail(_ message: String) -> (ChatToolResult, ChatAction?) {
            (ChatToolResult(callID: call.id, name: call.name, content: message, isError: true), nil)
        }
        func ok(_ content: String, _ action: ChatAction? = nil) -> (ChatToolResult, ChatAction?) {
            (ChatToolResult(callID: call.id, name: call.name, content: content, isError: false), action)
        }
        guard let args = call.arguments else { return fail("The arguments weren't valid JSON. Try the call again.") }

        switch call.name {
        case "list_tabs":
            let current = store.selectedTab
            let lines = store.spaces.map(\.id).appending(BrowserStore.privateSpaceID).flatMap { spaceID in
                store.orderedTabs(in: spaceID).filter { visibleTabs(store).contains($0) }.map { tab in
                    var flags: [String] = []
                    if tab === current { flags.append("current") }
                    if tab.isPinned { flags.append("pinned") }
                    if sharedTabIDs.contains(tab.id) { flags.append("shared in chat") }
                    if let group = store.group(containing: tab.id) { flags.append("group: \(group.name)") }
                    return "\(shortID(tab)) | \(tab.displayTitle) | \(tab.url?.absoluteString ?? "new tab page") | space: \(spaceName(spaceID, in: store))"
                        + (flags.isEmpty ? "" : " | " + flags.joined(separator: ", "))
                }
            }
            return ok(lines.isEmpty ? "No tabs are open." : "id | title | url | space | flags\n" + lines.joined(separator: "\n"))

        case "read_tab":
            guard let tab = tab(args["tab_id"], in: store) else { return fail("No open tab has that ID. Call list_tabs for current IDs.") }
            guard let page = await tab.readPage() else { return fail("That tab is on the new tab page; there's nothing to read.") }
            var text = page.text.isEmpty ? "(No readable text on this page.)" : page.text
            if page.truncated { text += "\n\n[Page text cut off here: it was longer than \(BrowserTab.maxPageCharacters.formatted()) characters.]" }
            let action = ChatAction(kind: .read, text: "Read “\(tab.displayTitle)”", tabID: tab.id)
            return ok("<tab title=\"\(page.title)\" url=\"\(page.url?.absoluteString ?? "")\">\n\(text)\n</tab>", action)

        case "open_tab":
            guard let input = args["url"] as? String, let resolved = URLInput.resolve(input) else { return fail("Give a URL, a domain, or search words.") }
            let background = args["background"] as? Bool ?? false
            let anchor = store.selectedTab
            let tab = store.newTab(url: resolved.url, in: anchor?.spaceID, after: anchor, select: !background)
            let label = resolved.isSearch ? "Searched for “\(input)”" : "Opened \(URLInput.displayHost(resolved.url) ?? resolved.url.absoluteString)"
            return ok("Opened tab \(shortID(tab))\(background ? " in the background" : "") at \(resolved.url.absoluteString).",
                      ChatAction(kind: .opened, text: label + (background ? " in the background" : ""), tabID: tab.id))

        case "close_tabs":
            guard let ids = args["tab_ids"] as? [Any], !ids.isEmpty else { return fail("Give at least one tab ID.") }
            let targets = ids.compactMap { tab($0, in: store) }
            guard !targets.isEmpty else { return fail("None of those IDs match an open tab. Call list_tabs for current IDs.") }
            let records = targets.map(\.record)
            for tab in targets { store.close(tab) }
            let missing = ids.count - targets.count
            let text = targets.count == 1 ? "Closed “\(targets[0].displayTitle)”" : "Closed \(targets.count) tabs"
            return ok("Closed \(targets.count) tab\(targets.count == 1 ? "" : "s")." + (missing > 0 ? " \(missing) ID(s) didn't match an open tab." : ""),
                      ChatAction(kind: .closed, text: text, closedRecords: records))

        case "switch_to_tab":
            guard let tab = tab(args["tab_id"], in: store) else { return fail("No open tab has that ID. Call list_tabs for current IDs.") }
            store.select(tab)
            return ok("Now showing \(shortID(tab)).", ChatAction(kind: .switched, text: "Switched to “\(tab.displayTitle)”", tabID: tab.id))

        case "search_history":
            let query = args["query"] as? String ?? ""
            let limit = min(max((args["limit"] as? NSNumber)?.intValue ?? 15, 1), 50)
            let spaceID = store.isPrivate ? (store.spaces.first?.id ?? store.selectedSpaceID) : store.selectedSpaceID
            let bookmarks = store.bookmarks.filter { $0.spaceID == spaceID }.filter {
                query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.url.absoluteString.localizedCaseInsensitiveContains(query)
            }.prefix(limit)
            let history = store.history(in: spaceID, matching: query, limit: limit)
            let formatter = Date.FormatStyle(date: .abbreviated, time: .shortened)
            var lines = bookmarks.map { "bookmark | \($0.title) | \($0.url.absoluteString)" }
            lines += history.map { "history | \($0.title.isEmpty ? "(untitled)" : $0.title) | \($0.url.absoluteString) | last visited \($0.lastVisited.formatted(formatter)) | \($0.visitCount) visits" }
            let label = query.isEmpty ? "Looked at recent history" : "Searched history for “\(query)”"
            return ok(lines.isEmpty ? "Nothing in history or bookmarks matches." : lines.joined(separator: "\n"), ChatAction(kind: .searched, text: label))

        case "group_tabs":
            guard let ids = args["tab_ids"] as? [Any], let name = (args["name"] as? String)?.trimmingCharacters(in: .whitespaces) else {
                return fail("Give tab IDs and a name.")
            }
            let targets = ids.compactMap { tab($0, in: store) }.filter { !$0.isPinned }
            guard !targets.isEmpty else { return fail("None of those IDs match an unpinned open tab. Call list_tabs for current IDs.") }
            guard Set(targets.map(\.spaceID)).count == 1 else { return fail("A group's tabs must be in the same space.") }
            store.newGroup(with: targets, name: name.isEmpty ? nil : name)
            return ok("Grouped \(targets.count) tab\(targets.count == 1 ? "" : "s") as “\(name)”.",
                      ChatAction(kind: .grouped, text: "Grouped \(targets.count) tab\(targets.count == 1 ? "" : "s") as “\(name)”", tabID: targets[0].id))

        case "show_side_by_side":
            guard let ids = args["tab_ids"] as? [Any] else { return fail("Give 2 to 4 tab IDs.") }
            let targets = ids.compactMap { tab($0, in: store) }
            guard (2...4).contains(targets.count) else { return fail("Give 2 to 4 IDs of open tabs.") }
            guard Set(targets.map(\.spaceID)).count == 1 else { return fail("Tabs shown side by side must be in the same space.") }
            for tab in targets.dropFirst() where tab.isPinned { store.togglePin(tab) }
            if targets[0].isPinned { store.togglePin(targets[0]) }
            for (anchor, tab) in zip(targets, targets.dropFirst()) { store.addToSplit(tab, beside: anchor) }
            store.select(targets[0])
            return ok("Showing \(targets.count) tabs side by side.",
                      ChatAction(kind: .split, text: "Showed \(targets.count) tabs side by side", tabID: targets[0].id))

        default:
            return fail("Unknown tool \(call.name).")
        }
    }
}

private extension Array {
    func appending(_ element: Element) -> [Element] { self + [element] }
}
