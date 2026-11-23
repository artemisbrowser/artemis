// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import ContentBlockerConverter
import CryptoKit
import WebKit

/// one subscribable filter list
struct Blocklist: Identifiable, Hashable {
    let id: String
    let name: String
    let detail: String
    let url: URL
    /// a plain host list, compiled as one rule that blocks pages on those hosts
    var blocksPages = false

    fileprivate var enabledKey: String { "blocklist.\(id).enabled" }
    /// the cached copy's ETag, and the seconds its `! Expires:` line gave it
    fileprivate var tagKey: String { "blocklist.\(id).etag" }
    fileprivate var expiryKey: String { "blocklist.\(id).expires" }
}

/// native content blocking via `WKContentRuleListStore`, from EasyList-format lists converted by
/// `FilterConverter`. the list's identifier embeds a hash of its JSON, so an unchanged list is
/// looked up in WebKit's on-disk store instead of compiled again
@Observable
@MainActor
final class ContentBlocker {
    static let shared = ContentBlocker()

    /// the lists behind `isEnabled`
    private static let adLists: [Blocklist] = [
        Blocklist(
            id: "easylist", name: "EasyList", detail: "",
            url: URL(string: "https://easylist.to/easylist/easylist.txt")!),
        Blocklist(
            id: "easyprivacy", name: "EasyPrivacy", detail: "",
            url: URL(string: "https://easylist.to/easylist/easyprivacy.txt")!),
        Blocklist(
            id: "popupads", name: "HaGeZi Pop-Up Ads", detail: "",
            url: URL(string: "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/popupads.txt")!,
            blocksPages: true),
    ]

    /// the lists with a switch of their own. `annoyances` holds everything `cookies` does
    static let catalog: [Blocklist] = [
        Blocklist(
            id: "cookies", name: "Hide Cookie Banners",
            detail: "Hides cookie banners and consent walls. Your cookie choices stay unanswered.",
            url: URL(string: "https://secure.fanboy.co.nz/fanboy-cookiemonster.txt")!),
        Blocklist(
            id: "annoyances", name: "Hide Page Clutter",
            detail: "Hides newsletter pop-ups, share buttons and notification prompts. Includes cookie banners.",
            url: URL(string: "https://easylist.to/easylist/fanboy-annoyance.txt")!),
    ]

    /// never blocked: `isAdult` reads it to keep these hosts out of history
    private static let adultList = Blocklist(
        id: "nsfw", name: "HaGeZi NSFW", detail: "",
        url: URL(string: "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/nsfw.txt")!)
    static let adultKey = "adultSitesOutOfHistory"

