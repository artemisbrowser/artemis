// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import SwiftUI

/// the first-run intro and setup cards, shown once on a fresh install
enum Onboarding {
    fileprivate static let doneKey = "onboarded"

    /// read once before anything saves a session; `-onboarded NO` forces it.
    /// the key is false while it shows, so a quit part-way through shows it again
    fileprivate(set) static var isDue: Bool = {
        guard !SelfTest.isRequested, !AppStorageLocation.isExtensionLab else { return false }
        let defaults = UserDefaults.standard, done = defaults.object(forKey: doneKey) == nil ? nil : defaults.bool(forKey: doneKey)
        let shows = due(done: done, hasSession: FileManager.default.fileExists(atPath: SessionStore.fileURL.path))
        if done == nil { defaults.set(!shows, forKey: doneKey) }
        return shows
    }()

    /// unfinished, or never begun on a Mac with no saved session yet
    static func due(done: Bool?, hasSession: Bool) -> Bool {
        done.map { !$0 } ?? !hasSession
    }

    private static weak var owner: TabManager?
    /// the manager whose window plays it again, as Settings asks
    static let replay = Replay()

    @Observable
    final class Replay {
        weak var target: TabManager?
    }

    /// whether `manager`'s window shows it: the first main window to ask
    static func claims(_ manager: TabManager) -> Bool {
        guard isDue, manager.kind == .main else { return false }
        if owner == nil { owner = manager }
        return owner === manager
    }
}

/// the onboarding over the first window, until it finishes
struct OnboardingOverlay: View {
    @Environment(TabManager.self) private var tabManager
    @State private var isShowing = true

    var body: some View {
        let replays = Onboarding.replay.target === tabManager
        if replays || isShowing && Onboarding.claims(tabManager) {
            OnboardingView(isReplay: replays) {
                if Onboarding.replay.target === tabManager { Onboarding.replay.target = nil }
                if Onboarding.claims(tabManager) {
                    UserDefaults.standard.set(true, forKey: Onboarding.doneKey)
                    Onboarding.isDue = false
                }
                isShowing = false
                if tabManager.selectedTab?.url == nil { tabManager.openNewTabBar() }
            }
            // the launch's blank tab opens ⌘T; it waits until the onboarding ends
            .onChange(of: tabManager.isCommandBarVisible, initial: true) { _, shown in
                if shown { tabManager.isCommandBarVisible = false }
            }
        }
    }
}

/// the intro's clock and progress, shared by the browser window and the full-screen cover it opens in
@Observable
private final class IntroShow {
    enum Phase { case intro, cards, leaving }

    var phase = Phase.intro
    var startedAt: Date?
    /// the mark and its light, until the setup cards replace them
    var isMarked = true
    var isMuted = false {
        didSet { sound.isMuted = isMuted }
    }
    let sound = IntroSound()
    /// the A blurred for the comet's glass, and the colour it was rendered in
    @ObservationIgnored fileprivate var frosted: (base: Color, image: Image?)?
    /// the borderless window over the whole screen the intro plays in, until it lands on `browser`
    private(set) var cover: NSWindow?
    /// the browser window's frame in the cover's points, and how far the sky has shrunk onto it, 0 to 1
    private(set) var landingRect: CGRect?
    private(set) var landed = 0.0
    @ObservationIgnored private weak var browser: NSWindow?

    /// the music begins, the screen fades to night, the A forms and the comet sweeps round it, then the sky shrinks onto the window
    /// over another app or under VoiceOver it goes straight to the cards
    func play(over window: NSWindow, reduceMotion: Bool) async throws {
        guard phase == .intro else { return }
        if reduceMotion {
            startedAt = Date(timeIntervalSinceNow: -IntroBeat.title - 2)
            try await Task.sleep(for: .seconds(2.5))
            return begin(quietly: false)
        }
        guard let screen = window.screen, NSApp.isActive, !NSWorkspace.shared.isVoiceOverEnabled else {
            window.alphaValue = 1
            return begin(quietly: false)
        }
        let cover = IntroCover(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        cover.isOpaque = false
        cover.backgroundColor = .clear
        cover.hasShadow = false
        cover.isMovable = false
        cover.isReleasedWhenClosed = false
        cover.acceptsMouseMovedEvents = true
        // over the menu bar and the Dock, so the whole screen fades
        cover.level = .popUpMenu
        let host = NSHostingView(rootView: CoverView(show: self))
        host.safeAreaRegions = []
        cover.contentView = host
        cover.alphaValue = 0
        cover.makeKeyAndOrderFront(nil)
        (self.cover, browser) = (cover, window)
        let began = sound.start()
        startedAt = began
        func wait(for beat: Double) async throws {
            try await Task.sleep(for: .seconds(beat - Date().timeIntervalSince(began)))
        }
        try await wait(for: IntroBeat.dawn.lowerBound)
        NSAnimationContext.runAnimationGroup(
            {
                $0.duration = IntroBeat.dawn.upperBound - IntroBeat.dawn.lowerBound
                $0.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                cover.animator().alphaValue = 1
            }, completionHandler: nil)
        try await wait(for: IntroBeat.dawn.upperBound)
        // a replay's window is still on screen until the cover is opaque
        if phase == .intro { window.alphaValue = 0 }
        try await wait(for: IntroBeat.shrink)
        begin(quietly: false)
    }

    /// on to the setup cards: the cover's sky shrinks onto the browser window, which then takes over
    func begin(quietly: Bool) {
        guard phase == .intro else { return }
        if quietly { sound.fadeOut() }
        guard let cover, let browser else {
            return withAnimation(Motion.panel) { (phase, isMarked) = (.cards, false) }
        }
        let frame = browser.frame, screen = cover.frame
        landingRect = CGRect(x: frame.minX - screen.minX, y: screen.maxY - frame.maxY, width: frame.width, height: frame.height)
        withAnimation(Motion.landing) {
            phase = .cards
            landed = 1
        } completion: {
            browser.alphaValue = 1
            browser.makeKeyAndOrderFront(nil)
            cover.close()
            withAnimation(Motion.panel) { (self.cover, self.isMarked) = (nil, false) }
        }
    }

    func end() {
        if phase == .intro { sound.fadeOut(over: 0.2) }
        browser?.alphaValue = 1
        cover?.close()
        cover = nil
    }
}

/// keeps the browser window unseen from its first frame, until the intro lands on it
private struct HiddenWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Hider() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class Hider: NSView {
        override func viewWillMove(toWindow window: NSWindow?) {
            super.viewWillMove(toWindow: window)
            window?.alphaValue = 0
        }
    }
}

