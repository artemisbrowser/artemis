// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import WebKit

/// a page's prose, read by walking text nodes. never `innerText`, which forces
/// a layout pass on pages nobody is looking at
enum PageText {
    /// `focused` reads what a question is about: the selection, else the main
    /// region minus navigation and toolbars, plus the labels of its buttons
    private static func script(focused: Bool) -> String {
        """
        (() => {
          const focused = \(focused);
          const skip = new Set(
            ['SCRIPT','STYLE','NOSCRIPT','TEMPLATE','SVG','IFRAME','CANVAS']);
          const chrome = new Set(['navigation','toolbar','menubar','menu','banner',
            'complementary','search','contentinfo','tablist']);
          const isChrome = (el) => el.tagName === 'NAV' || el.tagName === 'ASIDE'
            || chrome.has(el.getAttribute('role')) || el.getAttribute('aria-hidden') === 'true';
          // hides every descendant, whatever they set
          const isHidden = (el) => {
            if (el.hidden) return true;
            const s = getComputedStyle(el);
            const clipped = s.overflow !== 'visible' && s.display !== 'inline' && s.display !== 'contents'
              && (el.clientHeight < 2 || el.clientWidth < 2);
            // opacity 0 with a transition or animation is content waiting to be revealed
            const faded = s.opacity === '0' && parseFloat(s.transitionDuration) === 0
              && s.animationName === 'none';
            const offscreen = (s.position === 'absolute' || s.position === 'fixed')
              && (parseFloat(s.left) < -999 || parseFloat(s.top) < -999);
            return s.display === 'none' || faded || clipped || offscreen
              || s.clip === 'rect(0px, 0px, 0px, 0px)';
          };
          // a child can override these, so they are judged at each text node's parent
          const unreadable = (el) => {
            const s = getComputedStyle(el);
            const textClip = s.backgroundClip === 'text' || s.webkitBackgroundClip === 'text';
            return s.visibility === 'hidden' || parseFloat(s.fontSize) < 2
              || (!textClip && /^rgba\\(.*,\\s*0\\)$|\\/\\s*0\\)$/.test(s.color));
          };
          const button = 'button, [role=button], input[type=submit], input[type=button], '
            + 'a[class*=btn i], a[class*=button i], a[class*=cta i], a[style*=background]';
          const tidy = (text) => text.replace(/\\s+/g, ' ').trim();
          const actions = [];
          const read = (root) => {
            const parts = [];
            const walk = (node) => {
              for (const child of node.childNodes) {
                if (parts.length > 30000) return;
                if (child.nodeType === 3) {
                  if (!focused || !unreadable(node)) parts.push(child.nodeValue);
                } else if (child.nodeType === 1 && !skip.has(child.tagName)
                  && !(focused && (isChrome(child) || isHidden(child)))) {
                  if (focused && actions.length < 12 && child.matches(button) && !unreadable(child)) {
                    const label = tidy(child.tagName === 'INPUT' ? String(child.value) : child.textContent);
                    if (label.length > 1 && label.length <= 40 && !actions.includes(label))
                      actions.push(label);
                  }
                  walk(child);
                }
              }
            };
            walk(root);
            return tidy(parts.join(' ')).slice(0, 200000);
          };
          if (!document.body) return '';
          if (!focused) return read(document.body);
          const picked = tidy(String(getSelection())).slice(0, 200000);
          if (picked.length >= 200) return { text: picked };
          const articles = document.querySelectorAll('article');
          const region = document.querySelector('[role=main]:not([hidden]), main:not([hidden])')
            || (articles.length === 1 ? articles[0] : null);
          const text = region ? read(region) : '';
          if (text.length >= 200) return { text, actions };
          actions.length = 0;
          return { text: read(document.body), actions };
        })()
        """
    }

    /// the page's words, or nil if there aren't enough to be worth anything
    static func extract(from webView: WKWebView, minimum: Int = 200) async -> String? {
        // utf16 is O(1) on the bridged string; `count` walks every grapheme on main
        guard let text = (try? await webView.evaluateJavaScript(script(focused: false))) as? String,
            text.utf16.count >= minimum
        else { return nil }
        return text
    }

    /// what a question about the page should read: its words, and its buttons. a selection
    /// comes with no buttons, nil, since its text keeps what the page hides from view
    static func focus(from webView: WKWebView) async -> (text: String, actions: [String]?)? {
        guard let found = (try? await webView.evaluateJavaScript(script(focused: true))) as? [String: Any],
            let text = found["text"] as? String, text.utf16.count >= 200
        else { return nil }
        return (text, found["actions"] as? [String])
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
