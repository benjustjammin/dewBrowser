import WebKit
import Observation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// One tab. Its WKWebView is created lazily the first time the tab is shown, so restored
/// sessions with many tabs cost almost nothing until you actually visit them.
@MainActor @Observable
final class BrowserTab: NSObject, Identifiable {
    let id: UUID
    let spaceID: UUID
    var url: URL?
    var title: String
    var faviconURL: URL?
    var isPinned: Bool {
        didSet { if isPinned != oldValue { pinnedURL = isPinned ? url : nil } }
    }
    /// The page a pinned tab was pinned on: closing it goes back there (Dia's pinned tabs).
    @ObservationIgnored var pinnedURL: URL?
    var isLoading = false
    var progress: Double = 0
    var canGoBack = false
    var canGoForward = false
    var thumbnail: PlatformImage?
    var themeColor: RGBColor?

    @ObservationIgnored var openerID: UUID?
    @ObservationIgnored weak var store: BrowserStore?
    @ObservationIgnored private(set) var loadedWebView: WKWebView?
    @ObservationIgnored private var popupConfiguration: WKWebViewConfiguration?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    /// When the tab was last on screen; used to suspend tabs that haven't been looked at for a while.
    @ObservationIgnored var lastActive = Date()
    /// Back/forward list and scroll position saved when the tab was suspended, restored when it's shown again.
    @ObservationIgnored private var suspendedState: Any?
    /// True while the tab's web view has been released to save memory; it reloads when shown.
    private(set) var isSuspended = false

    init(id: UUID = UUID(), spaceID: UUID, url: URL?, title: String = "", faviconURL: URL? = nil,
         isPinned: Bool = false, themeColor: RGBColor? = nil, store: BrowserStore, popupConfiguration: WKWebViewConfiguration? = nil) {
        self.id = id
        self.spaceID = spaceID
        self.url = url
        self.title = title
        self.faviconURL = faviconURL
        self.isPinned = isPinned
        self.themeColor = themeColor
        self.store = store
        self.popupConfiguration = popupConfiguration
        super.init()
    }

    /// A tab brought back from saved state or from Recently Closed.
    convenience init(record: TabRecord, store: BrowserStore, isPinned: Bool? = nil) {
        self.init(id: record.id, spaceID: record.spaceID, url: record.url, title: record.title, faviconURL: record.faviconURL,
                  isPinned: isPinned ?? record.isPinned, themeColor: record.themeColor, store: store)
        if self.isPinned { pinnedURL = record.pinnedURL ?? record.url }
    }

    /// One of Dew's own pages (`dew://…`, like History), drawn natively rather than in a web view.
    var isInternalPage: Bool { url?.scheme == "dew" }

    var displayTitle: String {
        if url == BrowserStore.historyURL { return "History" }
        if !title.isEmpty { return title }
        return URLInput.displayHost(url) ?? "New Tab"
    }

    var record: TabRecord {
        TabRecord(id: id, spaceID: spaceID, url: url, title: title, faviconURL: faviconURL, isPinned: isPinned, themeColor: themeColor,
                  pinnedURL: pinnedURL)
    }

    // MARK: Web view

    var webView: WKWebView {
        if let loadedWebView { return loadedWebView }
        var configuration = popupConfiguration ?? store?.makeConfiguration(for: spaceID) ?? WKWebViewConfiguration()
        #if os(macOS)
        // An extension's own page (its welcome or options page) needs the extension's configuration to load.
        if popupConfiguration == nil, let url, let own = store?.extensions.configuration(for: url) { configuration = own }
        let webView = DewWebView(frame: .zero, configuration: configuration)   // adds Dew's link actions to the right-click menu
        webView.tab = self
        #else
        let webView = WKWebView(frame: .zero, configuration: configuration)
        #endif
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.isInspectable = true
        #if os(macOS)
        webView.allowsMagnification = true
        #else
        webView.isFindInteractionEnabled = true
        webView.scrollView.contentInsetAdjustmentBehavior = .automatic
        #endif
        observe(webView)
        loadedWebView = webView
        lastActive = Date()
        if let suspendedState {
            webView.interactionState = suspendedState   // restores back/forward history and reloads the page
            self.suspendedState = nil
        } else if popupConfiguration == nil, let url, !isInternalPage {
            #if os(macOS)
            // Pages restored at launch wait (briefly) for extensions, so their content scripts apply.
            store?.extensions.whenReady { [weak webView] in webView?.load(URLRequest(url: url)) }
            #else
            webView.load(URLRequest(url: url))
            #endif
        }
        isSuspended = false
        popupConfiguration = nil
        return webView
    }

