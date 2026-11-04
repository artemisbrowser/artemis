import AppKit
import SwiftUI
import WebKit

@objc private protocol WKPreferencesPeerConnectionSPI {
    func _setPeerConnectionEnabled(_ enabled: Bool)
}

/// `ARTEMIS_DIAG=extlab`: installs each package in `queue.txt` alone, exercises its background,
/// content scripts, popup and options page, removes it and appends one JSON verdict to
/// `results.jsonl`. finished keys are skipped, so a run resumes
@MainActor
enum ExtensionLab {
    /// the lab and the perf bundle (`ARTEMIS_DIAG=perf`, tools/perflab.sh) both run fenced:
    /// no prompt, no modal, no keychain
    nonisolated static let isRequested = AppStorageLocation.isExtensionLab
    nonisolated static let isSweep = ProcessInfo.processInfo.environment["ARTEMIS_DIAG"] == "extlab"

    /// WebRTC's interface scan raises macOS's Local Network prompt; the lab must never prompt
    nonisolated static func quiet(_ preferences: WKPreferences) {
        guard isRequested, preferences.responds(to: Selector(("_setPeerConnectionEnabled:"))) else { return }
        unsafeBitCast(preferences, to: WKPreferencesPeerConnectionSPI.self)._setPeerConnectionEnabled(false)
    }

    /// outside every folder macOS asks consent for; the lab's signature carries a
    /// sandbox exception for exactly this path (tools/extlab.sh)
    private static let root = URL(fileURLWithPath: "/private/tmp/artemis-extlab", isDirectory: true)

