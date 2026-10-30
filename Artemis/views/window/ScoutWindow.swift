import AppKit
import SwiftUI
import WebKit

/// The compact single-page window: a link glanced at from another app, and the
/// popup a page opens for a sign-in flow. Both hold one page in a space private
/// to the window, driven by their own `TabManager`, so every browser command
/// lands on the page in front of you.
@MainActor
enum ScoutWindow {
    /// windows are held until they close — an `NSWindow` with no owner is
    /// released out from under its content
    private static var open: [NSWindow] = []

    /// a link, opened for a look
    @discardableResult
    static func open(_ url: URL) -> NSWindow {
        let manager = TabManager(kind: .scout)
        manager.openScoutSpace(on: url)
        return present(manager, size: glanceSize(), centred: true)
    }

    /// `window.open`. The web view has to come back synchronously and already
    /// belong to a window, so the window is built around it here and WebKit
    /// drives the navigation itself
    static func openPopup(
        configuration: WKWebViewConfiguration, features: WKWindowFeatures
    ) -> WKWebView? {
        let manager = TabManager(kind: .scout)
        let tab = manager.openScoutSpace(adopting: configuration)
        present(manager, size: popupSize(features), centred: false)
        return tab.webView
    }

    /// a page that named a size wants a window, not a tab behind the one that
    /// opened it — the shape every sign-in flow relies on
    static func wantsOwnWindow(_ features: WKWindowFeatures) -> Bool {
        features.width != nil || features.height != nil
    }

    @discardableResult
    private static func present(_ manager: TabManager, size: NSSize, centred: Bool) -> NSWindow {
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
        window.title = "Scout"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // clear the opaque window backing so the frame's liquid glass samples
        // the desktop behind it instead of a flat grey fill
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
        window.contentView?.wantsLayer = true
        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        PanelMotion.appear(window)

        self.open.append(window)
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { _ in
            MainActor.assumeIsolated { self.open.removeAll { $0 === window } }
        }
        return window
    }

    private static let exit = Exit()

    /// every close — the lights, ⌘W, promoting the page — leaves the way the
    /// window came in: shrinking a touch as it fades, then closing for real
    private final class Exit: NSObject, NSWindowDelegate {
        private var leaving: Set<ObjectIdentifier> = []

        func windowShouldClose(_ window: NSWindow) -> Bool {
            guard leaving.insert(ObjectIdentifier(window)).inserted else { return false }
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

    /// two-thirds of the screen: big enough to read, plainly not the browser
    private static func glanceSize() -> NSSize {
        let screen = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSSize(width: screen.width * 2 / 3, height: screen.height * 2 / 3)
    }

    /// what the page asked for, clamped to something usable on this screen
    private static func popupSize(_ features: WKWindowFeatures) -> NSSize {
        let screen = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width = features.width?.doubleValue ?? 640
        let height = features.height?.doubleValue ?? 720
        return NSSize(
            width: min(max(width, 320), screen.width),
            height: min(max(height, 240), screen.height))
    }

    /// centred over the window that opened it, so a popup lands where you were
    /// looking rather than over a corner of the desktop
    private static func offsetFromFrontmost(size: NSSize) -> NSPoint {
        let anchor = NSApp.keyWindow?.frame
            ?? (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(
            x: anchor.midX - size.width / 2,
            y: anchor.midY - size.height / 2)
    }
}
