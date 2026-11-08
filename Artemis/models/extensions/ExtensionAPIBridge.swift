// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import AppKit
import UserNotifications
import WebKit

/// native half of the namespaces WebKit leaves undefined that need more than JavaScript. the
/// `ExtensionCompat` shim calls in over `sendNativeMessage` and hears events on its `connectNative`
/// ports; state is keyed by `key(of:)`, as one extension runs once per profile
@MainActor
final class ExtensionAPIBridge {
    static let shared = ExtensionAPIBridge()

    private var offscreenDocuments: [String: OffscreenDocument] = [:]
    private var sidePanels: [String: NSPanel] = [:]
    private var sidePanelObservers: [String: any NSObjectProtocol] = [:]
    private var pushPorts: [String: [WKWebExtension.MessagePort]] = [:]
    private var liveNotifications: [String: Set<String>] = [:]
    private var panelSettings: [String: PanelSettings] =
        UserDefaults.standard.data(forKey: ExtensionAPIBridge.panelSettingsKey)
        .flatMap { try? JSONDecoder().decode([String: PanelSettings].self, from: $0) } ?? [:]

    private struct PanelSettings: Codable {
        var path: String?
        var enabled = true
        var openOnActionClick = false
    }

    private static let panelSettingsKey = "extensionSidePanelsV1"
    /// Notification Center identifiers are `extension/<context id>/<notification id>`
    private static let notificationPrefix = "extension/"

