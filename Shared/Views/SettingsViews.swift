import SwiftUI

struct GeneralSettingsView: View {
    @Environment(BrowserStore.self) private var store
    @AppStorage(SearchEngine.defaultsKey) private var searchEngine = SearchEngine.google.rawValue

    var body: some View {
        @Bindable var store = store
        Form {
            Section {
                LabeledContent("Default browser") {
                    if store.defaultBrowser.isDefault == true {
                        Label("Dew", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Make Dew the Default") { store.defaultBrowser.makeDefault() }
                    }
                }
            } footer: {
                #if os(iOS)
                Text("Opens Settings, where you choose Default Browser App. Dew is listed there once Apple approves its browser entitlement.")
                    .font(.footnote).foregroundStyle(.secondary)
                #endif
            }
            Section {
                Picker("Search engine", selection: $searchEngine) {
                    ForEach(SearchEngine.allCases) { Text($0.name).tag($0.rawValue) }
                }
                Toggle("Search engine suggestions", isOn: $store.searchSuggestionsEnabled)
            }
            Section {
                Picker("Suspend unused tabs", selection: $store.tabSuspension) {
                    ForEach(TabSuspension.allCases) { Text($0.title).tag($0) }
                }
            } footer: {
                Text("Frees the memory of tabs you haven't looked at for a while. They stay in the tab bar and reload, with their history, when you go back to them. Tabs playing audio or video, or using the camera or microphone, are never suspended.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            #if os(macOS)
            Section {
                LabeledContent("Bookmarks and history") {
                    Button("Import from Dia…") { store.isImporting = true }
                }
            }
            #endif
            Section {
                Toggle("Show tabs from my other devices", isOn: Bindable(store.cloudSync).isEnabled)
                Toggle("Sync bookmarks and spaces", isOn: Bindable(store.cloudSync).syncBookmarks)
                    .disabled(!store.cloudSync.isEnabled)
                if let status = store.cloudSync.status {
                    Text(status).font(.footnote).foregroundStyle(.orange)
                } else if let lastSync = store.cloudSync.lastSync, store.cloudSync.isEnabled {
                    Text("Synced \(lastSync.formatted(.relative(presentation: .named)))" +
                         (store.cloudSync.remoteDevices.isEmpty ? "; no other devices yet" :
                            " · \(store.cloudSync.remoteDevices.count) other device\(store.cloudSync.remoteDevices.count == 1 ? "" : "s")"))
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } header: {
                Text("iCloud")
            } footer: {
                Text("Shares your open tabs (never private ones) and bookmarks through your iCloud account, so they're on all your devices. Bookmarks are matched by space name. Handoff also offers the page you're viewing.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// How Dew looks and where things sit: website colour, the bookmarks bar (Mac), and on iOS the address bar
/// and the iPhone Duo's side column.
struct AppearanceSettingsView: View {
    @Environment(BrowserStore.self) private var store

    var body: some View {
        @Bindable var store = store
        Form {
            Section {
                Toggle("Match toolbar to website colour", isOn: $store.matchSiteColor)
            } footer: {
                Text("The selected tab and address bar take on the colour at the top of the page.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            #if os(macOS)
            Section {
                Toggle("Show bookmarks bar", isOn: $store.showBookmarksBar)
                Toggle("Bookmark icons only", isOn: $store.bookmarksIconsOnly)
                    .disabled(!store.showBookmarksBar)
            } header: {
                Text("Bookmarks bar")
            }
            #else
            Section {
                Picker("Address bar", selection: $store.addressBarPosition) {
                    ForEach(AddressBarPosition.allCases) { Text($0.title).tag($0) }
                }
            } header: {
                Text("Layout")
            } footer: {
                Text("Automatic puts the address bar at the top on iPhone Duo and iPad, and at the bottom on iPhone.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            switch store.activeLayout {
            case .duo:
                Section {
                    NavigationLink("Side Buttons") { SideButtonsSettingsView(placement: .side) }
                    Toggle("Show page under the side status bar", isOn: $store.pageUnderStatusStrip)
                } header: {
                    Text("Buttons")
                } footer: {
                    Text("Choose which buttons show in the side column, and their order. The page can also fill the side edge, with the clock and buttons floating over it.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            case .bottomBar:
                Section {
                    NavigationLink("Bottom Bar Buttons") { SideButtonsSettingsView(placement: .bottom) }
                } header: {
                    Text("Buttons")
                } footer: {
                    Text("Choose which buttons show in the bar at the bottom of the screen, and their order.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            case .toolbar:
                EmptyView()   // the system toolbar arranges its own buttons
            }
            #endif
        }
        .formStyle(.grouped)
    }
}

struct PrivacySettingsView: View {
    @Environment(BrowserStore.self) private var store

    var body: some View {
        @Bindable var store = store
        Form {
            AdBlockSection(blocker: store.contentBlocker)
            Section {
                Picker("Cookie banners", selection: $store.cookieBannerMode) {
                    ForEach(CookieBannerMode.allCases) { Text($0.title).tag($0) }
                }
            } footer: {
                Text("Dew clicks the banner's Reject (or Accept) button for you on most sites. With Reject, it never accepts.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(store.spaces) { space in
                SpacePrivacySection(space: space)
            }
        }
        .formStyle(.grouped)
    }
}

private struct AdBlockSection: View {
    @Bindable var blocker: ContentBlocker

    var body: some View {
        Section {
            Toggle("Block ads and trackers", isOn: $blocker.isEnabled)
            if blocker.isEnabled {
                HStack {
                    Text(status)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if blocker.isUpdating {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Update Now") { Task { await blocker.update() } }
                            .buttonStyle(.borderless)
                    }
                }
            }
        } footer: {
            Text("Uses EasyList and EasyPrivacy, refreshed weekly. Turn this off if a site doesn't work properly.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var status: String {
        if let error = blocker.lastError, blocker.lastUpdated == nil { return "Using built-in list (\(error))" }
        let rules = "\(blocker.ruleCount.formatted()) rules"
        guard let updated = blocker.lastUpdated else { return "Built-in list · \(rules)" }
        return "Updated \(updated.formatted(.relative(presentation: .named))) · \(rules)"
    }
}

private struct SpacePrivacySection: View {
    @Environment(BrowserStore.self) private var store
    let space: Space
    @State private var confirmingHistory = false
    @State private var confirmingCookies = false

    var body: some View {
        let settings = space.privacySettings
        Section {
            Picker("Clear automatically", selection: binding(\.schedule)) {
                ForEach(AutoClearSchedule.allCases) { Text($0.title).tag($0) }
            }
            if settings.schedule != .never {
                Toggle("History", isOn: binding(\.clearHistory))
                Toggle("Cookies and site data", isOn: binding(\.clearCookies))
            }
            HStack(spacing: 16) {
                Button("Clear History…") { confirmingHistory = true }
                Button("Clear Cookies…") { confirmingCookies = true }
                Spacer()
            }
            .buttonStyle(.borderless)
        } header: {
            HStack(spacing: 8) {
                SpaceBadge(space: space, size: 18)
                Text(space.name)
            }
        }
        .confirmationDialog("Clear history for “\(space.name)”?", isPresented: $confirmingHistory) {
            Button("Clear History", role: .destructive) { store.clearHistory(for: space.id) }
        }
        .confirmationDialog("Clear cookies and site data for “\(space.name)”?", isPresented: $confirmingCookies) {
            Button("Clear Cookies", role: .destructive) { Task { await store.clearWebsiteData(for: space.id) } }
        } message: {
            Text("You'll be signed out of every site in this space. Other spaces aren't affected.")
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<PrivacySettings, Value>) -> Binding<Value> {
        Binding {
            store.spaces.first { $0.id == space.id }?.privacySettings[keyPath: keyPath] ?? space.privacySettings[keyPath: keyPath]
        } set: { value in
            store.updatePrivacy(of: space.id) { $0[keyPath: keyPath] = value }
        }
    }
}
