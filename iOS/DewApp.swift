import SwiftUI

@main
struct DewApp: App {
    @State private var store = BrowserStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            PhoneBrowserView()
                .environment(store)
                .onOpenURL { url in
                    // dew://search from the Search widget; anything else is a web link to open.
                    if url.scheme == "dew" { store.handleAppURL(url) } else { store.newTab(url: url) }
                }
                .modifier(HandoffModifier(store: store))
                .task {
                    store.applyAppearance()
                    store.applyAppIcon()   // tells the Search widget which drop to show
                    store.handleWidgetSearchRequest()   // launched by the Search widget's capsule
                    // Debug: `-DewOpenAppURL dew://search` acts as if the Search widget was tapped.
                    if let link = UserDefaults.standard.string(forKey: "DewOpenAppURL"), let url = URL(string: link) {
                        store.handleAppURL(url)
                    }
                    // Debug: `-DewOpenURL https://…` opens a page at launch (simulator testing).
                    // Debug: `-DewPrivate YES` starts in private browsing; `-DewEditAddress <text>` opens the
                    // address editor with that text (device testing).
                    if UserDefaults.standard.bool(forKey: "DewPrivate") { store.enterPrivate() }
                    // Debug: `-DewOpenSettings YES` opens Settings (with `-DewSettingsPage ai` for a page).
                    if UserDefaults.standard.bool(forKey: "DewOpenSettings") { store.openSettings(UserDefaults.standard.string(forKey: "DewSettingsPage")) }
                    if let text = UserDefaults.standard.string(forKey: "DewEditAddress") {
                        store.commandBar = CommandBarState(text: text, opensInNewTab: store.selectedTab == nil || store.isBlank(store.selectedTab))
                    }
                    if let string = UserDefaults.standard.string(forKey: "DewOpenURL"), let url = URL(string: string) {
                        let first = store.newTab(url: url)
                        // Debug: `-DewOpenSplitURL https://…` opens a second page beside it in split view.
                        if let second = UserDefaults.standard.string(forKey: "DewOpenSplitURL").flatMap(URL.init(string:)) {
                            store.addToSplit(store.newTab(url: second), beside: first)
                        }
                    }
                }
                // The capsule's intent can also run in Dew itself, already in front.
                .onReceive(NotificationCenter.default.publisher(for: OpenSearchIntent.requested)) { _ in
                    store.handleWidgetSearchRequest()
                }
                .onChange(of: scenePhase) {
                    if scenePhase == .active {
                        store.handleWidgetSearchRequest()   // the Search widget's capsule brought Dew forward
                        store.reloadAppearance()
                        store.chat.refreshKeys()   // an API key may have arrived from the Mac through iCloud Keychain
                        Task { await store.runAutoClear(.periodic) }
                        Task { await store.cloudSync.refresh() }
                        store.defaultBrowser.refresh()
                    } else {
                        store.saveNow()
                    }
                }
        }
    }
}
