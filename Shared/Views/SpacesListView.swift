import SwiftUI

/// Add, rename, restyle, reorder and delete spaces. Order sets the ⌃1…⌃9 shortcuts.
struct SpacesListView: View {
    @Environment(BrowserStore.self) private var store

    var body: some View {
        Form {
            Section {
                ForEach(Array(store.spaces.enumerated()), id: \.element.id) { index, space in
                    SpaceRow(space: space, index: index)
                }
                .onMove { store.moveSpaces(from: $0, to: $1) }

                Button {
                    let color = Space.palette.first { hex in !store.spaces.contains { $0.colorHex == hex } } ?? Space.palette[0]
                    store.save(Space(name: "New Space", colorHex: color, symbol: "star.fill"))
                } label: {
                    Label("Add Space", systemImage: "plus")
                }
                .buttonStyle(.borderless)
            } footer: {
                Text("Each space keeps its own logins, cookies and history.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        #if os(macOS)
        .task {
            // Don't open with the first space's name selected for editing.
            try? await Task.sleep(for: .milliseconds(10))
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
        #endif
    }
}

private struct SpaceRow: View {
    @Environment(BrowserStore.self) private var store
    let space: Space
    let index: Int
    @State private var showingStyle = false
    @State private var confirmingDelete = false

    var body: some View {
        HStack(spacing: 12) {
            Button { showingStyle = true } label: {
                SpaceBadge(space: space, size: 24)
            }
            .buttonStyle(.plain)
            .help("Colour and icon")
            #if os(macOS)
            .popover(isPresented: $showingStyle, arrowEdge: .bottom) {
                SpaceStylePicker(colorHex: binding(\.colorHex), symbol: binding(\.symbol))
            }
            #else
            // A bottom sheet always fits; a popover from a row near the top got cut off.
            .sheet(isPresented: $showingStyle) {
                SpaceStylePicker(colorHex: binding(\.colorHex), symbol: binding(\.symbol))
                    .presentationDetents([.height(300)])
                    .presentationDragIndicator(.visible)
            }
            #endif

            TextField("Name", text: binding(\.name))
                .textFieldStyle(.plain)
                .labelsHidden()

            #if os(macOS)
            if index < 9 {
                Text("⌃\(index + 1)")
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
            #endif

            Menu {
                Button("Move Up") { store.moveSpaces(from: [index], to: index - 1) }
                    .disabled(index == 0)
                Button("Move Down") { store.moveSpaces(from: [index], to: index + 2) }
                    .disabled(index == store.spaces.count - 1)
                Divider()
                Button("Delete…", role: .destructive) { confirmingDelete = true }
                    .disabled(store.spaces.count < 2)
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            #if os(macOS)
            .menuIndicator(.hidden)
            #endif
            .fixedSize()
        }
        .confirmationDialog("Delete “\(space.name)”?", isPresented: $confirmingDelete) {
            Button("Delete Space", role: .destructive) { store.delete(space) }
        } message: {
            Text("Its tabs and history are removed and you'll be signed out of every site in this space.")
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<Space, Value>) -> Binding<Value> {
        Binding {
            store.spaces.first { $0.id == space.id }?[keyPath: keyPath] ?? space[keyPath: keyPath]
        } set: { value in
            var updated = store.spaces.first { $0.id == space.id } ?? space
            updated[keyPath: keyPath] = value
            store.save(updated)
        }
    }
}

/// Colour swatches and an icon grid (touch-sized and centred on iOS).
struct SpaceStylePicker: View {
    @Binding var colorHex: String
    @Binding var symbol: String

    #if os(iOS)
    private let swatch: CGFloat = 30, tile: CGFloat = 40, gap: CGFloat = 10
    #else
    private let swatch: CGFloat = 22, tile: CGFloat = 30, gap: CGFloat = 6
    #endif

    var body: some View {
        VStack(spacing: 14) {
            // Colours, then the quiet greys and black.
            ForEach([Space.colours, Space.neutrals], id: \.self) { row in
                HStack(spacing: gap) {
                    ForEach(row, id: \.self) { hex in
                        Circle()
                            .fill(Color(hex: hex).gradient)
                            .overlay(Circle().strokeBorder(.primary.opacity(0.15)))
                            .frame(width: swatch, height: swatch)
                            .overlay {
                                if hex == colorHex {
                                    Circle().strokeBorder(.white, lineWidth: 2.5).padding(2.5)
                                }
                            }
                            .contentShape(Circle())
                            .onTapGesture { colorHex = hex }
                            .accessibilityLabel(Space.colourName(hex))
                    }
                }
            }
            Divider()
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(tile), spacing: gap), count: 6), spacing: gap) {
                ForEach(Space.symbols, id: \.self) { name in
                    Image(systemName: name)
                        .font(.system(size: tile * 0.42))
                        .frame(width: tile, height: tile)
                        .foregroundStyle(name == symbol ? .white : .secondary)
                        .background(name == symbol ? AnyShapeStyle(Color(hex: colorHex).gradient) : AnyShapeStyle(.quaternary.opacity(0.5)),
                                    in: RoundedRectangle(cornerRadius: tile * 0.24, style: .continuous))
                        .contentShape(Rectangle())
                        .onTapGesture { symbol = name }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
    }
}
