// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import Foundation

/// resolves raw url-field input: a URL or local path, then a bang, then a search
enum URLInput {
    /// query items that record where a visit came from rather than what the page is
    private static let trackingParameters: Set<String> = [
        "utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content", "utm_id",
        "fbclid", "gclid", "gclsrc", "dclid", "msclkid", "twclid", "igshid", "mkt_tok",
        "mc_cid", "mc_eid", "_hsenc", "_hsmi", "hsctatracking", "vero_id", "vero_conv",
        "yclid", "ysclid", "wickedid", "s_kwcid", "ref_src", "ref_url", "spm",
        "si", "pp", "feature", "share_id", "smid", "cmpid", "cid", "at_medium",
    ]

    /// the link minus its tracking parameters; a query that is only tracking is
    /// dropped whole
    static func withoutTrackingParameters(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let items = components.queryItems, !items.isEmpty
        else { return url }
        let kept = items.filter { !trackingParameters.contains($0.name.lowercased()) }
        guard kept.count != items.count else { return url }
        components.queryItems = kept.isEmpty ? nil : kept
        return components.url ?? url
    }

    static func resolve(_ input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return directURL(trimmed) ?? bangURL(trimmed) ?? searchURL(for: trimmed)
    }

    /// `!yt orbital mechanics` typed anywhere, not only in the command bar
    private static func bangURL(_ input: String) -> URL? {
        guard Bangs.isEnabled, let (trigger, query) = Bangs.split(input) else { return nil }
        return Bangs.lookup(trigger)?.url(for: query)
            ?? Bangs.fallbackURL(trigger: trigger, query: query)
    }

    /// the input as a navigable URL, or nil if it reads as a search query
    static func directURL(_ input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.contains("://") {
            return URL(string: trimmed)
        }

        // a path that doesn't exist is neither a file nor a host
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~/") {
            let path = (trimmed as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: path) else { return nil }
            return URL(fileURLWithPath: path)
        }

        let isHostLike =
            !trimmed.contains(" ")
            && (trimmed.contains(".") || trimmed.hasPrefix("localhost"))
        guard isHostLike,
            let url = URL(string: defaultScheme(for: trimmed) + trimmed),
            let host = url.host(), !host.isEmpty
        else { return nil }
        // lowercased so GitHub.com and github.com are the same page downstream
        guard host != host.lowercased() else { return url }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.host = host.lowercased()
        return components?.url ?? url
    }

    /// http for loopback and private-network hosts, https otherwise
    private static func defaultScheme(for input: String) -> String {
        let host = input
            .split(separator: "/", maxSplits: 1)[0]
            .split(separator: ":", maxSplits: 1)[0]
            .lowercased()
        let localHosts: Set<String> = ["localhost", "127.0.0.1", "0.0.0.0"]
        if localHosts.contains(host)
            || host.hasSuffix(".localhost")
            || host.hasSuffix(".local")
            || host.hasPrefix("192.168.")
            || host.hasPrefix("10.")
            || input.hasPrefix("[::1]")
        {
            return "http://"
        }
        return "https://"
    }

    /// a search on the current window's profile engine
    static func searchURL(for query: String) -> URL? {
        SearchEngine.current.searchURL(for: query)
    }
}
