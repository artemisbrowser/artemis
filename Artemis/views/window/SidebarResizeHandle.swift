// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import AppKit
import SwiftUI

/// the resize strip between sidebar and web card, in AppKit: next to a WKWebView,
/// SwiftUI's onHover and cursor push/pop drop out where cursor rects don't
struct SidebarResizeHandle: NSViewRepresentable {
    /// fills what it's offered, sparing SwiftUI an Auto Layout measurement of its subtree
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSViewType, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    @Binding var width: Double
    let range: ClosedRange<Double>
    /// fires true on mouse-down, false on mouse-up — lets the overlay
    /// sidebar lock itself open while a resize is in flight
    var onDraggingChanged: ((Bool) -> Void)? = nil

    func makeNSView(context: Context) -> HandleView {
        let view = HandleView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: HandleView, context: Context) {
        view.width = $width
        view.range = range
        view.mirrored = context.environment.layoutDirection == .rightToLeft
        view.onDraggingChanged = onDraggingChanged
    }

    final class HandleView: NSView {
        fileprivate var width: Binding<Double>?
        fileprivate var range: ClosedRange<Double> = 0...0
        /// right to left, dragging left widens the sidebar
        fileprivate var mirrored = false
        fileprivate var onDraggingChanged: ((Bool) -> Void)?
        /// window x and sidebar width at mouse-down: the drag moves the edge by the
        /// pointer's travel, wherever in the strip it was grabbed
        private var start: (x: CGFloat, width: Double)?

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .resizeLeftRight)
        }

        override func mouseDown(with event: NSEvent) {
            start = width.map { (event.locationInWindow.x, $0.wrappedValue) }
            onDraggingChanged?(true)
        }

        override func mouseUp(with event: NSEvent) {
            start = nil
            onDraggingChanged?(false)
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start, let width else { return }
            let travel = Double(event.locationInWindow.x - start.x)
            let asked = start.width + (mirrored ? -travel : travel)
            width.wrappedValue = min(max(asked, range.lowerBound), range.upperBound)
        }
    }
}
