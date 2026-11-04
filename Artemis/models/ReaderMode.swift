// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import Foundation

/// Readability-style article extraction over a page's serialized HTML: the block
/// with the most prose per unit of markup, rebuilt from meaningful tags only.
/// approximate by design; regex-based, never a DOM parse
nonisolated enum ReaderMode {
    struct Article {
        var title: String
        /// sanitized body HTML: `keptTags` only, `href`/`src`/`alt` only
        var html: String
        var url: URL
        var wordCount: Int

        /// at 220 words a minute, never under 1
        var readingMinutes: Int { max(1, Int((Double(wordCount) / 220).rounded())) }
    }

    /// tags whose content is never part of an article
    private static let junkTags = [
        "script", "style", "noscript", "nav", "header", "footer", "aside", "form",
        "iframe", "svg", "button", "select", "textarea", "template",
    ]

    /// tags kept in the cleaned output; everything else is unwrapped to its text
    private static let keptTags: Set<String> = [
        "p", "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "li", "blockquote",
        "pre", "code", "em", "strong", "b", "i", "a", "img", "figure", "figcaption", "br", "hr",
    ]

    /// nil below 120 words, which is a landing page or app shell, not an article
    @concurrent static func extract(html: String, url: URL) async -> Article? {
        let title = firstMatch(in: html, pattern: "<title[^>]*>(.*?)</title>")
            .map(decodeEntities)?.trimmingCharacters(in: .whitespacesAndNewlines)

        var body = html
        for tag in junkTags {
            body = remove(tag: tag, from: body)
        }
        // comment blocks can hide markup that confuses the scoring
        body = replace("<!--.*?-->", in: body, with: "")

        let candidate = bestCandidate(in: body) ?? body
        let cleaned = sanitize(candidate)
        let text = stripTags(cleaned)
        let words = text.split(whereSeparator: { $0.isWhitespace }).count
        guard words >= 120 else { return nil }

        let heading = firstMatch(in: candidate, pattern: "<h1[^>]*>(.*?)</h1>")
            .map(stripTags)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalTitle = [heading, title].compactMap { $0 }.first { !$0.isEmpty } ?? url.host() ?? "Reader"

        return Article(title: finalTitle, html: cleaned, url: url, wordCount: words)
    }

    // MARK: - Candidate scoring

    /// score every `<article>`/`<main>`/`<div>`/`<section>` block and take the one
    /// with the most prose per unit of markup
    private static func bestCandidate(in html: String) -> String? {
        var best: (score: Double, html: String)?
        for tag in ["article", "main", "section", "div"] {
            for block in blocks(of: tag, in: html) {
                let score = self.score(block)
                if score > (best?.score ?? 0) {
                    best = (score, block)
                }
            }
            // an <article> that scores at all wins outright
            if tag == "article", let best, best.score > 0 { return best.html }
        }
        return best?.html
    }

    /// prose density: real sentence-y text, penalised by link text (nav lists and
    /// "related stories" rails are mostly links) and by markup weight
    private static func score(_ block: String) -> Double {
        let text = stripTags(block).trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > 200 else { return 0 }
        let linkText = blocks(of: "a", in: block).map(stripTags).joined()
        let linkDensity = Double(linkText.count) / Double(max(text.count, 1))
        guard linkDensity < 0.5 else { return 0 }

        let paragraphs = Double(occurrences(of: "<p", in: block))
        let commas = Double(text.filter { $0 == "," }.count)
        let markupRatio = Double(text.count) / Double(max(block.count, 1))
        return (Double(text.count) + commas * 20 + paragraphs * 60) * markupRatio * (1 - linkDensity)
    }

    // MARK: - Cleaning

    private static func sanitize(_ html: String) -> String {
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
                out += rebuild(tag: tagText, name: name)
            }
            index = html.index(after: close)
        }
        out += html[index...]
        return out
    }

    /// the kept tag with only `href`, `src` and `alt`, minus `javascript:` urls
    private static func rebuild(tag: String, name: String) -> String {
        if tag.hasPrefix("/") { return "</\(name)>" }
        var attributes = ""
        for attribute in ["href", "src", "alt"] {
            if let value = firstMatch(in: tag, pattern: "\(attribute)\\s*=\\s*[\"']([^\"']*)[\"']"),
                !value.isEmpty,
                !value.lowercased().hasPrefix("javascript:") {
                attributes += " \(attribute)=\"\(value)\""
            }
        }
        let selfClosing = name == "br" || name == "hr" || name == "img"
        return "<\(name)\(attributes)\(selfClosing ? " /" : "")>"
    }

    // MARK: - Rendering

    /// a self-contained document, styled inline for light and dark
    static func page(for article: Article) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">
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
        </style></head>
        <body>
        <h1>\(escape(article.title))</h1>
        <div class="meta">\(escape(article.url.host() ?? "")) · \(article.readingMinutes) min read</div>
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

    private static func blocks(of tag: String, in html: String) -> [String] {
        var out: [String] = []
        var searchStart = html.startIndex
        while let open = html.range(of: "<\(tag)", options: .caseInsensitive, range: searchStart..<html.endIndex) {
            guard let close = html.range(
                of: "</\(tag)>", options: .caseInsensitive, range: open.upperBound..<html.endIndex)
            else { break }
            out.append(String(html[open.lowerBound..<close.upperBound]))
            searchStart = open.upperBound
            if out.count > 400 { break }
        }
        return out
    }

    private static func remove(tag: String, from html: String) -> String {
        replace("<\(tag)\\b[^>]*>.*?</\(tag)>", in: html, with: "")
    }

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

    private static func occurrences(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
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
    }
}
