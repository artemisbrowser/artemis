// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import Foundation

/// the search engines a query from the url field can run against. DuckDuckGo is the default.
enum SearchEngine: String, CaseIterable, Identifiable {
    case duckduckgo
    case google
    case bing
    case brave
    case yahoo
    case ecosia
    case startpage
    case kagi
    case qwant
    case perplexity
    case wikipedia

    var id: String { rawValue }

    /// app-wide key the default profile mirrors its engine into
    static let storageKey = "searchEngine"

    /// the app-wide choice, which is the default profile's; DuckDuckGo until one is made
    static var stored: SearchEngine {
        let raw = UserDefaults.standard.string(forKey: storageKey)
        return raw.flatMap(SearchEngine.init) ?? .duckduckgo
    }

    var label: String {
        switch self {
        case .duckduckgo: "DuckDuckGo"
        case .google: "Google"
        case .bing: "Bing"
        case .brave: "Brave"
        case .yahoo: "Yahoo"
        case .ecosia: "Ecosia"
        case .startpage: "Startpage"
        case .kagi: "Kagi"
        case .qwant: "Qwant"
        case .perplexity: "Perplexity"
        case .wikipedia: "Wikipedia"
        }
    }

    /// the query is appended as `q`, or `search` on Wikipedia
    private var endpoint: String {
        switch self {
        case .duckduckgo: "https://duckduckgo.com/"
        case .google: "https://www.google.com/search"
        case .bing: "https://www.bing.com/search"
        case .brave: "https://search.brave.com/search"
        case .yahoo: "https://search.yahoo.com/search"
        case .ecosia: "https://www.ecosia.org/search"
        case .startpage: "https://www.startpage.com/sp/search"
        case .kagi: "https://kagi.com/search"
        case .qwant: "https://www.qwant.com/"
        case .perplexity: "https://www.perplexity.ai/search"
        case .wikipedia: "https://en.wikipedia.org/w/index.php"
        }
    }

    func searchURL(for query: String) -> URL? {
        guard var components = URLComponents(string: endpoint) else { return nil }
        let name = self == .wikipedia ? "search" : "q"
        // queryItems leaves `+` bare, which every engine reads as a space
        components.percentEncodedQueryItems = [
            URLQueryItem(name: name, value: query.addingPercentEncoding(withAllowedCharacters: Bangs.queryAllowed))
        ]
        return components.url
    }
}
