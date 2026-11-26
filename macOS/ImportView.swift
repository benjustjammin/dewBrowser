import SwiftUI

/// File → Import from Dia…: pick Dia's data folder (the sandbox needs your permission), then choose
/// which Dia profiles go into which spaces and what to bring over.
struct ImportView: View {
    @Environment(BrowserStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    private struct Choice {
        var include = true
        var destination: UUID?   // nil = new space named after the profile
        var bookmarks = true
        var history = true
    }

    @State private var profiles: [DiaImporter.Profile] = []
    @State private var choices: [String: Choice] = [:]
    @State private var hasFolder = false
    @State private var isImporting = false
    @State private var summary: String?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "square.and.arrow.down.on.square")
                    .font(.system(size: 22))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Import from Dia").font(.headline)
                    Text("Bookmarks and history, one Dia profile per space.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            if let summary {
                Label(summary, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !hasFolder {
                Text("Dew needs your permission to read Dia's data. Choose Dia's “User Data” folder; it's already selected in the panel.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                if let error {
                    Text(error).font(.callout).foregroundStyle(.red)
                }
            } else {
                Form {
                    ForEach(profiles) { profile in
                        Section {
                            Toggle("Import “\(profile.name)”", isOn: choice(profile.id, \.include))
                            if choices[profile.id]?.include == true {
                                Picker("Into", selection: choice(profile.id, \.destination)) {
                                    Text("New space “\(profile.name)”").tag(UUID?.none)
                                    ForEach(store.spaces) { Text($0.name).tag(UUID?.some($0.id)) }
                                }
                                Toggle("Bookmarks bar (\(profile.bookmarkCount))", isOn: choice(profile.id, \.bookmarks))
                                Toggle("History", isOn: choice(profile.id, \.history))
                            }
                        }
                    }
                }
                .formStyle(.grouped)
                .frame(height: min(CGFloat(profiles.count) * 150, 420))

                Text("Cookies and passwords can't be imported: Dia encrypts them with a key only Dia can read.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                if summary != nil {
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    if hasFolder {
                        Button(isImporting ? "Importing…" : "Import") { Task { await runImport() } }
                            .keyboardShortcut(.defaultAction)
                            .disabled(isImporting || !choices.values.contains { $0.include })
                    } else {
                        Button("Choose Dia Folder…") { chooseFolder() }
                            .keyboardShortcut(.defaultAction)
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func choice<Value>(_ id: String, _ keyPath: WritableKeyPath<Choice, Value>) -> Binding<Value> {
        Binding {
            (choices[id] ?? Choice())[keyPath: keyPath]
        } set: {
            choices[id, default: Choice()][keyPath: keyPath] = $0
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = DiaImporter.defaultDataFolder
        panel.prompt = "Allow"
        panel.message = "Choose Dia's “User Data” folder so Dew can read your bookmarks and history."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        _ = url.startAccessingSecurityScopedResource()
        let found = DiaImporter.profiles(in: url)
        guard !found.isEmpty else {
            error = "No Dia profiles found in that folder. Choose “User Data” inside Library/Application Support/Dia."
            return
        }
        profiles = found
        for profile in found {
            // Match a space with the same name; otherwise create a new one.
            let match = store.spaces.first { $0.name.localizedCaseInsensitiveCompare(profile.name) == .orderedSame }
            choices[profile.id] = Choice(destination: match?.id)
        }
        hasFolder = true
    }

    private func runImport() async {
        isImporting = true
        var totalBookmarks = 0
        var totalHistory = 0
        var spaceNames: [String] = []
        for profile in profiles {
            guard let choice = choices[profile.id], choice.include else { continue }
            var data = await Task.detached(priority: .userInitiated) { DiaImporter.load(profile) }.value
            if !choice.bookmarks { data.bookmarks = [] }
            if !choice.history { data.history = [] }
            let result = store.importData(data, into: choice.destination, newSpaceName: profile.name)
            totalBookmarks += result.bookmarks
            totalHistory += result.history
            spaceNames.append(choice.destination.flatMap { id in store.spaces.first { $0.id == id }?.name } ?? profile.name)
        }
        store.saveNow()
        isImporting = false
        summary = "Imported \(totalBookmarks.formatted()) bookmarks and \(totalHistory.formatted()) history items into \(ListFormatter.localizedString(byJoining: spaceNames))."
    }
}