private final class IntroCover: NSWindow {
    override var canBecomeKey: Bool { true }
}

/// the cover's content: the stage filling the screen, then shrinking onto the browser window
private struct CoverView: View {
    let show: IntroShow

    var body: some View {
        GeometryReader { geometry in
            Landing(show: show, landed: show.landed, screen: geometry.size)
        }
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
    }
}

/// the stage laid out afresh each frame of the landing, so all it draws stays centred on the shrinking sky
private struct Landing: View, Animatable {
    let show: IntroShow
    var landed: Double
    let screen: CGSize

    var animatableData: Double {
        get { landed }
        set { landed = newValue }
    }

    var body: some View {
        let to = show.landingRect ?? CGRect(origin: .zero, size: screen), k = CGFloat(landed)
        let rect = CGRect(x: to.minX * k, y: to.minY * k, width: screen.width + (to.width - screen.width) * k, height: screen.height + (to.height - screen.height) * k)
        ZStack {
            IntroStage(show: show, isCovered: false)
            IntroChrome(show: show) { show.begin(quietly: true) }
                .opacity(show.phase == .intro ? 1 : 0)
        }
        .frame(width: rect.width, height: rect.height)
        .clipShape(.rect(cornerRadius: WindowChrome.outerWindowRadius * min(1, k)))
        .offset(x: rect.minX, y: rect.minY)
    }
}

/// the browser window's part: the intro itself under Reduce Motion, then the setup cards over the same sky
private struct OnboardingView: View {
    let isReplay: Bool
    let finish: () -> Void
    @Environment(TabManager.self) private var tabManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var show = IntroShow()

    var body: some View {
        ZStack {
            IntroStage(show: show, isCovered: show.cover != nil)
            if show.cover == nil {
                if show.phase == .intro {
                    IntroChrome(show: show) { show.begin(quietly: true) }
                } else {
                    OnboardingCards(profile: tabManager.currentProfile, isReplay: isReplay, finish: leave)
                        .transition(Motion.grow(from: 0.94))
                }
            }
        }
        .environment(\.colorScheme, .dark)
        .opacity(show.phase == .leaving ? 0 : 1)
        .scaleEffect(show.phase == .leaving && !reduceMotion ? 1.04 : 1)
        .background {
            if !reduceMotion, !isReplay, show.phase == .intro { HiddenWindow() }
        }
        // the window registers a few runloop turns after this view appears
        .task(id: BrowserWindows.shared.window(of: tabManager)) {
            OnboardingCards.lookForBrowsers()
            guard let window = BrowserWindows.shared.window(of: tabManager) else { return }
            try? await show.play(over: window, reduceMotion: reduceMotion)
        }
        // the cover sits over every app, so it lands once another comes forward
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            show.begin(quietly: true)
        }
        .onDisappear { show.end() }
    }

    private func leave() {
        guard show.phase != .leaving else { return }
        withAnimation(.easeIn(duration: 0.5)) { show.phase = .leaving }
        Task {
            try? await Task.sleep(for: .seconds(0.55))
            finish()
        }
    }
}

/// the night sky, and over it the A's glass, the comet and the title while the intro plays
private struct IntroStage: View {
    let show: IntroShow
    /// the browser window under the cover, whose sky holds still
    let isCovered: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(AppIconChoice.storageKey) private var icon = AppIconChoice.bundled

