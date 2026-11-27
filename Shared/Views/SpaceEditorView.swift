import SwiftUI

struct SpaceEditorView: View {
    @Environment(BrowserStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State var space: Space
    let isNew: Bool
    @State private var confirmingDelete = false
    @State private var confirmingClearHistory = false

    init(state: SpaceEditorState) {
        _space = State(initialValue: state.space)
        isNew = state.isNew
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                SpaceBadge(space: space, size: 40)
                TextField("Space name", text: $space.name)
                    .textFieldStyle(.plain)
                    .font(.title2.weight(.semibold))
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Color").font(.subheadline).foregroundStyle(.secondary)
                // Colours, then the quiet greys and black.
                ForEach([Space.colours, Space.neutrals], id: \.self) { row in
                    HStack(spacing: 10) {
                        ForEach(row, id: \.self) { hex in
                            Circle().fill(Color(hex: hex).gradient)
                                .overlay(Circle().strokeBorder(.primary.opacity(0.15)))
                                .frame(width: 26, height: 26)
                                .overlay { if hex == space.colorHex { Circle().strokeBorder(.white, lineWidth: 2.5).padding(2) } }
                                .onTapGesture { space.colorHex = hex }
                                .accessibilityLabel(Space.colourName(hex))
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Icon").font(.subheadline).foregroundStyle(.secondary)
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(34), spacing: 8), count: 6), alignment: .leading, spacing: 8) {
                    ForEach(Space.symbols, id: \.self) { symbol in
                        Image(systemName: symbol)
                            .frame(width: 34, height: 34)
                            .background(symbol == space.symbol ? space.color.opacity(0.25) : Color.secondary.opacity(0.1),
                                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .onTapGesture { space.symbol = symbol }
                    }
                }
            }

            Text("Each space has its own cookies and logins, so you can be signed in to different accounts in each.")
                .font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                if !isNew {
                    Menu("More") {
                        Button("Clear History") { confirmingClearHistory = true }
                        if store.spaces.count > 1 {
                            Button("Delete Space…", role: .destructive) { confirmingDelete = true }
                        }
                    }
                    .fixedSize()
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Create" : "Save") {
                    store.save(space)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(space.color)
                .disabled(space.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        #if os(macOS)
        .frame(width: 380)
        #endif
        .confirmationDialog("Delete “\(space.name)”?", isPresented: $confirmingDelete) {
            Button("Delete Space", role: .destructive) {
                store.delete(space)
                dismiss()
            }
        } message: {
            Text("Its tabs and history are removed and you'll be signed out of every site in this space.")
        }
        .confirmationDialog("Clear history for “\(space.name)”?", isPresented: $confirmingClearHistory) {
            Button("Clear History", role: .destructive) { store.clearHistory(for: space.id) }
        }
    }
}
