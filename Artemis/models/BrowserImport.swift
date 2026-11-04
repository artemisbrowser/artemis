import Foundation
import SQLite3

/// Finding the other browsers on the Mac and reading what they keep: bookmarks,
/// history, and Zen's workspaces. Everything is read-only, and databases are
/// read from copies because their browser holds them locked.
nonisolated enum BrowserImport {
    enum Engine: Sendable {
        case chromium, firefox, safari
    }

    /// one profile of one browser
    struct Source: Identifiable, Hashable, Sendable {
        var browser: String
        var bundleID: String
        var engine: Engine
        /// the browser's own name for the profile; nil when it has only one
        var profile: String?
        var directory: URL

        var id: String { directory.path }
        var title: String { profile.map { "\(browser) · \($0)" } ?? browser }
        var isZen: Bool { bundleID == "app.zen-browser.zen" }
    }

    /// name, bundle id, data folder under Application Support
    private static let chromiumFamily = [
        ("Chrome", "com.google.Chrome", "Google/Chrome"),
        ("Chrome Beta", "com.google.Chrome.beta", "Google/Chrome Beta"),
        ("Chrome Dev", "com.google.Chrome.dev", "Google/Chrome Dev"),
        ("Chrome Canary", "com.google.Chrome.canary", "Google/Chrome Canary"),
        ("Chromium", "org.chromium.Chromium", "Chromium"),
        ("Brave", "com.brave.Browser", "BraveSoftware/Brave-Browser"),
        ("Brave Beta", "com.brave.Browser.beta", "BraveSoftware/Brave-Browser-Beta"),
        ("Brave Nightly", "com.brave.Browser.nightly", "BraveSoftware/Brave-Browser-Nightly"),
        ("Edge", "com.microsoft.edgemac", "Microsoft Edge"),
        ("Edge Beta", "com.microsoft.edgemac.Beta", "Microsoft Edge Beta"),
        ("Edge Dev", "com.microsoft.edgemac.Dev", "Microsoft Edge Dev"),
        ("Edge Canary", "com.microsoft.edgemac.Canary", "Microsoft Edge Canary"),
        ("Vivaldi", "com.vivaldi.Vivaldi", "Vivaldi"),
        ("Opera", "com.operasoftware.Opera", "com.operasoftware.Opera"),
        ("Opera GX", "com.operasoftware.OperaGX", "com.operasoftware.OperaGX"),
    ]

    private static let firefoxFamily = [
        ("Firefox", "org.mozilla.firefox", "Firefox"),
        ("Zen", "app.zen-browser.zen", "zen"),
        ("LibreWolf", "io.gitlab.librewolf-community", "librewolf"),
        ("Floorp", "one.ablaze.floorp", "Floorp"),
        ("Waterfox", "net.waterfox.waterfox", "Waterfox"),
    ]

    // MARK: - Finding them

    /// every browser profile under `home` that holds bookmarks or history
    static func detect(home: URL) -> [Source] {
        let support = home.appending(path: "Library/Application Support")
        var out: [Source] = []
        for (name, id, path) in chromiumFamily {
            out += chromiumProfiles(name, id, support.appending(path: path))
        }
        for (name, id, path) in firefoxFamily {
            out += firefoxProfiles(name, id, support.appending(path: path))
        }
        let safari = home.appending(path: "Library/Safari")
        if FileManager.default.fileExists(atPath: safari.path) {
            out.append(Source(browser: "Safari", bundleID: "com.apple.Safari", engine: .safari, directory: safari))
        }
        return out
    }

    /// Profiles come from `Local State`. Without one, `Default` is tried, then
    /// the data folder itself, which is where Opera keeps its only profile.
    private static func chromiumProfiles(_ browser: String, _ bundleID: String, _ root: URL) -> [Source] {
        let cache = (try? Data(contentsOf: root.appending(path: "Local State")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            .flatMap { ($0["profile"] as? [String: Any])?["info_cache"] as? [String: [String: Any]] } ?? [:]
        let keys = cache.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        var found: [(key: String, directory: URL)] = (keys.isEmpty ? ["Default", ""] : keys).compactMap { key in
            let directory = key.isEmpty ? root : root.appending(path: key)
            let holds = ["Bookmarks", "History"].contains {
                FileManager.default.fileExists(atPath: directory.appending(path: $0).path)
            }
            return holds ? (key, directory) : nil
        }
        if keys.isEmpty { found = Array(found.prefix(1)) }
        return found.map { key, directory in
            Source(
                browser: browser, bundleID: bundleID, engine: .chromium,
                profile: found.count > 1 ? (cache[key]?["name"] as? String ?? key) : nil, directory: directory)
        }
    }

    /// the `[Profile…]` sections of `profiles.ini` whose folder holds places.sqlite
    private static func firefoxProfiles(_ browser: String, _ bundleID: String, _ root: URL) -> [Source] {
        guard let ini = try? String(contentsOf: root.appending(path: "profiles.ini"), encoding: .utf8)
        else { return [] }
        var sections: [[String: String]] = []
        for raw in ini.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                sections.append(["": line])
            } else if let equals = line.firstIndex(of: "="), !sections.isEmpty {
                sections[sections.count - 1][String(line[..<equals])] = String(line[line.index(after: equals)...])
            }
        }
        let found = sections.compactMap { section -> (name: String, directory: URL)? in
            guard section[""]?.hasPrefix("[Profile") == true, let path = section["Path"] else { return nil }
            let directory = section["IsRelative"] == "0" ? URL(fileURLWithPath: path) : root.appending(path: path)
            guard FileManager.default.fileExists(atPath: directory.appending(path: "places.sqlite").path)
            else { return nil }
            return (section["Name"] ?? directory.lastPathComponent, directory)
        }
        return found.map {
            Source(
                browser: browser, bundleID: bundleID, engine: .firefox,
                profile: found.count > 1 ? $0.name : nil, directory: $0.directory)
        }
    }

    // MARK: - What a profile holds

    struct Survey: Sendable {
        var bookmarks: BookmarkImport.Result?
        /// newest first, at most `historyLimit`
        var history: [HistoryEntry] = []
        /// Zen's workspaces, pins and essentials
        var workspaces: BookmarkImport.Result?
        /// Safari's files are behind Full Disk Access
        var blocked = false
    }

    static let historyLimit = 4000

    static func survey(_ source: Source) -> Survey {
        let directory = source.directory
        switch source.engine {
        case .chromium:
            return Survey(
                bookmarks: (try? Data(contentsOf: directory.appending(path: "Bookmarks"))).flatMap(BookmarkImport.parse),
                history: chromiumHistory(directory))
        case .firefox:
            let places = directory.appending(path: "places.sqlite")
            return Survey(
                bookmarks: firefoxBookmarks(places),
                history: history(
                    places,
                    """
                    SELECT url, title, last_visit_date, visit_count, typed FROM moz_places
                    WHERE hidden = 0 AND last_visit_date > 0 AND visit_count > 0 ORDER BY last_visit_date DESC
                    """
                ) { Date(timeIntervalSince1970: $0 / 1_000_000) },
                workspaces: source.isZen ? zenWorkspaces(directory) : nil)
        case .safari:
            let file = directory.appending(path: "Bookmarks.plist")
            guard isReadable(file) else { return Survey(blocked: true) }
            return Survey(
                bookmarks: (try? Data(contentsOf: file)).flatMap(BookmarkImport.parse),
                history: history(
                    directory.appending(path: "History.db"),
                    """
                    SELECT i.url, v.title, max(v.visit_time), i.visit_count, 0 FROM history_items i
                    JOIN history_visits v ON v.history_item = i.id GROUP BY i.id ORDER BY 3 DESC
                    """
                ) { Date(timeIntervalSinceReferenceDate: $0) })
        }
    }

    /// Opening the file is the honest test. Full Disk Access refuses with EPERM
    /// and never prompts, where a check of permissions alone says yes.
    static func isReadable(_ file: URL) -> Bool {
        let fd = open(file.path, O_RDONLY)
        guard fd >= 0 else { return false }
        close(fd)
        return true
    }

    // MARK: - History

    /// a Chromium profile's `History`; Arc's too
    static func chromiumHistory(_ profile: URL) -> [HistoryEntry] {
        history(
            profile.appending(path: "History"),
            """
            SELECT url, title, last_visit_time, visit_count, typed_count FROM urls
            WHERE hidden = 0 AND last_visit_time > 0 ORDER BY last_visit_time DESC
            """
        ) { Date(timeIntervalSince1970: $0 / 1_000_000 - 11_644_473_600) }
    }

    /// `sql` selects url, title, last visit, visit count and typed count
    private static func history(_ database: URL, _ sql: String, time: (Double) -> Date) -> [HistoryEntry] {
        withDatabase(at: database) { db in
            var out: [HistoryEntry] = []
            rows(db, sql + " LIMIT \(historyLimit);") { row in
                guard let raw = text(row, 0), let url = URL(string: raw), url.scheme == "http" || url.scheme == "https"
                else { return }
                let title = text(row, 1) ?? ""
                out.append(
                    HistoryEntry(
                        url: url, title: title.isEmpty ? (url.host() ?? raw) : title,
                        lastVisited: time(sqlite3_column_double(row, 2)),
                        visitCount: max(1, Int(sqlite3_column_int(row, 3))),
                        typedCount: Int(sqlite3_column_int(row, 4))))
            }
            return out
        } ?? []
    }

    // MARK: - Firefox bookmarks

    /// The toolbar, menu, unfiled and mobile roots, by their fixed guids. Tags
    /// are bookmarks too in places.sqlite, and are left out.
    private static func firefoxBookmarks(_ places: URL) -> BookmarkImport.Result? {
        withDatabase(at: places) { db -> BookmarkImport.Result? in
            var roots: [String: Int64] = [:]
            var children: [Int64: [(id: Int64, type: Int32, title: String?, url: String?)]] = [:]
            rows(
                db,
                """
                SELECT b.id, b.parent, b.type, b.title, p.url, b.guid FROM moz_bookmarks b
                LEFT JOIN moz_places p ON p.id = b.fk ORDER BY b.parent, b.position;
                """
            ) { row in
                let id = sqlite3_column_int64(row, 0)
                if let guid = text(row, 5) { roots[guid] = id }
                children[sqlite3_column_int64(row, 1), default: []].append(
                    (id, sqlite3_column_int(row, 2), text(row, 3), text(row, 4)))
            }
            func nodes(_ parent: Int64) -> [BookmarkImport.Node] {
                (children[parent] ?? []).compactMap { child in
                    switch child.type {
                    case 1: BookmarkImport.link(child.url, title: child.title).map { .link($0) }
                    case 2: .folder(child.title ?? "", nodes(child.id))
                    default: nil
                    }
                }
            }
            return BookmarkImport.result(
                ["toolbar_____", "menu________", "unfiled_____", "mobile______"].compactMap { roots[$0].map(nodes) })
        } ?? nil
    }

    // MARK: - Zen

    /// Workspaces become spaces, pinned tabs their pins, essentials favourites.
    /// The newest session file is read first; older Zen kept them in places.sqlite.
    static func zenWorkspaces(_ profile: URL) -> BookmarkImport.Result? {
        var spaces: [(id: String, name: String, icon: String?)] = []
        var pins: [(space: String?, link: BookmarkImport.Link, essential: Bool)] = []

        for name in ["zen-sessions.jsonlz4", "sessionstore-backups/recovery.jsonlz4", "sessionstore.jsonlz4"] {
            guard let data = try? Data(contentsOf: profile.appending(path: name)), let json = mozLz4(data),
                let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any]
            else { continue }
            for container in [root] + (root["windows"] as? [[String: Any]] ?? []) {
                for space in container["spaces"] as? [[String: Any]] ?? [] {
                    guard let id = space["uuid"] as? String else { continue }
                    spaces.append((id, space["name"] as? String ?? "", space["icon"] as? String))
                }
                for tab in container["tabs"] as? [[String: Any]] ?? [] {
                    let essential = tab["zenEssential"] as? Bool == true
                    guard essential || tab["pinned"] as? Bool == true else { continue }
                    let entries = tab["entries"] as? [[String: Any]] ?? []
                    let index = (tab["index"] as? Int ?? entries.count) - 1
                    let entry = entries.indices.contains(index) ? entries[index] : entries.last
                    guard let link = BookmarkImport.link(entry?["url"] as? String, title: entry?["title"] as? String)
                    else { continue }
                    pins.append((tab["zenWorkspace"] as? String, link, essential))
                }
            }
            break
        }

        if spaces.isEmpty && pins.isEmpty {
            withDatabase(at: profile.appending(path: "places.sqlite")) { db in
                rows(db, "SELECT uuid, name, icon FROM zen_workspaces ORDER BY position;") { row in
                    guard let id = text(row, 0) else { return }
                    spaces.append((id, text(row, 1) ?? "", text(row, 2)))
                }
                rows(
                    db,
                    """
                    SELECT workspace_uuid, url, title, is_essential FROM zen_pins
                    WHERE is_group = 0 ORDER BY position;
                    """
                ) { row in
                    guard let link = BookmarkImport.link(text(row, 1), title: text(row, 2)) else { return }
                    pins.append((text(row, 0), link, sqlite3_column_int(row, 3) != 0))
                }
            }
        }

        var result = BookmarkImport.Result(folders: [], loose: [])
        var slots: [String: Int] = [:]
        for space in spaces where slots[space.id] == nil {
            slots[space.id] = result.folders.count
            // Zen's own icons are chrome:// images; only an emoji carries over
            let icon = space.icon.flatMap {
                $0.count == 1 && $0.unicodeScalars.first?.properties.isEmoji == true && !$0.allSatisfy(\.isASCII)
                    ? $0 : nil
            }
            result.folders.append(BookmarkImport.Folder(name: space.name.isEmpty ? "Zen" : space.name, links: [], icon: icon))
        }
        for pin in pins {
            if pin.essential {
                if !result.favourites.contains(pin.link) { result.favourites.append(pin.link) }
            } else if let slot = pin.space.flatMap({ slots[$0] }) {
                if !result.folders[slot].links.contains(pin.link) { result.folders[slot].links.append(pin.link) }
            } else if !result.loose.contains(pin.link) {
                result.loose.append(pin.link)
            }
        }
        return result.folders.isEmpty && result.isEmpty ? nil : result
    }

    /// Mozilla's `mozLz40\0` header, the decoded size as a little-endian
    /// UInt32, then one LZ4 block. Nil for anything that isn't exactly that.
    static func mozLz4(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count >= 12, bytes.starts(with: Array("mozLz40\0".utf8)) else { return nil }
        let size = bytes[8..<12].reversed().reduce(0) { $0 << 8 | Int($1) }
        guard size <= 256 << 20 else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(size)
        var i = 12
        /// a 4-bit length of 15 continues in bytes until one isn't 255
        func length(_ nibble: UInt8) -> Int? {
            var n = Int(nibble)
            guard n == 15 else { return n }
            while i < bytes.count {
                let more = bytes[i]
                i += 1
                n += Int(more)
                if more != 255 { return n }
            }
            return nil
        }
        while i < bytes.count {
            let token = bytes[i]
            i += 1
            guard let literals = length(token >> 4), i + literals <= bytes.count, out.count + literals <= size
            else { return nil }
            out += bytes[i..<i + literals]
            i += literals
            // the last sequence is literals alone
            if i == bytes.count { break }
            guard i + 2 <= bytes.count else { return nil }
            let offset = Int(bytes[i]) | Int(bytes[i + 1]) << 8
            i += 2
            guard offset > 0, offset <= out.count, let match = length(token & 15).map({ $0 + 4 }),
                out.count + match <= size
            else { return nil }
            // byte by byte: a match may overlap the bytes it is writing
            for _ in 0..<match { out.append(out[out.count - offset]) }
        }
        return out.count == size ? Data(out) : nil
    }

    // MARK: - SQLite

    /// Run `body` against a copy of a database: the live file is locked while
    /// its browser runs, and its write-ahead log holds the newest rows, so both
    /// come across before it is opened.
    static func withDatabase<T>(at url: URL, _ body: (OpaquePointer) -> T) -> T? {
        let files = FileManager.default
        guard files.isReadableFile(atPath: url.path) else { return nil }
        let scratch = files.temporaryDirectory.appending(path: "import-\(UUID().uuidString)")
        guard (try? files.createDirectory(at: scratch, withIntermediateDirectories: true)) != nil
        else { return nil }
        defer { try? files.removeItem(at: scratch) }

        let copy = scratch.appending(path: url.lastPathComponent)
        guard (try? files.copyItem(at: url, to: copy)) != nil else { return nil }
        for suffix in ["-wal", "-shm"] {
            let side = URL(fileURLWithPath: url.path + suffix)
            guard files.fileExists(atPath: side.path) else { continue }
            try? files.copyItem(at: side, to: URL(fileURLWithPath: copy.path + suffix))
        }

        var handle: OpaquePointer?
        guard sqlite3_open_v2(copy.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
            let db = handle
        else {
            sqlite3_close(handle)
            return nil
        }
        defer { sqlite3_close(db) }
        return body(db)
    }

    /// each row of `sql`; nothing when it doesn't prepare, as on a database that isn't one
    static func rows(_ db: OpaquePointer, _ sql: String, _ each: (OpaquePointer) -> Void) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW { each(statement) }
    }

    static func text(_ statement: OpaquePointer?, _ column: Int32) -> String? {
        sqlite3_column_text(statement, column).map { String(cString: $0) }
    }
}
