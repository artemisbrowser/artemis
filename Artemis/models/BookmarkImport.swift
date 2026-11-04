import Foundation

/// another browser's bookmarks as spaces: each top-level folder becomes a space
/// with its links as pinned tabs, and deeper folders flatten into it
nonisolated enum BookmarkImport {
    struct Link: Equatable {
        var title: String
        var url: URL
    }

    /// one space-to-be
    struct Folder: Equatable {
        var name: String
        var links: [Link]
        /// an emoji the source browser showed for it
        var icon: String? = nil
    }

    struct Result: Equatable {
        var folders: [Folder]
        /// links that sat at the top level, belonging to no folder
        var loose: [Link]
        /// links the source kept above every space, which become the profile's favourites
        var favourites: [Link] = []

        var linkCount: Int { folders.reduce(loose.count + favourites.count) { $0 + $1.links.count } }
        var isEmpty: Bool { linkCount == 0 }
    }

    enum Format {
        /// the Netscape bookmark file every browser can export, Safari included
        case html
        /// Chrome and the Chromium family: the `Bookmarks` file in the profile
        case chromeJSON
        /// Safari's `Bookmarks.plist`
        case safariPlist
    }

    /// Pick a parser by looking at the file rather than trusting its name: a
    /// Chrome profile's bookmark file is called `Bookmarks` with no extension,
    /// and an exported one is `.html` whoever wrote it.
    static func format(of data: Data) -> Format? {
        if data.starts(with: Data("bplist00".utf8)) { return .safariPlist }
        guard let head = String(data: data.prefix(2048), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        else { return nil }
        if head.hasPrefix("{") { return .chromeJSON }
        if head.hasPrefix("<?xml"), head.contains("<plist") { return .safariPlist }
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
        case .safariPlist: parseSafari(data)
        case nil: nil
        }
    }

    // MARK: - Netscape HTML

    /// reads only `<H3>` (a folder), `<A HREF>` (a link) and `</DL>` (a folder's
    /// end); everything else in the file is ignored
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

    // MARK: - Trees

    /// a bookmark tree as every format holds it, before the translation
    indirect enum Node {
        case folder(String, [Node])
        case link(Link)
    }

    /// Each root's folders become spaces and its bare links go loose. Order is
    /// kept, roots first to last.
    static func result(_ roots: [[Node]]) -> Result? {
        var folders: [Folder] = []
        var loose: [Link] = []
        for node in roots.joined() {
            switch node {
            case .link(let link): loose.append(link)
            case .folder(let name, let children):
                let links = flatten(children)
                if !links.isEmpty { folders.append(Folder(name: name.isEmpty ? "Imported" : name, links: links)) }
            }
        }
        let result = Result(folders: folders, loose: loose)
        return result.isEmpty ? nil : result
    }

    private static func flatten(_ nodes: [Node]) -> [Link] {
        nodes.flatMap { node -> [Link] in
            switch node {
            case .link(let link): [link]
            case .folder(_, let children): flatten(children)
            }
        }
    }

    /// a page worth pinning, or nil
    static func link(_ raw: String?, title: String?) -> Link? {
        guard let raw, let url = URL(string: raw), isWeb(url) else { return nil }
        let title = title ?? ""
        return Link(title: title.isEmpty ? (url.host() ?? raw) : title, url: url)
    }

    // MARK: - Chrome JSON

    /// every Chromium-family browser writes the same `Bookmarks` file: a
    /// tree of `{type: "url" | "folder"}` nodes under a handful of named roots,
    /// bookmark_bar first because it is the one people keep things in
    private static func parseChrome(_ data: Data) -> Result? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let roots = root["roots"] as? [String: Any]
        else { return nil }
        return result(["bookmark_bar", "other", "synced"].map { chromeNodes((roots[$0] as? [String: Any])?["children"]) })
    }

    private static func chromeNodes(_ children: Any?) -> [Node] {
        (children as? [[String: Any]] ?? []).compactMap { child in
            switch child["type"] as? String {
            case "folder": .folder(child["name"] as? String ?? "", chromeNodes(child["children"]))
            case "url": link(child["url"] as? String, title: child["name"] as? String).map(Node.link)
            default: nil
            }
        }
    }

    // MARK: - Safari plist

    /// The bar and the menu are roots whose contents rise to the top. Any other
    /// top-level folder is a folder, and the Reading List is one too.
    private static func parseSafari(_ data: Data) -> Result? {
        guard let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            root["WebBookmarkType"] as? String == "WebBookmarkTypeList"
        else { return nil }
        var roots: [[Node]] = []
        var top: [[String: Any]] = []
        for child in root["Children"] as? [[String: Any]] ?? [] {
            switch child["Title"] as? String {
            case "BookmarksBar", "BookmarksMenu": roots.append(safariNodes(child["Children"]))
            case "com.apple.ReadingList": roots.append([.folder("Reading List", safariNodes(child["Children"]))])
            default: top.append(child)
            }
        }
        return result(roots + [safariNodes(top)])
    }

    private static func safariNodes(_ children: Any?) -> [Node] {
        (children as? [[String: Any]] ?? []).compactMap { child in
            switch child["WebBookmarkType"] as? String {
            case "WebBookmarkTypeList": .folder(child["Title"] as? String ?? "", safariNodes(child["Children"]))
            case "WebBookmarkTypeLeaf":
                link(
                    child["URLString"] as? String,
                    title: (child["URIDictionary"] as? [String: Any])?["title"] as? String
                ).map(Node.link)
            default: nil
            }
        }
    }
}
