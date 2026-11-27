import SwiftUI

/// First-run welcome: one short screen with what makes Dew different, then out of the way. Shown once to new
/// users; Help → Welcome to Dew (Mac) or Settings → Welcome to Dew (iOS) brings it back.
struct WelcomeView: View {
    @Environment(BrowserStore.self) private var store

    var body: some View {
        // The intro scrolls if the screen is short (folded iPhone Duo); the buttons stay at the bottom.
        ScrollView {
            VStack(spacing: 0) {
                DewMark(size: 40, style: store.appIcon.markStyle)
                    .frame(height: 86, alignment: .top)
                    .padding(.top, 28)
                Text("Welcome to Dew").font(.title.weight(.semibold))
                Text("A small, fast browser that stays out of the way.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
                VStack(alignment: .leading, spacing: 18) {
                    row("square.stack.3d.up", "Spaces",
                        "Keep Personal and Work apart. Each space has its own logins, history and tabs.")
                    row("rectangle.split.2x1", "Side by side",
                        "Show two tabs at once, and pin the ones you keep open all day.")
                    row("sparkles", "Chat", Self.chatLine)
                    row("hand.raised", "Private by default",
                        "Ads and trackers are blocked and cookie banners rejected. Private browsing is a tap away.")
                }
                .frame(maxWidth: 400, alignment: .leading)
                .padding(.top, 28)
                .padding(.bottom, 12)
            }
            .padding(.horizontal, 28)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom) { buttons }
        .tint(store.currentSpace.color)
        #if os(macOS)
        .frame(width: 520, height: 600)
        #endif
    }

    private var buttons: some View {
        VStack(spacing: 10) {
            Button { store.finishWelcome() } label: {
                Text("Get Started").font(.headline).frame(maxWidth: 320).padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            #if os(macOS)
            HStack(spacing: 18) {
                Button("Import from Dia…") {
                    store.finishWelcome()
                    // After this sheet closes, so the import sheet can open.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { store.isImporting = true }
                }
                if store.defaultBrowser.isDefault != true {
                    Button("Make Dew Your Default Browser") { store.defaultBrowser.makeDefault() }
                }
            }
            .buttonStyle(.link)
            .font(.callout)
            #endif
        }
        .padding(.horizontal, 28)
        .padding(.top, 12)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity)
        .background(.background)
    }

    private static var chatLine: String {
        #if os(macOS)
        "Ask about a page or several tabs, get help with writing, or let Chat tidy your tabs. Press ⌘E."
        #else
        "Ask about a page or several tabs, get help with writing, or let Chat tidy your tabs. It's in the ⋯ menu."
        #endif
    }

    private func row(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(store.currentSpace.color)
                .frame(width: 34, height: 34)
                .background(Circle().fill(store.currentSpace.color.opacity(0.12)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
