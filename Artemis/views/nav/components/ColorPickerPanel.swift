// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import AppKit
import SwiftUI

/// a colour swatch that opens `ColorPickerPanel` in a popover
struct ColorSwatchPicker: View {
    @Binding var color: Color
    var size: CGFloat = 26
    @State private var showing = false

    var body: some View {
        Button { showing.toggle() } label: {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(color)
                .frame(width: size, height: size)
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(.white.opacity(0.25), lineWidth: 1))
                .shadow(color: .black.opacity(0.2), radius: 1, y: 1)
        }
        .buttonStyle(.plain)
        .tooltip("Colour")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            ColorPickerPanel(color: $color)
        }
    }
}

/// an HSB colour picker: saturation/brightness field, hue rail, an editable
/// value in the chosen format, and per-channel sliders for that format
struct ColorPickerPanel: View {
    @Binding var color: Color

    private enum Fmt: String, CaseIterable { case hex = "HEX", rgb = "RGB", hsl = "HSL", hsv = "HSV" }

    @State private var hue = 0.0
    @State private var sat = 1.0
    @State private var bri = 1.0
    @State private var format: Fmt = .hex
    @State private var value = ""

    private static let ring = Color(red: 0.2, green: 0.83, blue: 0.7)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            svField
            hueRail
            formatRow
            // hex has no channels to tune
            if format != .hex {
                Divider().opacity(0.4)
                fineTune
            }
        }
        .padding(16)
        .frame(width: 344)
        .onAppear(perform: load)
        .onChange(of: format) { syncValue() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(live)
                .frame(width: 46, height: 46)
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.18)))
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.system(size: 15, weight: .bold).monospaced())
                    .contentTransition(.numericText())
                    .lineLimit(1).minimumScaleFactor(0.7)
                Text("Current colour").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            HStack(spacing: 6) {
                actionButton("shuffle", help: "Random") { randomise() }
                actionButton("doc.on.doc", help: "Copy") { copy() }
                actionButton("eyedropper", help: "Pick from screen") { sample() }
            }
        }
    }

    private func actionButton(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.8))
                .frame(width: 30, height: 30)
                .glassEffect(.regular, in: .rect(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .tooltip(help)
    }

    // MARK: Saturation / Brightness field

    private var svField: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                LinearGradient(
                    colors: [.white, Color(hue: hue, saturation: 1, brightness: 1)],
                    startPoint: .leading, endPoint: .trailing)
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 1))
            .overlay(svKnob.position(x: sat * w, y: (1 - bri) * h))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        sat = clamp(v.location.x / w)
                        bri = 1 - clamp(v.location.y / h)
                        push()
                    })
        }
        .frame(height: 150)
    }

    private var svKnob: some View {
        Circle().fill(.white.opacity(0.001))
            .frame(width: 18, height: 18)
            .overlay(Circle().strokeBorder(.white, lineWidth: 3))
            .shadow(color: .black.opacity(0.35), radius: 1.5)
    }

    // MARK: Hue rail

    private var hueRail: some View {
        GeometryReader { geo in
            let w = geo.size.width
            Capsule()
                .fill(LinearGradient(colors: Self.hueStops, startPoint: .leading, endPoint: .trailing))
                .overlay(
                    Circle().fill(Color(hue: hue, saturation: 1, brightness: 1))
                        .frame(width: 18, height: 18)
                        .overlay(Circle().strokeBorder(.white, lineWidth: 3))
                        .shadow(color: .black.opacity(0.3), radius: 1.5)
                        .position(x: hue * w, y: geo.size.height / 2))
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in hue = clamp(v.location.x / w); push() })
        }
        .frame(height: 16)
    }

    // MARK: Format + value

    private var formatRow: some View {
        HStack(alignment: .bottom, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                Text("FORMAT").font(.system(size: 11, weight: .semibold)).foregroundStyle(.primary.opacity(0.45))
                Menu {
                    ForEach(Fmt.allCases, id: \.self) { f in Button(f.rawValue) { format = f } }
                } label: {
                    HStack(spacing: 6) {
                        Text(format.rawValue).font(.system(size: 13, weight: .semibold))
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.primary.opacity(0.5))
                    }
                    .padding(.horizontal, 11).padding(.vertical, 8)
                    .glassEffect(.regular, in: .rect(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .frame(width: 96)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("VALUE").font(.system(size: 11, weight: .semibold)).foregroundStyle(.primary.opacity(0.45))
                TextField("", text: $value)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13).monospaced())
                    .accessibilityLabel("Colour value")
                    .onSubmit(applyValue)
                    .padding(.horizontal, 11).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.primary.opacity(0.06)))
            }
        }
    }

    // MARK: Fine tune

    private var fineTune: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Fine tune").font(.system(size: 14, weight: .semibold))
            switch format {
            case .hex:
                EmptyView()
            case .rgb:
                let (r, g, b) = rgbD()
                fineSlider("R", r * 255, 0...255, "\(Int(round(r * 255)))",
                    [srgb(0, g, b), srgb(1, g, b)]) { setRGB($0 / 255, g, b) }
                fineSlider("G", g * 255, 0...255, "\(Int(round(g * 255)))",
                    [srgb(r, 0, b), srgb(r, 1, b)]) { setRGB(r, $0 / 255, b) }
                fineSlider("B", b * 255, 0...255, "\(Int(round(b * 255)))",
                    [srgb(r, g, 0), srgb(r, g, 1)]) { setRGB(r, g, $0 / 255) }
            case .hsl:
                let (h, s, l) = hslD()
                fineSlider("Hue", h * 360, 0...360, "\(Int(round(h * 360)))°", Self.hueStops) {
                    hue = $0 / 360; push()
                }
                fineSlider("Saturation", s * 100, 0...100, "\(Int(round(s * 100)))%",
                    [hslColor(h, 0, l), hslColor(h, 1, l)]) { setHSL(h, $0 / 100, l) }
                fineSlider("Lightness", l * 100, 0...100, "\(Int(round(l * 100)))%",
                    [.black, hslColor(h, s, 0.5), .white]) { setHSL(h, s, $0 / 100) }
            case .hsv:
                fineSlider("Hue", hue * 360, 0...360, "\(Int(round(hue * 360)))°", Self.hueStops) {
                    hue = $0 / 360; push()
                }
                fineSlider("Saturation", sat * 100, 0...100, "\(Int(round(sat * 100)))%",
                    [Color(hue: hue, saturation: 0, brightness: bri), Color(hue: hue, saturation: 1, brightness: bri)]) {
                    sat = $0 / 100; push()
                }
                fineSlider("Value", bri * 100, 0...100, "\(Int(round(bri * 100)))%",
                    [.black, Color(hue: hue, saturation: sat, brightness: 1)]) { bri = $0 / 100; push() }
            }
        }
    }

    private func fineSlider(
        _ label: String, _ value: Double, _ range: ClosedRange<Double>, _ display: String,
        _ track: [Color], _ onChange: @escaping (Double) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label).font(.system(size: 12)).foregroundStyle(.primary.opacity(0.7))
                Spacer()
                Text(display).font(.system(size: 12).monospacedDigit())
                    .contentTransition(.numericText())
                    .foregroundStyle(.primary.opacity(0.4))
            }
            GeometryReader { geo in
                let w = geo.size.width
                let t = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
                ZStack(alignment: .leading) {
                    Capsule().fill(LinearGradient(colors: track, startPoint: .leading, endPoint: .trailing))
                        .frame(height: 8)
                    Circle().fill(.white).frame(width: 16, height: 16)
                        .overlay(Circle().strokeBorder(Self.ring, lineWidth: 3))
                        .shadow(color: .black.opacity(0.3), radius: 1.5)
                        .offset(x: t * (w - 16))
                }
                .frame(height: 16)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            let nt = min(max((v.location.x - 8) / (w - 16), 0), 1)
                            onChange(range.lowerBound + nt * (range.upperBound - range.lowerBound))
                        })
            }
            .frame(height: 16)
        }
    }

    // MARK: Colour plumbing

    private var live: Color { Color(hue: hue, saturation: sat, brightness: bri) }

    private func load() {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ns.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        if s > 0.0001 { hue = Double(h) }
        sat = Double(s); bri = Double(b)
        syncValue()
    }

    private func push() {
        color = live
        syncValue()
    }

    private func randomise() {
        // only discrete jumps animate; drags stay instant so the knob tracks the pointer
        withAnimation(.snappy(duration: 0.4)) {
            hue = .random(in: 0...1); sat = .random(in: 0.45...1); bri = .random(in: 0.5...1)
            push()
        }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func sample() {
        NSColorSampler().show { picked in
            guard let picked else { return }
            let c = picked.usingColorSpace(.sRGB).map(Color.init) ?? color
            withAnimation(.snappy(duration: 0.4)) { color = c; load() }
        }
    }

    // MARK: Conversions

    private func srgb(_ r: Double, _ g: Double, _ b: Double) -> Color {
        Color(.sRGB, red: clampD(r), green: clampD(g), blue: clampD(b))
    }

    private func rgbD() -> (Double, Double, Double) {
        let ns = NSColor(live).usingColorSpace(.sRGB) ?? .black
        return (Double(ns.redComponent), Double(ns.greenComponent), Double(ns.blueComponent))
    }

    private func hslD() -> (Double, Double, Double) {
        let (r, g, b) = rgbD()
        let mx = max(r, g, b), mn = min(r, g, b), l = (mx + mn) / 2, d = mx - mn
        let s = d == 0 ? 0 : d / (1 - abs(2 * l - 1))
        return (hue, s, l)
    }

    private func hslColor(_ h: Double, _ s: Double, _ l: Double) -> Color {
        let c = (1 - abs(2 * l - 1)) * s
        let x = c * (1 - abs((h * 6).truncatingRemainder(dividingBy: 2) - 1))
        let m = l - c / 2
        let (r, g, b): (Double, Double, Double)
        switch h * 6 {
        case ..<1: (r, g, b) = (c, x, 0)
        case ..<2: (r, g, b) = (x, c, 0)
        case ..<3: (r, g, b) = (0, c, x)
        case ..<4: (r, g, b) = (0, x, c)
        case ..<5: (r, g, b) = (x, 0, c)
        default: (r, g, b) = (c, 0, x)
        }
        return srgb(r + m, g + m, b + m)
    }

    private func setRGB(_ r: Double, _ g: Double, _ b: Double) {
        color = srgb(r, g, b); load()
    }

    private func setHSL(_ h: Double, _ s: Double, _ l: Double) {
        color = hslColor(h, s, l); load()
    }

    // MARK: Format value

    private func syncValue() {
        let ns = NSColor(live).usingColorSpace(.sRGB) ?? .black
        let r = Int(round(ns.redComponent * 255)), g = Int(round(ns.greenComponent * 255))
        let b = Int(round(ns.blueComponent * 255))
        switch format {
        case .hex: value = String(format: "#%02X%02X%02X", r, g, b)
        case .rgb: value = "rgb(\(r), \(g), \(b))"
        case .hsl: let (h, s, l) = hslD(); value = "hsl(\(Int(round(h * 360))), \(Int(round(s * 100)))%, \(Int(round(l * 100)))%)"
        case .hsv: value = "hsv(\(Int(round(hue * 360))), \(Int(round(sat * 100)))%, \(Int(round(bri * 100)))%)"
        }
    }

    private func applyValue() {
        withAnimation(.snappy(duration: 0.4)) { applyValueChange() }
    }

    private func applyValueChange() {
        switch format {
        case .hex:
            let s = value.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")
            guard s.count == 6, let v = Int(s, radix: 16) else { syncValue(); return }
            setRGB(Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
        case .rgb:
            let n = numbers(value); guard n.count >= 3 else { syncValue(); return }
            setRGB(n[0] / 255, n[1] / 255, n[2] / 255)
        case .hsl:
            let n = numbers(value); guard n.count >= 3 else { syncValue(); return }
            setHSL(n[0] / 360, n[1] / 100, n[2] / 100)
        case .hsv:
            let n = numbers(value); guard n.count >= 3 else { syncValue(); return }
            hue = clampD(n[0] / 360); sat = clampD(n[1] / 100); bri = clampD(n[2] / 100); push()
        }
    }

    private func numbers(_ s: String) -> [Double] {
        s.components(separatedBy: CharacterSet(charactersIn: "0123456789.").inverted).compactMap(Double.init)
    }

    private func clamp(_ v: CGFloat) -> Double { Double(min(max(v, 0), 1)) }
    private func clampD(_ v: Double) -> Double { min(max(v, 0), 1) }

    private static let hueStops: [Color] =
        stride(from: 0.0, through: 1.0, by: 1.0 / 12).map { Color(hue: $0, saturation: 1, brightness: 1) }
}