    /// one shim message → its reply; nil for the types `ExtensionProxyBridge` owns. a caller
    /// without what Chrome would require of it is answered empty, which the shim reads as refused
    func handle(_ message: [String: Any], for context: WKWebExtensionContext) async -> [String: Any]? {
        guard let type = message["artemisCompat"] as? String else { return nil }
        guard Self.permits(type, message, context) else { return [:] }
        let id = Self.key(of: context)
        switch type {
        case "offscreen.create":
            guard offscreenDocuments[id] == nil else {
                return ["error": "Only a single offscreen document may be created."]
            }
            guard let url = (message["url"] as? String).flatMap(URL.init(string:)),
                Self.isResource(url, of: context), let configuration = context.webViewConfiguration
            else { return ["error": "The offscreen document must be a page of this extension."] }
            configuration.mediaTypesRequiringUserActionForPlayback = []
            let document = OffscreenDocument(url: url, configuration: configuration)
            offscreenDocuments[id] = document
            guard await document.loaded() else {
                if offscreenDocuments[id] === document { offscreenDocuments[id] = nil }
                return ["error": "The offscreen document failed to load."]
            }
            return ["ok": true]

        case "offscreen.close":
            return ["ok": offscreenDocuments.removeValue(forKey: id) != nil]

        case "runtime.installedNow":
            return ["fresh": !PerfFlags.on("install-filter")
                || ExtensionManager.shared.installedThisSession.contains(id)]

        case "contexts.list":
            var found: [String: Any] = [:]
            found["offscreen"] = offscreenDocuments[id]?.url.absoluteString
            found["sidePanel"] = (sidePanels[id]?.contentView as? WKWebView)?.url?.absoluteString
            return found

        case "identity.launch":
            let interactive = message["interactive"] as? Bool ?? false
            guard let url = (message["url"] as? String).flatMap(URL.init(string:)),
                url.scheme == "https" || url.scheme == "http"
            else { return ["error": "Authorization page could not be loaded."] }
            let host = ExtensionCompat.redirectHost(
                storedID: context.uniqueIdentifier, manifest: context.webExtension.manifest)
            let flow = AuthFlow(
                url: url, redirectHost: host.lowercased(),
                title: context.webExtension.displayName ?? "Sign In",
                dataStore: ProfileStore.dataStore(for: Self.profile(of: context)))
            if let redirect = await flow.run(interactive: interactive) {
                return ["url": redirect.absoluteString]
            }
            return ["error": interactive ? "The user did not approve access." : "User interaction required."]

        case "fetch.perform":
            return await ExtensionProxyBridge.performBridgedFetch(message, for: context, in: Self.profile(of: context))

        case "sidePanel.state":
            let settings = panelSettings[context.uniqueIdentifier] ?? PanelSettings()
            var reply: [String: Any] = [
                "enabled": settings.enabled, "openPanelOnActionClick": settings.openOnActionClick,
            ]
            reply["path"] = settings.path ?? Self.defaultPanelPath(of: context)
            return reply

        case "sidePanel.configure":
            var settings = panelSettings[context.uniqueIdentifier] ?? PanelSettings()
            if let path = message["path"] as? String { settings.path = path }
            if let enabled = message["enabled"] as? Bool { settings.enabled = enabled }
            if let open = message["openPanelOnActionClick"] as? Bool { settings.openOnActionClick = open }
            panelSettings[context.uniqueIdentifier] = settings
            if let data = try? JSONEncoder().encode(panelSettings) {
                UserDefaults.standard.set(data, forKey: Self.panelSettingsKey)
            }
            if !settings.enabled { sidePanels[id]?.close() }
            return ["ok": true]

        case "sidePanel.open":
            let path = (message["path"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return ["ok": openSidePanel(for: context, path: path)]

        case "sidePanel.close":
            sidePanels[id]?.close()
            return ["ok": true]

        case "action.userSettings":
            let ext = ExtensionManager.shared.owner(of: context)
            return ["isOnToolbar": ext?.isPinned ?? false]

        case "management.uninstallSelf":
            // the lab must never put a dialog in front of anyone; it keeps the extension
            guard !ExtensionLab.isRequested, let ext = ExtensionManager.shared.owner(of: context)
            else { return ["ok": false] }
            let alert = NSAlert()
            alert.messageText = "“\(ext.name)” wants to remove itself."
            alert.informativeText = "Its settings and data are deleted with it."
            alert.addButton(withTitle: "Keep")
            alert.addButton(withTitle: "Remove")
            guard alert.runModal() == .alertSecondButtonReturn else { return ["ok": false] }
            Task { ExtensionManager.shared.remove(ext) }
            return ["ok": true]

        case "downloads.download":
            return await download(message, for: context)

        case "downloads.showFolder":
            NSWorkspace.shared.open(
                FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0])
            return ["ok": true]

        case "search.query":
            guard let text = message["text"] as? String, !text.isEmpty,
                let url = URLInput.searchURL(for: text)
            else { return ["ok": false] }
            // a focused incognito window only for an extension allowed there, and only a space of
            // the extension's own profile
            let profile = Self.profile(of: context)
            let windows = BrowserWindows.shared
            let incognito = windows.current.flatMap {
                $0.kind == .incognito && context.hasAccessToPrivateData && $0.currentSpace.profileID == profile
                    ? $0 : nil
            }
            guard let manager = incognito ?? windows.browserScope ?? windows.seed ?? ExtensionManager.shared.tabManager
            else { return ["ok": false] }
            if manager.currentSpace.profileID == profile {
                if message["disposition"] as? String == "CURRENT_TAB", let tab = manager.selectedTab {
                    tab.load(url)
                } else {
                    manager.newTab(url: url)
                }
            } else if let space = manager.spaces.first(where: { $0.profileID == profile }) {
                manager.selectSpace(space)
                manager.newTab(url: url, in: space)
            } else {
                return ["ok": false]
            }
            return ["ok": true]

        case "notifications.show":
            guard let note = message["id"] as? String else { return ["ok": false] }
            let content = UNMutableNotificationContent()
            content.title = message["title"] as? String ?? ""
            content.body = message["body"] as? String ?? ""
            content.subtitle = message["context"] as? String ?? ""
            content.threadIdentifier = id
            content.categoryIdentifier = WebNotificationPage.category
            if message["silent"] as? Bool != true { content.sound = .default }
            liveNotifications[id, default: []].insert(note)
            let center = UNUserNotificationCenter.current()
            guard !ExtensionLab.isRequested else { return ["ok": true] }
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
            let request = UNNotificationRequest(
                identifier: Self.notificationPrefix + id + "/" + note, content: content, trigger: nil)
            return ["ok": (try? await center.add(request)) != nil]

        case "notifications.clear":
            guard let note = message["id"] as? String else { return ["wasCleared": false] }
            UNUserNotificationCenter.current().removeDeliveredNotifications(
                withIdentifiers: [Self.notificationPrefix + id + "/" + note])
            return ["wasCleared": liveNotifications[id]?.remove(note) != nil]

        case "notifications.list":
            return ["ids": Array(liveNotifications[id] ?? [])]

        case "clipboard.write":
            guard context.hasPermission(.clipboardWrite), let text = message["text"] as? String
            else { return ["ok": false] }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            return ["ok": true]

        default:
            return await handleBrowserData(type, message, for: context)
        }
    }

    /// the manifest permission or host access each bridged type needs, as Chrome asks it of the
    /// caller; the browser-data types gate themselves, and a type not named is open to all
    private static func permits(
        _ type: String, _ message: [String: Any], _ context: WKWebExtensionContext
    ) -> Bool {
        let namespace = String(type.prefix { $0 != "." })
        switch namespace {
        case "downloads", "notifications", "search", "identity", "offscreen", "sidePanel", "idle":
            return ExtensionData.declares(namespace, context)
        case "setting":
            return ExtensionData.declares(message["name"] as? String == "proxy" ? "proxy" : "privacy", context)
        case "proxy":
            return ExtensionData.declares("proxy", context)
        case "fetch":
            return (message["url"] as? String).flatMap(URL.init(string:)).map { context.hasAccess(to: $0) } ?? false
        case "dnr":
            let tab = ExtensionManager.shared.currentTab
            return context.hasPermission(.declarativeNetRequestFeedback)
                || tab?.url.map { context.hasAccess(to: $0, in: tab) } == true
        case "probe":
            return SelfTest.isRequested
        default:
            return true
        }
    }

    /// one extension instance: its id in the profile it runs in. the id alone
    /// names it in every profile, and their offscreen pages and ports must not mix
    private static func key(of context: WKWebExtensionContext) -> String {
        key(of: context, in: profile(of: context))
    }

    /// the profile an extension instance runs in: each profile has its own controller
    private static func profile(of context: WKWebExtensionContext) -> UUID {
        context.webExtensionController.flatMap(WebExtensionRuntime.profile(of:)) ?? Profile.defaultID
    }

    static func key(of context: WKWebExtensionContext, in profile: UUID) -> String {
        context.uniqueIdentifier + "@" + profile.uuidString
    }

    // MARK: - Push ports

    /// a page's `connectNative` to the compat id: kept until it disconnects
    func connect(_ port: WKWebExtension.MessagePort, for context: WKWebExtensionContext) {
        let id = Self.key(of: context)
        pushPorts[id, default: []].append(port)
        port.disconnectHandler = { [weak self, weak port] _ in
            self?.pushPorts[id]?.removeAll { $0 === port }
        }
    }

    /// a Notification Center response: true when the notification was an
    /// extension's, whose open pages then hear about it
    func notificationResponded(_ identifier: String, clicked: Bool) -> Bool {
        guard identifier.hasPrefix(Self.notificationPrefix) else { return false }
        let parts = identifier.dropFirst(Self.notificationPrefix.count)
            .split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return true }
        liveNotifications[parts[0]]?.remove(parts[1])
        let event: [String: Any] = [
            "event": clicked ? "notifications.clicked" : "notifications.closed", "id": parts[1],
        ]
        for port in pushPorts[parts[0]] ?? [] where !port.isDisconnected {
            port.sendMessage(event, completionHandler: nil)
        }
        return true
    }

