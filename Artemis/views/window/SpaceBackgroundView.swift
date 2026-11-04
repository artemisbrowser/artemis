// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import AppKit
import SwiftUI

/// one space's backdrop. an appearance change holds the outgoing fill opaque beneath
/// and fades only the incoming one in: the window is non-opaque, so a plain
/// cross-fade would show the desktop through
private struct SpaceBackgroundView: View {
    var appearance: SpaceAppearance

    /// the outgoing backdrop, dropped once the incoming one fully covers it
    @State private var previous: SpaceAppearance?
    @State private var fade: Double = 1
    @State private var fadeToken = 0

    var body: some View {
        let _ = Bench.tick("SpaceBackgroundView")
        ZStack {
            if let previous {
                FillLayer(appearance: previous)
            }
            FillLayer(appearance: appearance)
                .opacity(previous == nil ? 1 : fade)
        }
        .ignoresSafeArea()
        // fill/colour/preset switches fade; mesh drags keep the same signature
        // and apply instantly
        .onChange(of: appearance) { old, new in
            guard old.transitionSignature != new.transitionSignature else { return }
            fadeToken += 1
            let token = fadeToken
            previous = old
            fade = 0
            withAnimation(.easeInOut(duration: 0.35)) {
                fade = 1
            } completion: {
                // drop the floor only if no newer fade has superseded this one
                if token == fadeToken { previous = nil }
            }
        }
    }
}

/// the window backdrop, cross-faded across spaces by the carousel position: one
/// stable-identity layer per space, faded by `.opacity`. colour layers keep an
/// opaque floor; glass layers are scrims over one shared `GlassSubstrate`
struct SpaceBackdrop: View, Animatable {
    var spaces: [Space]
    var position: Double
    /// glass frosts the page beneath (the floating sidebar) instead of the desktop behind the window
    var overPage = false

    // `withAnimation` interpolates only animatable data: exposing `position`
    // re-runs `body` per frame of a click switch instead of jumping to the end
    var animatableData: Double {
        get { position }
        set { position = newValue }
    }

    var body: some View {
        let _ = Bench.tick("SpaceBackdrop")
        // clamp to the real index range so an overshoot past the first/last space
        // can't reveal the opaque floor (a dark flash) at the ends
        let p = min(max(position, 0), Double(max(spaces.count - 1, 0)))
        let floor = Int(p.rounded(.down))
        let frac = p - p.rounded(.down)
        let floorSpace = spaces.indices.contains(floor) ? spaces[floor] : nil
        let nextSpace = spaces.indices.contains(floor + 1) ? spaces[floor + 1] : nil
        let floorGlass = floorSpace?.appearance.fill == .glass
        let nextGlass = nextSpace?.appearance.fill == .glass
        // only the floor and the incoming layer are ever visible at once, so a
        // glass surface is needed exactly when one of those two is glass
        let glassInvolved = floorGlass || nextGlass

        ZStack {
            // opaque floor for the empty/degenerate case — but never while glass
            // is in view: over the page, the frost has to see the page beneath
            if !glassInvolved {
                Color.black
            }

            // one shared frost, mounted across all spaces (hidden, opacity 0, over
            // colour) so two glass spaces crossfade over a single surface
            GlassSubstrate(blur: substrateBlur(
                floorSpace: floorSpace, nextSpace: nextSpace,
                floorGlass: floorGlass, nextGlass: nextGlass, frac: frac), overPage: overPage)
                .opacity(glassInvolved ? 1 : 0)

            ForEach(Array(spaces.enumerated()), id: \.element.id) { index, space in
                // SpaceBackgroundView (not a bare FillLayer) so a space's own
                // colour edits still fade in place; the space *switch* is the
                // outer opacity here
                SpaceBackgroundView(appearance: space.appearance)
                    .opacity(layerOpacity(
                        index: index, floor: floor, frac: frac, glassInvolved: glassInvolved))
            }
        }
        .ignoresSafeArea()
    }

    /// the frost level the shared substrate shows. both ends glass → crossfade
    /// blur-to-blur as the carousel slides; otherwise hold the single glass
    /// space's blur while the colour layer fades over it
    private func substrateBlur(
        floorSpace: Space?, nextSpace: Space?,
        floorGlass: Bool, nextGlass: Bool, frac: Double
    ) -> Double {
        let floorBlur = floorSpace?.appearance.glassBlur ?? 0.6
        let nextBlur = nextSpace?.appearance.glassBlur ?? 0.6
        if floorGlass && nextGlass { return floorBlur + (nextBlur - floorBlur) * frac }
        return floorGlass ? floorBlur : nextBlur
    }

    private func layerOpacity(index: Int, floor: Int, frac: Double, glassInvolved: Bool) -> Double {
        if glassInvolved {
            // the substrate is the floor; the two participating layers plain-
            // crossfade over it, everything else is clear
            if index == floor { return 1 - frac }
            if index == floor + 1 { return frac }
            return 0
        }
        if index <= floor { return 1 }      // floor + everything beneath it: opaque
        if index == floor + 1 { return frac }  // the incoming space, fading in
        return 0
    }
}

/// the single liquid-glass surface, shared across all spaces so two glass spaces never
/// stack two frosts. as the window backdrop it is frosted glass of its own and never
/// shows the desktop; over the page (the floating sidebar) it frosts the page beneath
private struct GlassSubstrate: View {
    /// 0 = light frost … 1 = heavy; crossfaded between two glass spaces by the carousel
    var blur: Double
    var overPage: Bool
    /// Reduce Transparency flattens the page frost to a system grey too light for white ink
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            if overPage && !reduceTransparency {
                VisualEffectView(material: .underWindowBackground, blending: .withinWindow)
                    .opacity(0.5 + blur * 0.5)
            } else {
                LinearGradient(
                    colors: [Color(white: 0.25), Color(white: 0.13)],
                    startPoint: .topLeading, endPoint: .bottomTrailing)
                NoiseTexture()
                    .opacity(0.05 + blur * 0.07)
                    .blendMode(.overlay)
            }
            // the sheen and edge refraction that make either surface read as glass
            Rectangle()
                .fill(.clear)
                .glassEffect(overPage ? .clear : .regular, in: Rectangle())
        }
        .ignoresSafeArea()
    }
}

/// AppKit vibrancy (blurs content behind the window) for the glass fill
struct VisualEffectView: NSViewRepresentable {
    /// fills what it's offered, sparing SwiftUI an Auto Layout measurement of its subtree
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSViewType, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    var material: NSVisualEffectView.Material
    var blending: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blending
    }
}

/// makes the window non-opaque so the glass fill can show the desktop through.
/// opaque fills (solid/gradient) cover it, so this is safe to leave on always
struct WindowTransparency: NSViewRepresentable {
    /// fills what it's offered, sparing SwiftUI an Auto Layout measurement of its subtree
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSViewType, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    /// handed back once the view is in a window, so SwiftUI can ask the window
    /// things AppKit only knows — e.g. its real corner radius, which the card's
    /// concentric rounding is derived from
    var onWindow: ((NSWindow) -> Void)? = nil

    func makeNSView(context: Context) -> Host {
        let view = Host()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ nsView: Host, context: Context) {
        nsView.onWindow = onWindow
        guard let window = nsView.window else { return }
        onWindow?(window)
    }

    final class Host: NSView {
        var onWindow: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.isOpaque = false
            window.backgroundColor = .clear
            onWindow?(window)
        }
    }
}
