// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import AppKit
import WebKit

@_silgen_name("responsibility_get_pid_responsible_for_pid")
private func responsiblePID(_ pid: pid_t) -> pid_t

/// `ARTEMIS_BENCH=frames`: idle cost and page frames. Opens `ARTEMIS_FRAMES_TABS` (10) tabs of
/// `ARTEMIS_FRAMES_PAGE` (quiet | busy) in a space, one busy page in the next space (mounted,
/// hidden), then meters `ARTEMIS_FRAMES_SECONDS` (30) of idle: CPU, wakeups and energy per process
/// this app is responsible for, and each page's rAF and timer rate by how it is held
@MainActor
enum BenchFrames {
    static var isRequested: Bool { ["frames", "seed"].contains(ProcessInfo.processInfo.environment["ARTEMIS_BENCH"]) }

    private static let env = ProcessInfo.processInfo.environment
    private static var lines: [String] = []

    static func run(manager: TabManager) async {
        // `ARTEMIS_BENCH=seed ARTEMIS_FRAMES_URL=…`: leave a session of `ARTEMIS_FRAMES_TABS` (1) tabs
        // on that page, the last one selected, for launch runs
        if env["ARTEMIS_BENCH"] == "seed", let url = env["ARTEMIS_FRAMES_URL"].flatMap(URL.init(string:)) {
            for tab in manager.currentSpace.tabs { manager.close(tab) }
            for index in 0..<max(Int(env["ARTEMIS_FRAMES_TABS"] ?? "") ?? 1, 1) {
                manager.newTab(url: URL(string: "\(url.absoluteString)?\(index)") ?? url)
            }
            try? await Task.sleep(for: .seconds(3))
            manager.saveNow()
            try? await Task.sleep(for: .seconds(1))
            return NSApp.terminate(nil)
        }
        let label = env["ARTEMIS_BENCH_LABEL"] ?? "frames"
        let count = max(Int(env["ARTEMIS_FRAMES_TABS"] ?? "") ?? 10, 1)
        let kind = env["ARTEMIS_FRAMES_PAGE"] ?? "quiet"
        let seconds = Double(env["ARTEMIS_FRAMES_SECONDS"] ?? "") ?? 30
        lines = ["Artemis frames bench (\(label)) — \(Date())",
            "tabs \(count) \(kind), off: \(env["ARTEMIS_PERF_OFF"] ?? "none")",
            "screen \(NSScreen.main.map { "\($0.maximumFramesPerSecond)Hz" } ?? "?")", ""]

        let background = env["ARTEMIS_BENCH_BACKGROUND"] != nil
        if !background {
            NSApp.activate(ignoringOtherApps: true)
            SelfTest.mainWindow()?.makeKeyAndOrderFront(nil)
        }
        // behind other windows: no App Nap, and the shown page counts as on screen (see `occlusion`)
        let activity = background ? ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "frames bench") : nil
        defer { activity.map(ProcessInfo.processInfo.endActivity) }
        manager.isCommandBarVisible = false
        let extensionsWereEnabled = ExtensionManager.shared.isMasterEnabled
        ExtensionManager.shared.isMasterEnabled = false
        await ContentBlocker.shared.waitForIdle()