    var body: some View {
        GeometryReader { geometry in
            let stage = Stage(geometry.size), intro = show.phase == .intro, tint = icon.glyph
            TimelineView(
                .animation(
                    minimumInterval: intro || show.cover != nil && !isCovered ? nil : 1.0 / 30,
                    paused: show.phase == .leaving || reduceMotion || (intro && isCovered))
            ) { context in
                let t = show.startedAt.map { context.date.timeIntervalSince($0) } ?? 0
                let field = Sky.field(at: t), frost = IntroGlass.frost(base: tint.base, for: show)
                ZStack {
                    IntroSky(
                        centre: stage.centre, zoom: Sky.zoom(at: t),
                        nebulae: [
                            .init(colour: tint.base.mix(with: .black, by: 0.3), at: UnitPoint(x: 0.78, y: 0.2), reach: 0.62, strength: 0.2 * field),
                            .init(colour: tint.light, at: UnitPoint(x: 0.18, y: 0.88), reach: 0.5, strength: 0.11 * field),
                        ],
                        glow: (tint.light, stage.side * 0.95, 0.2 * Sky.formed(at: t)), marked: show.isMarked ? 1 : 0)
                    Canvas { sky, size in Sky.draw(in: sky, size: size, at: t, stage: stage) }
                        .contentShape(Rectangle())
                        .gesture(WindowDragGesture())
                    Canvas { sky, _ in
                        IntroArms.drawGhosts(in: sky, at: t, stage: stage, tint: tint.light)
                        IntroGlass.draw(in: sky, at: t, stage: stage, glyph: tint, frost: frost)
                        Sky.drawLight(in: sky, at: t, stage: stage, light: tint.light)
                    }
                    .allowsHitTesting(false)
                    .opacity(show.isMarked ? 1 : 0)
                }
            }
        }
    }
}

/// the A and the comet as the dark icon renders their glass: a dark edge, the colour, a rim lit from the top left, and
/// the A frosted where the comet crosses it
private enum IntroGlass {
    private static let edge = Color.black.opacity(0.6)

    /// the A's colour from its top to its feet
    private static func shade(_ base: Color) -> Gradient {
        Gradient(colors: [base.mix(with: .black, by: 0.15, in: .device), base.mix(with: Color(white: 0.34), by: 0.6, in: .device)])
    }

    /// the whole A blurred as the comet's glass shows it, rendered once, framed from -30 to 1054 in the icon's space
    static func frost(base: Color, for show: IntroShow) -> Image? {
        if let frosted = show.frosted, frosted.base == base { return frosted.image }
        let side = 340.0, place = CGAffineTransform(scaleX: side / 1024, y: side / 1024).translatedBy(x: 30, y: 30)
        let renderer = ImageRenderer(
            content: Canvas { context, _ in
                context.addFilter(.blur(radius: side / 102.4))
                context.fill(
                    IntroArms.whole.applying(place),
                    with: .linearGradient(shade(base), startPoint: CGPoint(x: 512, y: 266).applying(place), endPoint: CGPoint(x: 512, y: 819).applying(place)))
            }
            .frame(width: side * 1084 / 1024, height: side * 1084 / 1024))
        renderer.scale = 2
        let image = renderer.cgImage.map { Image(decorative: $0, scale: 2) }
        show.frosted = (base, image)
        return image
    }

    static func draw(in sky: GraphicsContext, at t: Double, stage: Stage, glyph: (light: Color, base: Color), frost: Image?) {
        let screen = stage.icon(), k = stage.side / 1024
        typealias Arm = (i: Int, u: Double, place: CGAffineTransform, path: Path, depth: Double)
        var arms = (0..<2).compactMap { i -> Arm? in
            let u = IntroArms.flown(i, at: t), pose = IntroArms.pose(i, u), place = pose.transform.concatenating(screen)
            return u > 0 ? (i, u, place, IntroArms.outlines[i].applying(place), pose.depth) : nil
        }
        guard !arms.isEmpty else { return }
        let comet = MarkPart(isComet: true, sweep: IntroComet.swept(at: t))
            .path(in: CGRect(x: stage.centre.x - stage.side / 2, y: stage.centre.y - stage.side / 2, width: stage.side, height: stage.side))
        let shade = shade(glyph.base)
        let lit = Gradient(colors: [.white.opacity(0.5), .white.opacity(0.075)])
        if arms.count == 2, min(arms[0].u, arms[1].u) >= 1 { arms = [(2, 1, screen, IntroArms.whole.applying(screen), 1)] }
        var bare = sky
        if !comet.isEmpty { bare.clip(to: comet, options: .inverse) }

        /// an arm's edges, none where it lies on the other arm, so the two read as one
        func edges(_ arm: Arm, _ draw: (GraphicsContext) -> Void) {
            var outside = bare
            outside.opacity = IntroBeat.ease(0, 0.1, arm.u)
            if let other = arms.first(where: { $0.i != arm.i }) { outside.clip(to: other.path, options: .inverse) }
            draw(outside)
        }
        for arm in arms {
            edges(arm) { $0.stroke(arm.path, with: .color(edge), lineWidth: 4 * k / arm.depth) }
        }
        var colour = bare
        colour.opacity = 0.92
        colour.drawLayer { layer in
            for arm in arms {
                var fill = layer
                fill.opacity = IntroBeat.ease(0, 0.1, arm.u)
                fill.fill(
                    arm.path,
                    with: .linearGradient(shade, startPoint: CGPoint(x: 512, y: 266).applying(arm.place), endPoint: CGPoint(x: 512, y: 819).applying(arm.place)))
            }
        }
        for arm in arms {
            edges(arm) { context in
                var rim = context
                rim.clip(to: arm.path)
                rim.stroke(
                    arm.path,
                    with: .linearGradient(lit, startPoint: CGPoint(x: 250, y: 180).applying(arm.place), endPoint: CGPoint(x: 800, y: 850).applying(arm.place)),
                    lineWidth: 5 * k / arm.depth)
            }
        }

        guard !comet.isEmpty else { return }
        sky.stroke(comet, with: .color(edge), lineWidth: 4 * k)
        var inside = sky
        inside.clip(to: comet)
        if let frost {
            var frosted = inside
            frosted.opacity = 0.92
            let side = stage.side * 1084 / 1024
            frosted.draw(frost, in: CGRect(x: stage.centre.x - side / 2, y: stage.centre.y - side / 2, width: side, height: side))
        }
        let fade = Gradient(stops: [(0.05, 0.25), (0.45, 0.45), (0.7, 0.5), (0.95, 1)].map { Gradient.Stop(color: glyph.light.opacity($0.1), location: $0.0) })
        inside.fill(comet, with: .linearGradient(fade, startPoint: stage.point(CGPoint(x: 82, y: 614)), endPoint: stage.point(CGPoint(x: 922, y: 410))))
        inside.stroke(
            comet, with: .linearGradient(Gradient(colors: [.white.opacity(0.8), .white.opacity(0.05)]), startPoint: stage.point(CGPoint(x: 600, y: 300)), endPoint: stage.point(CGPoint(x: 650, y: 700))),
            lineWidth: 5 * k)
    }
}

