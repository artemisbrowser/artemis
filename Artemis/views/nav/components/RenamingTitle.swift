import AppKit
import SwiftUI

/// a tab's name, which crumbles to dust left to right when the tab is renamed.
/// only a change of `renameToken` animates: a page retitling itself never does.
/// the dust is an overlay, so it drifts past the row without reflowing it
struct RenamingTitle: View {
    let title: String
    /// the name this tab has been given, or "" when it's showing the page's own
    /// title. a change here — and only here — is a rename
    let renameToken: String
    /// which page this is; a change means navigation, never a rename
    let identity: String
    let fontSize: CGFloat
    let ink: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var shown = ""
    /// the name currently crumbling, and how far along it is
    @State private var dust: String?
    @State private var progress: CGFloat = 0
    @State private var lastToken = ""
    @State private var lastIdentity = ""

    /// how long the old name takes to blow away. anything that waits for the
    /// dust to settle — the "Click to rename" hint — times off this
    static let duration = 0.85

    /// where the wave has got to, 0…1 across the name: it crumbles the old name
    /// and uncovers the new one, so the two halves can't drift apart
    private var wave: CGFloat {
        min(1, progress / DustCloud.spread)
    }

    var body: some View {
        Group {
            if dust == nil {
                // at rest: plain text, with no mask left to dim the name's end
                text(shown)
            } else {
                text(shown).mask(alignment: .leading) { revealMask }
            }
        }
        .overlay(alignment: .leading) {
            if let dust {
                DustCloud(text: dust, progress: progress, fontSize: fontSize, ink: ink)
                    // room to fly: an overlay takes no layout space, so the
                    // canvas can be bigger than the text it came from
                    .frame(width: 260, height: fontSize * 3, alignment: .leading)
                    .allowsHitTesting(false)
            }
        }
        .onAppear {
            shown = title
            lastToken = renameToken
            lastIdentity = identity
        }
        .onChange(of: identity) { _, new in
            // a different page: whatever it's called now isn't a rename
            lastIdentity = new
            lastToken = renameToken
            dust = nil
            shown = title
        }
        .onChange(of: title) { _, new in
            // a rename changes title and token in one pass, and these
            // handlers run in declaration order: once the token has moved,
            // leave the old name for the handler below to animate
            guard renameToken == lastToken else { return }
            if dust == nil { shown = new }
        }
        .onChange(of: renameToken) { _, new in
            let previous = shown
            lastToken = new
            guard identity == lastIdentity, !previous.isEmpty, previous != title else {
                shown = title
                return
            }
            guard !reduceMotion else {
                withAnimation(Motion.fade) { shown = title }
                return
            }
            blowAway(previous)
        }
    }

    /// the new name, uncovered from the left as the wave passes over it
    private var revealMask: some View {
        GeometryReader { geo in
            let edge = wave * (geo.size.width + 24)
            Path(CGRect(x: 0, y: -20, width: max(0, edge), height: geo.size.height + 40))
                .fill(Color.black)
                .blur(radius: 3)
        }
    }

    private func blowAway(_ previous: String) {
        dust = previous
        progress = 0
        shown = title
        // the flight starts next runloop turn: 0 then 1 in one tick coalesces,
        // and with no frame drawn at 0 there is nothing to animate from
        DispatchQueue.main.async {
            withAnimation(.linear(duration: Self.duration)) { progress = 1 }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(Self.duration + 0.1))
            if dust == previous { dust = nil }
        }
    }

    private func text(_ value: String) -> some View {
        Text(value.replacingOccurrences(of: " ", with: "\u{00A0}"))
            .font(.system(size: fontSize))
            .lineLimit(1)
            .truncationMode(.tail)
            .foregroundStyle(ink)
    }
}

/// the old name mid-crumble: every letter breaks into dots that float right.
/// every particle is a function of the one animated `progress`
struct DustCloud: View, Animatable {
    let text: String
    var progress: CGFloat
    let fontSize: CGFloat
    let ink: Color

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    /// where each character sits along the name, measured once
    private let letters: [(character: Character, x: CGFloat, width: CGFloat)]

    init(text: String, progress: CGFloat, fontSize: CGFloat, ink: Color) {
        self.text = text
        self.progress = progress
        self.fontSize = fontSize
        self.ink = ink

        let font = NSFont.systemFont(ofSize: fontSize)
        var x: CGFloat = 0
        var measured: [(Character, CGFloat, CGFloat)] = []
        for character in text {
            let width = String(character).size(withAttributes: [.font: font]).width
            measured.append((character, x, width))
            x += width
        }
        letters = measured
    }

