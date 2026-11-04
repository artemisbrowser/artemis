// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import AppKit
import UserNotifications
import WebKit

/// what `navigator.setAppBadge` last set: a bare flag, or a count above zero
enum AppBadge: Equatable { case flag, count(Int) }

/// The Notification web API: a page-world `window.Notification` (main frame, secure
/// contexts) posting to this handler, delivered through Notification Center. Only a
/// live page can post; this is not Web Push and must never be described as it.
final class WebNotifications: NSObject, WKScriptMessageHandler, UNUserNotificationCenterDelegate {
    static let shared = WebNotifications()

    /// tabs that may still have a notification in Notification Center
    private var posted: Set<BrowserTab.ID> = []
    /// documents that have already raised the prompt; the page reports its own user activation
    private var prompted: Set<BrowserTab.ID> = []
    /// an answer given without "remember", good for the document that asked
    private var pageAnswers: [BrowserTab.ID: (origin: String, decision: PermissionDecision)] = [:]
    private lazy var authorization = Task {
        guard !ExtensionLab.isRequested else { return }
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    static func install(into controller: WKUserContentController) {
        controller.add(shared, name: WebNotificationPage.messageName)
        for source in [WebNotificationPage.source, badgeSource] {
            controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        let center = UNUserNotificationCenter.current()
        center.delegate = shared
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: WebNotificationPage.category, actions: [], intentIdentifiers: [],
                options: .customDismissAction)
        ])
    }

    /// the tab's document is gone: its notifications and one-off answer go with it
    func forgetPage(in tabID: BrowserTab.ID) {
        pageAnswers[tabID] = nil
        prompted.remove(tabID)
        guard posted.remove(tabID) != nil else { return }
        let prefix = tabID.uuidString + "/"
        Task {
            let center = UNUserNotificationCenter.current()
            let ids = await center.deliveredNotifications().map(\.request.identifier)
            center.removeDeliveredNotifications(withIdentifiers: ids.filter { $0.hasPrefix(prefix) })
        }
    }

    func userContentController(
        _ controller: WKUserContentController, didReceive message: WKScriptMessage
    ) {
        let frame = message.frameInfo
        guard frame.isMainFrame, let webView = message.webView,
            let body = message.body as? [String: Any], let type = body["type"] as? String,
            let tab = webView.navigationDelegate as? BrowserTab, tab.webView === webView,
            let manager = tab.manager
        else { return }
        let origin = frame.securityOrigin
        let site = SitePermissionStore.originString(origin)
        let isSecure =
            origin.protocol == "https"
            || (origin.protocol == "http" && ["localhost", "127.0.0.1"].contains(origin.host))
        let decision =
            SitePermissionStore.shared.decision(for: site, .notifications, ephemeral: false)
            ?? pageAnswers[tab.id].flatMap { $0.origin == site ? $0.decision : nil }
        let permission =
            !isSecure || tab.isPrivate
            ? "denied" : decision.map { $0 == .allow ? "granted" : "denied" } ?? "default"
        let reply = { (fields: [String: Any], permission: String) in
            webView.callAsyncJavaScript(
                WebNotificationPage.receive, arguments: ["m": fields.merging(["permission": permission]) { $1 }],
                in: frame, in: .page)
        }
        let id = body["id"] as? String ?? ""

        switch type {
        case "hello" where permission != "default":
            reply([:], permission)
        case "requestPermission":
            let request = body["request"] as? Int ?? 0
            // a prompt only answers a click or a keypress, never a page load
            guard permission == "default", body["userActivation"] as? Bool == true,
                prompted.insert(tab.id).inserted
            else {
                return reply(["type": "permission", "request": request], permission)
            }
            manager.requestPermission([.notifications], origin: site, tab: tab) { answer in
                self.pageAnswers[tab.id] = (site, answer)
                reply(["type": "permission", "request": request], answer == .allow ? "granted" : "denied")
            }
        case "badge":
            // the Badging API is gated on the notifications permission
            let granted = permission == "granted"
            if granted {
                let count = body["count"] as? Int
                tab.setAppBadge(count == 0 ? nil : count.map(AppBadge.count) ?? .flag, origin: site)
            }
            webView.callAsyncJavaScript(
                "globalThis.__artemisBadge?.receive(m)",
                arguments: ["m": ["request": body["request"] as? Int ?? 0, "granted": granted]], in: frame, in: .page)
        case "create":
            guard permission == "granted", !id.isEmpty, id.count <= 64,
                let title = body["title"] as? String
            else { return reply(["type": "error", "id": id], permission) }
            let tag = body["tag"] as? String ?? ""
            let content = UNMutableNotificationContent()
            // a locked space's page content stays out of Notification Center
            let locked = manager.space(of: tab).map(SpaceLock.shared.isLocked) == true
            content.title = locked ? "Notification from a locked space" : title
            content.body = locked ? "" : body["body"] as? String ?? ""
            content.subtitle = locked ? "" : origin.host
            content.threadIdentifier = site
            content.categoryIdentifier = WebNotificationPage.category
            content.userInfo = ["tag": tag]
            if body["silent"] as? Bool != true { content.sound = .default }
            posted.insert(tab.id)
            Task {
                await authorization.value
                let center = UNUserNotificationCenter.current()
                // a tag names one slot per origin, across its tabs; refilling it alerts only with `renotify`
                if !tag.isEmpty {
                    let replaced = await center.deliveredNotifications().map(\.request).filter {
                        $0.content.threadIdentifier == site && $0.content.userInfo["tag"] as? String == tag
                    }
                    center.removeDeliveredNotifications(withIdentifiers: replaced.map(\.identifier))
                    if !replaced.isEmpty, body["renotify"] as? Bool != true {
                        content.sound = nil
                        content.interruptionLevel = .passive
                    }
                }
                let request = UNNotificationRequest(
                    identifier: "\(tab.id.uuidString)/\(id)", content: content, trigger: nil)
                do {
                    try await center.add(request)
                    reply(["type": "show", "id": id], permission)
                } catch {
                    reply(["type": "error", "id": id], permission)
                }
            }
        case "close":
            UNUserNotificationCenter.current().removeDeliveredNotifications(
                withIdentifiers: ["\(tab.id.uuidString)/\(id)"])
        default:
            break
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        let identifier = response.notification.request.identifier
        let clicked = response.actionIdentifier == UNNotificationDefaultActionIdentifier
        await respond(to: identifier, clicked: clicked)
    }

    /// `identifier` is `<tab id>/<notification id>`; a dismissal fires `close`.
    /// A click goes to the window already on the tab's space or profile, waking the tab
    func respond(to identifier: String, clicked: Bool) {
        if ExtensionAPIBridge.shared.notificationResponded(identifier, clicked: clicked) { return }
        let parts = identifier.split(separator: "/", maxSplits: 1).map(String.init)
        let managers = BrowserWindows.shared.allManagers
        guard parts.count == 2, let tabID = UUID(uuidString: parts[0]),
            let tab = managers.lazy.flatMap(\.allTabs).first(where: { $0.id == tabID })
        else { return }
        if clicked {
            let home =
                managers.first { $0.isShowing(tab) }
                ?? managers.first {
                    tab.isEssential ? $0.currentProfile.id == tab.profileID : $0.space(of: tab) === $0.currentSpace
                }
                ?? BrowserWindows.shared.browserScope
            home?.revealTab(tab)
        }
        tab.webView.callAsyncJavaScript(
            WebNotificationPage.receive, arguments: ["m": ["type": clicked ? "click" : "close", "id": parts[1]]],
            in: nil, in: .page)
    }
}

