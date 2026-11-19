// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import AppKit
import SwiftUI

/// AppKit's own traffic lights, made for this window and mounted in the sidebar so they move on its
/// exact frames; the window's set stays hidden in its titlebar except in fullscreen
struct TrafficLightMount: NSViewRepresentable {
    /// fills what it's offered, sparing SwiftUI an Auto Layout measurement of its subtree
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MountView, context: Context) -> CGSize? {
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

    /// where button `index` (0 = close) sits inside the mount; mirrored right to left
    private static func buttonFrame(_ index: Int, mirrored: Bool) -> NSRect {
        let x = leadingInset + CGFloat(index) * buttonPitch
        return NSRect(x: mirrored ? width - x - buttonSize : x, y: 9, width: buttonSize, height: buttonSize)
    }

    func makeNSView(context: Context) -> MountView {
        let view = MountView()
        view.mirrored = context.environment.layoutDirection == .rightToLeft
        return view
    }

    func updateNSView(_ mount: MountView, context: Context) {
        let mirrored = context.environment.layoutDirection == .rightToLeft
        guard mount.mirrored != mirrored else { return }
        mount.mirrored = mirrored
        mount.needsLayout = true
    }

    /// the buttons' home: transparent to clicks outside them, and it answers
    /// AppKit's private group-hover question so the glyphs show on hover, as
    /// outside the titlebar there's no theme frame to answer it
    final class MountView: NSView {
        private static let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        /// close, minimise, zoom
        private(set) var buttons: [NSButton] = []
        /// the window's own set, hidden in its titlebar; held because once it's hidden,
        /// `standardWindowButton` answers with a visible copy
        private(set) var windowButtons: [NSButton] = []
        private var tracking: NSTrackingArea?
        private var mouseInside = false
        private var fullScreenObservers: [NSObjectProtocol] = []
        var mirrored = false

        deinit {
            fullScreenObservers.forEach(NotificationCenter.default.removeObserver)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            buttons.forEach { $0.removeFromSuperview() }
            fullScreenObservers.forEach(NotificationCenter.default.removeObserver)
            guard let window else {
                buttons = []
                windowButtons = []
                fullScreenObservers = []
                return
            }
            windowButtons =
                (window.standardWindowButton(.closeButton)?.superview as? MountView)?.windowButtons
                ?? Self.types.compactMap(window.standardWindowButton)
            buttons = Self.types.compactMap { NSWindow.standardWindowButton($0, for: window.styleMask) }
            for button in buttons {
                button.target = window
                addSubview(button)
            }
            window.setAccessibilityCloseButton(buttons.first)
            window.setAccessibilityMinimizeButton(buttons.dropFirst().first)
            window.setAccessibilityZoomButton(buttons.last)
            window.setAccessibilityFullScreenButton(buttons.last)
            showWindowButtons(window.styleMask.contains(.fullScreen))
            // fullscreen's auto-reveal titlebar shows the window's own set, from entry until the exit begins
            let center = NotificationCenter.default
            fullScreenObservers = [
                (NSWindow.willEnterFullScreenNotification, true), (NSWindow.willExitFullScreenNotification, false),
            ].map { name, shown in
                center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.showWindowButtons(shown) }
                }
            }
            needsLayout = true
            updateTrackingAreas()
        }

        /// fullscreen can't minimise, so the sidebar's minimise button is off while the window's own set shows
        private func showWindowButtons(_ shown: Bool) {
            for button in windowButtons { button.isHidden = !shown }
            if buttons.count == 3 { buttons[1].isEnabled = !shown }
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            let view = super.hitTest(point)
            return view === self ? nil : view
        }

        override func layout() {
            super.layout()
            for (index, button) in buttons.enumerated() {
                let frame = TrafficLightMount.buttonFrame(index, mirrored: mirrored)
                if button.frame != frame { button.frame = frame }
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
            for button in buttons {
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
}
