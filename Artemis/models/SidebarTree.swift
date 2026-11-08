// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import SwiftUI

/// which of a space's two lists an entry hangs in
enum SidebarSection: Equatable, Hashable { case pinned, today }

/// one entry in a space's sidebar tree
enum SidebarEntry: Equatable, Hashable {
    case tab(BrowserTab.ID)
    case folder(TabFolder.ID)
}

/// where an entry sits: straight in a section, or inside a folder
enum SidebarContainer: Equatable, Hashable {
    case section(SidebarSection)
    case folder(TabFolder.ID)
}

/// a named, collapsible run of sidebar entries that can hold folders of its own.
/// it survives being emptied
@Observable
final class TabFolder: Identifiable {
    let id: UUID
    var name: String
    var isExpanded: Bool
    var children: [SidebarEntry]
    /// set when the folder fills itself from a source
    var live: LiveFolder?

    init(id: UUID = UUID(), name: String, isExpanded: Bool = true, children: [SidebarEntry] = []) {
        self.id = id
        self.name = name
        self.isExpanded = isExpanded
        self.children = children
    }
}

/// what a sidebar row draws: a tab, a split's panes merged into one row, or a
/// folder header
enum SidebarRowKind {
    case tab(BrowserTab)
    case group(SplitGroup, [BrowserTab])
    case folder(TabFolder)
}

/// one row of the sidebar as drawn. `container` and `depth` are what a drop
/// needs to name a position
struct SidebarRow: Identifiable {
    let kind: SidebarRowKind
    let container: SidebarContainer
    let section: SidebarSection
    let depth: Int

    var id: String {
        switch kind {
        case .tab(let tab): "tab-\(tab.id)"
        case .group(let group, _): "group-\(group.id)"
        case .folder(let folder): "folder-\(folder.id)"
        }
    }

    /// the tabs this row stands for — one, a split's panes, or none for a folder
    var tabs: [BrowserTab] {
        switch kind {
        case .tab(let tab): [tab]
        case .group(_, let members): members
        case .folder: []
        }
    }
}

// MARK: - The tree

/// `Space.tabs` is the authority on which tabs exist; the entry tree is the
/// authority on their order and nesting. `normalizeTree` is what makes the two
/// agree, and every mutation ends in it.
extension Space {
    /// folder levels a space may hold; deeper entries are dropped by `normalizeTree`
    nonisolated static let maxFolderDepth = 5

    func folder(_ id: TabFolder.ID) -> TabFolder? { folders.first { $0.id == id } }

    func entries(in container: SidebarContainer) -> [SidebarEntry] {
        switch container {
        case .section(.pinned): pinnedEntries
        case .section(.today): todayEntries
        case .folder(let id): folder(id)?.children ?? []
        }
    }

    func setEntries(_ entries: [SidebarEntry], in container: SidebarContainer) {
        switch container {
        case .section(.pinned): pinnedEntries = entries
        case .section(.today): todayEntries = entries
        case .folder(let id): folder(id)?.children = entries
        }
    }

    /// the container holding `entry`, or nil if the tree doesn't have it
    func parent(of entry: SidebarEntry) -> SidebarContainer? {
        if pinnedEntries.contains(entry) { return .section(.pinned) }
        if todayEntries.contains(entry) { return .section(.today) }
        return folders.first { $0.children.contains(entry) }.map { .folder($0.id) }
    }

    /// true when the tab sits inside a folder rather than loose in a section.
    /// filing a tab is as deliberate as pinning it, so the sweeps leave it alone
    func isFoldered(_ id: BrowserTab.ID) -> Bool {
        if case .folder = parent(of: .tab(id)) { return true }
        return false
    }

    /// the section a container ultimately hangs in, climbing the folder chain
    func section(of container: SidebarContainer) -> SidebarSection {
        var current = container
        for _ in 0...Space.maxFolderDepth {
            switch current {
            case .section(let section): return section
            case .folder(let id):
                guard let up = parent(of: .folder(id)) else { return .today }
                current = up
            }
        }
        return .today
    }

    /// the indent level a container's children draw at
    func depth(of container: SidebarContainer) -> Int {
        var current = container
        var depth = 0
        for _ in 0...Space.maxFolderDepth {
            switch current {
            case .section: return depth
            case .folder(let id):
                guard let up = parent(of: .folder(id)) else { return depth }
                current = up
                depth += 1
            }
        }
        return depth
    }

