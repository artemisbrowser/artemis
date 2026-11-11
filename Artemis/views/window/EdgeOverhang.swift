// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import AppKit
import SwiftUI

/// the band just past the key window's sidebar edge, off the window: a pointer that overshoots the
/// edge onto a display or desktop beside it reports `hovering` there as if it were on the edge
struct EdgeOverhang: NSViewRepresentable {
    static let width: CGFloat = 40

    var onRight: Bool
    var onHover: (Bool) -> Void

    /// whether the pointer, in screen points, is in `window`'s band on its left or right,
    /// over nothing but the desktop: another window there keeps the pointer
    static func contains(_ window: NSWindow?, onRight: Bool) -> Bool {
        guard let window else { return false }
        let frame = window.frame, p = NSEvent.mouseLocation
        let beyond = onRight ? p.x - frame.maxX : frame.minX - p.x
        guard beyond > 0, beyond <= width, p.y >= frame.minY, p.y <= frame.maxY else { return false }
        let hit = NSWindow.windowNumber(at: p, belowWindowWithWindowNumber: 0)
        guard hit != 0, hit != window.windowNumber else { return true }
        let info = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(hit)) as? [[String: Any]]
        return (info?.first?[kCGWindowLayer as String] as? Int ?? 0) < 0
    }

    func makeNSView(context: Context) -> Watch { Watch() }

    func updateNSView(_ view: Watch, context: Context) {
        view.onHover = onHover
        view.onRight = onRight
    }

    final class Watch: NSView {
        var onHover: ((Bool) -> Void)?
        var onRight = false
        private var monitors: [Any] = []
        private var inside = false

        deinit { monitors.forEach(NSEvent.removeMonitor) }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            monitors.forEach(NSEvent.removeMonitor)
            monitors = []
            inside = false
            guard window != nil else { return }
            // off the window, the move belongs to whatever is under it: only a global monitor sees it
            monitors = [
                NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in self?.moved() },
                NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
                    self?.moved()
                    return event
                },
            ].compactMap { $0 }
        }

        private func moved() {
            let now = window?.isKeyWindow == true && EdgeOverhang.contains(window, onRight: onRight)
            guard now != inside else { return }
            inside = now
            onHover?(now)
        }
    }
}
