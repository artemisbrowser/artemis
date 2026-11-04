import AppKit
import Foundation
import SQLite3

/// Arc's sidebar file, spaces plus a flat pool of items linked by parent/child
/// ids, as Artemis `SpaceData`, so an import lands through the relaunch path
enum ArcImport {
    static let bundleID = "company.thebrowser.Browser"

    struct Result {
        var spaces: [SpaceData] = []
        /// Arc's top apps, which are Artemis' favourites
        var favouriteURLs: [String] = []
        var archived: [ArchiveEntry] = []
        /// url → the page title Arc had, shown until the tab is hydrated
        var titles: [String: String] = [:]
        /// url → the name you gave the tab in Arc, which outranks any title
        var renames: [String: String] = [:]
        /// Arc profile folder ("Default", "Profile 1") → the Artemis profile its
        /// spaces, cookies, history and passwords land in
        var profileIDs: [String: UUID] = ["Default": Profile.defaultID]
        /// Arc profile folder → the name Arc shows for it
        var profileNames: [String: String] = [:]
        var historyCount = 0

        var tabCount: Int { spaces.reduce(favouriteURLs.count) { $0 + $1.tabs.count } }
        var folderCount: Int {
            spaces.reduce(0) { $0 + folders(in: $1.pinnedEntries) + folders(in: $1.todayEntries) }
        }
        var isEmpty: Bool { spaces.isEmpty && favouriteURLs.isEmpty }

        /// the profiles Arc's spaces browse in, other than the default one
        var profiles: [ProfileData] {
            profileIDs.compactMap { folder, id in
                guard id != Profile.defaultID else { return nil }
                return ProfileData(
                    id: id, name: profileNames[folder] ?? folder, icon: "person.crop.circle",
                    essentialURLs: [])
            }
            .sorted { $0.name < $1.name }
        }

        private func folders(in entries: [EntryData]) -> Int {
            entries.reduce(0) { count, entry in
                count + (entry.kind == "folder" ? 1 : 0) + folders(in: entry.children ?? [])
            }
        }
    }

    // MARK: - Finding Arc

    /// the real home directory — `NSHomeDirectory()` is the sandbox container,
    /// and Arc's data sits outside it
    static var home: URL {
        guard let path = getpwuid(getuid())?.pointee.pw_dir else {
            return URL(fileURLWithPath: NSHomeDirectory())
        }
        return URL(fileURLWithPath: String(cString: path))
    }

    static var dataDirectory: URL { home.appending(path: "Library/Application Support/Arc") }

    static var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    /// the sandbox exception covers `~/Library/Application Support/Arc/`; a
    /// folder picked in an open panel is the fallback when it doesn't
    static func isReadable(_ directory: URL = dataDirectory) -> Bool {
        FileManager.default.isReadableFile(
            atPath: directory.appending(path: "StorableSidebar.json").path)
    }

    // MARK: - Reading

    static func read(from directory: URL = dataDirectory) -> Result? {
        guard let data = try? Data(contentsOf: directory.appending(path: "StorableSidebar.json")),
            var parsed = parseSidebar(data)
        else { return nil }
        parsed.result.profileNames = profileNames(in: directory)
        if let archive = try? Data(contentsOf: directory.appending(path: "StorableArchiveItems.json"))
        {
            parsed.result.archived = parse(archive: archive, spaceNames: parsed.spaceNames)
        }
        return parsed.result
    }

    // MARK: - Sidebar

    static func parse(sidebar data: Data) -> Result? { parseSidebar(data)?.result }

    /// the space names come back with the result: an archived tab names the
    /// space it was archived from by id
    private static func parseSidebar(_ data: Data) -> (result: Result, spaceNames: [String: String])? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let containers = (root["sidebar"] as? [String: Any])?["containers"] as? [[String: Any]],
            let container = containers.first(where: { $0["spaces"] != nil })
        else { return nil }

        var index: [String: [String: Any]] = [:]
        for (id, item) in pairs(container["items"] as? [Any] ?? []) { index[id] = item }

        var result = Result()
        var spaceNames: [String: String] = [:]