/// mute and Skip Intro, pills along the bottom that show for a moment whenever the mouse moves or a key is pressed;
/// held Esc fills Skip Intro and skips once it is full
private struct IntroChrome: View {
    let show: IntroShow
    let skip: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var stirs = 0
    @State private var isAwake = false
    @State private var isHovered = false
    /// how long Esc has been held, 0 to 1 over the second it takes to skip
    @State private var held = 0.0
    @State private var hold: Task<Void, Never>?
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 12) {
            if !reduceMotion {
                Button {
                    withAnimation { show.isMuted.toggle() }
                } label: {
                    Image(systemName: show.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .contentTransition(.symbolEffect(.replace.magic(fallback: .replace)))
                        .frame(width: 22)
                }
                .accessibilityLabel(show.isMuted ? "Unmute" : "Mute")
                .buttonBorderShape(.circle)
            }
            Button("Skip Intro", action: skip)
                .buttonBorderShape(.capsule)
                .overlay { HoldFill(progress: held) }
        }
        .buttonStyle(.glass)
        .controlSize(.extraLarge)
        .onHover { isHovered = $0 }
        .padding(.bottom, 40)
        .opacity(isAwake && show.phase != .leaving ? 1 : 0)
        .animation(.easeInOut(duration: 0.3), value: isAwake)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .task(id: stirs) {
            guard stirs > 0 else { return }
            isAwake = true
            repeat { try? await Task.sleep(for: .seconds(2.5)) } while (isHovered || hold != nil) && !Task.isCancelled
            if !Task.isCancelled { isAwake = false }
        }
        .onAppear {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .keyDown, .keyUp, .leftMouseDown, .scrollWheel]) { event in
                let isKey = event.type == .keyDown || event.type == .keyUp
                if event.type != .keyUp { stirs += 1 }
                guard isKey, event.keyCode == 53, show.phase == .intro else { return event }
                if event.type == .keyUp {
                    hold?.cancel()
                    hold = nil
                    withAnimation(.easeOut(duration: 0.3)) { held = 0 }
                } else if !event.isARepeat {
                    withAnimation(.linear(duration: 1)) { held = 1 }
                    hold = Task {
                        try? await Task.sleep(for: .seconds(1))
                        if !Task.isCancelled { skip() }
                    }
                }
                return nil
            }
        }
        .onDisappear { monitor.map(NSEvent.removeMonitor) }
    }
}

