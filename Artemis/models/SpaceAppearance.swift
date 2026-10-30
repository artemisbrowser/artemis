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
    /// the colours that define this appearance — the mesh's if present, else
    /// the legacy from/to list. drives the icon accent
    var paletteColors: [RGBA] {
        meshPoints.isEmpty ? colors : meshPoints.map(\.color)
    }

    /// what should cross-fade when it changes. mesh edits *and* glassBlur are
    /// excluded so live dragging applies instantly: a blur drag updates the
    /// shared substrate + scrim continuously, rather than firing a 0.35s fade
    /// per slider tick
    var transitionSignature: Int {
        var hasher = Hasher()
        hasher.combine(fill)
        hasher.combine(colors)
        hasher.combine(angle)
        hasher.combine(grain)
        return hasher.finalize()
    }

    /// the mesh points to paint; falls back to a spread derived from the legacy
    /// colours so spaces saved before the mesh editor still render
    var effectiveMeshPoints: [MeshPoint] {
        meshPoints.isEmpty ? Self.defaultMesh(from: colors) : meshPoints
    }

    /// a pleasant starting scatter of blobs from a colour list
    static func defaultMesh(from colors: [RGBA]) -> [MeshPoint] {
        let cs = colors.isEmpty ? [RGBA(0.18, 0.14, 0.40), RGBA(0.30, 0.18, 0.48)] : colors
        guard cs.count > 1 else { return [MeshPoint(x: 0.5, y: 0.5, color: cs[0])] }
        return cs.enumerated().map { i, c in
            let t = Double(i) / Double(cs.count - 1)
            // zigzag down the canvas so the blobs don't sit on one straight line
            let y = 0.22 + 0.56 * (i.isMultiple(of: 2) ? t : 1 - t)
            return MeshPoint(x: 0.2 + 0.6 * t, y: y, color: c)
        }
    }

    /// opaque base painted behind a tab's web view before its page renders —
    /// the space's darkest palette tone, so a loading or just-mounted card
    /// melts into the backdrop instead of flashing white on a space switch.
    /// glass takes the dark neutral of its frosted base
    var cardBase: Color {
        if fill == .glass { return Color(.sRGB, red: 0.12, green: 0.12, blue: 0.15, opacity: 1) }
        let palette = paletteColors
        let darkest = palette.min(by: { $0.brightness < $1.brightness }) ?? RGBA(0.1, 0.1, 0.12)
        return darkest.color
    }

    // MARK: - Adaptive chrome ink

    /// relative luminance of the backdrop *behind the sidebar* (0 dark…1 light).
    /// the sidebar hugs the window's left edge, so mesh blobs are weighted by how
    /// far left they sit — a light blob on the right doesn't drag a dark-left
    /// sidebar into "light" territory.
    ///
    /// glass is a dark frosted base under a dimming scrim, so it reports dark.
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

    /// near-black ink used over light backdrops — a touch cool and softer than
    /// pure black, the way Apple's label colour reads
    static let darkInk = darkInkRGBA.color
    private static let darkInkRGBA = RGBA(0.10, 0.11, 0.13)

    /// the foreground colour the sidebar chrome should tint text, glyphs and hover
    /// fills with: whichever of white and `darkInk` has the higher WCAG contrast.
    ///
    /// decisive on purpose. a space parked at the crossover needs full contrast,
    /// not a half-mixed grey — it is `TabManager.blendedInk` that crossfades two
    /// of these across a switch, so the ramp lives in the motion, not in the
    /// resting value. it also means two same-polarity spaces never dim at all
    /// mid-slide: blending white with white is white.
    var chromeInk: Color { Self.ink(over: backdropLuminance) }

    private static let darkInkLuminance = darkInkRGBA.luminance

    /// white or `darkInk`, whichever contrasts more with a surface of this relative luminance
    static func ink(over luminance: Double) -> Color {
        (luminance + 0.05) / (darkInkLuminance + 0.05) > 1.05 / (luminance + 0.05) ? darkInk : .white
    }
}

/// carries the space's adaptive sidebar ink down to every chrome view, so they
/// tint against the backdrop instead of hardcoding white. defaults to white for
/// any chrome shown off a space backdrop (popovers etc.)
private struct ChromeInkKey: EnvironmentKey {
    static let defaultValue: Color = .white
}

/// the accent of the space a view is drawn *for*, which is not always the
/// current one — the carousel renders its neighbours, and reading the manager
/// there paints them in the colour of the space you are leaving
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
