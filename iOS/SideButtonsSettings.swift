import SwiftUI

/// Where a set of browser buttons lives: the iPhone Duo's side column, or the iPhone's bottom bar.
/// Which buttons show there, and their order, is up to you (Settings → Appearance & Layout).
enum ButtonPlacement {
    case side, bottom

    var defaultsKey: String { self == .side ? "duoSideButtons" : "bottomBarButtons" }
    var defaultValue: String {
        SideButton.encode(self == .side ? [.back, .forward, .reload, .tabs, .newTab, .chat, .space, .more]
                                        : [.back, .forward, .space, .tabs, .more])
    }
    var title: String { self == .side ? "Side Buttons" : "Bottom Bar Buttons" }
    /// The bottom bar has room for six; the side column for more.
    var maxCount: Int { self == .side ? 9 : 6 }
}

/// A browser button that can go in the Duo's side column or the iPhone's bottom bar.
enum SideButton: String, CaseIterable, Identifiable {
    case back, forward, reload, tabs, newTab, chat, bookmark, share, space, settings, more

    static let defaultsKey = ButtonPlacement.side.defaultsKey
    static let defaultValue = ButtonPlacement.side.defaultValue

    var id: String { rawValue }

    var title: String {
        switch self {
        case .back: "Back"
        case .forward: "Forward"
        case .reload: "Reload"
        case .tabs: "Tabs"
        case .newTab: "New Tab"
        case .chat: "Chat"
        case .bookmark: "Bookmark"
        case .share: "Share"
        case .space: "Space"
        case .settings: "Settings"
        case .more: "More (⋯)"
        }
    }

    var symbol: String {
        switch self {
        case .back: "chevron.backward"
        case .forward: "chevron.forward"
        case .reload: "arrow.clockwise"
        case .tabs: "square.on.square"
        case .newTab: "plus"
        case .chat: "sparkles"
        case .bookmark: "star"
        case .share: "square.and.arrow.up"
        case .space: "person.crop.circle"
        case .settings: "gearshape"
        case .more: "ellipsis.circle"
        }
    }

    static func decode(_ value: String) -> [SideButton] {
        var seen = Set<SideButton>()
        return value.split(separator: ",").compactMap { SideButton(rawValue: String($0)) }.filter { seen.insert($0).inserted }
    }

    static func encode(_ buttons: [SideButton]) -> String { buttons.map(\.rawValue).joined(separator: ",") }
}

/// Choose and arrange a set of buttons: drag to reorder, − to remove, + to add.
struct SideButtonsSettingsView: View {
    let placement: ButtonPlacement
    @AppStorage private var saved: String

    init(placement: ButtonPlacement = .side) {
        self.placement = placement
        _saved = AppStorage(wrappedValue: placement.defaultValue, placement.defaultsKey)
    }

    var body: some View {
        let shown = SideButton.decode(saved)
        let hidden = SideButton.allCases.filter { !shown.contains($0) }
        List {
            Section {
                ForEach(shown) { button in
                    row(button)
                        // Keep a way into Settings: either ⋯ or the cog has to stay.
                        .deleteDisabled(isLastWayToSettings(button, in: shown))
                }
                .onMove { from, to in
                    var buttons = shown
                    buttons.move(fromOffsets: from, toOffset: to)
                    saved = SideButton.encode(buttons)
                }
                .onDelete { offsets in
                    var buttons = shown
                    buttons.remove(atOffsets: offsets)
                    saved = SideButton.encode(buttons)
                }
            } header: {
                Text("Shown")
            } footer: {
                Text("Drag to reorder. Swiping back and forward on the page also goes back and forward. Either More (⋯) or Settings always stays, so you can get to Settings."
                     + (placement == .bottom ? " The bottom bar holds up to \(placement.maxCount) buttons." : ""))
            }
            if !hidden.isEmpty {
                Section(shown.count >= placement.maxCount ? "More Buttons (remove one to add another)" : "More Buttons") {
                    ForEach(hidden) { button in
                        HStack(spacing: 12) {
                            Button {
                                saved = SideButton.encode(shown + [button])
                            } label: {
                                Image(systemName: "plus.circle.fill")
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, .green)
                                    .font(.title3)
                            }
                            .buttonStyle(.plain)
                            .disabled(shown.count >= placement.maxCount)
                            .opacity(shown.count >= placement.maxCount ? 0.35 : 1)
                            .accessibilityLabel("Add \(button.title)")
                            row(button)
                        }
                    }
                }
            }
            Section {
                Button("Reset to Default") { saved = placement.defaultValue }
            }
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle(placement.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ button: SideButton) -> some View {
        Label {
            Text(button.title)
        } icon: {
            Image(systemName: button.symbol).foregroundStyle(.tint)
        }
    }

    private func isLastWayToSettings(_ button: SideButton, in shown: [SideButton]) -> Bool {
        (button == .more && !shown.contains(.settings)) || (button == .settings && !shown.contains(.more))
    }
}
