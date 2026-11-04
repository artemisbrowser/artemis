// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import Foundation
import Network

/// query completions from the profile's search engine. off by default and
/// never used in incognito, since each keystroke is sent to the engine
enum SearchSuggest {
    static let enabledKey = "searchSuggestionsEnabled"

    /// false when the engine has no endpoint; another engine's is never substituted
    static func supports(_ engine: SearchEngine) -> Bool { endpoint(engine) != nil }

    /// sent through `profile`'s extension proxy, the way its pages are
    static func suggestions(
        for query: String, profile: Profile.ID, engine: SearchEngine = .current, limit: Int = 3
    ) async -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isEnabled, trimmed.count >= 2, let url = url(for: trimmed, engine: engine)
        else { return [] }
        // the timeout keeps a reply within one keystroke's life
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 2)
        guard let (data, _) = try? await session(for: profile).data(for: request),
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

    /// cookie-blind and cacheless, one per profile, so its keystrokes leave through its
    /// own proxy and share no connection with another profile's
    private static var sessions: [Profile.ID: (proxy: UUID?, session: URLSession)] = [:]

    private static func session(for profile: Profile.ID) -> URLSession {
        let proxy = ExtensionProxyBridge.shared.activeProxy(in: profile)
        if let cached = sessions[profile], cached.proxy == proxy?.id { return cached.session }
        sessions[profile]?.session.finishTasksAndInvalidate()
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCache = nil
        if let proxy { config.proxyConfigurations = [proxy.config] }
        let session = URLSession(configuration: config)
        sessions[profile] = (proxy?.id, session)
        return session
    }

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
