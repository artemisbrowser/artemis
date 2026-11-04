// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import WebKit

/// reports the href under the cursor and the page it is in, nil when it leaves
/// for a non-link. one handler serves every frame of every tab on the shared
/// content controller
final class LinkHoverReporter: NSObject, WKScriptMessageHandler {
    private static let messageName = "artemisLinkHover"

    private let onChange: (WKWebView?, URL?) -> Void

    init(onChange: @escaping (WKWebView?, URL?) -> Void) {
        self.onChange = onChange
    }

    static func install(into controller: WKUserContentController, handler: LinkHoverReporter) {
        controller.add(handler, name: messageName)
        controller.addUserScript(
            WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false))
    }

    func userContentController(
        _ controller: WKUserContentController, didReceive message: WKScriptMessage
    ) {
        let string = message.body as? String ?? ""
        onChange(message.webView, string.isEmpty ? nil : URL(string: string))
    }

    private static let source = """
    (function(){
      if (window.__artemisHoverInstalled) return;
      window.__artemisHoverInstalled = true;
      var last = null;
      function send(v){
        if (v === last) return;
        last = v;
        try { window.webkit.messageHandlers.\(messageName).postMessage(v || ""); } catch(e){}
      }
      document.addEventListener('mouseover', function(e){
        var a = e.target && e.target.closest ? e.target.closest('a[href]') : null;
        if (a && a.href) send(a.href);
      }, true);
      document.addEventListener('mouseout', function(e){
        // don't clear if we're moving onto another link — avoids a flicker
        var to = e.relatedTarget;
        var toLink = to && to.closest ? to.closest('a[href]') : null;
        if (!toLink) send(null);
      }, true);
      window.addEventListener('blur', function(){ send(null); });
    })();
    """
}