        for stale in manager.spaces where stale.name.hasPrefix("Frames") { manager.deleteSpace(stale) }
        let home = manager.currentSpace
        let appearance = SpacePreset.all[1].appearance
        let space = manager.createSpace(name: "Frames", icon: "gauge", appearance: appearance, profileID: Profile.defaultID)
        let neighbour = manager.createSpace(name: "Frames2", icon: "gauge", appearance: appearance, profileID: Profile.defaultID)
        manager.selectSpace(neighbour)
        try? await Task.sleep(for: .milliseconds(500))
        let warm = manager.newTab(in: neighbour)
        warm.webView.loadHTMLString(page("busy", 99), baseURL: URL(string: "https://frames.artemis.example/n"))
        manager.selectSpace(space)
        try? await Task.sleep(for: .milliseconds(500))
        var tabs: [BrowserTab] = []
        for index in 0..<count {
            let tab = manager.newTab(in: space)
            tab.webView.loadHTMLString(page(kind, index), baseURL: URL(string: "https://frames.artemis.example/\(index)"))
            tabs.append(tab)
            try? await Task.sleep(for: .milliseconds(200))
        }
        // `ARTEMIS_FRAMES_AUDIO`: tab 2 starts a near-silent tone on screen, then plays on hidden
        var audio: String?
        if env["ARTEMIS_FRAMES_AUDIO"] != nil, tabs.count > 1 {
            manager.selectedTabID = tabs[1].id
            try? await Task.sleep(for: .seconds(1))
            audio = (try? await tabs[1].webView.callAsyncJavaScript("""
                const c = new AudioContext(), o = c.createOscillator(), g = c.createGain();
                g.gain.value = 0.0005; o.frequency.value = 30; o.connect(g).connect(c.destination); o.start();
                await Promise.race([c.resume(), new Promise(r => setTimeout(r, 1000))]); return c.state
                """, contentWorld: .page)) as? String ?? "failed"
        }
        // the first tab is the one on screen; the rest are unmounted
        manager.selectedTabID = tabs[0].id
        try? await Task.sleep(for: .seconds(1))
        if background { occlusion(tabs[0].webView, false) }
        try? await Task.sleep(for: .seconds(7))

        let pages = [warm] + tabs
        let window = tabs[0].webView.window
        if let audio { lines.append("tab 2 audio: \(audio), playing \(tabs[1].isPlayingMediaContent)") }
        lines.append("window visible \(window?.occlusionState.contains(.visible) == true), key \(window?.isKeyWindow == true), app active \(NSApp.isActive)")
        let counters0 = await counters(pages)
        let usage0 = usage()
        let clock0 = Date()
        try? await Task.sleep(for: .seconds(seconds))
        let wall = Date().timeIntervalSince(clock0)
        let usage1 = usage()
        let counters1 = await counters(pages)

        lines.append("process              pid   cpu%   wakeups/s   mW")
        lines.append(String(repeating: "-", count: 56))
        var total = (cpu: 0.0, wakeups: 0.0, energy: 0.0)
        for (pid, after) in usage1.sorted(by: { $0.value.name < $1.value.name }) {
            guard let before = usage0[pid] else { continue }
            let cpu = (after.cpu - before.cpu) / wall * 100
            let wakeups = Double(after.wakeups - before.wakeups) / wall
            let energy = Double(after.energy - before.energy) / wall / 1e6
            total = (total.cpu + cpu, total.wakeups + wakeups, total.energy + energy)
            lines.append(pad(after.name, 18) + String(format: " %6d %6.2f %10.1f %7.1f", pid, cpu, wakeups, energy))
        }
        lines.append(pad("TOTAL", 25) + String(format: " %6.2f %10.1f %7.1f", total.cpu, total.wakeups, total.energy))
        lines.append("")
        lines.append("page          held        visibility   rAF/s  timers/s")
        lines.append(String(repeating: "-", count: 56))
        for (index, tab) in pages.enumerated() {
            let before = counters0[index], after = counters1[index]
            let held = tab.id == manager.displayedContentTab?.id ? "shown" : (tab.webView.window != nil ? "mounted" : "unmounted")
            lines.append(pad(index == 0 ? "neighbour" : "tab \(index)\(index == 2 && env["ARTEMIS_FRAMES_AUDIO"] != nil ? " ♪" : "")", 14) + pad(held, 12) + pad(after.visibility, 10)
                + String(format: " %7.1f %9.1f", Double(after.frames - before.frames) / wall, Double(after.timers - before.timers) / wall))
        }
        lines.append(String(format: "#csv cpu=%.3f wakeups=%.1f mW=%.1f", total.cpu, total.wakeups, total.energy))
        lines.append("")
        lines.append("done \(Date())")

