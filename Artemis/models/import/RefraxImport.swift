// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import Foundation
import SQLite3

/// Refrax's SwiftData store. `global` spaces share one profile, each `separate` space is its
/// own, and `private` spaces keep nothing on disk worth importing.
nonisolated enum RefraxImport {
    private static let variants = [("website.refrax.browser", "Refrax"), ("website.refrax.browser.debug", "Refrax Debug")]
    private static let passwordHint = "In Refrax, open Passwords and choose Export to CSV. Then pick that file here."

    static func detect(home: URL) -> [ImportedBrowser] {
        variants.compactMap { bundleID, name in
            let root = home.appending(path: "Library/Application Support/\(bundleID)")
            let store = root.appending(path: "default.store")
            guard FileManager.default.fileExists(atPath: store.path) else { return nil }
            var global = ImportedProfile(
                id: Importers.stableID("\(bundleID)/profile/global"), key: "global", name: name, isDefault: true,
                folder: root, logins: .csvOnly(hint: passwordHint))
            attach(home.appending(path: "Library/HTTPStorages/\(bundleID).binarycookies"), to: &global)
            let separate = SQLiteCopy.withDatabase(at: store) { db in
                read(db, global: &global, bundleID: bundleID, home: home, store: store)
            }
            return ImportedBrowser(
                name: name, bundleID: bundleID, family: .refrax, root: root, profiles: [global] + (separate ?? []))
        }
    }

    /// visits of these spaces aggregated by URL, newest first; failed loads are skipped
    static func history(_ store: URL, spaces: [UUID]) -> [ImportedVisit] {
        guard !spaces.isEmpty else { return [] }
        return SQLiteCopy.withDatabase(at: store) { db in
            var out: [ImportedVisit] = []
            let title = SQLiteCopy.columns(db, "ZHISTORYENTRY").contains("ZTITLE") ? "ZTITLE" : "NULL"
            // a bare column beside max() takes its value from the row holding the max
            SQLiteCopy.rows(
                db,
                """
                SELECT ZURL, \(title), max(ZVISITEDAT), count(*) FROM ZHISTORYENTRY
                WHERE \(visits(db, spaces)) GROUP BY ZURL ORDER BY 3 DESC LIMIT \(Importers.historyLimit);
                """
            ) { row in
                guard let url = SQLiteCopy.text(row, 0), let visited = date(row, 2) else { return }
                out.append(
                    ImportedVisit(
                        url: url, title: SQLiteCopy.text(row, 1) ?? "", lastVisited: visited,
                        visitCount: Int(sqlite3_column_int64(row, 3))))
            }
            return out
        } ?? []
    }

    /// the rows `history` reads
    private static func visits(_ db: OpaquePointer, _ spaces: [UUID]) -> String {
        let failed = SQLiteCopy.columns(db, "ZHISTORYENTRY").contains("ZFAILEDTOLOAD") ? "coalesce(ZFAILEDTOLOAD, 0) = 0 AND " : ""
        let ids = spaces.map { "x'\($0.uuidString.replacingOccurrences(of: "-", with: ""))'" }
        return failed + "ZURL IS NOT NULL AND ZSPACEID IN (\(ids.joined(separator: ",")))"
    }

    // MARK: - The store

    private struct Space {
        var pk: Int64
        var id: UUID
        var mode: String
        var imported: ImportedSpace
    }

    private struct Group {
        var id: UUID
        var space: Int64?
        var parent: UUID?
        var name: String
        var position: Int64
        var isPinned: Bool
        var isCollapsed: Bool
        var isArchive: Bool
    }

    private struct Tab {
        var space: Int64?
        var isFavourite: Bool
        var name: String?
        var group: UUID?
        var position: Int64
        var lastActive: Date?
        var archivedAt: Date?
        var bookmark: Int64?
        var pages: [ImportedTab]
        /// SwiftData's `layoutPosition`; nil or `single` outside a split
        var layout: [String?]
    }

    /// fills `global` and returns one profile per `separate` space
    private static func read(
        _ db: OpaquePointer, global: inout ImportedProfile, bundleID: String, home: URL, store: URL
    ) -> [ImportedProfile] {
        let spaceColumns = SQLiteCopy.columns(db, "ZSPACE")
        var spaces: [Space] = []
        SQLiteCopy.rows(
            db,
            """
            SELECT Z_PK, ZID, \(SQLiteCopy.column("ZNAME", spaceColumns)), \(SQLiteCopy.column("ZICONNAME", spaceColumns)),
                   \(SQLiteCopy.column("ZCOLORHEX", spaceColumns)), \(SQLiteCopy.column("ZDATASTOREMODE", spaceColumns))
            FROM ZSPACE ORDER BY \(SQLiteCopy.column("ZPOSITION", spaceColumns)), \(SQLiteCopy.column("ZCREATEDAT", spaceColumns));
            """
        ) { row in
            guard let id = uuid(row, 1) else { return }
            let space = ImportedSpace(
                id: UUID(), name: nonEmpty(row, 2) ?? "Space", icon: nonEmpty(row, 3),
                colors: color(SQLiteCopy.text(row, 4)).map { [$0] } ?? [])
            spaces.append(Space(pk: sqlite3_column_int64(row, 0), id: id, mode: SQLiteCopy.text(row, 5) ?? "global", imported: space))
        }

        let groupColumns = SQLiteCopy.columns(db, "ZTABGROUP")
        var groups: [Group] = []
        var groupByPK: [Int64: UUID] = [:]
        var groupIDs: Set<UUID> = []
        SQLiteCopy.rows(
            db,
            """
            SELECT Z_PK, ZID, \(SQLiteCopy.column("ZSPACE", groupColumns)), \(SQLiteCopy.column("ZPARENTGROUPID", groupColumns)),
                   \(SQLiteCopy.column("ZNAME", groupColumns)), \(SQLiteCopy.column("ZPOSITION", groupColumns)),
                   \(SQLiteCopy.column("ZISPINNED", groupColumns)), \(SQLiteCopy.column("ZISCOLLAPSED", groupColumns)),
                   \(SQLiteCopy.column("ZISARCHIVE", groupColumns))
            FROM ZTABGROUP;
            """
        ) { row in
            guard let id = uuid(row, 1) else { return }
            groupByPK[sqlite3_column_int64(row, 0)] = id
            // one group per id, so a walk down from a root never meets a group twice
            guard groupIDs.insert(id).inserted else { return }
            groups.append(
                Group(
                    id: id, space: int(row, 2), parent: uuid(row, 3),
                    name: nonEmpty(row, 4) ?? "Folder", position: sqlite3_column_int64(row, 5),
                    isPinned: sqlite3_column_int(row, 6) != 0, isCollapsed: sqlite3_column_int(row, 7) != 0,
                    isArchive: sqlite3_column_int(row, 8) != 0))
        }
        for index in groups.indices where groups[index].parent.map({ !groupIDs.contains($0) }) == true {
            groups[index].parent = nil
        }

        let pageColumns = SQLiteCopy.columns(db, "ZTABPAGE")
        var pages: [Int64: [(tab: ImportedTab, layout: String?)]] = [:]
        SQLiteCopy.rows(
            db,
            """
            SELECT ZTAB, ZURL, \(SQLiteCopy.column("ZTITLE", pageColumns)), \(SQLiteCopy.column("ZLAYOUTPOSITION", pageColumns))
            FROM ZTABPAGE ORDER BY \(SQLiteCopy.column("ZCREATEDAT", pageColumns));
            """
        ) { row in
            guard let tab = int(row, 0), let url = nonEmpty(row, 1) else { return }
            pages[tab, default: []].append((ImportedTab(url: url, title: SQLiteCopy.text(row, 2)), SQLiteCopy.text(row, 3)))
        }

        let tabColumns = SQLiteCopy.columns(db, "ZTAB")
        var tabs: [Tab] = []
        SQLiteCopy.rows(
            db,
            """
            SELECT Z_PK, \(SQLiteCopy.column("ZSPACE", tabColumns)), \(SQLiteCopy.column("ZSTATUS", tabColumns)),
                   \(SQLiteCopy.column("ZCUSTOMNAME", tabColumns)), \(SQLiteCopy.column("ZGROUP", tabColumns)),
                   \(SQLiteCopy.column("ZGROUPID", tabColumns)), \(SQLiteCopy.column("ZPOSITION", tabColumns)),
                   \(SQLiteCopy.column("ZLASTACCESSED", tabColumns)), \(SQLiteCopy.column("ZARCHIVEDAT", tabColumns)),
                   \(SQLiteCopy.column("ZLINKEDBOOKMARK", tabColumns))
            FROM ZTAB ORDER BY \(SQLiteCopy.column("ZPOSITION", tabColumns));
            """
        ) { row in
            // legacy `liveFavorite` and `pinned` rows read as favourites
            let favourite = ["favorite", "liveFavorite", "pinned"].contains(SQLiteCopy.text(row, 2) ?? "")
            let group = int(row, 4).flatMap { groupByPK[$0] } ?? uuid(row, 5)
            // a split's panes run top-left, top-right, bottom-left, bottom-right
            let order = ["topLeft", "topRight", "bottomLeft", "bottomRight"]
            let held = (pages[sqlite3_column_int64(row, 0)] ?? []).sorted {
                order.firstIndex(of: $0.layout ?? "") ?? -1 < order.firstIndex(of: $1.layout ?? "") ?? -1
            }
            tabs.append(
                Tab(
                    space: int(row, 1), isFavourite: favourite, name: nonEmpty(row, 3),
                    group: group.flatMap { groupIDs.contains($0) ? $0 : nil }, position: sqlite3_column_int64(row, 6),
                    lastActive: date(row, 7), archivedAt: date(row, 8), bookmark: int(row, 9),
                    pages: held.map(\.tab), layout: held.map(\.layout)))
        }

        // MARK: Spaces, pinned and today

        func archived(_ tab: Tab) -> Bool {
            tab.archivedAt != nil || groups.contains { $0.id == tab.group && $0.isArchive }
        }
        let live = tabs.filter { !$0.isFavourite && !archived($0) }
        func item(_ tab: Tab) -> ImportedItem? {
            let panes = tab.pages
            guard panes.count > 1 else {
                guard var only = panes.first else { return nil }
                only.name = tab.name
                return .tab(only)
            }
            // panes stacked in one column are rows; anything else reads side by side
            let left = tab.layout.allSatisfy { $0 == "topLeft" || $0 == "bottomLeft" }
            let right = tab.layout.allSatisfy { $0 == "topRight" || $0 == "bottomRight" }
            return .split(panes, left || right ? .rows : .columns)
        }
        /// groups and tabs share one position order under their parent
        func ordered(_ folders: [Group], _ leaves: [Tab]) -> [ImportedItem] {
            let entries =
                folders.map { ($0.position, ImportedItem.folder(name: $0.name, expanded: !$0.isCollapsed, inside($0))) }
                + leaves.compactMap { tab in item(tab).map { (tab.position, $0) } }
            return entries.sorted { $0.0 < $1.0 }.map(\.1)
        }
        func inside(_ group: Group) -> [ImportedItem] {
            ordered(groups.filter { $0.parent == group.id }, live.filter { $0.group == group.id })
        }
        for index in spaces.indices {
            let space = spaces[index]
            let roots = groups.filter { $0.space == space.pk && $0.parent == nil && !$0.isArchive }
            spaces[index].imported.id = Importers.stableID(
                "\(bundleID)/\(space.mode == "separate" ? key(space.id) : "global")/space/\(key(space.id))")
            spaces[index].imported.pinned = ordered(roots.filter(\.isPinned), [])
            spaces[index].imported.today = ordered(
                roots.filter { !$0.isPinned }, live.filter { $0.space == space.pk && $0.group == nil })
        }

        // MARK: Favourites

        var bookmarks: [(pk: Int64, url: String, title: String?)] = []
        let bookmarkColumns = SQLiteCopy.columns(db, "ZBOOKMARK")
        if bookmarkColumns.contains("ZISFAVORITE") {
            SQLiteCopy.rows(
                db,
                """
                SELECT Z_PK, ZURL, \(SQLiteCopy.column("ZTITLE", bookmarkColumns)) FROM ZBOOKMARK WHERE ZISFAVORITE != 0
                ORDER BY \(SQLiteCopy.column("ZFAVORITEPOSITIONVALUE", bookmarkColumns));
                """
            ) { row in
                if let url = nonEmpty(row, 1) { bookmarks.append((sqlite3_column_int64(row, 0), url, SQLiteCopy.text(row, 2))) }
            }
        }
        // a favourite tab's home is its linked bookmark; the grid runs in the bookmarks' order
        let favouriteTabs = tabs.filter(\.isFavourite)
        let homes = Dictionary(bookmarks.map { ($0.pk, $0.url) }) { first, _ in first }
        var favourites = bookmarks.map { bookmark in
            guard let tab = favouriteTabs.first(where: { $0.bookmark == bookmark.pk }), let page = tab.pages.first else {
                return ImportedTab(url: bookmark.url, title: bookmark.title)
            }
            return ImportedTab(
                url: page.url, title: page.title, name: tab.name,
                home: page.url == bookmark.url ? nil : bookmark.url)
        }
        favourites += favouriteTabs.filter { tab in tab.bookmark.flatMap { homes[$0] } == nil }.compactMap { tab in
            tab.pages.first.map { ImportedTab(url: $0.url, title: $0.title, name: tab.name) }
        }
        var seen: Set<String> = []
        global.favourites = favourites.filter { seen.insert($0.home ?? $0.url).inserted }

        // MARK: Profiles

        func fill(_ profile: inout ImportedProfile, _ members: [Space]) {
            profile.spaces = members.map(\.imported)
            profile.archive = members.flatMap { space in
                tabs.filter { $0.space == space.pk && !$0.isFavourite && archived($0) }.flatMap { tab in
                    tab.pages.map { page in
                        ImportedArchive(
                            url: page.url, title: page.title ?? "", name: tab.name,
                            archivedAt: tab.archivedAt ?? tab.lastActive ?? Date(), spaceName: space.imported.name)
                    }
                }
            }
            let ids = members.map(\.id)
            guard !ids.isEmpty else { return }
            profile.history = .refrax(store, spaces: ids)
            profile.historyCount = SQLiteCopy.scalar(db, "SELECT count(DISTINCT ZURL) FROM ZHISTORYENTRY WHERE \(visits(db, ids));")
        }
        fill(&global, spaces.filter { $0.mode != "separate" && $0.mode != "private" })
        return spaces.filter { $0.mode == "separate" }.map { space in
            var profile = ImportedProfile(
                id: Importers.stableID("\(bundleID)/profile/\(key(space.id))"), key: key(space.id),
                name: space.imported.name, folder: global.folder)
            fill(&profile, [space])
            attach(
                home.appending(path: "Library/WebKit/\(bundleID)/WebsiteDataStore/\(key(space.id))/Cookies/Cookies.binarycookies"),
                to: &profile)
            return profile
        }
    }

    private static func attach(_ jar: URL, to profile: inout ImportedProfile) {
        guard FileManager.default.fileExists(atPath: jar.path) else { return }
        profile.cookies = [.binary(jar)]
        profile.cookieCount = BinaryCookies.count(jar)
    }

    // MARK: - Values

    /// a space's id as WebKit names its data store folder
    private static func key(_ id: UUID) -> String { id.uuidString.lowercased() }

    private static func nonEmpty(_ row: OpaquePointer, _ column: Int32) -> String? {
        SQLiteCopy.text(row, column).flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func int(_ row: OpaquePointer, _ column: Int32) -> Int64? {
        sqlite3_column_type(row, column) == SQLITE_NULL ? nil : sqlite3_column_int64(row, column)
    }

    /// SwiftData dates are seconds since 2001
    private static func date(_ row: OpaquePointer, _ column: Int32) -> Date? {
        sqlite3_column_type(row, column) == SQLITE_NULL ? nil : Date(timeIntervalSinceReferenceDate: sqlite3_column_double(row, column))
    }

    /// SwiftData keeps a UUID as 16 bytes in RFC order
    private static func uuid(_ row: OpaquePointer, _ column: Int32) -> UUID? {
        let bytes = SQLiteCopy.blob(row, column)
        if bytes.count == 16 { return bytes.withUnsafeBytes { UUID(uuid: $0.loadUnaligned(as: uuid_t.self)) } }
        return SQLiteCopy.text(row, column).flatMap(UUID.init(uuidString:))
    }

    /// Refrax's `GroupColor` palette, light appearance, Display P3
    private static let palette: [String: [Double]] = [
        "Flamingo": [1.000, 0.267, 0.589], "Coral": [0.994, 0.303, 0.362], "Mahogany": [0.974, 0.367, 0.050],
        "Avocado": [0.446, 0.642, 0.000], "Emerald": [0.000, 0.671, 0.401], "Turquoise": [0.000, 0.666, 0.578],
        "Pelorus": [0.000, 0.638, 0.743], "Steel": [0.000, 0.600, 0.966], "Neon": [0.457, 0.552, 0.996],
        "Violet": [0.661, 0.468, 1.000], "Orchid": [0.890, 0.305, 0.906],
    ]

    /// a palette name, `p3:r,g,b` with 0…1 components, or `#RRGGBB`
    private static func color(_ raw: String?) -> RGBA? {
        guard let raw else { return nil }
        if raw.hasPrefix("#"), raw.count == 7, let value = UInt32(raw.dropFirst(), radix: 16) {
            return RGBA(Double(value >> 16 & 0xFF) / 255, Double(value >> 8 & 0xFF) / 255, Double(value & 0xFF) / 255)
        }
        let p3 = palette[raw] ?? (raw.hasPrefix("p3:") ? raw.dropFirst(3).split(separator: ",").compactMap { Double($0) } : [])
        guard p3.count == 3 else { return nil }
        // linear Display P3 to linear sRGB; both share the sRGB curve and D65 white
        let matrix = [[1.2249401, -0.2249404, 0], [-0.0420569, 1.0420571, 0], [-0.0196376, -0.0786361, 1.0982735]]
        let linear = p3.map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
        let srgb = matrix.map { row in
            let value = min(max(zip(row, linear).reduce(0) { $0 + $1.0 * $1.1 }, 0), 1)
            return value <= 0.0031308 ? value * 12.92 : 1.055 * pow(value, 1 / 2.4) - 0.055
        }
        return RGBA(srgb[0], srgb[1], srgb[2])
    }
}
