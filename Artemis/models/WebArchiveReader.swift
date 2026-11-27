// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import WebKit

/// a local .webarchive shown as a saved copy: a sandboxed page with an opaque origin and scripts off,
/// its resources served from the file under a random host per open, and none from the network
final class WebArchiveReader: NSObject, WKURLSchemeHandler {
    nonisolated static let scheme = "artemis-archive"
    /// on every response, frames included: Chromium's MHTML sandbox, less popups so a link click reaches the tab
    static let policy =
        "sandbox allow-popups; default-src \(scheme): data:; style-src \(scheme): data: 'unsafe-inline'; "
        + "script-src 'none'; object-src 'none'; form-action 'none'; base-uri 'none'"
    nonisolated private static let maxBytes = 200 << 20, maxResources = 10_000, maxDepth = 10

    nonisolated enum Failure: Error {
        case tooLarge, unreadable

        var message: String {
            switch self {
            case .tooLarge: "This web archive is too large to open."
            case .unreadable: "This file isn't a web archive Artemis can read."
            }
        }
    }

    /// every refusal the error page shows for an archive
    static let refusals: Set = [Failure.tooLarge.message, Failure.unreadable.message, BrowserTab.webArchiveError]

    let file: URL
    /// the address the page was saved from, when it was a web page
    let saved: URL?
    /// where the page loads in the reader
    let page: URL
    private let resources: [String: (data: Data, type: String)]

    init(file: URL) async throws {
        self.file = file
        (saved, page, resources) = try await Self.read(file)
        super.init()
    }

    /// the archive's pages and resources, rewritten off the main thread
    @concurrent nonisolated private static func read(_ file: URL) async throws -> (
        saved: URL?, page: URL, resources: [String: (data: Data, type: String)]
    ) {
        let token = String((0..<16).map { _ in "abcdefghijklmnopqrstuvwxyz0123456789".randomElement()! })
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? .max
        guard size <= maxBytes else { throw Failure.tooLarge }
        guard let data = try? Data(contentsOf: file),
            let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let main = root["WebMainResource"] as? [String: Any], let mainURL = address(of: main)
        else { throw Failure.unreadable }
        let saved = ["http", "https"].contains(mainURL.scheme?.lowercased()) ? mainURL : nil
        let page = mirror(mainURL, token) ?? URL(string: "\(scheme)://local.\(token)/")!
        var resources: [String: (data: Data, type: String)] = [:]
        var count = 0
        func add(_ archive: [String: Any], depth: Int) throws {
            guard depth <= Self.maxDepth else { throw Failure.unreadable }
            let parts = [archive["WebMainResource"] as Any] + (archive["WebSubresources"] as? [Any] ?? [])
            for case let resource as [String: Any] in parts {
                count += 1
                guard count <= maxResources else { throw Failure.tooLarge }
                guard let real = address(of: resource), let body = resource["WebResourceData"] as? Data,
                    let at = mirror(real, token) ?? (count == 1 ? page : nil), resources[key(at)] == nil
                else { continue }
                resources[key(at)] = served(body, from: real, resource, token)
            }
            for case let frame as [String: Any] in archive["WebSubframeArchives"] as? [Any] ?? [] {
                try add(frame, depth: depth + 1)
            }
        }
        try add(root, depth: 0)
        return (saved, page, resources)
    }