        if background { occlusion(tabs[0].webView, true) }
        manager.selectSpace(home)
        manager.deleteSpace(space)
        manager.deleteSpace(neighbour)
        manager.saveNow()
        SelfTest.forgetTestTraces(manager)
        ExtensionManager.shared.isMasterEnabled = extensionsWereEnabled
        let url = env["ARTEMIS_BENCH_DIR"].map { URL(fileURLWithPath: $0).appending(path: "artemis-bench-\(label).log") }
            ?? AppStorageLocation.devFile("artemis-bench-\(label)", "log")
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        try? await Task.sleep(for: .milliseconds(500))
        NSApp.terminate(nil)
    }

    private static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text + " " : text + String(repeating: " ", count: width - text.count)
    }

    private static func occlusion(_ webView: WKWebView, _ enabled: Bool) {
        let selector = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        guard webView.responds(to: selector) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(webView.method(for: selector), to: Setter.self)(webView, selector, enabled)
    }

    /// ms from exec to the shown page's first contentful paint, waiting up to 10s for it
    static func firstPaintLine() async -> String? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return nil }
        let start = Double(info.kp_proc.p_starttime.tv_sec) * 1000 + Double(info.kp_proc.p_starttime.tv_usec) / 1000
        let script = "(e => e ? performance.timeOrigin + e.startTime : 0)(performance.getEntriesByName('first-contentful-paint')[0])"
        for _ in 0..<200 {
            // `madeWebView`: the probe must never build the page it is timing
            if let page = BrowserWindows.shared.mainManagers.first?.displayedContentTab?.madeWebView,
                let paint = try? await page.evaluateJavaScript(script) as? Double, paint > 0
            {
                return String(format: "exec → first page paint: %.0f ms (%@)", paint - start, page.url?.absoluteString ?? "?")
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        let tab = BrowserWindows.shared.mainManagers.first?.displayedContentTab
        return "exec → first page paint: none within 10s (tab \(tab?.madeWebView?.url?.absoluteString ?? "nil"), pending \(tab?.pendingURL?.absoluteString ?? "nil"))"
    }

    /// quiet: a static article. busy: a rAF loop, a 10ms interval and a CSS animation
    private static func page(_ kind: String, _ index: Int) -> String {
        let text = String(repeating: "<p>Static text for an idle page, nothing scheduled and nothing moving.</p>", count: 40)
        let busy = kind == "busy" ? """
            <style>@keyframes s{to{transform:rotate(1turn)}}.s{width:40px;height:40px;background:#48f;animation:s 1s linear infinite}</style>
            <div class=s></div>
            <script>(function f(){window.__frames++;requestAnimationFrame(f)})();setInterval(()=>window.__timers++,10)</script>
            """ : ""
        return """
            <!doctype html><title>Frames \(index)</title><body style="font:16px -apple-system;max-width:720px;margin:40px auto">
            <script>window.__frames=0;window.__timers=0</script><h1>Frames \(index)</h1>\(busy)\(text)</body>
            """
    }

    private struct Counters { var frames = 0, timers = 0, visibility = "?" }

    private static func counters(_ tabs: [BrowserTab]) async -> [Counters] {
        var out: [Counters] = []
        for tab in tabs {
            let value = try? await tab.webView.evaluateJavaScript("[window.__frames|0, window.__timers|0, document.visibilityState]")
            let array = value as? [Any] ?? []
            out.append(Counters(
                frames: array.first as? Int ?? 0, timers: array.dropFirst().first as? Int ?? 0,
                visibility: array.last as? String ?? "?"))
        }
        return out
    }

    private struct Usage { var name: String, cpu: Double, wakeups: UInt64, energy: UInt64 }

    /// this process and every process it is responsible for (WebKit's content, GPU, networking)
    private static func usage() -> [pid_t: Usage] {
        var pids = [pid_t](repeating: 0, count: 8192)
        let n = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        var timebase = mach_timebase_info()
        mach_timebase_info(&timebase)
        let me = getpid()
        var out: [pid_t: Usage] = [:]
        for pid in pids.prefix(max(n, 0)) where pid > 0 && (pid == me || responsiblePID(pid) == me) {
            var info = rusage_info_v6()
            let rc = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
            }
            guard rc == 0 else { continue }
            var name = [CChar](repeating: 0, count: 256)
            proc_name(pid, &name, 256)
            let ticks = Double(info.ri_user_time + info.ri_system_time)
            out[pid] = Usage(
                name: String(cString: name).replacingOccurrences(of: "com.apple.WebKit.", with: ""),
                cpu: ticks * Double(timebase.numer) / Double(timebase.denom) / 1e9,
                wakeups: info.ri_interrupt_wkups + info.ri_pkg_idle_wkups, energy: info.ri_energy_nj)
        }
        return out
    }
}