/// grainy frost filling a pill from its leading edge, `progress` of the way across, brightest at the front and
/// throwing off specks
private struct HoldFill: View, Animatable {
    var progress: Double
    /// how far the specks fly past the pill, in points
    private static let spray = 28.0
    /// white, each pixel a random opacity
    private static let grain: CGImage = {
        var random = Mulberry(seed: 7)
        var pixels = (0..<96 * 96).flatMap { _ in Array(repeating: UInt8(255 * pow(random.next(), 1.5)), count: 4) }
        return pixels.withUnsafeMutableBytes {
            CGContext(
                data: $0.baseAddress, width: 96, height: 96, bitsPerComponent: 8, bytesPerRow: 96 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        }
    }()

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        TimelineView(.animation(paused: progress == 0)) { context in
            Canvas { canvas, size in
                let t = context.date.timeIntervalSinceReferenceDate, pad = Self.spray
                let pill = CGRect(x: pad, y: pad, width: size.width - 2 * pad, height: size.height - 2 * pad)
                let front = pill.minX + pill.width * progress, shown = min(1, progress * 6)
                guard progress > 0.002 else { return }
                var frost = canvas
                frost.clip(to: Capsule().path(in: pill))
                frost.blendMode = .plusLighter
                frost.drawLayer { layer in
                    layer.drawLayer { soft in
                        soft.addFilter(.blur(radius: 3))
                        soft.fill(
                            Path(CGRect(x: 0, y: 0, width: front, height: size.height)),
                            with: .linearGradient(
                                Gradient(stops: [.init(color: .white.opacity(0.1), location: 0), .init(color: .white.opacity(0.3), location: 0.8), .init(color: .white.opacity(0.7), location: 1)]),
                                startPoint: CGPoint(x: pill.minX, y: 0), endPoint: CGPoint(x: front, y: 0)))
                    }
                    var random = Mulberry(seed: UInt32(Int(t * 24) % 100_000))
                    var punch = layer
                    punch.blendMode = .destinationOut
                    punch.fill(
                        Path(CGRect(origin: .zero, size: size)),
                        with: .tiledImage(Image(decorative: Self.grain, scale: 2), origin: CGPoint(x: 48 * random.next(), y: 48 * random.next())))
                }
                // a speck every 6 ms, each flying 0.6 s from the front
                var specks = canvas
                specks.blendMode = .plusLighter
                for k in 0..<100 {
                    let index = Int(t / 0.006) - k, age = t - Double(index) * 0.006, life = age / 0.6
                    var random = Mulberry(seed: UInt32(truncatingIfNeeded: index &* 7919 &+ 3))
                    let angle = (random.next() - 0.5) * 2.6, speed = 20 + 70 * random.next(), y = pill.minY + pill.height * (0.1 + 0.8 * random.next())
                    let travel = speed * age * (1 - 0.5 * life), r = 0.35 + 0.7 * random.next()
                    let at = CGPoint(x: front + cos(angle) * travel, y: y + sin(angle) * travel)
                    specks.fill(
                        Path(ellipseIn: CGRect(x: at.x - r, y: at.y - r, width: 2 * r, height: 2 * r)),
                        with: .color(.white.opacity(shown * pow(1 - life, 1.5) * (0.35 + 0.65 * random.next()))))
                }
            }
        }
        .padding(-Self.spray)
        .allowsHitTesting(false)
    }
}

/// where the intro's mark sits on the stage: its centre and side, in points
private struct Stage {
    let centre: CGPoint
    let side: CGFloat
    /// the screen's own middle, a little below the mark's
    let middle: CGPoint

    init(_ size: CGSize) {
        side = min(340, max(150, min(size.width, size.height) * 0.3))
        centre = CGPoint(x: size.width / 2, y: size.height * 0.42)
        middle = CGPoint(x: size.width / 2, y: size.height / 2)
    }

    /// the icon's 1024-point space on screen
    func icon() -> CGAffineTransform {
        CGAffineTransform(translationX: -512, y: -512)
            .concatenating(CGAffineTransform(scaleX: side / 1024, y: side / 1024))
            .concatenating(CGAffineTransform(translationX: centre.x, y: centre.y))
    }

    func point(_ p: CGPoint) -> CGPoint { p.applying(icon()) }
}

/// 1 at `start`, decaying by e every `decay` seconds after
private func pulse(_ t: Double, _ start: Double, _ decay: Double) -> Double {
    t < start ? 0 : exp(-(t - start) / decay)
}

/// mulberry32
private struct Mulberry {
    var seed: UInt32

    mutating func next() -> Double {
        seed &+= 0x6D2B_79F5
        var x = (seed ^ (seed >> 15)) &* (seed | 1)
        x = (x &+ ((x ^ (x >> 7)) &* (x | 61))) ^ x
        return Double(x ^ (x >> 14)) / 4_294_967_296
    }
}

/// the A's two arms, each appearing behind the viewer on its beat and flying out to its place, the right one onto the left
private enum IntroArms {
    private static let apex = CGPoint(x: 512, y: 262), feet = [CGPoint(x: 268.1, y: 762), CGPoint(x: 755.9, y: 762)]
    /// each arm in glass, foot to apex, in the icon's space
    static let outlines = feet.map { foot in
        Path { $0.addLines([foot, apex]) }.strokedPath(StrokeStyle(lineWidth: 162, lineCap: .round))
    }
    /// the A they make in place, with no seam where they meet
    static let whole = outlines[0].union(outlines[1])
    /// where each sets off from, in icon points beside and behind the viewer, and its roll there
    private static let starts = [(CGSize(width: -220, height: 260), -0.6), (CGSize(width: 220, height: 260), 0.6)]
    private static let flight = 1.1
    static let joined = IntroBeat.arms[1] + flight

    static func flown(_ i: Int, at t: Double) -> Double {
        IntroBeat.ramp(IntroBeat.arms[i], IntroBeat.arms[i] + flight, t)
    }

