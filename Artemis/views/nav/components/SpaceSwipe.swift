import AppKit
import SwiftUI

/// detects a horizontal two-finger trackpad swipe over the view it backs and
/// reports it live: `onChanged` streams the cumulative horizontal translation
/// (points, right positive) once the gesture locks horizontal, `onEnded` fires
/// the final translation so the caller can snap or commit. only the moves of a
/// horizontal-locked gesture are consumed, so vertical tab scrolling is unaffected
struct SpaceSwipeDetector: NSViewRepresentable {
    /// fills what it's offered, sparing SwiftUI an Auto Layout measurement of its subtree
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSViewType, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    var onChanged: (CGFloat) -> Void
    var onEnded: (CGFloat) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = SwipeView()
        view.onChanged = onChanged
        view.onEnded = onEnded
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? SwipeView else { return }
        view.onChanged = onChanged
        view.onEnded = onEnded
    }

    final class SwipeView: NSView {
        var onChanged: ((CGFloat) -> Void)?
        var onEnded: ((CGFloat) -> Void)?

        private enum Axis { case horizontal, vertical }

        /// travel before the gesture commits to an axis (so a near-vertical
        /// scroll never nudges the panels)
        private let deadzone: CGFloat = 6
        private var monitor: Any?
        private var accumX: CGFloat = 0
        private var accumY: CGFloat = 0
        private var axis: Axis?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil, monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) {
                    [weak self] event in
                    self?.handle(event) == true ? nil : event
                }
            } else if window == nil, let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }

        /// whether the event was the swipe's alone; began and ended always pass
        /// through so the scroll view below sees every gesture close
        private func handle(_ event: NSEvent) -> Bool {
            guard let window, event.window === window,
                event.hasPreciseScrollingDeltas  // trackpad / Magic Mouse only
            else { return false }
            // only when the pointer is over the sidebar
            guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return false }

            switch event.phase {
            case .began:
                accumX = 0
                accumY = 0
                axis = nil
            case .changed:
                accumX += event.scrollingDeltaX
                accumY += event.scrollingDeltaY
                // lock the axis the first time motion clears the deadzone
                if axis == nil, max(abs(accumX), abs(accumY)) > deadzone {
                    axis = abs(accumX) > abs(accumY) ? .horizontal : .vertical
                }
                if axis == .horizontal {
                    onChanged?(accumX)
                    return true
                }
            case .ended, .cancelled:
                if axis == .horizontal {
                    onEnded?(accumX)
                }
                accumX = 0
                accumY = 0
                axis = nil
            default:
                break
            }
            return false
        }
    }
}
