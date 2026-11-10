// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import Foundation
import SQLite3

/// Orion's profiles, saved windows as spaces, bookmarks, history and cookies.
/// A profile's files live in `Defaults` or its identifier's folder.
nonisolated enum OrionImport {
    private static let bundleID = "com.kagi.kagimacOS"
    /// the profile colour picker's swatches, by index
    private static let palette = ["98989D", "CC66FF", "F7509E", "FF5045", "FFA915", "FFE018", "3EFD56", "A2A2A7"]

    static func detect(home: URL) -> [ImportedBrowser] {
        let files = FileManager.default
        let root = home.appending(path: "Library/Application Support/Orion")
        guard files.fileExists(atPath: root.appending(path: "Defaults").path) else { return [] }
        let list = plist(root.appending(path: "profiles")) as? [String: Any]
        let defaults = list?["defaults"] as? [String: Any]
        var entries = [(key: "Defaults", name: defaults?["name"] as? String ?? "Orion", color: defaults?["color"])]
        for raw in list?["profiles"] as? [[String: Any]] ?? [] {
            guard let key = raw["identifier"] as? String, files.fileExists(atPath: root.appending(path: key).path) else { continue }
            entries.append((key, raw["name"] as? String ?? "Profile", raw["color"]))
        }
        let jar = home.appending(path: "Library/HTTPStorages/\(bundleID).binarycookies")
        let hasJar = files.fileExists(atPath: jar.path)

        let profiles = entries.map { entry in
            let folder = root.appending(path: entry.key)
            let colors = (entry.color as? Int).flatMap { palette.indices.contains($0) ? RGBA(hex: palette[$0]) : nil }
            let saved = [".local_named_windows.plist", "named_windows.plist"].map { folder.appending(path: $0) }
                .first { files.fileExists(atPath: $0.path) }
            let history = folder.appending(path: "history")
            let hasHistory = files.fileExists(atPath: history.path)
            let isDefault = entry.key == "Defaults"
            return ImportedProfile(
                id: Importers.stableID("\(bundleID)/profile/\(entry.key)"), key: entry.key, name: entry.name,
                isDefault: isDefault, folder: folder,
                spaces: saved.map { spaces($0, profile: entry.key, colors: colors.map { [$0] } ?? []) } ?? [],
                bookmarks: bookmarks(folder.appending(path: "favourites.plist")),
                history: hasHistory ? .orion(history) : nil, cookies: isDefault && hasJar ? [.binary(jar)] : [],
                logins: .csvOnly(hint: "In Orion, open Settings > Passwords and choose Export Passwords."),
                historyCount: hasHistory ? SQLiteCopy.count(history, "SELECT count(*) FROM history_items;") : 0,
                cookieCount: isDefault && hasJar ? BinaryCookies.count(jar) : 0)
        }
        return [ImportedBrowser(name: "Orion", bundleID: bundleID, family: .orion, root: root, profiles: profiles)]
    }

    /// one visit per row, newest first; `LAST_VISIT_TIME` is UTC text or seconds since 2001, per row
    static func history(_ file: URL) -> [ImportedVisit] {
        SQLiteCopy.withDatabase(at: file) { db in
            let columns = Set(SQLiteCopy.columns(db, "history_items").map { $0.lowercased() })
            guard columns.contains("url"), columns.contains("last_visit_time") else { return [] }
            func column(_ name: String, else fallback: String) -> String { columns.contains(name) ? name : fallback }
            let sql = """
                SELECT url, \(column("title", else: "NULL")), t, \(column("visit_count", else: "1")), \(column("typed_count", else: "0"))
                FROM (SELECT *, CASE typeof(last_visit_time) WHEN 'text' THEN strftime('%s', last_visit_time) - 978307200
                ELSE last_visit_time END AS t FROM history_items)
                WHERE t IS NOT NULL ORDER BY t DESC LIMIT \(Importers.historyLimit);
                """
            var out: [ImportedVisit] = []
            SQLiteCopy.rows(db, sql) { row in
                guard let url = SQLiteCopy.text(row, 0) else { return }
                out.append(
                    ImportedVisit(
                        url: url, title: SQLiteCopy.text(row, 1) ?? "",
                        lastVisited: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(row, 2)),
                        visitCount: Int(sqlite3_column_int64(row, 3)), typedCount: Int(sqlite3_column_int64(row, 4))))
            }
            return out
        } ?? []
    }

    /// each saved window as a space; none when no tab's URL can be read
    private static func spaces(_ file: URL, profile: String, colors: [RGBA]) -> [ImportedSpace] {
        var tabCount = 0
        var resolved = 0
        let spaces = windows(plist(file), 0).map { window -> ImportedSpace in
            let info = window["windowInfo"] as? [String: Any] ?? [:]
            func text(_ key: String) -> String? { (info[key] ?? window[key]).flatMap(string) }
            var list = window["tabsInfo"] ?? window["_tabsInfo"] ?? info["tabsInfo"] ?? info["_tabsInfo"]
            if let wrapped = (list as? [String: Any])?["wrappedValue"] { list = wrapped }
            let tabs = list as? [[String: Any]] ?? []
            tabCount += tabs.count

            // a tab whose parent is another tab here follows that parent
            let ids = Set(tabs.compactMap { $0["iCloudTabIdentifier"].flatMap(string) })
            let children = Dictionary(grouping: tabs) { tab in
                tab["parentICloudTabIdentifier"].flatMap(string).flatMap { ids.contains($0) ? $0 : nil } ?? ""
            }
            var visited: Set<String> = []
            var pinned: [ImportedItem] = []
            var today: [ImportedItem] = []
            func add(_ raw: [String: Any], pinnedSection: Bool?) {
                let id = raw["iCloudTabIdentifier"].flatMap(string)
                if let id, !visited.insert(id).inserted { return }
                let isPinned = pinnedSection ?? (raw["isPinned"] as? Bool == true)
                let page = raw["webPage"] as? [String: Any]
                if let url = link(raw["url"]) ?? link(raw["URL"]) ?? link(page?["url"]) ?? link(raw["pinnedTabURL"]) {
                    resolved += 1
                    let home = isPinned ? link(raw["pinnedTabURL"]) : nil
                    let tab = ImportedTab(
                        url: url, title: raw["title"].flatMap(string) ?? page?["title"].flatMap(string),
                        name: raw["titleOverride"].flatMap(string), home: home == url ? nil : home)
                    if isPinned { pinned.append(.tab(tab)) } else { today.append(.tab(tab)) }
                }
                for child in id.flatMap({ children[$0] }) ?? [] { add(child, pinnedSection: isPinned) }
            }
            for raw in children[""] ?? [] { add(raw, pinnedSection: nil) }

            let name = text("name") ?? text("title") ?? text("titleOverride") ?? "Window"
            let key = text("namedWindowID") ?? text("id") ?? text("identifier") ?? name
            return ImportedSpace(
                id: Importers.stableID("\(bundleID)/\(profile)/space/\(key)"), name: name, icon: emoji(info["icon"] ?? window["icon"]),
                colors: colors, pinned: pinned, today: today)
        }
        guard resolved > 0 || tabCount == 0 else {
            debugLog("Orion import: no tab URL found in \(file.lastPathComponent), spaces skipped")
            return []
        }
        return spaces
    }

    /// the dictionaries holding a window's info or tabs, in key order
    private static func windows(_ value: Any?, _ depth: Int) -> [[String: Any]] {
        guard depth < 8 else { return [] }
        if let window = value as? [String: Any] {
            if window["windowInfo"] != nil || window["tabsInfo"] != nil || window["_tabsInfo"] != nil { return [window] }
            return window.keys.sorted().flatMap { windows(window[$0], depth + 1) }
        }
        return (value as? [Any] ?? []).flatMap { windows($0, depth + 1) }
    }

    /// favourites.plist's `id → {parentId, title, type, index, url}` as a tree;
    /// a lone root folder is unwrapped and loose links gather in "Bookmarks"
    private static func bookmarks(_ file: URL) -> [ImportedItem] {
        let raw = plist(file)
        var nodes: [String: [String: Any]] = [:]
        if let map = raw as? [String: Any] {
            for (key, value) in map { if let node = value as? [String: Any] { nodes[key] = node } }
        } else {
            for node in raw as? [[String: Any]] ?? [] { if let id = node["id"].flatMap(string) { nodes[id] = node } }
        }
        let children = Dictionary(grouping: nodes.keys) { key in
            nodes[key]?["parentId"].flatMap(string).flatMap { nodes[$0] == nil ? nil : $0 } ?? ""
        }
        func tree(_ parent: String, _ depth: Int) -> [ImportedItem] {
            guard depth < 32 else { return [] }
            let sorted = (children[parent] ?? []).sorted { (nodes[$0]?["index"] as? Int ?? 0, $0) < (nodes[$1]?["index"] as? Int ?? 0, $1) }
            return sorted.compactMap { key in
                let node = nodes[key] ?? [:]
                let title = node["title"].flatMap(string)
                switch node["type"].flatMap(string) {
                case "folder": return .folder(name: title ?? "Folder", expanded: false, tree(key, depth + 1))
                case "bookmark": return link(node["url"]).map { .tab(ImportedTab(url: $0, title: title)) }
                default: return nil
                }
            }
        }
        var top = tree("", 0)
        if top.count == 1, case .folder(_, _, let inner) = top[0] { top = inner }
        var folders: [ImportedItem] = []
        var loose: [ImportedItem] = []
        for item in top {
            if case .tab = item { loose.append(item) } else { folders.append(item) }
        }
        return folders + (loose.isEmpty ? [] : [.folder(name: "Bookmarks", expanded: false, loose)])
    }

    /// a URL as a string, or as a Codable or archived URL: `relative` against an optional `base`
    private static func link(_ raw: Any?) -> String? {
        if let text = raw as? String { return text.isEmpty ? nil : text }
        guard let parts = raw as? [String: Any], let relative = parts["relative"] as? String else { return nil }
        guard let base = link(parts["base"]) else { return relative }
        return URL(string: relative, relativeTo: URL(string: base))?.absoluteString ?? relative
    }

    private static func string(_ raw: Any) -> String? {
        (raw as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (raw as? UUID)?.uuidString
    }

    /// an emoji, bare or as a dictionary's string value
    private static func emoji(_ raw: Any?) -> String? {
        if let fields = raw as? [String: Any] { return fields.keys.sorted().lazy.compactMap { emoji(fields[$0]) }.first }
        guard let text = raw as? String, !text.isEmpty, text.count <= 2,
            text.allSatisfy({ $0.unicodeScalars.first.map { $0.properties.isEmoji && $0.value > 0x7F } == true })
        else { return nil }
        return text
    }

    /// a property list, with a keyed archive's object graph resolved to plain values
    private static func plist(_ file: URL) -> Any? {
        guard let data = try? Data(contentsOf: file),
            let top = try? PropertyListSerialization.propertyList(from: data, format: nil)
        else { return nil }
        guard let archive = top as? [String: Any], archive["$archiver"] != nil,
            let objects = archive["$objects"] as? [Any], let roots = archive["$top"] as? [String: Any],
            let root = roots["root"] ?? roots.values.first
        else { return top }
        return resolve(root, objects, 0)
    }

    /// Plain values pass through; a UID is looked up in `objects`, and Foundation's
    /// archived dictionaries, arrays, strings, URLs, dates and UUIDs become plain values.
    /// A UID already on `path` points back up the graph and reads as nil.
    private static func resolve(_ value: Any, _ objects: [Any], _ depth: Int, _ path: Set<Int> = []) -> Any? {
        guard depth < 32 else { return nil }
        func inner(_ value: Any?) -> Any? { value.flatMap { resolve($0, objects, depth + 1, path) } }
        switch value {
        case let text as String: return text == "$null" ? nil : text
        case is NSNumber, is Date, is Data: return value
        case let list as [Any]: return list.compactMap(inner)
        case let fields as [String: Any]:
            if let keys = fields["NS.keys"] as? [Any], let values = fields["NS.objects"] as? [Any] {
                var out: [String: Any] = [:]
                for (key, value) in zip(keys, values) {
                    if let key = inner(key) as? String, let value = inner(value) { out[key] = value }
                }
                return out
            }
            if let values = fields["NS.objects"] as? [Any] { return values.compactMap(inner) }
            if let text = fields["NS.string"] { return inner(text) }
            if let relative = fields["NS.relative"] {
                var url: [String: Any] = [:]
                url["relative"] = inner(relative)
                url["base"] = inner(fields["NS.base"])
                return url
            }
            if let time = fields["NS.time"] as? Double { return Date(timeIntervalSinceReferenceDate: time) }
            if let bytes = fields["NS.uuidbytes"] as? Data, bytes.count == 16 {
                return NSUUID(uuidBytes: [UInt8](bytes)).uuidString
            }
            return fields.filter { $0.key != "$class" }.compactMapValues(inner)
        default:
            // CFKeyedArchiverUID is opaque; its description ends "{value = N}"
            let text = String(describing: value)
            guard text.hasPrefix("<CFKeyedArchiverUID"), let last = text.split(separator: " ").last,
                let index = Int(last.dropLast()), objects.indices.contains(index), !path.contains(index)
            else { return nil }
            return resolve(objects[index], objects, depth + 1, path.union([index]))
        }
    }
}
