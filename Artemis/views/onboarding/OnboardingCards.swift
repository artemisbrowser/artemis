// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import SwiftUI

/// the setup cards after the intro, over the same sky: import, search, the sidebar, the look, habits, a few keys
struct OnboardingCards: View {
    /// played again from Settings: the search engine stays as chosen until a tap
    let isReplay: Bool
    let finish: () -> Void
    @Environment(TabManager.self) private var tabManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(AppIconChoice.storageKey) private var icon = AppIconChoice.bundled
    @AppStorage(BrowserToolbar.shownKey) private var showsToolbar = false
    @AppStorage(Intelligence.enabledKey) private var thinks = false
    @AppStorage(Intelligence.tidyTitlesKey) private var tidiesNames = true
    @State private var step = Step.bringAlong
    @State private var isForward = true
    @State private var browsers: [ImportedBrowser]?
    @State private var usedEngine: (engine: SearchEngine, browser: String)?
    @State private var hasPickedEngine = false
    @State private var showsMoreEngines = false
    @State private var sites: [Site] = []
    @State private var visitedCount = 0
    @State private var picked: Set<String> = []
    @State private var starters: Set<String> = []
    @State private var isDefault = DefaultBrowser.isArtemis
    @State private var canTidy = Intelligence.isReady
    /// the profile the cards set up, held from the start, as an import may switch to another
    @State private var profile: Profile
    private var blocker = ContentBlocker.shared

    init(profile: Profile, isReplay: Bool, finish: @escaping () -> Void) {
        _profile = State(initialValue: profile)
        self.isReplay = isReplay
        self.finish = finish
    }

    private enum Step: Int, CaseIterable {
        case bringAlong, search, sidebar, yours, habits, ready
    }

    private static let engines: [SearchEngine] = [.duckduckgo, .google, .brave, .kagi, .ecosia, .startpage, .perplexity]
    private static let moreEngines: [SearchEngine] = [.bing, .yahoo, .qwant, .wikipedia]
    private static let popular = [
        Site(name: "Gmail", host: "mail.google.com"), Site(name: "YouTube", host: "youtube.com"),
        Site(name: "Calendar", host: "calendar.google.com"), Site(name: "GitHub", host: "github.com"),
        Site(name: "Notion", host: "notion.so"), Site(name: "Spotify", host: "open.spotify.com"),
        Site(name: "Claude", host: "claude.ai"), Site(name: "Reddit", host: "reddit.com"),
        Site(name: "Figma", host: "figma.com"), Site(name: "Drive", host: "drive.google.com"),
    ]
    private static let starterSpaces = [("Work", "briefcase.fill"), ("School", "graduationcap.fill"), ("Projects", "hammer.fill")]