extension WebNotifications {
    /// `navigator.setAppBadge` and `clearAppBadge`, secure contexts only. No argument
    /// sets a flag and 0 clears; anything the page hasn't the notifications permission
    /// for rejects with NotAllowedError
    private static let badgeSource = """
    (() => {
      if (!isSecureContext) {
        delete Navigator.prototype.setAppBadge;
        delete Navigator.prototype.clearAppBadge;
        return;
      }
      if (globalThis.__artemisBadge) return;
      const handler = webkit.messageHandlers.\(WebNotificationPage.messageName);
      const send = handler.postMessage.bind(handler);
      const asking = new Map();
      let requests = 0;
      const ask = fields => new Promise((resolve, reject) => {
        const request = ++requests;
        asking.set(request, { resolve, reject });
        send({ type: "badge", request, ...fields });
      });
      const methods = {
        setAppBadge(contents = undefined) {
          if (contents === undefined) return ask({});
          let count;
          try { count = Number(contents); } catch (e) { return Promise.reject(e); }
          if (!Number.isFinite(count) || Math.trunc(count) < 0 || Math.trunc(count) > Number.MAX_SAFE_INTEGER) {
            return Promise.reject(new TypeError("Value is outside the 'unsigned long long' value range."));
          }
          return ask({ count: Math.trunc(count) });
        },
        clearAppBadge() { return ask({ count: 0 }); },
      };
      for (const [name, value] of Object.entries(methods)) {
        Object.defineProperty(Navigator.prototype, name, { value, writable: true, enumerable: true, configurable: true });
      }
      Object.defineProperty(globalThis, "__artemisBadge", { value: Object.freeze({
        receive(m) {
          const pending = asking.get(m.request);
          asking.delete(m.request);
          if (m.granted) pending?.resolve();
          else pending?.reject(new DOMException("The notifications permission has not been granted.", "NotAllowedError"));
        },
      }) });
    })();
    """
}
