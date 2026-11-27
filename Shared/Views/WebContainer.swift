import SwiftUI
import WebKit

/// Hosts the selected tab's WKWebView. Switching tabs swaps the subview rather than recreating
/// anything, so each tab keeps its scroll position, form state and running media.
#if os(macOS)
struct WebContainer: NSViewRepresentable {
    let tab: BrowserTab
    /// Called when the user clicks inside this web view (used to focus a split-view pane).
    var onInteract: (() -> Void)?
    /// Whether this web view should take keyboard focus when shown (only the focused split pane does).
    var takesFocus = true

    func makeNSView(context: Context) -> WebHostView { WebHostView() }
    func updateNSView(_ view: WebHostView, context: Context) {
        view.onInteract = onInteract
        view.takesFocus = takesFocus
        view.show(tab.webView)
    }
}

final class WebHostView: NSView {
    private weak var current: WKWebView?
    var onInteract: (() -> Void)?
    var takesFocus = true
    private var monitor: Any?

    func show(_ webView: WKWebView) {
        guard current !== webView else { return }
        current?.removeFromSuperview()
        webView.frame = bounds
        webView.autoresizingMask = [.width, .height]
        addSubview(webView)
        current = webView
        guard takesFocus else { return }
        DispatchQueue.main.async { [weak webView] in
            guard let webView, let window = webView.window, !(window.firstResponder is NSTextView) else { return }
            window.makeFirstResponder(webView)
        }
    }

    // The web view swallows clicks, so watch mouse-downs and check whether they land in this view.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, let onInteract = self.onInteract, event.window === self.window else { return event }
            if self.bounds.contains(self.convert(event.locationInWindow, from: nil)) { onInteract() }
            return event
        }
    }
}
#else
struct WebContainer: UIViewRepresentable {
    let tab: BrowserTab
    /// Called when the user taps inside this web view (used to focus a split-view pane).
    var onInteract: (() -> Void)?
    /// Mac-only (keyboard focus follows taps on iOS); accepted so shared code reads the same.
    var takesFocus = true
    /// Parts of the web view covered by floating controls (e.g. the Duo's address capsule). The page
    /// scrolls underneath them, and WebKit keeps fixed/sticky page elements clear of them.
    var obscuredInsets: UIEdgeInsets?

    func makeUIView(context: Context) -> WebHostView { WebHostView() }
    func updateUIView(_ view: WebHostView, context: Context) {
        view.onInteract = onInteract
        let webView = tab.webView
        view.show(webView)
        if let insets = obscuredInsets {
            webView.scrollView.contentInsetAdjustmentBehavior = .never
            if #available(iOS 26.0, *) {
                if webView.obscuredContentInsets != insets { webView.obscuredContentInsets = insets }
            } else if webView.scrollView.contentInset != insets {
                webView.scrollView.contentInset = insets
                webView.scrollView.verticalScrollIndicatorInsets = insets
            }
        }
    }
}

final class WebHostView: UIView, UIGestureRecognizerDelegate {
    private weak var current: WKWebView?
    var onInteract: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        addGestureRecognizer(tap)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func tapped() { onInteract?() }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    func show(_ webView: WKWebView) {
        guard current !== webView else { return }
        current?.removeFromSuperview()
        webView.frame = bounds
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(webView)
        current = webView
    }
}
#endif

struct FaviconView: View {
    let url: URL?
    /// The page the icon belongs to; lets the cache find the icon another way if `url` fails.
    var page: URL?
    var size: CGFloat = 16
    @State private var image: PlatformImage?

    init(url: URL?, page: URL? = nil, size: CGFloat = 16) {
        self.url = url
        self.page = page
        self.size = size
        _image = State(initialValue: (url ?? page).flatMap { FaviconCache.shared.cached($0) })
    }

    var body: some View {
        Group {
            if let image {
                Image(platformImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            } else if (page ?? url)?.scheme == "dew" {
                // Dew's own pages (History).
                Image(systemName: "clock").resizable().aspectRatio(contentMode: .fit)
                    .foregroundStyle(.secondary).padding(size * 0.06)
            } else {
                Image(systemName: "globe").resizable().aspectRatio(contentMode: .fit)
                    .foregroundStyle(.secondary).padding(size * 0.08)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        .task(id: url ?? page) {
            guard url != nil || page != nil else { image = nil; return }
            image = await FaviconCache.shared.image(for: url, page: page)
        }
    }
}

struct SpaceBadge: View {
    let space: Space
    var size: CGFloat = 20

    var body: some View {
        Image(systemName: space.symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(space.color.gradient, in: Circle())
    }
}
