import WebKit

/// a page's prose, read by walking text nodes. never `innerText`, which forces
/// a layout pass on pages nobody is looking at
enum PageText {
    private static let script = """
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

    /// what the page says it is: its meta description, then its h1. body prose is
    /// read only when those come to under 40 characters
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