    /// `ARTEMIS_EXTLAB_RUN=name` keeps a run's verdicts and shots in runs/name,
    /// so two builds can sweep the same queue side by side
    private static let output: URL = {
        guard let run = ProcessInfo.processInfo.environment["ARTEMIS_EXTLAB_RUN"] else { return root }
        let dir = root.appendingPathComponent("runs/\(run)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// shim reports for the extension under test, keyed by context id
    private static var reports: [String: [(level: String, text: String)]] = [:]

    static func record(_ message: [String: Any], from context: WKWebExtensionContext) {
        guard isSweep, message["artemisCompat"] as? String == "log" else { return }
        reports[context.uniqueIdentifier, default: []].append(
            (message["level"] as? String ?? "log", message["text"] as? String ?? ""))
    }

    static func run(manager: TabManager) async {
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled], reason: "extension lab")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        try? await Task.sleep(for: .seconds(3))

        let em = ExtensionManager.shared
        if let key = ProcessInfo.processInfo.environment["ARTEMIS_EXTLAB_MIGRATION"] {
            await migration(key: key, manager: manager)
            return NSApp.terminate(nil)
        }
        if let key = ProcessInfo.processInfo.environment["ARTEMIS_EXTLAB_SETTINGSSHOT"] {
            await settingsShot(key: key, manager: manager)
            return NSApp.terminate(nil)
        }
        if let key = ProcessInfo.processInfo.environment["ARTEMIS_EXTLAB_PROXYISO"] {
            await proxyIsolation(key: key, manager: manager)
            return NSApp.terminate(nil)
        }
        if let key = ProcessInfo.processInfo.environment["ARTEMIS_EXTLAB_ISOLATION"] {
            await isolation(key: key, manager: manager)
            return NSApp.terminate(nil)
        }
        if let key = ProcessInfo.processInfo.environment["ARTEMIS_EXTLAB_PAGES"] {
            await pages(key: key, manager: manager)
            return NSApp.terminate(nil)
        }
        if let key = ProcessInfo.processInfo.environment["ARTEMIS_EXTLAB_PERSIST"] {
            await persist(key: key)
            return NSApp.terminate(nil)
        }
        for ext in em.installed { em.remove(ext) }
        // a proxy left by a package that crashed the last run would stall every page after it
        ExtensionProxyBridge.shared.releaseAll()
        // a crashed run leaves its tabs in the session, and their pages would
        // host the next run's content scripts
        for tab in manager.allTabs where !tab.isEssential { discard(tab, from: manager) }

        let results = output.appendingPathComponent("results.jsonl")
        let done = Set(
            ((try? String(contentsOf: results, encoding: .utf8)) ?? "").split(separator: "\n")
                .compactMap { line in
                    (try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])?["key"]
                        as? String
                })
        let queueFile = ProcessInfo.processInfo.environment["ARTEMIS_EXTLAB_QUEUE"] ?? "queue.txt"
        let queue = ((try? String(contentsOf: root.appendingPathComponent(queueFile), encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init).filter { !$0.isEmpty && !done.contains($0) }

        // `ARTEMIS_EXTLAB_BATCH=n` relaunches every n packages: a long session drifts, its
        // content scripts sending from pages no tab owns
        let batch = Int(ProcessInfo.processInfo.environment["ARTEMIS_EXTLAB_BATCH"] ?? "") ?? .max
        for (index, key) in queue.enumerated() {
            if index == batch {
                try? Data().write(to: output.appendingPathComponent("batch-exit"))
                return NSApp.terminate(nil)
            }
            let verdict = await test(key: key, manager: manager)
            append(verdict, to: results)
        }
        append(["key": "__done__", "at": Date().timeIntervalSince1970], to: results)
        // `ARTEMIS_EXTLAB_HOLD=1` stays up for heap inspection
        guard ProcessInfo.processInfo.environment["ARTEMIS_EXTLAB_HOLD"] == nil else { return }
        NSApp.terminate(nil)
    }

    /// `ARTEMIS_EXTLAB_PERSIST=key`: keep one package installed across launches
    /// and record what it reports on each boot, to prove its state survives
    private static func persist(key: String) async {
        let em = ExtensionManager.shared
        for other in em.installed where !key.contains(other.id) && other.name != "Lab Persist Probe" {
            em.remove(other)
        }
        var ext = em.installed.first
        if ext == nil, let fresh = try? await em.installFromDisk(root.appendingPathComponent(key)) {
            em.setEnabled(fresh, true)
            ext = fresh
        }
        guard let ext else { return }
        try? await Task.sleep(for: .seconds(6))
        // `ARTEMIS_EXTLAB_RELOAD=1` loads it again past WebKit's five-second launch window
        if ProcessInfo.processInfo.environment["ARTEMIS_EXTLAB_RELOAD"] != nil {
            em.setEnabled(ext, false)
            em.setEnabled(ext, true)
            try? await Task.sleep(for: .seconds(6))
        }
        append([
            "key": key, "at": Date().timeIntervalSince1970,
            "id": ext.context.uniqueIdentifier, "baseURL": ext.context.baseURL.absoluteString,
            "console": (reports.removeValue(forKey: ext.context.uniqueIdentifier) ?? []).map(\.text),
        ], to: output.appendingPathComponent("results.jsonl"))
    }

    /// `ARTEMIS_EXTLAB_ISOLATION=key`: one package in two profiles. each instance
    /// reports what it can reach; then it is switched off in the second profile
    /// and a page there must not run its content script
    private static func isolation(key: String, manager: TabManager) async {
        let em = ExtensionManager.shared
        for ext in em.installed { em.remove(ext) }
        let other = manager.profiles.first { $0.name == "Lab B" }
            ?? manager.createProfile(name: "Lab B", icon: "flask")
        let home = manager.spaces.first { $0.profileID == Profile.defaultID }!
        let away = manager.spaces.first { $0.profileID == other.id }
            ?? manager.createSpace(name: "Lab B", icon: "flask", appearance: home.appearance, profileID: other.id)
        guard let ext = try? await em.installFromDisk(root.appendingPathComponent(key)) else { return }
        em.setEnabled(ext, true)

        manager.selectSpace(home)
        _ = manager.newTab(url: URL(string: "https://example.com/?profile=A")!)
        try? await Task.sleep(for: .seconds(5))
        manager.selectSpace(away)
        _ = manager.newTab(url: URL(string: "https://example.org/?profile=B")!)
        try? await Task.sleep(for: .seconds(8))

        em.setEnabled(ext, false, in: other.id)
        _ = manager.newTab(url: URL(string: "https://example.net/?profile=B-after-off")!)
        try? await Task.sleep(for: .seconds(6))

        append([
            "key": key, "at": Date().timeIntervalSince1970, "profiles": ext.profiles.map(\.uuidString),
            "console": (reports.removeValue(forKey: ext.id) ?? []).map(\.text),
        ], to: output.appendingPathComponent("results.jsonl"))
        em.remove(ext)
    }

    /// `ARTEMIS_EXTLAB_SETTINGSSHOT=key`: Settings › Extensions with the package
    /// installed and a second profile, drawn off screen into settings-extensions.png
    private static func settingsShot(key: String, manager: TabManager) async {
        let em = ExtensionManager.shared
        for ext in em.installed { em.remove(ext) }
        if !manager.profiles.contains(where: { $0.name == "Lab B" }) {
            _ = manager.createProfile(name: "Lab B", icon: "flask")
        }
        guard let ext = try? await em.installFromDisk(root.appendingPathComponent(key)) else { return }
        em.setEnabled(ext, true, in: Profile.defaultID)
        UserDefaults.standard.set(Tab.extensions.rawValue, forKey: "settingsPane")
        // the opener, without SettingsView.open's activate: nothing may come to the front
        SettingsView.openSettingsAction?()
        try? await Task.sleep(for: .milliseconds(300))
        let window = NSApp.windows.first { $0.isVisible && $0.title == Tab.extensions.rawValue }
        window?.setFrameOrigin(NSPoint(x: -6000, y: -6000))
        window?.orderBack(nil)
        try? await Task.sleep(for: .seconds(3))
        if let view = window?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?
                .write(to: output.appendingPathComponent("settings-extensions.png"))
        }
        window?.close()
        em.remove(ext)
    }

