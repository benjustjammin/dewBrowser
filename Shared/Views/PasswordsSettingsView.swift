import SwiftUI
import LocalAuthentication
import UniformTypeIdentifiers

struct PasswordsSettingsView: View {
    @Environment(BrowserStore.self) private var store
    @State private var isUnlocked = false
    @State private var query = ""
    @State private var revealed: Set<UUID> = []
    @State private var importSpaceID: UUID?
    @State private var isPickingFile = false
    @State private var importResult: String?
    @State private var importedFile: URL?
    @State private var pendingDelete: SavedLogin?

    var body: some View {
        let passwords = store.passwords
        Form {
            Section {
                Picker("Import into", selection: Binding(get: { importSpaceID ?? store.selectedSpaceID }, set: { importSpaceID = $0 })) {
                    ForEach(store.spaces) { Text($0.name).tag($0.id) }
                }
                HStack {
                    Button("Import CSV…") { isPickingFile = true }
                    Spacer()
                }
                if let importResult {
                    Label(importResult, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    if let importedFile {
                        HStack {
                            Text("The CSV isn't encrypted. Delete it now?")
                                .font(.callout).foregroundStyle(.secondary)
                            Spacer()
                            Button("Move to Trash", role: .destructive) { trash(importedFile) }
                        }
                    }
                }
            } header: {
                Text("Import")
            } footer: {
                Text("In Dia, open its password manager (Settings → Passwords) and choose Export passwords. Chrome, Safari, 1Password and Bitwarden CSV exports work too.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section {
                if passwords.isLocked {
                    Label("Your saved passwords couldn't be decrypted. Allow Dew to use its key in Keychain, then reopen Dew.",
                          systemImage: "exclamationmark.lock")
                        .foregroundStyle(.orange)
                } else if !isUnlocked {
                    HStack {
                        Label("\(passwords.logins.count) saved", systemImage: "lock.fill")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Unlock") { unlock() }
                    }
                } else {
                    TextField("Search", text: $query)
                    let visible = filtered(passwords.logins)
                    if visible.isEmpty {
                        Text(query.isEmpty ? "No saved passwords" : "No matches").foregroundStyle(.secondary)
                    }
                    ForEach(visible) { login in
                        row(login)
                    }
                }
            } header: {
                Text("Saved Passwords")
            }
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $isPickingFile, allowedContentTypes: [.commaSeparatedText, .plainText]) { result in
            guard case .success(let url) = result else { return }
            importCSV(from: url)
        }
        .confirmationDialog("Delete the password for \(pendingDelete?.username ?? "") on \(pendingDelete?.host ?? "")?",
                            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button("Delete Password", role: .destructive) {
                if let pendingDelete { store.passwords.delete(pendingDelete) }
                pendingDelete = nil
            }
        }
    }

    private func row(_ login: SavedLogin) -> some View {
        HStack(spacing: 10) {
            FaviconView(url: URL(string: "https://\(login.host)")?.faviconGuess, size: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(login.host).lineLimit(1)
                Text(login.username.isEmpty ? "No username" : login.username)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(revealed.contains(login.id) ? login.password : "••••••••")
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .textSelection(.enabled)
            Button { toggleReveal(login) } label: {
                Image(systemName: revealed.contains(login.id) ? "eye.slash" : "eye")
            }
            .help("Show password")
            Button { copy(login.password) } label: { Image(systemName: "doc.on.doc") }
                .help("Copy password")
            Button { pendingDelete = login } label: { Image(systemName: "trash") }
                .help("Delete")
            if store.spaces.count > 1 {
                Text(store.spaces.first { $0.id == login.spaceID }?.name ?? "")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.borderless)
    }

    private func filtered(_ logins: [SavedLogin]) -> [SavedLogin] {
        logins
            .filter { query.isEmpty || $0.host.localizedCaseInsensitiveContains(query) || $0.username.localizedCaseInsensitiveContains(query) }
            .sorted { ($0.host, $0.username) < ($1.host, $1.username) }
    }

    private func unlock() {
        let context = LAContext()
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "show your saved passwords") { success, _ in
            Task { @MainActor in isUnlocked = success }
        }
    }

    private func toggleReveal(_ login: SavedLogin) {
        if revealed.contains(login.id) { revealed.remove(login.id) } else { revealed.insert(login.id) }
    }

    private func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.setItems([[UTType.plainText.identifier: text]],
                                      options: [.expirationDate: Date().addingTimeInterval(90), .localOnly: true])
        #endif
    }

    private func importCSV(from url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            importResult = "Couldn't read that file."
            return
        }
        let spaceID = importSpaceID ?? store.selectedSpaceID
        let result = store.passwords.importCSV(text, into: spaceID)
        let name = store.spaces.first { $0.id == spaceID }?.name ?? "space"
        if result.added + result.updated == 0 {
            importResult = "No passwords found. Is this a password export CSV?"
            importedFile = nil
        } else {
            importResult = "Imported \(result.added) passwords into \(name)" + (result.updated > 0 ? " (\(result.updated) updated)." : ".")
            importedFile = url
        }
    }

    private func trash(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        #if os(macOS)
        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        #else
        try? FileManager.default.removeItem(at: url)
        #endif
        importedFile = nil
    }
}
