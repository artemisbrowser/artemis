// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import WebKit

/// on Chrome Web Store and Firefox Add-ons pages, hides the "use a different browser" nags and
/// turns each item page's install button into "Add to Artemis", through the normal consent flow
@MainActor
final class StorePageCleaner: NSObject, WKScriptMessageHandler {
    private static let shared = StorePageCleaner()
    /// isolated, so the store's own scripts can neither see nor call the install handler
    private static let world = WKContentWorld.world(name: "Artemis.Store")
    private static let handlerName = "artemisStore"

    static func install(into controller: WKUserContentController) {
        controller.addUserScript(
            WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: world))
        controller.add(shared, contentWorld: world, name: handlerName)
    }

    func userContentController(
        _ controller: WKUserContentController, didReceive message: WKScriptMessage
    ) {
        guard message.frameInfo.isMainFrame, let webView = message.webView, let page = webView.url,
            ExtensionStores.itemPageSource(for: page) != nil,
            let body = message.body as? [String: Any], let type = body["type"] as? String
        else { return }
        let frame = message.frameInfo
        let reply = { (state: String, note: String) in
            webView.callAsyncJavaScript(
                "globalThis.__artemisStore?.set(state, note)", arguments: ["state": state, "note": note],
                in: frame, in: Self.world)
        }
        let manager = ExtensionManager.shared
        switch type {
        case "hello":
            let name = (body["name"] as? String ?? "").lowercased()
            let added = !name.isEmpty && manager.installed.contains { $0.name.lowercased() == name }
            reply(added ? "added" : "ready", "")
        case "install":
            reply("adding", "")
            Task {
                do {
                    let ext = try await manager.installFromStore(pageURL: page)
                    await ExtensionInstallFlow.finalize(ext, manager: manager)
                    reply(manager.installed.contains { $0.id == ext.id } ? "added" : "ready", "")
                } catch ExtensionError.alreadyInstalled(_) {
                    reply("added", "")
                } catch {
                    reply("ready", error.localizedDescription)
                }
            }
        default:
            break
        }
    }

    private static let source = """
    (() => {
      const host = location.hostname;
      const isAMO = host.endsWith("addons.mozilla.org");
      const isCWS = host === "chromewebstore.google.com" || host === "chrome.google.com";
      if (!isAMO && !isCWS) return;
      const post = m => webkit.messageHandlers.\(handlerName).postMessage(m);
      const labels = { ready: "Add to Artemis", adding: "Adding…", added: "Added to Artemis" };
      const ours = /^(Add to Artemis|Adding…|Added to Artemis)$/;
      let state = "ready", note = "", lastItem = "";

      const isItemPage = () => isCWS ? location.pathname.includes("/detail/") : location.pathname.includes("/addon/");
      // the Chrome Web Store keeps the pages it left in the DOM, hidden
      const shown = e => e.getClientRects().length > 0 && getComputedStyle(e).visibility === "visible";

      // [button, element holding its label]
      function itemButton() {
        if (isCWS) {
          for (const span of document.querySelectorAll("button span")) {
            const text = span.textContent.trim(), button = span.closest("button");
            if ((/^(Add to Chrome|Remove from Chrome)$/.test(text) || ours.test(text)) && shown(button)) return [button, span];
          }
          // any language: the install button is the item's one disabled labelled button; the header
          // tabs and search's disabled "Clear all" label alike but sit outside main
          const span = [...document.querySelectorAll('main button[disabled] span[jsname="V67aGc"]')].find(s => shown(s.closest("button")));
          return span ? [span.closest("button"), span] : null;
        }
        const button = document.querySelector(".GetFirefoxButton-button, .AMInstallButton-button")
          || [...document.querySelectorAll("a, button")].find(e => /Download Firefox and get the|Add to Firefox/i.test(e.textContent) || ours.test(e.textContent.trim()));
        return button ? [button, button] : null;
      }

      function clean() {
        if (isAMO) {
          document.querySelectorAll('.Notice, [class*="Banner"], [class*="banner"], [role="alert"], .GetFirefoxButton-callout')
            .forEach(n => {
              if (n.classList.contains("GetFirefoxButton-callout") || /To use these add-ons|you'll need to download Firefox/i.test(n.textContent || ""))
                n.style.setProperty("display", "none", "important");
            });
        }
        if (isCWS) {
          document.querySelectorAll('[role="dialog"]').forEach(d => {
            if (/recommends using Chrome|Switch to Chrome/i.test(d.textContent || "")) {
              (d.closest(".cdk-overlay-pane") || d).remove();
              document.querySelectorAll(".cdk-overlay-backdrop").forEach(b => b.remove());
            }
          });
          // the "switch to Chrome" banner: hide the largest block around its text that stays
          // banner-sized (under 400 characters), never the item's title or install button
          const nag = /Switch to Chrome|Install Chrome|Get Chrome|recommends using Chrome|Download Chrome/i;
          const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
          for (let node = walker.nextNode(); node; node = walker.nextNode()) {
            if (!nag.test(node.data) || node.parentElement?.closest("[data-artemis-store]")) continue;
            let block = node.parentElement;
            while (block.parentElement && block.parentElement !== document.body
                   && (block.parentElement.textContent || "").length < 400
                   && !block.parentElement.querySelector("h1, [data-artemis-store]")) {
              block = block.parentElement;
            }
            block.style.setProperty("display", "none", "important");
          }
        }
      }

      function apply() {
        clean();
        if (!isItemPage()) return;
        const name = ([...document.querySelectorAll("h1")].find(shown)?.firstChild?.textContent || "").trim();
        // keyed on the name too: the URL changes before the store shows the item
        if (name && location.pathname + name !== lastItem) {
          lastItem = location.pathname + name;
          state = "ready";
          note = "";
          post({ type: "hello", name });
        }
        const found = itemButton();
        if (!found) return;
        const [button, label] = found;
        button.dataset.artemisStore = "1";
        button.removeAttribute("disabled");
        button.removeAttribute("aria-disabled");
        if (label.textContent !== labels[state]) label.textContent = labels[state];
        button.title = note;
        button.style.opacity = state === "ready" ? "" : "0.7";
      }

      // capture on window runs before the store's own handlers, which would open its "get Chrome/Firefox" flow
      window.addEventListener("click", e => {
        const button = e.target.closest?.("[data-artemis-store]");
        if (!button) return;
        e.preventDefault();
        e.stopImmediatePropagation();
        if (state === "ready") post({ type: "install" });
      }, true);

      globalThis.__artemisStore = { set(s, n) { state = s; note = n || ""; schedule(); } };

      let pending = false;
      function schedule() {
        if (pending) return;
        pending = true;
        // a timer, not rAF: animation frames never come to a page that isn't on screen
        setTimeout(() => { pending = false; try { apply(); } catch (e) {} }, 30);
      }
      document.addEventListener("DOMContentLoaded", schedule);
      window.addEventListener("load", schedule);
      new MutationObserver(schedule).observe(document.documentElement, { childList: true, subtree: true, characterData: true });
    })();
    """
}
