import ImageIO
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

    /// Small decoded icons, trimmed by the system under memory pressure and never more than a few hundred.
    private let images: NSCache<NSURL, PlatformImage> = {
        let cache = NSCache<NSURL, PlatformImage>()
        cache.countLimit = 400
        return cache
    }()
    /// Addresses the server said have no icon (not ones that failed for lack of a connection).
    private var failed: Set<URL> = []
    private var inFlight: [URL: Task<PlatformImage?, Never>] = [:]
    private let session = URLSession(configuration: .ephemeral, delegate: LocalTrust(), delegateQueue: nil)

    func cached(_ url: URL) -> PlatformImage? { images.object(forKey: url as NSURL) }

    /// `page` enables the fallbacks when `url` doesn't give an image.
    func image(for url: URL?, page: URL? = nil) async -> PlatformImage? {
        guard let key = url ?? page else { return nil }
        if let image = cached(key) { return image }
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
        if let image { images.setObject(image, forKey: key as NSURL) }
        return image
    }

    private func load(_ url: URL) async -> PlatformImage? {
        if let image = cached(url) { return image }
        if failed.contains(url) { return nil }
        // No connection: try again next time rather than remembering it as missing.
        guard let (data, response) = try? await session.data(from: url) else { return nil }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        let isHTML = response.mimeType?.contains("html") == true   // e.g. redirected to a login page
        guard status < 400, !isHTML, let image = Self.icon(from: data) else { failed.insert(url); return nil }
        images.setObject(image, forKey: url as NSURL)
        return image
    }

    /// Decoded at no more than 64 px (icons show at 16–32 pt), from the largest image in a multi-size .ico.
    private static func icon(from data: Data) -> PlatformImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else {
            return PlatformImage(data: data)   // formats Image I/O doesn't read (an SVG favicon on the Mac)
        }
        let width = { (index: Int) in
            (CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any])?[kCGImagePropertyPixelWidth] as? Int ?? 0
        }
        let largest = (0..<CGImageSourceGetCount(source)).max { width($0) < width($1) } ?? 0
        let options = [kCGImageSourceThumbnailMaxPixelSize: 64, kCGImageSourceCreateThumbnailFromImageAlways: true,
                       kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, largest, options) else { return nil }
        #if os(macOS)
        return NSImage(cgImage: image, size: .zero)
        #else
        return UIImage(cgImage: image)
        #endif
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
