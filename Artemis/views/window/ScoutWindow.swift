// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import AppKit
import SwiftUI
import WebKit

/// the compact single-page window, for a link glanced at from another app, a page's
/// sign-in popup or an installed app: one page in a private space, under its own `TabManager`
@MainActor
enum ScoutWindow {
    /// windows are held until they close — an `NSWindow` with no owner is
    /// released out from under its content
    private static var open: [NSWindow] = []
    /// the installed app each app window shows
    private static var apps: [ObjectIdentifier: UUID] = [:]

    static var isShowing: Bool { !open.isEmpty }

    static func window(showing app: UUID) -> NSWindow? { open.first { apps[ObjectIdentifier($0)] == app } }

    /// a link, opened for a look; from a page, in its `opener` space's profile
    @discardableResult
    static func open(_ url: URL, like opener: Space? = nil) -> NSWindow {
        // a link from another app lands after the activation it came with
        let from =
            NSApp.isActive && NSAppleEventManager.shared().currentAppleEvent?.eventID == AEEventID(kAEGetURL)
            ? takeActivation() : nil
        let manager = TabManager(kind: .scout)
        manager.openScoutSpace(on: url, like: opener)
        let window = present(manager, size: glanceSize(), centred: true, activates: true)
        returnTo[ObjectIdentifier(window)] = from
        return window
    }

    /// an installed app's page, in the jar of the space it was installed from
    static func open(_ app: WebApp) {
        let manager = TabManager(kind: .scout)
        guard let space = app.space(in: manager.spaces) else { return }
        manager.webAppID = app.id
        manager.openScoutSpace(on: app.url, like: space)
        let window = present(
            manager, size: glanceSize(), centred: true, activates: true, title: app.name, autosave: "app-\(app.id)")
        apps[ObjectIdentifier(window)] = app.id
    }

    /// `window.open`: the web view must come back synchronously and already belong
    /// to a window, so the window is built around it and WebKit drives the load
    static func openPopup(
        configuration: WKWebViewConfiguration, features: WKWindowFeatures
    ) -> WKWebView? {
        let manager = TabManager(kind: .scout)
        let tab = manager.openScoutSpace(adopting: configuration)
        present(manager, size: popupSize(features), centred: false, activates: false)
        return tab.webView
    }

    /// a page that named a size wants a window, not a tab behind the one that
    /// opened it — the shape every sign-in flow relies on
    static func wantsOwnWindow(_ features: WKWindowFeatures) -> Bool {
        features.width != nil || features.height != nil
    }

    @discardableResult
    private static func present(
        _ manager: TabManager, size: NSSize, centred: Bool, activates: Bool, title: String = "Scout",
        autosave: String? = nil
    ) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        let root = ScoutView(onClose: { [weak window] in window?.performClose(nil) })
            .environment(manager)
            .environment(manager.tooltipState)
            .environment(ExtensionManager.shared)
            .background(WindowBinder(manager: manager))
        window.contentViewController = NSHostingController(rootView: root)
        window.title = title
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // a clear backing, so the frame's glass samples the desktop, not flat grey
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isReleasedWhenClosed = false
        window.delegate = exit
        // contentViewController makes the window adopt the hosting view's fitting
        // size (the SwiftUI min frame), so force the asked-for size back after
        window.setContentSize(size)
        if centred {
            window.center()
        } else {
            window.setFrameOrigin(offsetFromFrontmost(size: size))
        }
        if let autosave {
            window.setFrameUsingName(autosave)
            window.setFrameAutosaveName(autosave)
        }
        window.contentView?.wantsLayer = true
        window.alphaValue = 0
        // a page's popup never brings Artemis in front of another app
        if activates {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            if !NSApp.isActive { frontOnActivation(window) }
        } else {
            window.makeKeyAndOrderFront(nil)
            if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
        }
        PanelMotion.appear(window)