    private func observe(_ webView: WKWebView) {
        observations = [
            webView.observe(\.title) { [weak self] webView, _ in
                MainActor.assumeIsolated {
                    guard let self, let title = webView.title else { return }
                    self.title = title
                    self.store?.setNeedsSave()
                    self.extensionsChanged(.title)
                }
            },
            webView.observe(\.url) { [weak self] webView, _ in
                MainActor.assumeIsolated {
                    guard let self, let url = webView.url else { return }
                    if url.host != self.url?.host { self.faviconURL = nil }
                    self.url = url
                    self.store?.setNeedsSave()
                    self.extensionsChanged(.URL)
                }
            },
            webView.observe(\.isLoading) { [weak self] webView, _ in
                MainActor.assumeIsolated {
                    self?.isLoading = webView.isLoading
                    self?.extensionsChanged(.loading)
                }
            },
            webView.observe(\.estimatedProgress) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.progress = webView.estimatedProgress }
            },
            webView.observe(\.canGoBack) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.canGoBack = webView.canGoBack }
            },
            webView.observe(\.canGoForward) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.canGoForward = webView.canGoForward }
            },
        ]
    }

    #if os(macOS)
    private func extensionsChanged(_ properties: WKWebExtension.TabChangedProperties) {
        store?.extensions.didChange(properties, of: self)
    }
    #else
    private enum TabChange { case title, URL, loading }
    private func extensionsChanged(_ change: TabChange) {}   // no extensions on iOS
    #endif

    func load(_ url: URL) {
        self.url = url
        if let loadedWebView { loadedWebView.load(URLRequest(url: url)) }
        // Otherwise the lazily-created web view loads `url` when first shown.
    }

    func goBack() { loadedWebView?.goBack() }
    func goForward() { loadedWebView?.goForward() }
    func reload() {
        if isLoading { loadedWebView?.stopLoading() } else { loadedWebView?.reload() }
    }

    func setZoom(_ zoom: CGFloat?) {
        guard let webView = loadedWebView else { return }
        webView.pageZoom = zoom.map { min(max($0, 0.5), 3) } ?? 1
    }

    /// The tab grid's picture of the page (iOS): only the top of it shows on a card, so only that is captured, kept
    /// at 2× rather than the screen's 3× (every open tab holds one).
    func captureThumbnail() async {
        guard let webView = loadedWebView, webView.window != nil else { return }
        let configuration = WKSnapshotConfiguration()
        configuration.rect = CGRect(x: 0, y: 0, width: webView.bounds.width, height: webView.bounds.width * 0.9)
        configuration.snapshotWidth = 300
        guard let image = try? await webView.takeSnapshot(configuration: configuration) else { return }
        #if os(iOS)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        thumbnail = UIGraphicsImageRenderer(size: image.size, format: format).image { _ in image.draw(at: .zero) }
        #else
        thumbnail = image
        #endif
    }

    /// A pinned tab being closed: it stays pinned, but its page is unloaded (and the memory with it), and it's back at
    /// the page it was pinned on when next opened.
    func putAway() {
        tearDown()
        suspendedState = nil
        isSuspended = false
        thumbnail = nil
        url = pinnedURL ?? url
        isLoading = false
        progress = 0
        canGoBack = false
        canGoForward = false
    }

    func tearDown() {
        observations.forEach { $0.invalidate() }
        observations = []
        guard let webView = loadedWebView else { return }
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
        loadedWebView = nil
    }

    /// Releases the web view (and its web content process memory) if the tab is idle: not on screen,
    /// not loading, and not playing media or using the camera/microphone. Returns whether it did.
    @discardableResult
    func suspendIfIdle() async -> Bool {
        guard let webView = loadedWebView, webView.window == nil, !webView.isLoading,
              webView.cameraCaptureState == .none, webView.microphoneCaptureState == .none,
              webView.url != nil else { return false }
        let playback = await webView.requestMediaPlaybackState()
        guard playback == .none || playback == .paused,
              loadedWebView === webView, webView.window == nil else { return false }
        suspendedState = webView.interactionState
        tearDown()
        isSuspended = true
        return true
    }

    private func updateFavicon() async {
        guard let webView = loadedWebView, let pageURL = webView.url, pageURL.scheme?.hasPrefix("http") == true else { return }
        let script = """
        const links = [...document.querySelectorAll('link[rel~="icon"], link[rel="apple-touch-icon"]')];
        const score = l => {
          if (l.type === 'image/svg+xml' || /\\.svg($|\\?)/.test(l.href)) return -1000;
          const size = parseInt((l.getAttribute('sizes') || '').split('x')[0]) || 16;
          return -Math.abs(size - 32);
        };
        links.sort((a, b) => score(b) - score(a));
        return links.length ? links[0].href : null;
        """
        let found = (try? await webView.callAsyncJavaScript(script, contentWorld: .defaultClient)) as? String
        let icon = found.flatMap(URL.init(string:)) ?? URL(string: "/favicon.ico", relativeTo: pageURL)?.absoluteURL
        if faviconURL != icon {
            faviconURL = icon
            store?.setNeedsSave()
        }
        if let icon { store?.learnFavicon(icon, for: pageURL, in: spaceID) }
    }
}

