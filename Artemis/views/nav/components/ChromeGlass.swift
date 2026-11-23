// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import AppKit
import SwiftUI

/// the face every sidebar icon button wears: hit box, glyph tint and highlight.
/// a `standalone` button is its own glass circle; one inside a pill or a row
/// keeps a flat round highlight, so glass never stacks on glass
struct ChromeButtonFace: ViewModifier {
    @Environment(\.chromeInk) private var ink
    var isHovering: Bool
    var enabled = true
    var standalone = false
    var boxSize: CGFloat = 28
    /// sits in the url bar: highlights with `UrlBarHighlight`
    var inUrlBar = false

    func body(content: Content) -> some View {
        let glyph = ink.opacity(enabled ? (isHovering ? 1 : 0.8) : 0.3)
        let fill = ink.opacity(isHovering && enabled ? 0.13 : 0)
        if standalone {
            content
                .foregroundStyle(glyph)
                .frame(width: SidebarMetrics.glassSide, height: SidebarMetrics.glassSide)
                .background(Circle().fill(fill))
                .chromeGlass(in: .circle, interactive: enabled)
                .contentShape(.circle)
                .animation(Motion.hover, value: isHovering)
        } else {
            content
                .foregroundStyle(glyph)
                .frame(width: boxSize, height: boxSize)
                .background {
                    if inUrlBar { UrlBarHighlight(fill: fill) } else { Capsule().fill(fill) }
                }
                .contentShape(.capsule)
                .animation(Motion.hover, value: isHovering)
        }
    }
}

/// a url-bar button's highlight: a circle as tall as the bar, centred on the
/// button without widening it
struct UrlBarHighlight: View {
    private let metrics = SidebarMetrics.standard
    let fill: Color

    var body: some View {
        Circle().fill(fill).frame(width: metrics.rowHeight, height: metrics.rowHeight)
    }
}

/// a sidebar row's highlight; the selected row is its own lit pane
struct RowHighlight: View {
    @Environment(\.chromeInk) private var ink
    let opacity: Double
    var isSelected = false
    var radius: CGFloat = 10
    static let glassBleed: CGFloat = 4
    /// from selection until the pane has faded out
    @State private var paneMounted = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if PerfFlags.animatesLitPaneInLayer {
            shape.fill(ink.opacity(isSelected ? 0 : opacity))
                .background {
                    if isSelected || paneMounted {
                        LitPane(lit: isSelected, ink: ink, radius: radius) { paneMounted = false }
                            .transition(.identity)
                    }
                }
                .onChange(of: isSelected, initial: true) { _, selected in
                    if selected { paneMounted = true }
                }
        } else if isSelected {
            Color.clear.chromeGlass(in: shape, lit: true)
        } else {
            shape.fill(ink.opacity(opacity))
        }
    }
}

/// `chromeGlass(lit: true)` as an AppKit view whose fade runs in Core Animation, on the
/// `Motion.hoverSpring` when the change was animated; `faded` fires once a fade-out ends
private struct LitPane: NSViewRepresentable {
    let lit: Bool
    let ink: Color
    let radius: CGFloat
    let faded: () -> Void

    func makeNSView(context: Context) -> NSGlassEffectView {
        let view = NSGlassEffectView()
        view.wantsLayer = true
        view.alphaValue = 0
        return view
    }

    func updateNSView(_ view: NSGlassEffectView, context: Context) {
        view.appearance = NSAppearance(named: ChromeGlassScheme.scheme(under: ink) == .light ? .aqua : .darkAqua)
        view.tintColor = NSColor(ink.opacity(0.12))
        view.cornerRadius = radius
        let target: CGFloat = lit ? 1 : 0
        guard view.alphaValue != target, let layer = view.layer else { return }
        let from = layer.presentation()?.opacity ?? layer.opacity
        view.alphaValue = target
        guard context.transaction.animation != nil, !context.transaction.disablesAnimations else {
            // never mid-update: `faded` writes view state
            if !lit { DispatchQueue.main.async(execute: faded) }
            return
        }
        let spring = Motion.hoverSpring
        let fade = CASpringAnimation(perceptualDuration: spring.duration, bounce: spring.bounce)
        fade.keyPath = "opacity"
        fade.fromValue = from
        fade.toValue = Float(target)
        CATransaction.begin()
        // a fade replaced by a re-selection still completes; only a pane left dark is done
        CATransaction.setCompletionBlock { [weak view] in if view?.alphaValue == 0 { faded() } }
        layer.add(fade, forKey: "opacity")
        CATransaction.commit()
    }
}

extension View {
    /// `clipped()` with room at the sides: a selected row's glass draws its edge just outside its
    /// shape, and the rows span the full width. must stay under the gutters between sliding panels
    func clippedPastSides(_ bleed: CGFloat = RowHighlight.glassBleed) -> some View {
        padding(.horizontal, bleed).clipped().padding(.horizontal, -bleed)
    }

    /// glass in the variant that matches the backdrop under the sidebar, not the
    /// system appearance: dark glass over a light space reads as grey murk
    func chromeGlass(in shape: some Shape, interactive: Bool = false, lit: Bool = false) -> some View {
        modifier(ChromeGlass(shape: shape, interactive: interactive, lit: lit))
    }
}

private struct ChromeGlass<S: Shape>: ViewModifier {
    @Environment(\.chromeInk) private var ink
    @Environment(\.colorScheme) private var scheme
    let shape: S
    let interactive: Bool
    let lit: Bool

    func body(content: Content) -> some View {
        // only the glass takes the backdrop's scheme; the content (and any
        // popover it presents) keeps the window's
        content
            .environment(\.colorScheme, scheme)
            .glassEffect(.regular.tint(lit ? ink.opacity(0.12) : nil).interactive(interactive), in: shape)
            .modifier(ChromeGlassScheme())
    }
}

/// the scheme glass takes over the sidebar's backdrop; a GlassEffectContainer draws its glass in
/// its own scheme, so it wears this too
struct ChromeGlassScheme: ViewModifier {
    @Environment(\.chromeInk) private var ink

    func body(content: Content) -> some View {
        content.environment(\.colorScheme, Self.scheme(under: ink))
    }

    static func scheme(under ink: Color) -> ColorScheme {
        let c = ink.resolve(in: EnvironmentValues())
        return 0.299 * c.red + 0.587 * c.green + 0.114 * c.blue < 0.5 ? .light : .dark
    }
}
