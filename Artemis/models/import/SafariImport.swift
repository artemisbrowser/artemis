// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import Foundation
import SQLite3

/// Safari's profiles and tab groups, and its export file. Everything but the
/// export needs Full Disk Access; SafariTabs.db dates are seconds since 2001.
nonisolated enum SafariImport {
    private static let bundleID = "com.apple.Safari"
    private static let passwordsHint = "In the Passwords app, choose File > Export All Passwords to File."
    /// SafariTabs.db folders that are never a tab group
    private static let specials: Set<String> = ["pinned", "privatePinned", "recentlyClosed", "TopScopedBookmarkList"]

    static func detect(home: URL) -> [ImportedBrowser] {
        let files = FileManager.default
        let safari = home.appending(path: "Library/Safari")
        guard files.fileExists(atPath: safari.path) else { return [] }
        var browser = ImportedBrowser(name: "Safari", bundleID: bundleID, family: .safari, root: safari)
        // checked before any container path is touched
        guard SQLiteCopy.isReadable(safari.appending(path: "Bookmarks.plist")) else {
            browser.wall = .fullDiskAccess
            return [browser]
        }
        let container = home.appending(path: "Library/Containers/com.apple.Safari/Data/Library")
        let tree = kids(
            (try? Data(contentsOf: safari.appending(path: "Bookmarks.plist")))
                .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] } ?? [:])
        let tabs = SQLiteCopy.withDatabase(at: container.appending(path: "Safari/SafariTabs.db"), read) ?? Tabs()

        let rows = tabs.rows
        let byID = Dictionary(rows.map { ($0.id, $0) }) { first, _ in first }
        let children = Dictionary(grouping: rows) { $0.parent }
        func resolve(_ ref: String) -> Int? { rows.first { String($0.id) == ref || $0.uuid == ref || $0.server == ref }?.id }
        let defaultRow = rows.first { $0.server == "DefaultProfile" }
        let named = rows.filter {
            $0.parent == 0 && $0.type == 1 && $0.subtype == 2 && $0.special == 0 && $0.server != "DefaultProfile"
                && $0.uuid != nil
        }
        let keys = ["DefaultProfile"] + named.map { $0.uuid ?? "" }
        /// 0 for the default profile, n for the nth named one
        func owner(_ ref: String?) -> Int? {
            guard let id = ref.flatMap(resolve) else { return nil }
            return named.firstIndex { $0.id == id }.map { $0 + 1 } ?? (id == defaultRow?.id ? 0 : nil)
        }
        let privates = Set(tabs.privates.compactMap(resolve))
        var unnamed = Dictionary(tabs.unnamed.compactMap { ref, profile in resolve(ref).map { ($0, profile) } }) { a, _ in a }
        for row in rows where row.attributes["IsUnnamed"] as? Bool == true && unnamed[row.id] == nil { unnamed[row.id] = "" }

        func tab(_ row: Row) -> ImportedTab? {
            guard row.type == 0, let url = row.url, !url.isEmpty else { return nil }
            let home = row.attributes["PinnedAddress"] as? String
            return ImportedTab(
                url: url, title: row.title, home: home == url ? nil : home)
        }
        func bookmarks(_ parent: Int, _ depth: Int) -> [ImportedItem] {
            guard depth < 16 else { return [] }
            return (children[parent] ?? []).compactMap { row in
                if let tab = tab(row) { return .tab(tab) }
                return row.type == 1 ? .folder(name: row.title ?? "Folder", expanded: false, bookmarks(row.id, depth + 1)) : nil
            }
        }
        func contents(_ group: Int) -> (pinned: [ImportedItem], today: [ImportedItem]) {
            var out: (pinned: [ImportedItem], today: [ImportedItem]) = ([], [])
            for row in children[group] ?? [] {
                if row.type == 1, row.title == "TopScopedBookmarkList" {
                    out.pinned.insert(.folder(name: "Favourites", expanded: false, bookmarks(row.id, 0)), at: 0)
                } else if let tab = tab(row) {
                    if row.attributes["IsPinned"] as? Bool == true { out.pinned.append(.tab(tab)) } else { out.today.append(.tab(tab)) }
                }
            }
            return out
        }

        var spaces = Array(repeating: [ImportedSpace](), count: keys.count)
        var loose = Array(repeating: (pinned: [ImportedItem](), today: [ImportedItem]()), count: keys.count)
        var pins = Array(repeating: [ImportedItem](), count: keys.count)
        for row in rows where row.type == 1 && !privates.contains(row.id) {
            if let window = unnamed[row.id] {
                let at = owner(window) ?? owner(String(row.parent)) ?? 0
                let found = contents(row.id)
                loose[at].pinned += found.pinned
                loose[at].today += found.today
            } else if row.title == "pinned" {
                pins[owner(String(row.parent)) ?? 0] += (children[row.id] ?? []).compactMap(tab).map(ImportedItem.tab)
            } else if row.subtype == 0, row.special == 0, !specials.contains(row.title ?? "") {
                let parent = byID[row.parent]
                let at: Int
                if let index = named.firstIndex(where: { $0.id == row.parent }) {
                    at = index + 1
                } else if !row.hidden, row.parent == 0 || row.parent == defaultRow?.id || (parent?.type == 1 && parent?.subtype == 3) {
                    at = 0
                } else {
                    continue
                }
                let found = contents(row.id)
                spaces[at].append(
                    ImportedSpace(
                        id: Importers.stableID("\(bundleID)/\(keys[at])/space/\(row.server ?? String(row.id))"),
                        name: row.title ?? "Tab Group", pinned: found.pinned, today: found.today))
            }
        }
        // the window outside any tab group, with the profile's pinned folder, leads
        for at in keys.indices where !(pins[at].isEmpty && loose[at].pinned.isEmpty && loose[at].today.isEmpty) {
            let space = ImportedSpace(
                id: Importers.stableID("\(bundleID)/\(keys[at])/space/unnamed"), name: "Safari",
                pinned: pins[at] + loose[at].pinned, today: loose[at].today)
            spaces[at].insert(space, at: 0)
        }

        browser.profiles = keys.indices.map { at in
            let row = at == 0 ? defaultRow : named[at - 1]
            let key = keys[at]
            let folder = at == 0 ? safari : container.appending(path: "Safari/Profiles/\(key.uppercased())")
            let history = folder.appending(path: "History.db")
            let hasHistory = files.fileExists(atPath: history.path)
            let jars =
                at == 0
                ? [container.appending(path: "Cookies/Cookies.binarycookies"), home.appending(path: "Library/Cookies/Cookies.binarycookies")]
                : [container.appending(path: "WebKit/WebsiteDataStore/\(key.lowercased())/Cookies/Cookies.binarycookies")]
            let jar = jars.first { files.fileExists(atPath: $0.path) }
            let bar =
                at == 0
                ? tree.first { $0["Title"] as? String == "BookmarksBar" }
                : (row?.attributes["CustomFavoritesFolderServerID"] as? String).flatMap { favouritesFolder(tree, $0, 0) }
            return ImportedProfile(
                id: Importers.stableID("\(bundleID)/profile/\(key)"), key: key,
                name: row?.title.flatMap { $0.isEmpty ? nil : $0 } ?? (at == 0 ? "Personal" : "Profile"),
                icon: row?.attributes["SymbolImageName"] as? String, isDefault: at == 0, folder: folder, spaces: spaces[at],
                favourites: kids(bar ?? [:]).compactMap(leaf), bookmarks: at == 0 ? bookmarkFolders(tree) : [],
                history: hasHistory ? .safari(history) : nil, cookies: jar.map { [.binary($0)] } ?? [],
                logins: .csvOnly(hint: passwordsHint),
                historyCount: hasHistory ? SQLiteCopy.count(history, "SELECT count(*) FROM history_items;") : 0,
                cookieCount: jar.map(BinaryCookies.count) ?? 0)
        }
        return [browser]
    }

    /// one visit per page, newest first; History.db times are seconds since 2001
    static func history(_ file: URL) -> [ImportedVisit] {
        SQLiteCopy.withDatabase(at: file) { db in
            var out: [ImportedVisit] = []
            let sql = """
                SELECT i.url, v.title, max(v.visit_time), i.visit_count FROM history_items i
                JOIN history_visits v ON v.history_item = i.id GROUP BY i.id ORDER BY 3 DESC LIMIT \(Importers.historyLimit);
                """
            SQLiteCopy.rows(db, sql) { row in
                guard let url = SQLiteCopy.text(row, 0) else { return }
                out.append(
                    ImportedVisit(
                        url: url, title: SQLiteCopy.text(row, 1) ?? "",
                        lastVisited: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(row, 2)),
                        visitCount: Int(sqlite3_column_int64(row, 3))))
            }
            return out
        } ?? []
    }

    /// History.json from the export: `time_usec` is microseconds since 1970
    static func exportedHistory(_ json: URL) -> [ImportedVisit] {
        guard let data = try? Data(contentsOf: json),
            let entries = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["history"] as? [[String: Any]]
        else { return [] }
        var visits: [String: ImportedVisit] = [:]
        for entry in entries {
            guard let url = entry["url"] as? String, let micros = entry["time_usec"] as? Double else { continue }
            let visit = ImportedVisit(
                url: url, title: entry["title"] as? String ?? "", lastVisited: Date(timeIntervalSince1970: micros / 1_000_000),
                visitCount: entry["visit_count"] as? Int ?? 1)
            guard var known = visits[url] else {
                visits[url] = visit
                continue
            }
            if visit.lastVisited > known.lastVisited {
                known.lastVisited = visit.lastVisited
                if !visit.title.isEmpty { known.title = visit.title }
            }
            known.visitCount = max(known.visitCount, visit.visitCount)
            visits[url] = known
        }
        let newest = visits.values.sorted { ($0.lastVisited, $1.url) > ($1.lastVisited, $0.url) }
        return Array(newest.prefix(Importers.historyLimit))
    }

    /// where export zips unpack, one folder per build since every build shares the temporary
    /// directory; emptied at launch
    static var exports: URL {
        FileManager.default.temporaryDirectory.appending(path: "\(AppStorageLocation.folderName) Safari Exports")
    }

    /// the Safari 18+ export zip, or a bookmarks HTML file; a zip unpacks into a temporary
    /// `root` the caller deletes, and nil leaves nothing behind
    @concurrent static func readExport(_ file: URL) async -> ImportedBrowser? {
        var root = file.deletingLastPathComponent()
        var found = ["bookmarks.html": file]
        if file.pathExtension.lowercased() == "zip" {
            let destination = exports.appending(path: UUID().uuidString)
            _ = await ZipArchive.extract(file, to: destination)
            root = destination
            found = [:]
            let unpacked = FileManager.default.enumerator(at: destination, includingPropertiesForKeys: nil)?.allObjects
            for url in (unpacked as? [URL] ?? []).sorted(by: { $0.path < $1.path }) {
                let name = url.lastPathComponent.lowercased()
                for kind in ["bookmarks.html", "history.json", "passwords.csv"] where name.hasSuffix(kind) && found[kind] == nil {
                    found[kind] = url
                }
            }
        }
        let parsed = found["bookmarks.html"].flatMap { try? Data(contentsOf: $0) }.flatMap(BookmarkImport.parse)
        let visits = found["history.json"].map(exportedHistory)?.count ?? 0
        let passwords = found["passwords.csv"]
        guard parsed?.isEmpty == false || visits > 0 || passwords != nil else {
            if root != file.deletingLastPathComponent() { try? FileManager.default.removeItem(at: root) }
            return nil
        }

        func tabs(_ links: [BookmarkImport.Link]) -> [ImportedTab] {
            links.map { ImportedTab(url: $0.url.absoluteString, title: $0.title) }
        }
        let loose = tabs(parsed?.loose ?? []).map(ImportedItem.tab)
        let folders = (parsed?.folders ?? []).map { ImportedItem.folder(name: $0.name, expanded: false, tabs($0.links).map(ImportedItem.tab)) }
        // the live default profile's key, so an export and a later live read land as one
        let key = "DefaultProfile"
        let profile = ImportedProfile(
            id: Importers.stableID("\(bundleID)/profile/\(key)"), key: key, name: "Safari", isDefault: true, folder: root,
            favourites: tabs(parsed?.favourites ?? []),
            bookmarks: (loose.isEmpty ? [] : [.folder(name: "Bookmarks", expanded: false, loose)]) + folders,
            history: visits > 0 ? found["history.json"].map { .safariExport($0) } : nil,
            logins: passwords.map { .csv($0) } ?? .csvOnly(hint: passwordsHint), historyCount: visits,
            loginCount: passwords.map(csvRows) ?? 0)
        return ImportedBrowser(name: "Safari", bundleID: bundleID, family: .safari, root: root, profiles: [profile])
    }

    private struct Row {
        var id: Int
        var parent: Int
        var type: Int
        /// 0 a tab group, 2 a profile, 3 a group folder; always 0 before Safari 17
        var subtype: Int
        var title: String?
        var url: String?
        var uuid: String?
        var server: String?
        var special: Int
        var hidden: Bool
        /// `extra_attributes` with `local_attributes` over it
        var attributes: [String: Any]
    }

    private struct Tabs {
        var rows: [Row] = []
        /// group refs of private windows
        var privates: [String] = []
        /// group ref of each window outside a tab group, with its window's profile ref or ""
        var unnamed: [String: String] = [:]
    }

    private static func read(_ db: OpaquePointer) -> Tabs {
        var tabs = Tabs()
        let fields = [
            "id", "parent", "type", "subtype", "title", "url", "external_uuid", "server_id", "special_id", "hidden",
            "extra_attributes", "local_attributes",
        ]
        let columns = SQLiteCopy.columns(db, "bookmarks")
        let live = columns.contains("deleted") ? " WHERE deleted IS NOT 1" : ""
        let order = columns.contains("order_index") ? "order_index, id" : "id"
        SQLiteCopy.rows(db, "SELECT \(select(fields, columns)) FROM bookmarks\(live) ORDER BY \(order);") { row in
            func int(_ column: Int32) -> Int { Int(sqlite3_column_int64(row, column)) }
            func attributes(_ column: Int32) -> [String: Any] {
                (try? PropertyListSerialization.propertyList(from: SQLiteCopy.blob(row, column), format: nil)) as? [String: Any] ?? [:]
            }
            tabs.rows.append(
                Row(
                    id: int(0), parent: int(1), type: int(2), subtype: int(3), title: SQLiteCopy.text(row, 4),
                    url: SQLiteCopy.text(row, 5), uuid: SQLiteCopy.text(row, 6), server: SQLiteCopy.text(row, 7),
                    special: int(8), hidden: int(9) != 0, attributes: attributes(10).merging(attributes(11)) { $1 }))
        }
        var profileOf: [String: String] = [:]
        let windows = select(["id", "private_tab_group_id", "local_tab_group_id", "active_profile_id"], SQLiteCopy.columns(db, "windows"))
        SQLiteCopy.rows(db, "SELECT \(windows) FROM windows;") { row in
            let profile = SQLiteCopy.text(row, 3) ?? ""
            if let window = SQLiteCopy.text(row, 0) { profileOf[window] = profile }
            if let group = SQLiteCopy.text(row, 1) { tabs.privates.append(group) }
            if let group = SQLiteCopy.text(row, 2) { tabs.unnamed[group] = profile }
        }
        let joined = select(["window_id", "tab_group_id"], SQLiteCopy.columns(db, "windows_unnamed_tab_groups"))
        SQLiteCopy.rows(db, "SELECT \(joined) FROM windows_unnamed_tab_groups;") { row in
            guard let group = SQLiteCopy.text(row, 1), tabs.unnamed[group] == nil else { return }
            tabs.unnamed[group] = SQLiteCopy.text(row, 0).flatMap { profileOf[$0] } ?? ""
        }
        return tabs
    }

    /// the named columns, NULL for any this version lacks
    private static func select(_ names: [String], _ columns: Set<String>) -> String {
        names.map { columns.contains($0) ? $0 : "NULL" }.joined(separator: ", ")
    }

    private static func kids(_ node: [String: Any]) -> [[String: Any]] { node["Children"] as? [[String: Any]] ?? [] }

    private static func leaf(_ node: [String: Any]) -> ImportedTab? {
        guard node["WebBookmarkType"] as? String == "WebBookmarkTypeLeaf", let url = node["URLString"] as? String else { return nil }
        return ImportedTab(url: url, title: (node["URIDictionary"] as? [String: Any])?["title"] as? String)
    }

    private static func items(_ nodes: [[String: Any]], _ depth: Int) -> [ImportedItem] {
        guard depth < 32 else { return [] }
        return nodes.compactMap { node in
            if let tab = leaf(node) { return .tab(tab) }
            guard node["WebBookmarkType"] as? String == "WebBookmarkTypeList" else { return nil }
            return .folder(name: node["Title"] as? String ?? "Folder", expanded: false, items(kids(node), depth + 1))
        }
    }

    /// Bookmarks.plist roots as folders, the Reading List among them; empty roots are left out
    private static func bookmarkFolders(_ roots: [[String: Any]]) -> [ImportedItem] {
        let names = ["BookmarksBar": "Favourites", "BookmarksMenu": "Bookmarks Menu", "com.apple.ReadingList": "Reading List"]
        var out: [ImportedItem] = []
        var loose: [ImportedItem] = []
        for node in roots {
            if let tab = leaf(node) {
                loose.append(.tab(tab))
                continue
            }
            let title = node["Title"] as? String ?? "Folder"
            let children = items(kids(node), 0)
            guard node["WebBookmarkType"] as? String == "WebBookmarkTypeList", !children.isEmpty else { continue }
            out.append(.folder(name: names[title] ?? title, expanded: false, children))
        }
        return loose.isEmpty ? out : out + [.folder(name: "Other Bookmarks", expanded: false, loose)]
    }

    /// the folder a named profile shows as its favourites, by bookmark UUID or sync id
    private static func favouritesFolder(_ nodes: [[String: Any]], _ id: String, _ depth: Int) -> [String: Any]? {
        guard depth < 32 else { return nil }
        for node in nodes where node["WebBookmarkType"] as? String == "WebBookmarkTypeList" {
            if node["WebBookmarkUUID"] as? String == id || (node["Sync"] as? [String: Any])?["ServerID"] as? String == id {
                return node
            }
            if let found = favouritesFolder(kids(node), id, depth + 1) { return found }
        }
        return nil
    }

    /// CSV records after the header; a quoted field may span lines
    private static func csvRows(_ file: URL) -> Int {
        guard let data = try? Data(contentsOf: file) else { return 0 }
        var quoted = false
        var open = false
        var rows = 0
        for byte in data {
            switch byte {
            case UInt8(ascii: "\""):
                quoted.toggle()
                open = true
            case UInt8(ascii: "\n") where !quoted:
                if open { rows += 1 }
                open = false
            case UInt8(ascii: "\r"): break
            default: open = true
            }
        }
        return max(0, rows + (open ? 1 : 0) - 1)
    }
}
