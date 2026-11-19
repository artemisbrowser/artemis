// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import Sparkle
import SwiftUI

/// where an update stands, from the check to the relaunch
enum UpdateFlow: Equatable {
    case idle, checking, upToDate
    case available(String)
    /// nil until the server says how much is coming
    case downloading(Double?)
    case preparing(Double)
    case ready(String)
    case installing
    case failed(String)

    /// the press this state waits for, and the sidebar pill's words for it
    var offer: (symbol: String, title: String, pill: String)? {
        switch self {
        case .available: ("arrow.down", "Download", "Update Available")
        case .ready: ("arrow.clockwise", "Relaunch", "Relaunch to Update")
        case .failed: ("arrow.clockwise", "Try Again", "Update Failed")
        default: nil
        }
    }

    var title: String? {
        switch self {
        case .idle: nil
        case .checking: "Checking for updates"
        case .upToDate: "Up to date"
        case .available(let version): "Artemis \(version) available"
        case .downloading(let fraction): fraction.map { "Downloading \(Int($0 * 100))%" } ?? "Downloading"
        case .preparing: "Unpacking"
        case .ready(let version): "Artemis \(version) ready"
        case .installing: "Installing"
        case .failed: "Update failed"
        }
    }

    /// the share of the one bar the download fills; unpacking fills the rest
    static let downloadShare = 0.7

    /// how far along from the download's start to ready, while there is an amount to show; it never goes back
    var progress: Double? {
        switch self {
        case .downloading(let fraction): (fraction ?? 0) * Self.downloadShare
        case .preparing(let fraction): Self.downloadShare + min(1, max(0, fraction)) * (1 - Self.downloadShare)
        default: nil
        }
    }

    var isBusy: Bool { self == .checking || self == .installing || progress != nil }

    /// what an animation keys on: every state but a bar's progress, which changes many times a second
    var phase: UpdateFlow? { progress == nil ? self : nil }

    /// worth the sidebar's pill: a press it waits for, or an update on its way
    var showsPill: Bool { offer != nil || isBusy && self != .checking }
}

/// Sparkle behind Artemis's own update UI, for builds that carry a feed; a build
/// without one never updates itself. Scheduled updates download quietly and wait
/// as `.ready`: nothing opens over browsing on its own.
@Observable
final class Updates: NSObject {
    static let shared = Updates()
    /// "beta" adds the beta channel, "nightly" adds beta and nightly; anything else is release only
    static let channelKey = "updateChannel"
    /// the channel tools/release.sh built this for; nil for a local build
    static let buildChannel = (Bundle.main.object(forInfoDictionaryKey: "ArtemisChannel") as? String)
        .flatMap { ["release", "beta", "nightly"].contains($0) ? $0 : nil }
    /// the commit this was built from, without deploy.sh's "-dirty"
    static let buildCommit: String? = {
        let hex = (Bundle.main.object(forInfoDictionaryKey: "ArtemisGitSHA") as? String ?? "")
            .prefix { "0123456789abcdef".contains($0) }
        return hex.count >= 7 ? String(hex) : nil
    }()
    /// the running version as "1.1.0 Beta"; the channel is named only off Release
    static let running: String = {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        return short + (buildChannel.flatMap { $0 == "release" ? nil : " \($0.capitalized)" } ?? "")
    }()

