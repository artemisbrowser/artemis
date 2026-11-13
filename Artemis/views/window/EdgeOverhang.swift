// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import AppKit
import SwiftUI

/// whether a pointer in the sidebar's hover area came for the sidebar or is passing through.
/// depth: points from the window's sidebar edge toward its centre; nil off its rows or under another window
struct EdgeApproach {
    /// a pointer from outside reveals once it has kept within `restSlack` this long
    static let restTime: TimeInterval = 0.18
    /// depth a resting pointer may drift, and the way back toward the edge that counts as turning round
    static let restSlack: CGFloat = 6

    let band: CGFloat
    let strip: CGFloat
    private var passing = false
    private var anchor: (depth: CGFloat, time: TimeInterval)?
    private var deepest: CGFloat = 0

    init(band: CGFloat = EdgeOverhang.width, strip: CGFloat) {
        self.band = band
        self.strip = strip
    }

    static func depth(of point: NSPoint, in frame: NSRect, onRight: Bool) -> CGFloat? {
        guard point.y >= frame.minY, point.y <= frame.maxY else { return nil }
        return onRight ? frame.maxX - point.x : point.x - frame.minX
    }

    mutating func reveals(depth: CGFloat?, at time: TimeInterval) -> Bool {
        guard let depth, depth >= -band else {
            passing = true
            anchor = nil
            return false
        }
        guard depth <= strip else {
            passing = false
            return false
        }
        guard passing else { return true }
        if anchor == nil { deepest = depth }
        deepest = max(deepest, depth)
        if let from = anchor, abs(depth - from.depth) <= Self.restSlack {
            passing = time - from.time < Self.restTime
        } else {
            anchor = (depth, time)
        }
        if deepest - depth > Self.restSlack { passing = false }
        return !passing
    }
}

/// watches the sidebar's hover area on the key window: the strip inside its sidebar edge and the
/// band just past it, off the window, where an overshooting pointer lands on a display or desktop
struct EdgeOverhang: NSViewRepresentable {
    static let width: CGFloat = 40

    var strip: CGFloat
    /// hovering, and whether the pointer is off the window
    var onHover: (Bool, Bool) -> Void

    /// whether the pointer, in screen points, is in the band past `window`'s sidebar edge,
    /// over nothing but the desktop: another window there keeps the pointer
    static func contains(_ window: NSWindow?) -> Bool {
        guard let window, let depth = depth(in: window) else { return false }
        return depth < 0 && depth >= -width
    }

    /// the pointer's depth while `window` or, past its edge, the desktop is what it is over
    fileprivate static func depth(in window: NSWindow) -> CGFloat? {
        let p = NSEvent.mouseLocation
        guard let depth = EdgeApproach.depth(of: p, in: window.frame, onRight: WindowChrome.isSidebarOnRight)
        else { return nil }
        let hit = NSWindow.windowNumber(at: p, belowWindowWithWindowNumber: 0)
        if hit == window.windowNumber { return depth }
        guard depth < 0 else { return nil }
        guard hit != 0 else { return depth }
        let info = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(hit)) as? [[String: Any]]
        return (info?.first?[kCGWindowLayer as String] as? Int ?? 0) < 0 ? depth : nil
    }

    func makeNSView(context: Context) -> Watch { Watch() }

    func updateNSView(_ view: Watch, context: Context) {
        view.onHover = onHover
        if view.approach.strip != strip { view.approach = EdgeApproach(strip: strip) }
    }

    final class Watch: NSView {
        var onHover: ((Bool, Bool) -> Void)?
        var approach = EdgeApproach(strip: 0)
        private var monitors: [Any] = []
        private var inside = false
        private var rest: DispatchWorkItem?

        deinit { monitors.forEach(NSEvent.removeMonitor) }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            monitors.forEach(NSEvent.removeMonitor)
            monitors = []
            inside = false
            rest?.cancel()
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
            rest?.cancel()
            var depth = window.flatMap(EdgeOverhang.depth)
            // past the edge only the key window listens; on it, any window of the active app
            if let d = depth, !(d < 0 ? window?.isKeyWindow == true : NSApp.isActive) { depth = nil }
            let now = approach.reveals(depth: depth, at: ProcessInfo.processInfo.systemUptime)
            if !now, let depth, depth >= -EdgeOverhang.width, depth <= approach.strip {
                // a pointer at rest sends no moves
                let again = DispatchWorkItem { [weak self] in self?.moved() }
                rest = again
                DispatchQueue.main.asyncAfter(deadline: .now() + EdgeApproach.restTime, execute: again)
            }
            guard now != inside else { return }
            inside = now
            onHover?(now, (depth ?? 0) < 0)
        }
    }
}
