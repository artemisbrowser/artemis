// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import AppKit
import SwiftUI

/// a runnable command surfaced in the bar, as opposed to somewhere to go
struct CommandAction: Identifiable {
    let id: String
    let title: String
    let symbol: String
    /// extra terms matched beyond the title, so "address" finds Copy Page Link
    let keywords: [String]
    let run: () -> Void
}

/// the bar narrowed to one kind of result
enum CommandScope: String, CaseIterable, Identifiable {
    case tabs, history, actions, spaces

    var id: String { rawValue }
    var token: String { "@" + rawValue }

    var label: String {
        switch self {
        case .tabs: "Tabs"
        case .history: "History"
        case .actions: "Actions"
        case .spaces: "Spaces"
        }
    }

    var symbol: String {
        switch self {
        case .tabs: "square.on.square"
        case .history: "clock.arrow.circlepath"
        case .actions: "command"
        case .spaces: "square.stack"
        }
    }
}

/// where a chosen result should land
enum CommandLaunch {
    case normal
    /// tiled beside whatever you're looking at
    case beside
    /// a floating Scout window
    case scout
    /// replacing the current page instead of opening a tab
    case current
}

/// the host the bar would finish the typed text into
struct CommandAutofill {
    let host: String
    /// the part after what's typed, drawn as the completion
    let completion: String
}

struct CommandItem: Identifiable {
    enum Kind {
        case tab(BrowserTab)
        case closed(ClosedTab)
        case history(HistoryEntry)
        case pageText(PageTextHit)
        case space(Space)
        case action(CommandAction)
        case bang(Bang?, trigger: String, query: String)
        case suggestion(String)
        case openURL(URL)
        case search(String)
        case scope(CommandScope)
    }

    let id: String
    let kind: Kind
    let title: String
    /// secondary text beside the title: where the result lives, never what ↵ does
    let hint: String
    /// byte offsets in `title` that matched, for highlighting
    let ranges: [Range<Int>]
    let score: Int

    var url: URL? {
        switch kind {
        case .tab(let tab): tab.url
        case .closed(let closed): closed.url
        case .history(let entry): entry.url
        case .pageText(let hit): hit.url
        case .openURL(let url): url
        default: nil
        }
    }

    var isSearch: Bool {
        if case .search = kind { return true }
        return false
    }

    /// what the bar learns this input meant, so the same keys land here again
    fileprivate var learningKey: String? {
        switch kind {
        case .action(let action): "action:" + action.id
        case .space(let space): "space:" + space.id.uuidString
        case .suggestion, .search, .scope, .bang: nil
        default: url?.absoluteString
        }
    }
}

/// builds and runs the command bar's results, every source ranked on one scale
@MainActor
struct CommandBarEngine {
    let manager: TabManager

    /// an incognito window reaches only its own tabs: no spaces, no undo stack
    private var spaces: [Space] { manager.kind == .main ? manager.spaces : [] }
    private var closedTabs: [ClosedTab] { manager.kind == .main ? manager.closedTabs : [] }
    /// what the bar learned, for the profile on screen; nothing in incognito
    private var habits: InputHistory? { manager.kind == .incognito ? nil : manager.currentProfile.inputHistory }

    /// base weights per source, added to match quality
    private enum Weight {
        static let tab = 250
        static let space = 170
        static let closed = 130
        static let history = 100
        static let action = 200
        static let pageText = -60
    }

    // MARK: - Results

    func items(
        input: String, scope: CommandScope?, textHits: [PageTextHit], suggestions: [String]
    ) -> [CommandItem] {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return recents(scope: scope) }

        if scope == nil, let modes = scopePicker(trimmed) { return modes }