    /// `ARTEMIS_EXTLAB_PROXYISO=key`: a proxy extension enabled in profile B only
    /// must route B's pages and leave A's direct; records what each tab loaded
    private static func proxyIsolation(key: String, manager: TabManager) async {
        let em = ExtensionManager.shared
        for ext in em.installed { em.remove(ext) }
        ExtensionProxyBridge.shared.releaseAll()
        let other = manager.profiles.first { $0.name == "Lab B" }
            ?? manager.createProfile(name: "Lab B", icon: "flask")
        let home = manager.spaces.first { $0.profileID == Profile.defaultID }!
        let away = manager.spaces.first { $0.profileID == other.id }
            ?? manager.createSpace(name: "Lab B", icon: "flask", appearance: home.appearance, profileID: other.id)
        guard let ext = try? await em.installFromDisk(root.appendingPathComponent(key)) else { return }
        manager.selectSpace(away)
        em.setEnabled(ext, true, in: other.id)
        try? await Task.sleep(for: .seconds(5))
        let url = URL(string: "https://example.com/?lab=\(Int(Date().timeIntervalSince1970))")!
        let inB = manager.newTab(url: url)
        await settle(inB, timeout: 10)
        manager.selectSpace(home)
        let inA = manager.newTab(url: url)
        await settle(inA, timeout: 10)
        let title = { (tab: BrowserTab) in
            await bounded(3) { try? await tab.webView.evaluateJavaScript("document.title") as? String } ?? nil
        }
        append([
            "key": key, "at": Date().timeIntervalSince1970,
            "profileA": ["title": await title(inA) ?? "", "proxied": ExtensionProxyBridge.shared.activeProxy(in: Profile.defaultID) != nil],
            "profileB": ["title": await title(inB) ?? "", "proxied": ExtensionProxyBridge.shared.activeProxy(in: other.id) != nil],
        ], to: output.appendingPathComponent("results.jsonl"))
        for tab in [inA, inB] { discard(tab, from: manager) }
        em.remove(ext)
    }

    /// `ARTEMIS_EXTLAB_MIGRATION=key`: a pre-profiles install reaching a second
    /// profile starts from the default profile's storage and hears no "install";
    /// a new per-profile enable starts fresh and does
    private static func migration(key: String, manager: TabManager) async {
        let em = ExtensionManager.shared
        for ext in em.installed { em.remove(ext) }
        let home = manager.spaces.first { $0.profileID == Profile.defaultID }!
        let profiles = ["Lab B", "Lab C"].map { name in
            manager.profiles.first { $0.name == name } ?? manager.createProfile(name: name, icon: "flask")
        }
        for profile in profiles where !manager.spaces.contains(where: { $0.profileID == profile.id }) {
            _ = manager.createSpace(name: profile.name, icon: "flask", appearance: home.appearance, profileID: profile.id)
        }
        manager.selectSpace(home)
        _ = manager.newTab(url: URL(string: "https://example.com/")!)
        guard let ext = try? await em.installFromDisk(root.appendingPathComponent(key)) else { return }
        em.setEnabled(ext, true, in: Profile.defaultID)
        try? await Task.sleep(for: .seconds(4))
        ext.seedsFromDefault = true
        try? await Task.sleep(for: .seconds(6))
        // a profile's controller exists once it has a tab
        let visit = { (profile: Profile) in
            if let space = manager.spaces.first(where: { $0.profileID == profile.id }) {
                manager.selectSpace(space)
                _ = manager.newTab(url: URL(string: "https://example.com/")!)
            }
        }
        visit(profiles[0])
        em.setEnabled(ext, true, in: profiles[0].id)
        try? await Task.sleep(for: .seconds(4))
        ext.seedsFromDefault = false
        visit(profiles[1])
        em.setEnabled(ext, true, in: profiles[1].id)
        try? await Task.sleep(for: .seconds(8))
        let names = [Profile.defaultID: "A", profiles[0].id: "B", profiles[1].id: "C"]
        append([
            "key": key, "at": Date().timeIntervalSince1970,
            "console": (reports.removeValue(forKey: ext.id) ?? []).map(\.text),
            "contexts": ext.contexts.map { profile, context in
                "\(names[profile] ?? "?") loaded=\(context.isLoaded) errors=\(context.errors.map(describe))"
            },
        ], to: output.appendingPathComponent("results.jsonl"))
        em.remove(ext)
    }

