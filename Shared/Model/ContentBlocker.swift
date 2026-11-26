import WebKit
import Observation

/// Ad blocking with WebKit's built-in content blocker: rules are compiled once into a fast native
/// format and applied by WebKit itself (no extension, no per-request Swift code).
///
/// Ships with a small built-in list so blocking works on first launch, then downloads EasyList (ads)
/// and EasyPrivacy (trackers), converts them to WebKit's rule format and refreshes them weekly.
@MainActor @Observable
final class ContentBlocker {
    static let identifier = "dew.adblock"
    static let listURLs = [
        URL(string: "https://easylist.to/easylist/easylist.txt")!,
        URL(string: "https://easylist.to/easylist/easyprivacy.txt")!,
    ]
    static let refreshInterval: TimeInterval = 7 * 86_400
    /// Bump when `listURLs` changes so existing installs fetch the new set right away.
    static let listsVersion = 2

    var isEnabled = UserDefaults.standard.object(forKey: "adBlockEnabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "adBlockEnabled")
            onChange?(true)
        }
    }
    private(set) var ruleList: WKContentRuleList?
    private(set) var ruleCount = UserDefaults.standard.integer(forKey: "adBlockRuleCount")
    private(set) var lastUpdated = UserDefaults.standard.object(forKey: "adBlockUpdated") as? Date
    private(set) var isUpdating = false
    private(set) var lastError: String?

    /// Called when the active rule list changes; the flag says whether to reload the current page.
    @ObservationIgnored var onChange: ((_ reload: Bool) -> Void)?

    var activeRuleList: WKContentRuleList? { isEnabled ? ruleList : nil }

    func start() async {
        guard let store = WKContentRuleListStore.default() else { return }
        if let list = try? await store.contentRuleList(forIdentifier: Self.identifier) {
            install(list, reload: true)
        } else {
            let baseline = FilterListConverter.baseline()
            if let list = try? await store.compileContentRuleList(forIdentifier: Self.identifier, encodedContentRuleList: baseline.json) {
                setStats(count: baseline.count, updated: nil)
                install(list, reload: true)
            }
        }
        let isStale = lastUpdated.map { Date().timeIntervalSince($0) > Self.refreshInterval } ?? true
            || UserDefaults.standard.integer(forKey: "adBlockListsVersion") != Self.listsVersion
        if isStale { await update() }
    }

    func update() async {
        guard !isUpdating, let store = WKContentRuleListStore.default() else { return }
        isUpdating = true
        defer { isUpdating = false }
        do {
            // Download the lists in parallel; use whichever arrive (EasyList alone still blocks ads).
            let texts = await withTaskGroup(of: String?.self) { group in
                for url in Self.listURLs {
                    group.addTask {
                        guard let result = try? await URLSession.shared.data(from: url),
                              (result.1 as? HTTPURLResponse)?.statusCode == 200 else { return nil }
                        return String(data: result.0, encoding: .utf8)
                    }
                }
                var results: [String] = []
                for await text in group { if let text { results.append(text) } }
                return results
            }
            guard !texts.isEmpty else { throw URLError(.cannotConnectToHost) }
            let text = texts.joined(separator: "\n")
            let tiers = await Task.detached(priority: .utility) { FilterListConverter.tiers(fromEasyList: text) }.value
            // Most complete first; fall back to simpler rule sets if WebKit rejects something.
            for tier in tiers {
                if let list = try? await store.compileContentRuleList(forIdentifier: Self.identifier, encodedContentRuleList: tier.json) {
                    setStats(count: tier.count, updated: .now)
                    UserDefaults.standard.set(Self.listsVersion, forKey: "adBlockListsVersion")
                    lastError = nil
                    install(list, reload: false)
                    return
                }
            }
            throw URLError(.cannotDecodeContentData)
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func install(_ list: WKContentRuleList, reload: Bool) {
        ruleList = list
        onChange?(reload)
    }

    private func setStats(count: Int, updated: Date?) {
        ruleCount = count
        lastUpdated = updated
        UserDefaults.standard.set(count, forKey: "adBlockRuleCount")
        UserDefaults.standard.set(updated, forKey: "adBlockUpdated")
    }
}

/// Converts Adblock Plus / EasyList filter syntax into WebKit content-blocker JSON.
/// Handles host rules, URL patterns with common options, element hiding and exceptions;
/// anything WebKit can't express faithfully (regex rules, scriptlets, :has-text…) is skipped.
enum FilterListConverter {
    struct Tier: Sendable {
        let json: String
        let count: Int
    }

    typealias Rule = [String: Any]
    private static let maxRules = 140_000

    // MARK: Built-in baseline

    static let baselineHosts = [
        "doubleclick.net", "googlesyndication.com", "googleadservices.com", "adservice.google.com",
        "googletagservices.com", "adnxs.com", "taboola.com", "outbrain.com", "criteo.com", "criteo.net",
        "amazon-adsystem.com", "pubmatic.com", "rubiconproject.com", "openx.net", "casalemedia.com",
        "advertising.com", "adsrvr.org", "moatads.com", "scorecardresearch.com", "quantserve.com",
        "smartadserver.com", "yieldmo.com", "sharethrough.com", "teads.tv", "33across.com", "media.net",
        "adform.net", "bidswitch.net", "indexww.com", "lijit.com", "sovrn.com", "contextweb.com",
        "revcontent.com", "mgid.com", "propellerads.com", "popads.net", "popcash.net", "exoclick.com",
        "adcolony.com", "ads-twitter.com", "ads.linkedin.com", "ads.yahoo.com", "adsafeprotected.com",
        "serving-sys.com", "zedo.com", "yieldlab.net", "adition.com", "smaato.net", "inmobi.com",
        "adroll.com", "trafficjunky.net", "juicyads.com", "zergnet.com", "adblade.com", "content.ad",
    ]

    static let baselineSelectors = [
        ".adsbygoogle", "ins.adsbygoogle", "[id^=\"google_ads_iframe\"]", "[id^=\"div-gpt-ad\"]",
        "[data-google-query-id]", "amp-ad", "amp-embed[type=\"taboola\"]", ".trc_rbox_container",
        "[id^=\"taboola-\"]", ".OUTBRAIN", ".ob-widget", "[data-ad-slot]", "iframe[src*=\"doubleclick.net\"]",
    ]

    static func baseline() -> Tier {
        var rules: [Rule] = baselineHosts.map { host in
            ["trigger": ["url-filter": hostAnchor + escape(host) + separator, "load-type": ["third-party"]],
             "action": ["type": "block"]]
        }
        rules.append(["trigger": ["url-filter": ".*"],
                      "action": ["type": "css-display-none", "selector": baselineSelectors.joined(separator: ", ")]])
        return Tier(json: encode(rules), count: rules.count)
    }

    // MARK: EasyList

    static func tiers(fromEasyList text: String) -> [Tier] {
        let parsed = parse(text)
        let candidates: [[Rule]] = [
            [parsed.hostBlocks, parsed.patternBlocks, parsed.cosmetic, parsed.exceptions],
            [parsed.hostBlocks, parsed.patternBlocks, parsed.exceptions],
            [parsed.hostBlocks, parsed.exceptions],
            [parsed.hostBlocks],
        ].map(fitted)
        return candidates.map { Tier(json: encode($0), count: $0.count) }
    }

    /// Keeps the rule count under WebKit's limit by trimming URL-pattern rules first, so exceptions
    /// (which stop sites breaking) are never the ones dropped.
    private static func fitted(_ groups: [[Rule]]) -> [Rule] {
        var groups = groups
        let overflow = groups.reduce(0) { $0 + $1.count } - maxRules
        if overflow > 0, groups.count > 1 {
            groups[1] = Array(groups[1].dropLast(min(overflow, groups[1].count)))
        }
        return Array(groups.joined().prefix(maxRules))
    }

    private struct Parsed {
        var hostBlocks: [Rule] = []
        var patternBlocks: [Rule] = []
        var cosmetic: [Rule] = []
        var exceptions: [Rule] = []
    }

    private static func parse(_ text: String) -> Parsed {
        var parsed = Parsed()
        var genericSelectors: [String] = []
        var domainSelectors: [String: [String]] = [:]

        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("!"), !line.hasPrefix("["), line.allSatisfy(\.isASCII) else { continue }

            // Element hiding: "##selector" or "a.com,b.com##selector".
            if let range = line.range(of: "##") {
                let domains = line[..<range.lowerBound]
                let selector = String(line[range.upperBound...])
                guard isSupported(selector: selector) else { continue }
                if domains.isEmpty {
                    genericSelectors.append(selector)
                } else {
                    let list = domains.split(separator: ",").map { String($0).lowercased() }
                    guard list.allSatisfy({ !$0.hasPrefix("~") && isHostname($0) }) else { continue }
                    domainSelectors[list.sorted().joined(separator: ","), default: []].append(selector)
                }
                continue
            }
            // Extended / exception cosmetic syntaxes WebKit can't do.
            if ["#@#", "#?#", "#$#", "#%#", "$$", "#@$#"].contains(where: line.contains) { continue }

            if line.hasPrefix("@@") {
                if let rule = networkRule(String(line.dropFirst(2)), exception: true) { parsed.exceptions.append(rule.rule) }
            } else if let rule = networkRule(line, exception: false) {
                if rule.isHostOnly { parsed.hostBlocks.append(rule.rule) } else { parsed.patternBlocks.append(rule.rule) }
            }
        }

        for start in stride(from: 0, to: genericSelectors.count, by: 400) {
            let chunk = genericSelectors[start..<min(start + 400, genericSelectors.count)]
            parsed.cosmetic.append(["trigger": ["url-filter": ".*"],
                                    "action": ["type": "css-display-none", "selector": chunk.joined(separator: ", ")]])
        }
        for (domains, selectors) in domainSelectors {
            parsed.cosmetic.append(["trigger": ["url-filter": ".*", "if-domain": domains.split(separator: ",").map { "*" + $0 }],
                                    "action": ["type": "css-display-none", "selector": selectors.joined(separator: ", ")]])
        }
        return parsed
    }

    private static let hostAnchor = "^[^:]+://+([^:/]+\\.)?"
    private static let separator = "[^a-zA-Z0-9_.%-]"

    private static let resourceTypes: [String: String] = [
        "script": "script", "image": "image", "stylesheet": "style-sheet", "font": "font", "media": "media",
        "xmlhttprequest": "raw", "subdocument": "document", "popup": "popup", "ping": "ping",
        "websocket": "websocket", "other": "other",
    ]

    private static func networkRule(_ line: String, exception: Bool) -> (rule: Rule, isHostOnly: Bool)? {
        var pattern = line
        var options: [String] = []
        if let dollar = line.lastIndex(of: "$") {
            pattern = String(line[..<dollar])
            options = line[line.index(after: dollar)...].split(separator: ",").map { String($0).lowercased() }
        }
        if pattern.count > 1, pattern.hasPrefix("/"), pattern.hasSuffix("/") { return nil } // regex rules

        var trigger: Rule = [:]
        var types: [String] = []
        var ifDomains: [String] = []
        var unlessDomains: [String] = []
        var pageException = false

        for option in options {
            if let type = resourceTypes[option] {
                types.append(type)
                continue
            }
            switch option {
            case "third-party", "3p": trigger["load-type"] = ["third-party"]
            case "~third-party", "1p", "first-party": trigger["load-type"] = ["first-party"]
            case "match-case": trigger["url-filter-is-case-sensitive"] = true
            case "important", "all": break
            case "document", "doc", "elemhide", "ehide", "generichide", "ghide":
                guard exception else { return nil }
                pageException = true
            default:
                guard option.hasPrefix("domain=") else { return nil } // csp=, redirect=, removeparam=, ~script…
                for domain in option.dropFirst(7).split(separator: "|").map(String.init) {
                    let negated = domain.hasPrefix("~")
                    let host = negated ? String(domain.dropFirst()) : domain
                    guard isHostname(host) else { return nil }
                    if negated { unlessDomains.append("*" + host) } else { ifDomains.append("*" + host) }
                }
            }
        }
        if !ifDomains.isEmpty && !unlessDomains.isEmpty { return nil }

        let action: Rule = ["type": exception ? "ignore-previous-rules" : "block"]

        if pageException {
            // "@@||site.com^$document": don't block anything on that site.
            guard pattern.hasPrefix("||"), pattern.hasSuffix("^") else { return nil }
            let host = String(pattern.dropFirst(2).dropLast())
            guard isHostname(host) else { return nil }
            return (["trigger": ["url-filter": ".*", "if-domain": ["*" + host]], "action": action], false)
        }

        guard let filter = urlFilter(from: pattern) else { return nil }
        trigger["url-filter"] = filter
        if !types.isEmpty { trigger["resource-type"] = types }
        if !ifDomains.isEmpty { trigger["if-domain"] = ifDomains }
        if !unlessDomains.isEmpty { trigger["unless-domain"] = unlessDomains }

        let hostOnly = !exception && pattern.hasPrefix("||") && pattern.hasSuffix("^")
            && isHostname(String(pattern.dropFirst(2).dropLast())) && types.isEmpty && ifDomains.isEmpty && unlessDomains.isEmpty
        return (["trigger": trigger, "action": action], hostOnly)
    }

    private static func urlFilter(from pattern: String) -> String? {
        var body = Substring(pattern)
        var result = ""
        if body.hasPrefix("||") {
            body = body.dropFirst(2)
            result = hostAnchor
        } else if body.hasPrefix("|") {
            body = body.dropFirst()
            result = "^"
        }
        var endAnchor = false
        if body.hasSuffix("|") {
            body = body.dropLast()
            endAnchor = true
        }
        // Too short/generic patterns would block far too much.
        guard body.filter({ $0 != "*" && $0 != "^" }).count >= 4 || !result.isEmpty else { return nil }
        guard !body.isEmpty else { return nil }
        for character in body {
            switch character {
            case "*": result += ".*"
            case "^": result += separator
            case ".", "+", "?", "$", "(", ")", "[", "]", "{", "}", "\\", "|": result += "\\" + String(character)
            default: result.append(character)
            }
        }
        if endAnchor { result += "$" }
        return result
    }

    private static func escape(_ host: String) -> String {
        host.replacingOccurrences(of: ".", with: "\\.")
    }

    private static func isHostname(_ value: String) -> Bool {
        !value.isEmpty && value.contains(".") && !value.hasSuffix(".*")
            && value.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }
    }

    private static let unsupportedSelectorParts = [
        ":-abp", ":has(", ":has-text", ":contains", ":xpath", ":matches-", ":upward", ":remove", ":style",
        ":watch-attr", ":min-text", ":others", "{", "}", "\\",
    ]

    private static func isSupported(selector: String) -> Bool {
        !selector.isEmpty && !unsupportedSelectorParts.contains(where: selector.contains)
    }

    private static func encode(_ rules: [Rule]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: rules) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }
}
