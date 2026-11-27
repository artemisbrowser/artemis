// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import AppKit

/// an installed app's launcher: it holds the app's Dock tile, ⌘-Tab entry and badge while
/// Artemis draws the app's window, and hands every activation on to Artemis
final class Shim: NSObject, NSApplicationDelegate {
    let appID: String, host: String

    init(appID: String, host: String) {
        self.appID = appID
        self.host = host
    }

    /// must match `WebApps.Shim`
    private func note(_ event: String) -> Notification.Name { Notification.Name("\(host).webapp.\(event)") }

    func applicationDidFinishLaunching(_ notification: Notification) {
        loadIcon()
        let center = DistributedNotificationCenter.default()
        center.addObserver(self, selector: #selector(badge), name: note("badge"), object: appID)
        center.addObserver(self, selector: #selector(loadIcon), name: note("icon"), object: appID)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(terminated), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        front()
    }

    func applicationDidBecomeActive(_ notification: Notification) { front() }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        front()
        return false
    }

    /// Artemis ends a launcher with a signal, so this runs only for a quit from the Dock or ⌘Q
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        DistributedNotificationCenter.default().postNotificationName(
            note("quit"), object: appID, userInfo: nil, deliverImmediately: true)
        return .terminateNow
    }

    /// opens its own bundle in Artemis, which fronts the app's window or opens one
    private func front() {
        guard FileManager.default.fileExists(atPath: Bundle.main.bundlePath) else { return NSApp.terminate(nil) }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: host).first?.bundleURL
        guard let artemis = running ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: host) else {
            return NSApp.terminate(nil)
        }
        NSWorkspace.shared.open(
            [Bundle.main.bundleURL], withApplicationAt: artemis, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func loadIcon() {
        let file = Bundle.main.bundleURL.appending(path: "Contents/Resources/icon.png")
        if let icon = NSImage(contentsOf: file) { NSApp.applicationIconImage = icon }
    }

    @objc private func badge(_ notification: Notification) {
        NSApp.dockTile.badgeLabel = notification.userInfo?["badge"] as? String
    }

    @objc private func terminated(_ notification: Notification) {
        let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        if app?.bundleIdentifier == host { exit(0) }
    }
}

let info = Bundle.main.infoDictionary ?? [:]
guard let appID = info["ArtemisAppID"] as? String, let host = info["ArtemisHost"] as? String else { exit(1) }
let app = NSApplication.shared
let shim = Shim(appID: appID, host: host)
app.delegate = shim
app.setActivationPolicy(.regular)
let name = info["CFBundleName"] as? String ?? "App"
let menu = NSMenu()
let appItem = NSMenuItem()
appItem.submenu = NSMenu(title: name)
appItem.submenu?.addItem(withTitle: "Hide \(name)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
appItem.submenu?.addItem(withTitle: "Quit \(name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
menu.addItem(appItem)
app.mainMenu = menu
app.run()
