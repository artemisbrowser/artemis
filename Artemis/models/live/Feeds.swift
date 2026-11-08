// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import Foundation

/// RSS 2.0, RSS 1.0 (RDF), Atom 1.0 and 0.3, and JSON Feed: reading one, and finding the one a page declares
enum Feeds {
    nonisolated static let accept =
        "application/atom+xml, application/rss+xml, application/feed+json, application/xml;q=0.9, "
        + "text/xml;q=0.9, */*;q=0.8"
    nonisolated static let maxItems = 50

    nonisolated struct Parsed: Sendable {
        var title: String
        /// newest first, at most `maxItems`
        var rows: [LiveRow]
        /// Gmail's unread count, which can pass the entries it lists
        var fullcount: Int?
    }

    @concurrent
    nonisolated static func rows(from response: ProfileFetch.Response) async -> LiveOutcome {
        switch response.status {
        case 200..<300:
            guard let feed = parse(response.body, base: response.url) else { return .unavailable(.unreadable) }
            return .rows(feed.rows, total: nil)
        case 429: return .unavailable(.rateLimited)
        default: return .unavailable(.network)
        }
    }

    /// nil when `data` is no feed this reads. relative links resolve against `base`; an internal
    /// entity declaration, in any encoding, refuses the whole document, and external ones never resolve
    nonisolated static func parse(_ data: Data, base: URL) -> Parsed? {
        let head = data.prefix(64).drop { [0x20, 0x09, 0x0A, 0x0D, 0xEF, 0xBB, 0xBF].contains($0) }
        if head.first == UInt8(ascii: "{") { return parseJSON(data, base: base) }
        let reader = FeedXML()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = reader
        parser.parse()
        guard reader.isFeed else { return nil }
        let rows = reader.items.enumerated().compactMap { index, item -> (Int, LiveRow)? in
            let link = [item.link, item.guidLink, item.about].lazy.compactMap { resolve($0, base) }.first
            let title = item.title.isEmpty ? stripTags(item.summary) : item.title
            let row = LiveRow(
                id: [item.id, item.guid, item.about, link?.absoluteString ?? ""].first { !$0.isEmpty } ?? "",
                title: title.isEmpty ? (link?.host() ?? "") : title,
                subtitle: item.author.isEmpty ? item.email : item.author,
                link: link, date: date(item.date.isEmpty ? item.updated : item.date))
            return row.map { (index, $0) }
        }
        return Parsed(title: LiveRow.plain(reader.title), rows: newestFirst(rows), fullcount: reader.fullcount)
    }

