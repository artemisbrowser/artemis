// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import AppKit
import SwiftUI

/// "Gift Artemis to a Friend": a glass card over the window holding a ticket to the site,
/// its link to copy, the sends that skip the system's share menu, and that menu out of the card's side
struct GiftCard: View {
    let manager: TabManager
    @State private var copied = false
    @State private var linkHovering = false
    @State private var arrived = false
    /// spans the More button out to the card's edge; the share menu hangs from it
    @State private var moreSide = NSView()
    @State private var escMonitor: Any?

    private static let inset: CGFloat = 18
    private static let sends: [(label: String, symbol: String, service: NSSharingService.Name?)] = [
        ("Messages", "message.fill", .composeMessage),
        ("Mail", "envelope.fill", .composeEmail),
        ("AirDrop", "dot.radiowaves.left.and.right", .sendViaAirDrop),
        ("More", "ellipsis", nil),
    ]

    var body: some View {
        VStack(spacing: 14) {
            GiftTicket()
                .rotation3DEffect(.degrees(arrived ? 0 : -32), axis: (x: 1, y: 0, z: 0), perspective: 0.5)
                .offset(y: arrived ? 0 : 18)
                .opacity(arrived ? 1 : 0)
                .animation(Motion.morph, value: arrived)
            link
            HStack(spacing: 0) {
                ForEach(Array(Self.sends.enumerated()), id: \.offset) { index, send in
                    GiftSend(label: send.label, symbol: send.symbol) {
                        guard let service = send.service else {
                            return Gift.more(from: moreSide, face: GiftSend.face) { manager.isGiftVisible = false }
                        }
                        Gift.send(service)
                        manager.isGiftVisible = false
                    }
                    .background {
                        if send.service == nil {
                            MenuAnchor(view: moreSide).padding(.trailing, -Self.inset).allowsHitTesting(false)
                        }
                    }
                    .scaleEffect(arrived ? 1 : 0.6)
                    .opacity(arrived ? 1 : 0)
                    .animation(Motion.pop.delay(0.08 + Double(index) * 0.035), value: arrived)
                }
            }
        }
        .padding(Self.inset)
        .frame(width: GiftTicket.size.width + 2 * Self.inset)
        .glassEffect(.regular, in: .rect(cornerRadius: GiftTicket.radius + Self.inset))
        .shadow(color: .black.opacity(0.3), radius: 30, y: 12)
        .onAppear {
            DispatchQueue.main.async { arrived = true }
            // a monitor, as SwiftUI's key handling never sees keys over a WKWebView; it sees every window's
            escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [manager] event in
                guard event.keyCode == 53, let window = event.window, BrowserWindows.shared.manager(for: window) === manager
                else { return event }
                manager.isGiftVisible = false
                return nil
            }
        }
        .onDisappear { if let escMonitor { NSEvent.removeMonitor(escMonitor) } }
    }

    /// the link, which copies itself when pressed and says so for a moment
    private var link: some View {
        Button {
            Gift.copy()
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.2))
                copied = false
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: copied ? "checkmark" : "link")
                    .font(.system(size: 12, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace.offUp))
                Text(copied ? "Copied" : (Gift.link.host() ?? "") + Gift.link.path())
                    .font(.system(size: 13, weight: .medium))
                    .contentTransition(.numericText())
            }
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .background(Capsule().fill(.primary.opacity(linkHovering ? 0.34 : 0.14)))
            .contentShape(Capsule())
            .scaleEffect(linkHovering ? 1.01 : 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Copy Link")
        .onHover { linkHovering = $0 }
        .animation(Motion.panel, value: copied)
        .animation(Motion.hover, value: linkHovering)
    }
}

struct MenuAnchor: NSViewRepresentable {
    let view: NSView

    func makeNSView(context: Context) -> NSView { view }

    func updateNSView(_ view: NSView, context: Context) {}
}

/// one way to send the gift: a round face and its name, flat, as it sits on the card's glass
private struct GiftSend: View {
    let label: String
    let symbol: String
    let action: () -> Void
    @State private var hovering = false

    static let face: CGFloat = 46

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: Self.face, height: Self.face)
                    .background(Circle().fill(.primary.opacity(hovering ? 0.3 : 0.1)))
                    .scaleEffect(hovering ? 1.04 : 1)
                Text(label)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.pop, value: hovering)
    }
}

/// the ticket, in the app icon's colour: the mark, and a stub whose code opens the site.
/// it leans toward the pointer with its layers in parallax, catches the light there, and drags out as the link
struct GiftTicket: View {
    static let size = CGSize(width: 320, height: 156)
    static let radius: CGFloat = 16
    private static let stub: CGFloat = 104
    private static let notch: CGFloat = 7

    /// where the pointer is over the ticket, in its unit space; nil when it is elsewhere
    @State private var pointer: UnitPoint?

