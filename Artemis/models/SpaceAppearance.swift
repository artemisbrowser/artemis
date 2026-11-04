// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import SwiftUI

extension RGBA {
    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }

    var brightness: Double { 0.299 * r + 0.587 * g + 0.114 * b }

    /// WCAG relative luminance; extended-sRGB components are clamped to 0…1 first
    var luminance: Double {
        func linear(_ c: Double) -> Double {
            let c = min(max(c, 0), 1)
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }
}

extension SpaceAppearance {
    /// the colours the fill paints
    var paletteColors: [RGBA] {
        fill == .solid ? Array(colors.prefix(1)) : effectiveMeshPoints.map(\.color)
    }

    /// changes that cross-fade the backdrop. mesh points and `glassBlur` are left
    /// out so dragging them applies live
    var transitionSignature: Int {
        var hasher = Hasher()
        hasher.combine(fill)
        hasher.combine(colors)
        hasher.combine(angle)
        hasher.combine(grain)
        return hasher.finalize()
    }

    /// the mesh points to paint, spread from `colors` when there are none
    var effectiveMeshPoints: [MeshPoint] {
        meshPoints.isEmpty ? Self.defaultMesh(from: colors) : meshPoints
    }

    private static func defaultMesh(from colors: [RGBA]) -> [MeshPoint] {
        let cs = colors.isEmpty ? defaultColors : colors
        guard cs.count > 1 else { return [MeshPoint(x: 0.5, y: 0.5, color: cs[0])] }
        return cs.enumerated().map { i, c in
            let t = Double(i) / Double(cs.count - 1)
            // zigzag down the canvas so the blobs don't sit on one straight line
            let y = 0.22 + 0.56 * (i.isMultiple(of: 2) ? t : 1 - t)
            return MeshPoint(x: 0.2 + 0.6 * t, y: y, color: c)
        }
    }

    /// opaque base behind a tab's web view until its page paints: the palette's
    /// darkest tone, or glass's dark neutral
    var cardBase: Color {
        if fill == .glass { return Color(.sRGB, red: 0.12, green: 0.12, blue: 0.15, opacity: 1) }
        let palette = paletteColors
        let darkest = palette.min(by: { $0.brightness < $1.brightness }) ?? RGBA(0.1, 0.1, 0.12)
        return darkest.color
    }

    // MARK: - Adaptive chrome ink

    /// relative luminance (0 dark…1 light) behind the sidebar: mesh blobs weigh
    /// more the further left they sit. glass always reports dark
    var backdropLuminance: Double {
        switch fill {
        case .glass:
            return 0
        case .solid:
            return colors.first?.luminance ?? 0
        case .gradient:
            let pts = effectiveMeshPoints
            guard !pts.isEmpty else { return 0 }
            var lum = 0.0, weightSum = 0.0
            for p in pts {
                let weight = 1 - p.x * 0.7  // left blobs count most; right still contributes
                lum += p.color.luminance * weight
                weightSum += weight
            }
            return weightSum > 0 ? lum / weightSum : 0
        }
    }

    /// the ink over light backdrops: a cool near-black
    static let darkInk = darkInkRGBA.color
    private static let darkInkRGBA = RGBA(0.10, 0.11, 0.13)

    /// the sidebar chrome's foreground: white or `darkInk`, never a mix.
    /// `TabManager.blendedInk` crossfades two of these across a switch
    var chromeInk: Color { Self.ink(over: backdropLuminance) }

    private static let darkInkLuminance = darkInkRGBA.luminance

    /// white or `darkInk`, whichever contrasts more with a surface of this relative luminance
    static func ink(over luminance: Double) -> Color {
        (luminance + 0.05) / (darkInkLuminance + 0.05) > 1.05 / (luminance + 0.05) ? darkInk : .white
    }
}

/// the space's `chromeInk`; white for chrome shown off a space backdrop
private struct ChromeInkKey: EnvironmentKey {
    static let defaultValue: Color = .white
}

/// the accent of the space a view is drawn for, which during a carousel slide
/// is not the manager's current space
private struct SpaceAccentKey: EnvironmentKey {
    static let defaultValue: Color = .white
}

extension EnvironmentValues {
    var chromeInk: Color {
        get { self[ChromeInkKey.self] }
        set { self[ChromeInkKey.self] = newValue }
    }

    var spaceAccent: Color {
        get { self[SpaceAccentKey.self] }
        set { self[SpaceAccentKey.self] = newValue }
    }
}