    /// `-previewUpdate ready` at launch: that state with nothing behind it, to see how it looks;
    /// a fraction is a download that far along, `play` one that runs to ready over and over.
    /// Only a launch argument counts, never a value saved in the defaults.
    static var preview: String? {
        UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)["previewUpdate"] as? String
    }

    private(set) var flow: UpdateFlow =
        switch Updates.preview {
        case "checking": .checking
        case "uptodate": .upToDate
        case "available": .available("1.2.0")
        case "downloading": .downloading(0.42)
        case "ready": .ready("1.2.0")
        case "failed": .failed("The update could not be downloaded.")
        case let fraction?: Double(fraction).map { UpdateFlow.downloading($0) } ?? .idle
        default: .idle
        }
    {
        didSet {
            debugLog("update: \(flow)")
            guard oldValue.progress != nil, case .ready = flow else { return }
            let now = Date.now
            finishing = now
            Task {
                try? await Task.sleep(for: .seconds(Self.finish))
                if finishing == now { finishing = nil }
            }
        }
    }
    /// when a download that was showing turned ready, for the `finish` seconds its bar plays that out
    private(set) var finishing: Date?
    static let finish = 0.9
    /// the bar while there is one to draw: the flow's progress, or full while a finish plays out
    var bar: (progress: Double, finishing: Bool)? {
        let finishing = !Motion.reduceMotion && self.finishing != nil
        return flow.progress.map { ($0, finishing) } ?? (finishing ? (1, true) : nil)
    }
    /// Sparkle's open question behind `.available`, and behind a `.ready` the user downloaded
    @ObservationIgnored private var reply: ((SPUUserUpdateChoice) -> Void)?
    /// installs the quietly downloaded update; does nothing once its session ends
    @ObservationIgnored private var install: (() -> Void)?
    @ObservationIgnored private var updater: SPUUpdater?
    @ObservationIgnored private var version = ""
    @ObservationIgnored private var expected: UInt64 = 0
    @ObservationIgnored private var received: UInt64 = 0

    /// fixed by the build, so the menu knows before the updater starts
    let isEnabled = !((Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String) ?? "").isEmpty

    var checksAutomatically: Bool {
        get {
            access(keyPath: \.checksAutomatically)
            return updater?.automaticallyChecksForUpdates ?? false
        }
        set { withMutation(keyPath: \.checksAutomatically) { updater?.automaticallyChecksForUpdates = newValue } }
    }

    /// off, a scheduled check stops at `.available` and waits for a press
    var installsAutomatically: Bool {
        get {
            access(keyPath: \.installsAutomatically)
            return updater?.automaticallyDownloadsUpdates ?? false
        }
        set { withMutation(keyPath: \.installsAutomatically) { updater?.automaticallyDownloadsUpdates = newValue } }
    }

    func start() {
        if let preview = Self.preview {
            if preview == "play" { play() }
            return
        }
        guard isEnabled else { return }
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: self, delegate: self)
        do {
            try updater.start()
            self.updater = updater
        } catch {
            debugLog("updater did not start: \(error)")
        }
    }

    private func play() {
        Task {
            while true {
                for percent in 0...100 {
                    flow = percent < 70 ? .downloading(Double(percent) / 70) : .preparing(Double(percent - 70) / 30)
                    try? await Task.sleep(for: .milliseconds(30))
                }
                flow = .ready("1.2.0")
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    /// the press an offer waits for: download it, or relaunch into it; with no offer, a check
    func act() {
        if let install { return install() }
        if let reply {
            self.reply = nil
            return reply(.install)
        }
        check()
    }

    /// the menu's check: About shows how it goes, and an offer already there keeps waiting for its own press
    func checkNow() {
        SettingsView.open(.about)
        check()
    }

    private func check() {
        switch flow {
        case .idle, .upToDate, .failed: updater?.checkForUpdates()
        default: break
        }
    }

    /// a background check, so leaving or joining Beta doesn't wait for the next schedule
    func channelChanged() {
        guard let updater, !updater.sessionInProgress else { return }
        updater.checkForUpdatesInBackground()
    }

    /// Sparkle's found update in plain values, which the self-test can pose
    func offer(_ version: String, downloaded: Bool, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        self.version = version
        self.reply = reply
        flow = downloaded ? .ready(version) : .available(version)
    }
}

extension Updates: @preconcurrency SPUUpdaterDelegate {
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        switch UserDefaults.standard.string(forKey: Self.channelKey) {
        case "nightly": ["beta", "nightly"]
        case "beta": ["beta"]
        default: []
        }
    }

    func updater(
        _ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock: @escaping () -> Void
    ) -> Bool {
        install = immediateInstallationBlock
        WhatsNew.remember(build: item.versionString, notes: item.itemDescription)
        flow = .ready(item.displayVersionString)
        debugLog("update ready: \(item.displayVersionString) (\(item.versionString))")
        return true
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        dismissUpdateInstallation()
    }
}

extension Updates: @preconcurrency SPUUserDriver {
    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        flow = .checking
    }

    func showUpdateFound(
        with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        WhatsNew.remember(build: appcastItem.versionString, notes: appcastItem.itemDescription)
        offer(appcastItem.displayVersionString, downloaded: state.stage != .notDownloaded, reply: reply)
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        flow = .upToDate
        acknowledgement()
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        flow = .failed(error.localizedDescription)
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        (expected, received) = (0, 0)
        flow = .downloading(nil)
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expected = expectedContentLength
    }

    /// in whole percents, so the bar redraws only when it moves; the server's length can fall short of the data
    func showDownloadDidReceiveData(ofLength length: UInt64) {
        received += length
        let next = UpdateFlow.downloading(
            expected > 0 ? min((Double(received) / Double(expected) * 100).rounded() / 100, 1) : nil)
        if next != flow { flow = next }
    }

    func showDownloadDidStartExtractingUpdate() {
        flow = .preparing(0)
    }

    /// in whole percents, as the download is
    func showExtractionReceivedProgress(_ progress: Double) {
        let next = UpdateFlow.preparing((progress * 100).rounded() / 100)
        if next != flow { flow = next }
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        self.reply = reply
        flow = .ready(version)
    }

    func showInstallingUpdate(
        withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void
    ) {
        flow = .installing
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement()
    }

    /// the session is over: its reply and install block are dead, and only its verdict stays up
    func dismissUpdateInstallation() {
        reply = nil
        install = nil
        switch flow {
        case .upToDate, .failed: break
        default: flow = .idle
        }
    }
}