    /// true when `container` is `folder` itself or sits anywhere beneath it —
    /// the check that stops a folder being dragged into its own subtree
    func container(_ container: SidebarContainer, isWithin folder: TabFolder.ID) -> Bool {
        var current = container
        for _ in 0...Space.maxFolderDepth {
            switch current {
            case .section: return false
            case .folder(let id):
                if id == folder { return true }
                guard let up = parent(of: .folder(id)) else { return false }
                current = up
            }
        }
        return false
    }

    /// levels of folder nesting under this folder — 0 when it holds no folders
    private func height(of folder: TabFolder) -> Int {
        var out = 0
        for case .folder(let id) in folder.children {
            guard let child = self.folder(id), out < Space.maxFolderDepth else { continue }
            out = max(out, 1 + height(of: child))
        }
        return out
    }

    /// `depth(of:)` is the level a container's children draw at, so this is
    /// whether one more folder still fits under the cap there
    func canNestFolder(in container: SidebarContainer) -> Bool {
        depth(of: container) < Space.maxFolderDepth
    }

    /// the same question for a folder that brings a subtree with it
    func canNest(_ folder: TabFolder, in container: SidebarContainer) -> Bool {
        depth(of: container) + height(of: folder) < Space.maxFolderDepth
    }

    /// every tab under a container, folders included, in flatten order
    func tabIDs(under container: SidebarContainer) -> [BrowserTab.ID] {
        var out: [BrowserTab.ID] = []
        func walk(_ list: [SidebarEntry], _ depth: Int) {
            guard depth <= Space.maxFolderDepth else { return }
            for entry in list {
                switch entry {
                case .tab(let id): out.append(id)
                case .folder(let id):
                    if let folder = folder(id) { walk(folder.children, depth + 1) }
                }
            }
        }
        walk(entries(in: container), 0)
        return out
    }

    /// every folder under a container, itself excluded
    func folderIDs(under container: SidebarContainer) -> [TabFolder.ID] {
        var out: [TabFolder.ID] = []
        func walk(_ list: [SidebarEntry], _ depth: Int) {
            guard depth <= Space.maxFolderDepth else { return }
            for case .folder(let id) in list {
                out.append(id)
                if let folder = folder(id) { walk(folder.children, depth + 1) }
            }
        }
        walk(entries(in: container), 0)
        return out
    }

    /// pull an entry out of wherever it is, returning the slot it left
    @discardableResult
    func removeEntry(_ entry: SidebarEntry) -> (SidebarContainer, Int)? {
        guard let container = parent(of: entry) else { return nil }
        var list = entries(in: container)
        guard let index = list.firstIndex(of: entry) else { return nil }
        list.remove(at: index)
        setEntries(list, in: container)
        return (container, index)
    }

    func insertEntry(_ entry: SidebarEntry, into container: SidebarContainer, at index: Int) {
        var list = entries(in: container)
        list.insert(entry, at: max(0, min(index, list.count)))
        setEntries(list, in: container)
    }

    /// move an entry to a new slot, reading the index as a position in the
    /// destination *after* the entry has been lifted out of its old one
    func moveEntry(_ entry: SidebarEntry, to container: SidebarContainer, at index: Int) {
        removeEntry(entry)
        insertEntry(entry, into: container, at: index)
    }

    // MARK: Repair

    /// reconcile the tree with `tabs`: stale, duplicate and over-deep entries
    /// go, tabs the tree never heard of join their section. Rewrites `tabs` in
    /// flatten order, and never removes one.
    func normalizeTree() {
        var seenTabs = Set<BrowserTab.ID>()
        var seenFolders = Set<TabFolder.ID>()
        let known = Set(tabs.map(\.id))

        func prune(_ list: [SidebarEntry], depth: Int) -> [SidebarEntry] {
            var out: [SidebarEntry] = []
            for entry in list {
                switch entry {
                case .tab(let id):
                    guard known.contains(id), seenTabs.insert(id).inserted else { continue }
                    out.append(entry)
                case .folder(let id):
                    // over the cap the folder goes, not its tabs: they fall
                    // through to the sweep below and reappear in the section
                    guard depth < Space.maxFolderDepth, let folder = folder(id),
                        seenFolders.insert(id).inserted
                    else { continue }
                    folder.children = prune(folder.children, depth: depth + 1)
                    out.append(entry)
                }
            }
            return out
        }

        pinnedEntries = prune(pinnedEntries, depth: 0)
        todayEntries = prune(todayEntries, depth: 0)
        folders.removeAll { !seenFolders.contains($0.id) }

        for tab in tabs where !seenTabs.contains(tab.id) {
            if tab.isPinned {
                pinnedEntries.append(.tab(tab.id))
            } else {
                todayEntries.append(.tab(tab.id))
            }
        }

        tabs = flattenedTabs()
    }

