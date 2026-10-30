import WebKit

/// Reading a page's prose out of the DOM.
///
/// Deliberately not `innerText`. `innerText` is defined in terms of *rendered*
/// layout, so asking for it forces a layout pass — on a background tab, or a tab
/// you're only hovering a link toward, that's real work for a page nobody is
/// looking at. Walking text nodes gets the same words for free, skipping the
/// tags whose contents are code rather than reading.
///
/// Shared by the three things that need to know what a page says: the full-text
/// index, "ask about this page", and link previews.
enum PageText {
    static let script = """
        (() => {
          const skip = new Set(
            ['SCRIPT','STYLE','NOSCRIPT','TEMPLATE','SVG','IFRAME','CANVAS']);
          const parts = [];
          const walk = (node) => {
            for (const child of node.childNodes) {
              if (parts.length > 30000) return;
              if (child.nodeType === 3) parts.push(child.nodeValue);
              else if (child.nodeType === 1 && !skip.has(child.tagName)) walk(child);
            }
          };
          if (document.body) walk(document.body);
          return parts.join(' ').replace(/\\s+/g, ' ').trim().slice(0, 200000);
        })()
        """

    /// the page's words, or nil if there aren't enough to be worth anything
    static func extract(from webView: WKWebView, minimum: Int = 200) async -> String? {
        // utf16 is O(1) on the bridged string; `count` walks every grapheme on main
        guard let text = (try? await webView.evaluateJavaScript(script)) as? String,
            text.utf16.count >= minimum
        else { return nil }
        return text
    }

    /// Just enough of the page to say what it's *about*.
    ///
    /// What that turns out to be, measured over 258 real sites: the description
    /// a page advertises itself with, then its heading — and no body text at
    /// all. Adding the opening prose (700 or 1500 characters of it) named
    /// **fewer** pages, not more, took 200ms longer, and on a news front page
    /// pulled the tab's name towards whichever story was leading that day.
    /// Around 150 characters of what the page says it *is* beats ten times as
    /// much of what it happens to say.
    ///
    /// Prose is still the fallback for the pages — about a third of them — that
    /// describe themselves with nothing at all.
    static func summaryContext(from webView: WKWebView, limit: Int = 700) async -> String? {
        let js = """
            (() => {
              const meta = (name) => {
                const el = document.querySelector(
                  `meta[property="og:${name}"], meta[name="${name}"]`);
                return el ? (el.getAttribute('content') || '') : '';
              };
              const h1 = document.querySelector('h1');
              // description first: it is what the page says it IS, while an h1
              // on a front page is whichever story is leading today
              const parts = [
                meta('description'),
                h1 ? h1.textContent : '',
              ];
              // newlines are KEPT: a page's description is often a list of
              // lines, most of them advertising, and the only way to drop the
              // adverts is to still be able to tell where each line ends
              const spine = parts.filter(Boolean).join('\\n')
                .replace(/[ \\t]+/g, ' ').trim();
              // a page that says what it is needs nothing more; only the ones
              // that say nothing pay for a look at their body text
              if (spine.length >= 40) return spine.slice(0, \(limit));
              const skip = new Set(
                ['SCRIPT','STYLE','NOSCRIPT','TEMPLATE','SVG','IFRAME','CANVAS','NAV','HEADER','FOOTER']);
              const prose = [];
              const walk = (node) => {
                for (const child of node.childNodes) {
                  if (prose.join(' ').length > 800) return;
                  if (child.nodeType === 3) prose.push(child.nodeValue);
                  else if (child.nodeType === 1 && !skip.has(child.tagName)) walk(child);
                }
              };
              if (document.body) walk(document.body);
              return [spine, prose.join(' ')].filter(Boolean).join(' — ')
                .replace(/\\s+/g, ' ').trim().slice(0, 400);
            })()
            """
        guard let text = (try? await webView.evaluateJavaScript(js)) as? String,
            text.count >= 20
        else { return nil }
        return text
    }
}