/// the sidebar footer's word on an update under way; Updates.act does the rest
struct UpdatePill: View {
    @Environment(\.chromeInk) private var ink
    private var flow: UpdateFlow { Updates.shared.flow }

    var body: some View {
        if flow.showsPill {
            Button { Updates.shared.act() } label: {
                Label(flow.offer?.pill ?? flow.title ?? "", systemImage: flow.offer?.symbol ?? "arrow.down")
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(ink.opacity(0.9))
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, minHeight: 28)
                    .background {
                        Group {
                            if let bar = Updates.shared.bar {
                                UpdateBar(progress: bar.progress, finishing: bar.finishing, gap: 4, ink: ink)
                                    .transition(.opacity)
                            }
                        }
                        .animation(Motion.fade, value: Updates.shared.bar == nil)
                    }
                    .chromeGlass(in: .capsule, interactive: true)
                    .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .tooltip(flow.title ?? "")
            .transition(Motion.grow(from: 0.95))
            .animation(Motion.hover, value: flow.phase)
        }
    }
}

/// the Settings toolbar's trailing word on the updater: the running version, or the update on its way
struct UpdateStatus: View {
    private var flow: UpdateFlow { Updates.shared.flow }

    /// the toolbar's capsule is 36pt tall and hugs its item: the bar is half that, a quarter clear on all four sides
    fileprivate static let bar = CGSize(width: 120, height: 18)
    fileprivate static let gap = bar.height / 2

    var body: some View {
        Group {
            if let bar = Updates.shared.bar {
                Color.clear
                    .frame(width: Self.bar.width, height: Self.bar.height)
                    // the tooltip's words become this element's label
                    .accessibilityElement()
                    .padding(Self.gap)
                    .background { UpdateBar(progress: bar.progress, finishing: bar.finishing) }
                    .tooltip(flow.title ?? "")
            } else {
                // the mark stands as tall as the bar and the row keeps the bar's gap from the capsule's ends
                HStack(spacing: 6) {
                    Group {
                        switch flow {
                        case .checking, .installing:
                            // a small spinner is 16pt
                            ProgressView().controlSize(.small).scaleEffect(Self.bar.height / 16)
                                .frame(width: Self.bar.height, height: Self.bar.height)
                        case .upToDate: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        case .available, .ready: Image(systemName: "arrow.down.circle.fill").foregroundStyle(.tint)
                        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        default: EmptyView()
                        }
                    }
                    .font(.system(size: Self.bar.height))
                    // less the symbols' own side bearing
                    .padding(.leading, -1)
                    Text(flow.title ?? "Artemis \(Updates.running)")
                }
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, Self.gap)
            }
        }
        .animation(Motion.hover, value: flow.phase)
        .animation(Motion.fade, value: Updates.shared.bar == nil)
    }
}

/// the update bar drawn as layers the render server animates, so nothing here runs per frame
struct UpdateBar: NSViewRepresentable {
    var progress: Double
    var finishing: Bool
    /// clear room between the bar and the glass round it, on every side
    var gap = UpdateStatus.gap
    /// the chrome's own ink, drawn faint so words read over it; nil is white on dark glass, the accent on light
    var ink: Color?

