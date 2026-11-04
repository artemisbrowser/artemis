// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import AppKit
import SwiftUI

/// The window's sidebar and web card as AppKit views, each in its own hosting
/// view and placed by frame. Sliding the sidebar moves its view without laying
/// it out, and only the card's host resizes, so no animation frame re-lays out
/// the whole window.
struct BrowserShell<Sidebar: View, Content: View>: NSViewRepresentable {
    /// fills what it's offered, sparing SwiftUI an Auto Layout measurement of its subtree
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSViewType, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    struct Placement: Equatable {
        /// the sidebar host's frame along x, in window points
        var sidebarX: CGFloat
        var sidebarWidth: CGFloat
        /// hover-only strips at the sidebar host's edges; clicks pass through them
        var sidebarPassLeading: CGFloat
        var sidebarPassTrailing: CGFloat
        /// where the card's host starts; it runs to the window's trailing edge
        var contentX: CGFloat
    }

    /// The state whose changes pick the motion, mirroring the old per-value
    /// SwiftUI animations: pinning, peeking, and the Library's rail.
    struct Cause: Equatable {
        var collapsed: Bool
        var overlayVisible: Bool
        var libraryOpen: Bool
    }

    let sidebar: Sidebar
    let content: Content
    let placement: Placement
    let cause: Cause
    let revealDuration: Double

    func makeCoordinator() -> Coordinator { Coordinator(cause: cause) }

    func makeNSView(context: Context) -> ShellView<Sidebar, Content> {
        let view = ShellView(sidebar: sidebar, content: content)
        view.move(to: placement, spring: nil)
        return view
    }

    func updateNSView(_ view: ShellView<Sidebar, Content>, context: Context) {
        view.sidebarHost.rootView = sidebar
        view.contentHost.rootView = content
        let last = context.coordinator.cause
        context.coordinator.cause = cause
        var spring: Spring?
        if cause.collapsed != last.collapsed {
            // pinning from the peek swaps layers in place, with no re-slide
            spring = cause.overlayVisible ? nil : Motion.sidebarSpring
        } else if cause.overlayVisible != last.overlayVisible {
            spring = cause.collapsed ? Motion.sidebarRevealSpring(duration: revealDuration) : nil
        } else if cause.libraryOpen != last.libraryOpen {
            spring = Motion.panelSpring
        }
        if context.transaction.disablesAnimations { spring = nil }
        view.move(to: placement, spring: spring)
    }

    final class Coordinator {
        var cause: Cause
        init(cause: Cause) { self.cause = cause }
    }
}

final class ShellView<Sidebar: View, Content: View>: NSView {
    let sidebarHost: PassthroughHostingView<Sidebar>
    let contentHost: NSHostingView<Content>

    private var sidebarX = Glide()
    private var sidebarWidth = Glide()
    private var contentX = Glide()
    private var link: CADisplayLink?

    init(sidebar: Sidebar, content: Content) {
        sidebarHost = PassthroughHostingView(rootView: sidebar)
        contentHost = NSHostingView(rootView: content)
        super.init(frame: .zero)
        // frames are set here, so the hosts publish no sizing constraints, and
        // the window's hidden titlebar is no safe area to them
        contentHost.sizingOptions = []
        contentHost.safeAreaRegions = []
        sidebarHost.sizingOptions = []
        sidebarHost.safeAreaRegions = []
        addSubview(contentHost)
        addSubview(sidebarHost)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func move(to placement: BrowserShell<Sidebar, Content>.Placement, spring: Spring?) {
        let now = CACurrentMediaTime()
        // a sidebar leaving the window drops the keyboard its own fields hold,
        // and nothing else's. deferred: resigning a SwiftUI field writes its state
        if sidebarX.target + sidebarWidth.target > 0, placement.sidebarX + placement.sidebarWidth <= 0 {
            DispatchQueue.main.async { [weak self] in
                guard let self, let window,
                    (window.firstResponder as? NSView)?.isDescendant(of: sidebarHost) == true
                else { return }
                window.makeFirstResponder(nil)
            }
        }
        sidebarX.set(placement.sidebarX, spring: spring, at: now)
        // the rig animates its own width inside the host; a host that springs
        // its width would re-lay out the whole sidebar every frame
        sidebarWidth.set(placement.sidebarWidth, spring: nil, at: now)
        contentX.set(placement.contentX, spring: spring, at: now)
        sidebarHost.passLeading = placement.sidebarPassLeading
        sidebarHost.passTrailing = placement.sidebarPassTrailing
        place(at: now)
        if !isSettled(at: now), link == nil {
            let link = displayLink(target: self, selector: #selector(step))
            link.add(to: .main, forMode: .common)
            self.link = link
        }
    }

    override func layout() {
        super.layout()
        place(at: CACurrentMediaTime())
    }

    // a display link retains its target; one left running would keep a
    // closed window's view tree alive
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window == nil, let link else { return }
        link.invalidate()
        self.link = nil
    }

    @objc private func step(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        place(at: now)
        if isSettled(at: now) {
            link.invalidate()
            self.link = nil
        }
    }

    private func isSettled(at now: CFTimeInterval) -> Bool {
        sidebarX.isSettled(at: now) && sidebarWidth.isSettled(at: now) && contentX.isSettled(at: now)
    }

    /// frames land on the pixel grid: an off-grid host renders the page soft
    private func place(at now: CFTimeInterval) {
        let height = bounds.height
        let sidebar = backingAlignedRect(
            CGRect(x: sidebarX.value(at: now), y: 0, width: sidebarWidth.value(at: now), height: height),
            options: .alignAllEdgesNearest)
        let x = contentX.value(at: now)
        let content = backingAlignedRect(
            CGRect(x: x, y: 0, width: max(bounds.width - x, 0), height: height),
            options: .alignAllEdgesNearest)
        if sidebarHost.frame != sidebar { sidebarHost.frame = sidebar }
        if contentHost.frame != content { contentHost.frame = content }
    }
}

/// A hosting view whose edge strips track hover but let clicks reach what's below.
final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    var passLeading: CGFloat = 0
    var passTrailing: CGFloat = 0

    override func hitTest(_ point: NSPoint) -> NSView? {
        let x = convert(point, from: superview).x
        guard x >= passLeading, x <= bounds.width - passTrailing else { return nil }
        return super.hitTest(point)
    }
}

/// One value moving toward its target on a spring, sampled by time. A retarget
/// mid-flight carries the current velocity into the new spring.
private struct Glide {
    private(set) var target: CGFloat = 0
    private var from: CGFloat = 0
    private var start: CFTimeInterval = 0
    private var spring: Spring?
    private var initialVelocity: CGFloat = 0

    mutating func set(_ value: CGFloat, spring: Spring?, at now: CFTimeInterval) {
        guard value != target else { return }
        let velocity = spring == nil ? 0 : self.velocity(at: now)
        from = self.value(at: now)
        target = value
        start = now
        self.spring = spring
        initialVelocity = velocity
    }

    func value(at now: CFTimeInterval) -> CGFloat {
        guard let spring, !isSettled(at: now) else { return target }
        return from
            + spring.value(target: target - from, initialVelocity: initialVelocity, time: now - start)
    }

    private func velocity(at now: CFTimeInterval) -> CGFloat {
        guard let spring, !isSettled(at: now) else { return 0 }
        return spring.velocity(target: target - from, initialVelocity: initialVelocity, time: now - start)
    }

    func isSettled(at now: CFTimeInterval) -> Bool {
        guard let spring else { return true }
        return now - start >= spring.settlingDuration
    }
}
