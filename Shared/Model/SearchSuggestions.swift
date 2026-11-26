import Foundation

/// Live search suggestions from the search engine (OpenSearch JSON: ["query", ["suggestion", …]]).
/// Only Google and DuckDuckGo offer an open endpoint; others return nothing (local suggestions still show).
enum SearchSuggestions {
    static func endpoint(for engine: SearchEngine, query: String) -> URL? {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#")
        guard let q = query.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        switch engine {
        case .google: return URL(string: "https://suggestqueries.google.com/complete/search?client=firefox&q=\(q)")
        case .duckDuckGo: return URL(string: "https://duckduckgo.com/ac/?type=list&q=\(q)")
        case .bing, .kagi, .ecosia: return nil
        }
    }

    static func fetch(_ query: String, engine: SearchEngine) async -> [String] {
        guard let url = endpoint(for: engine, query: query) else { return [] }
        var request = URLRequest(url: url, timeoutInterval: 4)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
              json.count > 1, let list = json[1] as? [String] else { return [] }
        return list
    }
}
