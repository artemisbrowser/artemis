import Foundation

/// query completions from the profile's search engine. off by default and never
/// used in incognito: turning it on means every keystroke in the command bar
/// leaves the machine.
enum SearchSuggest {
    static let enabledKey = "searchSuggestionsEnabled"

    /// engines whose completions we can ask for. the rest have no endpoint we
    /// speak, and silently borrowing another engine's would send your typing to
    /// a company you didn't choose
    static func supports(_ engine: SearchEngine) -> Bool { endpoint(engine) != nil }

    static func suggestions(
        for query: String, engine: SearchEngine = .current, limit: Int = 3
    ) async -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isEnabled, trimmed.count >= 2, let url = url(for: trimmed, engine: engine)
        else { return [] }
        guard let (data, _) = try? await session.data(from: url),
            let root = try? JSONSerialization.jsonObject(with: data) as? [Any],
            root.count >= 2
        else { return [] }
        let list = (root[1] as? [Any])?.compactMap { $0 as? String } ?? []
        return
            list
            .filter { $0.caseInsensitiveCompare(trimmed) != .orderedSame }
            .prefix(limit)
            .map { $0 }
    }

    /// its own session: no cookies, no cache, and a short leash, so a slow
    /// endpoint can't outlive the keystroke that asked
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    private static func url(for query: String, engine: SearchEngine) -> URL? {
        guard let template = endpoint(engine),
            let escaped = query.addingPercentEncoding(withAllowedCharacters: Bangs.queryAllowed)
        else { return nil }
        return URL(string: template.replacingOccurrences(of: "{q}", with: escaped))
    }

    /// endpoints that answer with OpenSearch's `[query, [suggestions]]`
    private static func endpoint(_ engine: SearchEngine) -> String? {
        switch engine {
        case .duckduckgo: "https://ac.duckduckgo.com/ac/?q={q}&type=list"
        case .google: "https://suggestqueries.google.com/complete/search?client=firefox&q={q}"
        case .bing: "https://api.bing.com/osjson.aspx?query={q}"
        case .brave: "https://search.brave.com/api/suggest?q={q}"
        case .ecosia: "https://ac.ecosia.org/autocomplete?q={q}&type=list"
        case .wikipedia:
            "https://en.wikipedia.org/w/api.php?action=opensearch&limit=5&namespace=0&format=json&search={q}"
        case .yahoo, .startpage, .kagi, .qwant, .perplexity: nil
        }
    }
}
