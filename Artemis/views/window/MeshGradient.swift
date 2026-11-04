// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import CoreGraphics
import SwiftUI

/// a mesh gradient: every point blended by normalised inverse-distance weighting,
/// rendered on the CPU into a small bitmap that is scaled up
struct MeshGradientView: View {
    var points: [MeshPoint]
    /// higher = tighter, more distinct colour regions; lower = softer blend
    var sharpness: Double = 4

    var body: some View {
        if let image = Self.render(points: points, sharpness: sharpness) {
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.high)
        } else {
            Color.black
        }
    }

    // the field is smooth, so this resolution upscales cleanly to any size
    private static let cols = 110
    private static let rows = 74

    // keyed on point positions/colours + sharpness, not MeshPoint.id, which
    // differs between loads of the same look
    private static var cache: [Int: CGImage] = [:]

    private static func cacheKey(points: [MeshPoint], sharpness: Double) -> Int {
        var hasher = Hasher()
        for p in points {
            hasher.combine(p.x)
            hasher.combine(p.y)
            hasher.combine(p.color)
        }
        hasher.combine(sharpness)
        return hasher.finalize()
    }

    static func render(points: [MeshPoint], sharpness: Double) -> CGImage? {
        guard !points.isEmpty else { return nil }

        let key = cacheKey(points: points, sharpness: sharpness)
        if let hit = cache[key] { return hit }

        let w = cols, h = rows
        let power = sharpness / 2  // distances are kept squared to skip a sqrt
        let squared = power == 2  // common case (sharpness 4) avoids pow()

        // flat arrays so the hot loop isn't walking an array of structs
        let n = points.count
        let xs = points.map(\.x), ys = points.map(\.y)
        let rs = points.map(\.color.r), gs = points.map(\.color.g), bs = points.map(\.color.b)
        var px = [UInt8](repeating: 255, count: w * h * 4)

        for yy in 0..<h {
            let uy = Double(yy) / Double(h - 1)
            for xx in 0..<w {
                let ux = Double(xx) / Double(w - 1)
                var total = 0.0, r = 0.0, g = 0.0, b = 0.0
                for i in 0..<n {
                    let dx = ux - xs[i], dy = uy - ys[i]
                    let d2 = dx * dx + dy * dy
                    let weight = 1.0 / ((squared ? d2 * d2 : pow(d2, power)) + 1e-5)
                    r += weight * rs[i]
                    g += weight * gs[i]
                    b += weight * bs[i]
                    total += weight
                }
                let inv = total > 0 ? 1 / total : 0
                let i = (yy * w + xx) * 4
                px[i] = UInt8(max(0, min(1, r * inv)) * 255)
                px[i + 1] = UInt8(max(0, min(1, g * inv)) * 255)
                px[i + 2] = UInt8(max(0, min(1, b * inv)) * 255)
                px[i + 3] = 255
            }
        }

        let space = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        guard
            let ctx = CGContext(
                data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: space, bitmapInfo: info)
        else { return nil }
        let image = ctx.makeImage()
        // an editor drag mints a look per tick; the spaces and presets in use are far fewer than 64
        if cache.count >= 64 { cache.removeAll(keepingCapacity: true) }
        if let image { cache[key] = image }
        return image
    }
}