    private var ownSpaces: [Space] { tabManager.spaces.filter { $0.profileID == profile.id } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 36) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(heading)
                        .font(.system(size: 30, weight: .semibold))
                    Text(detail)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    controls
                        .padding(.top, 14)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                visual
                    .frame(width: 230, height: 250)
            }
            .id(step)
            .transition(reduceMotion ? .opacity : .push(from: isForward ? .trailing : .leading))
            Spacer(minLength: 0)
            footer
        }
        .padding(40)
        .frame(width: 720, height: 480)
        .clipShape(.rect(cornerRadius: 32))
        .glassEffect(.regular, in: .rect(cornerRadius: 32))
        .task {
            for engine in Self.engines + Self.moreEngines {
                FaviconStore.shared.prefetch(host: Self.host(of: engine), profile: profile.id, isPrivate: false)
            }
            let found = await Self.lookForBrowsers().value
            browsers = found
            guard let used = await Task.detached(priority: .utility, operation: { Self.searchHost(in: found) }).value,
                let engine = SearchEngine.allCases.first(where: { Self.host(of: $0) == used.host })
            else { return }
            usedEngine = (engine, used.browser)
            if !hasPickedEngine, !isReplay { choose(engine, byHand: false) }
        }
        .task(id: step) {
            if step == .search { await suggestSites() }
        }
        .onDisappear(perform: settle)
    }

    private static var search: Task<[ImportedBrowser], Never>?

    /// starts the search for other browsers' data once, so the first card has it by the time it shows
    @discardableResult
    static func lookForBrowsers() -> Task<[ImportedBrowser], Never> {
        if let search { return search }
        let started = Task.detached(priority: .utility) { Importers.detect(home: .homeDirectory) }
        search = started
        return started
    }

    private var heading: String {
        switch step {
        case .bringAlong: "Bring your stuff along"
        case .search: "Choose a search engine"
        case .sidebar: "Set up your sidebar"
        case .yours: "Make it yours"
        case .habits: "How you browse"
        case .ready: "You're all set"
        }
    }

    private var detail: String {
        switch step {
        case .bringAlong: "Move your spaces, tabs, bookmarks, history and passwords over from the browser you use now."
        case .search: "Searches from the address bar go here."
        case .sidebar: "Favourites stay one click away in every space."
        case .yours: "Pick a colour for the icon. It shows in the Dock, the app switcher and Finder."
        case .habits: "You can change any of these later in Settings."
        case .ready: "A few keys worth knowing."
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch step {
        case .bringAlong:
            VStack(alignment: .leading, spacing: 14) {
                if let browsers {
                    Text(found(browsers))
                        .foregroundStyle(.secondary)
                }
                Button(browsers?.first.map { "Import from \($0.name)…" } ?? "Import…") {
                    ImportModel.open(in: tabManager)
                }
                .buttonStyle(.glass)
                .controlSize(.large)
            }
        case .search:
            searchControls
        case .sidebar:
            sidebarControls
        case .yours:
            VStack(alignment: .leading, spacing: 12) {
                Rows(items: AppIconChoice.allCases, columns: 6, spacing: 10) { choice in
                    Button {
                        icon = choice
                        AppIconChoice.apply()
                    } label: {
                        Circle()
                            .fill(LinearGradient(colors: [choice.glyph.light, choice.glyph.base], startPoint: .top, endPoint: .bottom))
                            .frame(width: 26, height: 26)
                            .padding(2)
                            .overlay(Circle().stroke(.white.opacity(icon == choice ? 0.9 : 0), lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(choice.label)
                    .accessibilityAddTraits(icon == choice ? .isSelected : [])
                    .tooltip(choice.label)
                }
                Text(icon.label)
                    .foregroundStyle(.secondary)
            }
            .animation(Motion.pop, value: icon)
        case .habits:
            habitControls
        case .ready:
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
                keys("⌘T", "Search, or open a site or tab")
                keys("⌘S", "Show or hide the sidebar")
                keys("⌥⌘N", "Open a site from any app")
            }
        }
    }

    private var searchControls: some View {
        let current = profile.searchEngine, suggests = SearchSuggest.supports(current)
        let other = Self.moreEngines.contains(current) ? current : nil
        return VStack(alignment: .leading, spacing: 14) {
            Rows(items: Self.engines.map(Optional.some) + [nil], columns: 4) { engine in
                if let engine {
                    Button { choose(engine) } label: {
                        Tile(name: engine.label, isPicked: current == engine) { SiteIcon(host: Self.host(of: engine), name: engine.label, side: 22) }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(current == engine ? .isSelected : [])
                } else {
                    Button { showsMoreEngines.toggle() } label: {
                        Tile(name: other?.label ?? "More", isPicked: other != nil) {
                            if let other {
                                SiteIcon(host: Self.host(of: other), name: other.label, side: 22)
                            } else {
                                Image(systemName: "ellipsis").font(.system(size: 16, weight: .semibold)).frame(width: 22, height: 22)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showsMoreEngines, arrowEdge: .bottom) {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Self.moreEngines, id: \.self) { engine in
                                Button {
                                    choose(engine)
                                    showsMoreEngines = false
                                } label: {
                                    Label { Text(engine.label) } icon: { SiteIcon(host: Self.host(of: engine), name: engine.label, side: 16) }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 5)
                                        .contentShape(.rect)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(8)
                        .frame(width: 170)
                    }
                }
            }
            if let usedEngine {
                Text("You used \(usedEngine.engine.label) in \(usedEngine.browser).")
                    .foregroundStyle(.secondary)
                    .opacity(usedEngine.engine == current || isReplay ? 1 : 0)
            }
            switchRow(
                "Show suggestions", suggests ? "Sends what you type to \(current.label)." : "\(current.label) doesn't offer suggestions.",
                isOn: Binding(
                    get: { suggests && profile.suggestsSearches },
                    set: {
                        profile.suggestsSearches = $0
                        tabManager.scheduleSave()
                    })
            )
            .disabled(!suggests)
            .opacity(suggests ? 1 : 0.4)
        }
        .animation(Motion.pop, value: current)
    }

    private var sidebarControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Favourites").font(.headline)
                Text(visitedCount == 0 ? "Popular sites" : visitedCount == sites.count ? "Sites you visit most" : "Suggested")
                    .foregroundStyle(.secondary)
            }
            Rows(items: sites, columns: 4) { site in
                Button { picked.formSymmetricDifference([site.host]) } label: {
                    Tile(name: site.name, isPicked: picked.contains(site.host)) { SiteIcon(host: site.host, name: site.name, side: 22) }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(picked.contains(site.host) ? .isSelected : [])
            }
            Text("Spaces").font(.headline)
                .padding(.top, 6)
            let own = ownSpaces
            if own.count > 1 {
                Text("Your \(own.count) spaces are ready.")
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 6) {
                    ForEach(own) { space in chip(space.name, space.icon, isPicked: true) }
                    ForEach(Self.starterSpaces.filter { name, _ in !own.contains { $0.name == name } }, id: \.0) { name, symbol in
                        Button { starters.formSymmetricDifference([name]) } label: {
                            chip(name, symbol, isPicked: starters.contains(name))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(starters.contains(name) ? .isSelected : [])
                    }
                }
            }
            switchRow("Show a toolbar", "Puts the address and buttons above the page.", isOn: $showsToolbar)
                .padding(.top, 10)
        }
        .animation(Motion.pop, value: picked)
        .animation(Motion.pop, value: starters)
    }

    private var habitControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                setting("Archive old tabs", "Tabs you leave alone move to the archive.")
                Spacer()
                Picker(
                    "Archive old tabs",
                    selection: Binding(
                        get: { profile.archiveAfterHours },
                        set: {
                            profile.archiveAfterHours = $0
                            tabManager.scheduleSave()
                        })
                ) {
                    ForEach(Profile.archiveChoices, id: \.self) { Text($0 == 0 ? "Never" : "After \(Profile.archiveLabel($0))").tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            switchRow(
                "Block ads and trackers", "Built in, with no extension to install.",
                isOn: Binding(get: { blocker.isEnabled }, set: { blocker.isEnabled = $0 }))
            if canTidy {
                switchRow(
                    "Tidy tab names", "Shortens long titles with the model on this Mac.",
                    isOn: Binding(
                        get: { thinks && tidiesNames },
                        set: { on in
                            tidiesNames = on
                            guard on, !thinks else { return }
                            // Ask about this page stays off unless it was set before
                            if UserDefaults.standard.object(forKey: Intelligence.askPageKey) == nil {
                                UserDefaults.standard.set(false, forKey: Intelligence.askPageKey)
                            }
                            thinks = true
                        }))
            }
            HStack {
                setting("Default browser", "Links from other apps open here.")
                Spacer()
                if isDefault {
                    Label("Done", systemImage: "checkmark")
                        .foregroundStyle(.secondary)
                } else {
                    Button("Make Default") {
                        Task {
                            await DefaultBrowser.makeArtemis()
                            isDefault = DefaultBrowser.isArtemis
                        }
                    }
                    .buttonStyle(.glass)
                }
            }
        }
    }

    @ViewBuilder
    private var visual: some View {
        switch step {
        case .bringAlong:
            if let browsers { BrowserFan(browsers: browsers) }
        case .search:
            SearchSketch(engine: profile.searchEngine, suggests: SearchSuggest.supports(profile.searchEngine) && profile.suggestsSearches)
        case .sidebar, .habits:
            WindowSketch(
                showsToolbar: showsToolbar, blocks: step == .habits && blocker.isEnabled, favourites: sketchedFavourites,
                spaces: sketchedSpaces)
        case .yours, .ready:
            HeldMark(side: 180)
        }
    }

    /// the favourites grid as it will be: those already there, then the picks
    private var sketchedFavourites: [Site] {
        var seen = Set<String>()
        let had = profile.essentials.compactMap { ($0.pinnedURL ?? $0.url)?.host().map(Self.bare) }.map { Site(name: $0, host: $0) }
        return Array((had + sites.filter { picked.contains($0.host) }).filter { seen.insert($0.host).inserted }.prefix(9))
    }

    private var sketchedSpaces: [String] {
        let own = ownSpaces
        return own.map(\.icon) + (own.count > 1 ? [] : Self.starterSpaces.filter { starters.contains($0.0) }.map(\.1))
    }

    private var footer: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.self) { each in
                    Capsule()
                        .fill(.white.opacity(each == step ? 0.9 : 0.25))
                        .frame(width: each == step ? 18 : 6, height: 6)
                }
            }
            .animation(Motion.pop, value: step)
            Spacer()
            if let back = Step(rawValue: step.rawValue - 1) {
                Button("Back") { go(to: back) }
                    .buttonStyle(.glass)
                    .controlSize(.large)
            }
            Button(step == .ready ? "Start Browsing" : "Continue") {
                if let next = Step(rawValue: step.rawValue + 1) { go(to: next) } else { finish() }
            }
            .buttonStyle(.glassProminent)
            .tint(icon.glyph.base)
            .controlSize(.large)
            .keyboardShortcut(tabManager.importer == nil ? KeyboardShortcut.defaultAction : nil)
        }
    }

    private func go(to next: Step) {
        isForward = next.rawValue > step.rawValue
        withAnimation(Motion.panel) { step = next }
    }

    private func choose(_ engine: SearchEngine, byHand: Bool = true) {
        hasPickedEngine = hasPickedEngine || byHand
        profile.searchEngine = engine
        tabManager.scheduleSave()
    }

    /// the eight sites offered as favourites: the ones they visit most, topped up with popular ones
    private func suggestSites() async {
        let profile = self.profile, entries = profile.history.entries
        let skipped = Set(
            profile.essentials.compactMap { ($0.pinnedURL ?? $0.url)?.host() }.map(Self.bare)
                + SearchEngine.allCases.map { Self.bare(Self.host(of: $0)) })
        let visited = await Task.detached(priority: .utility) { Self.mostVisited(entries, leaving: skipped) }.value
        let names = Dictionary(uniqueKeysWithValues: Self.popular.map { ($0.host, $0.name) })
        let fill = Self.popular.filter { !skipped.contains($0.host) && !visited.contains($0.host) }
        sites = visited.map { Site(name: names[$0] ?? $0, host: $0) } + fill.prefix(8 - visited.count)
        visitedCount = visited.count
        for site in sites { FaviconStore.shared.prefetch(host: site.host, profile: profile.id, isPrivate: false) }
    }

    /// up to eight hosts by frecency summed across their pages, without `www.`
    nonisolated private static func mostVisited(_ entries: [HistoryEntry], leaving skipped: Set<String>) -> [String] {
        let now = Date()
        var score: [String: Double] = [:]
        for entry in entries where entry.url.scheme == "https" || entry.url.scheme == "http" {
            guard let host = entry.url.host().map(bare), host.contains("."), host.last?.isLetter == true, !skipped.contains(host)
            else { continue }
            score[host, default: 0] += entry.frecency(now: now)
        }
        return score.sorted { $0.value > $1.value }.prefix(8).map(\.key)
    }

    nonisolated private static func bare(_ host: String) -> String {
        host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    fileprivate static func host(of engine: SearchEngine) -> String {
        engine.searchURL(for: "")?.host() ?? ""
    }

    /// the search engine host set in the Chromium profile of the browser they use, when it names one
    nonisolated private static func searchHost(in browsers: [ImportedBrowser]) -> (host: String, browser: String)? {
        let usual = URL(string: "https://example.com").flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) }.flatMap { Bundle(url: $0)?.bundleIdentifier }
        guard let browser = browsers.first(where: { $0.bundleID == usual }) ?? browsers.first,
            let profile = browser.profiles.first(where: \.isDefault) ?? browser.profiles.first,
            let data = try? Data(contentsOf: profile.folder.appending(path: "Preferences")),
            let prefs = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let provider = prefs["default_search_provider_data"] as? [String: Any],
            let template = (provider["template_url_data"] as? [String: Any])?["url"] as? String,
            let host = URL(string: template.replacingOccurrences(of: "{searchTerms}", with: ""))?.host()
        else { return nil }
        return (host, browser.name)
    }

    private func settle() {
        Self.search = nil
        let names = Set(ownSpaces.map(\.name))
        let links = sites.filter { picked.contains($0.host) }.compactMap { site in
            URL(string: "https://\(site.host)/").map { BookmarkImport.Link(title: site.name, url: $0) }
        }
        tabManager.addFavourites(links, to: profile)
        for (name, symbol) in Self.starterSpaces where starters.contains(name) && !names.contains(name) {
            let preset = SpacePreset.all[tabManager.spaces.count % SpacePreset.all.count]
            tabManager.spaces.append(Space(name: name, icon: symbol, appearance: preset.appearance, profileID: profile.id))
        }
        tabManager.scheduleSave()
    }

    private func found(_ browsers: [ImportedBrowser]) -> String {
        var seen = Set<String>()
        let names = browsers.map(\.name).filter { seen.insert($0).inserted }
        guard let last = names.last else { return "No other browser found on this Mac." }
        let list = names.count == 1 ? last : names.dropLast().joined(separator: ", ") + " and " + last
        return "Found \(list) on this Mac."
    }

    private func setting(_ title: String, _ note: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(note)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func chip(_ name: String, _ symbol: String, isPicked: Bool) -> some View {
        Label(name, systemImage: symbol)
            .font(.callout)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(.white.opacity(isPicked ? 0.16 : 0.05), in: .capsule)
            .overlay(Capsule().stroke(.white.opacity(isPicked ? 0.75 : 0), lineWidth: 1.5))
            .contentShape(.capsule)
    }

    /// a setting whose switch keeps to the trailing edge, however long the words
    private func switchRow(_ title: String, _ note: String, isOn: Binding<Bool>) -> some View {
        HStack {
            setting(title, note)
            Spacer(minLength: 12)
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
    }

    private func keys(_ caps: String, _ meaning: String) -> some View {
        GridRow {
            Text(caps)
                .font(.system(.body, design: .rounded, weight: .medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .glassEffect(.regular, in: .rect(cornerRadius: 8))
                .gridColumnAlignment(.trailing)
            Text(meaning)
        }
    }
}

private struct Site: Hashable {
    let name: String
    let host: String
}

/// a pickable square: an icon over a short name
private struct Tile<Icon: View>: View {
    let name: String
    let isPicked: Bool
    @ViewBuilder let icon: Icon

    var body: some View {
        VStack(spacing: 6) {
            icon
            Text(name)
                .font(.caption)
                .lineLimit(1)
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity)
        .frame(height: 54)
        .background(.white.opacity(isPicked ? 0.16 : 0.05), in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(isPicked ? 0.75 : 0), lineWidth: 1.5))
        .contentShape(.rect(cornerRadius: 12))
    }
}

/// a site's favicon, or its initial until the favicon arrives
private struct SiteIcon: View {
    let host: String
    let name: String
    let side: CGFloat

    var body: some View {
        if let image = FaviconStore.shared.icon(for: host) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: side, height: side)
        } else {
            Text(name.prefix(1).uppercased())
                .font(.system(size: side * 0.55, weight: .semibold))
                .frame(width: side, height: side)
                .background(.white.opacity(0.15), in: .rect(cornerRadius: side * 0.25))
        }
    }
}

