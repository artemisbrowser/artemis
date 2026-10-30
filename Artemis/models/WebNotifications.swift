import AppKit
import UserNotifications
import WebKit

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
        controller.addUserScript(
            WKUserScript(source: WebNotificationPage.source, injectionTime: .atDocumentStart, forMainFrameOnly: true))
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
        case "create":
            guard permission == "granted", !id.isEmpty, id.count <= 64,
                let title = body["title"] as? String
            else { return reply(["type": "error", "id": id], permission) }
            let content = UNMutableNotificationContent()
            // a locked space's page content stays out of Notification Center
            let locked = manager.space(of: tab).map(SpaceLock.shared.isLocked) == true
            content.title = locked ? "Notification from a locked space" : title
            content.body = locked ? "" : body["body"] as? String ?? ""
            content.subtitle = locked ? "" : origin.host
            content.threadIdentifier = site
            content.categoryIdentifier = WebNotificationPage.category
            if body["silent"] as? Bool != true { content.sound = .default }
            posted.insert(tab.id)
            let request = UNNotificationRequest(
                identifier: "\(tab.id.uuidString)/\(id)", content: content, trigger: nil)
            Task {
                await authorization.value
                do {
                    try await UNUserNotificationCenter.current().add(request)
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

    /// `identifier` is `<tab id>/<notification id>`; a dismissal fires `close`
    private func respond(to identifier: String, clicked: Bool) {
        if ExtensionAPIBridge.shared.notificationResponded(identifier, clicked: clicked) { return }
        let parts = identifier.split(separator: "/", maxSplits: 1).map(String.init)
        let managers = BrowserWindows.shared.allManagers
        guard parts.count == 2, let tabID = UUID(uuidString: parts[0]),
            let tab = managers.lazy.flatMap(\.allTabs).first(where: { $0.id == tabID })
        else { return }
        if clicked {
            (managers.first { $0.isShowing(tab) } ?? BrowserWindows.shared.browserScope)?
                .revealTab(tab)
        }
        tab.webView.callAsyncJavaScript(
            WebNotificationPage.receive, arguments: ["m": ["type": clicked ? "click" : "close", "id": parts[1]]],
            in: nil, in: .page)
    }
}
