import AppKit
import SwiftUI
import WebKit

/// drags the window, and zooms it on a double click: the titlebar's job, since the
/// window is `isMovable = false`
struct WindowDragStrip: NSViewRepresentable {
    /// fills what it's offered, sparing SwiftUI an Auto Layout measurement of its subtree
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSViewType, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    /// hands a drag to the window server; the self-test stands in for it
    static var perform: (NSWindow, NSEvent) -> Void = { $0.performDrag(with: $1) }
    /// the window server's mouse buttons; the self-test stands in for them
    static var pressedButtons: () -> Int = { NSEvent.pressedMouseButtons }

    /// `performDrag` hands the drag to the window server and returns at once, and
    /// the release may never be sent: the drag is over when the button is up
    fileprivate static func drag(_ window: NSWindow, with event: NSEvent) {
        let manager = BrowserWindows.shared.manager(for: window)
        manager?.isDraggingWindow = true
        perform(window, event)
        guard let manager else { return }
        Task {
            while pressedButtons() & 1 != 0 { try? await Task.sleep(for: .milliseconds(50)) }
            manager.isDraggingWindow = false
        }
    }

    private final class DragView: NSView {
        /// a titlebar drags a window that isn't key in the same press
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return super.mouseDown(with: event) }
            if event.clickCount == 2 { return window.zoom(nil) }
            WindowDragStrip.drag(window, with: event)
        }
    }
}

/// Where a page reaches the window's top edge. A left press there is held back:
/// moved past `slop` it drags the window and the page never sees it; let go
/// first, the press and its release reach the page untouched.
struct PageDragBand: NSViewRepresentable {
    /// from the window's top edge: an 8pt band was missed by half a point
    static let height: CGFloat = 14
    /// per axis, in points: a press that moves no further is still a click
    static let slop: CGFloat = 3

    /// fills what it's offered, sparing SwiftUI an Auto Layout measurement of its subtree
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSViewType, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    func makeNSView(context: Context) -> NSView { BandView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class BandView: NSView {
        private var monitor: Any?
        private var held: NSEvent?
        /// a held press became a drag: the moves after it are not the page's
        private var dragged = false
        private var replaying = false

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            held = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
            ) { [weak self] event in
                guard let self else { return event }
                return route(event)
            }
        }

        private func route(_ event: NSEvent) -> NSEvent? {
            guard let window, event.window === window, !replaying else { return event }
            switch event.type {
            case .leftMouseDown:
                held = nil
                dragged = false
                guard !event.modifierFlags.contains(.control), isOnPage(event.locationInWindow, in: window)
                else { return event }
                held = event
                return nil
            case .leftMouseDragged:
                if dragged { return nil }
                guard let down = held else { return event }
                let from = down.locationInWindow, to = event.locationInWindow
                guard max(abs(to.x - from.x), abs(to.y - from.y)) > PageDragBand.slop else { return nil }
                held = nil
                dragged = true
                if !window.isKeyWindow { window.makeKeyAndOrderFront(nil) }
                WindowDragStrip.drag(window, with: event)
                return nil
            case .leftMouseUp:
                // a drag's release goes on, for AppKit's drag-end monitor, but to no window:
                // the window would hand it to the view last pressed, often the page
                if dragged {
                    dragged = false
                    return NSEvent.mouseEvent(
                        with: .leftMouseUp, location: window.convertPoint(toScreen: event.locationInWindow),
                        modifierFlags: event.modifierFlags, timestamp: event.timestamp, windowNumber: 0,
                        context: nil, eventNumber: event.eventNumber, clickCount: event.clickCount,
                        pressure: event.pressure)
                }
                guard let down = held else { return event }
                held = nil
                replaying = true
                NSApp.sendEvent(down)
                replaying = false
                return event
            default:
                return event
            }
        }

        /// hit-tested from the frame view, as the window dispatches, so a press on
        /// AppKit's resize edge is never taken for the page. A page's slot counts while
        /// the page is elsewhere; a login key over it does not
        private func isOnPage(_ point: NSPoint, in window: NSWindow) -> Bool {
            guard !window.styleMask.contains(.fullScreen), let frame = window.contentView?.superview,
                point.y >= frame.bounds.height - PageDragBand.height,
                let hit = frame.hitTest(point)
            else { return false }
            return hit is WebHostView || hit.superview is WebHostView
                || sequence(first: hit, next: \.superview).contains { $0 is WKWebView }
        }
    }
}
