// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import Foundation
import SQLite3

/// Nook's spaces, pins, favourites and archive from its `Tabs` JSON, history from
/// its SwiftData store, and cookies from WebKit. A profile is the spaces sharing
/// one data store. JSON dates are seconds since 2001 and ids uppercase UUIDs.
nonisolated enum NookImport {
    /// newest first
    private static let bundleIDs = ["com.gstudios.nook", "com.baingurley.nook", "io.browsewithnook.nook"]
    /// icons Nook draws as a plain dot
    private static let plainIcons: Set<String> = ["", "square.grid.2x2", "house", "person.fill"]

    static func detect(home: URL) -> [ImportedBrowser] {
        let support = home.appending(path: "Library/Application Support")
        guard
            let bundleID = bundleIDs.first(where: {
                FileManager.default.fileExists(atPath: support.appending(path: "\($0)/Tabs/structure.json").path)
            })
        else { return [] }
        let root = support.appending(path: bundleID)
        let tabs = root.appending(path: "Tabs")
        let structure = json(tabs.appending(path: "structure.json")) ?? [:]
        let device = json(tabs.appending(path: "device.json")) ?? [:]
        let state = device["state"] as? [String: Any] ?? [:]

        // structure.json overwrites device.json, so a synced tombstone hides a device copy
        var raws: [String: [String: Any]] = [:]
        for raw in (device["items"] as? [[String: Any]] ?? []) + (structure["items"] as? [[String: Any]] ?? []) {
            if let id = (raw["id"] as? String)?.uppercased() { raws[id] = raw }
        }
        let pool = raws.compactMapValues(Item.init)
        let children = Dictionary(grouping: pool.values) { $0.parent }
            .mapValues { $0.sorted { ($0.order, $0.id) < ($1.order, $1.id) } }
        let openPages = keyed(state["openPages"])
        let openFolders = Set((state["openFolders"] as? [String] ?? []).map { $0.uppercased() })

        func space(of id: String) -> String? {
            var item = pool[id]
            for _ in 0..<64 {
                guard let current = item else { return nil }
                switch current.section {
                case "pinned", "tabs": return current.ref
                case "folder": item = pool[current.ref]
                default: return nil
                }
            }
            return nil
        }
        // a window's split pairs two tabs of one space; the right one moves next to the left
        var partner: [String: String] = [:]
        for window in state["windows"] as? [[String: Any]] ?? [] {
            let split = window["split"] as? [String: Any]
            guard let left = (split?["leftItemID"] as? String)?.uppercased(),
                let right = (split?["rightItemID"] as? String)?.uppercased(), left != right,
                pool[left]?.url != nil, pool[right]?.url != nil, let home = space(of: left), space(of: right) == home,
                !partner.keys.contains(where: { $0 == left || $0 == right }), !partner.values.contains(left),
                !partner.values.contains(right)
            else { continue }
            partner[left] = right
        }
        let moved = Set(partner.values)

        func tab(_ item: Item) -> ImportedTab {
            let page = openPages[item.id] as? [String: Any]
            let home = item.url ?? ""
            let url = page?["url"] as? String ?? home
            return ImportedTab(
                url: url, title: page?["title"] as? String ?? item.pageTitle, name: item.customTitle,
                home: home == url ? nil : home)
        }
        // a tab's own children (a trail) follow it, flattened
        func tree(_ parent: String) -> [ImportedItem] {
            (children[parent] ?? []).flatMap { item -> [ImportedItem] in
                let nested = tree("folder:" + item.id)
                guard item.url != nil else {
                    let name = item.customTitle ?? "Folder"
                    return [.folder(name: name, expanded: openFolders.contains(item.id), nested)]
                }
                if moved.contains(item.id) { return nested }
                if let right = partner[item.id].flatMap({ pool[$0] }) {
                    return [.split([tab(item), tab(right)], .columns)] + nested
                }
                return [.tab(tab(item))] + nested
            }
        }

        let spaces = (structure["spaces"] as? [[String: Any]] ?? [])
            .filter { $0["deletedAt"] == nil && !(($0["icon"] as? String)?.hasPrefix("nook.agent:") ?? false) }
            .compactMap { raw in (raw["id"] as? String).map { (id: $0.uppercased(), raw: raw) } }
            .sorted { (order($0.raw["order"]), $0.id) < (order($1.raw["order"]), $1.id) }
        // format 2 shares a data store across spaces; format 1 names a profile row
        func profileKey(_ raw: [String: Any]) -> String? {
            (raw["dataStoreID"] as? String ?? raw["profileID"] as? String)?.uppercased()
        }
        var groups: [(key: String, spaces: [(id: String, raw: [String: Any])])] = []
        for space in spaces {
            let key = profileKey(space.raw) ?? space.id
            if let index = groups.firstIndex(where: { $0.key == key }) {
                groups[index].spaces.append(space)
            } else {
                groups.append((key, [space]))
            }
        }
        var rows: [String: [String: Any]] = [:]
        for row in structure["profiles"] as? [[String: Any]] ?? [] where row["deletedAt"] == nil {
            if let id = (row["id"] as? String)?.uppercased() { rows[id] = row }
        }
        let names = Dictionary(spaces.map { ($0.id, $0.raw["name"] as? String ?? "Space") }) { first, _ in first }
        let entries = json(tabs.appending(path: "archive.json"))?["entries"] as? [[String: Any]] ?? []
        let store = root.appending(path: "default.store")
        let hasStore = FileManager.default.fileExists(atPath: store.path)

        let profiles = groups.enumerated().map { index, group -> ImportedProfile in
            let key = group.key
            let isDefault = index == 0
            let row = rows[key]
            let first = group.spaces[0].raw
            var favourites: [ImportedTab] = []
            for owner in [key] + group.spaces.map(\.id) {
                for tab in flatten(tree("favorites:" + owner)) where !favourites.contains(where: { same($0, tab) }) {
                    favourites.append(tab)
                }
            }
            let ids = Set(group.spaces.map(\.id))
            let archive = entries.flatMap { entry -> [ImportedArchive] in
                guard let space = (entry["spaceID"] as? String)?.uppercased(), ids.contains(space),
                    let at = date(entry["archivedAt"])
                else { return [] }
                let title = entry["title"] as? String
                let items = (entry["items"] as? [[String: Any]] ?? []).compactMap(Item.init).filter { $0.url != nil }
                if items.isEmpty, let url = entry["url"] as? String {
                    return [ImportedArchive(url: url, title: title ?? url, archivedAt: at, spaceName: names[space] ?? "")]
                }
                return items.map { item in
                    let url = item.url ?? ""
                    return ImportedArchive(
                        url: url, title: item.pageTitle ?? title ?? url, name: item.customTitle, archivedAt: at,
                        spaceName: names[space] ?? "")
                }
            }
            let owner = UUID(uuidString: key).flatMap { hasStore ? $0 : nil }
            let jar = home.appending(
                path: "Library/WebKit/\(bundleID)/WebsiteDataStore/\(key.lowercased())/Cookies/Cookies.binarycookies")
            let session = root.appending(path: "SessionCookies/\(key).plist")
            let jars = [(jar, CookieSource.binary(jar)), (session, CookieSource.cookiePlist(session))]
                .filter { FileManager.default.fileExists(atPath: $0.0.path) }

            return ImportedProfile(
                id: Importers.stableID("\(bundleID)/profile/\(key)"), key: key,
                name: group.spaces.lazy.compactMap({ $0.raw["profileName"] as? String }).first ?? row?["name"] as? String
                    ?? first["name"] as? String ?? "Nook",
                icon: (row?["icon"] as? String).flatMap { plainIcons.contains($0) ? nil : $0 }, isDefault: isDefault,
                folder: root,
                spaces: group.spaces.map { space in
                    let theme = space.raw["theme"] as? [String: Any]
                    return ImportedSpace(
                        id: Importers.stableID("\(bundleID)/\(key)/space/\(space.id)"), name: names[space.id] ?? "Space",
                        icon: (space.raw["icon"] as? String).flatMap { plainIcons.contains($0) ? nil : $0 },
                        colors: colors(theme, accent: space.raw["accentHex"] as? String),
                        grain: theme?["grain"] as? Double ?? 0, pinned: tree("pinned:" + space.id),
                        today: tree("tabs:" + space.id))
                },
                favourites: favourites, archive: archive,
                history: owner.map { .nook(store, profile: $0, includeUnowned: isDefault) },
                cookies: jars.map(\.1),
                historyCount: owner.map {
                    SQLiteCopy.count(store, "SELECT count(DISTINCT ZURL) FROM ZHISTORYENTITY WHERE \(ownedBy($0, includeUnowned: isDefault));")
                } ?? 0,
                cookieCount: jars.reduce(0) { $0 + BinaryCookies.count($1.0) })
        }
        guard !profiles.isEmpty else { return [] }
        return [ImportedBrowser(name: "Nook", bundleID: bundleID, family: .nook, root: root, profiles: profiles)]
    }

    /// `ZHISTORYENTITY` rows of `profile`, one per URL, newest first
    static func history(_ store: URL, profile: UUID, includeUnowned: Bool) -> [ImportedVisit] {
        SQLiteCopy.withDatabase(at: store) { db in
            let columns = SQLiteCopy.columns(db, "ZHISTORYENTITY")
            guard columns.contains("ZURL"), columns.contains("ZPROFILEID") else { return [] }
            let times = ["ZLASTVISITED", "ZVISITDATE"].filter(columns.contains).map { "coalesce(\($0), 0)" }
            let time = times.count == 2 ? "max(\(times[0]), \(times[1]))" : times.first ?? "0"
            let title = columns.contains("ZTITLE") ? "ZTITLE" : "NULL"
            let count = columns.contains("ZVISITCOUNT") ? "ZVISITCOUNT" : "0"
            var out: [ImportedVisit] = []
            var rows: [Int] = []
            var index: [String: Int] = [:]
            let sql = """
                SELECT ZURL, \(title), \(time), \(count) FROM ZHISTORYENTITY
                WHERE \(ownedBy(profile, includeUnowned: includeUnowned)) ORDER BY 3 DESC;
                """
            SQLiteCopy.rows(db, sql) { row in
                guard let url = SQLiteCopy.text(row, 0) else { return }
                let recorded = Int(sqlite3_column_int64(row, 3))
                if let at = index[url] {
                    rows[at] += 1
                    out[at].visitCount = max(out[at].visitCount, recorded)
                } else if out.count < Importers.historyLimit {
                    index[url] = out.count
                    rows.append(1)
                    out.append(
                        ImportedVisit(
                            url: url, title: SQLiteCopy.text(row, 1) ?? "",
                            lastVisited: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(row, 2)),
                            visitCount: recorded))
                }
            }
            for at in out.indices { out[at].visitCount = max(out[at].visitCount, rows[at]) }
            return out
        } ?? []
    }

    /// `ZPROFILEID` is the store UUID as a 16-byte blob in RFC order
    private static func ownedBy(_ profile: UUID, includeUnowned: Bool) -> String {
        let hex = profile.uuidString.replacingOccurrences(of: "-", with: "")
        return "(ZPROFILEID = X'\(hex)'" + (includeUnowned ? " OR ZPROFILEID IS NULL)" : ")")
    }

    private struct Item {
        var id: String
        /// `pinned`, `tabs` or `favorites` with a space or profile id, or `folder` with an item id
        var section: String
        var ref: String
        var order: String
        /// nil for a folder
        var url: String?
        var pageTitle: String?
        var customTitle: String?

        var parent: String { section + ":" + ref }

        /// nil for a tombstone or a kind this reader doesn't know; a live folder reads as a folder
        init?(_ raw: [String: Any]) {
            guard raw["deletedAt"] == nil, let id = raw["id"] as? String, let parent = (raw["parent"] as? [String: Any])?.first,
                let ref = ((parent.value as? [String: Any])?.values.first as? String), let kind = raw["kind"] as? [String: Any]
            else { return nil }
            if let tab = kind["tab"] as? [String: Any] {
                url = tab["url"] as? String ?? ""
                pageTitle = tab["pageTitle"] as? String
            } else if !kind.keys.contains(where: { $0.lowercased().hasSuffix("folder") }) {
                return nil
            }
            self.id = id.uppercased()
            section = parent.key
            self.ref = ref.uppercased()
            order = NookImport.order(raw["order"])
            customTitle = raw["customTitle"] as? String
        }
    }

    /// an order key, compared as a string: plain, or wrapped in a one-field object
    private static func order(_ raw: Any?) -> String {
        raw as? String ?? (raw as? [String: Any])?.values.first as? String ?? ""
    }

    /// a `[UUID: X]` as JSONEncoder writes it, a flat [key, value, …] array, or as an object
    private static func keyed(_ raw: Any?) -> [String: Any] {
        if let object = raw as? [String: Any] {
            return Dictionary(object.map { ($0.key.uppercased(), $0.value) }) { first, _ in first }
        }
        guard let flat = raw as? [Any] else { return [:] }
        var out: [String: Any] = [:]
        for at in stride(from: 0, to: flat.count - 1, by: 2) {
            if let key = flat[at] as? String { out[key.uppercased()] = flat[at + 1] }
        }
        return out
    }

    private static func date(_ raw: Any?) -> Date? {
        (raw as? Double).map { Date(timeIntervalSinceReferenceDate: $0) }
    }

    private static func json(_ file: URL) -> [String: Any]? {
        (try? Data(contentsOf: file)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    private static func flatten(_ items: [ImportedItem]) -> [ImportedTab] {
        items.flatMap { item -> [ImportedTab] in
            switch item {
            case .tab(let tab): [tab]
            case .folder(_, _, let children): flatten(children)
            case .split(let tabs, _): tabs
            }
        }
    }

    private static func same(_ a: ImportedTab, _ b: ImportedTab) -> Bool { (a.home ?? a.url) == (b.home ?? b.url) }

    /// The theme's points as the colours the user picked, else the accent. A point's
    /// angle from the canvas centre is the OKLCH hue and its distance the strength.
    private static func colors(_ theme: [String: Any]?, accent: String?) -> [RGBA] {
        let points = theme?["points"] as? [[String: Any]] ?? []
        guard !points.isEmpty else { return accent.flatMap(RGBA.init(hex:)).map { [$0] } ?? [] }
        return points.prefix(3).compactMap { point in
            guard let x = point["x"] as? Double, let y = point["y"] as? Double else { return nil }
            let strength = min(1, hypot(x - 0.5, y - 0.5) / 0.5)
            return oklch(0.99 - 0.27 * strength, 0.17 * strength, atan2(0.5 - y, x - 0.5))
        }
    }

    /// OKLCH, hue in radians, to clamped sRGB through Ottosson's OKLab matrices
    private static func oklch(_ lightness: Double, _ chroma: Double, _ hue: Double) -> RGBA {
        let a = chroma * cos(hue)
        let b = chroma * sin(hue)
        let l = pow(lightness + 0.3963377774 * a + 0.2158037573 * b, 3)
        let m = pow(lightness - 0.1055613458 * a - 0.0638541728 * b, 3)
        let s = pow(lightness - 0.0894841775 * a - 1.2914855480 * b, 3)
        let rgb = [
            4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
            -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
            -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s,
        ].map { min(1, max(0, $0 <= 0.0031308 ? 12.92 * $0 : 1.055 * pow($0, 1 / 2.4) - 0.055)) }
        return RGBA(rgb[0], rgb[1], rgb[2])
    }
}
