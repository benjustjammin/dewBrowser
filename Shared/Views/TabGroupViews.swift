import SwiftUI

/// Renames a group (from its menu). Return or clicking away closes it.
struct GroupRenamer: View {
    @Environment(BrowserStore.self) private var store
    let groupID: UUID
    @FocusState private var focused: Bool

    var body: some View {
        if let group = store.groups.first(where: { $0.id == groupID }) {
            TextField("Group name", text: Binding(get: { group.name },
                                                 set: { name in store.updateGroup(groupID) { $0.name = name } }))
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { store.editingGroupID = nil }
                .padding(12)
                .frame(width: 220)
                .onAppear { focused = true }
        }
    }
}

/// A group's context menu (its label in the top strip or sidebar).
struct GroupMenu: View {
    @Environment(BrowserStore.self) private var store
    let group: TabGroup

    var body: some View {
        Button(group.isCollapsed ? "Expand Group" : "Collapse Group") { store.updateGroup(group.id) { $0.isCollapsed.toggle() } }
        Button("Rename Group…") { store.editingGroupID = group.id }
        Button("New Tab in Group") {
            let tab = store.newTab(url: nil, in: group.spaceID)
            store.add(tab, to: group.id)
        }
        Divider()
        Button("Ungroup") { store.ungroup(group.id) }
        Button("Close Group") { store.closeGroup(group.id) }
    }
}

/// The group items in a tab's context menu.
struct TabGroupMenuItems: View {
    @Environment(BrowserStore.self) private var store
    let tab: BrowserTab

    var body: some View {
        if store.group(containing: tab.id) != nil {
            Button("Remove from Group") { store.removeFromGroup(tab) }
        } else if !tab.isPinned {
            Button("Add to New Group") { store.newGroup(with: [tab]) }
            let existing = store.groups(in: tab.spaceID)
            if !existing.isEmpty {
                Menu("Add to Group") {
                    ForEach(existing) { group in Button(group.name) { store.add(tab, to: group.id) } }
                }
            }
        }
    }
}

/// Dia's group label: a small stack glyph and the name. Click to collapse or expand; right-click for the menu.
struct GroupLabel: View {
    @Environment(BrowserStore.self) private var store
    let group: TabGroup

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "rectangle.stack.fill")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(group.name.isEmpty ? "Group" : group.name)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            if group.isCollapsed {
                Text("\(group.tabIDs.count)").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.snappy(duration: 0.2)) { store.updateGroup(group.id) { $0.isCollapsed.toggle() } } }
        .contextMenu { GroupMenu(group: group) }
        .help(group.isCollapsed ? "Click to show this group's tabs" : "Click to collapse this group")
        .popover(isPresented: Binding(get: { store.editingGroupID == group.id },
                                      set: { if !$0 && store.editingGroupID == group.id { store.editingGroupID = nil } })) {
            GroupRenamer(groupID: group.id)
        }
    }

    /// Roughly how wide the label is, for sizing the tabs around it.
    static func width(for group: TabGroup) -> CGFloat {
        CGFloat(min(group.name.count, 18)) * 7.5 + 46 + (group.isCollapsed ? 16 : 0)
    }
}

/// The soft tray around a group's tabs (the same look as the space pill). Fill and edge both sit behind the tabs,
/// so the active tab covers the tray where it crosses it and flows into the page, like Dia's.
struct GroupTray: ViewModifier {
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        content.background {
            shape.fill(.primary.opacity(0.035))
                .overlay(shape.strokeBorder(.primary.opacity(0.13), lineWidth: 1))
        }
    }
}
