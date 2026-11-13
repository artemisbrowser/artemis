// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import Foundation
import WebKit

/// articles found by Mozilla's Readability (Readability.js, 0.6.0) in a copy of the page's DOM,
/// rebuilt from meaningful tags only
nonisolated enum ReaderMode {
    struct Article {
        var title: String
        /// sanitized body HTML: `keptTags` only, `href`/`src`/`alt` only
        var html: String
        var url: URL
        var wordCount: Int
        var byline: String? = nil
        var siteName: String? = nil

        /// at 220 words a minute, never under 1
        var readingMinutes: Int { max(1, Int((Double(wordCount) / 220).rounded())) }
    }

    /// tags kept in the cleaned output; everything else is unwrapped to its text
    private static let keptTags: Set<String> = [
        "p", "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "li", "blockquote",
        "pre", "code", "em", "strong", "b", "i", "a", "img", "figure", "figcaption", "br", "hr",
    ]

    /// Readability's source, then a parse of a clone so the page itself is never touched;
    /// `hidden="until-found"` is folded content (mobile Wikipedia's sections), which Readability would drop as hidden
    private static let parse = Bundle.main.url(forResource: "Readability", withExtension: "js")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        .map {
            $0 + """

                const page = document.cloneNode(true);
                page.querySelectorAll('[hidden="until-found"]').forEach(node => node.removeAttribute('hidden'));
                const found = new Readability(page).parse();
                return found && { title: found.title ?? "", byline: found.byline ?? "", site: found.siteName ?? "", content: found.content ?? "" };
                """
        }

    /// run in a world the page can't reach; nil below 120 words, which is a landing page or app shell, not an article
    @MainActor static func extract(from webView: WKWebView, url: URL) async -> Article? {
        guard let parse, let found = try? await webView.callAsyncJavaScript(parse, contentWorld: .defaultClient) as? [String: String]
        else { return nil }
        return await article(found, url: url)
    }

    @concurrent private static func article(_ found: [String: String], url: URL) async -> Article? {
        let cleaned = sanitize(found["content"] ?? "", base: url)
        let words = stripTags(cleaned).split(whereSeparator: \.isWhitespace).count
        guard words >= 120 else { return nil }
        func text(_ key: String) -> String? {
            found[key].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        }
        return Article(
            title: text("title") ?? url.host() ?? "Reader", html: cleaned, url: url, wordCount: words,
            byline: text("byline"), siteName: text("site"))
    }

    // MARK: - Cleaning

    /// `html` with `keptTags` only; never leaves a `<` it didn't write
    static func sanitize(_ html: String, base: URL) -> String {
        var out = ""
        var index = html.startIndex
        while let open = html[index...].firstIndex(of: "<") {
            out += html[index..<open]
            guard let close = html[open...].firstIndex(of: ">") else { break }
            let tagText = String(html[html.index(after: open)..<close])
            let name = tagText
                .trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
                .prefix { !$0.isWhitespace && $0 != "/" }
                .lowercased()
            if keptTags.contains(name) {
                out += rebuild(tag: tagText, name: name, base: base)
            }
            index = html.index(after: close)
        }
        out += html[index...].replacingOccurrences(of: "<", with: "&lt;")
        return out
    }

    /// the kept tag with only `alt` and an absolute `href` or `src`; a url is written only
    /// as parsed, and only under a scheme listed here
    private static func rebuild(tag: String, name: String, base: URL) -> String {
        if tag.hasPrefix("/") { return "</\(name)>" }
        func value(_ attribute: String) -> String? {
            firstMatch(in: tag, pattern: "\\b\(attribute)\\s*=\\s*[\"']([^\"']*)[\"']").map(decodeEntities)
        }
        var attributes = ""
        for (attribute, schemes) in [("href", ["http", "https", "mailto"]), ("src", ["http", "https"])] {
            if let raw = value(attribute)?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
                let url = URL(string: raw, relativeTo: base)?.absoluteURL,
                schemes.contains(url.scheme?.lowercased() ?? "") {
                attributes += " \(attribute)=\"\(escape(url.absoluteString))\""
            }
        }
        if let alt = value("alt"), !alt.isEmpty { attributes += " alt=\"\(escape(alt))\"" }
        let selfClosing = name == "br" || name == "hr" || name == "img"
        return "<\(name)\(attributes)\(selfClosing ? " /" : "")>"
    }

    // MARK: - Rendering

    /// a self-contained document, styled inline for light and dark; `style` lands last, in #reader-style.
    /// its policy runs no script, whatever `article.html` holds
    static func page(for article: Article, style: String = "") -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src http: https:; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escape(article.title))</title>
        <style>
          :root { color-scheme: light dark; }
          body {
            margin: 0 auto; padding: 64px 24px 120px; max-width: 42rem;
            font: 19px/1.7 -apple-system, ui-serif, Georgia, serif;
            color: #1c1c1e; background: #fdfcfa;
            -webkit-font-smoothing: antialiased;
          }
          @media (prefers-color-scheme: dark) {
            body { color: #e6e4e1; background: #16171a; }
            a { color: #7fb2ff; }
          }
          h1 { font-size: 2em; line-height: 1.2; margin: 0 0 8px; letter-spacing: -0.02em; }
          .meta { font: 13px/1.4 -apple-system, sans-serif; opacity: 0.55; margin-bottom: 40px; }
          p { margin: 0 0 1.2em; }
          img { max-width: 100%; height: auto; border-radius: 8px; margin: 1.5em 0; }
          blockquote {
            margin: 1.5em 0; padding-left: 1.2em; border-left: 3px solid currentColor;
            opacity: 0.8; font-style: italic;
          }
          pre, code { font: 15px/1.5 ui-monospace, SFMono-Regular, Menlo, monospace; }
          pre { overflow-x: auto; padding: 1em; background: rgba(127,127,127,0.12); border-radius: 8px; }
          h2, h3, h4 { line-height: 1.3; margin: 1.8em 0 0.5em; letter-spacing: -0.01em; }
          a { color: #0b62d0; text-decoration-thickness: 1px; text-underline-offset: 2px; }
        </style>\(style.isEmpty ? "" : "<style id=\"reader-style\">\(style)</style>")</head>
        <body>
        <h1>\(escape(article.title))</h1>
        <div class="meta">\(escape([article.byline, article.siteName ?? article.url.host()].compactMap { $0 }.joined(separator: " · "))) · \(article.readingMinutes) min read</div>
        \(article.html)
        </body></html>
        """
    }

    // MARK: - Markdown

    /// the article's sanitised html as Markdown, links and images absolute
    @concurrent static func markdown(for article: Article) async -> String {
        // a link, quote or code block collects into its own buffer, wrapped as it closes
        var buffers = [""]
        var hrefs: [String?] = []
        var lists: [(ordered: Bool, count: Int)] = []
        var inPre = 0
        func emit(_ text: String) { buffers[buffers.count - 1] += text }
        func block() { if !buffers[buffers.count - 1].isEmpty { emit("\n\n") } }
        func pop() -> String { buffers.count > 1 ? buffers.removeLast() : "" }
        func absolute(_ raw: String?) -> String? {
            raw.flatMap { URL(string: $0, relativeTo: article.url)?.absoluteString }
        }
        func text(_ raw: Substring) {
            let decoded = decodeEntities(String(raw))
            if inPre > 0 { return emit(decoded) }
            var collapsed = replace("\\s+", in: decoded, with: " ")
            let last = buffers[buffers.count - 1].last
            if last == nil || last == " " || last == "\n" { collapsed = String(collapsed.drop { $0 == " " }) }
            emit(collapsed)
        }

        let html = article.html
        var index = html.startIndex
        while let open = html[index...].firstIndex(of: "<") {
            text(html[index..<open])
            guard let close = html[open...].firstIndex(of: ">") else { break }
            index = html.index(after: close)
            let tag = String(html[html.index(after: open)..<close])
            let closing = tag.hasPrefix("/")
            let name = tag.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
                .prefix { !$0.isWhitespace && $0 != "/" }.lowercased()
            switch name {
            case "h1", "h2", "h3", "h4", "h5", "h6":
                block()
                if !closing { emit(String(repeating: "#", count: Int(name.dropFirst()) ?? 1) + " ") }
            case "p", "figure", "figcaption":
                if lists.isEmpty { block() }
            case "br":
                emit("\n")
            case "hr":
                block()
                emit("---\n\n")
            case "ul", "ol":
                if closing { _ = lists.popLast() } else { lists.append((name == "ol", 0)) }
                if closing ? lists.isEmpty : lists.count == 1 { block() }
            case "li" where !closing && !lists.isEmpty:
                lists[lists.count - 1].count += 1
                let item = lists[lists.count - 1]
                emit("\n" + String(repeating: "  ", count: lists.count - 1) + (item.ordered ? "\(item.count). " : "- "))
            case "blockquote", "pre":
                if !closing {
                    block()
                    buffers.append("")
                    if name == "pre" { inPre += 1 }
                    continue
                }
                let body = pop().trimmingCharacters(in: .whitespacesAndNewlines)
                if name == "pre" {
                    inPre = max(inPre - 1, 0)
                    emit("```\n\(body)\n```")
                } else {
                    emit(body.split(separator: "\n", omittingEmptySubsequences: false).map { "> \($0)" }
                        .joined(separator: "\n"))
                }
                block()
            case "code" where inPre == 0:
                emit("`")
            case "strong", "b":
                emit("**")
            case "em", "i":
                emit("*")
            case "a":
                if !closing {
                    hrefs.append(firstMatch(in: tag, pattern: "href=\"([^\"]*)\""))
                    buffers.append("")
                    continue
                }
                let label = pop().trimmingCharacters(in: .whitespaces)
                let href = absolute(hrefs.popLast() ?? nil)
                emit(href.map { label.isEmpty ? "" : "[\(label)](\($0))" } ?? label)
            case "img":
                if let src = absolute(firstMatch(in: tag, pattern: "src=\"([^\"]*)\"")) {
                    emit("![\(firstMatch(in: tag, pattern: "alt=\"([^\"]*)\"") ?? "")](\(src))")
                }
            default:
                break
            }
        }
        text(html[index...])
        while buffers.count > 1 { buffers[buffers.count - 2] += buffers.removeLast() }
        // linear in each line's length
        let tidy = buffers[0].split(separator: "\n", omittingEmptySubsequences: false).map { line in
            line[..<(line.lastIndex { $0 != " " && $0 != "\t" }.map(line.index(after:)) ?? line.startIndex)]
        }.joined(separator: "\n")
        return replace("\n{3,}", in: tidy, with: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Small string helpers

    private static func stripTags(_ html: String) -> String {
        decodeEntities(replace("<[^>]+>", in: html, with: " "))
    }

    private static func replace(_ pattern: String, in text: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive])
        else { return text }
        return regex.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    private static func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive]),
            let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
            match.numberOfRanges > 1,
            let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
    }

    private static func decodeEntities(_ text: String) -> String {
        var out = text
        for (entity, character) in [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
            ("&#39;", "'"), ("&apos;", "'"), ("&nbsp;", " "), ("&mdash;", "—"),
            ("&ndash;", "–"), ("&hellip;", "…"), ("&rsquo;", "’"), ("&lsquo;", "‘"),
            ("&ldquo;", "“"), ("&rdquo;", "”"),
        ] {
            out = out.replacingOccurrences(of: entity, with: character)
        }
        return out
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
