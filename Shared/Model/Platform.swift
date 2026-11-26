import SwiftUI

#if os(macOS)
import AppKit
typealias PlatformImage = NSImage

extension Image {
    init(platformImage: NSImage) { self.init(nsImage: platformImage) }
}

@MainActor func openExternally(_ url: URL) { NSWorkspace.shared.open(url) }
#else
import UIKit
typealias PlatformImage = UIImage

extension Image {
    init(platformImage: UIImage) { self.init(uiImage: platformImage) }
}

@MainActor func openExternally(_ url: URL) { UIApplication.shared.open(url) }
#endif

/// In-memory favicon cache shared by every tab in every space.
///
/// If an icon address fails (missing, or redirected to a login page) and the page it belongs to is
/// known, the page is read for the icons it declares, then the usual /favicon.ico and .png spots on
/// the same scheme, host and port are tried.
@MainActor
final class FaviconCache {
    static let shared = FaviconCache()

    private var images: [URL: PlatformImage] = [:]
    private var failed: Set<URL> = []
    private var inFlight: [URL: Task<PlatformImage?, Never>] = [:]
    private let session = URLSession(configuration: .ephemeral, delegate: LocalTrust(), delegateQueue: nil)

    func cached(_ url: URL) -> PlatformImage? { images[url] }

    /// `page` enables the fallbacks when `url` doesn't give an image.
    func image(for url: URL?, page: URL? = nil) async -> PlatformImage? {
        guard let key = url ?? page else { return nil }
        if let image = images[key] { return image }
        if let task = inFlight[key] { return await task.value }
        let task = Task { () -> PlatformImage? in
            if let url, let image = await self.load(url) { return image }
            guard let page, page.scheme?.hasPrefix("http") == true else { return nil }
            for candidate in await self.declaredIcons(on: page) + self.defaultIcons(for: page) where candidate != url {
                if let image = await self.load(candidate) { return image }
            }
            return nil
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        if let image { images[key] = image }
        return image
    }

    private func load(_ url: URL) async -> PlatformImage? {
        if let image = images[url] { return image }
        if failed.contains(url) { return nil }
        var image: PlatformImage?
        if let (data, response) = try? await session.data(from: url) {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 200
            let isHTML = response.mimeType?.contains("html") == true   // e.g. redirected to a login page
            if status < 400, !isHTML { image = PlatformImage(data: data) }
        }
        if let image { images[url] = image } else { failed.insert(url) }
        return image
    }

    /// Icons declared by <link rel="icon" | "shortcut icon" | "apple-touch-icon"> in the page's HTML.
    private func declaredIcons(on page: URL) async -> [URL] {
        guard let (data, response) = try? await session.data(from: page),
              let html = String(data: data.prefix(300_000), encoding: .utf8) ?? String(data: data.prefix(300_000), encoding: .isoLatin1) else { return [] }
        let base = response.url ?? page
        var icons: [(url: URL, score: Int)] = []
        for match in html.matches(of: /<link\b[^>]*>/.ignoresCase()) {
            let tag = String(match.output)
            guard let rel = tag.firstMatch(of: /rel\s*=\s*["']?([^"'>]+)/.ignoresCase())?.1.lowercased(),
                  rel.contains("icon"),
                  let href = tag.firstMatch(of: /href\s*=\s*["']?([^"'\s>]+)/.ignoresCase())?.1,
                  let url = URL(string: String(href).replacingOccurrences(of: "&amp;", with: "&"), relativeTo: base)?.absoluteURL
            else { continue }
            // Prefer ~32 px PNG/ICO icons; SVG can't be shown, apple-touch icons are big but fine.
            let size = tag.firstMatch(of: /sizes\s*=\s*["']?(\d+)/).flatMap { Int(String($0.1)) } ?? 16
            let isSVG = url.pathExtension.lowercased() == "svg" || tag.lowercased().contains("svg+xml")
            icons.append((url, isSVG ? -1000 : -abs(size - 32)))
        }
        return icons.sorted { $0.score > $1.score }.filter { $0.score > -1000 }.map(\.url)
    }

    private func defaultIcons(for page: URL) -> [URL] {
        guard let origin = page.originURL else { return [] }
        return ["favicon.ico", "favicon.png", "apple-touch-icon.png"].compactMap { URL(string: $0, relativeTo: origin)?.absoluteURL }
    }
}

/// Lets favicon requests to local devices (router, NAS, Homebridge…) succeed with self-signed
/// certificates, which is how most of them ship. Never applies to public sites.
private final class LocalTrust: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust, let trust = space.serverTrust,
              PasswordStore.isLocal(space.host) else { return (.performDefaultHandling, nil) }
        return (.useCredential, URLCredential(trust: trust))
    }
}

enum ErrorPage {
    static func html(for error: NSError, url: URL?) -> String {
        let host = URLInput.displayHost(url) ?? "This page"
        let message = error.localizedDescription
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
        return """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <title>\(host)</title><style>
        :root { color-scheme: light dark; font: -apple-system-body; font-family: -apple-system, sans-serif; }
        body { display: grid; place-items: center; min-height: 90vh; margin: 0; }
        main { max-width: 420px; padding: 24px; text-align: center; }
        h1 { font-size: 20px; font-weight: 600; } p { opacity: .65; line-height: 1.5; }
        </style></head><body><main><h1>Can't open \(host)</h1><p>\(message)</p></main></body></html>
        """
    }
}