    /// `ARTEMIS_EXTLAB_PAGES=key` (empty: no package) with `ARTEMIS_EXTLAB_URLS=a,b,…`: each page's
    /// title, text, `ARTEMIS_EXTLAB_PROBE` (a JS expression) and snapshot with the package in place.
    /// `ARTEMIS_EXTLAB_NATIVE=off` runs without Artemis's own blocker
    private static func pages(key: String, manager: TabManager) async {
        let env = ProcessInfo.processInfo.environment
        let em = ExtensionManager.shared
        for ext in em.installed { em.remove(ext) }
        ContentBlocker.shared.isEnabled = env["ARTEMIS_EXTLAB_NATIVE"] != "off"
        var ext: InstalledExtension?
        if !key.isEmpty, let installed = try? await em.installFromDisk(root.appendingPathComponent(key)) {
            em.setEnabled(installed, true)
            ext = installed
        }
        // rulesets compile and scriptlets register in the background after install
        try? await Task.sleep(for: .seconds(15))
        let probe = env["ARTEMIS_EXTLAB_PROBE"] ?? "''"
        let read = "(() => { let probe; try { probe = String(\(probe)); } catch (e) { probe = 'probe threw ' + e; }"
            + " return JSON.stringify({ title: document.title, probe,"
            + " text: document.body ? document.body.innerText.slice(0, 2500) : '' }); })()"
        for (index, raw) in (env["ARTEMIS_EXTLAB_URLS"] ?? "").split(separator: ",").enumerated() {
            guard let url = URL(string: String(raw)) else { continue }
            let tab = manager.newTab(url: url)
            await settle(tab, timeout: 20)
            try? await Task.sleep(for: .seconds(8))
            // `ARTEMIS_EXTLAB_SETUP`: a page expression run first (start a video), then read 12s later
            if let setup = env["ARTEMIS_EXTLAB_SETUP"] {
                _ = await bounded(5) { try? await tab.webView.evaluateJavaScript(setup, contentWorld: .page) }
                try? await Task.sleep(for: .seconds(12))
            }
            let state = await bounded(8) {
                try? await tab.webView.evaluateJavaScript(read, contentWorld: .page) as? String
            } ?? nil
            append([
                "key": key, "url": url.absoluteString, "at": Date().timeIntervalSince1970,
                "native": ContentBlocker.shared.isEnabled,
                "state": state.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } ?? "evaluate failed",
                "shot": await snapshot(tab.webView, name: "page\(index)", part: key.isEmpty ? "none" : "ext") ?? "",
                "console": ext.map { (reports.removeValue(forKey: $0.context.uniqueIdentifier) ?? []).map(\.text) } ?? [],
            ], to: output.appendingPathComponent("results.jsonl"))
            discard(tab, from: manager)
        }
        if let ext { em.remove(ext) }
    }

    private static func append(_ object: [String: Any], to url: URL) {
        guard var line = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        else { return }
        line.append(0x0A)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(line)
            try? handle.close()
        } else {
            try? line.write(to: url)
        }
    }

    // MARK: - One package

    private static func test(key: String, manager: TabManager) async -> [String: Any] {
        let em = ExtensionManager.shared
        var verdict: [String: Any] = ["key": key, "at": Date().timeIntervalSince1970]
        let started = Date()
        // a Chrome window always has an active tab; backgrounds query it as they boot
        let resting = manager.newTab(url: URL(string: "about:blank")!, select: true)
        let tabsBefore = Set(manager.allTabs.map(\.id))

        let ext: InstalledExtension
        do {
            ext = try await em.installFromDisk(root.appendingPathComponent(key))
        } catch {
            verdict["install"] = "\(error.localizedDescription)"
            return verdict
        }
        verdict["name"] = ext.name
        verdict["version"] = ext.version ?? ""
        verdict["mv"] = Int(ext.webExtension.manifestVersion)
        verdict["parseErrors"] = ext.webExtension.errors.map(describe)
        verdict["unsupported"] = em.permissionCoverage(for: ext).missing

        em.setEnabled(ext, true)
        verdict["loaded"] = ext.context.isLoaded
        verdict["installMs"] = Int(Date().timeIntervalSince(started) * 1000)
        try? await Task.sleep(for: .seconds(4))

        let probe = probeURL(for: ext.webExtension.manifest)
        var tab: BrowserTab! = manager.newTab(url: probe, select: true)
        await settle(tab, timeout: 12)
        verdict["page"] = probe.absoluteString
        verdict["pageShot"] = await snapshot(tab.webView, name: key, part: "page")

        if let popup = await popupState(for: ext, key: key) { verdict["popup"] = popup }
        if let options = await optionsState(for: ext, key: key, manager: manager) {
            verdict["options"] = options
        }

        verdict["contextErrors"] = ext.context.errors.map(describe)
        verdict["injects"] = ext.context.hasInjectedContent(for: probe)
        verdict["console"] = (reports.removeValue(forKey: ext.context.uniqueIdentifier) ?? [])
            .prefix(200).map { "[\($0.level)] \($0.text)" }

        weak var closedProbe = tab
        // scoped so `opened` lets go of its tabs before the leak check
        do {
            let opened = manager.allTabs.filter { !tabsBefore.contains($0.id) && $0.id != tab.id }
            verdict["openedTabs"] = opened.compactMap { $0.url?.absoluteString }
            for extra in opened + [tab!, resting] { discard(extra, from: manager) }
        }
        tab = nil
        em.remove(ext)
        try? await Task.sleep(for: .seconds(1))
        verdict["probeTabFreed"] = closedProbe == nil
        verdict["totalMs"] = Int(Date().timeIntervalSince(started) * 1000)
        return verdict
    }

    /// a real page the content scripts target: the first concrete host in
    /// their match patterns, else a text-heavy article
    private static func probeURL(for manifest: [String: Any]) -> URL {
        let patterns = ((manifest["content_scripts"] as? [[String: Any]]) ?? [])
            .flatMap { ($0["matches"] as? [String]) ?? [] }
        for pattern in patterns {
            guard let hostStart = pattern.range(of: "://") else { continue }
            var host = pattern[hostStart.upperBound...].prefix { $0 != "/" }
            if host.hasPrefix("*.") { host = "www." + host.dropFirst(2) }
            guard !host.isEmpty, !host.contains("*"), host.contains("."),
                let url = URL(string: "https://\(host)/")
            else { continue }
            return url
        }
        return URL(string: "https://en.wikipedia.org/wiki/Web_browser")!
    }

    private static func settle(_ tab: BrowserTab, timeout: Double) async {
        let deadline = Date().addingTimeInterval(timeout)
        try? await Task.sleep(for: .milliseconds(500))
        while tab.isLoading, Date() < deadline { try? await Task.sleep(for: .milliseconds(250)) }
        try? await Task.sleep(for: .seconds(2))
    }

    // MARK: - UI surfaces

    private static let pageState = """
        (() => {
          const text = (document.body && document.body.innerText || "").trim();
          const box = document.body && document.body.getBoundingClientRect();
          return JSON.stringify({
            url: location.href, ready: document.readyState, title: document.title,
            chars: text.length, text: text.slice(0, 300),
            width: box ? Math.round(box.width) : 0, height: box ? Math.round(box.height) : 0,
            elements: document.getElementsByTagName("*").length,
            spinners: document.querySelectorAll('[class*=spinner],[class*=loader],[class*=loading]').length,
          });
        })()
        """

    private static func popupState(for ext: InstalledExtension, key: String) async -> [String: Any]? {
        let em = ExtensionManager.shared
        guard let action = em.action(for: ext), action.presentsPopup else { return nil }
        // the real click path: it grants activeTab, which popups rely on to see the page
        em.performAction(for: ext)
        var webView: WKWebView?
        for _ in 0..<20 where webView == nil {
            webView = action.popupWebView
            if webView == nil { try? await Task.sleep(for: .milliseconds(150)) }
        }
        guard let webView else { return ["error": "popupWebView nil"] }
        for _ in 0..<10 where webView.window == nil {
            try? await Task.sleep(for: .milliseconds(150))
        }
        let host = webView.window == nil
            ? backgroundWindow(hosting: webView, size: CGSize(width: 400, height: 600)) : nil
        defer {
            action.closePopup()
            em.pendingPopupExtensionID = nil
            host?.orderOut(nil)
        }
        try? await Task.sleep(for: .seconds(3))
        var state = await evaluateState(in: webView)
        state["shot"] = await snapshot(webView, name: key, part: "popup")
        return state
    }

    /// a closed page lives on until WebKit drains its navigation callbacks, and the
    /// next extension's content scripts would run in it, sending as a tab nobody has
    private static func discard(_ tab: BrowserTab, from manager: TabManager) {
        manager.close(tab)
        tab.webView.loadHTMLString("", baseURL: nil)
    }

    private static func optionsState(
        for ext: InstalledExtension, key: String, manager: TabManager
    ) async -> [String: Any]? {
        guard let url = ext.context.optionsPageURL else { return nil }
        let tab = manager.newTab(url: url, configuration: ext.context.webViewConfiguration)
        defer { discard(tab, from: manager) }
        await settle(tab, timeout: 8)
        var state = await evaluateState(in: tab.webView)
        state["shot"] = await snapshot(tab.webView, name: key, part: "options")
        return state
    }

    private static func evaluateState(in webView: WKWebView) async -> [String: Any] {
        // its own world: a page that locks down or patches its built-ins can't skew the reading
        let reply = await bounded(5) {
            try? await webView.evaluateJavaScript(pageState, contentWorld: .defaultClient) as? String
        }
        guard let json = reply ?? nil,
            let state = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        else {
            return ["error": "evaluate failed", "url": webView.url?.absoluteString ?? "nil",
                    "loading": webView.isLoading]
        }
        return state
    }

    /// popups paint only inside an on-screen window; this one sits behind every
    /// other window, with occlusion throttling off so it still renders
    private static func backgroundWindow(hosting webView: WKWebView, size: CGSize) -> NSWindow {
        let origin = NSScreen.main?.visibleFrame.origin ?? .zero
        let window = NSWindow(
            contentRect: CGRect(origin: origin, size: size),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        webView.frame = CGRect(origin: .zero, size: size)
        window.contentView = webView
        disableOcclusionThrottling(webView)
        window.orderBack(nil)
        return window
    }

    private static func disableOcclusionThrottling(_ webView: WKWebView) {
        let selector = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        guard webView.responds(to: selector) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(webView.method(for: selector), to: Setter.self)(webView, selector, false)
    }

    private static func snapshot(_ webView: WKWebView, name: String, part: String) async -> String? {
        disableOcclusionThrottling(webView)
        let shot = await bounded(5) { try? await webView.takeSnapshot(configuration: nil) }
        guard let image = shot ?? nil,
            let tiff = image.tiffRepresentation,
            let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { return nil }
        let shots = output.appendingPathComponent("shots", isDirectory: true)
        try? FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        let file = name.replacingOccurrences(of: "/", with: "_") + "-\(part).png"
        guard (try? png.write(to: shots.appendingPathComponent(file))) != nil else { return nil }
        return "shots/" + file
    }

    /// whichever of `work` and the timer ends first; a hung page never answers
    /// evaluateJavaScript or takeSnapshot
    private static func bounded<T>(_ seconds: Double, _ work: @escaping () async -> T) async -> T? {
        let once = Flag()
        return await withCheckedContinuation { (finish: CheckedContinuation<T?, Never>) in
            Task {
                let value = await work()
                if !once.done { once.done = true; finish.resume(returning: value) }
            }
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                if !once.done { once.done = true; finish.resume(returning: nil) }
            }
        }
    }

    private final class Flag { var done = false }

    private static func describe(_ error: Error) -> String {
        let ns = error as NSError
        return "[\(ns.domain) \(ns.code)] \(ns.localizedDescription)"
    }
}