    func makeNSView(context: Context) -> Layers { Layers(gap: gap) }
    func updateNSView(_ view: Layers, context: Context) {
        view.given = ink.map { NSColor($0).cgColor }
        view.show(progress, finishing: finishing)
    }

    final class Layers: NSView {
        private let gap: CGFloat
        /// the view less `gap` on every side
        private var bar = CGSize.zero
        /// the light's half-lit point sits this far into its layer, all of it lit behind that; the layer ends dark
        private var lit: CGFloat { bar.width + 20 }
        /// how far past its outline the bar grows on every side at the finish
        private var swell: CGFloat { gap / 4 }
        private static let dot = stencil(CGSize(width: 2, height: 2)) { x, y in (1 - hypot(x - 1, y - 1)) * 3 }

        let capsule = CALayer()
        private let lens = CALayer(), glass = CALayer(), light = CALayer(), front = CALayer()
        private let flood = CALayer()
        let dust = CAEmitterLayer()
        /// the finish's dots, each where it comes to rest
        let sparks = CALayer()
        /// the glass capsule the item fills: dust and sparks leave the bar but are never drawn past this
        let glassClip = CALayer()
        private var shown: (progress: Double, finishing: Bool)?
        /// the specks, and the fill unless `given`: white on dark glass, the accent on light
        private var ink = CGColor.white
        var given: CGColor? {
            didSet { if given != oldValue { needsDisplay = true } }
        }

