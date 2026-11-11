// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import WebKit

// the main frame's scroll offset, posted by the page only while watch has armed it;
// each new document starts quiet. runs in its own content world
final class ScrollReporter: NSObject, WKScriptMessageHandler {
    private static let messageName = "artemisScroll"
    private static let world = WKContentWorld.world(name: "Artemis.Scroll")

    static func install(into controller: WKUserContentController) {
        controller.add(ScrollReporter(), contentWorld: world, name: messageName)
        controller.addUserScript(
            WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: world))
    }

    // arm or quiet the page in webView; a load replaces the document, so arm again once it ends
    static func watch(_ on: Bool, in webView: WKWebView) {
        webView.evaluateJavaScript(
            "window.__artemisScroll && window.__artemisScroll(\(on))", in: nil, in: world)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let y = (message.body as? NSNumber)?.doubleValue,
            let tab = (message.webView as? ArtemisWebView)?.owningTab
        else { return }
        tab.pageScrollY = y
    }

    private static let source = """
    (function(){
      if (window.__artemisScroll) return;
      var armed = false, last = null, pending = null;
      function read(){ return window.scrollY || document.documentElement.scrollTop || 0; }
      function report(){
        pending = null;
        if (!armed) return;
        var y = read();
        if (last !== null && Math.abs(y - last) <= 0.5) return;
        last = y;
        try { window.webkit.messageHandlers.\(messageName).postMessage(y); } catch (e) {}
      }
      // trailing, so a fling posts a handful of offsets and always the one it settles on
      window.addEventListener('scroll', function(){
        if (armed && pending === null) pending = setTimeout(report, 120);
      }, { passive: true });
      window.__artemisScroll = function(on){
        armed = !!on;
        last = armed ? read() : null;
        if (!armed && pending !== null) { clearTimeout(pending); pending = null; }
      };
    })();
    """
}
