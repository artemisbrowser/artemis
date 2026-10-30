import Foundation

/// Reading another browser's bookmarks.
///
/// Artemis has no bookmarks — pinned tabs and spaces are the bookmarks — so an
/// import is a translation, not a copy: a top-level folder becomes a space and
/// its links become that space's pinned tabs. Nesting deeper than that is
/// flattened into the folder it came from rather than dropped, because a link
/// three folders down is still a link the person kept.
nonisolated enum BookmarkImport {
    struct Link: Equatable {
        var title: String
        var url: URL
    }

    /// one space-to-be
    struct Folder: Equatable {
        var name: String
        var links: [Link]
    }

    struct Result: Equatable {
        var folders: [Folder]
        /// links that sat at the top level, belonging to no folder
        var loose: [Link]

        var linkCount: Int { folders.reduce(loose.count) { $0 + $1.links.count } }
        var isEmpty: Bool { linkCount == 0 }
    }

    enum Format {
        /// the Netscape bookmark file every browser can export, Safari included
        case html
        /// Chrome and the Chromium family: the `Bookmarks` file in the profile
        case chromeJSON
    }

    /// Pick a parser by looking at the file rather than trusting its name: a
    /// Chrome profile's bookmark file is called `Bookmarks` with no extension,
    /// and an exported one is `.html` whoever wrote it.
    static func format(of data: Data) -> Format? {
        guard let head = String(data: data.prefix(2048), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        else { return nil }
        if head.hasPrefix("{") { return .chromeJSON }
        if head.lowercased().contains("<!doctype netscape-bookmark-file")
            || head.lowercased().contains("<dl") || head.lowercased().contains("<a href")
        {
            return .html
        }
        return nil
    }

    /// Bookmark files are full of things that aren't pages: `javascript:`
    /// bookmarklets, `place:` queries, `chrome://` internals. A pinned tab can
    /// only ever be a page, so only pages come across.
    private static func isWeb(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased()
        return (scheme == "http" || scheme == "https") && url.host()?.isEmpty == false
    }

    static func parse(_ data: Data) -> Result? {
        switch format(of: data) {
        case .html: parseHTML(data)
        case .chromeJSON: parseChrome(data)
        case nil: nil
        }
    }

    // MARK: - Netscape HTML

    /// Tolerant by design. The format is thirty years of browsers each writing
    /// slightly different markup, so this tracks the two things every one of
    /// them agrees on — `<H3>` names a folder, `<A HREF>` is a link — and uses
    /// `</DL>` to close a folder. Anything else in the file is ignored.
    private static func parseHTML(_ data: Data) -> Result? {
        guard let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
        else { return nil }

        var folders: [Folder] = []
        var loose: [Link] = []
        /// the folder names we are inside, outermost first
        var stack: [String] = []
        /// links collected for each open folder, keyed by its depth
        var pending: [Int: [Link]] = [:]

        for token in tags(in: text) {
            switch token {
            case .folder(let name):
                stack.append(name)
            case .link(let link):
                // depth 1 is a top-level folder; anything deeper is flattened
                // into it, since a link kept three folders down is still kept
                if stack.isEmpty {
                    loose.append(link)
                } else {
                    pending[1, default: []].append(link)
                }
            case .closeFolder:
                guard let name = stack.popLast() else { break }
                if stack.isEmpty {
                    let links = pending.removeValue(forKey: 1) ?? []
                    if !links.isEmpty { folders.append(Folder(name: name, links: links)) }
                }
            }
        }
        // an unclosed final folder still counts
        if let name = stack.first, let links = pending[1], !links.isEmpty {
            folders.append(Folder(name: name, links: links))
        }
        let result = Result(folders: folders, loose: loose)
        return result.isEmpty ? nil : result
    }

    private enum Token {
        case folder(String)
        case link(Link)
        case closeFolder
    }

    /// walk the markup once, emitting only the three things that matter
    private static func tags(in text: String) -> [Token] {
        var out: [Token] = []
        var index = text.startIndex
        while let open = text[index...].firstIndex(of: "<") {
            guard let close = text[open...].firstIndex(of: ">") else { break }
            let tag = String(text[text.index(after: open)..<close])
            let lower = tag.lowercased()
            let after = text.index(after: close)

            if lower.hasPrefix("h3") {
                out.append(.folder(innerText(of: text, from: after, until: "</h3")))
            } else if lower.hasPrefix("a "), let href = attribute("href", in: tag),
                let url = URL(string: href), isWeb(url)
            {
                let title = innerText(of: text, from: after, until: "</a")
                out.append(.link(Link(title: title.isEmpty ? (url.host() ?? href) : title, url: url)))
            } else if lower.hasPrefix("/dl") {
                out.append(.closeFolder)
            }
            index = after
        }
        return out
    }

    private static func innerText(
        of text: String, from start: String.Index, until terminator: String
    ) -> String {
        guard let end = text.range(of: terminator, options: .caseInsensitive, range: start..<text.endIndex)
        else { return "" }
        return decodeEntities(String(text[start..<end.lowerBound]))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        guard let range = tag.range(of: "\(name)=\"", options: .caseInsensitive) else { return nil }
        let rest = tag[range.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return decodeEntities(String(rest[..<end]))
    }

    private static let entities: [(String, String)] = [
        ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
        ("&nbsp;", " "), ("&amp;", "&"),
    ]

    /// `&amp;` last, or an escaped entity would be decoded twice
    private static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var out = text
        for (entity, character) in entities {
            out = out.replacingOccurrences(of: entity, with: character, options: .caseInsensitive)
        }
        return out
    }

    // MARK: - Chrome JSON

    /// every Chromium-family browser writes the same `Bookmarks` file: a
    /// tree of `{type: "url" | "folder"}` nodes under a handful of named roots.
    private static func parseChrome(_ data: Data) -> Result? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let roots = root["roots"] as? [String: Any]
        else { return nil }

        var folders: [Folder] = []
        var loose: [Link] = []
        // bookmark_bar first: it is the one people actually keep things in
        for key in ["bookmark_bar", "other", "synced"] {
            guard let node = roots[key] as? [String: Any],
                let children = node["children"] as? [[String: Any]]
            else { continue }
            for child in children {
                if child["type"] as? String == "folder" {
                    let links = flatten(child)
                    let name = child["name"] as? String ?? "Imported"
                    if !links.isEmpty { folders.append(Folder(name: name, links: links)) }
                } else if let link = link(from: child) {
                    loose.append(link)
                }
            }
        }
        let result = Result(folders: folders, loose: loose)
        return result.isEmpty ? nil : result
    }

    /// every link at or below this node, in order
    private static func flatten(_ node: [String: Any]) -> [Link] {
        guard let children = node["children"] as? [[String: Any]] else { return [] }
        return children.flatMap { child -> [Link] in
            child["type"] as? String == "folder" ? flatten(child) : [link(from: child)].compactMap { $0 }
        }
    }

    private static func link(from node: [String: Any]) -> Link? {
        guard node["type"] as? String == "url",
            let raw = node["url"] as? String, let url = URL(string: raw), isWeb(url)
        else { return nil }
        let name = node["name"] as? String ?? ""
        return Link(title: name.isEmpty ? (url.host() ?? raw) : name, url: url)
    }
}
