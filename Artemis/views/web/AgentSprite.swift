// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import SwiftUI
import WebKit

/// the agent's mark over a page, beside where it is about to act. A native view in the web view, so
/// nothing of it is in the page to read or move, and it never takes a click
final class AgentSprite: NSView {
    private let state = AgentSpriteState()
    private let face: NSHostingView<AgentSpriteFace>
    private var leaving: Task<Void, Never>?

    /// the mark's square, in points; its corner sits this far past the point it marks
    static let size: CGFloat = 26
    private static let offset: CGFloat = 6

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private init(over webView: WKWebView) {
        face = NSHostingView(rootView: AgentSpriteFace(state: state))
        super.init(frame: webView.bounds)
        autoresizingMask = [.width, .height]
        face.frame = NSRect(x: 0, y: 0, width: Self.size, height: Self.size)
        addSubview(face)
        webView.addSubview(self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used from a nib") }

    static func on(_ webView: WKWebView) -> AgentSprite? {
        webView.subviews.lazy.compactMap { $0 as? AgentSprite }.first
    }

    /// puts the mark beside `point`, in the page's viewport in CSS pixels. It travels there from where
    /// it was, or appears there when it wasn't up or Reduce Motion is on
    static func aim(over webView: WKWebView, at point: CGPoint) {
        let sprite = on(webView) ?? AgentSprite(over: webView)
        sprite.leaving?.cancel()
        let zoom = webView.pageZoom
        let origin = CGPoint(x: point.x * zoom + offset, y: point.y * zoom + offset)
        if sprite.state.isShown, !Motion.reduceMotion {
            NSAnimationContext.animate(Motion.sprite) { sprite.face.animator().setFrameOrigin(origin) }
        } else {
            sprite.face.setFrameOrigin(origin)
        }
        withAnimation(Motion.pop) {
            sprite.state.isShown = true
            sprite.state.isPressed = false
        }
    }

    /// the agent acted where the mark is: it presses, then goes once the agent has moved on
    static func acted(on webView: WKWebView) {
        guard let sprite = on(webView) else { return }
        withAnimation(Motion.pop) { sprite.state.isPressed = true }
        sprite.leaving = Task { [weak sprite] in
            try? await Task.sleep(for: .milliseconds(150))
            withAnimation(Motion.pop) { sprite?.state.isPressed = false }
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            withAnimation(Motion.fade) { sprite?.state.isShown = false }
            try? await Task.sleep(for: .seconds(0.3))
            if !Task.isCancelled { sprite?.removeFromSuperview() }
        }
    }
}

@Observable
private final class AgentSpriteState {
    var isShown = false
    var isPressed = false
}

private struct AgentSpriteFace: View {
    let state: AgentSpriteState

    var body: some View {
        ZStack {
            if state.isShown {
                AgentMarkFace()
                    .scaleEffect(state.isPressed ? 0.8 : 1)
                    .transition(Motion.grow(from: 0.4))
            }
        }
        .frame(width: AgentSprite.size, height: AgentSprite.size)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// every agent's mark on its white disc, at any size
struct AgentMarkFace: View {
    var body: some View {
        GeometryReader { box in
            let side = min(box.size.width, box.size.height)
            Circle()
                .fill(.white)
                .overlay {
                    Image(systemName: "sparkle").font(.system(size: side * 0.5)).foregroundStyle(.black.opacity(0.6))
                }
                .shadow(color: .black.opacity(0.3), radius: side / 9, y: side / 26)
        }
        .accessibilityHidden(true)
    }
}

/// tabs an agent has called on within the last `linger` seconds, for their sidebar rows
@Observable
final class AgentDriving {
    static let shared = AgentDriving()
    static let linger = 3.0
    private(set) var driven: Set<BrowserTab.ID> = []
    @ObservationIgnored private var clearing: [BrowserTab.ID: Task<Void, Never>] = [:]

    func drove(_ id: BrowserTab.ID) {
        if !driven.contains(id) { driven.insert(id) }
        clearing[id]?.cancel()
        clearing[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.linger))
            guard !Task.isCancelled else { return }
            self?.driven.remove(id)
            self?.clearing[id] = nil
        }
    }
}
