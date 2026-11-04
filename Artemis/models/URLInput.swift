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
        "yclid", "ysclid", "wickedid", "s_kwcid", "ref_src", "ref_url",
        "smid", "cmpid", "at_medium",
    ]

    /// names that only track on these sites, keyed by registrable domain; on other
    /// sites the same name can be what the link points at
    private static let siteTrackingParameters: [String: Set<String>] = [
        "youtube.com": ["si", "pp", "feature"],
        "youtu.be": ["si", "pp", "feature"],
        "spotify.com": ["si"],
        "reddit.com": ["share_id"],
        "aliexpress.com": ["spm"],
        "alibaba.com": ["spm"],
        "taobao.com": ["spm"],
        "tmall.com": ["spm"],
    ]

    /// the link minus its tracking parameters; a query that is only tracking is
    /// dropped whole
    static func withoutTrackingParameters(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let items = components.queryItems, !items.isEmpty
        else { return url }
        let host = components.host?.lowercased() ?? ""
        let sited = siteTrackingParameters.first { host == $0.key || host.hasSuffix("." + $0.key) }?.value ?? []
        let kept = items.filter {
            let name = $0.name.lowercased()
            return !trackingParameters.contains(name) && !sited.contains(name)
        }
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

        // a scheme the text starts with, not a `://` further along in a path or query
        if let url = URL(string: trimmed), let scheme = url.scheme,
            trimmed.dropFirst(scheme.count).hasPrefix("://")
        {
            return url
        }

        // a path that doesn't exist is neither a file nor a host
        if isPathLike(trimmed) {
            let path = (trimmed as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: path) else { return nil }
            return URL(fileURLWithPath: path)
        }

        guard !trimmed.contains(" "), let url = URL(string: "https://" + trimmed), url.user() == nil,
            let host = url.host(percentEncoded: false)?.lowercased(), isServer(host),
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        components.scheme = defaultScheme(for: host)
        // lowercased so GitHub.com and github.com are the same page downstream
        components.encodedHost = components.encodedHost?.lowercased()
        return components.url ?? url
    }

    /// an absolute or home-relative path, read from the text alone
    static func isPathLike(_ input: String) -> Bool { input.hasPrefix("/") || input.hasPrefix("~/") }

    /// file extensions that are not top-level domains, so `report.pdf` is a search
    private static let documentExtensions: Set<String> = [
        "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "key", "pages", "numbers",
        "txt", "rtf", "csv", "odt", "ods", "odp", "epub", "html", "htm", "jpg", "jpeg",
        "png", "gif", "heic", "svg", "webp", "mp3", "mp4", "dmg", "exe", "log", "out",
        "js", "mjs", "ts", "jsx", "tsx", "json", "swift", "cpp", "hpp", "rb", "go", "php",
        "css", "scss", "xml", "yml", "yaml", "toml", "sql",
    ]

    /// a host typed with no scheme that names a server: a bracketed IPv6 address,
    /// localhost, four numbers, or a dotted name that isn't a file
    private static func isServer(_ host: String) -> Bool {
        if host.contains(":") { return true }
        let labels = host.split(separator: ".")
        guard host.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }),
            let last = labels.last
        else { return false }
        if last.allSatisfy(\.isNumber) { return labels.count == 4 && labels.allSatisfy { UInt8($0) != nil } }
        // no top-level domain is one letter
        guard last.count >= 2 else { return false }
        return labels.count > 1 ? !documentExtensions.contains(String(last)) : host == "localhost"
    }

    /// http for loopback and private-network hosts, https otherwise
    private static func defaultScheme(for host: String) -> String {
        let labels = host.split(separator: ".")
        let octets = labels.compactMap { UInt8($0) }
        let isPrivateIPv4 =
            labels.count == 4 && octets.count == 4
            && (octets[0] == 10 || octets[0] == 127 || octets == [0, 0, 0, 0]
                || (octets[0] == 192 && octets[1] == 168)
                || (octets[0] == 172 && (16...31).contains(octets[1]))
                || (octets[0] == 169 && octets[1] == 254))
        let isLocalName =
            host == "localhost" || [".localhost", ".local", ".lan", ".home.arpa"].contains { host.hasSuffix($0) }
        return isPrivateIPv4 || isLocalName || host == "::1" || host.hasPrefix("fe80:") ? "http" : "https"
    }

    /// a search on the current window's profile engine
    static func searchURL(for query: String) -> URL? {
        SearchEngine.current.searchURL(for: query)
    }
}