/// the command bar drawn small: the engine, and its suggestions unrolling beneath when they're on
private struct SearchSketch: View {
    let engine: SearchEngine
    let suggests: Bool

    var body: some View {
        let line = Color.white.opacity(0.22), fill = Color.white.opacity(0.07)
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                SiteIcon(host: OnboardingCards.host(of: engine), name: engine.label, side: 18)
                Text("Search \(engine.label)")
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(height: 42)
            VStack(alignment: .leading, spacing: 0) {
                Rectangle().fill(line).frame(height: 1)
                ForEach(0..<3, id: \.self) { k in
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                        Capsule().fill(line).frame(width: [110, 80, 96][k], height: 5)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 30)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(suggests ? 1 : 0)
            .frame(height: suggests ? 91 : 0, alignment: .top)
            .clipped()
        }
        .frame(width: 220)
        .background(RoundedRectangle(cornerRadius: 14).fill(fill))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(line))
        .animation(Motion.panel, value: suggests)
        .animation(Motion.pop, value: engine)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// the detected browsers' icons, fanned like a hand of cards
private struct BrowserFan: View {
    let browsers: [ImportedBrowser]
    @State private var isShown = false

    var body: some View {
        var seen = Set<String>()
        let icons = Array(browsers.map(\.bundleID).filter { seen.insert($0).inserted }.compactMap(Self.icon).prefix(4))
        ZStack {
            if icons.isEmpty {
                Image(systemName: "tray.and.arrow.down")
                    .font(.system(size: 72, weight: .light))
                    .foregroundStyle(.secondary)
            }
            ForEach(icons.indices, id: \.self) { k in
                let spread = Double(k) - Double(icons.count - 1) / 2
                Image(nsImage: icons[k])
                    .resizable()
                    .frame(width: 96, height: 96)
                    .shadow(color: .black.opacity(0.35), radius: 10, y: 6)
                    .rotationEffect(.degrees(isShown ? spread * 11 : 0), anchor: .bottom)
                    .offset(x: isShown ? spread * 42 : 0, y: isShown ? abs(spread) * 10 : 30)
                    .opacity(isShown ? 1 : 0)
                    .animation(Motion.panel.delay(0.06 * Double(k)), value: isShown)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { isShown = true }
    }

    private static func icon(_ bundleID: String) -> NSImage? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { NSWorkspace.shared.icon(forFile: $0.path) }
    }
}

/// a small window drawn in outline: the sidebar with its favourites and spaces, the page, and the toolbar when it shows
private struct WindowSketch: View {
    let showsToolbar: Bool
    let blocks: Bool
    let favourites: [Site]
    let spaces: [String]