    private nonisolated static func parseJSON(_ data: Data, base: URL) -> Parsed? {
        guard let feed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            (feed["version"] as? String)?.hasPrefix("https://jsonfeed.org/version/") == true,
            let items = feed["items"] as? [[String: Any]]
        else { return nil }
        let rows = items.prefix(maxItems * 4).enumerated().compactMap { index, item -> (Int, LiveRow)? in
            let link = [item["url"], item["external_url"]].lazy
                .compactMap { ($0 as? String).flatMap { resolve($0, base) } }.first
            let authors = (item["authors"] as? [[String: Any]]) ?? [(item["author"] as? [String: Any]) ?? [:]]
            let summary = item["content_text"] as? String ?? stripTags(item["content_html"] as? String ?? "")
            let row = LiveRow(
                id: (item["id"].map { "\($0)" }) ?? link?.absoluteString ?? "",
                title: (item["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? summary,
                subtitle: authors.first?["name"] as? String ?? "", link: link,
                date: date(item["date_published"] as? String ?? item["date_modified"] as? String ?? ""))
            return row.map { (index, $0) }
        }
        return Parsed(title: LiveRow.plain(feed["title"] as? String ?? ""), rows: newestFirst(rows), fullcount: nil)
    }

    /// dated rows by date, then undated ones in document order; a repeated id keeps its first row
    private nonisolated static func newestFirst(_ rows: [(Int, LiveRow)]) -> [LiveRow] {
        var ids: Set<String> = []
        return Array(
            rows.sorted { a, b in
                let da = a.1.date ?? .distantPast, db = b.1.date ?? .distantPast
                return da != db ? da > db : a.0 < b.0
            }
            .map(\.1).filter { ids.insert($0.id).inserted }.prefix(maxItems))
    }

    private nonisolated static func resolve(_ raw: String, _ base: URL) -> URL? {
        let trimmed = decodeEntities(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !trimmed.isEmpty, let url = URL(string: trimmed, relativeTo: base)?.absoluteURL,
            ["http", "https"].contains(url.scheme?.lowercased())
        else { return nil }
        return url
    }

    /// RFC 3339 and RFC 822, the forms feeds and GitHub write
    nonisolated static func date(_ raw: String) -> Date? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        let variants: [ISO8601DateFormatter.Options] = [
            [.withInternetDateTime], [.withInternetDateTime, .withFractionalSeconds],
        ]
        for options in variants {
            iso.formatOptions = options
            if let date = iso.date(from: text) { return date }
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for format in [
            "EEE, d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm:ss zzz", "d MMM yyyy HH:mm:ss Z",
            "d MMM yyyy HH:mm:ss zzz", "EEE, d MMM yyyy HH:mm Z", "EEE, d MMM yyyy HH:mm zzz",
            "EEE, d MMM yy HH:mm:ss Z", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd",
        ] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    // MARK: - Markup

    nonisolated static func stripTags(_ html: String) -> String {
        var text = ""
        var inTag = false
        for character in html {
            switch character {
            case "<": inTag = true
            case ">" where inTag:
                inTag = false
                text.append(" ")
            default: if !inTag { text.append(character) }
            }
        }
        return decodeEntities(text)
    }

    /// the named entities feeds use, and numeric ones
    nonisolated static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let named: [Substring: String] = [
            "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "hellip": "…", "mdash": "—",
            "ndash": "–", "rsquo": "\u{2019}", "lsquo": "\u{2018}", "rdquo": "\u{201D}", "ldquo": "\u{201C}",
        ]
        var out = ""
        var rest = text[...]
        while let amp = rest.firstIndex(of: "&") {
            out += rest[..<amp]
            let tail = rest[rest.index(after: amp)...]
            guard let semi = tail.prefix(10).firstIndex(of: ";") else {
                out += "&"
                rest = tail
                continue
            }
            let name = tail[..<semi]
            var scalar: Unicode.Scalar?
            if name.hasPrefix("#x") || name.hasPrefix("#X") {
                scalar = UInt32(name.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init)
            } else if name.hasPrefix("#") {
                scalar = UInt32(name.dropFirst()).flatMap(Unicode.Scalar.init)
            }
            if let scalar {
                out.unicodeScalars.append(scalar)
            } else if let value = named[name] {
                out += value
            } else {
                out += "&" + name + ";"
            }
            rest = tail[tail.index(after: semi)...]
        }
        return out + rest
    }

    // MARK: - Discovery

    nonisolated private static let feedTypes: Set<String> = [
        "application/rss+xml", "application/atom+xml", "application/feed+json", "application/rdf+xml",
    ]

    /// the feeds a page's `<link rel="alternate">` tags declare before its `</head>`, in page order
    @concurrent
    nonisolated static func links(inHTML data: Data, base: URL) async -> [URL] {
        let html = String(decoding: data, as: UTF8.self)
        var found: [URL] = []
        var rest = html[..<(html.range(of: "</head", options: .caseInsensitive)?.lowerBound ?? html.endIndex)]
        while let open = rest.range(of: "<link", options: .caseInsensitive) {
            rest = rest[open.upperBound...]
            guard let first = rest.first, first.isWhitespace, let close = rest.firstIndex(of: ">") else { continue }
            let attributes = tagAttributes(rest[..<close])
            rest = rest[close...]
            guard attributes["rel"]?.lowercased().split(separator: " ").contains("alternate") == true,
                let type = attributes["type"]?.lowercased().trimmingCharacters(in: .whitespaces),
                feedTypes.contains(type), let url = attributes["href"].flatMap({ resolve($0, base) }),
                !found.contains(url)
            else { continue }
            found.append(url)
        }
        return found
    }

    /// a tag's attributes, names lowercased; values quoted either way or bare
    private nonisolated static func tagAttributes(_ tag: Substring) -> [String: String] {
        var result: [String: String] = [:]
        var rest = tag
        while true {
            rest = rest.drop { $0.isWhitespace || $0 == "/" }
            let name = rest.prefix { !$0.isWhitespace && $0 != "=" && $0 != "/" }
            guard !name.isEmpty else { return result }
            rest = rest[name.endIndex...].drop(while: \.isWhitespace)
            guard rest.first == "=" else {
                result[name.lowercased()] = ""
                continue
            }
            rest = rest.dropFirst().drop(while: \.isWhitespace)
            let value: Substring
            if let quote = rest.first, quote == "\"" || quote == "'" {
                let body = rest.dropFirst()
                value = body.prefix { $0 != quote }
                rest = body[value.endIndex...].dropFirst()
            } else {
                value = rest.prefix { !$0.isWhitespace }
                rest = rest[value.endIndex...]
            }
            result[name.lowercased()] = String(value)
        }
    }

    /// paths sites serve a feed at without declaring it
    nonisolated private static let commonPaths = ["/feed", "/feed.xml", "/rss.xml", "/atom.xml", "/index.xml"]

    /// `page` itself when it is a feed, else the feeds it declares, else those at the common paths,
    /// keeping only the ones that read as feeds. no cookies are sent
    static func discover(from page: URL, in space: Space) async -> [(url: URL, title: String)] {
        guard let profile = LiveSource.admittedProfile(of: space),
            let response = try? await ProfileFetch.send(
                page, accept: "text/html, " + accept, withCookies: false, in: profile),
            (200..<300).contains(response.status)
        else { return [] }
        if let feed = await parsed(response.body, base: response.url) { return [(response.url, feed.title)] }
        let declared = await links(inHTML: response.body, base: response.url)
        let candidates =
            declared.isEmpty
            ? commonPaths.compactMap { URL(string: $0, relativeTo: response.url)?.absoluteURL }
            : Array(declared.prefix(5))
        let found = await withTaskGroup(of: (Int, URL, String)?.self) { group in
            for (index, url) in candidates.enumerated() {
                group.addTask {
                    guard let reply = try? await ProfileFetch.send(url, accept: accept, withCookies: false, in: profile),
                        (200..<300).contains(reply.status), let feed = await parsed(reply.body, base: reply.url)
                    else { return nil }
                    return (index, reply.url, feed.title)
                }
            }
            var found: [(Int, URL, String)] = []
            for await result in group { if let result { found.append(result) } }
            return found
        }
        guard LiveSource.admittedProfile(of: space) == profile else { return [] }
        return found.sorted { $0.0 < $1.0 }.map { ($0.1, $0.2) }
    }

    @concurrent
    private nonisolated static func parsed(_ data: Data, base: URL) async -> Parsed? {
        parse(data, base: base)
    }
}

/// the XMLParser delegate behind `Feeds.parse`, reading elements by local name
nonisolated private final class FeedXML: NSObject, XMLParserDelegate {
    struct Item {
        var title = "", titleType = "", link = "", guid = "", guidLink = "", id = "", about = ""
        var date = "", updated = "", author = "", email = "", summary = ""
    }

    private(set) var isFeed = false
    private(set) var title = ""
    private(set) var fullcount: Int?
    private(set) var items: [Item] = []

    private var item: Item?
    private var path: [String] = []
    /// each open element's text, its descendants' included
    private var texts: [String] = []
    private var guidIsPermaLink = true

    func parser(
        _ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
        attributes: [String: String] = [:]
    ) {
        if path.isEmpty {
            isFeed = ["rss", "RDF", "feed"].contains(name)
            if !isFeed { return parser.abortParsing() }
        }
        let direct = ["item", "entry"].contains(path.last ?? "")
        path.append(name)
        texts.append("")
        switch name {
        case "item", "entry":
            item = Item(about: attributes["rdf:about"] ?? attributes["about"] ?? "")
        case "link" where direct:
            // Atom's link is its href; RSS's is its text
            if (attributes["rel"] ?? "alternate") == "alternate", let href = attributes["href"],
                item?.link.isEmpty == true
            {
                item?.link = href
            }
        case "title" where direct:
            item?.titleType = attributes["type"]?.lowercased() ?? ""
        case "guid":
            guidIsPermaLink = attributes["isPermaLink"]?.lowercased() != "false"
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) {
        isFeed = false
        parser.abortParsing()
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if !texts.isEmpty { texts[texts.count - 1] += string }
    }

    func parser(_ parser: XMLParser, foundCDATA block: Data) {
        if !texts.isEmpty { texts[texts.count - 1] += String(decoding: block, as: UTF8.self) }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        guard let text = texts.popLast() else { return }
        path.removeLast()
        if !texts.isEmpty { texts[texts.count - 1] += text }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parent = path.last ?? ""
        guard var current = item else {
            if name == "title", ["channel", "feed"].contains(parent) { title = value }
            if name == "fullcount" { fullcount = Int(value) }
            return
        }
        let direct = parent == "item" || parent == "entry"
        switch name {
        case "item", "entry":
            items.append(current)
            item = nil
            if items.count >= Feeds.maxItems * 4 { parser.abortParsing() }
            return
        case "title" where direct:
            current.title = current.titleType == "html" ? Feeds.stripTags(value) : Feeds.decodeEntities(value)
        case "link" where direct:
            if current.link.isEmpty { current.link = value }
        case "guid" where direct:
            current.guid = value
            if guidIsPermaLink { current.guidLink = value }
        case "id" where direct:
            current.id = value
        case "pubDate", "published", "issued", "date":
            if current.date.isEmpty { current.date = value }
        case "updated", "modified":
            if current.updated.isEmpty { current.updated = value }
        case "name" where parent == "author":
            current.author = value
        case "email" where parent == "author":
            current.email = value
        case "author" where direct, "creator" where direct:
            if current.author.isEmpty, current.email.isEmpty { current.author = value }
        case "description" where direct, "summary" where direct, "content" where direct:
            if current.summary.isEmpty { current.summary = value }
        default:
            break
        }
        item = current
    }
}