    // MARK: - Lifecycle

    /// the extension stopped running: its offscreen page, panel and ports go too
    func tearDown(_ context: WKWebExtensionContext) {
        let id = Self.key(of: context)
        offscreenDocuments[id] = nil
        sidePanels[id]?.close()
        pushPorts[id] = nil
        if let profile = context.webExtensionController.flatMap(WebExtensionRuntime.profile(of:)) {
            ExtensionProxyBridge.shared.release(owner: context.uniqueIdentifier, in: profile)
        }
    }

    // MARK: - Side panel

    /// an uninstalled extension's panel settings go with it
    func forgetPanelSettings(of id: String) {
        guard panelSettings.removeValue(forKey: id) != nil,
            let data = try? JSONEncoder().encode(panelSettings)
        else { return }
        UserDefaults.standard.set(data, forKey: Self.panelSettingsKey)
    }

    /// an action click for an extension that set `openPanelOnActionClick` and has
    /// no popup toggles its panel; false leaves the click to WebKit
    func handleActionClick(for context: WKWebExtensionContext, presentsPopup: Bool) -> Bool {
        guard !presentsPopup, panelSettings[context.uniqueIdentifier]?.openOnActionClick == true
        else { return false }
        if let panel = sidePanels[Self.key(of: context)] {
            panel.close()
            return true
        }
        return openSidePanel(for: context, path: nil)
    }

