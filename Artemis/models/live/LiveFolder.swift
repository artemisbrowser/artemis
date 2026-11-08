// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import AppKit
import WebKit

/// what a folder fills itself from, and which of its tabs stand for rows. the item tabs sit in the
/// folder like any other; a tab the user closes or moves out is dismissed
@Observable
final class LiveFolder {
    var sources: [LiveSource]
    /// by tab id
    var items: [BrowserTab.ID: LiveItemData] = [:]
    /// row ids never filled again while their source lists them
    var dismissed: Set<String> = []
    /// the last refresh that read every source
    var fetched: Date?
    /// why the last refresh read nothing; every item stayed
    var problem: LiveProblem?
    @ObservationIgnored var isRefreshing = false
    /// the last refresh started, whatever came of it
    @ObservationIgnored var attempted: Date?

    init(sources: [LiveSource]) {
        self.sources = sources
    }

    /// nil when no source decodes, as one from a later build, which leaves the folder plain
    convenience init?(_ data: LiveFolderData) {
        let sources = data.sources.compactMap { try? JSONDecoder().decode(LiveSource.self, from: Data($0.utf8)) }
        guard !sources.isEmpty else { return nil }
        self.init(sources: sources)
        for var item in data.items where ["http", "https"].contains(item.link.scheme?.lowercased()) {
            item.title = LiveRow.plain(item.title)
            items[item.tab] = item
        }
        dismissed = Set(data.dismissed)
        fetched = data.fetched
    }

    /// the folder as the session stores it: items whose tab has left the folder are dismissed
    func data(for folder: TabFolder, in space: Space) -> LiveFolderData {
        let tabs = Dictionary(space.tabs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let filed = space.tabIDs(under: .folder(folder.id))
        let kept = filed.compactMap { id -> LiveItemData? in
            guard var item = items[id] else { return nil }
            if let tab = tabs[id], Self.wasOpened(tab) { item.opened = true }
            return item
        }
        let gone = Set(items.keys).subtracting(filed).compactMap { items[$0]?.id }
        let sources = sources.compactMap { try? JSONEncoder().encode($0) }.map { String(decoding: $0, as: UTF8.self) }
        return LiveFolderData(
            sources: sources, items: kept, dismissed: dismissed.union(gone).sorted(), fetched: fetched)
    }

    /// loaded once, or asleep after loading
    static func wasOpened(_ tab: BrowserTab) -> Bool { tab.pendingURL == nil || tab.isHibernated }

    func isUnread(_ tab: BrowserTab) -> Bool {
        guard let item = items[tab.id] else { return false }
        return item.unread && !item.opened && !Self.wasOpened(tab)
    }

    func unreadCount(of folder: TabFolder, in space: Space) -> Int {
        let filed = Set(space.tabIDs(under: .folder(folder.id)))
        return space.tabs.count(where: { filed.contains($0.id) && isUnread($0) })
    }

    /// the count a folded folder's row shows; an open one shows its items' own dots instead
    func foldedUnread(of folder: TabFolder, in space: Space) -> Int {
        folder.isExpanded ? 0 : unreadCount(of: folder, in: space)
    }

    func markAllRead() {
        for id in items.keys where items[id]?.unread == true { items[id]?.unread = false }
    }

    /// what the folder's row says went wrong
    var problemText: String? {
        let site = sources.contains { if case .feed = $0 { false } else { true } } ? "GitHub" : "The site"
        switch problem {
        case nil, .unavailable(.refused): return nil
        case .needsSignIn: return "Sign in to GitHub in this space, then refresh."
        case .unavailable(.network): return "Couldn’t update. Your items are kept."
        case .unavailable(.rateLimited): return "\(site) asked to slow down. It will try again later."
        case .unavailable(.unreadable):
            return site == "GitHub"
                ? "GitHub’s page has changed. Your items are kept." : "This feed couldn’t be read."
        }
    }
}

enum LiveProblem: Equatable {
    case needsSignIn
    case unavailable(LiveFailure)
}

extension GitHubQuery {
    var title: String {
        switch self {
        case .created: "My Pull Requests"
        case .reviewRequested: "Review Requests"
        case .teamReviewRequested: "Team Review Requests"
        case .assignedIssues: "Assigned Issues"
        }
    }
}

// MARK: - Filling a folder

extension TabManager {
    /// a live folder in `space`, else the current one, filled straight away; nil outside a browser
    /// window or past the nesting cap
    @discardableResult
    func newLiveFolder(
        named name: String, sources: [LiveSource], in container: SidebarContainer = .section(.today),
        at index: Int? = nil, space: Space? = nil
    ) -> TabFolder? {
        let space = space ?? currentSpace
        guard kind == .main, !sources.isEmpty,
            let folder = newFolder(
                named: name, in: container, at: index, space: space, live: LiveFolder(sources: sources))
        else { return nil }
        LiveRefresh.shared.reschedule()
        Task { await refreshLive(folder, in: space) }
        return folder
    }

