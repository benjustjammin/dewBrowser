import Foundation

/// A named set of tabs in one space, shown together like Dia's: a tray around them in the top strip (a
/// labelled section in the sidebar), collapsible. A group's tabs are kept next to each other in the tab order.
struct TabGroup: Codable, Identifiable, Equatable {
    var id = UUID()
    let spaceID: UUID
    var name: String
    var isCollapsed = false
    var tabIDs: [UUID]
}

extension BrowserStore {
    func group(containing tabID: UUID) -> TabGroup? {
        groups.first { $0.tabIDs.contains(tabID) }
    }

    func groups(in spaceID: UUID) -> [TabGroup] {
        groups.filter { $0.spaceID == spaceID }
    }

    /// Puts `tabs` (with any split partners) in a new group, next to the first of them, and returns its ID.
    /// Unnamed groups are called "Group 1", "Group 2"… like Dia's; rename from the group's menu.
    @discardableResult
    func newGroup(with tabs: [BrowserTab], name: String? = nil) -> UUID? {
        let members = withSplitPartners(tabs)
        guard let first = members.first else { return nil }
        let taken = Set(groups(in: first.spaceID).map(\.name))
        let number = (1...).first { !taken.contains("Group \($0)") } ?? 1
        let group = TabGroup(spaceID: first.spaceID, name: name ?? "Group \(number)", tabIDs: [])
        groups.append(group)
        for tab in members { add(tab, to: group.id) }
        return group.id
    }

    /// Opens a link in a new background tab in `source`'s group (making one with both tabs if it has none):
    /// middle-click with "Add to the tab's group" on.
    func openInGroup(_ url: URL, from source: BrowserTab) {
        let tab = newTab(url: url, in: source.spaceID, after: source, select: false)
        guard !source.isPinned else { return }
        if let group = group(containing: source.id) { add(tab, to: group.id) } else { newGroup(with: [source, tab]) }
    }

    /// Moves a tab (and its split partners) into a group, after the group's last tab.
    func add(_ tab: BrowserTab, to groupID: UUID) {
        guard let target = groups.first(where: { $0.id == groupID }), target.spaceID == tab.spaceID else { return }
        for member in withSplitPartners([tab]) where !target.tabIDs.contains(member.id) {
            detachFromGroup(member)
            if member.isPinned { member.isPinned = false }
            guard let index = groups.firstIndex(where: { $0.id == groupID }) else { return }
            if let lastID = groups[index].tabIDs.last, let last = tabs.first(where: { $0.id == lastID }) { place(member, after: last) }
            groups[index].tabIDs.append(member.id)
        }
        setNeedsSave()
    }

    /// Takes a tab (and its split partners) out of its group, placing it just after the group.
    func removeFromGroup(_ tab: BrowserTab) {
        guard let group = group(containing: tab.id) else { return }
        let lastOfGroup = group.tabIDs.last.flatMap { id in tabs.first { $0.id == id } }
        for member in withSplitPartners([tab]) {
            detachFromGroup(member)
            if let lastOfGroup, lastOfGroup !== member { place(member, after: lastOfGroup) }
        }
        setNeedsSave()
    }

    /// Dissolves a group; its tabs stay where they are.
    func ungroup(_ groupID: UUID) {
        groups.removeAll { $0.id == groupID }
        setNeedsSave()
    }

    /// Closes every tab in a group (and so the group).
    func closeGroup(_ groupID: UUID) {
        guard let group = groups.first(where: { $0.id == groupID }) else { return }
        for id in group.tabIDs { if let tab = tabs.first(where: { $0.id == id }) { close(tab) } }
    }

    func updateGroup(_ groupID: UUID, _ change: (inout TabGroup) -> Void) {
        guard let index = groups.firstIndex(where: { $0.id == groupID }) else { return }
        change(&groups[index])
        setNeedsSave()
    }

    /// Whether a tab is hidden in a collapsed group (the selected tab never is).
    func isHiddenInCollapsedGroup(_ tab: BrowserTab) -> Bool {
        guard let group = group(containing: tab.id), group.isCollapsed else { return false }
        return !isSelected(tab)
    }

    // MARK: Housekeeping (called from the tab code)

    /// After a drag: a tab dropped among a group's tabs joins it; dropped elsewhere, it leaves its group.
    func regroupAfterMove(_ tab: BrowserTab, before target: BrowserTab) {
        let destination = group(containing: target.id)
        guard destination?.id != group(containing: tab.id)?.id else { return }
        detachFromGroup(tab)
        if let destination, !tab.isPinned, let index = groups.firstIndex(where: { $0.id == destination.id }) {
            let position = groups[index].tabIDs.firstIndex(of: target.id) ?? groups[index].tabIDs.endIndex
            groups[index].tabIDs.insert(tab.id, at: position)
        }
    }

    /// Removes a tab from its group; a group it leaves empty goes too (other empty groups, like one just
    /// being made, are left alone).
    func detachFromGroup(_ tab: BrowserTab) {
        guard let index = groups.firstIndex(where: { $0.tabIDs.contains(tab.id) }) else { return }
        groups[index].tabIDs.removeAll { $0 == tab.id }
        if groups[index].tabIDs.isEmpty { groups.remove(at: index) }
    }

    private func withSplitPartners(_ list: [BrowserTab]) -> [BrowserTab] {
        var result: [BrowserTab] = []
        for tab in list {
            let ids = split(containing: tab.id)?.tabIDs ?? [tab.id]
            for id in ids { if let member = tabs.first(where: { $0.id == id }), !result.contains(member) { result.append(member) } }
        }
        return result
    }
}