    /// the panel is a child window along the browser window's trailing edge,
    /// so it moves with the window it belongs to
    private func openSidePanel(for context: WKWebExtensionContext, path: String?) -> Bool {
        let id = Self.key(of: context)
        let settings = panelSettings[context.uniqueIdentifier] ?? PanelSettings()
        guard settings.enabled,
            let path = path ?? settings.path ?? Self.defaultPanelPath(of: context),
            let url = URL(string: path, relativeTo: context.baseURL)?.absoluteURL,
            Self.isResource(url, of: context)
        else { return false }
        if let panel = sidePanels[id], let webView = panel.contentView as? WKWebView {
            if webView.url != url { webView.load(URLRequest(url: url)) }
            panel.makeKeyAndOrderFront(nil)
            return true
        }
        // never the key window: from a popup's button that is the popover's own
        guard let configuration = context.webViewConfiguration,
            let parent = BrowserWindows.shared.browserScope.flatMap(BrowserWindows.shared.window(of:))
                ?? NSApp.mainWindow
        else { return false }

        let webView = WKWebView(frame: .zero, configuration: configuration)
        let panel = NSPanel(
            contentRect: .zero, styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered, defer: false)
        panel.title = context.webExtension.displayName ?? "Side Panel"
        panel.contentView = webView
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        let width = min(400, parent.frame.width / 2)
        panel.setFrame(
            NSRect(
                x: parent.frame.maxX - width, y: parent.frame.minY,
                width: width, height: parent.frame.height),
            display: false)
        parent.addChildWindow(panel, ordered: .above)
        sidePanelObservers[id] = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: panel, queue: .main
        ) { [weak self, weak panel] _ in
            MainActor.assumeIsolated {
                if let observer = self?.sidePanelObservers.removeValue(forKey: id) {
                    NotificationCenter.default.removeObserver(observer)
                }
                guard let panel else { return }
                panel.parent?.removeChildWindow(panel)
                if self?.sidePanels[id] === panel { self?.sidePanels[id] = nil }
            }
        }
        sidePanels[id] = panel
        webView.load(URLRequest(url: url))
        panel.makeKeyAndOrderFront(nil)
        return true
    }

    private static func defaultPanelPath(of context: WKWebExtensionContext) -> String? {
        (context.webExtension.manifest["side_panel"] as? [String: Any])?["default_path"] as? String
    }

    private static func isResource(_ url: URL, of context: WKWebExtensionContext) -> Bool {
        url.scheme == context.baseURL.scheme && url.host() == context.baseURL.host()
    }

    // MARK: - Downloads

    /// a web URL downloads through a tab of the extension's profile, the current one first, so it
    /// shows in Downloads with that profile's cookies; page-local bytes are written straight to disk,
    /// quarantined
    private func download(_ message: [String: Any], for context: WKWebExtensionContext) async -> [String: Any] {
        let name = (message["filename"] as? String)
            .map { URL(fileURLWithPath: $0).lastPathComponent }
            .flatMap { $0.isEmpty || $0 == "/" ? nil : $0 }
        guard let encoded = message["bytesBase64"] as? String else {
            guard let url = (message["url"] as? String).flatMap(URL.init(string:)),
                url.scheme == "https" || url.scheme == "http"
            else { return ["error": "Invalid URL."] }
            let profile = Self.profile(of: context)
            let tabs = [ExtensionManager.shared.currentTab].compactMap { $0 }
                + BrowserWindows.shared.allManagers.flatMap(\.allTabs)
            guard let tab = tabs.first(where: { !$0.isPrivate && $0.profileID == profile }) else {
                return ["error": "Download failed."]
            }
            // the delegate must be set inside the handler: by the time the async form
            // resumes, WebKit may have found no delegate and cancelled the download
            tab.webView.startDownload(using: URLRequest(url: url)) { download in
                DownloadManager.shared.register(download, filename: name)
            }
            return ["ok": true]
        }
        guard let data = Data(base64Encoded: encoded) else { return ["error": "Download failed."] }
        let destination: URL
        if message["saveAs"] as? Bool == true {
            guard !ExtensionLab.isRequested else { return ["error": "Download canceled."] }
            let panel = NSSavePanel()
            panel.canCreateDirectories = true
            panel.nameFieldStringValue = name ?? "download"
            guard panel.runModal() == .OK, let url = panel.url else {
                return ["error": "Download canceled."]
            }
            destination = url
        } else {
            // ~/Downloads raises a Downloads folder prompt for a lab copy
            let folder = SelfTest.isRequested
                ? FileManager.default.temporaryDirectory
                : FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            destination = DownloadItem.uniqueURL(for: folder.appendingPathComponent(name ?? "download"))
        }
        guard (try? data.write(to: destination)) != nil else { return ["error": "Download failed."] }
        DownloadItem.quarantine(destination, from: nil)
        return ["ok": true]
    }
}