    /// a configuration that holds nothing of the profile: no jar, no extensions, no autofill scripts
    func configuration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.setURLSchemeHandler(self, forURLScheme: Self.scheme)
        if configuration.preferences.responds(to: Selector(("_setDNSPrefetchingEnabled:"))) {
            unsafeBitCast(configuration.preferences, to: WKPreferencesPrefetchSPI.self)._setDNSPrefetchingEnabled(false)
        }
        return configuration
    }

    /// true for the reader's own pages, the only ones it loads
    func serves(_ url: URL) -> Bool { url.scheme == Self.scheme && resources[Self.key(url)] != nil }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let found = resources[Self.key(url)]
        let headers = [
            "Content-Type": found?.type ?? "text/plain", "Content-Security-Policy": Self.policy,
            "Access-Control-Allow-Origin": "*", "X-DNS-Prefetch-Control": "off",
        ]
        task.didReceive(HTTPURLResponse(url: url, statusCode: found == nil ? 404 : 200, httpVersion: "HTTP/1.1", headerFields: headers)!)
        task.didReceive(found?.data ?? Data())
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}

    nonisolated private static func address(of resource: [String: Any]) -> URL? {
        (resource["WebResourceURL"] as? String).flatMap(URL.init(string:))
    }

    /// a resource's lookup key: host, decoded path and query, so WebKit's re-encoding still finds it
    nonisolated private static func key(_ url: URL) -> String {
        let path = url.path(percentEncoded: false)
        return (url.host() ?? "").lowercased() + (path.isEmpty ? "/" : path) + (url.query().map { "?" + $0 } ?? "")
    }

    /// where the reader serves an http(s) address; nil for any other
    nonisolated private static func mirror(_ real: URL, _ token: String) -> URL? {
        guard ["http", "https"].contains(real.scheme?.lowercased()), let host = real.host(), !host.isEmpty,
            var parts = URLComponents(url: real, resolvingAgainstBaseURL: false)
        else { return nil }
        parts.scheme = scheme
        parts.host = host.lowercased() + "." + token
        parts.port = nil
        parts.user = nil
        parts.password = nil
        parts.fragment = nil
        return parts.url
    }

    nonisolated private static func mirrored(_ string: String, _ token: String) -> String {
        URL(string: string.hasPrefix("//") ? "https:" + string : string).flatMap { mirror($0, token) }?.absoluteString ?? string
    }

    nonisolated private static let cssURL = try! NSRegularExpression(
        pattern: #"(url\(\s*["']?|@import\s+["'])((?:https?:)?//[^)"'\s]+)"#, options: .caseInsensitive)
    nonisolated private static let tag = try! NSRegularExpression(pattern: #"<([A-Za-z][\w:-]*)(\s[^>]*)>"#)
    nonisolated private static let attribute = try! NSRegularExpression(
        pattern: #"(\s)([\w:-]+)(\s*=\s*)(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))"#)
    nonisolated private static let srcsetURL = try! NSRegularExpression(pattern: #"(?:https?:)?//[^\s,]+"#)
    nonisolated private static let leadingURL = try! NSRegularExpression(pattern: #"^(?:https?:)?//\S+"#)

    /// `text` with each match replaced by `transform` of its groups, nil for a group that took no part
    nonisolated private static func replacing(
        _ pattern: NSRegularExpression, in text: String, _ transform: ([String?]) -> String
    ) -> String {
        let ns = text as NSString
        var out = "", last = 0
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            out += transform(
                (0..<match.numberOfRanges).map {
                    match.range(at: $0).location == NSNotFound ? nil : ns.substring(with: match.range(at: $0))
                })
            last = NSMaxRange(match.range)
        }
        return out + ns.substring(from: last)
    }

    /// a resource's bytes and type; markup and stylesheets load their resources from the reader
    /// and send links to the live site
    nonisolated private static func served(_ body: Data, from real: URL, _ resource: [String: Any], _ token: String) -> (
        data: Data, type: String
    ) {
        let type = (resource["WebResourceMIMEType"] as? String ?? "application/octet-stream").lowercased()
        let charset = resource["WebResourceTextEncodingName"] as? String
        guard ["text/html", "application/xhtml+xml", "text/css", "image/svg+xml"].contains(type) else {
            return (body, charset.map { "\(type); charset=\($0)" } ?? type)
        }
        let named = charset.map { CFStringConvertEncodingToNSStringEncoding(CFStringConvertIANACharSetNameToEncoding($0 as CFString)) }
        guard let text = String(data: body, encoding: named.map(String.Encoding.init(rawValue:)) ?? .utf8) ?? String(data: body, encoding: .utf8)
        else { return (body, type) }
        var rewritten = replacing(cssURL, in: text) { "\($0[1]!)\(mirrored($0[2]!, token))" }
        if type != "text/css" {
            // no tag ends past the last ">": stopping there keeps a tail of unclosed tags linear
            let scalars = rewritten.unicodeScalars
            let end = scalars.lastIndex(of: ">").map(scalars.index(after:)) ?? scalars.startIndex
            rewritten =
                replacing(tag, in: String(scalars[..<end])) {
                    "<\($0[1]!)\(rewrite(attributes: $0[2]!, of: $0[1]!.lowercased(), base: real, token))>"
                } + String(scalars[end...])
        }
        return (Data(rewritten.utf8), "\(type); charset=utf-8")
    }

    nonisolated private static func rewrite(attributes: String, of tag: String, base: URL, _ token: String) -> String {
        replacing(attribute, in: attributes) { found -> String in
            let name = found[2]!.lowercased(), value = found[4] ?? found[5] ?? found[6] ?? ""
            let next: String
            if (tag == "a" || tag == "area") && name == "href" {
                // absolute and live, so every way of opening a link sees the real address
                let resolved = URL(string: value.replacing("&amp;", with: "&"), relativeTo: base)?.absoluteString
                next = value.hasPrefix("#") ? value : resolved ?? value
            } else if name == "srcset" {
                next = replacing(srcsetURL, in: value) { mirrored($0[0]!, token) }
            } else if ["src", "href", "poster", "background", "data", "xlink:href"].contains(name) {
                next = replacing(leadingURL, in: value) { mirrored($0[0]!, token) }
            } else {
                return found[0]!
            }
            let quote = found[4] != nil ? "\"" : found[5] != nil ? "'" : ""
            return "\(found[1]!)\(found[2]!)\(found[3]!)\(quote)\(next)\(quote)"
        }
    }
}

/// private WKPreferences SPI, via `unsafeBitCast` and guarded by `responds(to:)`
@objc private protocol WKPreferencesPrefetchSPI {
    func _setDNSPrefetchingEnabled(_ enabled: Bool)
}
