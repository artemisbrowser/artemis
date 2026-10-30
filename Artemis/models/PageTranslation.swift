import Foundation
import WebKit

/// on-device full-page translation: the page-side scripts and the tab-facing state.
/// scripts run via `callAsyncJavaScript` in an isolated world the page can't see
enum PageTranslation {
    enum State: Equatable {
        case idle
        /// progress is 0...1 over unique strings
        case translating(progress: Double)
        case translated(from: Locale.Language, to: Locale.Language)
        case failed(String)

        /// the page shows, or is turning into, translated text
        var isActive: Bool {
            switch self {
            case .translating, .translated: true
            case .idle, .failed: false
            }
        }
    }

    static let world = WKContentWorld.world(name: "Artemis.Translation")

    static func name(of language: Locale.Language) -> String {
        Locale.current.localizedString(forIdentifier: language.minimalIdentifier) ?? language.minimalIdentifier
    }

    /// returns `{id, lang, texts}`; `texts[i]` is captured node `i`'s trimmed text.
    /// `written[i]` is what node `i` last held from us, so a site edit shows as a mismatch
    static let capture = #"""
        let state = window.artemisTranslation;
        if (!state) {
            state = window.artemisTranslation = {
                lastID: 0,
                capture: null,
                restore() {
                    const c = this.capture;
                    if (!c) return;
                    c.nodes.forEach((node, i) => { if (node.data === c.written[i]) node.data = c.originals[i]; });
                    this.capture = null;
                },
            };
            addEventListener("pagehide", () => state.restore());
        }
        const skip = "script,style,noscript,template,input,textarea,select,option,code,pre,kbd,samp,svg,canvas,"
            + "iframe,object,embed,[contenteditable],[role='textbox'],[translate='no'],.notranslate,[hidden]";
        const visible = new Map();
        const nodes = [], texts = [];
        let chars = 0;
        const walker = document.createTreeWalker(document.body ?? document.documentElement, NodeFilter.SHOW_TEXT);
        for (let node; (node = walker.nextNode()) && nodes.length < 2000; ) {
            if (node.data.length > 5000) continue;
            const text = node.data.trim();
            const element = node.parentElement;
            if (!/\p{L}/u.test(text) || !element || element.closest(skip)) continue;
            if (!visible.has(element)) {
                visible.set(element, element.checkVisibility({ checkVisibilityCSS: true, checkOpacity: true }));
            }
            if (!visible.get(element)) continue;
            if (chars + text.length > 120000) break;
            chars += text.length;
            nodes.push(node);
            texts.push(text);
        }
        const originals = nodes.map((node) => node.data);
        state.capture = { id: ++state.lastID, nodes, originals, written: [...originals] };
        return { id: state.lastID, lang: document.documentElement.lang, texts };
        """#

    /// args `id` (capture), `pairs` ([[index, text]]); keeps each node's original edge whitespace
    static let apply = #"""
        const c = window.artemisTranslation?.capture;
        if (c?.id !== id) return;
        for (const [i, text] of pairs) {
            const node = c.nodes[i];
            if (node.data !== c.written[i]) continue;
            const [, lead, trail] = c.originals[i].match(/^(\s*)[\s\S]*?(\s*)$/);
            node.data = c.written[i] = lead + text + trail;
        }
        """#

    static let restore = "window.artemisTranslation?.restore();"
}
