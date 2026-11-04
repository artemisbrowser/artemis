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
    /// how far the strip's centre sits to the right of the sidebar's edge.
    /// nil means "the strip starts at the edge" (half its width), which is the
    /// case when it lives in the gap; a strip that straddles the seam passes 0
    var centreOffsetFromEdge: CGFloat? = nil

    func makeNSView(context: Context) -> HandleView {
        let view = HandleView()
        configure(view)
        return view
    }

    func updateNSView(_ nsView: HandleView, context: Context) {
        configure(nsView)
    }

    private func configure(_ view: HandleView) {
        view.onDrag = { x in
            width = min(max(x, range.lowerBound), range.upperBound)
        }
        view.onDraggingChanged = onDraggingChanged
        view.centreOffsetFromEdge = centreOffsetFromEdge
    }

    final class HandleView: NSView {
        var onDrag: ((CGFloat) -> Void)?
        var onDraggingChanged: ((Bool) -> Void)?
        var centreOffsetFromEdge: CGFloat?

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .resizeLeftRight)
        }

        override func mouseDown(with event: NSEvent) {
            onDraggingChanged?(true)
        }

        override func mouseUp(with event: NSEvent) {
            onDraggingChanged?(false)
        }

        override func mouseDragged(with event: NSEvent) {
            // window x, minus wherever the sidebar's edge sits inside the grip,
            // is the width being asked for
            onDrag?(event.locationInWindow.x - (centreOffsetFromEdge ?? bounds.width / 2))
        }
    }
}
