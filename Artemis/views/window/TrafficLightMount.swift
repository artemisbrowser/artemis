import AppKit
import SwiftUI

/// the window's real traffic lights, re-parented into the sidebar so they move on its exact
/// frames; the sidebar hides by animating its width, as a `.transition` leaves hosted views behind.
/// `MountView.layout()` holds 9pt gaps against AppKit's stock frames; fullscreen hands them back.
struct TrafficLightMount: NSViewRepresentable {
    /// fills what it's offered, sparing SwiftUI an Auto Layout measurement of its subtree
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSViewType, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    /// close/minimise/zoom placement: 14pt buttons on a pitch of button + gap
    private static let buttonSize: CGFloat = 14
    private static let buttonGap: CGFloat = 9
    private static let leadingInset: CGFloat = 9
    private static var buttonPitch: CGFloat { buttonSize + buttonGap }

    /// wide enough that the last button ends inside the bounds — hit-testing
    /// stops at the mount's edge
    static var width: CGFloat { leadingInset + 2 * buttonPitch + buttonSize + 1 }
    /// stock titlebar height; keeps the buttons' 9pt-from-bottom centring sane
    static let height: CGFloat = 32

    /// where button `index` (0 = close) sits inside the mount
    private static func buttonFrame(_ index: Int) -> NSRect {
        NSRect(
            x: leadingInset + CGFloat(index) * buttonPitch, y: 9,
            width: buttonSize, height: buttonSize)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = MountView()
        DispatchQueue.main.async {
            context.coordinator.attach(view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.attach(nsView as? MountView)
    }

    /// the buttons' home: transparent to clicks outside them, and it answers
    /// AppKit's private group-hover question so the glyphs show on hover, as
    /// outside the titlebar there's no theme frame to answer it
    final class MountView: NSView {
        private var tracking: NSTrackingArea?
        private var mouseInside = false
        private var frameObservers: [NSObjectProtocol] = []
        /// asks the coordinator to adopt if it hasn't: a mount is laid out before
        /// its window exists, and a second window's is built while the first is
        /// key, so adoption is re-checked rather than awaited
        var recheckAdoption: (() -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            recheckAdoption?()
        }

        deinit {
            frameObservers.forEach(NotificationCenter.default.removeObserver)
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            let view = super.hitTest(point)
            return view === self ? nil : view
        }

        /// AppKit re-asserts its stock frames (20pt pitch) on the buttons wherever
        /// they live; each frame change lands back here and this re-applies ours,
        /// writing only a frame that is wrong so it stays loop-free
        override func layout() {
            super.layout()
            recheckAdoption?()
            applyButtonFrames()
        }

        fileprivate func applyButtonFrames() {
            for (index, button) in orderedButtons.enumerated() {
                let frame = TrafficLightMount.buttonFrame(index)
                if button.frame != frame { button.frame = frame }
            }
        }

        /// close, minimise, zoom — in their canonical order regardless of the
        /// order they were adopted in
        private var orderedButtons: [NSButton] {
            subviews.compactMap { $0 as? NSButton }.sorted { $0.tag < $1.tag }
        }

        /// watch the adopted buttons so a system re-assert is corrected
        fileprivate func watchButtonFrames() {
            frameObservers.forEach(NotificationCenter.default.removeObserver)
            frameObservers = subviews.compactMap { view in
                guard view is NSButton else { return nil }
                view.postsFrameChangedNotifications = true
                return NotificationCenter.default.addObserver(
                    forName: NSView.frameDidChangeNotification, object: view, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.correctIfNeeded() }
                }
            }
        }

        private func correctIfNeeded() {
            for (index, button) in orderedButtons.enumerated()
            where button.frame != TrafficLightMount.buttonFrame(index) {
                needsLayout = true
                return
            }
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            // `.inVisibleRect` tracks the live bounds; SwiftUI sizes the view after
            // makeNSView, and a zero tracking rect never fires enter/exit
            let area = NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self)
            addTrackingArea(area)
            tracking = area
        }

        override func mouseEntered(with event: NSEvent) {
            setMouseInside(true)
        }

        override func mouseExited(with event: NSEvent) {
            setMouseInside(false)
        }

        /// the glyph follows `_NSThemeWidget`'s internal state, not `_mouseInGroup:`
        /// at draw time; its private zero-argument `mouseEnteredOrExited` makes it
        /// re-ask, so all three are poked to light and dim as one
        func setMouseInside(_ inside: Bool) {
            guard mouseInside != inside else { return }
            mouseInside = inside
            let recompute = Selector(("mouseEnteredOrExited"))
            for case let button as NSButton in subviews {
                if button.responds(to: recompute) {
                    button.perform(recompute)
                }
                button.needsDisplay = true
            }
        }

        /// AppKit's group-hover question, which the buttons ask their ancestors
        @objc func _mouseInGroup(_ button: NSButton) -> Bool {
            mouseInside
        }
    }

    @MainActor
    final class Coordinator {
        private weak var mount: MountView?
        private weak var window: NSWindow?
        private weak var originalSuperview: NSView?
        private var originalFrames: [NSWindow.ButtonType: NSRect] = [:]
        private var observers: [NSObjectProtocol] = []

        private static let buttonTypes: [NSWindow.ButtonType] = [
            .closeButton, .miniaturizeButton, .zoomButton,
        ]

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }

        func attach(_ view: MountView?) {
            if let view, view !== mount {
                mount = view
                view.recheckAdoption = { [weak self] in self?.adoptIfNeeded() }
            }
            guard let mount, let window = mount.window else { return }
            if window !== self.window {
                self.window = window
                installObservers(window)
            }
            adoptIfNeeded()
        }

        private func installObservers(_ window: NSWindow) {
            observers.forEach(NotificationCenter.default.removeObserver)
            let center = NotificationCenter.default
            observers = [
                // fullscreen owns the lights (auto-reveal titlebar); hand back
                center.addObserver(
                    forName: NSWindow.willEnterFullScreenNotification,
                    object: window, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.returnButtonsToSystem() }
                },
                center.addObserver(
                    forName: NSWindow.didExitFullScreenNotification,
                    object: window, queue: .main
                ) { [weak self] _ in
                    DispatchQueue.main.async { self?.adoptIfNeeded() }
                },
                // the reliable "window is fully set up" beat for first adoption
                center.addObserver(
                    forName: NSWindow.didBecomeKeyNotification,
                    object: window, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.adoptIfNeeded() }
                },
            ]
        }

        private func adoptIfNeeded() {
            guard let mount, let window = mount.window,
                !window.styleMask.contains(.fullScreen)
            else { return }

            let buttons = Self.buttonTypes.compactMap(window.standardWindowButton)
            guard buttons.count == 3 else { return }
            // already ours and still attached — nothing to do
            guard buttons[0].superview !== mount else { return }

            // remember the system's own placement for the fullscreen handback
            if originalSuperview == nil, let titlebar = buttons[0].superview {
                originalSuperview = titlebar
                for (type, button) in zip(Self.buttonTypes, buttons) {
                    originalFrames[type] = button.frame
                }
            }

            for (index, button) in buttons.enumerated() {
                // canonical ordering handle for the mount's own layout
                button.tag = index
                mount.addSubview(button)
            }
            mount.applyButtonFrames()
            mount.watchButtonFrames()
            mount.updateTrackingAreas()
        }

        private func returnButtonsToSystem() {
            guard let originalSuperview else { return }
            for type in Self.buttonTypes {
                guard let button = window?.standardWindowButton(type) else { continue }
                originalSuperview.addSubview(button)
                if let frame = originalFrames[type] { button.frame = frame }
            }
        }
    }
}