// MARK: - Navigation

extension BrowserTab: WKNavigationDelegate {
    /// "webkit-extension": extensions' own pages (welcome, options).
    private static let inBrowserSchemes: Set<String> = ["http", "https", "about", "blob", "data", "file", "javascript", "webkit-extension"]

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else { return .allow }
        if !Self.inBrowserSchemes.contains(url.scheme?.lowercased() ?? "") {
            openExternally(url) // mailto:, tel:, facetime:, zoommtg:, app links…
            return .cancel
        }
        #if os(macOS)
        // An extension's page sending you on to a website (a welcome page's "Sign in"): the page's web view belongs
        // to the extension, so the site opens as a normal tab in its place, as Safari does.
        if webView.url?.scheme == "webkit-extension", url.scheme == "http" || url.scheme == "https",
           navigationAction.targetFrame?.isMainFrame != false, let store {
            store.newTab(url: url, in: spaceID, after: self)
            store.close(self, remember: false)
            return .cancel
        }
        if opensInNewTab(navigationAction) {
            openLinkInNewTab(url, navigationAction)
            return .cancel
        }
        #endif
        // Link tracking stripped from the address before the page loads (with ad and tracker blocking on), as Safari does.
        if store?.contentBlocker.isEnabled == true, navigationAction.targetFrame?.isMainFrame == true,
           navigationAction.request.httpMethod == "GET", let clean = URLInput.withoutTracking(url) {
            webView.load(URLRequest(url: clean))
            return .cancel
        }
        if navigationAction.shouldPerformDownload { return .download }
        return .allow
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if let http = navigationResponse.response as? HTTPURLResponse,
           http.value(forHTTPHeaderField: "Content-Disposition")?.lowercased().hasPrefix("attachment") == true {
            return .download
        }
        return navigationResponse.canShowMIMEType ? .allow : .download
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = store?.downloads
        downloadStarted(in: webView)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = store?.downloads
        downloadStarted(in: webView)
    }

    /// A tab opened just for a download (nothing ever shown in it) closes itself, like Safari; otherwise it
    /// would be restored on next launch and download the file again.
    private func downloadStarted(in webView: WKWebView) {
        if webView.backForwardList.currentItem == nil {
            store?.close(self, remember: false)   // reopening would just download again
        } else if let shown = webView.url {
            url = shown   // keep the page that's showing, not the download's address
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        store?.recordVisit(self)
        Task { await updateFavicon() }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let error = error as NSError
        if error.code == NSURLErrorCancelled { return }
        if error.domain == "WebKitErrorDomain" && (error.code == 102 || error.code == 204) { return } // policy change / plug-in handled
        let failingURL = error.userInfo[NSURLErrorFailingURLErrorKey] as? URL
        webView.loadHTMLString(ErrorPage.html(for: error, url: failingURL), baseURL: failingURL)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }
}

// MARK: - UI (popups, JS dialogs, file pickers)

