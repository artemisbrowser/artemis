// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import AppKit
import SwiftUI

extension RGBA {
    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
        r = Double(ns.redComponent)
        g = Double(ns.greenComponent)
        b = Double(ns.blueComponent)
        a = Double(ns.alphaComponent)
    }
}

extension SpaceAppearance {
    /// a vivid, legible accent for the space's icon + selection on dark chrome
    var accent: Color {
        if fill == .glass { return .white.opacity(0.9) }
        let palette = paletteColors
        let base = palette.max(by: { saturation($0) < saturation($1) }) ?? RGBA(0.6, 0.5, 0.95)
        let ns = NSColor(base.color).usingColorSpace(.sRGB) ?? .white
        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
        ns.getHue(&h, saturation: &s, brightness: &v, alpha: &a)
        return Color(hue: Double(h), saturation: Double(min(s, 0.75)), brightness: 0.92)
    }

    /// linear blend in sRGB; `t` is clamped to 0…1
    static func blend(_ a: Color, _ b: Color, _ t: Double) -> Color {
        let t = min(max(t, 0), 1)
        if t == 0 || a == b { return a }
        if t == 1 { return b }
        guard let na = NSColor(a).usingColorSpace(.sRGB),
            let nb = NSColor(b).usingColorSpace(.sRGB)
        else { return a }
        return Color(
            .sRGB,
            red: Double(na.redComponent + (nb.redComponent - na.redComponent) * t),
            green: Double(na.greenComponent + (nb.greenComponent - na.greenComponent) * t),
            blue: Double(na.blueComponent + (nb.blueComponent - na.blueComponent) * t),
            opacity: Double(na.alphaComponent + (nb.alphaComponent - na.alphaComponent) * t))
    }

    /// ink for text drawn on the card, over `cardBase` rather than the backdrop
    var cardInk: Color { Self.ink(over: RGBA(cardBase).luminance) }

    private func saturation(_ rgba: RGBA) -> Double {
        let maxC = max(rgba.r, rgba.g, rgba.b)
        let minC = min(rgba.r, rgba.g, rgba.b)
        return maxC == 0 ? 0 : (maxC - minC) / maxC
    }
}