    /// follows the feed discovery confirms from `feed`, in the space it was asked in, named by the
    /// feed's own title, else the page's. with none confirmed, New Live Folder opens on the address
    func newLiveFolder(fromFeed feed: URL, page: BrowserTab) {
        let space = currentSpace
        Task {
            guard let found = await Feeds.discover(from: feed, in: space).first else {
                guard LiveSource.admittedProfile(of: space) != nil else { return }
                let draft = LiveFolderDraft(page: feed)
                draft.kind = .feed
                draft.found = []
                liveFolderDraft = draft
                return
            }
            let name = found.title.isEmpty ? LiveRow.plain(page.displayTitle) : found.title
            newLiveFolder(
                named: name.isEmpty ? (found.url.host() ?? "Feed") : name, sources: [.feed(found.url)], space: space)
        }
    }

    /// reads every source and folds the rows in. a locked space reads nothing
    func refreshLive(_ folder: TabFolder, in space: Space) async {
        guard let live = folder.live, !live.isRefreshing, LiveSource.admittedProfile(of: space) != nil else { return }
        live.isRefreshing = true
        live.attempted = Date()
        defer { live.isRefreshing = false }
        var rows: [LiveRow] = []
        for source in live.sources {
            let outcome = await source.load(in: space)
            guard case .rows(let found, _) = outcome else {
                await applyLive(outcome, to: folder, in: space) { _ in nil }
                return
            }
            rows += found.filter { row in !rows.contains { $0.id == row.id } }
        }
        await applyLive(.rows(rows, total: nil), to: folder, in: space) { await GitHub.state(ofPull: $0, in: space) }
    }

    /// folds one refresh into the folder; a failure keeps everything. new rows arrive as lazy tabs,
    /// unread after the first fill. a row that left takes an untouched tab along and leaves an opened
    /// one as a plain tab; a GitHub list's pull request goes only once `pullState` reads it merged or closed
    func applyLive(
        _ outcome: LiveOutcome, to folder: TabFolder, in space: Space, pullState: (URL) async -> LiveState?
    ) async {
        guard let live = folder.live else { return }
        let rows: [LiveRow]
        switch outcome {
        case .rows(let found, _):
            rows = found
        case .unavailable(.refused):
            return
        case .needsSignIn:
            if live.problem != .needsSignIn { live.problem = .needsSignIn }
            return
        case .unavailable(let failure):
            if live.problem != .unavailable(failure) { live.problem = .unavailable(failure) }
            return
        }
        let wanted = rows.filter { ![.merged, .closed].contains($0.state) }
        let tracksPulls = live.sources.contains { if case .github = $0 { true } else { false } }
        let present = Set(wanted.map(\.id))
        let wasFiled = Set(space.tabIDs(under: .folder(folder.id)))
        var finished: Set<String> = []
        for item in live.items.values
        where tracksPulls && !present.contains(item.id) && wasFiled.contains(item.tab)
            && GitHub.pullLookup(item.link) != nil
        {
            if let state = await pullState(item.link), [.merged, .closed].contains(state) { finished.insert(item.id) }
        }
        guard folder.live === live, space.folder(folder.id) === folder, LiveSource.admittedProfile(of: space) != nil
        else { return }

        let tabs = Dictionary(space.tabs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let filed = Set(space.tabIDs(under: .folder(folder.id)))
        let selected = Set(BrowserWindows.shared.allManagers.compactMap(\.selectedTabID))
            .union([space.selectedTabID].compactMap { $0 })
        var treeChanged = false
        for (id, item) in live.items {
            guard let tab = tabs[id], filed.contains(id) else {
                live.items[id] = nil
                live.dismissed.insert(item.id)
                continue
            }
            let touched =
                item.opened || LiveFolder.wasOpened(tab) || tab.customName != nil || tab.keepsLoaded
                || selected.contains(id) || space.splitGroup(containing: id) != nil
            if touched, !item.opened {
                live.items[id]?.opened = true
                live.items[id]?.unread = false
            }
            guard !present.contains(item.id) else { continue }
            if tracksPulls, GitHub.pullLookup(item.link) != nil, !finished.contains(item.id) { continue }
            live.items[id] = nil
            if !touched {
                space.tabs.removeAll { $0 === tab }
                SpotlightIndex.forget(.items([id]))
                letGo(of: tab)
                treeChanged = true
            }
        }

        let filledBefore = live.fetched != nil
        var known = Dictionary(live.items.values.map { ($0.id, $0.tab) }, uniquingKeysWith: { first, _ in first })
        var slot = 0
        for row in wanted where !live.dismissed.contains(row.id) {
            if let id = known[row.id] {
                if live.items[id]?.title != row.title {
                    live.items[id]?.title = row.title
                    tabs[id]?.adopt(restoredTitle: row.title)
                }
                continue
            }
            let tab = BrowserTab(
                restoring: row.link, pinned: space.section(of: .folder(folder.id)) == .pinned,
                dataStore: dataStore(for: space))
            tab.adopt(restoredTitle: row.title)
            wire(tab)
            space.tabs.append(tab)
            space.insertEntry(.tab(tab.id), into: .folder(folder.id), at: slot)
            slot += 1
            ExtensionManager.shared.tabDidOpen(tab)
            live.items[tab.id] = LiveItemData(
                tab: tab.id, id: row.id, link: row.link, title: row.title, unread: filledBefore, opened: false)
            known[row.id] = tab.id
            treeChanged = true
        }
        live.dismissed.formIntersection(present)
        live.fetched = Date()
        if live.problem != nil { live.problem = nil }
        if treeChanged { space.normalizeTree() }
        scheduleSave()
    }
}

// MARK: - Refresh schedule

/// a minute's tick refreshes the one folder waiting longest once its half hour is up, so folders
/// spread out. only the shared spaces hold live folders; a locked one waits, and nothing runs asleep
@MainActor
final class LiveRefresh {
    static let shared = LiveRefresh()
    static let interval: TimeInterval = 30 * 60