        self.open.append(window)
        return window
    }

    private static var pendingFront: (any NSObjectProtocol)?

    /// activation completes after `activate` returns and fronts the app's last key window,
    /// so the Scout window is fronted again once it lands
    private static func frontOnActivation(_ window: NSWindow) {
        if let pendingFront { NotificationCenter.default.removeObserver(pendingFront) }
        pendingFront = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak window] _ in
            MainActor.assumeIsolated {
                if let pendingFront { NotificationCenter.default.removeObserver(pendingFront) }
                pendingFront = nil
                guard let window, window.isVisible else { return }
                window.makeKeyAndOrderFront(nil)
                returnTo[ObjectIdentifier(window)] = takeActivation()
            }
        }
    }

    /// set as Artemis is brought forward: the app that was in front
    private static var activation: (at: CFTimeInterval, from: NSRunningApplication?)?
    /// Scout windows a link brought forward, and the app each came from; given up once
    /// anything else of Artemis takes the focus
    private static var returnTo: [ObjectIdentifier: NSRunningApplication] = [:]

    /// once at launch: notes the app in front each time Artemis is brought forward
    static func watchActivation() {
        let center = NotificationCenter.default
        center.addObserver(forName: NSApplication.willBecomeActiveNotification, object: nil, queue: nil) { _ in
            MainActor.assumeIsolated {
                let windows = normalWindows()
                let own = ProcessInfo.processInfo.processIdentifier
                let front = windows.first { $0.pid != own }.flatMap { NSRunningApplication(processIdentifier: $0.pid) }
                activation = (CACurrentMediaTime(), front)
            }
        }
        center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: nil) { _ in
            MainActor.assumeIsolated { returnTo = [:] }
        }
        center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: nil) { note in
            MainActor.assumeIsolated {
                if let window = note.object as? NSWindow, returnTo[ObjectIdentifier(window)] == nil { returnTo = [:] }
            }
        }
    }

    /// the app in front as Artemis was just brought forward, at most once
    private static func takeActivation() -> NSRunningApplication? {
        defer { activation = nil }
        guard let activation, CACurrentMediaTime() - activation.at < 2 else { return nil }
        return activation.from
    }

    /// every app's on-screen normal-level window numbers, front to back; numbers only, as
    /// names would need Screen Recording
    static func normalStack() -> [Int] { normalWindows().map(\.number) }

    private static func normalWindows() -> [(number: Int, pid: pid_t)] {
        (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? [])
            .filter { $0[kCGWindowLayer as String] as? Int == 0 }
            .compactMap { info in
                guard let number = info[kCGWindowNumber as String] as? Int,
                    let pid = info[kCGWindowOwnerPID as String] as? pid_t
                else { return nil }
                return (number, pid)
            }
    }

    private static let exit = Exit()

    /// every close — the lights, ⌘W, promoting the page — leaves the way the
    /// window came in: shrinking a touch as it fades, then closing for real
    private final class Exit: NSObject, NSWindowDelegate {
        private var leaving: Set<ObjectIdentifier> = []

        func windowWillClose(_ notification: Notification) {
            guard let window = notification.object as? NSWindow else { return }
            ScoutWindow.open.removeAll { $0 === window }
            if let app = ScoutWindow.apps.removeValue(forKey: ObjectIdentifier(window)) { WebApps.shared.windowClosed(app) }
        }

        /// a Scout a link brought forward hands the focus back to the link's app first, so
        /// AppKit never promotes a browser window in its place
        func windowShouldClose(_ window: NSWindow) -> Bool {
            guard leaving.insert(ObjectIdentifier(window)).inserted else { return false }
            if let app = ScoutWindow.returnTo.removeValue(forKey: ObjectIdentifier(window)), !app.isTerminated {
                app.activate(from: .current, options: [])
            }
            if let layer = window.contentView?.layer, !Motion.reduceMotion {
                let b = layer.bounds
                var to = CATransform3DMakeTranslation(b.midX, b.midY, 0)
                to = CATransform3DScale(to, 0.96, 0.96, 1)
                to = CATransform3DTranslate(to, -b.midX, -b.midY, 0)
                let shrink = CABasicAnimation(keyPath: "transform")
                shrink.toValue = NSValue(caTransform3D: to)
                shrink.duration = Motion.exitDuration
                shrink.timingFunction = CAMediaTimingFunction(name: .easeIn)
                shrink.fillMode = .forwards
                shrink.isRemovedOnCompletion = false
                layer.add(shrink, forKey: "exit")
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Motion.exitDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                window.animator().alphaValue = 0
            } completionHandler: { [weak self, weak window] in
                guard let window else { return }
                self?.leaving.remove(ObjectIdentifier(window))
                window.close()
            }
            return false
        }
    }

    private static var screenFrame: NSRect {
        (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    }

    /// two-thirds of the screen: big enough to read, plainly not the browser
    private static func glanceSize() -> NSSize {
        let screen = screenFrame
        return NSSize(width: screen.width * 2 / 3, height: screen.height * 2 / 3)
    }

    /// what the page asked for, clamped to something usable on this screen
    private static func popupSize(_ features: WKWindowFeatures) -> NSSize {
        let screen = screenFrame
        let width = features.width?.doubleValue ?? 640
        let height = features.height?.doubleValue ?? 720
        return NSSize(
            width: min(max(width, 320), screen.width),
            height: min(max(height, 240), screen.height))
    }

    /// centred over the window that opened it, so a popup lands where you were
    /// looking rather than over a corner of the desktop
    private static func offsetFromFrontmost(size: NSSize) -> NSPoint {
        let anchor = Lobby.keyWindow?.frame ?? screenFrame
        return NSPoint(
            x: anchor.midX - size.width / 2,
            y: anchor.midY - size.height / 2)
    }
}
