import AppKit
import QuartzCore
import SwiftUI
import WebKit

/// Dev-only performance harness.
///
/// `ARTEMIS_BENCH=1` drives the *running* app through a fixed script — open
/// tabs, sit idle, switch tabs, switch spaces, toggle the sidebar — and records
/// what each phase cost: CPU seconds burned by the app process, its physical
/// memory footprint, how many frames the compositor actually delivered (and how
/// many were late), and how many SwiftUI bodies were evaluated.
///
/// It exists because "feels faster" is not a measurement. Every optimisation in
/// the app is supposed to move a number here; if it doesn't, it isn't worth the
/// complexity. The report goes to `~/Downloads/artemis-bench.log` for the same
/// reason the self-test's does — the app is sandboxed and that's the only path
/// a terminal outside the container can read.
///
/// Body counts come from `Bench.tick(_:)` calls sprinkled through the hot views.
/// They're inert (one atomic load) unless the harness is running.
@MainActor
enum Bench {
    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["ARTEMIS_BENCH"] != nil
    }

    /// a label for this run, so two logs can be diffed by name
    private static var runLabel: String {
        ProcessInfo.processInfo.environment["ARTEMIS_BENCH_LABEL"] ?? "run"
    }

    // MARK: - View body counters

    /// flipped on only while the harness runs, so `tick` costs a bool load in
    /// normal use
    nonisolated(unsafe) static var isCounting = false
    nonisolated(unsafe) private static var counts: [String: Int] = [:]
    nonisolated(unsafe) private static let countLock = NSLock()

    /// call from a view's `body`: `Bench.tick("Sidebar")`
    nonisolated static func tick(_ name: String) {
        guard isCounting else { return }
        countLock.lock()
        counts[name, default: 0] += 1
        countLock.unlock()
    }

    private static func drainCounts() -> [String: Int] {
        countLock.lock()
        let snapshot = counts
        counts = [:]
        countLock.unlock()
        return snapshot
    }

    // MARK: - Process metrics

    /// user + system CPU seconds this process has burned so far
    private static func cpuSeconds() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        func seconds(_ t: timeval) -> Double {
            Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000
        }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    /// physical footprint in MB — the number Activity Monitor calls "Memory"
    private static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.phys_footprint) / 1_048_576
    }

    // MARK: - Frame timing

    /// counts display-link callbacks and how many arrived late, which is the
    /// only honest read on "is the UI smooth" — a body count can be small and
    /// still miss vsync if each body is expensive
    @MainActor
    private final class FrameCounter: NSObject {
        private var link: CADisplayLink?
        private var last: CFTimeInterval = 0
        private(set) var frames = 0
        /// intervals longer than ~1.5 refresh periods: a dropped frame
        private(set) var longFrames = 0
        private var budget: CFTimeInterval = 1.0 / 60.0 * 1.5

        func start(in view: NSView) {
            let link = view.displayLink(target: self, selector: #selector(tick(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
        }

        func stop() {
            link?.invalidate()
            link = nil
        }

        func reset() {
            frames = 0
            longFrames = 0
            last = 0
        }

        @objc private func tick(_ link: CADisplayLink) {
            let now = link.timestamp
            if last > 0 {
                let delta = now - last
                // adapt the budget to the panel's real refresh rate
                if link.duration > 0 { budget = link.duration * 1.5 }
                if delta > budget { longFrames += 1 }
            }
            last = now
            frames += 1
        }
    }

    // MARK: - Main-thread busy time

    /// how long the main run loop spends awake, summed, and its longest single
    /// stretch awake: the cost of a step including whatever it deferred
    @MainActor
    private final class BusyMeter {
        private var observer: CFRunLoopObserver?
        private var wokeAt: CFTimeInterval = 0
        private(set) var busy: CFTimeInterval = 0
        private(set) var longest: CFTimeInterval = 0

        func start() {
            let activities = CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue
            wokeAt = CACurrentMediaTime()
            observer = CFRunLoopObserverCreateWithHandler(nil, activities, true, 0) { [weak self] _, activity in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let now = CACurrentMediaTime()
                    if activity == .afterWaiting {
                        self.wokeAt = now
                    } else {
                        self.busy += now - self.wokeAt
                        self.longest = max(self.longest, now - self.wokeAt)
                    }
                }
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        }

        func stop() {
            if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
            observer = nil
        }
    }

    // MARK: - Report

    private nonisolated(unsafe) static var lines: [String] = []

    private static func flush() {
        // ARTEMIS_BENCH_DIR: the perf bundle has no Downloads access (tools/perflab.sh)
        let custom = ProcessInfo.processInfo.environment["ARTEMIS_BENCH_DIR"].map { URL(fileURLWithPath: $0) }
        guard let folder = custom ?? FileManager.default.urls(
            for: .downloadsDirectory, in: .userDomainMask
        ).first?.resolvingSymlinksInPath() else { return }
        try? lines.joined(separator: "\n").write(
            to: folder.appendingPathComponent("artemis-bench-\(runLabel).log"),
            atomically: true, encoding: .utf8)
    }

    private struct PhaseResult {
        let name: String
        let start: Double
        let end: Double
        let seconds: Double
        let cpu: Double
        let footprint: Double
        let frames: Int
        let longFrames: Int
        let bodies: [String: Int]
    }

    private nonisolated(unsafe) static var results: [PhaseResult] = []

    /// run `work` while metering it, then record a row
    private static func phase(
        _ name: String, counter: FrameCounter, _ work: () async -> Void
    ) async {
        // let the previous phase's animations land before we start counting
        try? await Task.sleep(for: .milliseconds(600))
        _ = drainCounts()
        counter.reset()
        let cpu0 = cpuSeconds()
        let clock0 = Date()
        await work()
        let clock1 = Date()
        let elapsed = clock1.timeIntervalSince(clock0)
        let cpu = cpuSeconds() - cpu0
        let bodies = drainCounts()
        results.append(PhaseResult(
            name: name, start: clock0.timeIntervalSince1970, end: clock1.timeIntervalSince1970,
            seconds: elapsed, cpu: cpu, footprint: footprintMB(),
            frames: counter.frames, longFrames: counter.longFrames, bodies: bodies))
    }

    // MARK: - The script

    /// live sites, used only with `ARTEMIS_BENCH=live`. realistic, but useless
    /// as a regression signal — see `BenchPage`
    private static let sites = [
        "https://en.wikipedia.org/wiki/Web_browser",
        "https://news.ycombinator.com/",
        "https://developer.mozilla.org/en-US/docs/Web/API/Fetch_API",
        "https://www.theverge.com/",
        "https://github.com/apple/swift",
        "https://www.reddit.com/r/macapps/",
        "https://stackoverflow.com/questions",
        "https://www.apple.com/mac/",
    ]

    private static var useLiveSites: Bool {
        ProcessInfo.processInfo.environment["ARTEMIS_BENCH"] == "live"
    }

    /// open the fixture tabs and wait for them to settle
    private static func openTabs(_ manager: TabManager) async -> [BrowserTab] {
        var tabs: [BrowserTab] = []
        let count = Int(ProcessInfo.processInfo.environment["ARTEMIS_BENCH_TABS"] ?? "") ?? sites.count
        for index in 0..<count {
            let site = sites[index % sites.count]
            let tab = manager.newTab()
            if useLiveSites, let url = URL(string: site) {
                tab.load(url)
            } else {
                tab.webView.loadHTMLString(
                    BenchPage.html(index: index),
                    baseURL: URL(string: "https://bench.artemis.local/page\(index)"))
            }
            tabs.append(tab)
            try? await Task.sleep(for: .milliseconds(300))
        }
        for _ in 0..<120 {
            try? await Task.sleep(for: .milliseconds(250))
            if tabs.allSatisfy({ !$0.webView.isLoading }) { break }
        }
        return tabs
    }

    // MARK: - Launch marks

    /// Coarse "when did this happen, relative to exec" marks for the launch
    /// path. Always recorded (they cost a timestamp each) because the launch
    /// path is the one place a profiler is least useful: by the time you can
    /// attach to the process, the part you wanted is over.
    nonisolated(unsafe) private static var marks: [(String, Double)] = []
    nonisolated(unsafe) private static let markLock = NSLock()

    nonisolated(unsafe) private static var markedOnce: Set<String> = []

    /// for marks that sit inside something that runs repeatedly (a `body`), where
    /// only the first time is the launch milestone
    nonisolated static func markOnce(_ name: String) {
        markLock.lock()
        let seen = markedOnce.contains(name)
        markedOnce.insert(name)
        markLock.unlock()
        guard !seen else { return }
        mark(name)
    }

    nonisolated static func mark(_ name: String) {
        let t = processStartInterval()
        markLock.lock()
        marks.append((name, t))
        markLock.unlock()
    }

    // MARK: - Launch

    /// `ARTEMIS_BENCH=launch`: report how long it took from `exec` to a window
    /// on screen, then quit. Timed from the kernel's record of when the process
    /// started rather than from `main`, so dynamic linking, the runtime's own
    /// start-up and every `init` before the first frame are all inside the
    /// number — which is the part a person actually waits through.
    static var isLaunchRequested: Bool {
        ProcessInfo.processInfo.environment["ARTEMIS_BENCH"] == "launch"
    }

    static func reportLaunch() async {
        // one turn of the run loop after the first frame, so the window is
        // genuinely up rather than merely scheduled
        try? await Task.sleep(for: .milliseconds(50))
        let elapsed = processStartInterval()
        lines = [
            "Artemis launch — \(Date())",
            "",
            String(format: "exec → window on screen: %.0f ms", elapsed * 1000),
            String(format: "footprint at first frame: %.1f MB", footprintMB()),
            String(format: "cpu burned getting there:  %.0f ms", cpuSeconds() * 1000),
            "",
            "milestones (ms since exec)",
            String(repeating: "-", count: 40),
        ]
        markLock.lock()
        let taken = marks.sorted { $0.1 < $1.1 }
        markLock.unlock()
        var last = 0.0
        for (name, at) in taken {
            lines.append(String(
                format: "%8.0f  (+%6.0f)  %@", at * 1000, (at - last) * 1000, name as NSString))
            last = at
        }
        flush()
        NSApp.terminate(nil)
    }

    /// seconds since this process was exec'd, from the kernel's process table
    nonisolated static func processStartInterval() -> Double {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return 0 }
        let started = info.kp_proc.p_starttime
        let start = Double(started.tv_sec) + Double(started.tv_usec) / 1_000_000
        return Date().timeIntervalSince1970 - start
    }

    // MARK: - Mechanism probes

    /// Aggregate CPU over a minute turned out to be a poor way to judge a
    /// change: on a live machine two runs of the *same* build differ by 2x, and
    /// the effects worth shipping are smaller than that. These probes ask the
    /// page itself what happened instead, which is both exact and instant.
    private static func probes(manager: TabManager, bench: Space, other: Space) async {
        lines.append("mechanism probes")
        lines.append(String(repeating: "-", count: 78))

        // every one of these readings is a page visibility question, and a window
        // that isn't frontmost is hidden to WebKit no matter what the app does —
        // so take the front first, or the probe measures the window manager
        takeFront()
        try? await Task.sleep(for: .milliseconds(800))

        // 1. a page in a neighbouring space is kept mounted so a swipe doesn't
        // have to mount it mid-gesture. it must not still be *running*.
        manager.selectSpace(bench)
        try? await Task.sleep(for: .seconds(2))
        guard let background = other.selectedTab ?? other.tabs.first else {
            lines.append("no background tab to probe")
            return
        }
        let before = await ticks(background)
        try? await Task.sleep(for: .seconds(5))
        let after = await ticks(background)
        let state = await visibility(background)
        lines.append(String(
            format: "background page over 5s: %d frames, visibilityState=%@",
            after - before, state as NSString))

        // 2. and the page you're actually looking at must be running normally —
        // a fix that quietly freezes the foreground would look great here
        guard let foreground = bench.selectedTab else { return }
        let fgBefore = await ticks(foreground)
        try? await Task.sleep(for: .seconds(5))
        let fgAfter = await ticks(foreground)
        let fgState = await visibility(foreground)
        lines.append(String(
            format: "foreground page over 5s: %d frames, visibilityState=%@",
            fgAfter - fgBefore, fgState as NSString))
        lines.append("")
    }

    /// `ARTEMIS_BENCH_BACKGROUND=1` never takes the front, for runs that time
    /// steps rather than frames while someone else is using the screen
    private static func takeFront() {
        guard ProcessInfo.processInfo.environment["ARTEMIS_BENCH_BACKGROUND"] == nil else { return }
        NSApp.activate(ignoringOtherApps: true)
        SelfTest.mainWindow()?.makeKeyAndOrderFront(nil)
    }

    private static func ticks(_ tab: BrowserTab) async -> Int {
        let value = try? await tab.webView.evaluateJavaScript("window.__ticks || 0")
        return (value as? Int) ?? -1
    }

    private static func visibility(_ tab: BrowserTab) async -> String {
        let value = try? await tab.webView.evaluateJavaScript("document.visibilityState")
        return (value as? String) ?? "?"
    }

    static func run(manager: TabManager) async {
        lines = ["Artemis bench (\(runLabel)) — \(Date())", ""]
        results = []

        takeFront()
        try? await Task.sleep(for: .seconds(2))

        // App Nap will throttle a background app's timers by roughly 10x, which
        // silently turns a 6-second phase into a 60-second one and makes two
        // runs incomparable for reasons that have nothing to do with the code.
        // Hold an activity for the length of the run.
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled, .latencyCritical],
            reason: "artemis bench")
        defer { ProcessInfo.processInfo.endActivity(activity) }

        let counter = FrameCounter()
        // The counter rides a CADisplayLink on the window's view. Starting it
        // only `if let` meant that a run which began before the window existed
        // metered nothing and reported `frames 0` for every phase — a silent
        // zero that reads like a clean result. Wait for the window, and say so
        // in the report if it never arrives, so the numbers can't lie quietly.
        var counterView: NSView?
        for _ in 0..<40 {
            if let view = SelfTest.mainWindow()?.contentView {
                counterView = view
                break
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        if let counterView {
            counter.start(in: counterView)
        } else {
            lines.append("WARNING: no window after 10s — frame counts are NOT measured")
        }
        isCounting = true

        // whatever the user happens to have installed must not decide the
        // numbers: an extension's content scripts run in every page the bench
        // opens, and a VPN extension's background page is a whole extra web
        // process. `ARTEMIS_BENCH_EXTENSIONS=1` measures with them on
        // `isMasterEnabled` is a persisted setting, so this has to be handed
        // back however the run ends — leaving a user's extensions switched off
        // after a benchmark would be a fine way to lose an afternoon
        let extensionsWereEnabled = ExtensionManager.shared.isMasterEnabled
        defer { ExtensionManager.shared.isMasterEnabled = extensionsWereEnabled }
        if ProcessInfo.processInfo.environment["ARTEMIS_BENCH_EXTENSIONS"] == nil {
            ExtensionManager.shared.isMasterEnabled = false
            lines.append("(extensions disabled for this run)")
            lines.append("")
        }

        // the blocker compiles 130k rules on a background task at first launch;
        // measuring through that times the machine, not the UI
        await ContentBlocker.shared.waitForIdle()
        try? await Task.sleep(for: .seconds(1))

        // work in a space of our own so the user's session isn't disturbed
        for stale in manager.spaces where stale.name == "Bench" {
            manager.deleteSpace(stale)
        }
        let home = manager.currentSpace
        let bench = manager.createSpace(name: "Bench", icon: "gauge", appearance: SpacePreset.all[1].appearance,
            profileID: Profile.defaultID)
        manager.selectSpace(bench)
        try? await Task.sleep(for: .milliseconds(500))

        // ARTEMIS_BENCH_LOOP=<phase> repeats one interaction for a minute so a
        // profiler (`sample Artemis`) has something steady to attach to —
        // phase timings say *which* interaction is slow, a sampled stack says why
        if let loop = ProcessInfo.processInfo.environment["ARTEMIS_BENCH_LOOP"] {
            let tabs = await openTabs(manager)
            let defaults = UserDefaults.standard
            var newTabs: [BrowserTab] = []
            var stepDirection = 1
            // ARTEMIS_BENCH_SYNC: lay out and draw each step at once and time it, so a
            // step's main-thread cost is measured even with no display to drive frames
            let sync = ProcessInfo.processInfo.environment["ARTEMIS_BENCH_SYNC"] != nil
            var stepTimes: [Double] = []
            var steps = 0
            let meter = BusyMeter()
            meter.start()
            await phase("loop-\(loop)", counter: counter) {
                let deadline = Date().addingTimeInterval(60)
                var i = 0
                while Date() < deadline {
                    let stepStart = CACurrentMediaTime()
                    switch loop {
                    case "tab": manager.selectedTabID = tabs[i % tabs.count].id
                    // the pattern people actually have: flipping between the two
                    // pages they're working with, not a round-robin of eight
                    case "tab2": manager.selectedTabID = tabs[i % 2].id
                    case "space": manager.selectSpace(i.isMultiple(of: 2) ? home : bench)
                    // ⌘⌥→ along the row of spaces and back: each switch is to a neighbour
                    case "step":
                        let at = manager.spaces.firstIndex { $0.id == manager.selectedSpaceID } ?? 0
                        if at == manager.spaces.count - 1 { stepDirection = -1 } else if at == 0 { stepDirection = 1 }
                        manager.cycleSpace(by: stepDirection)
                    // the click path animates; a two-finger swipe writes the
                    // position by hand once per scroll event, so it flushes the
                    // graph tens of times per gesture instead of once
                    case "swipe":
                        let from = manager.spacePagePosition
                        let to = Double(
                            manager.spaces.firstIndex(
                                where: { $0.id == (i.isMultiple(of: 2) ? home : bench).id }) ?? 0)
                        for step in 1...24 {
                            let t = Double(step) / 24
                            manager.spacePagePosition = from + (to - from) * t
                            manager.backdropPosition = manager.spacePagePosition
                            try? await Task.sleep(for: .milliseconds(8))
                        }
                        manager.selectSpace(i.isMultiple(of: 2) ? home : bench, animatePosition: false)
                    // the switch alone, to the neighbour, with no motion
                    case "commit":
                        let at = manager.spaces.firstIndex { $0.id == manager.selectedSpaceID } ?? 0
                        if at == manager.spaces.count - 1 { stepDirection = -1 } else if at == 0 { stepDirection = 1 }
                        manager.spacePagePosition = Double(at + stepDirection)
                        manager.backdropPosition = manager.spacePagePosition
                        manager.selectSpace(at: at + stepDirection, animatePosition: false)
                    // a quick flick to the neighbour, along every space and back,
                    // the next one starting while the last is still settling
                    case "flick":
                        let at = manager.spaces.firstIndex { $0.id == manager.selectedSpaceID } ?? 0
                        if at == manager.spaces.count - 1 { stepDirection = -1 } else if at == 0 { stepDirection = 1 }
                        for step in 1...12 {
                            manager.spacePagePosition = Double(at) + Double(stepDirection) * Double(step) / 12
                            manager.backdropPosition = manager.spacePagePosition
                            try? await Task.sleep(for: .milliseconds(8))
                        }
                        manager.selectSpace(at: at + stepDirection, animatePosition: false)
                    // a hand swipe to the neighbour, along every space and back
                    case "swipeall":
                        let at = manager.spaces.firstIndex { $0.id == manager.selectedSpaceID } ?? 0
                        if at == manager.spaces.count - 1 { stepDirection = -1 } else if at == 0 { stepDirection = 1 }
                        let to = at + stepDirection
                        for step in 1...24 {
                            manager.spacePagePosition = Double(at) + Double(stepDirection) * Double(step) / 24
                            manager.backdropPosition = manager.spacePagePosition
                            try? await Task.sleep(for: .milliseconds(8))
                        }
                        manager.selectSpace(at: to, animatePosition: false)
                    // the swipe's per-frame half alone: out toward a neighbour and
                    // back, never committing a switch
                    case "glide":
                        let base = Double(manager.spaces.firstIndex { $0.id == manager.selectedSpaceID } ?? 0)
                        let toward: Double = base + 1 < Double(manager.spaces.count) ? 1 : -1
                        for step in 1...24 {
                            let reach = Double(step <= 12 ? step : 24 - step) / 12
                            manager.spacePagePosition = base + toward * 0.9 * reach
                            manager.backdropPosition = manager.spacePagePosition
                            try? await Task.sleep(for: .milliseconds(8))
                        }
                    // nothing at all: what the app burns with its tabs open and no one at it
                    case "idle": break
                    case "sidebar":
                        manager.isSidebarCollapsed = !i.isMultiple(of: 2)
                    case "library":
                        withAnimation(Motion.panel) { manager.isLibraryOpen = !manager.isLibraryOpen }
                    // the Library held open, flipping between its three lists
                    case "libmode":
                        manager.isLibraryOpen = true
                        defaults.set(["Archive", "Downloads", "History"][i % 3], forKey: "libraryLastMode")
                    // ⌘T, a beat to type, Enter: the bar closes as the page opens
                    case "newtab":
                        manager.requestNewTab()
                        try? await Task.sleep(for: .milliseconds(300))
                        manager.isCommandBarVisible = false
                        let opened = manager.newTab()
                        opened.webView.loadHTMLString(
                            BenchPage.html(index: i % 8),
                            baseURL: URL(string: "https://bench.artemis.local/new\(i)"))
                        if let stale = newTabs.popLast() { manager.close(stale) }
                        newTabs.append(opened)
                    default: break
                    }
                    if sync, let window = SelfTest.mainWindow() {
                        window.layoutIfNeeded()
                        window.displayIfNeeded()
                        CATransaction.flush()
                        stepTimes.append((CACurrentMediaTime() - stepStart) * 1000)
                    }
                    i += 1
                    steps = i
                    // an app that drifts out of the foreground stops being asked
                    // to draw at all, which silently turns a loop that should
                    // cost 45 CPU-seconds into one that costs 7. take the front
                    // back regularly rather than trusting it to stay there
                    if i.isMultiple(of: 10) {
                        takeFront()
                    }
                    try? await Task.sleep(for: .milliseconds(loop == "flick" ? 150 : 400))
                }
            }
            meter.stop()
            lines.append(String(
                format: "main busy per step ms: %.2f  longest stall ms: %.1f  steps %d",
                meter.busy * 1000 / Double(max(steps, 1)), meter.longest * 1000, steps))
            if !stepTimes.isEmpty {
                let sorted = stepTimes.sorted()
                lines.append(String(
                    format: "sync step ms: median %.2f  p90 %.2f  mean %.2f  n %d",
                    sorted[sorted.count / 2], sorted[sorted.count * 9 / 10],
                    sorted.reduce(0, +) / Double(sorted.count), sorted.count))
                lines.append("")
            }
            manager.isSidebarCollapsed = false
            manager.isLibraryOpen = false
            isCounting = false
            counter.stop()
            manager.selectSpace(home)
            manager.deleteSpace(bench)
            manager.saveNow()
            SelfTest.forgetTestTraces(manager)
            report()
            ExtensionManager.shared.isMasterEnabled = extensionsWereEnabled
            try? await Task.sleep(for: .milliseconds(500))
            NSApp.terminate(nil)
            return
        }

        await phase("idle-empty", counter: counter) {
            try? await Task.sleep(for: .seconds(8))
        }

        var tabs: [BrowserTab] = []
        await phase("open-8-tabs", counter: counter) {
            tabs = await openTabs(manager)
        }

        // a second space, so the warm-neighbour mount path is exercised — that's
        // where a background page is kept mounted and could keep rendering
        let other = manager.createSpace(
            name: "Bench2", icon: "gauge", appearance: SpacePreset.all[2].appearance,
            profileID: Profile.defaultID)
        other.selectedTab?.webView.loadHTMLString(
            BenchPage.html(index: 99), baseURL: URL(string: "https://bench.artemis.local/page99"))
        try? await Task.sleep(for: .seconds(3))
        await probes(manager: manager, bench: bench, other: other)

        await phase("idle-8-tabs", counter: counter) {
            try? await Task.sleep(for: .seconds(15))
        }

        await phase("tab-switch-x30", counter: counter) {
            for i in 0..<30 {
                manager.selectedTabID = tabs[i % tabs.count].id
                try? await Task.sleep(for: .milliseconds(200))
            }
        }

        await phase("space-switch-x10", counter: counter) {
            for i in 0..<10 {
                manager.selectSpace(i.isMultiple(of: 2) ? home : bench)
                try? await Task.sleep(for: .milliseconds(500))
            }
            manager.selectSpace(bench)
            try? await Task.sleep(for: .milliseconds(500))
        }

        let wasCollapsed = manager.isSidebarCollapsed
        await phase("sidebar-toggle-x10", counter: counter) {
            for i in 0..<10 {
                manager.isSidebarCollapsed = !i.isMultiple(of: 2)
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        manager.isSidebarCollapsed = wasCollapsed

        await phase("scroll-active-tab", counter: counter) {
            guard let tab = tabs.first else { return }
            manager.selectedTabID = tab.id
            try? await Task.sleep(for: .milliseconds(500))
            for _ in 0..<30 {
                _ = try? await tab.webView.evaluateJavaScript("window.scrollBy(0, 400)")
                try? await Task.sleep(for: .milliseconds(100))
            }
        }

        await phase("idle-after-work", counter: counter) {
            try? await Task.sleep(for: .seconds(10))
        }

        isCounting = false
        counter.stop()

        // clean up: the bench space and its tabs go away, so the session the
        // user comes back to is the one they left
        manager.selectSpace(home)
        manager.deleteSpace(bench)
        for stale in manager.spaces where stale.name == "Bench2" {
            manager.deleteSpace(stale)
        }
        manager.saveNow()
        SelfTest.forgetTestTraces(manager)

        report()
        ExtensionManager.shared.isMasterEnabled = extensionsWereEnabled
        try? await Task.sleep(for: .milliseconds(500))
        NSApp.terminate(nil)
    }

    private static func report() {
        // a run that never got a display-link callback measured no smoothness at
        // all; every frame column below is a silent zero, not a good result
        if results.allSatisfy({ $0.frames == 0 }) {
            lines.append("WARNING: 0 frames delivered all run — the frame columns are NOT valid")
            lines.append("")
        }
        lines.append("phase                  wall     cpu   cpu%   mem(MB)  frames  late   bodies")
        lines.append(String(repeating: "-", count: 78))
        for r in results {
            let pct = r.seconds > 0 ? r.cpu / r.seconds * 100 : 0
            let bodies = r.bodies.values.reduce(0, +)
            lines.append(String(
                format: "%-20@ %7.1fs %6.2fs %5.1f%% %8.1f %7d %5d %8d",
                r.name as NSString, r.seconds, r.cpu, pct, r.footprint,
                r.frames, r.longFrames, bodies))
        }
        lines.append("")
        lines.append("body evaluations by view")
        lines.append(String(repeating: "-", count: 78))
        for r in results where !r.bodies.isEmpty {
            let top = r.bodies.sorted { $0.value > $1.value }.prefix(12)
            lines.append("\(r.name):")
            for (name, count) in top {
                lines.append(String(format: "    %-32@ %6d", name as NSString, count))
            }
        }
        lines.append("")
        // machine-readable, for correlating with an outside sampler that can see
        // the WebKit child processes and WindowServer (this process can't)
        lines.append("#csv phase,start,end,cpu,footprintMB,frames,late,bodies")
        for r in results {
            lines.append(String(
                format: "#csv %@,%.3f,%.3f,%.3f,%.1f,%d,%d,%d",
                r.name, r.start, r.end, r.cpu, r.footprint,
                r.frames, r.longFrames, r.bodies.values.reduce(0, +)))
        }
        lines.append("")
        lines.append("done \(Date())")
        flush()
    }
}