    private var timer: Timer?
    private var isAsleep = false
    var isRunning: Bool { timer != nil }

    private init() {
        let center = NSWorkspace.shared.notificationCenter
        for (name, asleep) in [(NSWorkspace.willSleepNotification, true), (NSWorkspace.didWakeNotification, false)] {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    LiveRefresh.shared.isAsleep = asleep
                    LiveRefresh.shared.reschedule()
                }
            }
        }
    }

    /// ticks while a browser window is open, an unlocked shared space has a live folder, and the
    /// Mac is awake. a tick notices when to stop; whatever lets it start (a window, an unlock) calls this
    func reschedule() {
        let wanted =
            !isAsleep && !BrowserWindows.shared.mainManagers.isEmpty
            && BrowserCore.shared.spaces.contains { space in
                space.folders.contains { $0.live != nil } && LiveSource.admittedProfile(of: space) != nil
            }
        if wanted, timer == nil {
            let timer = Timer(timeInterval: 60, repeats: true) { _ in
                MainActor.assumeIsolated { LiveRefresh.shared.tick() }
            }
            timer.tolerance = 10
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else if !wanted {
            timer?.invalidate()
            timer = nil
        }
    }

    private func tick() {
        reschedule()
        guard let manager = BrowserWindows.shared.mainManagers.first,
            let next = Self.due(in: BrowserCore.shared.spaces, at: Date()).first
        else { return }
        Task { await manager.refreshLive(next.folder, in: next.space) }
    }

    /// the folders owed a refresh, longest waiting first
    static func due(in spaces: [Space], at now: Date) -> [(space: Space, folder: TabFolder)] {
        spaces.filter { LiveSource.admittedProfile(of: $0) != nil }
            .flatMap { space in
                space.folders.compactMap { folder -> (space: Space, folder: TabFolder, last: Date)? in
                    guard let live = folder.live, !live.isRefreshing else { return nil }
                    let last = live.attempted ?? live.fetched ?? .distantPast
                    return now.timeIntervalSince(last) >= interval ? (space, folder, last) : nil
                }
            }
            .sorted { $0.last < $1.last }
            .map { ($0.space, $0.folder) }
    }
}

// MARK: - A page's feeds

extension BrowserTab {
    /// the feeds the page declares in its link tags, read in a world of Artemis's own; none for a
    /// private page or one not loaded over http(s)
    func declaredFeeds() async -> [URL] {
        guard !isPrivate, let base = url, ["http", "https"].contains(base.scheme?.lowercased()) else { return [] }
        let script = """
            return Array.from(document.querySelectorAll('link[rel~="alternate" i]'))
              .slice(0, 20).map(l => l.outerHTML).join('').slice(0, 65536)
            """
        guard let tags = try? await webView.callAsyncJavaScript(script, contentWorld: .defaultClient) as? String,
            url == base
        else { return [] }
        return await Feeds.links(inHTML: Data(tags.utf8), base: base)
    }
}
