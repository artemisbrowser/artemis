import Foundation

/// Reader: strips a page down to its article and re-renders it as clean,
/// readable typography.
///
/// Safari's reader is a private WebKit component with no API, so this is our own
/// extraction — the same heuristic Readability made standard: score block
/// elements by how much real prose they hold versus how much link/markup noise,
/// take the best subtree, then rebuild it with only the tags that carry meaning.
///
/// The extraction runs on the page's serialized HTML rather than in the page, so
/// hostile script can't interfere with it and the result is deterministic enough
/// to unit-test.
nonisolated enum ReaderMode {
    struct Article {
        var title: String
        /// sanitized body HTML — headings, paragraphs, lists, quotes, images
        var html: String
        var url: URL
        /// rough reading time, shown under the title
        var wordCount: Int

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

    /// pull the article out of a page, or nil when there isn't one worth showing
    static func extract(html: String, url: URL) -> Article? {
        let title = firstMatch(in: html, pattern: "<title[^>]*>(.*?)</title>")
            .map(decodeEntities)?.trimmingCharacters(in: .whitespacesAndNewlines)

        var body = html
        // drop wholesale-junk elements, contents and all
        for tag in junkTags {
            body = remove(tag: tag, from: body)
        }
        // comment blocks can hide markup that confuses the scoring
        body = replace("<!--.*?-->", in: body, with: "")

        let candidate = bestCandidate(in: body) ?? body
        let cleaned = sanitize(candidate)
        let text = stripTags(cleaned)
        let words = text.split(whereSeparator: { $0.isWhitespace }).count
        // below this it isn't an article — it's a landing page or an app shell,
        // and a reader view of it would be worse than the page
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
            // an explicit <article> that scores at all wins outright — semantic
            // markup beats any heuristic guess
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

    /// keep only the tags that carry meaning, and only the attributes that do
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
        // collapse the whitespace the tag removal leaves behind
        return replace("(\\s*\n\\s*){2,}", in: out, with: "\n")
    }

    /// re-emit a kept tag carrying only safe attributes (`href`, `src`, `alt`) —
    /// this is what stops layout classes and inline styles following the content
    /// into the reader and undoing its typography
    private static func rebuild(tag: String, name: String) -> String {
        if tag.hasPrefix("/") { return "</\(name)>" }
        var attributes = ""
        for attribute in ["href", "src", "alt"] {
            if let value = firstMatch(in: tag, pattern: "\(attribute)\\s*=\\s*[\"']([^\"']*)[\"']"),
                !value.isEmpty,
                // javascript: urls have no place in a stripped-down reader
                !value.lowercased().hasPrefix("javascript:") {
                attributes += " \(attribute)=\"\(value)\""
            }
        }
        let selfClosing = name == "br" || name == "hr" || name == "img"
        return "<\(name)\(attributes)\(selfClosing ? " /" : "")>"
    }

    // MARK: - Rendering

    /// the reader document. deliberately styled here rather than in the app so it
    /// prints and saves as it looks, and adapts to the system appearance
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

    // MARK: - Small string helpers
    //
    // deliberately regex/scanner based rather than a DOM parse: this runs on
    // every reader toggle and only ever needs to be approximately right, and
    // pulling in a parser for it would cost more than it returns

    private static func blocks(of tag: String, in html: String) -> [String] {
        var out: [String] = []
        var searchStart = html.startIndex
        while let open = html.range(of: "<\(tag)", options: .caseInsensitive, range: searchStart..<html.endIndex) {
            guard let close = html.range(
                of: "</\(tag)>", options: .caseInsensitive, range: open.upperBound..<html.endIndex)
            else { break }
            out.append(String(html[open.lowerBound..<close.upperBound]))
            searchStart = open.upperBound
            if out.count > 400 { break }  // pathological markup guard
        }
        return out
    }

    private static func remove(tag: String, from html: String) -> String {
        replace("<\(tag)\\b[^>]*>.*?</\(tag)>", in: html, with: "")
    }

    static func stripTags(_ html: String) -> String {
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
