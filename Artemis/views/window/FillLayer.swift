import AppKit
import SwiftUI

/// one backdrop layer: the fill plus its film-grain overlay, for a single
/// appearance. two of these stack during a switch — the outgoing floor and
/// the incoming fade
struct FillLayer: View {
    var appearance: SpaceAppearance

    var body: some View {
        let _ = Bench.tick("FillLayer")
        ZStack {
            fill
            // glass never takes grain — its editor hides the slider, but a stale
            // value can linger from a gradient/preset the space was before, so
            // gate on fill type here rather than trusting the stored number
            if appearance.fill != .glass, appearance.grain > 0.001 {
                NoiseTexture()
                    // slider 100% maps to the old 20% — anything above was overkill
                    .opacity(appearance.grain * 0.2)
                    .blendMode(.overlay)
                    .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private var fill: some View {
        switch appearance.fill {
        case .solid:
            (appearance.colors.first?.color ?? .black)
        case .gradient:
            MeshGradientView(points: appearance.effectiveMeshPoints, sharpness: appearance.meshSharpness)
        case .glass:
            // just the dimming scrim over the shared GlassSubstrate; it keeps white
            // chrome ink legible over a bright page under the floating sidebar
            Color.black.opacity(0.22 + appearance.glassBlur * 0.13)
        }
    }
}

/// tiling film-grain. the noise tile is generated once and cached
struct NoiseTexture: View {
    var body: some View {
        Image(nsImage: Self.tile)
            .resizable(resizingMode: .tile)
    }

    static let tile: NSImage = {
        let size = 128
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        for x in 0..<size {
            for y in 0..<size {
                let v = CGFloat.random(in: 0...1)
                NSColor(white: v, alpha: 1).setFill()
                NSRect(x: x, y: y, width: 1, height: 1).fill()
            }
        }
        image.unlockFocus()
        return image
    }()
}
