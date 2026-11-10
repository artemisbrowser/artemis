// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import Metal
import QuartzCore
import SwiftUI

/// the intro sky's gradient, its two nebulae and the glow behind the A, drawn on the GPU and dithered before they
/// reach 8 bits, so they fade out without stepping in rings
struct IntroSky: NSViewRepresentable, Animatable {
    struct Nebula {
        let colour: Color
        /// its middle as a share of the sky's size, and how far it reaches as a share of the sky's width
        let at: UnitPoint
        let reach: Double
        let strength: Double
    }

    /// the stage's centre in points, which the sky zooms about and the glow sits on
    let centre: CGPoint
    let zoom: Double
    let nebulae: [Nebula]
    let glow: (colour: Color, radius: Double, alpha: Double)
    /// how much of the glow shows, as the mark comes and goes
    var marked: Double
    @Environment(\.self) private var environment

    var animatableData: Double {
        get { marked }
        set { marked = newValue }
    }

    func makeNSView(context: Context) -> Surface { Surface() }

    func updateNSView(_ surface: Surface, context: Context) {
        func rgb(_ colour: Color, _ w: Double) -> SIMD4<Float> {
            let c = colour.resolve(in: environment)
            return SIMD4(c.red, c.green, c.blue, Float(w))
        }
        var uniforms = [
            SIMD4(0, 0, Float(centre.x), Float(centre.y)), SIMD4(Float(zoom), 0, Float(glow.radius), 0), rgb(glow.colour, glow.alpha * marked),
        ]
        for nebula in nebulae.prefix(2) {
            uniforms += [rgb(nebula.colour, nebula.strength), SIMD4(Float(nebula.at.x), Float(nebula.at.y), Float(nebula.reach), 0)]
        }
        surface.uniforms = uniforms
    }

    final class Surface: NSView {
        private static let device = MTLCreateSystemDefaultDevice()
        private static let pipeline: MTLRenderPipelineState? = {
            guard let device, let library = try? device.makeLibrary(source: shader, options: nil) else { return nil }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "cover")
            descriptor.fragmentFunction = library.makeFunction(name: "sky")
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            return try? device.makeRenderPipelineState(descriptor: descriptor)
        }()
        private let queue = device?.makeCommandQueue()
        private let metal = CAMetalLayer()
        /// redrawn at most 30 times a second
        private var drawn = 0.0, isDue = false
        var uniforms: [SIMD4<Float>] = [] {
            didSet { schedule() }
        }

        init() {
            super.init(frame: .zero)
            metal.device = Self.device
            metal.pixelFormat = .bgra8Unorm
            metal.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
            metal.isOpaque = true
            layer = metal
            wantsLayer = true
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        private func schedule() {
            let wait = drawn + 1.0 / 30 - CACurrentMediaTime()
            guard wait > 0 else { return render() }
            guard !isDue else { return }
            isDue = true
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                self?.isDue = false
                self?.render()
            }
        }

        /// into a drawable kept at the largest size the view has had, which the layer scales to fit as it shrinks
        private func render() {
            let scale = window?.backingScaleFactor ?? 2, pixels = CGSize(width: bounds.width * scale, height: bounds.height * scale)
            guard uniforms.count == 7, pixels.width >= 1, pixels.height >= 1, let pipeline = Self.pipeline else { return }
            drawn = CACurrentMediaTime()
            if pixels.width > metal.drawableSize.width || pixels.height > metal.drawableSize.height {
                metal.drawableSize = CGSize(width: max(pixels.width, metal.drawableSize.width), height: max(pixels.height, metal.drawableSize.height))
            }
            guard let drawable = metal.nextDrawable(), let commands = queue?.makeCommandBuffer() else { return }
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = drawable.texture
            pass.colorAttachments[0].loadAction = .dontCare
            pass.colorAttachments[0].storeAction = .store
            guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
            var uniforms = uniforms
            (uniforms[0].x, uniforms[0].y) = (Float(bounds.width), Float(bounds.height))
            (uniforms[1].y, uniforms[1].w) = (Float(metal.drawableSize.width / bounds.width), Float(metal.drawableSize.height / bounds.height))
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<SIMD4<Float>>.stride * uniforms.count, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
            commands.present(drawable)
            commands.commit()
        }
    }

    /// u[0] size and centre in points; u[1] zoom, pixels per point across, glow radius, pixels per point down; u[2] glow; u[3...6] each nebula's colour and
    /// strength, then its middle and reach as shares. colours are gamma-encoded sRGB, blended as SwiftUI blends them
    private static let shader = """
        #include <metal_stdlib>
        using namespace metal;

        vertex float4 cover(uint id [[vertex_id]]) {
            float2 p = float2((id << 1) & 2, id & 2);
            return float4(p * 2 - 1, 0, 1);
        }

        float fading(float x, float core) {
            x = saturate(x);
            return core * exp(-x * x / 0.04) + (1 - core) * pow(1 - x * x, 2);
        }

        float noise(uint2 p) {
            uint h = p.x * 1664525u ^ p.y * 2654435761u;
            h ^= h >> 16; h *= 0x7feb352du; h ^= h >> 15; h *= 0x846ca68bu; h ^= h >> 16;
            return float(h) / 4294967295.0;
        }

        fragment float4 sky(float4 at [[position]], constant float4 *u [[buffer(0)]]) {
            float2 p = at.xy / u[1].yw, centre = u[0].zw, q = centre + (p - centre) / u[1].x;
            float3 rgb = mix(float3(0.016, 0.02, 0.047), float3(0.043, 0.063, 0.14), saturate(q.y / u[0].y));
            for (int i = 0; i < 2; i++) {
                float4 nebula = u[3 + 2 * i], place = u[4 + 2 * i];
                rgb = mix(rgb, nebula.rgb, nebula.w * fading(length(q - place.xy * u[0].xy) / (place.z * u[0].x), 0));
            }
            rgb += u[2].rgb * u[2].w * fading(length(p - centre) / u[1].z, 0.65);
            uint2 pixel = uint2(at.xy);
            return float4(rgb + (noise(pixel) + noise(pixel + uint2(7919, 104729)) - 1) / 255, 1);
        }
        """
}
