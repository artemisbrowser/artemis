// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import Foundation

/// what an import can bring; the sheet shows a category only when its source has it
nonisolated enum ImportCategory: CaseIterable, Hashable, Sendable {
    case spaces, favourites, bookmarks, archive, history, cookies, passwords
}

/// One browser's chosen parts as Artemis session data, for `TabManager.importBrowser`.
nonisolated struct ImportHaul {
    /// new profiles to adopt, never the default one
    var profiles: [ProfileData] = []
    var spaces: [SpaceData] = []
    /// one per source profile, its only pinned entry the bookmarks folder to land in a space here
    var bookmarks: [SpaceData] = []
    /// by Artemis profile id; every `url` and `home` is already a web link
    var favourites: [UUID: [ImportedTab]] = [:]
    var archive: [UUID: [ArchiveEntry]] = [:]
    /// a restored tab's url → the title shown until it loads
    var titles: [String: String] = [:]
}

/// Shapes what a reader found into Artemis' session types. Pure, so it runs off main.
nonisolated enum ImportBuilder {
    /// `destinations` maps each included source profile to its Artemis profile; one mapped
    /// to its own id is a new profile. `names` are the profile names Artemis already has.
    static func haul(
        _ browser: ImportedBrowser, into destinations: [UUID: UUID], taking categories: Set<ImportCategory>,
        names: Set<String>
    ) -> ImportHaul {
        var out = ImportHaul()
        var names = names
        let marked = browser.profiles.filter { destinations[$0.id] != nil && !$0.bookmarks.isEmpty }.count
        for profile in browser.profiles {
            guard let into = destinations[profile.id] else { continue }
            if into == profile.id {
                let name = names.contains(profile.name) ? "\(profile.name) (\(browser.name))" : profile.name
                names.insert(name)
                out.profiles.append(ProfileData(id: into, name: name, icon: profile.icon ?? "person.crop.circle"))
            }
            if categories.contains(.bookmarks), let folder = bookmarks(profile, of: browser, into: into, named: marked > 1) {
                out.bookmarks.append(folder.data)
                out.titles.merge(folder.titles) { first, _ in first }
            }
            for space in categories.contains(.spaces) ? profile.spaces : [] {
                var walk = Walk()
                let pinned = walk.entries(space.pinned, pinned: true)
                let today = walk.entries(space.today, pinned: false)
                guard browser.family == .arc || !(pinned.isEmpty && today.isEmpty) else { continue }
                out.spaces.append(
                    SpaceData(
                        id: space.id, name: space.name, icon: space.icon ?? "square.stack",
                        appearance: appearance(space.colors, grain: space.grain, index: out.spaces.count),
                        profileID: into, splitGroups: walk.splits, tabs: walk.tabs,
                        selectedTabID: walk.tabs.first?.id, pinnedEntries: pinned, todayEntries: today))
                out.titles.merge(walk.titles) { first, _ in first }
            }
            if categories.contains(.favourites) {
                out.favourites[into, default: []] += profile.favourites.compactMap { tab in
                    link(tab).map {
                        ImportedTab(
                            url: $0.url, title: tab.title, name: tab.name.flatMap { $0.isEmpty ? nil : $0 },
                            home: $0.home)
                    }
                }
            }
            if categories.contains(.archive) {
                out.archive[into, default: []] += profile.archive.compactMap { item in
                    guard let raw = web(item.url), let url = URL(string: raw) else { return nil }
                    return ArchiveEntry(
                        url: url, title: item.title.isEmpty ? (url.host() ?? raw) : item.title,
                        archivedAt: item.archivedAt, spaceName: item.spaceName, name: item.name)
                }
            }
        }
        if !browser.spaceOrder.isEmpty {
            let rank = Dictionary(browser.spaceOrder.enumerated().map { ($1, $0) }) { first, _ in first }
            out.spaces.sort { rank[$0.id, default: .max] < rank[$1.id, default: .max] }
        }
        return out
    }

    /// web visits only, each titled and counted at least once
    static func history(_ visits: [ImportedVisit]) -> [HistoryEntry] {
        visits.compactMap { visit in
            guard let raw = web(visit.url), let url = URL(string: raw) else { return nil }
            return HistoryEntry(
                url: url, title: visit.title.isEmpty ? (url.host() ?? raw) : visit.title,
                lastVisited: visit.lastVisited, visitCount: max(1, visit.visitCount), typedCount: visit.typedCount)
        }
    }

    /// the tab's page and home as web links, a missing one taking the other's; nil when neither is
    static func link(_ tab: ImportedTab) -> (url: String, home: String)? {
        let page = web(tab.url)
        let home = tab.home.flatMap(web)
        guard let either = page ?? home else { return nil }
        return (page ?? either, home ?? either)
    }

    /// http(s) only, after Brave's `containers+<uuid>:` prefix
    private static func web(_ raw: String) -> String? {
        var raw = raw
        if raw.hasPrefix("containers+"), let colon = raw.firstIndex(of: ":") {
            raw = String(raw[raw.index(after: colon)...])
        }
        guard let scheme = URL(string: raw)?.scheme?.lowercased(), scheme == "http" || scheme == "https"
        else { return nil }
        return raw
    }

    /// the profile's bookmarks as one collapsed folder of collapsed roots; its id is stable, so importing again finds it
    private static func bookmarks(
        _ profile: ImportedProfile, of browser: ImportedBrowser, into: UUID, named: Bool
    ) -> (data: SpaceData, titles: [String: String])? {
        let roots = profile.bookmarks.compactMap { item -> ImportedItem? in
            guard case .folder(let name, _, let children) = item else { return item }
            return children.isEmpty ? nil : .folder(name: name, expanded: false, children)
        }
        var walk = Walk()
        let inner = walk.entries(roots, pinned: true, depth: 1)
        guard !inner.isEmpty else { return nil }
        let folder = EntryData(
            kind: "folder", id: Importers.stableID("\(browser.bundleID)/\(profile.key)/bookmarks"),
            name: "Imported bookmarks from \(browser.name)" + (named ? " (\(profile.name))" : ""), expanded: false,
            children: inner)
        let data = SpaceData(
            id: UUID(), name: "", icon: "bookmark", appearance: SpaceAppearance(), profileID: into, tabs: walk.tabs,
            pinnedEntries: [folder])
        return (data, walk.titles)
    }

    /// up to three visible colours; none falls back to a preset picked by `index`
    private static func appearance(_ colors: [RGBA], grain: Double, index: Int) -> SpaceAppearance {
        let visible = colors.filter { $0.a > 0.01 }
        guard !visible.isEmpty else { return SpacePreset.all[index % SpacePreset.all.count].appearance }
        var out = SpaceAppearance()
        out.fill = visible.count == 1 ? .solid : .gradient
        out.colors = Array(visible.prefix(3))
        out.grain = min(max(grain, 0), 1)
        return out
    }

    /// one space's items as an entry tree, collecting its tabs, splits and titles on the way
    private struct Walk {
        var tabs: [TabRecord] = []
        var splits: [SplitGroupData] = []
        var titles: [String: String] = [:]

        mutating func entries(_ items: [ImportedItem], pinned: Bool, depth: Int = 0) -> [EntryData] {
            var out: [EntryData] = []
            for item in items {
                switch item {
                case .tab(let tab):
                    if let entry = record(tab, pinned: pinned) { out.append(entry) }
                case .folder(let name, let expanded, let children):
                    let inner = entries(children, pinned: pinned, depth: depth + 1)
                    // deeper than Artemis nests: the contents come up a level
                    if depth >= Space.maxFolderDepth {
                        out += inner
                    } else {
                        out.append(
                            EntryData(
                                kind: "folder", id: UUID(), name: name.isEmpty ? "Folder" : name, expanded: expanded,
                                children: inner))
                    }
                case .split(let panes, let orientation):
                    let all = panes.compactMap { record($0, pinned: pinned) }
                    for start in stride(from: 0, to: all.count, by: SplitGroup.maxPanes) {
                        let chunk = Array(all[start..<min(start + SplitGroup.maxPanes, all.count)])
                        if chunk.count >= SplitGroup.minPanes {
                            splits.append(
                                SplitGroupData(
                                    id: UUID(), tree: nil, tabIDs: chunk.map(\.id), tabIndices: [],
                                    orientation: orientation, ratios: [], linkSourceID: nil, linkTargetID: nil,
                                    linkSourceIndex: nil, linkTargetIndex: nil))
                        }
                        out += chunk
                    }
                }
            }
            return out
        }

        private mutating func record(_ tab: ImportedTab, pinned: Bool) -> EntryData? {
            guard let link = ImportBuilder.link(tab) else { return nil }
            // lastAccessed is now: an imported tab's archive clock starts at import
            let record = TabRecord(
                url: link.url, pinnedURL: pinned ? link.home : nil, isPinned: pinned,
                name: tab.name.flatMap { $0.isEmpty ? nil : $0 })
            tabs.append(record)
            // keyed as the restored tab's URL prints
            let key = URL(string: link.url)?.absoluteString ?? link.url
            if let title = tab.title, !title.isEmpty, titles[key] == nil { titles[key] = title }
            return EntryData(kind: "tab", id: record.id)
        }
    }
}
