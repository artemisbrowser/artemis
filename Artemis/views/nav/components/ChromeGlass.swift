// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

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

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if isSelected {
            Color.clear.chromeGlass(in: shape, lit: true)
        } else {
            shape.fill(ink.opacity(opacity))
        }
    }
}

extension View {
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
        let c = ink.resolve(in: EnvironmentValues())
        let inkIsDark = 0.299 * c.red + 0.587 * c.green + 0.114 * c.blue < 0.5
        // only the glass takes the backdrop's scheme; the content (and any
        // popover it presents) keeps the window's
        content
            .environment(\.colorScheme, scheme)
            .glassEffect(.regular.tint(lit ? ink.opacity(0.12) : nil).interactive(interactive), in: shape)
            .environment(\.colorScheme, inkIsDark ? .light : .dark)
    }
}