        // row 0 is always the input read literally: a bang, an address, else a
        // search. nothing the bar merely matched can take that row
        var head: [CommandItem] = []
        if scope == nil {
            if Bangs.isEnabled, let partial = Bangs.partial(trimmed) {
                // the trigger you typed leads; the others are completions under it
                let literal =
                    partial.isEmpty
                    ? searchItem(trimmed)
                    : Bangs.lookup(partial).map { bangItem($0, query: "") }
                        ?? unknownBangItem(partial, query: "")
                let listed = Bangs.matching(partial).map { bangItem($0, query: "") }
                return deduped([literal] + listed + [searchItem(trimmed)])
            }
            if Bangs.isEnabled, let (trigger, query) = Bangs.split(trimmed) {
                head.append(
                    Bangs.lookup(trigger).map { bangItem($0, query: query) }
                        ?? unknownBangItem(trigger, query: query))
            } else if let url = URLInput.directURL(trimmed) {
                head.append(openItem(url))
            } else {
                head.append(searchItem(trimmed))
            }
            if let answer = Arithmetic.evaluate(trimmed) {
                let text = answer.formatted(.number.grouping(.never).precision(.fractionLength(0...10)))
                head.append(
                    actionItem(
                        CommandAction(
                            id: "calculate", title: "= \(text)", symbol: "equal", keywords: [],
                            run: {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(text, forType: .string)
                            }),
                        score: 0, ranges: []))
            }
        }

        var ranked = rank(trimmed, scope: scope, textHits: textHits)
        let headURLs = head.compactMap(\.url)
        // an open tab stays listed even when its address is row 0
        ranked.removeAll { item in
            if case .tab = item.kind { return false }
            return headURLs.contains { sameTarget($0, item.url) }
        }

        guard scope == nil else { return deduped(head + ranked.prefix(24)) }