extension BrowserTab: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        #if os(macOS)
        // A middle- or ⌘-clicked link arrives here (as a new-window request), not through the navigation policy.
        if opensInNewTab(navigationAction), let url = navigationAction.request.url {
            openLinkInNewTab(url, navigationAction)
            return nil
        }
        #endif
        // window.open / target=_blank: must use WebKit's configuration so window.opener works (OAuth popups).
        return store?.openPopup(configuration: configuration, from: self).webView
    }

    #if os(macOS)
    /// A link the user middle- or ⌘-clicked.
    private func opensInNewTab(_ action: WKNavigationAction) -> Bool {
        action.navigationType == .linkActivated && (action.modifierFlags.contains(.command) || isMiddleClick(action))
    }

    /// WebKit reports the button as a mask (middle = 1 << 2), older versions as a number (middle = 2).
    private func isMiddleClick(_ action: WKNavigationAction) -> Bool {
        action.buttonNumber == 4 || action.buttonNumber == 2
    }

    /// Middle-click follows Settings → General → Middle-click on a link (plain new tab, or into this tab's group);
    /// ⌘-click always opens a plain new tab (⇧ to switch to it).
    private func openLinkInNewTab(_ url: URL, _ action: WKNavigationAction) {
        let flags = action.modifierFlags
        if isMiddleClick(action), !flags.contains(.command), store?.middleClickAddsToGroup == true {
            store?.openInGroup(url, from: self)
        } else {
            store?.newTab(url: url, in: spaceID, after: self, select: flags.contains(.shift))
        }
    }
    #endif

    func webViewDidClose(_ webView: WKWebView) {
        store?.close(self)
    }

    #if os(macOS)
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async {
        let alert = makeAlert(message, frame: frame, buttons: ["OK"])
        _ = await present(alert, in: webView)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async -> Bool {
        let alert = makeAlert(message, frame: frame, buttons: ["OK", "Cancel"])
        return await present(alert, in: webView) == .alertFirstButtonReturn
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo) async -> String? {
        let alert = makeAlert(prompt, frame: frame, buttons: ["OK", "Cancel"])
        let field = NSTextField(string: defaultText ?? "")
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        return await present(alert, in: webView) == .alertFirstButtonReturn ? field.stringValue : nil
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        let response: NSApplication.ModalResponse
        if let window = webView.window { response = await panel.beginSheetModal(for: window) } else { response = panel.runModal() }
        return response == .OK ? panel.urls : nil
    }

    private func makeAlert(_ message: String, frame: WKFrameInfo, buttons: [String]) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = frame.securityOrigin.host.isEmpty ? "This page says" : "\(frame.securityOrigin.host) says"
        alert.informativeText = message
        buttons.forEach { alert.addButton(withTitle: $0) }
        return alert
    }

    private func present(_ alert: NSAlert, in webView: WKWebView) async -> NSApplication.ModalResponse {
        if let window = webView.window { return await alert.beginSheetModal(for: window) }
        return alert.runModal()
    }
    #else
    /// Long-press on a link: Dew's own actions first (new tab, background tab, chat), then WebKit's
    /// (copy, share…). The link preview stays; tapping it opens the link here.
    func webView(_ webView: WKWebView, contextMenuConfigurationFor elementInfo: WKContextMenuElementInfo) async -> UIContextMenuConfiguration? {
        guard let url = elementInfo.linkURL, let store else { return nil }
        let spaceID = self.spaceID
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] suggested in
            let newTab = UIAction(title: "Open in New Tab", image: UIImage(systemName: "plus.square.on.square")) { _ in
                MainActor.assumeIsolated { _ = store.newTab(url: url, in: spaceID, after: self, select: true) }
            }
            let background = UIAction(title: "Open in Background Tab", image: UIImage(systemName: "square.on.square.dashed")) { _ in
                MainActor.assumeIsolated { _ = store.newTab(url: url, in: spaceID, after: self, select: false) }
            }
            let chat = UIAction(title: "Chat About Link", image: UIImage(systemName: "sparkles")) { _ in
                MainActor.assumeIsolated {
                    // Opens it quietly in a background tab, shares that tab with the chat, and shows Chat.
                    let tab = store.newTab(url: url, in: spaceID, after: self, select: false)
                    store.chat.attach(tab)
                    store.isChatOpen = true
                }
            }
            return UIMenu(children: [UIMenu(options: .displayInline, children: [newTab, background, chat])] + suggested)
        }
    }

    func webView(_ webView: WKWebView, contextMenuForElement elementInfo: WKContextMenuElementInfo,
                 willCommitWithAnimator animator: UIContextMenuInteractionCommitAnimating) {
        guard let url = elementInfo.linkURL else { return }
        animator.addCompletion { [weak self] in MainActor.assumeIsolated { self?.load(url) } }
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async {
        _ = await presentAlert(message, frame: frame, in: webView, cancellable: false, field: nil)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async -> Bool {
        await presentAlert(message, frame: frame, in: webView, cancellable: true, field: nil) != nil
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo) async -> String? {
        await presentAlert(prompt, frame: frame, in: webView, cancellable: true, field: defaultText ?? "")
    }

    /// Returns nil when cancelled, otherwise the text field value (or "" when there is no field).
    private func presentAlert(_ message: String, frame: WKFrameInfo, in webView: WKWebView,
                              cancellable: Bool, field: String?) async -> String? {
        guard var presenter = webView.window?.rootViewController else { return nil }
        while let next = presenter.presentedViewController { presenter = next }
        let host = frame.securityOrigin.host
        let alert = UIAlertController(title: host.isEmpty ? nil : host, message: message, preferredStyle: .alert)
        if let field { alert.addTextField { $0.text = field } }
        return await withCheckedContinuation { continuation in
            alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in
                continuation.resume(returning: alert.textFields?.first?.text ?? "")
            })
            if cancellable {
                alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in continuation.resume(returning: nil) })
            }
            presenter.present(alert, animated: true)
        }
    }
    #endif
}

struct TabRecord: Codable {
    var id: UUID
    var spaceID: UUID
    var url: URL?
    var title: String
    var faviconURL: URL?
    var isPinned: Bool
    var themeColor: RGBColor?
    /// Optional so state saved before it existed still decodes.
    var pinnedURL: URL?
}
