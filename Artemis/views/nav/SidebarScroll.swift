// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import AppKit
import SwiftUI

/// the live tab list's scrolling, read from and driven through the NSScrollView behind it, so the
/// gutter scroller and a drag's auto-scroll never re-run the sidebar's body
@Observable
final class SidebarScroll {
    struct Metrics: Equatable {
        /// points scrolled from the top
        var offset: CGFloat = 0
        var content: CGFloat = 0
        var visible: CGFloat = 0
        var maxOffset: CGFloat { max(0, content - visible) }
    }

    private(set) var metrics = Metrics()
    /// scrolled within the last moment, so the thumb shows
    private(set) var isActive = false
    /// the list's frame in `SidebarDragState.contentSpace`
    var track: CGRect = .zero

    @ObservationIgnored private weak var scrollView: NSScrollView?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var fade: Task<Void, Never>?
    @ObservationIgnored private var speed: CGFloat = 0
    @ObservationIgnored private var ticker: Task<Void, Never>?

    /// how far in from each end of the list a held drag scrolls it
    static let edgeZone: CGFloat = 56
    /// points per second with the pointer at the edge
    static let topSpeed: CGFloat = 720

    func attach(_ view: NSScrollView) {
        guard view !== scrollView else { return }
        observers.forEach(NotificationCenter.default.removeObserver)
        scrollView = view
        view.contentView.postsBoundsChangedNotifications = true
        view.documentView?.postsFrameChangedNotifications = true
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSView.boundsDidChangeNotification, object: view.contentView, queue: .main) {
                [weak self] _ in MainActor.assumeIsolated { self?.measure(scrolled: true) }
            },
            center.addObserver(forName: NSView.frameDidChangeNotification, object: view.documentView, queue: .main) {
                [weak self] _ in MainActor.assumeIsolated { self?.measure(scrolled: false) }
            },
        ]
        measure(scrolled: false)
    }

    func detach(_ view: NSScrollView) {
        guard view === scrollView else { return }
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        scrollView = nil
        follow(nil)
        metrics = Metrics()
    }

    private func measure(scrolled: Bool) {
        guard let view = scrollView, let document = view.documentView else { return }
        let clip = view.contentView.bounds
        let content = document.frame.height
        let measured = Metrics(
            offset: document.isFlipped ? clip.minY : content - clip.maxY, content: content, visible: clip.height)
        if measured != metrics { metrics = measured }
        guard scrolled else { return }
        if !isActive { isActive = true }
        fade?.cancel()
        fade = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            self?.isActive = false
        }
    }

    func scroll(toOffset target: CGFloat) {
        guard let view = scrollView, let document = view.documentView else { return }
        let offset = min(max(0, target), metrics.maxOffset)
        let clip = view.contentView
        let y = document.isFlipped ? offset : metrics.content - metrics.visible - offset
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
        view.reflectScrolledClipView(clip)
    }

    /// a drag held at `point` (nil once it ends) scrolls the list at `speed(at:in:)`; `tick` runs
    /// after each step, so whatever reads the rows' frames can follow them
    func follow(_ point: CGPoint?, tick: @escaping () -> Void = {}) {
        speed = point.map { Self.speed(at: $0, in: track) } ?? 0
        guard speed != 0 else {
            ticker?.cancel()
            ticker = nil
            return
        }
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            var last = ContinuousClock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(8))
                guard let self, !Task.isCancelled else { return }
                let now = ContinuousClock.now
                scroll(toOffset: metrics.offset + speed * CGFloat((now - last) / .seconds(1)))
                last = now
                tick()
            }
        }
    }

    /// zero where an edge zone begins, rising with the square of the depth to `topSpeed` at the
    /// edge and up to a zone past it; negative scrolls up
    static func speed(at point: CGPoint, in rect: CGRect) -> CGFloat {
        guard rect.height > 2 * edgeZone, point.x >= rect.minX, point.x <= rect.maxX + Sidebar.contentInset,
            point.y >= rect.minY - edgeZone, point.y <= rect.maxY + edgeZone
        else { return 0 }
        let up = (rect.minY + edgeZone - point.y) / edgeZone
        let down = (point.y - rect.maxY + edgeZone) / edgeZone
        if up > 0 { return -topSpeed * pow(min(up, 1), 2) }
        if down > 0 { return topSpeed * pow(min(down, 1), 2) }
        return 0
    }
}

/// hands over the NSScrollView behind the SwiftUI ScrollView it sits in, and takes it back as it leaves
struct ScrollViewProbe: NSViewRepresentable {
    let scroll: SidebarScroll

    func makeNSView(context: Context) -> Probe { Probe(scroll: scroll) }
    func updateNSView(_ view: Probe, context: Context) {}

    final class Probe: NSView {
        private let scroll: SidebarScroll
        private weak var attached: NSScrollView?

        init(scroll: SidebarScroll) {
            self.scroll = scroll
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil, let view = enclosingScrollView {
                attached = view
                scroll.attach(view)
            } else if let attached {
                scroll.detach(attached)
            }
        }
    }
}

/// the list's scroller, a thin thumb centred in the gutter between the tab column and the
/// sidebar's edge; it shows while the list scrolls or the pointer is on it, and drags
struct GutterScroller: View {
    let scroll: SidebarScroll
    let gutter: CGFloat
    /// the gutter lies left of the track, as when the sidebar sits on the right
    var onLeft = false
    @Environment(\.chromeInk) private var ink
    @State private var hovering = false
    @State private var grabbed: CGFloat?

    var body: some View {
        let m = scroll.metrics
        let track = scroll.track
        let thumb = m.content > 0 ? max(28, track.height * m.visible / m.content) : 0
        let travel = track.height - thumb
        if m.maxOffset > 1, travel > 0 {
            let wide = hovering || grabbed != nil
            Capsule()
                .fill(ink.opacity(wide ? 0.42 : 0.26))
                .frame(width: wide ? 5 : 3, height: thumb)
                .opacity(scroll.isActive || wide ? 1 : 0)
                .frame(width: gutter, height: thumb)
                // outside the opacity, so the hidden thumb still takes the pointer
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .global)
                        .onChanged { value in
                            let start = grabbed ?? m.offset
                            if grabbed == nil { grabbed = start }
                            scroll.scroll(toOffset: start + value.translation.height * m.maxOffset / travel)
                        }
                        .onEnded { _ in grabbed = nil }
                )
                .position(x: onLeft ? track.minX - gutter / 2 : track.maxX + gutter / 2, y: track.minY + travel * min(1, m.offset / m.maxOffset) + thumb / 2)
                .animation(Motion.hover, value: wide)
                .animation(Motion.fade, value: scroll.isActive)
                .accessibilityHidden(true)
        }
    }
}
