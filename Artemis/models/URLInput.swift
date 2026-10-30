import Foundation

/// resolves raw url-field input into a loadable URL
///
/// - explicit scheme (`https://…`, `file://…`) → used as-is
/// - host-like (no spaces, has a dot, or localhost) → `https://` prefixed
/// - anything else → search engine query
enum URLInput {
    /// Parameters a site (or whoever linked you) hangs on a URL to record where
    /// you came from. They aren't the page, so a link you copy to send someone
    /// shouldn't carry them — this is what Arc calls "Super Copy".
    private static let trackingParameters: Set<String> = [
        "utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content", "utm_id",
        "fbclid", "gclid", "gclsrc", "dclid", "msclkid", "twclid", "igshid", "mkt_tok",
        "mc_cid", "mc_eid", "_hsenc", "_hsmi", "hsctatracking", "vero_id", "vero_conv",
        "yclid", "ysclid", "wickedid", "s_kwcid", "ref_src", "ref_url", "spm",
        "si", "pp", "feature", "share_id", "smid", "cmpid", "cid", "at_medium",
    ]

    /// the same link, minus the parameters that describe *you* rather than it.
    /// a URL that is nothing but tracking (some share links) keeps its query,
    /// since stripping it would break the link rather than clean it
    static func withoutTrackingParameters(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let items = components.queryItems, !items.isEmpty
        else { return url }
        let kept = items.filter { !trackingParameters.contains($0.name.lowercased()) }
        guard kept.count != items.count else { return url }  // nothing to strip
        components.queryItems = kept.isEmpty ? nil : kept
        return components.url ?? url
    }

    static func resolve(_ input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return directURL(trimmed) ?? bangURL(trimmed) ?? searchURL(for: trimmed)
    }

    /// `!yt orbital mechanics` typed anywhere, not only in the command bar
    static func bangURL(_ input: String) -> URL? {
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

        // a typed or pasted path is a local file, not a search. a path that
        // isn't there is neither — falling through would build https:///Users/…,
        // a url with no host that can only fail to load
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
        // hosts are case-insensitive; carrying the typed case through would make
        // GitHub.com a different page from github.com everywhere downstream
        guard host != host.lowercased() else { return url }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.host = host.lowercased()
        return components?.url ?? url
    }

    /// local dev servers rarely speak TLS — default them to http
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

    /// run the query against the user's chosen engine (DuckDuckGo by default)
    static func searchURL(for query: String) -> URL? {
        SearchEngine.current.searchURL(for: query)
    }
}