        for (arcID, space) in pairs(container["spaces"] as? [Any] ?? []) {
            let name = (space["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Space"
            spaceNames[arcID] = name
            let sections = sectionIDs(space)
            let builder = Builder(items: index)
            let pinned = builder.entries(under: sections.pinned, pinned: true)
            let today = builder.entries(under: sections.unpinned, pinned: false)
            // spaces on the same Arc profile share one profile here
            let folder = profileFolder(space)
            let profileID = result.profileIDs[folder] ?? UUID()
            result.profileIDs[folder] = profileID
            result.spaces.append(
                SpaceData(
                    id: UUID(), name: name, icon: icon(space), appearance: appearance(space),
                    profileID: profileID,
                    splitGroups: builder.splits, tabs: builder.tabs,
                    selectedTabID: builder.tabs.first?.id,
                    pinnedEntries: pinned, todayEntries: today))
            result.titles.merge(builder.titles) { current, _ in current }
            result.renames.merge(builder.renames) { current, _ in current }
        }

        // the top-apps container's children are the favourites
        let favourites = Builder(items: index)
        for (_, item) in index {
            guard let type = (item["data"] as? [String: Any])?["itemContainer"] as? [String: Any],
                (type["containerType"] as? [String: Any])?["topApps"] != nil,
                let id = item["id"] as? String
            else { continue }
            _ = favourites.entries(under: id, pinned: false)
        }
        result.favouriteURLs = favourites.tabs.map(\.url)
        result.titles.merge(favourites.titles) { current, _ in current }
        result.renames.merge(favourites.renames) { current, _ in current }

        return result.isEmpty ? nil : (result, spaceNames)
    }

    /// Arc writes its collections as flat `[id, value, id, value…]` arrays
    private static func pairs(_ array: [Any]) -> [(String, [String: Any])] {
        stride(from: 0, to: max(array.count - 1, 0), by: 2).compactMap { i in
            guard let id = array[i] as? String, let value = array[i + 1] as? [String: Any]
            else { return nil }
            return (id, value)
        }
    }

    /// the container ids holding a space's pinned and unpinned rows
    private static func sectionIDs(_ space: [String: Any]) -> (pinned: String?, unpinned: String?) {
        let raw = (space["newContainerIDs"] as? [Any]) ?? (space["containerIDs"] as? [Any]) ?? []
        var pinned: String?
        var unpinned: String?
        for i in stride(from: 0, to: max(raw.count - 1, 0), by: 2) {
            guard let key = (raw[i] as? [String: Any])?.keys.first, let id = raw[i + 1] as? String
            else { continue }
            if key == "pinned" { pinned = id }
            if key == "unpinned" { unpinned = id }
        }
        return (pinned, unpinned)
    }

    /// the folder of the Arc profile a space browses in
    private static func profileFolder(_ space: [String: Any]) -> String {
        guard let profile = space["profile"] as? [String: Any], profile["default"] == nil,
            let custom = payload(profile, "custom"),
            let name = custom["directoryBasename"] as? String
        else { return "Default" }
        return name
    }

    /// the names Arc shows for its profiles, from Chromium's `Local State`
    private static func profileNames(in directory: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: directory.appending(path: "User Data/Local State")),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let cache = (root["profile"] as? [String: Any])?["info_cache"] as? [String: [String: Any]]
        else { return [:] }
        return cache.compactMapValues { ($0["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } }
    }

    /// Walks one Arc container, collecting its tabs and splits as it flattens
    /// the item pool into an Artemis entry tree.
    private final class Builder {
        let items: [String: [String: Any]]
        var tabs: [TabRecord] = []
        var splits: [SplitGroupData] = []
        var titles: [String: String] = [:]
        var renames: [String: String] = [:]

        init(items: [String: [String: Any]]) { self.items = items }

        func entries(under id: String?, pinned: Bool, depth: Int = 0) -> [EntryData] {
            guard let id, let node = items[id] else { return [] }
            var out: [EntryData] = []
            for childID in node["childrenIds"] as? [String] ?? [] {
                guard let child = items[childID], let data = child["data"] as? [String: Any]
                else { continue }
                if data["tab"] != nil {
                    if let entry = tab(child, pinned: pinned) { out.append(entry) }
                } else if data["list"] != nil {
                    let children = entries(under: childID, pinned: pinned, depth: depth + 1)
                    // deeper than Artemis nests: the tabs come up a level rather
                    // than being dropped
                    if depth >= Space.maxFolderDepth {
                        out.append(contentsOf: children)
                    } else {
                        out.append(
                            EntryData(
                                kind: "folder", id: UUID(),
                                name: child["title"] as? String ?? "Folder", expanded: true,
                                children: children))
                    }
                } else if let info = data["splitView"] as? [String: Any] {
                    out.append(contentsOf: split(child, info, pinned: pinned))
                }
            }
            return out
        }

        private func tab(_ item: [String: Any], pinned: Bool) -> EntryData? {
            guard let info = (item["data"] as? [String: Any])?["tab"] as? [String: Any],
                let raw = info["savedURL"] as? String, let url = URL(string: raw),
                url.scheme == "http" || url.scheme == "https"
            else { return nil }
            let record = TabRecord(
                url: raw, pinnedURL: pinned ? raw : nil, isPinned: pinned,
                lastAccessed: date(info["timeLastActiveAt"]), createdAt: date(item["createdAt"]))
            tabs.append(record)
            if let title = info["savedTitle"] as? String, !title.isEmpty { titles[raw] = title }
            if let name = item["title"] as? String, !name.isEmpty { renames[raw] = name }
            return EntryData(kind: "tab", id: record.id)
        }

        private func split(_ item: [String: Any], _ info: [String: Any], pinned: Bool) -> [EntryData]
        {
            var panes: [EntryData] = []
            for childID in (item["childrenIds"] as? [String] ?? []).prefix(SplitGroup.maxPanes) {
                guard let child = items[childID], let entry = tab(child, pinned: pinned) else {
                    continue
                }
                panes.append(entry)
            }
            guard panes.count >= SplitGroup.minPanes else { return panes }
            splits.append(
                SplitGroupData(
                    id: UUID(), tree: nil, tabIDs: panes.map(\.id), tabIndices: [],
                    orientation: info["layoutOrientation"] as? String == "vertical"
                        ? .rows : .columns,
                    ratios: [], linkSourceID: nil, linkTargetID: nil, linkSourceIndex: nil,
                    linkTargetIndex: nil))
            return panes
        }

        /// Arc stores times as seconds from the 2001 reference date
        private func date(_ value: Any?) -> Date {
            guard let seconds = value as? Double else { return Date() }
            return Date(timeIntervalSinceReferenceDate: seconds)
        }
    }

    // MARK: - Archive

    private static func parse(archive data: Data, spaceNames: [String: String]) -> [ArchiveEntry] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        return pairs(root["items"] as? [Any] ?? []).compactMap { _, item in
            guard let sidebar = item["sidebarItem"] as? [String: Any],
                let info = (sidebar["data"] as? [String: Any])?["tab"] as? [String: Any],
                let raw = info["savedURL"] as? String, let url = URL(string: raw),
                url.scheme == "http" || url.scheme == "https"
            else { return nil }
            let title = (sidebar["title"] as? String) ?? (info["savedTitle"] as? String)
                ?? url.host() ?? raw
            let archivedAt = (item["archivedAt"] as? Double)
                .map(Date.init(timeIntervalSinceReferenceDate:)) ?? Date()
            let source = ((item["source"] as? [String: Any])?["space"] as? [String: Any])?["_0"]
                as? String
            return ArchiveEntry(
                url: url, title: title, archivedAt: archivedAt,
                spaceName: source.flatMap { spaceNames[$0] } ?? "Arc")
        }
    }

    // MARK: - Appearance

    /// Arc encodes its enums as `{"caseName": {"_0": payload}}`
    private static func payload(_ dict: [String: Any], _ key: String) -> [String: Any]? {
        guard let inner = dict[key] as? [String: Any] else { return nil }
        return inner["_0"] as? [String: Any] ?? inner
    }

    /// unwrap an enum whose case name doesn't matter
    private static func onlyCase(_ dict: [String: Any]?) -> [String: Any]? {
        guard let first = dict?.values.first as? [String: Any] else { return nil }
        return first["_0"] as? [String: Any] ?? first
    }

    private static func appearance(_ space: [String: Any]) -> SpaceAppearance {
        let theme = (space["customInfo"] as? [String: Any])?["windowTheme"] as? [String: Any]
        let background = theme?["background"] as? [String: Any]
        let single = background.flatMap { payload($0, "single") ?? onlyCase($0) }
        let style = onlyCase(onlyCase(single?["style"] as? [String: Any]))

        var colors: [RGBA] = []
        if let base = style?["baseColors"] as? [[String: Any]] {
            colors = base.compactMap(rgba(from:))
        } else if let one = (style?["color"] as? [String: Any]).flatMap(rgba(from:)) {
            colors = [one]
        }
        colors = colors.filter { $0.a > 0.01 }

        var out = SpaceAppearance()
        switch colors.count {
        case 0: return SpacePreset.all[0].appearance
        case 1:
            out.fill = .solid
            out.colors = colors
        default:
            out.fill = .gradient
            out.colors = Array(colors.prefix(3))
        }
        let modifiers = style?["modifiers"] as? [String: Any]
        out.grain = min(max((modifiers?["noiseFactor"] as? Double) ?? 0, 0), 1)
        return out
    }

    /// Arc's colours are extended sRGB and often outside the gamut; converting
    /// through `NSColor` clamps them to something Artemis can paint
    private static func rgba(from dict: [String: Any]) -> RGBA? {
        guard let r = dict["red"] as? Double, let g = dict["green"] as? Double,
            let b = dict["blue"] as? Double
        else { return nil }
        let a = dict["alpha"] as? Double ?? 1
        let components: [CGFloat] = [CGFloat(r), CGFloat(g), CGFloat(b), CGFloat(a)]
        let extended = NSColor(colorSpace: .extendedSRGB, components: components, count: 4)
        guard let srgb = extended.usingColorSpace(.sRGB) else { return nil }
        return RGBA(
            Double(srgb.redComponent), Double(srgb.greenComponent), Double(srgb.blueComponent),
            Double(srgb.alphaComponent))
    }

    // MARK: - Icons

    private static func icon(_ space: [String: Any]) -> String {
        guard let type = (space["customInfo"] as? [String: Any])?["iconType"] as? [String: Any]
        else { return "square.stack" }
        if let emoji = type["emoji"] as? String, !emoji.isEmpty { return emoji }
        if let code = type["emoji"] as? Int, let scalar = UnicodeScalar(UInt32(code)) {
            return String(Character(scalar))
        }
        guard let name = type["icon"] as? String else { return "square.stack" }
        if let symbol = symbols[name] { return symbol }
        return SFSymbols.allSymbols.contains(name) ? name : "square.stack"
    }

    /// Arc's icon names against the nearest SF Symbol; anything unmapped that is
    /// already a symbol name passes through
    private static let symbols: [String: String] = [
        "airplane": "airplane", "bank": "building.columns.fill", "bike": "bicycle",
        "book": "book.fill", "briefcase": "briefcase.fill", "calendar": "calendar",
        "camera": "camera.fill", "car": "car.fill", "cart": "cart.fill",
        "chat": "bubble.left.fill", "clock": "clock.fill", "cloud": "cloud.fill",
        "code": "chevron.left.forwardslash.chevron.right", "coffee": "cup.and.saucer.fill",
        "compass": "safari.fill", "construction": "hammer.fill", "dollar": "dollarsign.circle.fill",
        "envelope": "envelope.fill", "film": "film.fill", "flag": "flag.fill",
        "flash": "bolt.fill", "folder": "folder.fill", "food": "fork.knife",
        "game": "gamecontroller.fill", "gift": "gift.fill", "globe": "globe",
        "graduation": "graduationcap.fill", "headphones": "headphones", "health": "heart.text.square.fill",
        "heart": "heart.fill", "home": "house.fill", "house": "house.fill",
        "image": "photo.fill", "key": "key.fill", "leaf": "leaf.fill",
        "lightbulb": "lightbulb.fill", "lock": "lock.fill", "mail": "envelope.fill",
        "map": "map.fill", "message": "bubble.left.fill", "mic": "mic.fill",
        "money": "dollarsign.circle.fill", "moon": "moon.fill", "music": "music.note",
        "note": "note.text", "paint": "paintpalette.fill", "paperclip": "paperclip",
        "pen": "pencil", "people": "person.2.fill", "person": "person.fill",
        "phone": "phone.fill", "photo": "photo.fill", "pin": "pin.fill",
        "planet": "globe.europe.africa.fill", "play": "play.fill", "printer": "printer.fill",
        "robot": "cpu.fill", "rocket": "paperplane.fill", "school": "graduationcap.fill",
        "search": "magnifyingglass", "settings": "gearshape.fill", "shield": "shield.fill",
        "shop": "bag.fill", "smile": "face.smiling", "sparkles": "sparkles",
        "sun": "sun.max.fill", "tag": "tag.fill", "target": "target",
        "terminal": "terminal.fill", "tool": "wrench.and.screwdriver.fill", "trophy": "trophy.fill",
        "tv": "tv.fill", "user": "person.fill", "users": "person.2.fill",
        "video": "video.fill", "wallet": "creditcard.fill", "work": "briefcase.fill",
        "wrench": "wrench.and.screwdriver.fill", "zap": "bolt.fill",
    ]

    // MARK: - Chromium databases

    /// the profile folders Arc keeps its Chromium data in
    static func profiles(in directory: URL = dataDirectory) -> [URL] {
        let all = (try? FileManager.default.contentsOfDirectory(
            at: directory.appending(path: "User Data"), includingPropertiesForKeys: nil)) ?? []
        return all
            .filter {
                $0.lastPathComponent == "Default" || $0.lastPathComponent.hasPrefix("Profile ")
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func scalar(_ db: OpaquePointer, _ sql: String) -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int(statement, 0)) : 0
    }

    private static func blob(_ statement: OpaquePointer?, _ column: Int32) -> Data {
        guard let bytes = sqlite3_column_blob(statement, column) else { return Data() }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
    }

    /// Chromium counts microseconds from 1601-01-01
    private static func chromeDate(_ raw: Int64) -> Date {
        Date(timeIntervalSince1970: Double(raw) / 1_000_000 - 11_644_473_600)
    }

    // MARK: - Survey

    /// What there is to move, and how much of it. Counted without decrypting
    /// anything, so the picker can be specific before the keychain is touched.
    struct Survey {
        var directory: URL
        var sidebar: Result?
        var history = 0
        var cookies = 0
        var cookieSites = 0
        var logins = 0

        var spaces: Int { sidebar?.spaces.count ?? 0 }
        var tabs: Int { (sidebar?.tabCount ?? 0) - favourites }
        var folders: Int { sidebar?.folderCount ?? 0 }
        var favourites: Int { sidebar?.favouriteURLs.count ?? 0 }
        var archived: Int { sidebar?.archived.count ?? 0 }
        var isEmpty: Bool { sidebar == nil && history == 0 && cookies == 0 && logins == 0 }
    }

    static func survey(_ directory: URL = dataDirectory) -> Survey {
        var out = Survey(directory: directory, sidebar: read(from: directory))
        for profile in profiles(in: directory) {
            out.history += BrowserImport.withDatabase(at: profile.appending(path: "History")) {
                scalar($0, "SELECT count(*) FROM urls WHERE hidden = 0 AND last_visit_time > 0;")
            } ?? 0
            BrowserImport.withDatabase(at: profile.appending(path: "Cookies")) { db in
                out.cookies += scalar(db, "SELECT count(*) FROM cookies;")
                out.cookieSites += scalar(db, "SELECT count(DISTINCT host_key) FROM cookies;")
            }
            out.logins += BrowserImport.withDatabase(at: profile.appending(path: "Login Data")) {
                scalar($0, "SELECT count(*) FROM logins WHERE blacklisted_by_user = 0;")
            } ?? 0
        }
        return out
    }

    // MARK: - Cookies

    /// One profile's cookies, unsealed and shaped for a `WKHTTPCookieStore`.
    /// `key` comes from `ArcSecrets.key()`, which is where the user consents;
    /// a cookie that won't decrypt is dropped rather than written as rubbish.
    static func cookies(in profile: URL, key: Data, now: Date = Date()) -> CookieRead {
        BrowserImport.withDatabase(at: profile.appending(path: "Cookies")) { db in
            var read = CookieRead()
            var seen: Set<String> = []
            var statement: OpaquePointer?
            // unpartitioned rows first, then https — a site's cookie can exist
            // several times over, split by partition, scheme and port, and only
            // one of them can be the cookie Artemis stores
            let sql = """
                SELECT host_key, name, encrypted_value, value, path, expires_utc, is_secure,
                       is_httponly, has_expires, samesite
                FROM cookies
                ORDER BY (top_frame_site_key = '') DESC, source_scheme DESC;
                """
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return read }
            defer { sqlite3_finalize(statement) }

            while sqlite3_step(statement) == SQLITE_ROW {
                read.rows += 1
                guard let host = BrowserImport.text(statement, 0), !host.isEmpty,
                    let name = BrowserImport.text(statement, 1)
                else { continue }
                guard seen.insert("\(host)\u{1}\(name)\u{1}\(BrowserImport.text(statement, 4) ?? "")").inserted
                else { continue }
                let sealed = blob(statement, 2)
                let value: String
                if sealed.isEmpty {
                    value = BrowserImport.text(statement, 3) ?? ""
                } else if let unsealed = try? ArcSecrets.decrypt(sealed, key: key, host: host) {
                    value = unsealed
                    read.unsealed += 1
                } else {
                    continue
                }

                var properties: [HTTPCookiePropertyKey: Any] = [
                    .name: name, .value: value, .domain: host,
                    .path: BrowserImport.text(statement, 4) ?? "/",
                ]
                if sqlite3_column_int(statement, 6) != 0 { properties[.secure] = "TRUE" }
                if sqlite3_column_int(statement, 7) != 0 {
                    properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE"
                }
                if sqlite3_column_int(statement, 8) != 0 {
                    let expiry = chromeDate(sqlite3_column_int64(statement, 5))
                    guard expiry > now else { continue }
                    properties[.expires] = expiry
                }
                switch sqlite3_column_int(statement, 9) {
                case 1: properties[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteLax.rawValue
                case 2: properties[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteStrict.rawValue
                default: break
                }
                if let cookie = HTTPCookie(properties: properties) { read.cookies.append(cookie) }
            }
            return read
        } ?? CookieRead()
    }

    /// what one profile's cookie table gave up: the cookies themselves, the rows
    /// behind them, and how many needed the key. A profile with rows but nothing
    /// unsealed means the key was wrong, which is worth saying out loud
    struct CookieRead {
        var cookies: [HTTPCookie] = []
        var rows = 0
        var unsealed = 0
    }

    // MARK: - Saved passwords

    /// one saved login, decrypted, held only until it reaches the Keychain
    struct Login {
        var title: String
        var url: String
        var username: String
        var password: String
    }

    static func logins(in profile: URL, key: Data) -> [Login] {
        BrowserImport.withDatabase(at: profile.appending(path: "Login Data")) { db in
            var out: [Login] = []
            var statement: OpaquePointer?
            let sql = """
                SELECT origin_url, username_value, password_value, signon_realm FROM logins
                WHERE blacklisted_by_user = 0;
                """
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return out }
            defer { sqlite3_finalize(statement) }

            while sqlite3_step(statement) == SQLITE_ROW {
                let origin = BrowserImport.text(statement, 0) ?? ""
                let sealed = blob(statement, 2)
                guard !sealed.isEmpty,
                    let password = try? ArcSecrets.decrypt(sealed, key: key), !password.isEmpty
                else { continue }
                let address = origin.isEmpty ? (BrowserImport.text(statement, 3) ?? "") : origin
                out.append(
                    Login(
                        title: URL(string: address)?.host() ?? address, url: address,
                        username: BrowserImport.text(statement, 1) ?? "", password: password))
            }
            return out
        } ?? []
    }
}