    /// dots per 10pt of letter, so a wide letter crumbles into more of them
    private static let density: CGFloat = 12
    /// how far a particle can travel before it's spent
    private static let drift: CGFloat = 120
    /// the share of the flight the wavefront takes to cross the name; the rest
    /// is the last letter's dust still travelling
    static let spread: CGFloat = 0.55
    /// how long a single letter takes to come apart once the wave reaches it
    private static let crumble: CGFloat = 0.16

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            let baseline = size.height / 2
            let colour = ink

            for (index, letter) in letters.enumerated() {
                let reached = waveHit(index: index)
                guard progress > reached else {
                    // the wave hasn't got here yet: still a letter
                    draw(letter, in: &context, at: baseline, opacity: 1, colour: colour)
                    continue
                }

                // the glyph fades over `crumble` as its dots take over
                let crumbling = min(1, (progress - reached) / Self.crumble)
                if crumbling < 1 {
                    draw(
                        letter, in: &context, at: baseline,
                        opacity: Double(1 - crumbling), colour: colour)
                }

                // the dust then travels for whatever is left of the flight, so
                // the letters that went first end up furthest right
                let count = max(3, Int(letter.width / 10 * Self.density))
                for dot in 0..<count {
                    // each dot leaves on its own beat, so the letter frays
                    // rather than popping
                    let delay = random(index, dot, 1) * Self.crumble
                    let elapsed = progress - reached - delay
                    guard elapsed > 0 else { continue }
                    // against this dot's own remaining time, so every dot is
                    // spent exactly at progress 1
                    let travel = min(1, elapsed / max(0.01, 1 - reached - delay))
                    guard travel < 1 else { continue }

                    let start = CGPoint(
                        x: letter.x + random(index, dot, 2) * letter.width,
                        y: baseline + (random(index, dot, 3) - 0.5) * fontSize * 0.9)
                    // rightward, with a little lift and spread
                    let distance = Self.drift * (0.45 + random(index, dot, 4) * 0.55)
                    let rise = (random(index, dot, 5) - 0.35) * fontSize * 1.6
                    let point = CGPoint(
                        x: start.x + distance * eased(travel),
                        y: start.y + rise * travel)

                    let radius = (0.42 + random(index, dot, 6) * 0.68) * (1 - travel * 0.5)
                    // holds its brightness while it's still recognisably part
                    // of the word, then goes quickly
                    let fade = 1 - travel * travel * travel
                    context.fill(
                        Path(
                            ellipseIn: CGRect(
                                x: point.x - radius, y: point.y - radius,
                                width: radius * 2, height: radius * 2)),
                        with: .color(colour.opacity(Double(fade))))
                }
            }
        }
    }

    private func draw(
        _ letter: (character: Character, x: CGFloat, width: CGFloat),
        in context: inout GraphicsContext, at baseline: CGFloat,
        opacity: Double, colour: Color
    ) {
        guard opacity > 0.01 else { return }
        var layer = context
        layer.opacity = opacity
        layer.draw(
            Text(String(letter.character))
                .font(.system(size: fontSize))
                .foregroundStyle(colour),
            at: CGPoint(x: letter.x, y: baseline), anchor: .leading)
    }

    /// when the wave reaches this letter — evenly across the name, so the
    /// dissolution reads as one edge sweeping right
    private func waveHit(index: Int) -> CGFloat {
        let count = max(letters.count - 1, 1)
        return (CGFloat(index) / CGFloat(count)) * Self.spread
    }

    /// quick off the mark, then coasting — dust doesn't accelerate
    private func eased(_ value: CGFloat) -> CGFloat { 1 - pow(1 - value, 2) }

    /// deterministic per-particle noise in 0..<1: a name always crumbles the
    /// same way
    private func random(_ a: Int, _ b: Int, _ salt: Int) -> CGFloat {
        var h = UInt64(bitPattern: Int64(a &* 73_856_093 ^ b &* 19_349_663 ^ salt &* 83_492_791))
        h ^= h >> 33
        h = h &* 0xff51_afd7_ed55_8ccd
        h ^= h >> 29
        return CGFloat(h % 1000) / 1000
    }
}
