// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import WebKit

/// per-frame "a field or editor has focus", so ⌘Z goes to the page while it is editing and to
/// the sidebar otherwise. runs in a world of its own: it only reads the DOM
final class EditingFocusReporter: NSObject, WKScriptMessageHandler {
    private static let messageName = "artemisEditing"
    private static let world = WKContentWorld.world(name: "Artemis.Editing")

    static func install(into controller: WKUserContentController) {
        controller.add(EditingFocusReporter(), contentWorld: world, name: messageName)
        controller.addUserScript(
            WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: world))
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let frame = body["frame"] as? String,
            let editing = body["editing"] as? Bool, let tab = (message.webView as? ArtemisWebView)?.owningTab
        else { return }
        tab.setFrameEditing(editing, frame: frame)
    }

    private static let source = """
    (function(){
      // a frame's url changes under pushState and can repeat across frames, so each document names itself
      var frame = Math.random().toString(36).slice(2) + Date.now().toString(36);
      var last = false;
      function post(now){
        try { window.webkit.messageHandlers.artemisEditing.postMessage({ frame: frame, editing: now }); } catch (e) {}
      }
      var typed = /^(text|search|email|url|tel|password|number)$/;
      function editing(){
        if (document.designMode === 'on') return document.hasFocus();
        var el = document.activeElement;
        while (el && el.shadowRoot && el.shadowRoot.activeElement) el = el.shadowRoot.activeElement;
        if (!el || !document.hasFocus()) return false;
        if (el.isContentEditable) return true;
        if (el.readOnly || el.disabled) return false;
        return el.tagName === 'TEXTAREA' || (el.tagName === 'INPUT' && typed.test(el.type));
      }
      function report(){
        var now = editing();
        if (now === last) return;
        last = now;
        post(now);
      }
      function later(){ setTimeout(report, 0); }
      document.addEventListener('focusin', report, true);
      // focus is still on the old element while focusout runs
      document.addEventListener('focusout', later, true);
      window.addEventListener('blur', later);
      window.addEventListener('focus', report);
      window.addEventListener('pagehide', function(){ if (last) { last = false; post(false); } });
      // a page back from the back/forward cache may still hold focus
      window.addEventListener('pageshow', function(e){ if (e.persisted) report(); });
    })();
    """
}
