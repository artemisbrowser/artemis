// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import AppKit
import QuartzCore
import SwiftUI
import WebKit

/// dev-only performance harness: `ARTEMIS_BENCH=1` drives the running app through a fixed
/// script and logs each phase's CPU, footprint, frames and SwiftUI body counts to
/// `artemis-bench-<ARTEMIS_BENCH_LABEL>.log` in ~/Library/Logs/Artemis (or `ARTEMIS_BENCH_DIR`)
@MainActor
enum Bench {
    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["ARTEMIS_BENCH"] != nil
    }

    private static var runLabel: String {
        ProcessInfo.processInfo.environment["ARTEMIS_BENCH_LABEL"] ?? "run"
    }

    // MARK: - View body counters

    /// on only while the harness runs, so `tick` costs a bool load in normal use
    nonisolated(unsafe) private static var isCounting = false
    nonisolated(unsafe) private static var counts: [String: Int] = [:]
    nonisolated(unsafe) private static let countLock = NSLock()

    /// call from a view's `body`: `Bench.tick("Sidebar")`
    nonisolated static func tick(_ name: String) {
        guard isCounting else { return }
        countLock.lock()
        counts[name, default: 0] += 1
        countLock.unlock()
    }

    /// ARTEMIS_BENCH_TIMELINE: the strip's and the backdrop's shown positions, in spaces
    static var stripShown: (@MainActor () -> Double?)?
    static var backdropShown: (@MainActor () -> Double?)?

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

    /// counts display-link callbacks and how many arrived late
    @MainActor
    final class FrameCounter: NSObject {
        private var link: CADisplayLink?
        private var last: CFTimeInterval = 0
        /// every callback's timestamp, kept only while set
        var stamps: [CFTimeInterval]?
        /// with `stamps`: the strip's and the backdrop's shown positions at each callback
        var shown: [(Double, Double)] = []
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
                if link.duration > 0 { budget = link.duration * 1.5 }
                if delta > budget { longFrames += 1 }
            }
            last = now
            if stamps != nil {
                stamps?.append(now)
                shown.append((Bench.stripShown?() ?? .nan, Bench.backdropShown?() ?? .nan))
            }
            frames += 1
        }
    }

    /// ARTEMIS_BENCH_TIMELINE: per step, main-thread time awake by offset from the step's start,
    /// the longest stretch in each band, and the display link's first callback and longest gap
    private static func timelineReport(
        _ starts: [CFTimeInterval], _ spans: [(CFTimeInterval, CFTimeInterval)], _ stamps: [CFTimeInterval]
    ) -> [String] {
        let bands: [(String, Double, Double)] = [
            ("0-20", 0, 0.02), ("20-100", 0.02, 0.1), ("100-250", 0.1, 0.25), ("250-500", 0.25, 0.5),
            ("500-700", 0.5, 0.7), ("700+", 0.7, 9),
        ]
        func median(_ v: [Double]) -> Double { v.isEmpty ? 0 : v.sorted()[v.count / 2] }
        func p90(_ v: [Double]) -> Double { v.isEmpty ? 0 : v.sorted()[v.count * 9 / 10] }
        var busy = Array(repeating: [Double](), count: bands.count)
        var longest = busy
        var firstFrame: [Double] = [], gap300: [Double] = [], gapAll: [Double] = [], missed: [Double] = []
        // the first and last steps sit beside the loop's own setup and teardown
        for k in starts.indices.dropFirst().dropLast() {
            let s = starts[k], e = starts[k + 1]
            let mine = spans.filter { $0.0 + $0.1 > s && $0.0 < e }
            for (b, band) in bands.enumerated() {
                let inBand = mine.filter { max($0.0 - s, 0) >= band.1 && max($0.0 - s, 0) < band.2 }
                busy[b].append(inBand.reduce(0) { $0 + $1.1 } * 1000)
                longest[b].append((inBand.map(\.1).max() ?? 0) * 1000)
            }
            let frames = stamps.filter { $0 > s && $0 < e }
            guard let first = frames.first else { continue }
            firstFrame.append((first - s) * 1000)
            var prev = first
            var worst300 = first - s, worst = first - s
            var late = 0.0
            for t in frames.dropFirst() {
                if t - s < 0.3 { worst300 = max(worst300, t - prev) }
                worst = max(worst, t - prev)
                late += max(((t - prev) * 120).rounded() - 1, 0)
                prev = t
            }
            gap300.append(worst300 * 1000)
            gapAll.append(worst * 1000)
            missed.append(late)
        }
        var out = ["timeline over \(max(starts.count - 2, 0)) steps, ms from the step's start (median / p90):"]
        for (b, band) in bands.enumerated() {
            out.append(String(
                format: "  %@ busy %.1f / %.1f  longest %.1f / %.1f", band.0 as NSString,
                median(busy[b]), p90(busy[b]), median(longest[b]), p90(longest[b])))
        }
        out.append(String(
            format: "  frames: first %.1f / %.1f  worst gap in 0-300 %.1f / %.1f  worst gap %.1f / %.1f  missed %.1f / %.1f  (n %d)",
            median(firstFrame), p90(firstFrame), median(gap300), p90(gap300), median(gapAll), p90(gapAll),
            median(missed), p90(missed), firstFrame.count))
        return out
    }

    /// per step: the most the strip and the backdrop disagree while either moves, how many
    /// callbacks saw each move, and the longest the backdrop stood still while the strip moved
    private static func lockstepReport(
        _ starts: [CFTimeInterval], _ stamps: [CFTimeInterval], _ shown: [(Double, Double)]
    ) -> [String] {
        func median(_ v: [Double]) -> Double { v.isEmpty ? 0 : v.sorted()[v.count / 2] }
        func p90(_ v: [Double]) -> Double { v.isEmpty ? 0 : v.sorted()[v.count * 9 / 10] }
        var apart: [Double] = [], stripMoves: [Double] = [], backdropMoves: [Double] = [], still: [Double] = []
        var stripStart: [Double] = [], backdropStart: [Double] = []
        for k in starts.indices.dropFirst().dropLast() {
            let s = starts[k], e = starts[k + 1]
            let idx = stamps.indices.filter { stamps[$0] > s && stamps[$0] < e && !shown[$0].0.isNaN && !shown[$0].1.isNaN }
            guard idx.count > 2 else { continue }
            var worst = 0.0, sm = 0.0, bm = 0.0, stillFor = 0.0, longestStill = 0.0
            var firstS: Double?, firstB: Double?
            for (a, b) in zip(idx, idx.dropFirst()) {
                let ds = abs(shown[b].0 - shown[a].0), db = abs(shown[b].1 - shown[a].1)
                let moving = ds > 1e-4 || db > 1e-4
                if moving { worst = max(worst, abs(shown[b].0 - shown[b].1)) }
                if ds > 1e-4 { sm += 1; firstS = firstS ?? (stamps[b] - s) * 1000 }
                if db > 1e-4 { bm += 1; firstB = firstB ?? (stamps[b] - s) * 1000 }
                if ds > 1e-4, db <= 1e-4 { stillFor += stamps[b] - stamps[a] } else { stillFor = 0 }
                longestStill = max(longestStill, stillFor)
            }
            guard sm > 0 || bm > 0 else { continue }
            apart.append(worst)
            stripMoves.append(sm)
            backdropMoves.append(bm)
            still.append(longestStill * 1000)
            if let firstS { stripStart.append(firstS) }
            if let firstB { backdropStart.append(firstB) }
        }
        return [
            String(
                format: "lockstep (n %d): most apart %.3f / %.3f spaces  strip moved on %.0f / %.0f callbacks, backdrop %.0f / %.0f",
                apart.count, median(apart), p90(apart), median(stripMoves), p90(stripMoves), median(backdropMoves),
                p90(backdropMoves)),
            String(
                format: "  backdrop still while the strip moved, longest ms %.1f / %.1f  first move ms strip %.1f / %.1f  backdrop %.1f / %.1f",
                median(still), p90(still), median(stripStart), p90(stripStart), median(backdropStart), p90(backdropStart)),
        ]
    }

    // MARK: - Main-thread busy time

    /// how long the main run loop spends awake, summed, and its longest single
    /// stretch awake: the cost of a step including whatever it deferred
    @MainActor
    final class BusyMeter {
        private var observer: CFRunLoopObserver?
        private var wokeAt: CFTimeInterval = 0
        private(set) var busy: CFTimeInterval = 0
        private(set) var longest: CFTimeInterval = 0
        /// each awake stretch as (start, length), kept only while set
        var spans: [(CFTimeInterval, CFTimeInterval)]?

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
                        self.spans?.append((self.wokeAt, now - self.wokeAt))
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

    // MARK: - Tab sleep

    private static let sleepSites = [
        "https://en.wikipedia.org/wiki/Web_browser", "https://news.ycombinator.com/",
        "https://developer.mozilla.org/en-US/docs/Web/API/Fetch_API", "https://github.com/apple/swift",
        "https://www.bbc.co.uk/news", "https://www.theguardian.com/international", "https://www.reddit.com/r/macapps/",
        "https://stackoverflow.com/questions", "https://www.apple.com/mac/", "https://www.nytimes.com/",
        "https://www.youtube.com/", "https://www.amazon.co.uk/", "https://www.imdb.com/chart/top/",
        "https://www.theverge.com/", "https://arstechnica.com/", "https://www.figma.com/",
        "https://www.notion.com/", "https://www.spotify.com/", "https://www.airbnb.co.uk/",
        "https://www.booking.com/", "https://www.espn.com/", "https://www.cnn.com/",
        "https://www.nasa.gov/", "https://www.nature.com/", "https://www.economist.com/",
        "https://www.wired.com/", "https://www.twitch.tv/", "https://www.pinterest.com/",
        "https://www.etsy.com/", "https://www.ikea.com/gb/en/", "https://www.bbc.co.uk/sport",
        "https://www.reuters.com/", "https://www.bloomberg.com/", "https://docs.python.org/3/",
        "https://www.rust-lang.org/", "https://developer.apple.com/documentation/webkit",
    ]

    /// physical footprint of this process and every process it is responsible for (WebKit's
    /// content, network and GPU processes), in MB, and how many processes that is
    private static func familyFootprint() -> (total: Double, app: Double, processes: Int) {
        typealias Responsible = @convention(c) (pid_t) -> pid_t
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid")
        else { return (footprintMB(), footprintMB(), 1) }
        let responsible = unsafeBitCast(symbol, to: Responsible.self)
        var pids = [pid_t](repeating: 0, count: 8192)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        let me = getpid()
        var total = 0.0, processes = 0
        for pid in pids.prefix(max(count, 0)) where pid > 0 && (pid == me || responsible(pid) == me) {
            var usage = rusage_info_v4()
            let result = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            guard result == 0 else { continue }
            total += Double(usage.ri_phys_footprint) / 1_048_576
            processes += 1
        }
        return (total, footprintMB(), processes)
    }

    /// ARTEMIS_BENCH=1 ARTEMIS_BENCH_LOOP=sleep: 36 live sites over three spaces, used over the last
    /// 36 minutes, then the idle sweep, a memory warning and waking slept tabs
    private static func sleepBench(_ manager: TabManager, bench: Space) async {
        let spaces = [bench] + (2...3).map {
            manager.createSpace(
                name: "Bench\($0)", icon: "gauge", appearance: SpacePreset.all[$0].appearance, profileID: Profile.defaultID)
        }
        manager.selectSpace(bench)
        var tabs: [BrowserTab] = []
        for (index, site) in sleepSites.enumerated() {
            let tab = manager.newTab(url: URL(string: site), select: false, in: spaces[index % 3])
            if index < 6 { tab.isPinned = true }
            tabs.append(tab)
            try? await Task.sleep(for: .milliseconds(250))
        }
        for _ in 0..<240 where tabs.contains(where: { $0.webView.isLoading }) {
            try? await Task.sleep(for: .milliseconds(250))
        }
        for tab in tabs { _ = try? await tab.webView.evaluateJavaScript("window.scrollTo(0, 1200)") }
        try? await Task.sleep(for: .seconds(10))
        for (index, tab) in tabs.enumerated() { tab.lastAccessed = Date(timeIntervalSinceNow: -60 * Double(index) - 30) }

        func measure(_ name: String) {
            let family = familyFootprint()
            let asleep = tabs.count(where: \.isHibernated)
            lines.append(String(
                format: "%-12@ total %7.0f MB  app %5.0f MB  processes %3d  asleep %2d/%d",
                name as NSString, family.total, family.app, family.processes, asleep, tabs.count))
        }
        measure("loaded")
        await manager.hibernateIdleTabs()
        try? await Task.sleep(for: .seconds(10))
        measure("idle sweep")
        await manager.relieveMemoryPressure(critical: false)
        try? await Task.sleep(for: .seconds(10))
        measure("warning")
        lines.append("")

        // selecting a slept tab until its first contentful paint, and whether its scroll came back
        var wakes: [Double] = []
        var scrolled = 0
        for tab in tabs.filter(\.isHibernated).prefix(8) {
            guard let space = spaces.first(where: { $0.tabs.contains { $0 === tab } }) else { continue }
            manager.selectSpace(space)
            try? await Task.sleep(for: .milliseconds(600))
            let start = Date().timeIntervalSince1970 * 1000
            manager.selectedTabID = tab.id
            var painted = 0.0
            for _ in 0..<100 where painted == 0 {
                try? await Task.sleep(for: .milliseconds(50))
                let probe = "(() => { const p = performance.getEntriesByName('first-contentful-paint')[0]; "
                    + "return p ? performance.timeOrigin + p.startTime : 0 })()"
                painted = (try? await tab.webView.evaluateJavaScript(probe)) as? Double ?? 0
            }
            if painted > 0 { wakes.append(painted - start) }
            try? await Task.sleep(for: .seconds(1))
            if ((try? await tab.webView.evaluateJavaScript("window.scrollY")) as? Double ?? 0) > 0 { scrolled += 1 }
        }
        let sorted = wakes.sorted()
        if !sorted.isEmpty {
            lines.append(String(
                format: "wake to first paint ms: median %.0f  p90 %.0f  n %d  scroll restored %d",
                sorted[sorted.count / 2], sorted[min(sorted.count - 1, sorted.count * 9 / 10)], sorted.count, scrolled))
        }
        lines.append("")
        lines.append("done \(Date())")
    }

    // MARK: - Report

    private nonisolated(unsafe) static var lines: [String] = []

    private static func flush() {
        let name = "artemis-bench-\(runLabel)"
        let url = ProcessInfo.processInfo.environment["ARTEMIS_BENCH_DIR"]
            .map { URL(fileURLWithPath: $0).appending(path: "\(name).log") } ?? AppStorageLocation.devFile(name, "log")
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
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

    /// loaded only with `ARTEMIS_BENCH=live`; their count is the default tab count
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
        // the tab loops alternate between two tabs
        let count = max(Int(ProcessInfo.processInfo.environment["ARTEMIS_BENCH_TABS"] ?? "") ?? sites.count, 2)
        for index in 0..<count {
            let url = useLiveSites ? URL(string: sites[index % sites.count]) : nil
            // unselected, so a URL-less tab doesn't open the ⌘T bar
            let tab = manager.newTab(url: url, select: false)
            if url == nil {
                tab.webView.loadHTMLString(
                    BenchPage.html(index: index),
                    baseURL: URL(string: "https://bench.artemis.example/page\(index)"))
            }
            manager.selectedTabID = tab.id
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

    /// launch milestones in seconds since exec, recorded on every launch
    nonisolated(unsafe) private static var marks: [(String, Double)] = []
    nonisolated(unsafe) private static let markLock = NSLock()

    nonisolated(unsafe) private static var markedOnce: Set<String> = []

    /// for marks that sit inside something that runs repeatedly (a `body`), where
    /// only the first time is the launch milestone
    nonisolated static func markOnce(_ name: String) {
        markLock.lock()
        let isFirst = markedOnce.insert(name).inserted
        markLock.unlock()
        guard isFirst else { return }
        mark(name)
    }

    nonisolated static func mark(_ name: String) {
        let t = processStartInterval()
        markLock.lock()
        marks.append((name, t))
        markLock.unlock()
    }

    // MARK: - Launch

    /// `ARTEMIS_BENCH=launch`: log the time from exec to a window on screen, then quit;
    /// timed from the kernel's process start, so dyld and static inits count
    static var isLaunchRequested: Bool {
        ProcessInfo.processInfo.environment["ARTEMIS_BENCH"] == "launch"
    }

    static func reportLaunch() async {
        // lets the first frame reach the screen rather than merely be scheduled
        try? await Task.sleep(for: .milliseconds(50))
        let elapsed = processStartInterval()
        let madeAtWindow = BrowserTab.webViewsMade
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
        if let paint = await BenchFrames.firstPaintLine() { lines.insert(paint, at: 3) }
        markLock.lock()
        let later = marks.filter { $0.1 > last }.sorted { $0.1 < $1.1 }
        markLock.unlock()
        for (name, at) in later {
            lines.append(String(format: "%8.0f  (+%6.0f)  %@", at * 1000, (at - last) * 1000, name as NSString))
            last = at
        }
        try? await Task.sleep(for: .seconds(max(0, elapsed + 10 - processStartInterval())))
        lines.insert("web views made: \(madeAtWindow) at window, \(BrowserTab.webViewsMade) 10 s later", at: 4)
        flush()
        NSApp.terminate(nil)
    }

    /// seconds since this process was exec'd, from the kernel's process table
    nonisolated private static func processStartInterval() -> Double {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return 0 }
        let started = info.kp_proc.p_starttime
        let start = Double(started.tv_sec) + Double(started.tv_usec) / 1_000_000
        return Date().timeIntervalSince1970 - start
    }

    // MARK: - Mechanism probes

    /// asks the pages themselves how many frames they ran: the background one
    /// should have stopped, the foreground one must not have
    private static func probes(manager: TabManager, bench: Space, other: Space) async {
        lines.append("mechanism probes")
        lines.append(String(repeating: "-", count: 78))

        // WebKit hides every page of a window that isn't frontmost
        takeFront()
        try? await Task.sleep(for: .milliseconds(800))

        // a neighbouring space's page stays mounted, but must not keep running
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
        if BenchFrames.isRequested { return await BenchFrames.run(manager: manager) }
        lines = ["Artemis bench (\(runLabel)) — \(Date())", ""]
        results = []

        await SelfTest.yieldScreen { lines.append($0); flush() }
        takeFront()
        // a launch onto an empty space opens the ⌘T bar; every phase runs without it
        manager.isCommandBarVisible = false
        try? await Task.sleep(for: .seconds(2))
        // one size on the fastest panel, so a 60Hz main display can't cap the run
        if let screen = NSScreen.screens.max(by: { $0.maximumFramesPerSecond < $1.maximumFramesPerSecond }),
            let window = SelfTest.mainWindow()
        {
            let area = screen.visibleFrame
            let size = CGSize(width: min(1400, area.width), height: min(860, area.height))
            window.setFrame(
                CGRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2,
                    width: size.width, height: size.height),
                display: true)
            lines.append("screen \(screen.localizedName) \(screen.maximumFramesPerSecond)Hz")
        }

        // App Nap throttles a background app's timers ~10x; hold it off for the run
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled, .latencyCritical],
            reason: "artemis bench")
        defer { ProcessInfo.processInfo.endActivity(activity) }

        let counter = FrameCounter()
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

        // extensions are off unless `ARTEMIS_BENCH_EXTENSIONS=1`; `isMasterEnabled`
        // is persisted, so every exit path restores it before terminating
        let extensionsWereEnabled = ExtensionManager.shared.isMasterEnabled
        defer { ExtensionManager.shared.isMasterEnabled = extensionsWereEnabled }
        if ProcessInfo.processInfo.environment["ARTEMIS_BENCH_EXTENSIONS"] == nil {
            ExtensionManager.shared.isMasterEnabled = false
            lines.append("(extensions disabled for this run)")
            lines.append("")
        }

        // first launch compiles the blocker's rules in the background
        await ContentBlocker.shared.waitForIdle()
        lines.append(ContentBlocker.shared.statusLine)
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

        if ProcessInfo.processInfo.environment["ARTEMIS_BENCH_LOOP"] == "sleep" {
            await sleepBench(manager, bench: bench)
            isCounting = false
            counter.stop()
            manager.selectSpace(home)
            for stale in manager.spaces where stale.name.hasPrefix("Bench") { manager.deleteSpace(stale) }
            manager.saveNow()
            SelfTest.forgetTestTraces(manager)
            flush()
            ExtensionManager.shared.isMasterEnabled = extensionsWereEnabled
            try? await Task.sleep(for: .milliseconds(500))
            NSApp.terminate(nil)
            return
        }

        // `ARTEMIS_BENCH_LOOP=<case>` repeats one interaction for a minute, steady
        // enough for a profiler to attach to
        if let loop = ProcessInfo.processInfo.environment["ARTEMIS_BENCH_LOOP"] {
            let tabs = await openTabs(manager)
            let split = loop == "split" ? manager.createSplit(Array(tabs.prefix(2))) : nil
            try? await Task.sleep(for: .seconds(1))
            var newTabs: [BrowserTab] = []
            var stepDirection = 1
            // the selected space's index; turns `stepDirection` around at either end
            @discardableResult func bounce() -> Int {
                let at = manager.spaces.firstIndex { $0.id == manager.selectedSpaceID } ?? 0
                if at == manager.spaces.count - 1 { stepDirection = -1 } else if at == 0 { stepDirection = 1 }
                return at
            }
            // ARTEMIS_BENCH_SYNC: lay out and draw each step at once and time it, so a
            // step's main-thread cost is measured even with no display to drive frames
            let sync = ProcessInfo.processInfo.environment["ARTEMIS_BENCH_SYNC"] != nil
            var stepTimes: [Double] = []
            var loadWall: [Double] = [], loadPage: [Double] = [], loadPaint: [Double] = []
            // the bar's field takes the keyboard only in the key window, so "bar" needs the front
            var barField: NSTextView?
            var barPhrases = 0, barMangled = 0
            let keyGap = Int(ProcessInfo.processInfo.environment["ARTEMIS_BENCH_KEY_GAP_MS"] ?? "") ?? 150
            if loop == "bar", let window = SelfTest.mainWindow() {
                manager.openNewTabBar()
                for _ in 0..<24 where barField == nil {
                    try? await Task.sleep(for: .milliseconds(250))
                    barField = window.firstResponder as? NSTextView
                }
                if barField == nil {
                    lines.append("WARNING: the bar's field never took the keyboard — keystrokes are NOT measured")
                }
            }
            // ARTEMIS_BENCH_MARK: a 20 pt square child window in the bottom-right corner flips
            // black/white as each step starts, committed before the step's update, for screen recordings
            let mark: CALayer? = ProcessInfo.processInfo.environment["ARTEMIS_BENCH_MARK"] == nil
                ? nil
                : SelfTest.mainWindow().flatMap { window in
                    let corner = NSRect(x: window.frame.maxX - 30, y: window.frame.minY + 10, width: 20, height: 20)
                    let panel = NSPanel(
                        contentRect: corner, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
                        defer: false)
                    panel.contentView?.wantsLayer = true
                    window.addChildWindow(panel, ordered: .above)
                    panel.contentView?.layer?.actions = ["backgroundColor": NSNull()]
                    return panel.contentView?.layer
                }
            if ProcessInfo.processInfo.environment["ARTEMIS_BENCH_MARK"] != nil, mark == nil {
                lines.append("WARNING: no step mark")
            }
            var steps = 0
            let meter = BusyMeter()
            let timeline = ProcessInfo.processInfo.environment["ARTEMIS_BENCH_TIMELINE"] != nil
            var stepStarts: [CFTimeInterval] = []
            if timeline {
                meter.spans = []
                counter.stamps = []
            }
            meter.start()
            Coverage.mark("_launch")
            await phase("loop-\(loop)", counter: counter) {
                let deadline = Date().addingTimeInterval(60)
                var i = 0
                while Date() < deadline {
                    let stepStart = CACurrentMediaTime()
                    stepStarts.append(stepStart)
                    if let mark {
                        mark.backgroundColor = (i.isMultiple(of: 2) ? NSColor.white : NSColor.black).cgColor
                        CATransaction.flush()
                    }
                    switch loop {
                    case "tab": manager.selectedTabID = tabs[i % tabs.count].id
                    // flipping between two pages
                    case "tab2": manager.selectedTabID = tabs[i % 2].id
                    case "space": manager.selectSpace(i.isMultiple(of: 2) ? home : bench)
                    // ⌘⌥→ along the row of spaces and back: each switch is to a neighbour
                    case "step":
                        bounce()
                        manager.cycleSpace(by: stepDirection)
                    // a two-finger swipe writes the position by hand once per scroll event
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
                        let at = bounce()
                        manager.spacePagePosition = Double(at + stepDirection)
                        manager.backdropPosition = manager.spacePagePosition
                        manager.selectSpace(at: at + stepDirection, animatePosition: false)
                    // a hand swipe to the neighbour, along every space and back; a flick is
                    // shorter, and the next one starts while the last is still settling
                    case "swipeall", "flick":
                        let at = bounce()
                        let frameCount = loop == "flick" ? 12 : 24
                        for step in 1...frameCount {
                            manager.spacePagePosition =
                                Double(at) + Double(stepDirection) * Double(step) / Double(frameCount)
                            manager.backdropPosition = manager.spacePagePosition
                            try? await Task.sleep(for: .milliseconds(8))
                        }
                        manager.selectSpace(at: at + stepDirection, animatePosition: false)
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
                    // a divider dragged a quarter of the way across and back, one
                    // resize per mouse event like `SplitDivider`
                    case "split":
                        guard let split,
                            let divider = split.root.dividers(
                                in: CGRect(x: 0, y: 0, width: 1000, height: 1000), gap: splitPaneGap
                            ).first
                        else { break }
                        for step in 1...24 {
                            split.resize(
                                path: divider.path, boundary: divider.boundary, by: step <= 12 ? 0.02 : -0.02)
                            try? await Task.sleep(for: .milliseconds(8))
                        }
                        manager.commitSplitLayout(split)
                    // nothing at all: what the app burns with its tabs open and no one at it
                    case "idle": break
                    // one keystroke in the ⌘T bar every `ARTEMIS_BENCH_KEY_GAP_MS` (150); each
                    // phrase is checked for lost keys before the next replaces it
                    case "bar":
                        guard let field = barField else { break }
                        let phrase = Array("bench page \(i / 12 % 60)")
                        let at = i % 12
                        if at == 0, i > 0 {
                            let typed = String(Array("bench page \((i - 1) / 12 % 60)").prefix(12))
                            barPhrases += 1
                            if !field.string.lowercased().hasPrefix(typed) { barMangled += 1 }
                        }
                        if at == 0 {
                            field.insertText(
                                String(phrase[0]), replacementRange: NSRange(location: 0, length: field.string.utf16.count))
                        } else if at < phrase.count {
                            field.insertText(String(phrase[at]), replacementRange: field.selectedRange())
                        }
                    // a page loads in a tab nobody is looking at; `ARTEMIS_BENCH_URL` loads a real one
                    case "load":
                        let tab = tabs[0]
                        let t0 = CACurrentMediaTime()
                        if let url = ProcessInfo.processInfo.environment["ARTEMIS_BENCH_URL"].flatMap(URL.init) {
                            tab.load(url)
                        } else {
                            tab.webView.loadHTMLString(
                                BenchPage.html(index: i % 8),
                                baseURL: URL(string: "https://bench.artemis.example/load\(i)"))
                        }
                        try? await Task.sleep(for: .milliseconds(20))
                        while tab.webView.isLoading, CACurrentMediaTime() - t0 < 30 {
                            try? await Task.sleep(for: .milliseconds(5))
                        }
                        loadWall.append((CACurrentMediaTime() - t0) * 1000)
                        let timing = try? await tab.webView.evaluateJavaScript("""
                            (() => { const n = performance.getEntriesByType('navigation')[0];
                              const p = performance.getEntriesByName('first-contentful-paint')[0];
                              return [n ? n.loadEventEnd : -1, p ? p.startTime : -1] })()
                            """) as? [Double]
                        loadPage.append(timing?.first ?? -1)
                        loadPaint.append(timing?.last ?? -1)
                    case "sidebar":
                        manager.isSidebarCollapsed = !i.isMultiple(of: 2)
                    case "agent":
                        manager.isAgentPanelVisible = !i.isMultiple(of: 2)
                    case "library":
                        withAnimation(Motion.panel) { manager.isLibraryOpen = !manager.isLibraryOpen }
                    // the Library held open, flipping between its three lists
                    case "libmode":
                        manager.openLibrary([LibraryMode.archive, .downloads, .history][i % 3])
                    // ⌘T, a beat to type, Enter: the bar closes as the page opens
                    case "newtab":
                        manager.requestNewTab()
                        try? await Task.sleep(for: .milliseconds(300))
                        manager.isCommandBarVisible = false
                        let opened = manager.newTab(select: false)
                        manager.selectedTabID = opened.id
                        opened.webView.loadHTMLString(
                            BenchPage.html(index: i % 8),
                            baseURL: URL(string: "https://bench.artemis.example/new\(i)"))
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
                    // an app out of the foreground isn't asked to draw at all
                    if i.isMultiple(of: 10) {
                        takeFront()
                    }
                    try? await Task.sleep(for: .milliseconds(loop == "bar" ? keyGap : loop == "flick" ? 150 : 400))
                }
            }
            meter.stop()
            if timeline {
                lines.append(contentsOf: timelineReport(stepStarts, meter.spans ?? [], counter.stamps ?? []))
                lines.append(contentsOf: lockstepReport(stepStarts, counter.stamps ?? [], counter.shown))
            }
            Coverage.mark("loop-\(loop)")
            lines.append(String(
                format: "main busy per step ms: %.2f  longest stall ms: %.1f  steps %d",
                meter.busy * 1000 / Double(max(steps, 1)), meter.longest * 1000, steps))
            if barPhrases > 0 {
                lines.append("bar phrases mangled: \(barMangled) of \(barPhrases) at \(keyGap) ms a key")
            }
            for (name, values) in [
                ("load wall ms", loadWall), ("load loadEventEnd ms", loadPage), ("load FCP ms", loadPaint),
            ] where !values.isEmpty {
                let sorted = values.sorted()
                lines.append(String(
                    format: "%@: median %.1f  p90 %.1f  n %d",
                    name as NSString, sorted[sorted.count / 2], sorted[sorted.count * 9 / 10], sorted.count))
            }
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

        // a second space exercises the warm-neighbour mount, where a background
        // page stays mounted and could keep rendering
        let other = manager.createSpace(
            name: "Bench2", icon: "gauge", appearance: SpacePreset.all[2].appearance,
            profileID: Profile.defaultID)
        other.selectedTab?.webView.loadHTMLString(
            BenchPage.html(index: 99), baseURL: URL(string: "https://bench.artemis.example/page99"))
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
        // tools/bench-report.py joins these rows with tools/bench-sample.sh
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