        override var isFlipped: Bool { true }
        override var wantsUpdateLayer: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        init(gap: CGFloat) {
            self.gap = gap
            super.init(frame: .zero)
            wantsLayer = true
            glass.contentsScale = 3
            front.contentsScale = 3
            lens.mask = glass
            light.mask = front
            let mote = CAEmitterCell()
            mote.name = "mote"
            mote.contents = Self.dot
            mote.contentsScale = 3
            mote.birthRate = 14
            mote.lifetime = 0.7
            mote.lifetimeRange = 0.3
            mote.velocity = 26
            mote.velocityRange = 14
            mote.emissionRange = 0.2
            mote.scale = 0.3
            mote.scaleRange = 0.12
            mote.scaleSpeed = 0.15
            mote.alphaRange = 0.2
            mote.alphaSpeed = -0.25
            dust.emitterShape = .rectangle
            dust.emitterCells = [mote]
            lens.addSublayer(light)
            capsule.sublayers = [lens, flood]
            glassClip.masksToBounds = true
            glassClip.sublayers = [sparks, capsule, dust]
            layer?.addSublayer(glassClip)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override func setFrameSize(_ size: NSSize) {
            super.setFrameSize(size)
            let bar = CGSize(width: max(0, size.width - 2 * gap), height: max(0, size.height - 2 * gap))
            guard bar != self.bar else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if bar.height != self.bar.height { cut(bar.height) }
            self.bar = bar
            let whole = CGRect(origin: .zero, size: bar)
            capsule.position = CGPoint(x: size.width / 2, y: size.height / 2)
            lens.frame = whole
            glass.frame = whole
            flood.position = CGPoint(x: bar.width / 2, y: bar.height / 2)
            grow(by: shown?.finishing == true && !Motion.reduceMotion ? swell : 0)
            light.bounds = CGRect(x: 0, y: 0, width: lit + bar.height * 1.1, height: bar.height)
            light.anchorPoint = CGPoint(x: lit / light.bounds.width, y: 0.5)
            light.position.y = bar.height / 2
            front.frame = light.bounds
            dust.frame = whole.offsetBy(dx: gap, dy: gap)
            dust.emitterSize = CGSize(width: bar.height * 2.8, height: bar.height * 1.3)
            glassClip.frame = CGRect(origin: .zero, size: size)
            glassClip.cornerRadius = size.height / 2
            reach(shown?.progress ?? 0, still: true)
            CATransaction.commit()
        }

        /// the glass and front masks for a bar this tall; both stretch along the bar, so no width redraws them
        private func cut(_ high: CGFloat) {
            let radius = high / 2
            // the capsule the light shows through, dimmer at the rim
            glass.contents = Self.stencil(CGSize(width: high + 1, height: high)) { x, y in
                let inside = radius - hypot(min(max(x, radius), radius + 1) - x, y - radius)
                let rise = min(1, inside / 1.8)
                return min(1, inside * 3) * (1 - 0.15 * (1 - rise * rise * (3 - 2 * rise)))
            }
            glass.contentsCenter = CGRect(x: radius / (high + 1), y: 0, width: 1 / (high + 1), height: 1)
            // alpha across the light's front, half lit at `behind`; the rows nearer the rim trail the middle one
            let behind = high * 4, wide = behind + high * 1.1
            front.contents = Self.stencil(CGSize(width: wide, height: high)) { x, y in
                let row = (y - radius) / radius
                return 1.03 / (1 + exp(((x - behind) / high + 0.25 * row * row) / 0.2))
            }
            front.contentsCenter = CGRect(x: 0, y: 0, width: 1 / (wide * 3), height: 1)
        }

        override func updateLayer() {
            let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ink = given ?? (dark ? .white : NSColor.controlAccentColor.cgColor)
            capsule.backgroundColor = given?.copy(alpha: 0.08) ?? NSColor.labelColor.withAlphaComponent(0.12).cgColor
            // dark ink means a light backdrop: light and flood thin by one factor, so the bar's ends still match
            let thin: CGFloat = given.flatMap { NSColor(cgColor: $0)?.usingColorSpace(.sRGB)?.brightnessComponent }.map { $0 < 0.5 ? 0.4 : 1 } ?? 1
            light.backgroundColor = given?.copy(alpha: 0.24 * thin) ?? ink
            // the full light under its flood, drawn as one layer
            flood.backgroundColor = given?.copy(alpha: 0.42 * thin) ?? ink
            dust.setValue(ink.copy(alpha: 0.3), forKeyPath: "emitterCells.mote.color")
        }

        func show(_ progress: Double, finishing: Bool) {
            let calm = Motion.reduceMotion
            let part = min(1, max(0, progress)), full = part >= 1
            let spread = 0.6 + 1.5 * part * part, lean = 0.72 - 1.15 * part
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let still = calm || shown == nil
            glide(light, "transform", to: CATransform3DMakeAffineTransform(CGAffineTransform(a: spread, b: 0, c: lean, d: 1, tx: 0, ty: 0)), still: still)
            reach(part, still: still)
            // dust falls only while the front moves, so a stalled bar asks for no frames
            let moving = !still && !full && part != shown.map({ min(1, max(0, $0.progress)) })
            dust.birthRate = moving ? 1 : 0
            NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(rest), object: nil)
            if moving { perform(#selector(rest), with: nil, afterDelay: 0.5) }
            flood.opacity = full ? 1 : 0
            lens.opacity = full ? 0 : 1
            if finishing != (shown?.finishing ?? false) {
                sparks.sublayers = nil
                if finishing, !calm { finish() } else { grow(by: 0) }
            }
            CATransaction.commit()
            shown = (progress, finishing)
        }

        @objc private func rest() { dust.birthRate = 0 }

        /// the light's edge and the dust it sheds, `part` of the way along the bar
        private func reach(_ part: Double, still: Bool) {
            let edge = bar.width * min(1, max(0, part))
            glide(light, "position.x", to: edge, still: still)
            glide(dust, "emitterPosition", to: CGPoint(x: edge + bar.height * 1.1, y: bar.height / 2), still: still)
        }

        /// sets a layer's value, the layer moving to it at an even pace from where it shows now
        private func glide(_ layer: CALayer, _ key: String, to value: Any, still: Bool) {
            if !still {
                let move = CABasicAnimation(keyPath: key)
                move.fromValue = (layer.presentation() ?? layer).value(forKeyPath: key)
                move.duration = 0.25
                layer.add(move, forKey: key)
            }
            layer.setValue(value, forKeyPath: key)
        }

        /// the capsule and its flood `out` past the bar on every side, still a capsule
        private func grow(by out: CGFloat, animated: Bool = false) {
            let rect = CGRect(origin: .zero, size: bar).insetBy(dx: -out, dy: -out), radius = bar.height / 2 + out
            let changes: [(CALayer, String, Any)] = [
                (capsule, "bounds", rect), (capsule, "cornerRadius", radius),
                (flood, "bounds", CGRect(origin: .zero, size: rect.size)), (flood, "cornerRadius", radius),
            ]
            for (layer, key, value) in changes {
                if animated {
                    let spring = CASpringAnimation(perceptualDuration: Motion.popSpring.duration, bounce: Motion.popSpring.bounce)
                    spring.keyPath = key
                    spring.fromValue = (layer.presentation() ?? layer).value(forKeyPath: key)
                    spring.duration = spring.settlingDuration
                    layer.add(spring, forKey: key)
                }
                layer.setValue(value, forKeyPath: key)
            }
        }

        /// the bar swells and stays swollen while dots leave its outline all round, slow to a stop and fade
        private func finish() {
            grow(by: swell, animated: true)
            for dot in 0..<80 {
                let (from, out) = outline((Double(dot) + Self.unit(dot, 7)) / 80)
                let far = Self.unit(dot, 8), size = 0.3 + 1.5 * Self.unit(dot, 9)
                let room = gap - size / 2 - swell, reach = swell + room * (0.16 + 0.73 * far * far)
                let spark = CALayer()
                spark.bounds.size = CGSize(width: size, height: size)
                spark.cornerRadius = size / 2
                spark.position = CGPoint(x: from.x + out.dx * reach, y: from.y + out.dy * reach)
                spark.opacity = 0
                spark.backgroundColor =
                    switch dot % 8 {
                    case 0: CGColor(red: 1, green: 0.82, blue: 0.62, alpha: 1)
                    case 1: CGColor(red: 0.76, green: 0.7, blue: 1, alpha: 1)
                    default: ink
                    }
                let fly = CABasicAnimation(keyPath: "position")
                fly.fromValue = from
                fly.timingFunction = CAMediaTimingFunction(controlPoints: 0.05, 0.9, 0.15, 1)
                let fade = CAKeyframeAnimation(keyPath: "opacity")
                let peak = 0.3 + 0.55 * Self.unit(dot, 10)
                fade.values = [peak, peak * 0.5, peak * 0.4, 0]
                fade.keyTimes = [0, 0.25, 0.55, 1]
                let both = CAAnimationGroup()
                both.animations = [fly, fade]
                both.duration = Updates.finish * (0.5 + 0.5 * Self.unit(dot, 11))
                spark.add(both, forKey: nil)
                sparks.addSublayer(spark)
            }
        }

        /// a point on the bar's outline in the view's space and the way out from it, `along` going once round
        private func outline(_ along: Double) -> (CGPoint, CGVector) {
            let radius = bar.height / 2, straight = bar.width - bar.height
            // half a lap is the top's straight and the trailing end's turn; the other half is that turned round
            let half = straight + .pi * radius
            let far = along >= 0.5, run = (far ? along - 0.5 : along) * 2 * half
            let angle = -Double.pi / 2 + max(0, run - straight) / radius
            let out = CGVector(dx: cos(angle), dy: sin(angle))
            let point = CGPoint(x: min(run, straight) - straight / 2 + out.dx * radius, y: out.dy * radius)
            let sign: Double = far ? -1 : 1
            return (
                CGPoint(x: gap + bar.width / 2 + sign * point.x, y: gap + radius + sign * point.y),
                CGVector(dx: sign * out.dx, dy: sign * out.dy)
            )
        }

        /// a fixed value in 0..<1 for a seed and a purpose
        private static func unit(_ seed: Int, _ salt: UInt32) -> Double {
            var x = UInt32(truncatingIfNeeded: seed) &* 2_654_435_761 ^ salt &* 0x9E37_79B9
            x ^= x >> 15
            x = x &* 0x2C1B_3C6D
            x ^= x >> 12
            return Double(x % 10_000) / 10_000
        }

        /// a white picture `size` points big at 3x, its alpha at each point `alpha(x, y)`
        private static func stencil(_ size: CGSize, alpha: (Double, Double) -> Double) -> CGImage {
            let wide = Int(size.width * 3), high = Int(size.height * 3)
            var pixels = (0..<wide * high).flatMap { at -> [UInt8] in
                let value = alpha((Double(at % wide) + 0.5) / 3, (Double(at / wide) + 0.5) / 3)
                return [UInt8](repeating: UInt8(255 * min(1, max(0, value))), count: 4)
            }
            return pixels.withUnsafeMutableBytes {
                CGContext(
                    data: $0.baseAddress, width: wide, height: high, bitsPerComponent: 8, bytesPerRow: wide * 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
            }
        }
    }
}
