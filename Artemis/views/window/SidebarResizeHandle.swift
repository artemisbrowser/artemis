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
    /// the gutter scroller's thumb in SwiftUI's global space, empty when there is none
    var scrollerThumb: () -> CGRect = { .zero }
    /// the list a scroll over the strip goes to
    var scroll: SidebarScroll?
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
        view.scrollerThumb = scrollerThumb
        view.scroll = scroll
        view.mirrored = context.environment.layoutDirection == .rightToLeft
        view.onDraggingChanged = onDraggingChanged
    }

    final class HandleView: NSView {
        fileprivate var width: Binding<Double>?
        fileprivate var range: ClosedRange<Double> = 0...0
        /// right to left, dragging left widens the sidebar
        fileprivate var mirrored = false
        fileprivate var onDraggingChanged: ((Bool) -> Void)?
        fileprivate var scrollerThumb: () -> CGRect = { .zero }
        fileprivate weak var scroll: SidebarScroll?
        private var watching = false
        /// window x and sidebar width at mouse-down: the drag moves the edge by the
        /// pointer's travel, wherever in the strip it was grabbed
        private var start: (x: CGFloat, width: Double)?

        /// the thumb's part of the strip, in the strip's space; SwiftUI's global space is the content view's, top down
        private var hole: CGRect {
            let thumb = scrollerThumb()
            guard !thumb.isEmpty, let content = window?.contentView else { return .null }
            let y = content.isFlipped ? thumb.minY : content.bounds.height - thumb.maxY
            return convert(CGRect(x: thumb.minX, y: y, width: thumb.width, height: thumb.height), from: content)
                .intersection(bounds)
        }

        /// `bounds` less `hole`: what lies below it, above it and to either side
        static func around(_ hole: CGRect, in bounds: CGRect) -> [CGRect] {
            guard !hole.isEmpty else { return [bounds] }
            return [
                CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: hole.minY - bounds.minY),
                CGRect(x: bounds.minX, y: hole.maxY, width: bounds.width, height: bounds.maxY - hole.maxY),
                CGRect(x: bounds.minX, y: hole.minY, width: hole.minX - bounds.minX, height: hole.height),
                CGRect(x: hole.maxX, y: hole.minY, width: bounds.maxX - hole.maxX, height: hole.height),
            ].filter { !$0.isEmpty }
        }

        override func resetCursorRects() {
            for rect in Self.around(hole, in: bounds) { addCursorRect(rect, cursor: .resizeLeftRight) }
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            hole.contains(convert(point, from: superview)) ? nil : super.hitTest(point)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if !watching { watchThumb() }
        }

        /// the cursor rects are cut round the thumb, so they are laid again each time it moves
        private func watchThumb() {
            watching = window != nil
            guard watching else { return }
            withObservationTracking { _ = scrollerThumb() } onChange: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.window?.invalidateCursorRects(for: self)
                    self.watchThumb()
                }
            }
        }

        override func scrollWheel(with event: NSEvent) { scroll?.wheel(event) }

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
            width.wrappedValue = min(max(asked, range.lowerBound), range.upperBound).rounded()
        }
    }
}