        // suggestions arrive late, so they only fill rows below what's shown:
        // the list grows, it never reshuffles under the cursor
        let matched = ranked.prefix(5)
        var tail: [CommandItem] = []
        // an address in row 0 is never also offered as a search
        if !head.contains(where: { $0.isSearch || $0.url != nil }) { tail.append(searchItem(trimmed)) }
        let room = Self.rowLimit - head.count - matched.count - tail.count
        tail += suggestions.prefix(max(0, min(4, room))).map(suggestionItem)
        return deduped(head + matched + tail)
    }

    /// rows the unscoped bar shows; it never scrolls
    static let rowLimit = 8

    /// the list is keyed by id, so ids must be unique
    private func deduped(_ items: [CommandItem]) -> [CommandItem] {
        var seen: Set<String> = []
        return items.filter { seen.insert($0.id).inserted }
    }

    /// the same page, allowing for the trailing slash a host-only url grows
    private func sameTarget(_ lhs: URL?, _ rhs: URL?) -> Bool {
        guard let lhs, let rhs else { return false }
        func key(_ url: URL) -> String {
            var text = url.absoluteString
            if var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                components.scheme = components.scheme?.lowercased()
                components.host = components.host?.lowercased()
                text = components.string ?? text
            }
            return text.hasSuffix("/") ? String(text.dropLast()) : text
        }
        return key(lhs) == key(rhs)
    }

    /// the bar with nothing typed lists nothing until a scope is picked, then
    /// that scope's most recent
    private func recents(scope: CommandScope?) -> [CommandItem] {
        switch scope {
        case nil: []
        case .actions: actions.map { actionItem($0, score: 0, ranges: []) }
        case .spaces: spaces.map { spaceItem($0, score: 0, ranges: []) }
        case .history:
            manager.history.entries.prefix(20).map { historyItem($0, score: 0, ranges: []) }
        case .tabs:
            manager.switchableTabs
                .sorted { $0.lastAccessed > $1.lastAccessed }
                .prefix(24)
                .map { tabItem($0, score: 0, ranges: []) }
        }
    }

    /// "@" and its prefixes offer the modes themselves
    private func scopePicker(_ input: String) -> [CommandItem]? {
        guard input.hasPrefix("@"), !input.contains(" ") else { return nil }
        let key = String(input.dropFirst()).lowercased()
        let modes = CommandScope.allCases.filter { key.isEmpty || $0.rawValue.hasPrefix(key) }
        guard !modes.isEmpty else { return nil }
        return modes.map {
            CommandItem(
                id: "scope-\($0.rawValue)", kind: .scope($0), title: "Search \($0.label)",
                hint: $0.token, ranges: [], score: 0)
        }
    }

    private func rank(
        _ query: String, scope: CommandScope?, textHits: [PageTextHit]
    ) -> [CommandItem] {
        let needle = CommandMatcher.needle(query)
        let mask = CommandMatcher.mask(needle)
        let boosts = habits?.boosts(for: query) ?? [:]
        let now = Date()
        var out: [CommandItem] = []

        var openURLs: Set<String> = []
        if scope == nil || scope == .tabs {
            var scored: [CommandItem] = []
            for tab in manager.switchableTabs {
                let address = ((tab.url ?? tab.pendingURL)?.absoluteString ?? "").lowercased()
                let title = CommandMatcher.match(needle, tab.displayTitle.lowercased())
                let best = max(title?.score ?? -1, CommandMatcher.match(needle, address)?.score ?? -1)
                guard best >= 0 else { continue }
                let boost = tab.url.map { boosts[$0.absoluteString] ?? 0 } ?? 0
                scored.append(
                    tabItem(
                        tab, score: best + Weight.tab + boost,
                        ranges: (title?.score ?? -1) >= best ? (title?.ranges ?? []) : []))
            }
            scored.sort { $0.score > $1.score }
            // every matching tab, not just the listed ones, so a cut tab never
            // returns as a history row
            openURLs = Set(scored.compactMap { $0.url?.absoluteString })
            out += scored.prefix(8)
        }

        if scope == nil || scope == .spaces {
            for space in spaces {
                guard let match = CommandMatcher.match(needle, space.name.lowercased()) else {
                    continue
                }
                let boost = boosts["space:" + space.id.uuidString] ?? 0
                out.append(
                    spaceItem(
                        space, score: match.score + Weight.space + boost, ranges: match.ranges))
            }
        }

        var closedURLs: Set<String> = []
        if scope == nil {
            var scored: [CommandItem] = []
            for closed in closedTabs
            where !openURLs.contains(closed.url.absoluteString) {
                let title = CommandMatcher.match(needle, closed.title.lowercased())
                let address = CommandMatcher.match(needle, closed.url.absoluteString.lowercased())
                let best = max(title?.score ?? -1, address?.score ?? -1)
                guard best >= 0 else { continue }
                let boost = boosts[closed.url.absoluteString] ?? 0
                scored.append(
                    closedItem(
                        closed, score: best + Weight.closed + boost,
                        ranges: (title?.score ?? -1) >= best ? (title?.ranges ?? []) : []))
            }
            scored.sort { $0.score > $1.score }
            closedURLs = Set(scored.compactMap { $0.url?.absoluteString })
            out += scored.prefix(3)
        }

        if scope == nil || scope == .history {
            let covered = openURLs.union(closedURLs)
            let depth = scope == .history ? 30 : 12
            // pages that differ only by query or fragment read as the same row
            var seen: Set<String> = []
            for match in manager.history.rankedMatches(needle, mask: mask, limit: depth, now: now)
            where !covered.contains(match.entry.url.absoluteString)
                && seen.insert(match.entry.title + Self.address(match.entry.url)).inserted {
                let boost = boosts[match.entry.url.absoluteString] ?? 0
                out.append(
                    historyItem(
                        match.entry, score: match.score + Weight.history + boost,
                        ranges: match.titleRanges))
            }
        }

        if scope == nil || scope == .actions {
            for action in actions {
                let title = CommandMatcher.match(needle, action.title.lowercased())
                let keyword = action.keywords
                    .compactMap { CommandMatcher.match(needle, $0.lowercased())?.score }.max()
                let best = max(title?.score ?? -1, keyword ?? -1)
                // outside the actions scope a command needs a contiguous match
                guard best >= (scope == .actions ? 0 : CommandMatcher.Tier.substring)
                else { continue }
                let boost = boosts["action:" + action.id] ?? 0
                out.append(
                    actionItem(
                        action, score: best + Weight.action + boost,
                        ranges: (title?.score ?? -1) >= best ? (title?.ranges ?? []) : []))
            }
        }

        if scope == nil {
            let covered = Set(out.compactMap { $0.url?.absoluteString })
            for hit in textHits where !covered.contains(hit.url.absoluteString) {
                out.append(
                    CommandItem(
                        id: "text-" + hit.id, kind: .pageText(hit), title: hit.title,
                        hint: hit.snippet, ranges: [],
                        score: CommandMatcher.Tier.substring + Weight.pageText))
            }
        }

        out.sort { $0.score > $1.score }
        return out
    }

    // MARK: - Autofill

    /// the host the bar would finish the input into; only a well-worn host
    /// clearly ahead of any other with the same prefix
    func autofill(for input: String) -> CommandAutofill? {
        let typed = input.lowercased()
        guard typed.count >= 2, !typed.contains(" "), !typed.contains("://"), !typed.hasPrefix("!"),
            typed.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" })
        else { return nil }

        let now = Date()
        var best: (host: String, frecency: Double)?
        var runnerUp: Double = 0

        func offer(_ host: String, _ frecency: Double) {
            guard host.count > typed.count else { return }
            guard let current = best else {
                best = (host, frecency)
                return
            }
            if host == current.host {
                best = (host, max(frecency, current.frecency))
            } else if frecency > current.frecency {
                runnerUp = max(runnerUp, current.frecency)
                best = (host, frecency)
            } else {
                runnerUp = max(runnerUp, frecency)
            }
        }

        for entry in manager.history.autofillCandidates(typed, now: now).prefix(24) {
            offer(entry.autofillHost, entry.frecency(now: now))
        }
        for tab in manager.switchableTabs {
            guard var host = tab.url?.host()?.lowercased() else { continue }
            if host.hasPrefix("www.") { host = String(host.dropFirst(4)) }
            guard host.hasPrefix(typed) else { continue }
            offer(host, 6)
        }

        guard let winner = best, winner.frecency >= 2, winner.frecency >= 1.5 * runnerUp
        else { return nil }
        return CommandAutofill(
            host: winner.host, completion: String(winner.host.dropFirst(typed.count)))
    }

    // MARK: - Running

    func run(_ item: CommandItem, input: String, launch: CommandLaunch) {
        if let key = item.learningKey { habits?.record(input: input, key: key) }
        switch item.kind {
        case .tab(let tab):
            if launch == .beside { manager.openBeside(tab) } else { manager.focus(tab) }
        case .space(let space):
            manager.selectSpace(space)
        case .action(let action):
            action.run()
        case .closed(let closed):
            if launch == .normal { manager.reopen(closed) } else { open(closed.url, launch) }
        case .history(let entry):
            if manager.kind != .incognito { manager.history.markTyped(entry.url) }
            open(entry.url, launch)
        case .pageText(let hit):
            open(hit.url, launch)
        case .openURL(let url):
            if manager.kind != .incognito { manager.history.markTyped(url) }
            open(url, launch)
        case .bang(let bang, let trigger, let query):
            let url = bang?.url(for: query) ?? Bangs.fallbackURL(trigger: trigger, query: query)
            if let url { open(url, launch) }
        case .suggestion(let text):
            if let url = URLInput.searchURL(for: text) { open(url, launch) }
        case .search(let text):
            if let url = URLInput.searchURL(for: text) { open(url, launch) }
        case .scope:
            break
        }
    }

    private func open(_ url: URL, _ launch: CommandLaunch) {
        switch launch {
        case .normal:
            manager.newTab(url: url)
        case .current:
            if let tab = manager.selectedTab { tab.load(url) } else { manager.newTab(url: url) }
        case .scout:
            if let delegate = AppDelegate.shared {
                delegate.openScoutWindow(url)
            } else {
                manager.newTab(url: url)
            }
        case .beside:
            manager.openBeside(manager.newTab(url: url, select: false))
        }
    }

    // MARK: - Item builders

    private func tabItem(_ tab: BrowserTab, score: Int, ranges: [Range<Int>]) -> CommandItem {
        CommandItem(
            id: "tab-\(tab.id)", kind: .tab(tab), title: tab.displayTitle,
            hint: (tab.url ?? tab.pendingURL).map(Self.address) ?? "", ranges: ranges, score: score)
    }

    private func spaceItem(_ space: Space, score: Int, ranges: [Range<Int>]) -> CommandItem {
        CommandItem(
            id: "space-\(space.id)", kind: .space(space), title: space.name,
            hint: "", ranges: ranges, score: score)
    }

    private func closedItem(_ closed: ClosedTab, score: Int, ranges: [Range<Int>]) -> CommandItem {
        CommandItem(
            id: "closed-\(closed.id)", kind: .closed(closed), title: closed.title,
            hint: Self.address(closed.url), ranges: ranges, score: score)
    }

    private func historyItem(
        _ entry: HistoryEntry, score: Int, ranges: [Range<Int>]
    ) -> CommandItem {
        let address = Self.address(entry.url)
        // a page titled with its own host says nothing its address doesn't
        let titled = !entry.title.isEmpty && !address.hasPrefix(entry.title.lowercased())
        return CommandItem(
            id: "history-\(entry.url.absoluteString)", kind: .history(entry),
            title: titled ? entry.title : address, hint: titled ? address : "",
            ranges: titled ? ranges : [], score: score)
    }

    private func actionItem(
        _ action: CommandAction, score: Int, ranges: [Range<Int>]
    ) -> CommandItem {
        CommandItem(
            id: "action-\(action.id)", kind: .action(action), title: action.title,
            hint: "", ranges: ranges, score: score)
    }

    private func bangItem(_ bang: Bang, query: String) -> CommandItem {
        CommandItem(
            id: "bang-\(bang.trigger)", kind: .bang(bang, trigger: bang.trigger, query: query),
            title: query.isEmpty ? bang.name : "\(bang.name): \(query)",
            hint: "!\(bang.trigger)", ranges: [], score: 0)
    }

    private func unknownBangItem(_ trigger: String, query: String) -> CommandItem {
        CommandItem(
            id: "bang-unknown-\(trigger)", kind: .bang(nil, trigger: trigger, query: query),
            title: query.isEmpty ? "!\(trigger)" : "!\(trigger): \(query)",
            hint: "DuckDuckGo bang", ranges: [], score: 0)
    }

    /// head and tail rows sit where they're put; only `rank` reads a score
    private func openItem(_ url: URL) -> CommandItem {
        CommandItem(
            id: "url-\(url.absoluteString)", kind: .openURL(url),
            title: url.absoluteString, hint: "", ranges: [], score: 0)
    }

    private func searchItem(_ query: String) -> CommandItem {
        CommandItem(
            id: "search-\(query)", kind: .search(query), title: query,
            hint: "", ranges: [], score: 0)
    }

    private func suggestionItem(_ text: String) -> CommandItem {
        CommandItem(
            id: "suggest-\(text)", kind: .suggestion(text), title: text,
            hint: "", ranges: [], score: 0)
    }

    /// host and path, the way a person reads an address: no scheme, www,
    /// query or trailing slash
    private static func address(_ url: URL) -> String {
        guard var host = url.host() else { return url.absoluteString }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        let path = url.path()
        return path == "/" ? host : host + (path.hasSuffix("/") ? String(path.dropLast()) : path)
    }

    // MARK: - Actions catalog

    /// every command the bar can run. tab-scoped ones drop out when there's no
    /// tab, so the list never offers something that would do nothing
    private var actions: [CommandAction] {
        var out: [CommandAction] = [
            CommandAction(
                id: "new-space", title: "New Space…", symbol: "plus.square.on.square",
                keywords: ["create", "workspace"],
                run: { manager.isSpaceCreatorVisible = true }),
            CommandAction(
                id: "incognito", title: "New Incognito Window", symbol: "eyeglasses",
                keywords: ["private", "burner", "ephemeral", "secret"],
                run: { IncognitoWindow.open() }),
            CommandAction(
                id: "toggle-sidebar", title: "Toggle Sidebar", symbol: "sidebar.left",
                keywords: ["hide", "collapse", "show"], run: { manager.isSidebarCollapsed.toggle() }),
            CommandAction(
                id: "library", title: "Library", symbol: "books.vertical",
                keywords: ["archive", "downloads", "history"],
                run: { manager.isLibraryOpen = true }),
            CommandAction(
                id: "history", title: "History", symbol: "clock.arrow.circlepath",
                keywords: ["visited", "trail"], run: { openLibrary("History") }),
            CommandAction(
                id: "archive", title: "Archive", symbol: "archivebox",
                keywords: ["old tabs", "stale"], run: { openLibrary("Archive") }),
            CommandAction(
                id: "downloads", title: "Downloads", symbol: "arrow.down.circle",
                keywords: ["files", "saved"], run: { openLibrary("Downloads") }),
            CommandAction(
                id: "clear-today", title: "Clear Today’s Tabs", symbol: "sparkles",
                keywords: ["close all", "tidy", "clean"], run: { manager.clearTodayTabs() }),
            CommandAction(
                id: "feedback", title: "Send Feedback…", symbol: "exclamationmark.bubble",
                keywords: ["bug", "report", "problem", "issue", "crash", "suggestion", "idea"],
                run: {
                    // once the bar has faded, so the screenshot doesn't catch it
                    Task {
                        try? await Task.sleep(for: .milliseconds(350))
                        FeedbackDraft.open(in: manager)
                    }
                }),
            CommandAction(
                id: "import", title: "Import from Browser…", symbol: "square.and.arrow.down",
                keywords: ["bookmarks", "history", "passwords", "move", "migrate", "chrome", "safari", "firefox", "zen"],
                run: { BrowserImportModel.open(in: manager) }),
            CommandAction(
                id: "settings", title: "Settings", symbol: "gearshape",
                keywords: ["preferences", "config", "options"], run: { SettingsView.open() }),
            CommandAction(
                id: "passwords", title: "Passwords", symbol: "key",
                keywords: ["logins", "passkeys", "keychain", "credentials", "accounts"],
                run: { ProfilesNavigator.show(.passwords, for: manager.currentProfile.id) }),
            CommandAction(
                id: "toolbar", title: BrowserToolbar.isShown ? "Hide Toolbar" : "Show Toolbar",
                symbol: "menubar.rectangle", keywords: ["address bar", "url", "top bar"],
                run: { UserDefaults.standard.set(!BrowserToolbar.isShown, forKey: BrowserToolbar.shownKey) }),
        ]

        if Updates.shared.isEnabled {
            out.append(
                CommandAction(
                    id: "check-updates", title: "Check for Updates…", symbol: "arrow.down.circle",
                    keywords: ["update", "upgrade", "new version", "release", "beta"],
                    run: { Updates.shared.checkNow() }))
        }

        if spaces.count > 1 {
            out.append(
                CommandAction(
                    id: "next-space", title: "Next Space", symbol: "arrow.right",
                    keywords: ["switch"], run: { manager.cycleSpace(by: 1) }))
            out.append(
                CommandAction(
                    id: "previous-space", title: "Previous Space", symbol: "arrow.left",
                    keywords: ["switch"], run: { manager.cycleSpace(by: -1) }))
        }

        if let last = closedTabs.first {
            out.append(
                CommandAction(
                    id: "reopen-closed", title: "Reopen “\(last.title)”",
                    symbol: "arrow.uturn.backward",
                    keywords: ["reopen", "closed", "undo", "restore", "tab"],
                    run: { manager.reopenLastClosedTab() }))
        }

        guard let tab = manager.selectedTab else { return out }

        if tab.isReaderAvailable || tab.isReaderMode {
            out.append(
                CommandAction(
                    id: "reader", title: tab.isReaderMode ? "Hide Reader" : "Show Reader",
                    symbol: "doc.plaintext", keywords: ["article", "reading", "clean"],
                    run: { Task { await tab.toggleReader() } }))
        }
        if let target = PasswordAutofill.shared.target(in: tab),
            let login = PasswordStore.shared.matches(for: target.origin, in: tab.loginProfile).first
        {
            out.append(
                CommandAction(
                    id: "fill-password", title: "Fill Password", symbol: "key.fill",
                    keywords: ["login", "sign in", "autofill", login.username],
                    run: { Task { await PasswordAutofill.shared.fill(login, into: target, in: tab) } }))
        }
        if tab.url != nil {
            out.append(
                CommandAction(
                    id: "translate-page",
                    title: tab.pageTranslation.isActive ? "Show Original" : "Translate Page",
                    symbol: "translate", keywords: ["language", "on device", "foreign", "original"],
                    run: { Task { await tab.toggleTranslation() } }))
        }
        if !tab.isPrivate, let languages = tab.pageTranslation.languages, let rules = tab.translationRules {
            let language = PageTranslation.name(of: languages.from)
            let always = rules.alwaysTranslates(languages.from)
            out.append(
                CommandAction(
                    id: "translate-always",
                    title: always ? "Stop Always Translating \(language)" : "Always Translate \(language)",
                    symbol: "translate", keywords: ["language", "automatic", "rule"],
                    run: { tab.setAlwaysTranslates(languages.from, !always) }))
            let never = rules.neverTranslates(tab.url)
            out.append(
                CommandAction(
                    id: "translate-never",
                    title: never ? "Allow Translating This Site" : "Never Translate This Site",
                    symbol: "translate", keywords: ["language", "automatic", "rule"],
                    run: { tab.setNeverTranslatesSite(!never) }))
        }
        out.append(
            CommandAction(
                id: "split", title: manager.displayedSplitGroup == nil ? "Split View" : "Unsplit",
                symbol: "rectangle.split.2x1", keywords: ["pane", "side by side", "tile"],
                run: { manager.toggleSplit() }))
        out.append(
            CommandAction(
                id: "pip", title: "Picture in Picture", symbol: "pip",
                keywords: ["video", "float", "mini player"],
                run: { manager.togglePictureInPicture() }))
        out.append(
            CommandAction(
                id: "pin", title: tab.isPinned ? "Unpin Tab" : "Pin Tab", symbol: "pin",
                keywords: ["favorite", "keep"], run: { manager.togglePin(tab) }))
        out.append(
            CommandAction(
                id: "duplicate", title: "Duplicate Tab", symbol: "plus.square.on.square",
                keywords: ["copy", "clone"], run: { manager.duplicateTab(tab) }))
        out.append(
            CommandAction(
                id: "mute", title: tab.isMuted ? "Unmute Tab" : "Mute Tab",
                symbol: tab.isMuted ? "speaker.slash" : "speaker.wave.2",
                keywords: ["sound", "audio", "silence"], run: { tab.toggleMuted() }))
        out.append(
            CommandAction(
                id: "copy-url", title: "Copy Page Link", symbol: "link",
                keywords: ["address", "clipboard", "url", "share"], run: { tab.copyLink() }))
        out.append(
            CommandAction(
                id: "copy-markdown", title: "Copy Page Link as Markdown", symbol: "text.badge.plus",
                keywords: ["clipboard", "md"], run: { tab.copyLink(asMarkdown: true) }))
        out.append(
            CommandAction(
                id: "find", title: "Find on Page…", symbol: "magnifyingglass",
                keywords: ["search page", "locate"],
                run: {
                    manager.opensFindBarAsking = false
                    manager.isFindBarVisible = true
                }))
        out.append(
            CommandAction(
                id: "zoom-in", title: "Zoom In", symbol: "plus.magnifyingglass",
                keywords: ["bigger", "larger", "text size"], run: { tab.zoomIn() }))
        out.append(
            CommandAction(
                id: "zoom-out", title: "Zoom Out", symbol: "minus.magnifyingglass",
                keywords: ["smaller", "text size"], run: { tab.zoomOut() }))
        out.append(
            CommandAction(
                id: "zoom-reset", title: "Actual Size", symbol: "1.magnifyingglass",
                keywords: ["reset zoom", "100%"], run: { tab.resetZoom() }))
        out.append(
            CommandAction(
                id: "print", title: "Print…", symbol: "printer",
                keywords: ["pdf", "paper"], run: { tab.printPage() }))
        out.append(
            CommandAction(
                id: "export-pdf", title: "Export Page as PDF", symbol: "doc.richtext",
                keywords: ["save", "download"], run: { Task { await tab.export(.pdf) } }))
        out.append(
            CommandAction(
                id: "export-archive", title: "Save Page as Web Archive", symbol: "archivebox",
                keywords: ["save", "offline", "download"], run: { Task { await tab.export(.webArchive) } }))
        out.append(
            CommandAction(
                id: "export-image", title: "Capture Full Page", symbol: "camera.viewfinder",
                keywords: ["screenshot", "image", "png", "save"],
                run: { Task { await tab.export(.fullPageImage) } }))
        if tab.isCapturing {
            out.append(
                CommandAction(
                    id: "stop-capture", title: "Stop Camera and Microphone", symbol: "video.slash",
                    keywords: ["webcam", "mic", "privacy"], run: { tab.stopCapture() }))
        }
        out.append(
            CommandAction(
                id: "keep-loaded", title: tab.keepsLoaded ? "Stop Keeping Tab Loaded" : "Keep Tab Loaded",
                symbol: "lock", keywords: ["sleep", "hibernate", "memory"],
                run: { tab.keepsLoaded.toggle(); manager.scheduleSave() }))
        out.append(
            CommandAction(
                id: "inspector",
                title: tab.isInspectorVisible ? "Close Web Inspector" : "Show Web Inspector",
                symbol: "curlybraces", keywords: ["devtools", "developer", "debug", "console"],
                run: { tab.toggleInspector() }))
        out.append(
            CommandAction(
                id: "close", title: "Close Tab", symbol: "xmark",
                keywords: ["quit", "dismiss"], run: { manager.closeSelectedTab() }))
        return out
    }

    private func openLibrary(_ mode: String) {
        UserDefaults.standard.set(mode, forKey: "libraryLastMode")
        manager.isLibraryOpen = true
    }
}
