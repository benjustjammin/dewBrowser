// Renders Tools/AppIcon.svg into the app icon PNGs, using WebKit so
// gradients, clip paths and <use> render exactly as they did in Dia.
//
//   swiftc -O -o /tmp/render-icon Tools/render-icon.swift && /tmp/render-icon Tools/AppIcon.svg /tmp/dewicon
//
// Writes icon-mac.png (the SVG as designed: rounded tile on the macOS icon grid, with shadow) and
// icon-ios.png (full-bleed, opaque square: mac-only parts removed, tile scaled to fill; iOS masks it).
import AppKit
import WebKit

@MainActor final class Renderer: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Never>?

    func render(svg: String, to url: URL, opaque: Bool = false) async {
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1024, height: 1024))
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = self
        let window = NSWindow(contentRect: NSRect(x: -4000, y: 0, width: 1024, height: 1024), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = webView
        window.orderBack(nil)
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            webView.loadHTMLString("<html><body style='margin:0;background:transparent'>\(svg)</body></html>", baseURL: nil)
        }
        try? await Task.sleep(for: .milliseconds(300))
        let configuration = WKSnapshotConfiguration()
        configuration.snapshotWidth = 1024   // exact pixels regardless of screen scale
        guard let image = try? await webView.takeSnapshot(configuration: configuration),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        // iOS icons must not have an alpha channel.
        var finalImage = cgImage
        if opaque, let context = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0,
                                           space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                           bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) {
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
            finalImage = context.makeImage() ?? cgImage
        }
        let rep = NSBitmapImageRep(cgImage: finalImage)
        rep.size = NSSize(width: 1024, height: 1024)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        window.orderOut(nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        continuation?.resume()
        continuation = nil
    }
}

/// iOS: drop the mac-only tile shadow/edge, square the tile and scale it to fill 1024.
func fullBleed(_ svg: String) -> String {
    var out = svg.replacingOccurrences(of: #"<rect class="mac-only"[^>]*/>"#, with: "", options: .regularExpression)
    out = out.replacingOccurrences(of: #"<rect id="tile-rect" x="100" y="100" width="824" height="824" rx="185"/>"#,
                                   with: #"<rect id="tile-rect" x="100" y="100" width="824" height="824"/>"#)
    out = out.replacingOccurrences(of: #"<clipPath id="tile"><rect x="100" y="100" width="824" height="824" rx="185"/></clipPath>"#,
                                   with: #"<clipPath id="tile"><rect x="100" y="100" width="824" height="824"/></clipPath>"#)
    let scale = 1024.0 / 824.0
    if let defsEnd = out.range(of: "</defs>"), let svgEnd = out.range(of: "</svg>", options: .backwards) {
        out.replaceSubrange(svgEnd, with: "</g></svg>")
        out.insert(contentsOf: "<g transform=\"translate(512 512) scale(\(scale)) translate(-512 -512)\">", at: defsEnd.upperBound)
    }
    return out
}

let arguments = CommandLine.arguments
let source = try String(contentsOfFile: arguments.count > 1 ? arguments[1] : "Tools/AppIcon.svg", encoding: .utf8)
let output = URL(fileURLWithPath: arguments.count > 2 ? arguments[2] : ".")
try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let svg = String(source[source.range(of: "<svg")!.lowerBound...])

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
Task { @MainActor in
    let renderer = Renderer()
    await renderer.render(svg: svg, to: output.appending(path: "icon-mac.png"))
    await renderer.render(svg: fullBleed(svg), to: output.appending(path: "icon-ios.png"), opaque: true)
    print("Wrote icon-mac.png and icon-ios.png to \(output.path)")
    exit(0)
}
app.run()