    /// arm `i` `u` of the way out: its depth, 0.08 near the viewer to 1 in place, and where that puts it in the icon's space
    static func pose(_ i: Int, _ u: Double) -> (depth: Double, transform: CGAffineTransform) {
        let v = 1 - pow(1 - u, 2.2), depth = 0.08 + 0.92 * v, (from, roll) = starts[i]
        let middle = CGPoint(x: (feet[i].x + apex.x) / 2, y: (feet[i].y + apex.y) / 2)
        let x = 512 + (middle.x + from.width * (1 - v) - 512) / depth, y = 512 + (middle.y + from.height * (1 - v) - 512) / depth
        let transform = CGAffineTransform(translationX: -middle.x, y: -middle.y)
            .concatenating(CGAffineTransform(rotationAngle: roll * (1 - v)))
            .concatenating(CGAffineTransform(scaleX: 1 / depth, y: 1 / depth))
            .concatenating(CGAffineTransform(translationX: x, y: y))
        return (depth, transform)
    }

    /// the faint copies trailing each arm in flight
    static func drawGhosts(in sky: GraphicsContext, at t: Double, stage: Stage, tint: Color) {
        let screen = stage.icon()
        for i in 0..<2 {
            let landing = 1 - IntroBeat.ease(0.85, 1, flown(i, at: t))
            for k in 1...3 {
                let u = flown(i, at: t) - 0.035 * Double(k)
                guard u > 0, landing > 0 else { continue }
                let ghost = outlines[i].applying(pose(i, u).transform.concatenating(screen)), alpha = landing * IntroBeat.ease(0, 0.1, u) * 0.22 * (1 - Double(k) / 4)
                sky.fill(ghost, with: .color(tint.opacity(0.35 * alpha)))
                sky.stroke(ghost, with: .color(.white.opacity(0.6 * alpha)), lineWidth: 1)
            }
        }
    }
}

/// the comet: from far back in the sky towards the A, down its left side onto its orbit, then a swoosh round it that
/// draws the icon's comet
private enum IntroComet {
    /// how far off it sets out, as a multiple of its distance at the A
    private static let far = 15.0
    /// setting off on bar 6, onto the orbit just before the swoosh
    private static let setOff = 13.2, onOrbit = IntroBeat.reveal - 0.35
    private static let route = [CGPoint(x: 760, y: -300), CGPoint(x: 250, y: -520), CGPoint(x: -175, y: -97), orbit(3.0)]

    private static func orbit(_ angle: Double) -> CGPoint {
        let (centre, radius) = MarkPart.orbit
        return CGPoint(x: centre.x + radius * cos(angle), y: centre.y + radius * sin(angle))
    }

    private static func depth(at t: Double) -> Double {
        t >= onOrbit ? 1 : far + (1 - far) * IntroBeat.ramp(setOff, onOrbit, t)
    }

    /// 0 far off to 1 at the A, in step with its apparent size
    static func nearness(at t: Double) -> Double {
        (1 / depth(at: t) - 1 / far) / (1 - 1 / far)
    }

    /// the share of the icon's comet the swoosh has drawn
    static func swept(at t: Double) -> Double {
        IntroBeat.ramp(IntroBeat.reveal, IntroBeat.reveal + 0.6, t)
    }

    /// its head in the icon's space: along the route as it nears, then round the orbit onto the sweep's start by the
    /// reveal and on round to its end
    static func head(at t: Double) -> CGPoint {
        let (from, to) = MarkPart.sweepAngles
        guard t < onOrbit else {
            return orbit(t >= IntroBeat.reveal ? from + (to - from) * swept(at: t) : 3 + (from - 3) * IntroBeat.ramp(onOrbit, IntroBeat.reveal, t))
        }
        let s = nearness(at: t), u = 1 - s, weights = [u * u * u, 3 * u * u * s, 3 * u * s * s, s * s * s]
        return CGPoint(
            x: zip(weights, route).reduce(0) { $0 + $1.0 * $1.1.x }, y: zip(weights, route).reduce(0) { $0 + $1.0 * $1.1.y })
    }

    /// faded in as it sets off; the head goes once the swoosh is through
    static func showing(at t: Double) -> Double {
        IntroBeat.ease(setOff - 0.2, setOff + 1.5, t) * (1 - IntroBeat.ramp(IntroBeat.reveal + 0.5, IntroBeat.reveal + 0.75, t))
    }