    var body: some View {
        let tint = AppIconChoice.current.glyph
        let deep = tint.base.mix(with: .black, by: 0.38, in: .perceptual)
        let tear = Self.size.width - Self.stub
        let shape = TicketShape(tear: tear, notch: Self.notch, radius: Self.radius)
        let lean = pointer ?? .center
        return ZStack(alignment: .topLeading) {
            LinearGradient(
                colors: [tint.light.mix(with: tint.base, by: 0.35, in: .perceptual), tint.base, deep],
                startPoint: .topLeading, endPoint: .bottomTrailing)
            orbits.frame(width: tear, height: Self.size.height).clipped()
            mark.frame(width: tear, height: Self.size.height).clipped()
            words.frame(width: tear, height: Self.size.height, alignment: .topLeading).offset(drift(3))
            code(ink: deep).frame(width: Self.stub, height: Self.size.height).offset(x: tear).offset(drift(3))
            Path { path in
                path.move(to: CGPoint(x: tear, y: Self.notch + 5))
                path.addLine(to: CGPoint(x: tear, y: Self.size.height - Self.notch - 5))
            }
            .stroke(.white.opacity(0.45), style: StrokeStyle(lineWidth: 1.2, lineCap: .round, dash: [0.1, 5]))
            Circle()
                .fill(RadialGradient(colors: [.white.opacity(0.18), .clear], center: .center, startRadius: 0, endRadius: 150))
                .frame(width: 300, height: 300)
                .position(x: lean.x * Self.size.width, y: lean.y * Self.size.height)
                .blendMode(.plusLighter)
                .opacity(pointer == nil ? 0 : 1)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .overlay {
            shape.stroke(
                LinearGradient(colors: [.white.opacity(0.6), .white.opacity(0.1)], startPoint: .top, endPoint: .bottom),
                lineWidth: 1.5)
        }
        .clipShape(shape)
        .contentShape(shape)
        .shadow(color: .black.opacity(0.3), radius: 10, x: (0.5 - lean.x) * 10, y: 6 + (0.5 - lean.y) * 8)
        .rotation3DEffect(.degrees((lean.x - 0.5) * 10), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
        .rotation3DEffect(.degrees((0.5 - lean.y) * 9), axis: (x: 1, y: 0, z: 0), perspective: 0.5)
        .scaleEffect(pointer == nil ? 1 : 1.02)
        .offset(drift(3))
        .animation(Motion.follow, value: pointer)
        .onContinuousHover { phase in
            guard !Motion.reduceMotion else { return }
            switch phase {
            case .active(let point): pointer = UnitPoint(x: point.x / Self.size.width, y: point.y / Self.size.height)
            case .ended: pointer = nil
            }
        }
        .onDrag { NSItemProvider(object: Gift.link as NSURL) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Ticket to \(Gift.link.host() ?? "")")
    }

    private static let markSide: CGFloat = 150
    private static let markCentre = CGPoint(x: 148, y: 64)

    /// how far the pointer pulls a layer floating `depth` points above the paper
    private func drift(_ depth: CGFloat) -> CGSize {
        let lean = pointer ?? .center
        return CGSize(width: (lean.x - 0.5) * depth, height: (lean.y - 0.5) * depth)
    }

    /// rings about the centre of the comet's orbit, faint in the paper
    private var orbits: some View {
        let scale = Self.markSide / 1024
        let radius = MarkPart.orbit.radius * scale
        return ZStack {
            ForEach(-2..<5, id: \.self) { ring in
                let side = 2 * (radius + CGFloat(ring) * 24)
                Circle()
                    .stroke(.white.opacity(0.1), lineWidth: 1)
                    .frame(width: side, height: side)
            }
        }
        .position(
            x: Self.markCentre.x + (MarkPart.orbit.centre.x - 512) * scale,
            y: Self.markCentre.y + (MarkPart.orbit.centre.y - 512) * scale)
    }

    private var mark: some View {
        ZStack {
            MarkPart(isComet: false).fill(.white.opacity(0.22))
            MarkPart(isComet: true).fill(.white.opacity(0.38))
        }
        .frame(width: Self.markSide, height: Self.markSide)
        .offset(drift(4))
        .position(Self.markCentre)
    }

    private var words: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 0)
            Text("Artemis")
                .font(.system(size: 30, weight: .bold, design: .serif))
            Text("An invite just for you.")
                .font(.system(size: 10.5, weight: .medium))
                .fixedSize()
                .opacity(0.85)
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
        .padding(16)
    }

    @ViewBuilder
    private func code(ink: Color) -> some View {
        if let code = Gift.code {
            CodeShape(code: code)
                .fill(ink)
                // two points a module, so each lands on whole pixels
                .frame(width: CGFloat(code.width) * 2, height: CGFloat(code.height) * 2)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white))
        }
    }
}

/// the dark modules of a QR code drawn one pixel a module, as squares filling the rect
private struct CodeShape: Shape {
    let code: CGImage

    func path(in rect: CGRect) -> Path {
        guard let data = code.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return Path() }
        let unit = rect.width / CGFloat(code.width), step = code.bitsPerPixel / 8
        return Path { path in
            for y in 0..<code.height {
                for x in 0..<code.width where bytes[y * code.bytesPerRow + x * step] < 128 {
                    path.addRect(CGRect(x: rect.minX + CGFloat(x) * unit, y: rect.minY + CGFloat(y) * unit, width: unit, height: unit))
                }
            }
        }
    }
}

/// a rounded ticket with a half-round notch cut from its top and bottom edges, `tear` from the left
private struct TicketShape: Shape {
    let tear: CGFloat
    let notch: CGFloat
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        let notches = Path { path in
            for y in [rect.minY, rect.maxY] {
                path.addEllipse(in: CGRect(x: rect.minX + tear - notch, y: y - notch, width: 2 * notch, height: 2 * notch))
            }
        }
        return Path(roundedRect: rect, cornerRadius: radius, style: .continuous).subtracting(notches)
    }
}