    var body: some View {
        let line = Color.white.opacity(0.22), fill = Color.white.opacity(0.07)
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 4) {
                    ForEach(0..<3, id: \.self) { _ in Circle().fill(line).frame(width: 6, height: 6) }
                }
                .padding(.bottom, 4)
                if !showsToolbar {
                    Capsule().fill(fill).stroke(line).frame(height: 14)
                }
                Rows(items: favourites, columns: 3, spacing: 4) { site in
                    SiteIcon(host: site.host, name: site.name, side: 11)
                        .frame(maxWidth: .infinity)
                        .frame(height: 18)
                        .background(fill, in: .rect(cornerRadius: 5))
                        .transition(.scale.combined(with: .opacity))
                }
                ForEach(0..<3, id: \.self) { k in
                    Capsule().fill(line).frame(width: [52, 40, 46][k], height: 5)
                }
                Spacer(minLength: 0)
                HStack(spacing: 9) {
                    ForEach(spaces.indices, id: \.self) { k in
                        Image(systemName: spaces[k])
                            .font(.system(size: 8))
                            .foregroundStyle(.white.opacity(0.75))
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .frame(width: 72)
            VStack(spacing: 0) {
                if showsToolbar {
                    HStack {
                        Capsule().fill(fill).stroke(line).frame(width: 80, height: 14)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 26)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
                VStack(alignment: .leading, spacing: 8) {
                    RoundedRectangle(cornerRadius: 4).fill(line).frame(height: 40)
                    ForEach(0..<4, id: \.self) { k in
                        Capsule().fill(line.opacity(0.7)).frame(width: [100, 80, 110, 60][k], height: 5)
                    }
                    Spacer()
                }
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(fill))
            .clipShape(.rect(cornerRadius: 8))
        }
        .padding(10)
        .frame(width: 230, height: 190)
        .background(RoundedRectangle(cornerRadius: 14).stroke(line))
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 26))
                .foregroundStyle(.white.opacity(0.85))
                .padding(12)
                .opacity(blocks ? 1 : 0)
                .scaleEffect(blocks ? 1 : 0.6)
        }
        .animation(Motion.panel, value: showsToolbar)
        .animation(Motion.pop, value: blocks)
        .animation(Motion.pop, value: favourites)
        .animation(Motion.pop, value: spaces)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// `items` in rows of `columns`, built with the card so they arrive with it
private struct Rows<Item: Hashable, Cell: View>: View {
    let items: [Item]
    let columns: Int
    var spacing: CGFloat = 8
    @ViewBuilder let cell: (Item) -> Cell

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: spacing, verticalSpacing: spacing) {
            ForEach(Array(stride(from: 0, to: items.count, by: columns)), id: \.self) { start in
                GridRow {
                    ForEach(items[start..<min(start + columns, items.count)], id: \.self) { cell($0) }
                }
            }
        }
    }
}