    /// `tabs` in tree order, each tab's section taken from the root it hangs in
    private func flattenedTabs() -> [BrowserTab] {
        let byID = Dictionary(tabs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var out: [BrowserTab] = []
        func walk(_ list: [SidebarEntry], _ section: SidebarSection, _ depth: Int) {
            guard depth <= Space.maxFolderDepth else { return }
            for entry in list {
                switch entry {
                case .tab(let id):
                    guard let tab = byID[id] else { continue }
                    // the tree, not the flag, says which section a tab is in,
                    // and a pin without its anchor is a pin nothing can deviate from
                    tab.isPinned = section == .pinned
                    if tab.isPinned {
                        if tab.pinnedURL == nil {
                            tab.pinnedURL = tab.url ?? tab.lastAttemptedURL ?? tab.pendingURL
                        }
                    } else {
                        tab.pinnedURL = nil
                    }
                    out.append(tab)
                case .folder(let id):
                    if let folder = folder(id) { walk(folder.children, section, depth + 1) }
                }
            }
        }
        walk(pinnedEntries, .pinned, 0)
        walk(todayEntries, .today, 0)
        return out
    }

    // MARK: Rows

    /// the section's rows as drawn, top to bottom: folder headers over their visible
    /// children, each split's panes as one row, and for a collapsed folder its header
    /// plus the tab you are on if it is filed there
    func rows(in section: SidebarSection) -> [SidebarRow] {
        let byID = Dictionary(tabs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var groupOf: [BrowserTab.ID: SplitGroup] = [:]
        for group in splitGroups {
            for id in group.tabIDs where groupOf[id] == nil { groupOf[id] = group }
        }
        var out: [SidebarRow] = []
        func walk(_ container: SidebarContainer, depth: Int) {
            guard depth <= Space.maxFolderDepth else { return }
            let list = entries(in: container)
            var i = 0
            while i < list.count {
                switch list[i] {
                case .folder(let id):
                    guard let folder = folder(id) else { i += 1; continue }
                    out.append(
                        SidebarRow(
                            kind: .folder(folder), container: container, section: section,
                            depth: depth))
                    if folder.isExpanded {
                        walk(.folder(id), depth: depth + 1)
                    } else if let active = selectedTabID,
                        case let filed = tabIDs(under: .folder(id)), filed.contains(active),
                        let tab = byID[active]
                    {
                        // a folded folder still shows the tab you are on, so
                        // folding never hides where you are; a split shows whole
                        let group = groupOf[active]
                        let members = group.map { group in
                            filed.filter { groupOf[$0] === group }.compactMap { byID[$0] }
                        } ?? []
                        let kind: SidebarRowKind =
                            if let group, members.count >= SplitGroup.minPanes {
                                .group(group, members)
                            } else {
                                .tab(tab)
                            }
                        out.append(
                            SidebarRow(
                                kind: kind, container: .folder(id), section: section,
                                depth: depth + 1))
                    }
                    i += 1
                case .tab(let id):
                    guard let tab = byID[id] else { i += 1; continue }
                    // a split is one row: the maximal run of its panes among
                    // these siblings, which is what keeps a group's members
                    // contiguous inside one container
                    if let group = groupOf[id] {
                        var run = [tab]
                        var j = i + 1
                        while j < list.count, case .tab(let next) = list[j],
                            groupOf[next] === group, let member = byID[next]
                        {
                            run.append(member)
                            j += 1
                        }
                        if run.count >= SplitGroup.minPanes {
                            out.append(
                                SidebarRow(
                                    kind: .group(group, run), container: container,
                                    section: section, depth: depth))
                            i = j
                            continue
                        }
                    }
                    out.append(
                        SidebarRow(
                            kind: .tab(tab), container: container, section: section, depth: depth))
                    i += 1
                }
            }
        }
        walk(.section(section), depth: 0)
        return out
    }

    /// every visible row, pinned above today — the order ⌘1–⌘8 and ⇧-click
    /// ranges count in, which is the order on screen and not the order in `tabs`
    var visibleRows: [SidebarRow] {
        (pinnedCollapsed ? [] : rows(in: .pinned)) + rows(in: .today)
    }
}
