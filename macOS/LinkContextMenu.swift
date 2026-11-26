import AppKit
import WebKit

/// Dew's web view on the Mac. Adds Dew's link actions to WebKit's right-click menu: Open Link in New Tab,
/// Open Link in Background Tab and Chat About Link (WebKit has no public API for this on macOS).
final class DewWebView: WKWebView {
    weak var tab: BrowserTab?
    /// The link under the pointer when the menu was requested, reported by `ContextLinkHandler`'s script.
    var contextLinkURL: URL?

    private static let openLink = "WKMenuItemIdentifierOpenLink"
    private static let openLinkInNewWindow = "WKMenuItemIdentifierOpenLinkInNewWindow"
    private static let copyLink = "WKMenuItemIdentifierCopyLink"

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        let identifiers = menu.items.compactMap { $0.identifier?.rawValue }
        let isLinkMenu = identifiers.contains(Self.openLinkInNewWindow) || identifiers.contains(Self.copyLink)
        // If the link isn't known (the script's report didn't arrive in time), leave WebKit's menu as it is.
        guard isLinkMenu, let url = contextLinkURL, let tab, let store = tab.store else { return }
        let spaceID = tab.spaceID

        // Dew's "new tab" replaces WebKit's "new window".
        menu.items.first { $0.identifier?.rawValue == Self.openLinkInNewWindow }?.isHidden = true

        let actions = [
            ActionMenuItem(title: "Open Link in New Tab") { [weak tab] in
                store.newTab(url: url, in: spaceID, after: tab, select: true)
            },
            ActionMenuItem(title: "Open Link in Background Tab") { [weak tab] in
                store.newTab(url: url, in: spaceID, after: tab, select: false)
            },
            ActionMenuItem(title: "Chat About Link") { [weak tab] in
                // Opens it quietly in a background tab, shares that tab with the chat, and shows Chat.
                let opened = store.newTab(url: url, in: spaceID, after: tab, select: false)
                store.chat.attach(opened)
                store.isChatOpen = true
            },
        ]
        // After WebKit's "Open Link" (which opens it here), or at the top.
        var index = (menu.items.firstIndex { $0.identifier?.rawValue == Self.openLink }).map { $0 + 1 } ?? 0
        for item in actions {
            menu.insertItem(item, at: index)
            index += 1
        }
        if index < menu.items.count, !menu.items[index].isSeparatorItem { menu.insertItem(.separator(), at: index) }
    }

    override func didCloseMenu(_ menu: NSMenu, with event: NSEvent?) {
        super.didCloseMenu(menu, with: event)
        contextLinkURL = nil
    }
}

/// A menu item that runs a closure.
private final class ActionMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(title: String, handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self   // targets are weak; the menu keeps the item (and so its target) alive
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func run() { MainActor.assumeIsolated { handler() } }
}

/// Reports the link under the pointer when the page's context menu is requested. Runs in Dew's own JS world,
/// so pages can't see or fake it; the `contextmenu` event reaches Dew before WebKit builds its menu.
final class ContextLinkHandler: NSObject, WKScriptMessageHandler {
    static let name = "dewContextLink"
    static let script = """
    document.addEventListener('contextmenu', (event) => {
      const link = event.target instanceof Element ? event.target.closest('a[href]') : null;
      window.webkit.messageHandlers.\(name).postMessage(link ? link.href : '');
    }, true);
    """

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            guard let webView = message.webView as? DewWebView else { return }
            let href = message.body as? String ?? ""
            webView.contextLinkURL = href.isEmpty ? nil : URL(string: href)
        }
    }
}