    /// a tapering ribbon along the head's real path, wider and longer as it nears, shedding dust that drifts and dims
    static func draw(in sky: GraphicsContext, at t: Double, stage: Stage, light: Color) {
        let shown = showing(at: t)
        guard shown > 0.002 else { return }
        let near = 1 / depth(at: t), count = 64, span = 0.5 + 5 * (1 - near), width = 1.5 + 9 * near
        let trail = (0...count).map { stage.point(head(at: t - span * Double($0) / Double(count))) }
        var glow = sky
        glow.blendMode = .plusLighter
        let ribbon: [(Double, Color, Double)] = [(6, light, 0.05), (3.5, light, 0.09), (2, light, 0.2), (1, light.mix(with: .white, by: 0.6), 0.45), (0.45, .white, 0.9)]
        for (thickness, colour, alpha) in ribbon {
            for k in 0..<count {
                let p = trail[k], q = trail[k + 1], f = Double(k) / Double(count)
                guard abs(p.x - q.x) + abs(p.y - q.y) >= 0.05 else { continue }
                glow.stroke(
                    Path { $0.addLines([p, q]) }, with: .color(colour.opacity(alpha * shown * pow(1 - f, 1.8))),
                    lineWidth: width * thickness * pow(1 - f, 0.7))
            }
        }
        for k in stride(from: 0, to: count * 3 / 5, by: 6) {
            let f = Double(k) / Double(count)
            Sky.glow(in: sky, at: trail[k], radius: width * 5 * (1 - f), colour: light, alpha: 0.12 * shown * (1 - f) * (1 - f))
        }
        // a speck every 25 ms, each living 2 s
        for k in 0..<80 {
            let index = Int(t / 0.025) - k, shed = Double(index) * 0.025, age = t - shed, lit = showing(at: shed)
            guard lit > 0.002 else { continue }
            var random = Mulberry(seed: UInt32(truncatingIfNeeded: index &* 7919 &+ 13))
            let direction = 2 * .pi * random.next(), nearThen = 1 / depth(at: shed), speed = (10 + 50 * random.next()) * nearThen
            let size = random.next(), from = head(at: shed)
            let at = stage.point(CGPoint(x: from.x + cos(direction) * speed * age, y: from.y + sin(direction) * speed * age))
            let r = 0.5 + 1.4 * size * nearThen
            glow.fill(
                Path(ellipseIn: CGRect(x: at.x - r, y: at.y - r, width: 2 * r, height: 2 * r)),
                with: .color((size > 0.6 ? .white : light).opacity(lit * nearThen * pow(1 - age / 2, 2) * (0.3 + 0.7 * size))))
        }
        Sky.glow(in: sky, at: trail[0], radius: 8 + 56 * near, colour: light, alpha: 0.55 * shown * (0.4 + 0.6 * near))
        Sky.glow(in: sky, at: trail[0], radius: 2.5 + 14 * near, colour: .white, alpha: shown)
    }
}

/// the night sky: nebula in the icon's colours, stars filling in brightest first and a camera pushing in on the mark
private enum Sky {
    private struct Star {
        let x, y, depth, brightness, phase, rate, appear: Double
        let isWarm: Bool
    }

    /// the stars, then the faint dust behind them in bands of brightness, each speck a share of the screen and a side in points
    private static let scatter: (stars: [Star], dust: [(alpha: Double, specks: [(x: Double, y: Double, side: Double)])]) = {
        var random = Mulberry(seed: 1969)
        let stars = (0..<340).map { _ in
            let x = random.next(), y = random.next(), depth = pow(random.next(), 1.6), brightness = 0.25 + 0.75 * random.next()
            let phase = 2 * .pi * random.next(), rate = 0.3 + 0.9 * random.next(), isWarm = random.next() < 0.3
            let appear = 1.5 + 11.5 * min(1, 0.7 * (1 - brightness) / 0.75 + 0.3 * random.next())
            return Star(x: x, y: y, depth: depth, brightness: brightness, phase: phase, rate: rate, appear: appear, isWarm: isWarm)
        }
        var bands = Array(repeating: [(x: Double, y: Double, side: Double)](), count: 8)
        for _ in 0..<1600 {
            let x = random.next(), y = random.next(), band = min(7, Int(8 * pow(random.next(), 2)))
            bands[band].append((x, y, 0.5 + 0.5 * random.next()))
        }
        return (stars, bands.enumerated().map { (0.06 + 0.22 * (Double($0.offset) + 0.5) / 8, $0.element) })
    }()

    /// the A, and the band round its edge that the comet's light catches, in the icon's space
    private static let a = Path { $0.addLines([CGPoint(x: 268.1, y: 762), CGPoint(x: 512, y: 262), CGPoint(x: 755.9, y: 762)]) }
    private static let rim = a.strokedPath(StrokeStyle(lineWidth: 162, lineCap: .round, lineJoin: .round))
        .subtracting(a.strokedPath(StrokeStyle(lineWidth: 148, lineCap: .round, lineJoin: .round)))

    static func zoom(at t: Double) -> Double {
        1 + 0.12 * IntroBeat.ease(IntroBeat.dawn.lowerBound, IntroBeat.reveal + 2, t)
    }

    /// how far the sky has filled in, stars and nebulae
    static func field(at t: Double) -> Double {
        0.25 + 0.65 * IntroBeat.ease(2, 16, t)
    }

    /// as the swoosh draws the comet, the glow rising behind the A
    static func formed(at t: Double) -> Double {
        IntroBeat.ease(IntroBeat.reveal - 0.1, IntroBeat.reveal + 0.6, t)
    }

