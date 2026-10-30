import AppKit
import SwiftUI

/// paints a space's backdrop: solid color, linear gradient, or live glass
/// (desktop vibrancy), with an optional film-grain overlay on top.
///
/// switching spaces cross-fades the colour. the catch: the window is
/// non-opaque (for glass), so a plain cross-fade — both layers part-way
/// translucent at once — briefly shows the desktop through. instead we hold
/// the outgoing backdrop fully opaque beneath and fade only the incoming one
/// in over it, so there's always an opaque floor and the fade reads as one
/// colour melting into the next
struct SpaceBackgroundView: View {
    var appearance: SpaceAppearance

    // the outgoing backdrop, kept opaque under the incoming one for the length
    // of a switch fade, then dropped once it's fully covered
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
        // fade fill/colour/preset switches, but never mesh drags — they keep
        // the same signature, so they apply instantly instead of firing a
        // 0.35s fade every frame and tanking the framerate
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

/// the window backdrop, cross-faded across spaces by the carousel position so
/// the colour shifts *as* the spaces slide rather than after they land.
///
/// every space is stacked as its own layer with a stable identity, and the
/// transition is carried purely by each layer's `.opacity`. that's deliberate:
/// `.opacity` is an animatable modifier, so a `withAnimation` change to these
/// stable-identity layers (the release-snap, a click-switch) animates the fade
/// frame-by-frame on its own — we don't depend on `body` re-running per frame
/// (it isn't, during an animation it runs once at the final position). a raw
/// finger-drag isn't animated, so `body` re-runs live per frame and the fade
/// tracks the drag 1:1.
///
/// the window is non-opaque (for glass). a colour layer is opaque, so colour↔
/// colour keeps an opaque floor at all times: every layer at or below the floor
/// index stays opaque and the next fades in by the fraction. but a glass layer
/// isn't a colour — it's a live frost over the desktop — so it can't be stacked
/// and alpha-crossfaded: two of them doubled the blur + dimming and popped on
/// settle. instead one shared `GlassSubstrate` (the actual frost) is mounted
/// beneath, only while a glass space is in view, and each space's layer carries
/// just its dimming scrim. with glass in view the two participating layers
/// plain-crossfade over that single substrate; a colour layer stays opaque and
/// hides the substrate until it fades, a glass layer is a thin scrim that lets
/// it through
struct SpaceBackdrop: View, Animatable {
    var spaces: [Space]
    var position: Double
    /// glass frosts the page beneath (the floating sidebar) instead of the desktop behind the window
    var overPage = false

    // a raw finger-drag changes `position` outside any animation, so `body`
    // re-runs live per frame and the fade tracks the drag 1:1. a click / keyboard
    // switch sets it inside `withAnimation`, where only animatable data is
    // interpolated — so we expose `position` as `animatableData`. that makes
    // SwiftUI step it frame-by-frame (re-running `body` each step) instead of
    // jumping to the final value, so the colour glides in lockstep with the
    // sidebar filmstrip rather than snapping while the panels slide
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

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.isOpaque = false
            window.backgroundColor = .clear
            onWindow?(window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let window = nsView.window else { return }
        onWindow?(window)
    }
}