/// `identity.launchWebAuthFlow`: the provider's page in the calling extension's profile, stopped
/// at the first navigation to the redirect host. the window appears only once a load finishes
/// without reaching it
private final class AuthFlow: NSObject, WKNavigationDelegate, NSWindowDelegate {
    private let url: URL
    private let redirectHost: String
    private let title: String
    private let webView: WKWebView
    private var window: NSWindow?
    private var interactive = false
    private var continuation: CheckedContinuation<URL?, Never>?

    init(url: URL, redirectHost: String, title: String, dataStore: WKWebsiteDataStore) {
        self.url = url
        self.redirectHost = redirectHost
        self.title = title
        webView = WKWebView(
            frame: .zero, configuration: BrowserTab.defaultConfiguration(dataStore: dataStore))
        super.init()
        webView.navigationDelegate = self
    }

    /// the redirect URL, or nil when the user closed the window, the page
    /// failed, or a non-interactive flow needed the user
    func run(interactive: Bool) async -> URL? {
        self.interactive = interactive
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            webView.load(URLRequest(url: url))
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(30))
                if self?.window == nil { self?.finish(nil) }
            }
        }
    }

    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        guard let target = navigationAction.request.url, target.host()?.lowercased() == redirectHost
        else { return .allow }
        finish(target)
        return .cancel
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        window?.subtitle = webView.url?.host() ?? ""
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if interactive { show() } else { finish(nil) }
    }

    /// 102 is WebKit's "interrupted by policy change": the redirect cancel itself
    func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        let error = error as NSError
        let failing = error.userInfo[NSURLErrorFailingURLErrorKey] as? URL
        if failing?.host()?.lowercased() == redirectHost {
            finish(failing)
        } else if window == nil, ![NSURLErrorCancelled, 102].contains(error.code) {
            finish(nil)
        }
    }

    func windowWillClose(_ notification: Notification) { finish(nil) }

    private func show() {
        guard window == nil else { return }
        let size = NSSize(width: 520, height: 680)
        let anchor = NSApp.keyWindow?.frame ?? NSScreen.main?.visibleFrame ?? NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: NSRect(
                x: anchor.midX - size.width / 2, y: anchor.midY - size.height / 2,
                width: size.width, height: size.height),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = title
        window.subtitle = webView.url?.host() ?? ""
        window.contentView = webView
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    private func finish(_ redirect: URL?) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: redirect)
        webView.stopLoading()
        window?.delegate = nil
        window?.close()
    }
}