    /// the stars and dust over `IntroSky` at `t`
    static func draw(in sky: GraphicsContext, size: CGSize, at t: Double, stage: Stage) {
        var sky = sky
        let zoom = zoom(at: t), field = field(at: t)
        sky.translateBy(x: stage.centre.x, y: stage.centre.y)
        sky.scaleBy(x: zoom, y: zoom)
        sky.translateBy(x: -stage.centre.x, y: -stage.centre.y)
        for star in scatter.stars {
            let alpha =
                field * star.brightness * IntroBeat.ease(star.appear, star.appear + 2, t)
                * (0.75 + 0.25 * sin(2 * .pi * star.rate * t + star.phase))
            guard alpha > 0.002 else { continue }
            let x = (star.x - t * 0.0035 * star.depth).truncatingRemainder(dividingBy: 1)
            let at = CGPoint(x: (x < 0 ? x + 1 : x) * size.width, y: (star.y + t * 0.0012 * star.depth).truncatingRemainder(dividingBy: 1) * size.height)
            let r = 0.35 + 1.1 * star.depth * star.depth
            let colour = star.isWarm ? Color(red: 1, green: 0.93, blue: 0.82) : Color(red: 0.86, green: 0.91, blue: 1)
            sky.fill(Path(ellipseIn: CGRect(x: at.x - r, y: at.y - r, width: 2 * r, height: 2 * r)), with: .color(colour.opacity(alpha)))
        }

        let specks = field * IntroBeat.ease(6, 16, t)
        guard specks > 0 else { return }
        for band in scatter.dust {
            let path = Path { path in
                for speck in band.specks {
                    path.addRect(CGRect(x: speck.x * size.width, y: speck.y * size.height, width: speck.side, height: speck.side))
                }
            }
            sky.fill(path, with: .color(Color(red: 0.8, green: 0.87, blue: 1).opacity(specks * band.alpha)))
        }
    }

    /// over the glass: the comet's light on the A's edge, the comet, the message and the title
    static func drawLight(in sky: GraphicsContext, at t: Double, stage: Stage, light: Color) {
        let reveal = IntroBeat.reveal, formed = formed(at: t)
        if t > IntroArms.joined {
            let lit = IntroComet.nearness(at: t), whole = IntroBeat.ease(IntroArms.joined, reveal, t)
            var edge = sky
            edge.blendMode = .plusLighter
            edge.opacity = min(1, (0.7 * lit * lit * IntroComet.showing(at: t) * whole + 0.6 * pulse(t, reveal, 0.8)) * (1 - 0.5 * formed))
            edge.fill(
                rim.applying(stage.icon()),
                with: .radialGradient(
                    fading(Color(red: 0.88, green: 0.93, blue: 1), 1), center: stage.point(IntroComet.head(at: t)), startRadius: 0,
                    endRadius: (520 + 300 * formed) * stage.side / 1024))
        }
        IntroComet.draw(in: sky, at: t, stage: stage, light: light)

        let (said, unsaid) = (IntroBeat.message.lowerBound, IntroBeat.message.upperBound)
        let say = IntroBeat.ease(said, said + 0.9, t) * (1 - IntroBeat.ease(unsaid - 0.9, unsaid, t))
        if say > 0 {
            var words = sky
            words.opacity = 0.75 * say
            let size = stage.side * 0.055
            words.draw(
                Text("MADE WITH LOVE").font(.system(size: size, weight: .light)).tracking(0.32 * size)
                    .foregroundStyle(Color(red: 0.9, green: 0.93, blue: 1)),
                at: CGPoint(x: stage.middle.x, y: stage.middle.y + 6 * (1 - say)))
        }
        let titled = IntroBeat.ease(IntroBeat.title, IntroBeat.title + 0.9, t)
        if titled > 0 {
            var title = sky
            title.opacity = titled
            title.draw(
                Text("Artemis").font(.system(size: stage.side * 0.15, weight: .semibold)).foregroundStyle(.white),
                at: CGPoint(x: stage.centre.x, y: stage.centre.y + stage.side * 0.64 + 14 * (1 - titled)))
        }
    }

    /// a soft additive glow fading out from `centre`
    static func glow(in sky: GraphicsContext, at centre: CGPoint, radius: Double, colour: Color, alpha: Double) {
        guard alpha > 0.002, radius > 0 else { return }
        var sky = sky
        sky.blendMode = .plusLighter
        sky.fill(
            Path(ellipseIn: CGRect(x: centre.x - radius, y: centre.y - radius, width: 2 * radius, height: 2 * radius)),
            with: .radialGradient(fading(colour, min(1, alpha), core: 0.65), center: centre, startRadius: 0, endRadius: radius))
    }

    /// `colour` from `peak` at the centre to nothing at the edge with no crease for a ring to show at, `core` of it in a
    /// tight bright middle
    private static func fading(_ colour: Color, _ peak: Double, core: Double = 0) -> Gradient {
        Gradient(
            stops: (0...16).map { k in
                let x = Double(k) / 16
                return .init(color: colour.opacity(peak * (core * exp(-x * x / 0.04) + (1 - core) * pow(1 - x * x, 2))), location: x)
            })
    }
}
