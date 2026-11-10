// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import Foundation
import SQLite3

/// A Gecko profile's session as spaces, favourites and archive: Firefox's windows, Zen's spaces
/// and Floorp's workspaces.
nonisolated enum GeckoSession {
    enum Flavour { case firefox, zen, floorp }

    struct Container {
        var name: String
        var icon: String?
    }

    /// keyed by container: 0 is the profile itself, n is `userContextId` n; every space listed holds something
    struct Layout {
        var spaces: [Int: [ImportedSpace]] = [:]
        var favourites: [Int: [ImportedTab]] = [:]
        var archive: [ImportedArchive] = []
        /// public identities only
        var containers: [Int: Container] = [:]
    }

    /// `namespace` prefixes every space key; `theme` is a CSS colour for spaces that bring none of their own
    static func layout(_ flavour: Flavour, folder: URL, name: String, namespace: String, theme: String?) -> Layout {
        var layout = Layout(containers: containers(folder))
        let saved = session(folder)
        let windows = (saved?.json["windows"] as? [[String: Any]] ?? []).filter {
            !flag($0["isPrivate"]) && !flag($0["isPopup"])
        }
        let prefs = (try? String(contentsOf: folder.appending(path: "prefs.js"), encoding: .utf8)) ?? ""
        let separate = pref("zen.workspaces.separate-essentials", in: prefs) != "false"
        var names: [String: String] = [:]
        let handled =
            switch flavour {
            case .zen:
                zen(lz4(folder.appending(path: "zen-sessions.jsonlz4")), namespace, separate, &layout, &names)
                    || zenLegacy(folder.appending(path: "places.sqlite"), windows, namespace, separate, &layout, &names)
            case .floorp: floorp(folder, prefs: prefs, windows, namespace, &layout, &names)
            case .firefox: false
            }
        if !handled { firefox(windows, name: name, namespace, &layout) }

        if let saved {
            layout.archive = archive(saved.json, saved: saved.date) { tab in
                ((tab["zenWorkspace"] as? String) ?? (tab["floorpWorkspaceId"] as? String).map(bare))
                    .flatMap { names[$0] } ?? name
            }
        }
        if flavour == .floorp { layout.archive += floorpArchive(folder) }

        let paint = color(theme).map { [$0] } ?? []
        layout.spaces = layout.spaces.compactMapValues { spaces in
            let kept = spaces.compactMap { space -> ImportedSpace? in
                guard !(space.pinned.isEmpty && space.today.isEmpty) else { return nil }
                var space = space
                if space.colors.isEmpty { space.colors = paint }
                return space
            }
            return kept.isEmpty ? nil : kept
        }
        layout.favourites = layout.favourites.filter { !$0.value.isEmpty }
        return layout
    }

    // MARK: - Firefox

    /// every normal window in one space, and each public container's tabs in a space of its own
    private static func firefox(_ windows: [[String: Any]], name: String, _ namespace: String, _ layout: inout Layout) {
        let containers = layout.containers
        let routed = windowSpaces(windows) { tab in
            let n = tab["userContextId"] as? Int ?? 0
            return containers[n] == nil ? "session" : "session/container/\(n)"
        }
        let spaces = [(0, "session", name)]
            + containers.sorted { $0.key < $1.key }.map { ($0.key, "session/container/\($0.key)", $0.value.name) }
        for (n, key, title) in spaces {
            guard let tree = routed[key] else { continue }
            layout.spaces[n, default: []].append(
                ImportedSpace(
                    id: Importers.stableID(namespace + key), name: title, pinned: tree.pinned, today: tree.today))
        }
    }

    /// each window's tabs in the space `route` names, in tab order: groups become today folders, splits stay whole
    private static func windowSpaces(
        _ windows: [[String: Any]], route: ([String: Any]) -> String
    ) -> [String: (pinned: [ImportedItem], today: [ImportedItem])] {
        var out: [String: (pinned: [ImportedItem], today: [ImportedItem])] = [:]
        for window in windows {
            let groups = keyed(window["groups"], by: "id")
            let native = !(window["splitViews"] as? [Any] ?? []).isEmpty
            // Floorp's own split ids count only where the window has no native split views
            func split(_ tab: [String: Any]) -> String? {
                native
                    ? (tab["splitViewId"] as? Int).map(String.init)
                    : tab["floorpSplitViewGroupId"] as? String
                        ?? (tab["extData"] as? [String: Any])?["floorp.splitViewGroupId"] as? String
            }
            // keys: "g" + a known group's id, else "s" + a split id
            func items(_ tabs: [[String: Any]], folders: Bool) -> [ImportedItem] {
                gather(tabs) { tab in
                    (folders ? (tab["groupId"] as? String).flatMap { groups[$0] == nil ? nil : "g" + $0 } : nil)
                        ?? split(tab).map { "s" + $0 }
                }.compactMap { key, members in
                    guard let key else { return tab(members[0]).map(ImportedItem.tab) }
                    guard key.hasPrefix("g"), let group = groups[String(key.dropFirst())] else {
                        return .split(members.compactMap { tab($0) }, .columns)
                    }
                    return .folder(
                        name: text(group["name"]) ?? "", expanded: !flag(group["collapsed"]),
                        items(members, folders: false))
                }
            }
            for (key, tabs) in Dictionary(grouping: window["tabs"] as? [[String: Any]] ?? [], by: route) {
                out[key, default: ([], [])].pinned += items(tabs.filter { flag($0["pinned"]) }, folders: false)
                out[key, default: ([], [])].today += items(tabs.filter { !flag($0["pinned"]) }, folders: true)
            }
        }
        return out
    }

    // MARK: - Archive

    /// closed tabs, closed and saved groups, closed windows, and a last session whose restore was deferred
    private static func archive(
        _ session: [String: Any], saved: Date, space: ([String: Any]) -> String
    ) -> [ImportedArchive] {
        var out: [ImportedArchive] = []
        func add(_ state: Any?, at time: Any?, title: Any? = nil) {
            guard let state = state as? [String: Any], let page = page(state) else { return }
            out.append(
                ImportedArchive(
                    url: page.url, title: page.title ?? text(title) ?? "", archivedAt: date(time) ?? saved,
                    spaceName: space(state)))
        }
        // a `removeAfterRestore` entry copies a tab listed elsewhere
        func closed(_ entries: Any?, group: [String: Any]? = nil) {
            for entry in entries as? [[String: Any]] ?? [] where !flag(entry["removeAfterRestore"]) {
                add(entry["state"], at: entry["closedAt"] ?? group?["closedAt"], title: entry["title"])
            }
        }
        let closedWindows = session["_closedWindows"] as? [[String: Any]] ?? []
        for window in (session["windows"] as? [[String: Any]] ?? []) + closedWindows where !flag(window["isPrivate"]) {
            closed(window["_closedTabs"])
            for group in window["closedGroups"] as? [[String: Any]] ?? [] { closed(group["tabs"], group: group) }
        }
        for window in closedWindows {
            for tab in window["tabs"] as? [[String: Any]] ?? [] { add(tab, at: window["closedAt"]) }
        }
        for group in session["savedGroups"] as? [[String: Any]] ?? [] { closed(group["tabs"], group: group) }
        for window in (session["lastSessionState"] as? [String: Any])?["windows"] as? [[String: Any]] ?? [] {
            for tab in window["tabs"] as? [[String: Any]] ?? [] { add(tab, at: tab["lastAccessed"]) }
        }
        return out
    }

    // MARK: - Zen

    private enum Node {
        case tab([String: Any])
        /// a `folders[]` entry: a folder, or a split placed like one
        case folder([String: Any])
        /// a split with no `folders[]` entry, by group id
        case split(String)
    }

    /// `zen-sessions.jsonlz4`: spaces with folder trees, splits and essentials; false when it holds no space
    private static func zen(
        _ json: [String: Any]?, _ namespace: String, _ separate: Bool, _ layout: inout Layout,
        _ names: inout [String: String]
    ) -> Bool {
        let spaces = (json?["spaces"] as? [[String: Any]] ?? []).compactMap { space in
            (space["uuid"] as? String).map { ($0, space) }
        }
        guard let json, let first = spaces.first?.0 else { return false }
        let tabs = (json["tabs"] as? [[String: Any]] ?? []).filter { !flag($0["zenIsGlance"]) }
        // one folder per id, so a walk down from a space never meets a folder twice
        var seen: Set<String> = []
        let folders = (json["folders"] as? [[String: Any]] ?? []).filter { ($0["id"] as? String).map { seen.insert($0).inserted } ?? false }
        let splits = keyed(json["splitViewData"], by: "groupId")
        let bySync = keyed(tabs, by: "zenSyncId")
        let entered = Set(folders.filter { flag($0["splitViewGroup"]) }.compactMap { $0["id"] as? String })
        let folderIDs = Set(folders.filter { !flag($0["splitViewGroup"]) }.compactMap { $0["id"] as? String })
        let spaceIDs = Set(spaces.map(\.0))
        let owned = Set(spaces.compactMap { $0.1["containerTabId"] as? Int }.filter { layout.containers[$0] != nil })
        func space(_ raw: Any?) -> String { (raw as? String).flatMap { spaceIDs.contains($0) ? $0 : nil } ?? first }
        func loose(_ tab: [String: Any]) -> String? {
            (tab["groupId"] as? String).flatMap { splits[$0] != nil && !entered.contains($0) ? $0 : nil }
        }
        func split(_ id: String, pinned: Bool) -> ImportedItem? {
            guard let data = splits[id] else { return nil }
            let tree = leaves(data["layoutTree"])
            let panes = (tree.isEmpty ? data["tabs"] as? [String] ?? [] : tree).compactMap { bySync[$0] }
                .filter { flag($0["pinned"]) == pinned && !flag($0["zenEssential"]) && !flag($0["zenIsEmpty"]) }
            return .split(panes.compactMap { tab($0, pinned: pinned) }, orientation(data))
        }
        // `prevSiblingInfo`: missing or `start` is first, else after a tab's `zenSyncId` or a group's id;
        // resolved before placeholders drop, and entries whose sibling never appears go last in array order
        func chain(_ entries: [[String: Any]], into nodes: inout [Node]) {
            func id(_ node: Node) -> String? {
                switch node {
                case .tab: nil
                case .folder(let folder): folder["id"] as? String
                case .split(let id): id
                }
            }
            var pending = entries
            var starts = 0
            var placed = true
            while placed {
                placed = false
                pending = pending.filter { entry in
                    let info = entry["prevSiblingInfo"] as? [String: Any]
                    let sibling = info?["id"] as? String
                    let at: Int?
                    switch info?["type"] as? String {
                    case nil, "start": at = starts
                    case "tab":
                        let group = sibling.flatMap { bySync[$0]?["groupId"] as? String }
                        at = nodes.firstIndex { node in
                            if case .tab(let raw) = node, raw["zenSyncId"] as? String == sibling { return true }
                            return group != nil && id(node) == group
                        }.map { $0 + 1 }
                    case "group": at = nodes.firstIndex { sibling != nil && id($0) == sibling }.map { $0 + 1 }
                    default: at = nil
                    }
                    guard let at else { return true }
                    if at == starts, info?["type"] as? String ?? "start" == "start" { starts += 1 }
                    nodes.insert(.folder(entry), at: at)
                    placed = true
                    return false
                }
            }
            nodes += pending.map(Node.folder)
        }
        func children(_ parent: String?, of spaceID: String) -> [ImportedItem] {
            let direct = tabs.filter { tab in
                guard !flag(tab["zenEssential"]) else { return false }
                let group = tab["groupId"] as? String
                if let parent { return group == parent }
                return flag(tab["pinned"]) && space(tab["zenWorkspace"]) == spaceID
                    && !(group.map { folderIDs.contains($0) || entered.contains($0) } ?? false)
            }
            var nodes = gather(direct, by: loose).map { key, members in key.map(Node.split) ?? .tab(members[0]) }
            chain(
                folders.filter { folder in
                    let up = (folder["parentId"] as? String).flatMap { folderIDs.contains($0) ? $0 : nil }
                    return parent == nil ? up == nil && space(folder["workspaceId"]) == spaceID : up == parent
                }, into: &nodes)
            return nodes.compactMap { node in
                switch node {
                case .tab(let raw): flag(raw["zenIsEmpty"]) ? nil : tab(raw, pinned: true).map(ImportedItem.tab)
                case .split(let id): split(id, pinned: true)
                case .folder(let folder):
                    flag(folder["splitViewGroup"])
                        ? (folder["id"] as? String).flatMap { split($0, pinned: true) }
                        : .folder(
                            name: text(folder["name"]) ?? "", expanded: !flag(folder["collapsed"]),
                            children(folder["id"] as? String, of: spaceID))
                }
            }
        }
        for (uuid, raw) in spaces {
            let theme = raw["theme"] as? [String: Any]
            let n = raw["containerTabId"] as? Int ?? 0
            let today = tabs.filter { tab in
                !flag(tab["pinned"]) && !flag(tab["zenEssential"]) && !flag(tab["zenIsEmpty"])
                    && space(tab["zenWorkspace"]) == uuid
            }
            names[uuid] = text(raw["name"]) ?? "Zen"
            layout.spaces[owned.contains(n) ? n : 0, default: []].append(
                ImportedSpace(
                    id: Importers.stableID(namespace + "zen/" + uuid), name: names[uuid] ?? "Zen", icon: zenIcon(raw["icon"]),
                    colors: colors(theme?["gradientColors"]),
                    grain: theme?["textureType"] as? String ?? "grain" == "grain" ? theme?["texture"] as? Double ?? 0 : 0,
                    pinned: children(nil, of: uuid),
                    today: gather(today, by: loose).compactMap { key, members in
                        if let key { return split(key, pinned: false) }
                        return tab(members[0]).map(ImportedItem.tab)
                    }))
        }
        essentials(
            tabs.filter { flag($0["zenEssential"]) }.compactMap { raw in
                tab(raw, pinned: true).map { ($0, raw["userContextId"] as? Int ?? 0) }
            }, separate: separate, owned: owned, into: &layout)
        return true
    }

    /// Zen before `zen-sessions.jsonlz4`: spaces and pins in places.sqlite, live pages in the session
    private static func zenLegacy(
        _ places: URL, _ windows: [[String: Any]], _ namespace: String, _ separate: Bool, _ layout: inout Layout,
        _ names: inout [String: String]
    ) -> Bool {
        struct Pin {
            var uuid: String, title: String, url: String?, container: Int?, space: String?, parent: String?
            var essential: Bool, group: Bool, edited: Bool, collapsed: Bool
        }
        let read = SQLiteCopy.withDatabase(at: places) { db -> (spaces: [[String: Any]], pins: [Pin]) in
            // columns vary by Zen release; a missing one reads as NULL
            func select(_ table: String, _ wanted: [String], order: [String]) -> String {
                let have = SQLiteCopy.columns(db, table)
                let sort = order.filter(have.contains)
                return "SELECT \(wanted.map { have.contains($0) ? $0 : "NULL" }.joined(separator: ", ")) FROM \(table) "
                    + "ORDER BY \(sort.isEmpty ? "rowid" : sort.joined(separator: ", "));"
            }
            var spaces: [[String: Any]] = []
            let wanted = ["uuid", "name", "icon", "container_id", "theme_colors", "theme_texture"]
            SQLiteCopy.rows(db, select("zen_workspaces", wanted, order: ["position", "created_at"])) { row in
                guard let uuid = SQLiteCopy.text(row, 0) else { return }
                spaces.append([
                    "uuid": uuid, "name": SQLiteCopy.text(row, 1) ?? "", "icon": SQLiteCopy.text(row, 2) ?? "",
                    "container": Int(sqlite3_column_int(row, 3)), "theme": SQLiteCopy.text(row, 4) ?? "",
                    "texture": sqlite3_column_double(row, 5),
                ])
            }
            var pins: [Pin] = []
            // one pin per uuid, so a walk down from a space never meets a group twice
            var seen: Set<String> = []
            let columns = [
                "uuid", "title", "url", "container_id", "workspace_uuid", "folder_parent_uuid", "is_essential", "is_group",
                "edited_title", "is_folder_collapsed",
            ]
            SQLiteCopy.rows(db, select("zen_pins", columns, order: ["position"])) { row in
                guard let uuid = SQLiteCopy.text(row, 0), seen.insert(uuid).inserted else { return }
                pins.append(
                    Pin(
                        uuid: uuid, title: SQLiteCopy.text(row, 1) ?? "", url: SQLiteCopy.text(row, 2),
                        container: sqlite3_column_type(row, 3) == SQLITE_NULL ? nil : Int(sqlite3_column_int(row, 3)),
                        space: SQLiteCopy.text(row, 4), parent: SQLiteCopy.text(row, 5),
                        essential: sqlite3_column_int(row, 6) != 0, group: sqlite3_column_int(row, 7) != 0,
                        edited: sqlite3_column_int(row, 8) != 0, collapsed: sqlite3_column_int(row, 9) != 0))
            }
            return (spaces, pins)
        }
        guard let read, let first = read.spaces.first?["uuid"] as? String else { return false }
        var live: [String: [String: Any]] = [:]
        let tabs = windows.flatMap { $0["tabs"] as? [[String: Any]] ?? [] }.filter { !flag($0["zenIsGlance"]) }
        for tab in tabs { if let id = tab["zenPinnedId"] as? String, live[id] == nil { live[id] = tab } }
        let spaceIDs = Set(read.spaces.compactMap { $0["uuid"] as? String })
        let groups = Set(read.pins.filter(\.group).map(\.uuid))
        let owned = Set(read.spaces.compactMap { $0["container"] as? Int }.filter { layout.containers[$0] != nil })
        func space(_ id: String?) -> String { id.flatMap { spaceIDs.contains($0) ? $0 : nil } ?? first }
        func essential(_ pin: Pin) -> Bool { !pin.group && (pin.essential || flag(live[pin.uuid]?["zenEssential"])) }
        func tab(_ pin: Pin) -> ImportedTab? {
            let raw = live[pin.uuid]
            let current = raw.flatMap(page)
            guard let url = current?.url ?? pin.url else { return nil }
            return ImportedTab(
                url: url, title: current?.title ?? text(pin.title), name: pin.edited ? text(pin.title) : nil,
                home: pin.url == url ? nil : pin.url)
        }
        func children(_ parent: String?, of spaceID: String) -> [ImportedItem] {
            read.pins.filter { pin in
                guard !essential(pin) else { return false }
                let up = pin.parent.flatMap { groups.contains($0) ? $0 : nil }
                return parent == nil ? up == nil && space(pin.space) == spaceID : up == parent
            }.compactMap { pin in
                pin.group
                    ? .folder(name: pin.title, expanded: !pin.collapsed, children(pin.uuid, of: spaceID))
                    : tab(pin).map(ImportedItem.tab)
            }
        }
        for raw in read.spaces {
            guard let uuid = raw["uuid"] as? String else { continue }
            let n = raw["container"] as? Int ?? 0
            let stops = (raw["theme"] as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) }
            names[uuid] = text(raw["name"]) ?? "Zen"
            layout.spaces[owned.contains(n) ? n : 0, default: []].append(
                ImportedSpace(
                    id: Importers.stableID(namespace + "zen/" + uuid), name: names[uuid] ?? "Zen",
                    icon: zenIcon(raw["icon"]), colors: colors(stops), grain: raw["texture"] as? Double ?? 0,
                    pinned: children(nil, of: uuid),
                    today: tabs.filter { tab in
                        !flag(tab["pinned"]) && !flag(tab["zenEssential"]) && !flag(tab["zenIsEmpty"])
                            && space(tab["zenWorkspace"] as? String) == uuid
                    }.compactMap { GeckoSession.tab($0).map(ImportedItem.tab) }))
        }
        let pinIDs = Set(read.pins.map(\.uuid))
        let pinned = read.pins.filter(essential).compactMap { pin in
            tab(pin).map { ($0, pin.container ?? live[pin.uuid]?["userContextId"] as? Int ?? 0) }
        }
        let loose = tabs.filter { flag($0["zenEssential"]) && !pinIDs.contains($0["zenPinnedId"] as? String ?? "") }
            .compactMap { raw in GeckoSession.tab(raw, pinned: true).map { ($0, raw["userContextId"] as? Int ?? 0) } }
        essentials(pinned + loose, separate: separate, owned: owned, into: &layout)
        return true
    }

    /// with `separate`, an essential goes to the container whose space owns it, else the profile;
    /// without, to the profile and every container a space owns
    private static func essentials(
        _ tabs: [(tab: ImportedTab, container: Int)], separate: Bool, owned: Set<Int>, into layout: inout Layout
    ) {
        for (tab, n) in tabs {
            for key in separate ? [owned.contains(n) ? n : 0] : [0] + owned.sorted() {
                layout.favourites[key, default: []].append(tab)
            }
        }
    }

    /// a split's root axis, deeper ones flattened into it: Zen's `row` lays panes side by side
    private static func orientation(_ split: [String: Any]) -> SplitOrientation {
        let axis =
            (split["layoutTree"] as? [String: Any])?["direction"] as? String
            ?? (split["gridType"] as? String == "hsep" ? "column" : "row")
        return axis == "column" ? .rows : .columns
    }

    /// a layout tree's tab ids, depth first
    private static func leaves(_ node: Any?) -> [String] {
        guard let node = node as? [String: Any] else { return [] }
        if let id = node["tabId"] as? String { return [id] }
        return (node["children"] as? [Any] ?? []).flatMap { leaves($0) }
    }

    /// up to three stops: `[r, g, b]` in 0…255, or a CSS colour
    private static func colors(_ stops: Any?) -> [RGBA] {
        let all = (stops as? [[String: Any]] ?? []).compactMap { stop -> RGBA? in
            if let c = stop["c"] as? [Double], c.count >= 3 { return RGBA(c[0] / 255, c[1] / 255, c[2] / 255) }
            return color(stop["c"] as? String)
        }
        return Array(all.prefix(3))
    }

    /// an emoji as it is, or a selectable `chrome://…/<name>.svg` as its SF Symbol
    private static func zenIcon(_ raw: Any?) -> String? {
        guard let icon = text(raw) else { return nil }
        guard icon.hasSuffix(".svg") else { return icon.contains("/") ? nil : icon }
        return zenSymbols[String((icon.split(separator: "/").last ?? "").dropLast(4))]
    }

    // MARK: - Floorp

    /// Floorp's workspaces as spaces, every tab routed by `floorpWorkspaceId`; false when it keeps none
    private static func floorp(
        _ folder: URL, prefs: String, _ windows: [[String: Any]], _ namespace: String, _ layout: inout Layout,
        _ names: inout [String: String]
    ) -> Bool {
        var workspaces: [(id: String, raw: [String: Any])] = []
        var fallback: String?
        let store = pref("floorp.workspaces.v4.store", in: prefs).flatMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
        if let store {
            if let entries = store["data"] as? [[Any]] {
                workspaces = entries.compactMap { pair in
                    guard pair.count == 2, let id = pair[0] as? String, let raw = pair[1] as? [String: Any] else { return nil }
                    return (bare(id), raw)
                }
            } else if let record = store["data"] as? [String: [String: Any]] {
                workspaces = record.map { (bare($0.key), $0.value) }.sorted { $0.id < $1.id }
            }
            let rank = Dictionary(
                ((store["order"] as? [String]) ?? []).map(bare).enumerated().map { ($1, $0) }, uniquingKeysWith: min)
            workspaces = workspaces.enumerated().sorted {
                (rank[$0.element.id] ?? .max, $0.offset) < (rank[$1.element.id] ?? .max, $1.offset)
            }.map(\.element)
            fallback = (store["defaultID"] as? String).map(bare)
        } else if let data = try? Data(contentsOf: folder.appending(path: "Workspaces/Workspaces.json")),
            let file = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let byWindow = file["windows"] as? [String: [String: Any]]
        {
            // JSONSerialization drops key order; the file's own order is where each key first appears
            let source = String(decoding: data, as: UTF8.self)
            func ordered(_ keys: Dictionary<String, some Any>.Keys) -> [String] {
                keys.map { ($0, source.range(of: "\"\($0)\"")?.lowerBound ?? source.endIndex) }.sorted { $0.1 < $1.1 }
                    .map(\.0)
            }
            for window in ordered(byWindow.keys).compactMap({ byWindow[$0] }) {
                for key in ordered(window.keys) {
                    guard let raw = window[key] as? [String: Any], raw["name"] is String else { continue }
                    let id = bare(raw["id"] as? String ?? key)
                    guard !workspaces.contains(where: { $0.id == id }) else { continue }
                    workspaces.append((id, raw))
                    if fallback == nil, flag(raw["defaultWorkspace"]) { fallback = id }
                }
            }
        }
        guard let first = workspaces.first?.id else { return false }
        let ids = Set(workspaces.map(\.id))
        let home = fallback.flatMap { ids.contains($0) ? $0 : nil } ?? first
        let routed = windowSpaces(windows) { tab in
            (tab["floorpWorkspaceId"] as? String).map(bare).flatMap { ids.contains($0) ? $0 : nil } ?? home
        }
        for (id, raw) in workspaces {
            let n = raw["userContextId"] as? Int ?? 0
            names[id] = text(raw["name"]) ?? "Floorp"
            layout.spaces[layout.containers[n] == nil ? 0 : n, default: []].append(
                ImportedSpace(
                    id: Importers.stableID(namespace + "floorp/" + id), name: names[id] ?? "Floorp",
                    icon: floorpIcon(raw["icon"] as? String), pinned: routed[id]?.pinned ?? [],
                    today: routed[id]?.today ?? []))
        }
        return true
    }

    /// `workspaces/archive/*.json`, one snapshot of an archived workspace each
    private static func floorpArchive(_ folder: URL) -> [ImportedArchive] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder.appending(path: "workspaces/archive"), includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            .flatMap { file -> [ImportedArchive] in
                guard let data = try? Data(contentsOf: file),
                    let snapshot = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["snapshot"]
                        as? [String: Any]
                else { return [] }
                let space = text((snapshot["workspace"] as? [String: Any])?["name"]) ?? "Floorp"
                let captured = date(snapshot["capturedAt"]) ?? ChromiumData.modified(file) ?? Date()
                return (snapshot["tabs"] as? [[String: Any]] ?? []).compactMap { tab in
                    let current = (tab["state"] as? [String: Any]).flatMap(page)
                    guard let url = text(tab["url"]) ?? current?.url else { return nil }
                    return ImportedArchive(
                        url: url, title: text(tab["title"]) ?? current?.title ?? "", archivedAt: captured,
                        spaceName: space)
                }
            }
    }

    /// Floorp writes a workspace id with braces in some places and without in others
    private static func bare(_ id: String) -> String { id.trimmingCharacters(in: CharacterSet(charactersIn: "{}")) }

    /// `floorp-icon:v1:<slug>` or a bare slug; Floorp draws anything else as a fingerprint
    private static func floorpIcon(_ raw: String?) -> String? {
        let slug = raw.map { $0.hasPrefix("floorp-icon:v1:") ? String($0.dropFirst(15)) : $0 } ?? ""
        return floorpSymbols[slug] ?? floorpSymbols["fingerprint"]
    }

    // MARK: - Files

    /// the newer of the clean file and the recovery file
    private static func session(_ folder: URL) -> (json: [String: Any], date: Date)? {
        ["sessionstore.jsonlz4", "sessionstore-backups/recovery.jsonlz4"]
            .compactMap { name -> (URL, Date)? in
                let file = folder.appending(path: name)
                return ChromiumData.modified(file).map { (file, $0) }
            }
            .sorted { $0.1 > $1.1 }
            .lazy.compactMap { file, date in lz4(file).map { ($0, date) } }.first
    }

    private static func lz4(_ file: URL) -> [String: Any]? {
        (try? Data(contentsOf: file)).flatMap(SQLiteCopy.mozLz4).flatMap {
            (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any]
        }
    }

    /// `containers.json`'s public identities; the others are Firefox's own
    private static func containers(_ folder: URL) -> [Int: Container] {
        guard let data = try? Data(contentsOf: folder.appending(path: "containers.json")),
            let identities = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["identities"]
                as? [[String: Any]]
        else { return [:] }
        var out: [Int: Container] = [:]
        for identity in identities where flag(identity["public"]) {
            guard let n = identity["userContextId"] as? Int, n > 0 else { continue }
            let label = ((identity["l10nId"] ?? identity["l10nID"]) as? String ?? "").lowercased()
            let name =
                text(identity["name"]) ?? ["Personal", "Work", "Banking", "Shopping"].first {
                    label.contains($0.lowercased())
                } ?? "Container \(n)"
            out[n] = Container(name: name, icon: (identity["icon"] as? String).flatMap { floorpSymbols[$0] })
        }
        return out
    }

    /// a `user_pref` value from prefs.js: a string literal unescaped, anything else as written
    private static func pref(_ name: String, in prefs: String) -> String? {
        guard let start = prefs.range(of: "user_pref(\"\(name)\", ")?.upperBound else { return nil }
        let rest = prefs[start...]
        guard rest.first == "\"" else { return rest.prefix { $0 != ")" }.trimmingCharacters(in: .whitespaces) }
        var scalars = rest.unicodeScalars.dropFirst().makeIterator()
        func hex(_ digits: Int) -> UInt32? {
            var value: UInt32 = 0
            for _ in 0..<digits {
                guard let scalar = scalars.next(), let digit = UInt32(String(scalar), radix: 16) else { return nil }
                value = value << 4 | digit
            }
            return value
        }
        var out = String.UnicodeScalarView()
        while let scalar = scalars.next() {
            switch scalar {
            case "\"": return String(out)
            case "\\":
                guard let escaped = scalars.next() else { return nil }
                switch escaped {
                case "n": out.append("\n")
                case "r": out.append("\r")
                case "t": out.append("\t")
                case "x", "u":
                    guard var code = hex(escaped == "x" ? 2 : 4) else { return nil }
                    // a character past U+FFFF is a UTF-16 surrogate pair, two escapes long
                    if (0xD800..<0xDC00).contains(code), scalars.next() == "\\", scalars.next() == "u", let low = hex(4),
                        (0xDC00..<0xE000).contains(low)
                    {
                        code = 0x10000 + (code - 0xD800) << 10 + (low - 0xDC00)
                    }
                    out.append(Unicode.Scalar(code) ?? "\u{FFFD}")
                default: out.append(escaped)
                }
            default: out.append(scalar)
            }
        }
        return nil
    }

    // MARK: - Values

    /// the page a session tab shows: `entries[index - 1]`, since `index` counts from 1
    private static func page(_ tab: [String: Any]) -> (url: String, title: String?)? {
        guard let entries = tab["entries"] as? [[String: Any]], !entries.isEmpty else { return nil }
        let entry = entries[min(max(tab["index"] as? Int ?? entries.count, 1), entries.count) - 1]
        return text(entry["url"]).map { ($0, text(entry["title"])) }
    }

    /// a session tab at its current page, with a pin's home and Zen's rename; nil without a page
    private static func tab(_ raw: [String: Any], pinned: Bool = false) -> ImportedTab? {
        let current = page(raw)
        let initial = (raw["_zenPinnedInitialState"] as? [String: Any])?["entry"] as? [String: Any]
        let home = pinned ? text(initial?["url"]) : nil
        guard let url = current?.url ?? home else { return nil }
        return ImportedTab(
            url: url, title: current?.title, name: text(raw["zenStaticLabel"]), home: home == url ? nil : home)
    }

    /// each key's members gathered at its first member's place; keyless elements stand alone
    private static func gather(
        _ tabs: [[String: Any]], by key: ([String: Any]) -> String?
    ) -> [(key: String?, members: [[String: Any]])] {
        var out: [(key: String?, members: [[String: Any]])] = []
        var at: [String: Int] = [:]
        for tab in tabs {
            guard let key = key(tab) else {
                out.append((nil, [tab]))
                continue
            }
            if let i = at[key] {
                out[i].members.append(tab)
            } else {
                at[key] = out.count
                out.append((key, [tab]))
            }
        }
        return out
    }

    /// the objects of a JSON array by a string field, first one winning
    private static func keyed(_ array: Any?, by field: String) -> [String: [String: Any]] {
        Dictionary(
            (array as? [[String: Any]] ?? []).compactMap { item in (item[field] as? String).map { ($0, item) } },
            uniquingKeysWith: { first, _ in first })
    }

    /// `#rgb`, `#rrggbb`, `#rrggbbaa`, `rgb()` or `rgba()`, as sRGB
    private static func color(_ css: String?) -> RGBA? {
        guard let css = css?.trimmingCharacters(in: .whitespaces).lowercased() else { return nil }
        if css.hasPrefix("#") {
            var hex = String(css.dropFirst())
            if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
            guard hex.count == 6 || hex.count == 8, let value = UInt64(hex, radix: 16) else { return nil }
            let rgba = hex.count == 8 ? value : value << 8 | 0xFF
            return RGBA(
                Double(rgba >> 24 & 0xFF) / 255, Double(rgba >> 16 & 0xFF) / 255, Double(rgba >> 8 & 0xFF) / 255,
                Double(rgba & 0xFF) / 255)
        }
        guard css.hasPrefix("rgb"), let open = css.firstIndex(of: "("), let close = css.lastIndex(of: ")") else {
            return nil
        }
        let parts = css[css.index(after: open)..<close].split { ",/ ".contains($0) }.compactMap { Double($0) }
        guard parts.count >= 3 else { return nil }
        return RGBA(parts[0] / 255, parts[1] / 255, parts[2] / 255, parts.count > 3 ? parts[3] : 1)
    }

    /// true for JSON `true` and for the string "true"
    private static func flag(_ value: Any?) -> Bool { value as? Bool == true || value as? String == "true" }

    /// a non-empty string
    private static func text(_ value: Any?) -> String? { (value as? String).flatMap { $0.isEmpty ? nil : $0 } }

    /// milliseconds since 1970
    private static func date(_ ms: Any?) -> Date? { (ms as? Double).map { Date(timeIntervalSince1970: $0 / 1000) } }

    // MARK: - Icons

    /// Zen's selectable space icons
    private static let zenSymbols = [
        "airplane": "airplane", "american-football": "football.fill", "baseball": "baseball.fill",
        "basket": "basket.fill", "bed": "bed.double.fill", "bell": "bell.fill", "book": "book.fill",
        "bookmark": "bookmark.fill", "briefcase": "briefcase.fill", "brush": "paintbrush.fill", "bug": "ladybug.fill",
        "build": "hammer.fill", "cafe": "cup.and.saucer.fill", "call": "flipphone", "card": "creditcard.fill",
        "chat": "bubble.left.fill", "checkbox": "checkmark.square.fill", "circle": "circle.fill", "cloud": "cloud.fill",
        "code": "chevron.left.forwardslash.chevron.right", "coins": "dollarsign.circle.fill",
        "construct": "wrench.and.screwdriver.fill", "cutlery": "fork.knife", "egg": "frying.pan.fill",
        "extension-puzzle": "puzzlepiece.extension.fill", "eye": "eye.fill",
        "fast-food": "takeoutbag.and.cup.and.straw.fill", "fish": "fish.fill", "flag": "flag.fill",
        "flame": "flame.fill", "flask": "flask.fill", "folder": "folder.fill", "game-controller": "gamecontroller.fill",
        "globe-1": "globe.europe.africa.fill", "globe": "globe", "grid-2x2": "square.grid.2x2.fill",
        "grid-3x3": "square.grid.3x3.fill", "heart": "heart.fill", "ice-cream": "birthday.cake.fill",
        "image": "photo.fill", "inbox": "tray.fill", "key": "key.fill", "layers": "square.3.layers.3d",
        "leaf": "leaf.fill", "lightning": "bolt.fill", "location": "location.fill", "lock-closed": "lock.fill",
        "logo-github": "chevron.left.forwardslash.chevron.right", "logo-rss": "dot.radiowaves.up.forward",
        "logo-usd": "dollarsign", "mail": "envelope.fill", "map": "map.fill", "megaphone": "megaphone.fill",
        "moon": "moon.fill", "music": "music.note", "navigate": "location.north.fill", "nuclear": "atom",
        "page": "doc.fill", "palette": "paintpalette.fill", "paw": "pawprint.fill", "people": "person.2.fill",
        "pizza": "fork.knife", "planet": "globe.americas.fill", "present": "gift.fill", "rocket": "paperplane.fill",
        "school": "graduationcap.fill", "shapes": "square.on.circle.fill", "shirt": "tshirt.fill",
        "skull": "exclamationmark.octagon.fill", "square": "square.fill", "squares": "square.on.square.fill",
        "star-1": "star.fill", "star": "star.fill", "stats-chart": "chart.bar.fill", "sun": "sun.max.fill",
        "tada": "party.popper.fill", "terminal": "terminal.fill", "ticket": "ticket.fill", "time": "clock.fill",
        "trash": "trash.fill", "triangle": "triangle.fill", "video": "video.fill", "volume-high": "speaker.wave.3.fill",
        "wallet": "wallet.pass.fill", "warning": "exclamationmark.triangle.fill", "water": "drop.fill",
        "weight": "scalemass.fill",
    ]

    /// Floorp's workspace icons, which include every container icon
    private static let floorpSymbols = [
        "article": "doc.text.fill", "book": "book.fill", "briefcase": "briefcase.fill", "cart": "cart.fill",
        "chat": "bubble.left.fill", "chill": "sun.horizon.fill", "circle": "circle.fill",
        "code": "chevron.left.forwardslash.chevron.right", "compass": "safari.fill", "dollar": "dollarsign",
        "fence": "square.split.2x2.fill", "fingerprint": "touchid", "food": "fork.knife", "fruit": "carrot.fill",
        "game": "gamecontroller.fill", "gear": "gearshape.fill", "gift": "gift.fill", "key": "key.fill",
        "lightning": "bolt.fill", "network": "network", "notes": "note.text", "paint": "paintbrush.fill",
        "photo": "photo.fill", "pin": "pin.fill", "pet": "pawprint.fill", "question": "questionmark.circle.fill",
        "smartphone": "candybarphone", "star": "star.fill", "tree": "tree.fill", "vacation": "beach.umbrella.fill",
        "love": "heart.fill", "moon": "moon.fill", "music": "music.note", "user": "person.fill",
    ]
}
