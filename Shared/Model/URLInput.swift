import Foundation

/// Turns whatever is typed in the address/command bar into a URL to load.
enum URLInput {
    static var searchTemplate: String { SearchEngine.current.template }
    private static let loadableSchemes: Set<String> = ["http", "https", "file", "about", "data"]

    struct Resolved {
        let url: URL
        let isSearch: Bool
    }

    static func resolve(_ input: String) -> Resolved? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if let url = URL(string: text), let scheme = url.scheme?.lowercased(), loadableSchemes.contains(scheme),
           scheme != "http" && scheme != "https" || url.host != nil {
            return Resolved(url: url, isSearch: false)
        }
        if !text.contains(" ") {
            let lower = text.lowercased()
            let isIP = lower.range(of: #"^\d{1,3}(\.\d{1,3}){3}(:\d+)?(/.*)?$"#, options: .regularExpression) != nil
            if lower.hasPrefix("localhost") || isIP, let url = URL(string: "http://" + text) {
                return Resolved(url: url, isSearch: false)
            }
            if text.contains("."), !text.hasPrefix("."), !text.hasSuffix("."),
               let url = URL(string: "https://" + text), let host = url.host, host.contains(".") {
                return Resolved(url: url, isSearch: false)
            }
        }
        return searchURL(for: text).map { Resolved(url: $0, isSearch: true) }
    }

    static func searchURL(for query: String) -> URL? {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#")
        let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) ?? query
        return URL(string: String(format: searchTemplate, encoded))
    }

    static func displayHost(_ url: URL?) -> String? {
        guard let url else { return nil }
        guard let host = url.host(percentEncoded: false), !host.isEmpty else { return url.absoluteString }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

enum SearchEngine: String, CaseIterable, Identifiable {
    case google, duckDuckGo, bing, kagi, ecosia

    static let defaultsKey = "searchEngine"
    static var current: SearchEngine {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(SearchEngine.init(rawValue:)) ?? .google
    }

    var id: String { rawValue }

    var name: String {
        switch self {
        case .google: "Google"
        case .duckDuckGo: "DuckDuckGo"
        case .bing: "Bing"
        case .kagi: "Kagi"
        case .ecosia: "Ecosia"
        }
    }

    var template: String {
        switch self {
        case .google: "https://www.google.com/search?q=%@"
        case .duckDuckGo: "https://duckduckgo.com/?q=%@"
        case .bing: "https://www.bing.com/search?q=%@"
        case .kagi: "https://kagi.com/search?q=%@"
        case .ecosia: "https://www.ecosia.org/search?q=%@"
        }
    }
}
