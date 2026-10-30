import WebKit

/// Reports the URL of the link the cursor is hovering, for the status-style
/// capsule the chrome shows at the bottom of the content. Installed once as a
/// persistent user script + message handler on the shared content controller, so
/// every tab (and iframe) reports hovers without per-tab wiring.
///
/// it posts the href on `mouseover` of an `<a>` and clears on `mouseout` — but
/// only when the cursor isn't entering another link, so moving link→link doesn't
/// flicker the capsule off and on.
final class LinkHoverReporter: NSObject, WKScriptMessageHandler {
    static let messageName = "artemisLinkHover"

    private let onChange: (URL?) -> Void

    init(onChange: @escaping (URL?) -> Void) {
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
        onChange(string.isEmpty ? nil : URL(string: string))
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
