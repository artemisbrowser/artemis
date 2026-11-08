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
/// opaque floor; glass layers are clear over one shared `GlassSubstrate`
struct SpaceBackdrop: View, Animatable {
    var spaces: [Space]
    var position: Double
    /// glass frosts the page beneath (the floating sidebar) instead of the desktop behind the window
    var overPage = false
    /// the pinned sidebar's leading strip, frosted at the sidebar's own level; 0 while it floats
    var sidebarWidth: CGFloat = 0

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
            GlassSubstrate(
                background: frost(\.backgroundFrost, floorSpace, nextSpace, frac),
                sidebar: frost(\.sidebarFrost, floorSpace, nextSpace, frac),
                sidebarWidth: sidebarWidth, overPage: overPage, edge: glassInvolved)
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

    /// the frost the shared substrate shows. both ends glass → crossfade frost to
    /// frost as the carousel slides; otherwise hold the single glass space's frost
    /// while the colour layer fades over it
    private func frost(
        _ key: KeyPath<SpaceAppearance, Double>, _ floorSpace: Space?, _ nextSpace: Space?, _ frac: Double
    ) -> Double {
        let floor = floorSpace?.appearance[keyPath: key] ?? 0.6
        let next = nextSpace?.appearance[keyPath: key] ?? 0.6
        let floorGlass = floorSpace?.appearance.fill == .glass
        if floorGlass && nextSpace?.appearance.fill == .glass { return floor + (next - floor) * frac }
        return floorGlass ? floor : next
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
/// stack two frosts. as the window backdrop it frosts the desktop behind the window, the
/// pinned sidebar's strip at its own level; over the page it frosts the page beneath
private struct GlassSubstrate: View {
    var background: Double
    var sidebar: Double
    var sidebarWidth: CGFloat
    var overPage: Bool
    var edge: Bool
    /// Reduce Transparency flattens any vibrancy to a system grey too light for white ink
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            if reduceTransparency {
                LinearGradient(
                    colors: [Color(white: 0.25), Color(white: 0.13)],
                    startPoint: .topLeading, endPoint: .bottomTrailing)
                NoiseTexture()
                    .opacity(0.1)
                    .blendMode(.overlay)
                Color.black.opacity(0.3)
            } else if overPage {
                Frost(amount: sidebar, blending: .withinWindow)
            } else {
                // the pinned sidebar is glass on glass: its frost and rim stack on the background's,
                // running a corner's width under the card so its rounded sidebar side shows no seam
                let tucked = sidebarWidth > 0 ? sidebarWidth + WindowChrome.outerWindowRadius : 0
                ZStack(alignment: .leading) {
                    Frost(amount: background, blending: .behindWindow)
                    Frost(amount: sidebar, blending: .behindWindow)
                        .frame(width: tucked)
                    if edge && sidebarWidth > 0 {
                        GlassLens(identifier: GlassLens.sidebar)
                            .frame(width: tucked)
                    }
                }
                if edge {
                    GlassLens(identifier: GlassLens.window)
                }
            }
        }
        .ignoresSafeArea()
    }
}

/// one frosted region over what lies behind it, the same curve for the sidebar and the
/// background: 0 paints nothing, 1 is the full blur, clear-glass sheen and scrim
struct Frost: NSViewRepresentable {
    static let fullBlur = 0.8
    static let fullScrim = 0.3
    var amount: Double
    var blending: NSVisualEffectView.BlendingMode

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSViewType, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    func makeNSView(context: Context) -> FrostView { FrostView() }

    func updateNSView(_ view: FrostView, context: Context) {
        view.blur.blendingMode = blending
        // the blur comes in ahead of the scrim, so a low frost already reads as frost
        view.blur.alphaValue = Self.fullBlur * amount.squareRoot()
        view.sheen.alphaValue = amount
        view.scrim.layer?.backgroundColor = NSColor.black.withAlphaComponent(Self.fullScrim * amount).cgColor
    }

    final class FrostView: NSView {
        let blur = NSVisualEffectView()
        /// overhangs the region on every side, so its edge lens is clipped away
        let sheen = NSGlassEffectView()
        let scrim = NSView()

        override init(frame: NSRect) {
            super.init(frame: frame)
            clipsToBounds = true
            blur.material = .underWindowBackground
            blur.state = .active
            blur.appearance = NSAppearance(named: .darkAqua)
            sheen.style = .clear
            scrim.wantsLayer = true
            for view in [blur, sheen, scrim] {
                view.frame = view === sheen ? bounds.insetBy(dx: -Self.sheenOverhang, dy: -Self.sheenOverhang) : bounds
                view.autoresizingMask = [.width, .height]
                addSubview(view)
            }
        }

        private static let sheenOverhang: CGFloat = 40

        required init?(coder: NSCoder) { fatalError() }
    }
}

/// a rim of the same clear glass the floating sidebar's edge uses, at the window's radius;
/// it lenses what lies behind the window, frosted or not
struct GlassLens: NSViewRepresentable {
    static let window = NSUserInterfaceItemIdentifier("windowGlassEdge")
    static let sidebar = NSUserInterfaceItemIdentifier("sidebarGlassEdge")
    let identifier: NSUserInterfaceItemIdentifier

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSViewType, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    func makeNSView(context: Context) -> NSGlassEffectView {
        let glass = NSGlassEffectView()
        glass.identifier = identifier
        glass.style = .clear
        glass.cornerRadius = WindowChrome.outerWindowRadius
        return glass
    }

    func updateNSView(_ nsView: NSGlassEffectView, context: Context) {}
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
        view.state = .active
        updateNSView(view, context: context)
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

    /// handed the window on entering it and on every update after, so it must be idempotent
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