    static let enabledKey = "contentBlockingEnabledV1"
    /// identifiers of the compiled lists in WebKit's store, and their rule counts, which launch
    /// installs without converting the lists again
    private static let compiledIdentifiersKey = "contentBlockingCompiledIDs"
    private static let compiledStatsKey = "contentBlockingCompiledStats"
    /// fingerprint of the converter and `siteFixes` the compiled list was built with; a mismatch
    /// forces a rebuild
    private static let compiledFixesKey = "contentBlockingCompiledFixes"
    private static let fixesFingerprint: String = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return digest(
            "\(ContentBlockerConverterVersion.library)+\(converterRevision)"
                + (String(data: (try? encoder.encode(siteFixes)) ?? Data(), encoding: .utf8) ?? ""))
    }()
    /// bump when the output changes without a converter version: a vendored patch, a dependency
    /// pin or `FilterConverter` itself
    private static let converterRevision = 4
    /// how often a running app looks for lists past their expiry, in seconds; no list is asked for sooner
    private static let refreshPeriod: TimeInterval = 3 * 3600
    /// how long a copy stays current when its list states no expiry
    private static let defaultAge: TimeInterval = 4 * 86_400

    var isEnabled: Bool {
        didSet {
            guard oldValue != isEnabled else { return }
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            resubscribe()
        }
    }

    var keepsAdultSitesOutOfHistory: Bool {
        didSet {
            UserDefaults.standard.set(keepsAdultSitesOutOfHistory, forKey: Self.adultKey)
            Task { await serialized { await self.loadAdultHosts() } }
        }
    }

    /// ids of the `catalog` lists switched on
    private(set) var switchedOn: Set<String>
    func isOn(_ list: Blocklist) -> Bool { switchedOn.contains(list.id) }

    var isActive: Bool { !enabledLists.isEmpty }

    /// live status for Settings: rule count, when a host last answered for a list in use, and
    /// how many filters the converter couldn't express or left out at WebKit's ceiling
    private(set) var ruleCount = 0
    private(set) var droppedCount = 0
    private(set) var overCeilingCount = 0
    private(set) var lastUpdated: Date?
    private(set) var isUpdating = false
    private(set) var lastError: String?

    @ObservationIgnored private var installed: [WKContentRuleList] = []
    /// serializes every install: an overlapping `apply()` and `updateLists` could each prune
    /// the lists the other recorded as compiled
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var refresher: Task<Void, Never>?
    @ObservationIgnored private let cacheDirectory = AppStorageLocation.directory
        .appendingPathComponent("blocklists", isDirectory: true)

    private init() {
        let defaults = UserDefaults.standard
        isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        keepsAdultSitesOutOfHistory = defaults.bool(forKey: Self.adultKey)
        // the social list had a switch of its own; `annoyances` holds all of it
        if defaults.bool(forKey: "blocklist.social.enabled") {
            defaults.set(true, forKey: "blocklist.annoyances.enabled")
            defaults.removeObject(forKey: "blocklist.social.enabled")
        }
        switchedOn = Set(Self.catalog.filter { defaults.bool(forKey: $0.enabledKey) }.map(\.id))
        try? FileManager.default.createDirectory(
            at: cacheDirectory, withIntermediateDirectories: true)
        lastUpdated = enabledLists.compactMap(checked).max()
        // a profile's controller made after the lists went in gets the live ones
        SharedWebContent.everywhere { [weak self] ucc in
            guard let self, self.isActive else { return }
            for list in self.installed { ucc.add(list) }
        }
    }

    /// one-line summary under the Settings toggle
    var statusLine: String {
        guard isActive else { return "Blocking is off. Pages load with their ads and trackers." }
        if let lastError { return "Couldn't update: \(lastError)" }
        guard ruleCount > 0 else { return "Preparing blocklists…" }
        let updated = lastUpdated.map {
            $0.formatted(date: .abbreviated, time: .shortened)
        } ?? "never"
        let dropped = droppedCount > 0 ? ", \(droppedCount.formatted()) unsupported filters skipped" : ""
        let over = overCeilingCount > 0 ? ", \(overCeilingCount.formatted()) rules over WebKit's limit left out" : ""
        return "\(ruleCount.formatted()) rules active, updated \(updated)\(dropped)\(over)."
    }

    private var enabledLists: [Blocklist] {
        let extras = Self.catalog.filter(isOn)
        return (isEnabled ? Self.adLists : [])
            + (extras.count > 1 ? extras.filter { $0.id == "annoyances" } : extras)
    }

    func setList(_ list: Blocklist, enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: list.enabledKey)
        if enabled { switchedOn.insert(list.id) } else { switchedOn.remove(list.id) }
        resubscribe()
    }

    /// a switch changed: the compiled set no longer matches, so neither launch nor an
    /// unchanged download may reuse it
    private func resubscribe() {
        UserDefaults.standard.removeObject(forKey: Self.compiledIdentifiersKey)
        if !isActive { uninstall() }
        Task { await updateLists(force: false) }
    }

    // MARK: - Applying

    /// returns once nothing is compiling or installing, including the launch rebuild, which
    /// `isUpdating` doesn't cover
    func waitForIdle() async {
        await work?.value
    }

    /// run `body` after any install already in flight has finished
    private func serialized(_ body: @escaping @MainActor () async -> Void) async {
        let previous = work
        let task = Task { @MainActor in
            await previous?.value
            await body()
        }
        work = task
        await task.value
    }

    /// hosts the privacy list blocks, so a blocked request can be reported as a
    /// tracker; anything else blocked counts as an ad
    @ObservationIgnored private var trackerHosts: Set<String> = []
    private var trackerHostsCache: URL {
        cacheDirectory.appendingPathComponent("trackerhosts.txt")
    }

    /// does the privacy list recognise this request's host, or a parent of it?
    /// `requestDomains` semantics: a rule for example.com also covers a.example.com
    func isTracker(_ url: URL) -> Bool { Self.lists(url, in: trackerHosts) }

    /// is this page on the adult list, while the switch that keeps those out of history is on?
    func isAdult(_ url: URL) -> Bool { keepsAdultSitesOutOfHistory && Self.lists(url, in: adultHosts) }

    @ObservationIgnored private var adultHosts: Set<String> = []

    private static func lists(_ url: URL, in hosts: Set<String>) -> Bool {
        guard !hosts.isEmpty, var host = url.host()?.lowercased() else { return false }
        while host.contains(".") {
            if hosts.contains(host) { return true }
            guard let dot = host.firstIndex(of: ".") else { return false }
            host = String(host[host.index(after: dot)...])
        }
        return false
    }

    /// empty while the switch is off; otherwise from the cache, or the network once that is stale
    private func loadAdultHosts() async {
        guard keepsAdultSitesOutOfHistory else { return adultHosts = [] }
        guard adultHosts.isEmpty || !isFresh(Self.adultList) else { return }
        guard let (text, isNew) = await fetch(Self.adultList, force: false), isNew || adultHosts.isEmpty else { return }
        adultHosts = await Task.detached { FilterConverter.blockedHosts(in: text) }.value
    }

    private func rememberTrackerHosts(from source: String) async {
        trackerHosts = await Self.parseTrackerHosts(source, savingTo: trackerHostsCache)
    }

    @concurrent nonisolated private static func parseTrackerHosts(
        _ source: String, savingTo file: URL
    ) async -> Set<String> {
        let hosts = FilterConverter.blockedHosts(in: source)
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? hosts.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        return hosts
    }

    @concurrent nonisolated private static func readTrackerHosts(_ file: URL) async -> Set<String> {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        return Set(text.split(separator: "\n").map(String.init))
    }

    /// a rule list reaches a document only when the document loads after it is
    /// installed, so a page that is already open has to run again
    private static func reloadLoadedTabs() {
        guard let manager = ExtensionManager.shared.tabManager else { return }
        for tab in manager.allTabs where !tab.isHibernated && tab.url != nil {
            tab.webView.reload()
        }
    }

    /// install (or remove) the compiled lists on the shared user-content
    /// controller every tab already uses
    func apply() async {
        await serialized { await self.applyLocked() }
    }

    /// at once, ahead of any download or compile in flight, which then records its lists
    /// without adding them
    private func uninstall() {
        guard !installed.isEmpty else { return }
        for ucc in SharedWebContent.all { for list in installed { ucc.remove(list) } }
        installed = []
        Self.reloadLoadedTabs()
    }

    private func applyLocked() async {
        if refresher == nil, !AppStorageLocation.isTestRun {
            refresher = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(Self.refreshPeriod))
                    await serialized {
                        await self.loadAdultHosts()
                        if self.isActive { await self.refreshIfStaleLocked(reloadTabs: false) }
                    }
                }
            }
        }
        await loadAdultHosts()
        guard isActive else { return uninstall() }
        let hadCache = enabledLists.contains {
            (try? cacheURL($0).checkResourceIsReachable()) == true
        }
        if installed.isEmpty {
            await rebuild()
        } else {
            for ucc in SharedWebContent.all { for list in installed { ucc.add(list) } }
        }
        // a self-test or lab launch asks no host: a record that needs the lists fetches them
        guard !AppStorageLocation.isTestRun else { return }
        // with cached rules already in, a newer download reaches pages as they
        // next load; with only the starter list in, open pages run again
        await refreshIfStaleLocked(reloadTabs: !hadCache)
    }

    /// ask the hosts about the lists past their expiry, inside the serialized section
    private func refreshIfStaleLocked(reloadTabs: Bool) async {
        guard enabledLists.contains(where: { !isFresh($0) }) else { return }
        await updateListsLocked(force: false, reloadTabs: reloadTabs)
    }

    func cacheURL(_ list: Blocklist) -> URL {
        cacheDirectory.appendingPathComponent("\(list.id).txt")
    }

    /// when its host last answered for `list`: the cached copy's modification date
    private func checked(_ list: Blocklist) -> Date? {
        try? cacheURL(list).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    private func isFresh(_ list: Blocklist) -> Bool {
        let stated = UserDefaults.standard.double(forKey: list.expiryKey)
        return checked(list).map { Date().timeIntervalSince($0) < (stated > 0 ? stated : Self.defaultAge) } ?? false
    }

    /// a list's `! Expires:` line in seconds, never under the refresh period
    static func expiry(in text: String) -> TimeInterval? {
        guard let stated = text.prefix(4096).firstMatch(of: #/(?m)^! Expires: (\d+) (day|hour)/#),
            let count = TimeInterval(stated.1)
        else { return nil }
        return max(count * (stated.2 == "day" ? 86_400 : 3600), refreshPeriod)
    }

    /// bring every enabled list up to date, then convert, compile and install what changed.
    /// `force` asks the hosts even while the copies are current (the Settings button)
    func updateLists(force: Bool) async {
        await serialized { await self.updateListsLocked(force: force, reloadTabs: true) }
    }

    private func updateListsLocked(force: Bool, reloadTabs: Bool) async {
        guard !isUpdating else { return }
        isUpdating = true
        lastError = nil
        defer { isUpdating = false }
        guard !enabledLists.isEmpty else { return await removeLists(reloadTabs: reloadTabs) }

        var sources: [String] = []
        var pages: String?
        var changed = false
        for list in enabledLists {
            if let (text, isNew) = await fetch(list, force: force) {
                if list.blocksPages { pages = text } else { sources.append(text) }
                changed = changed || isNew
                if list.id == "easyprivacy" { await rememberTrackerHosts(from: text) }
            }
        }
        guard !sources.isEmpty else {
            lastError = lastError ?? "no lists available offline"
            await install(sources: [Self.starterList], pages: pages, reloadTabs: reloadTabs)
            return
        }
        lastUpdated = enabledLists.compactMap(checked).max()
        let resubscribed = UserDefaults.standard.object(forKey: Self.compiledIdentifiersKey) == nil
        guard changed || installed.isEmpty || resubscribed else { return }
        await install(sources: sources, pages: pages, reloadTabs: reloadTabs)
    }

    /// one list from its host, or from the cached copy while that is current or the host fails. the host is
    /// asked with the copy's ETag; a 304 keeps the copy and restarts its clock. `isNew` when the text changed
    func fetch(_ list: Blocklist, force: Bool) async -> (text: String, isNew: Bool)? {
        let cached = cacheURL(list)
        let previous = (try? String(contentsOf: cached, encoding: .utf8)).flatMap { $0.isEmpty ? nil : $0 }
        if !force, isFresh(list), let previous { return (previous, false) }
        do {
            var request = URLRequest(url: list.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
            if previous != nil {
                request.setValue(UserDefaults.standard.string(forKey: list.tagKey), forHTTPHeaderField: "If-None-Match")
            }
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = response as? HTTPURLResponse
            if http?.statusCode == 304, let previous {
                try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: cached.path)
                return (previous, false)
            }
            guard http?.statusCode == 200, let text = String(data: data, encoding: .utf8), !text.isEmpty
            else { throw URLError(.badServerResponse) }
            // the tag must describe the copy on disk, or a later 304 would keep the wrong text
            let isSaved = (try? text.write(to: cached, atomically: true, encoding: .utf8)) != nil
            UserDefaults.standard.set(isSaved ? http?.value(forHTTPHeaderField: "ETag") : nil, forKey: list.tagKey)
            UserDefaults.standard.set(Self.expiry(in: text), forKey: list.expiryKey)
            return (text, text != previous)
        } catch {
            debugLog("blocklist \(list.id) fetch failed: \(error.localizedDescription)")
            lastError = error.localizedDescription
            return previous.map { ($0, false) }
        }
    }

    /// convert, compile and install, converting off the main actor. `pages` is the host list
    /// whose pages are blocked whole, in a rule list of its own
    private func install(sources: [String], pages: String?, reloadTabs: Bool) async {
        let fixes = Self.siteFixes
        let qos: QualityOfService = reloadTabs ? .userInitiated : .utility
        let built = await Task.detached(priority: reloadTabs ? .userInitiated : .utility) {
            Self.builtByHelper(sources, pages: pages, qos: qos)
        }.value

        var compiled: [WKContentRuleList] = []
        let converted: FilterConverter.Result
        if let built, let lists = await Self.storedLists(built.identifiers) {
            converted = built.counts
            compiled = lists
        } else {
            let (result, pageRule) = await Task.detached(priority: reloadTabs ? .userInitiated : .utility) {
                (FilterConverter.convert(sources, extraExceptions: fixes), pages.flatMap(FilterConverter.pageBlock))
            }.value
            converted = result
            for json in [result.json, pageRule].compactMap(\.self) {
                if let list = await compile(json) { compiled.append(list) }
            }
        }
        if converted.overCeilingCount > 0 {
            Diagnostics.record(
                area: "blocker", message: "over WebKit's rule ceiling: \(converted.overCeilingCount) rules dropped")
        }
        guard !compiled.isEmpty else {
            if installed.isEmpty, sources != [Self.starterList] {
                await install(sources: [Self.starterList], pages: nil, reloadTabs: reloadTabs)
            }
            return
        }

        // the same list already in: nothing to swap, and no open page has to run again
        if compiled.map(\.identifier) != installed.map(\.identifier) {
            replaceInstalled(with: compiled)
            if reloadTabs, isActive { Self.reloadLoadedTabs() }
        }
        ruleCount = converted.ruleCount
        droppedCount = converted.droppedCount
        overCeilingCount = converted.overCeilingCount
        UserDefaults.standard.set(compiled.map(\.identifier), forKey: Self.compiledIdentifiersKey)
        UserDefaults.standard.set(Self.fixesFingerprint, forKey: Self.compiledFixesKey)
        UserDefaults.standard.set(
            [converted.ruleCount, converted.droppedCount, converted.overCeilingCount], forKey: Self.compiledStatsKey)
        await pruneStaleCompiledLists(keeping: Set(compiled.map(\.identifier)))
        debugLog("blocklists installed: \(converted.ruleCount) rules")
    }

    private func compile(_ json: String) async -> WKContentRuleList? {
        do {
            return try await Self.compiled(json)
        } catch {
            // WebKit puts the parser's own message in the help anchor; the
            // localized description is only "compile failed"
            let detail = (error as NSError).userInfo[NSHelpAnchorErrorKey] as? String
            let failure = "rules failed to compile: \(detail ?? error.localizedDescription)"
            debugLog("blocklist \(failure)")
            lastError = failure
            Diagnostics.record(area: "blocker", message: failure)
            return nil
        }
    }

    /// build from the cached lists without the network, reusing the last build's bytecode
    /// while it is still current
    private func rebuild() async {
        guard !enabledLists.isEmpty else { return await removeLists(reloadTabs: false) }
        if await installPreviouslyCompiled() { return }

        var sources: [String] = []
        var pages: String?
        for list in enabledLists {
            if let text = try? String(contentsOf: cacheURL(list), encoding: .utf8), !text.isEmpty {
                if list.blocksPages { pages = text } else { sources.append(text) }
                if list.id == "easyprivacy" { await rememberTrackerHosts(from: text) }
            }
        }
        await install(
            sources: sources.isEmpty ? [Self.starterList] : sources, pages: pages, reloadTabs: true)
    }

    /// look the last build's lists up by identifier and install them as-is.
    /// false if any is missing, in which case the caller rebuilds from source
    @discardableResult
    func installPreviouslyCompiled() async -> Bool {
        let defaults = UserDefaults.standard
        guard let identifiers = defaults.array(forKey: Self.compiledIdentifiersKey) as? [String],
            !identifiers.isEmpty, let store = WKContentRuleListStore.default(),
            defaults.string(forKey: Self.compiledFixesKey) == Self.fixesFingerprint
        else { return false }

        let together = PerfFlags.startsLaunchPageEarly, cache = trackerHostsCache, readsEarly = together && trackerHosts.isEmpty
        async let early: Set<String> = readsEarly ? Self.readTrackerHosts(cache) : []
        var lists: [WKContentRuleList] = []
        if together {
            guard let found = await Self.lookUp(identifiers, in: store) else { return false }
            lists = found
        } else {
            for identifier in identifiers {
                guard let list = try? await store.contentRuleList(forIdentifier: identifier)
                else { return false }
                lists.append(list)
            }
        }

        replaceInstalled(with: lists)
        if let stats = defaults.array(forKey: Self.compiledStatsKey) as? [Int], stats.count == 3 {
            ruleCount = stats[0]
            droppedCount = stats[1]
            overCeilingCount = stats[2]
        }
        if trackerHosts.isEmpty { trackerHosts = together ? await early : await Self.readTrackerHosts(cache) }
        debugLog("blocklists: reused \(lists.count) already-compiled lists")
        return true
    }

    /// every list, asked for all at once and returned in order; nil if any is missing
    private static func lookUp(_ identifiers: [String], in store: WKContentRuleListStore) async -> [WKContentRuleList]? {
        await withCheckedContinuation { done in
            var found = [WKContentRuleList?](repeating: nil, count: identifiers.count), left = identifiers.count
            for (i, identifier) in identifiers.enumerated() {
                store.lookUpContentRuleList(forIdentifier: identifier) { list, _ in
                    found[i] = list
                    left -= 1
                    if left == 0 { done.resume(returning: found.contains { $0 == nil } ? nil : found.compactMap { $0 }) }
                }
            }
        }
    }

    /// no list subscribed: nothing blocks, not even the starter list
    private func removeLists(reloadTabs: Bool) async {
        let hadLists = !installed.isEmpty
        replaceInstalled(with: [])
        if hadLists, reloadTabs { Self.reloadLoadedTabs() }
        ruleCount = 0
        droppedCount = 0
        overCeilingCount = 0
        UserDefaults.standard.removeObject(forKey: Self.compiledIdentifiersKey)
        UserDefaults.standard.removeObject(forKey: Self.compiledStatsKey)
        await pruneStaleCompiledLists(keeping: [])
    }

    private func replaceInstalled(with lists: [WKContentRuleList]) {
        for ucc in SharedWebContent.all {
            for list in installed { ucc.remove(list) }
            if isActive { for list in lists { ucc.add(list) } }
        }
        installed = lists
    }

    /// every compile stores a new blob under its content hash, so the superseded ones are removed
    private func pruneStaleCompiledLists(keeping identifiers: Set<String>) async {
        guard let store = WKContentRuleListStore.default() else { return }
        let existing = (try? await store.availableIdentifiers()) ?? []
        for identifier in existing
        where identifier.hasPrefix("artemis-block") && !identifiers.contains(identifier) {
            try? await store.removeContentRuleList(forIdentifier: identifier)
        }
    }

    static func identifier(of json: String) -> String { "artemis-block-\(digest(json))" }

    private static func compiled(_ json: String) async throws -> WKContentRuleList? {
        let store = WKContentRuleListStore.default()
        if let existing = try? await store?.contentRuleList(forIdentifier: identifier(of: json)) { return existing }
        return try await store?.compileContentRuleList(forIdentifier: identifier(of: json), encodedContentRuleList: json)
    }

    private static func storedLists(_ identifiers: [String]) async -> [WKContentRuleList]? {
        var lists: [WKContentRuleList] = []
        for id in identifiers {
            guard let list = try? await WKContentRuleListStore.default()?.contentRuleList(forIdentifier: id)
            else { return nil }
            lists.append(list)
        }
        return lists
    }

    // MARK: - the conversion helper

    nonisolated static let helperArgument = "convert-blocklists"

    /// `Artemis convert-blocklists`: lists on stdin, then a NUL and the page-block hosts, compiled into the
    /// shared store; stdout is "identifier rules dropped overCeiling [pageIdentifier]".
    /// The converter's and compiler's heap dies with it
    static func runHelper() -> Never {
        // the converter's Debug logging prints, so only this descriptor reaches the parent
        let out = FileHandle(fileDescriptor: dup(STDOUT_FILENO), closeOnDealloc: true)
        dup2(open("/dev/null", O_WRONLY), STDOUT_FILENO)
        let input = FileHandle.standardInput.readDataToEndOfFile()
        let parts = input.split(separator: 0, maxSplits: 1, omittingEmptySubsequences: false)
        let result = FilterConverter.convert([String(decoding: parts[0], as: UTF8.self)], extraExceptions: siteFixes)
        let pageRule = parts.count > 1 ? FilterConverter.pageBlock(String(decoding: parts[1], as: UTF8.self)) : nil
        Task {
            var reply = "\(identifier(of: result.json)) \(result.ruleCount) \(result.droppedCount) \(result.overCeilingCount)"
            for json in [result.json, pageRule].compactMap(\.self) {
                guard (try? await compiled(json)) != nil else { exit(1) }
            }
            if let pageRule { reply += " \(identifier(of: pageRule))" }
            out.write(Data((reply + "\n").utf8))
            exit(0)
        }
        RunLoop.main.run()
        exit(1)
    }

    /// the helper's compiled lists (page block last) and counts, nil when it fails. It reads stdin
    /// to its end before writing, so writing everything first can't deadlock
    nonisolated static func builtByHelper(
        _ sources: [String], pages: String?, qos: QualityOfService
    ) -> (identifiers: [String], counts: FilterConverter.Result)? {
        guard let binary = Bundle.main.executableURL else { return nil }
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = binary
        process.arguments = [helperArgument]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.qualityOfService = qos
        let writer = input.fileHandleForWriting
        _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
        guard (try? process.run()) != nil else { return nil }
        for source in sources { try? writer.write(contentsOf: Data((source + "\n").utf8)) }
        if let pages { try? writer.write(contentsOf: Data([0]) + Data(pages.utf8)) }
        try? writer.close()
        let reply = (try? output.fileHandleForReading.readToEnd()).flatMap { $0 } ?? Data()
        process.waitUntilExit()
        let fields = String(decoding: reply, as: UTF8.self).split(whereSeparator: \.isWhitespace)
        guard process.terminationStatus == 0, fields.count >= 4 else { return nil }
        let counts = fields[1...3].compactMap { Int($0) }
        guard counts.count == 3 else { return nil }
        return (
            [String(fields[0])] + fields.dropFirst(4).map(String.init),
            FilterConverter.Result(ruleCount: counts[0], droppedCount: counts[1], overCeilingCount: counts[2])
        )
    }

    private static func digest(_ text: String) -> String {
        let hash = SHA256.hash(data: Data(text.utf8))
        return String(hash.map { String(format: "%02x", $0) }.joined().prefix(16))
    }

    // MARK: - Artemis' own site fixes

    /// exceptions appended after every converted list. Prime Video's player aborts ("Video
    /// Unavailable") while `amazon-adsystem.com` is blocked on Amazon pages, and YouTube's tears
    /// its stream down while `/api/stats/qoe` is blocked
    static let siteFixes: [ContentRule] = {
        let amazonHosts = [
            "*amazon.co.uk", "*amazon.com", "*amazon.de", "*amazon.fr", "*amazon.es",
            "*amazon.it", "*amazon.ca", "*amazon.co.jp", "*primevideo.com",
        ]
        return [
            ContentRule(
                trigger: .init(
                    urlFilter: "^https?://([^/]+\\.)?amazon-adsystem\\.com",
                    ifDomain: amazonHosts),
                action: .init(type: "ignore-previous-rules")),
            ContentRule(
                trigger: .init(
                    urlFilter: "^https?://([^/]+\\.)?youtube\\.com/api/stats/qoe",
                    ifDomain: ["*youtube.com"]),
                action: .init(type: "ignore-previous-rules")),
        ]
    }()

    /// the most prolific ad and tracker domains, installed until a list first downloads
    private static let starterList: String = {
        let domains = [
            "doubleclick.net", "googlesyndication.com", "google-analytics.com",
            "googleadservices.com", "googletagservices.com", "googletagmanager.com",
            "2mdn.net", "adnxs.com", "advertising.com", "adsystem.com",
            "amazon-adsystem.com", "scorecardresearch.com", "moatads.com",
            "rubiconproject.com", "pubmatic.com", "criteo.com", "criteo.net",
            "taboola.com", "outbrain.com", "quantserve.com", "openx.net",
            "casalemedia.com", "adform.net", "bidswitch.net", "hotjar.com",
            "mixpanel.com", "segment.com", "branch.io", "appsflyer.com",
            "doubleverify.com", "yieldmo.com", "sharethrough.com", "smartadserver.com",
            "teads.tv", "zedo.com", "adroll.com", "bluekai.com", "demdex.net", "krxd.net",
        ]
        return domains.map { "||\($0)^$third-party" }.joined(separator: "\n")
    }()
}
