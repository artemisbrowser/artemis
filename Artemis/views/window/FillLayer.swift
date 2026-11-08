// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

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
            // glass never takes grain, though a stale value can survive a fill change
            if appearance.fill != .glass, appearance.grain > 0.001 {
                NoiseTexture()
                    // slider 100% is 20% grain
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
            // the shared GlassSubstrate paints glass, scrim included
            Color.clear
        }
    }
}
