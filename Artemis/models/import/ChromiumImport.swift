// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import Foundation

/// Chrome, Edge, Brave, Vivaldi, Opera, Dia and the other Chromium browsers.
nonisolated enum ChromiumImport {
    static func detect(home: URL) -> [ImportedBrowser] {
        let support = home.appending(path: "Library/Application Support")
        var claimed: Set<String> = [
            support.appending(path: "Arc/User Data").path, home.appending(path: "Library/\(YabImport.chromium)").path,
        ]
        var found: [ImportedBrowser] = []
        for entry in table {
            let roots = entry.roots.map { support.appending(path: $0) }
            claimed.formUnion(roots.map(\.path))
            let marker = entry.vendor == .opera ? "Preferences" : "Local State"
            if let root = roots.first(where: { exists($0.appending(path: marker)) }) {
                found.append(browser(entry, root: root))
            }
        }
        return found + scan(support, claimed: claimed)
    }

    static func unlock(_ browser: ImportedBrowser, key: Data) -> ImportedBrowser {
        let entry =
            table.first { $0.bundleID == browser.bundleID }
            ?? Entry(browser.name, browser.bundleID, [], [], family: browser.family)
        let cards = value(json(browser.root.appending(path: "Local State")), "profile.info_cache") as? [String: Any]
        var out = browser
        for i in out.profiles.indices where !out.profiles[i].locked.isEmpty {
            fill(&out.profiles[i], entry, card: cards?[out.profiles[i].key] as? [String: Any], key: key)
        }
        return out
    }

    // MARK: - Browsers

    private enum Vendor { case upstream, vivaldi, opera }

    private struct Entry {
        let name: String
        let bundleID: String
        /// under Application Support; the first that exists wins
        let roots: [String]
        let keychain: [KeychainItem]
        let vendor: Vendor
        let family: Family

        init(
            _ name: String, _ bundleID: String, _ roots: [String], _ keychain: [KeychainItem],
            vendor: Vendor = .upstream, family: Family = .chromium
        ) {
            (self.name, self.bundleID, self.roots, self.keychain) = (name, bundleID, roots, keychain)
            (self.vendor, self.family) = (vendor, family)
        }
    }

    private static func storage(_ accounts: String...) -> [KeychainItem] {
        accounts.map { KeychainItem(service: "\($0) Safe Storage", account: $0) }
    }

    private static let table: [Entry] = [
        Entry("Chrome", "com.google.Chrome", ["Google/Chrome"], storage("Chrome")),
        Entry("Chrome Beta", "com.google.Chrome.beta", ["Google/Chrome Beta"], storage("Chrome")),
        Entry("Chrome Dev", "com.google.Chrome.dev", ["Google/Chrome Dev"], storage("Chrome")),
        Entry("Chrome Canary", "com.google.Chrome.canary", ["Google/Chrome Canary"], storage("Chrome")),
        Entry("Chromium", "org.chromium.Chromium", ["Chromium"], storage("Chromium")),
        Entry("Brave", "com.brave.Browser", ["BraveSoftware/Brave-Browser"], storage("Brave")),
        Entry("Brave Beta", "com.brave.Browser.beta", ["BraveSoftware/Brave-Browser-Beta"], storage("Brave")),
        Entry("Brave Nightly", "com.brave.Browser.nightly", ["BraveSoftware/Brave-Browser-Nightly"], storage("Brave")),
        Entry("Brave Origin", "com.brave.Browser.origin", ["BraveSoftware/Brave-Origin"], storage("Brave")),
        Entry("Edge", "com.microsoft.edgemac", ["Microsoft Edge"], storage("Microsoft Edge")),
        Entry("Edge Beta", "com.microsoft.edgemac.Beta", ["Microsoft Edge Beta"], storage("Microsoft Edge")),
        Entry("Edge Dev", "com.microsoft.edgemac.Dev", ["Microsoft Edge Dev"], storage("Microsoft Edge")),
        Entry("Edge Canary", "com.microsoft.edgemac.Canary", ["Microsoft Edge Canary"], storage("Microsoft Edge")),
        Entry("Vivaldi", "com.vivaldi.Vivaldi", ["Vivaldi"], storage("Vivaldi", "Chrome"), vendor: .vivaldi),
        Entry(
            "Vivaldi Snapshot", "com.vivaldi.Vivaldi.snapshot", ["Vivaldi Snapshot"], storage("Vivaldi", "Chrome"),
            vendor: .vivaldi),
        Entry("Opera", "com.operasoftware.Opera", ["com.operasoftware.Opera"], storage("Opera"), vendor: .opera),
        Entry(
            "Opera Beta", "com.operasoftware.OperaNext", ["com.operasoftware.OperaNext"], storage("Opera"),
            vendor: .opera),
        Entry(
            "Opera Developer", "com.operasoftware.OperaDeveloper", ["com.operasoftware.OperaDeveloper"],
            storage("Opera"), vendor: .opera),
        Entry("Opera GX", "com.operasoftware.OperaGX", ["com.operasoftware.OperaGX"], storage("Opera"), vendor: .opera),
        Entry(
            "Opera Air", "com.operasoftware.OperaAir", ["com.operasoftware.OperaAir"], storage("Opera"), vendor: .opera),
        Entry("Comet", "ai.perplexity.comet", ["Comet", "Perplexity/Comet", "ai.perplexity.comet"], []),
        Entry(
            "ChatGPT Atlas", "com.openai.atlas", ["com.openai.atlas/browser-data/host", "OpenAI/ChatGPT Atlas"],
            storage("ChatGPT", "Aura")),
        Entry(
            "Helium", "net.imput.helium", ["net.imput.helium"],
            [KeychainItem(service: "Helium Storage Key", account: "Helium")]),
        Entry("Thorium", "org.chromium.Thorium", ["Thorium"], storage("Chromium")),
        Entry("Yandex", "ru.yandex.desktop.yandex-browser", ["Yandex/YandexBrowser"], storage("Yandex")),
        Entry("Whale", "com.naver.Whale", ["Naver/Whale"], storage("Whale")),
        Entry("Dia", "company.thebrowser.dia", ["Dia/User Data"], storage("Dia"), family: .dia),
        Entry("DiaDev", "company.thebrowser.diadev", ["DiaDev/User Data"], storage("DiaDev"), family: .dia),
    ]

    /// TCC-guarded folders the scan never lists
    private static let guarded: Set<String> = [
        "AddressBook", "CallHistoryDB", "CallHistoryTransactions", "Knowledge", "MobileSync",
    ]

    /// Any other user-data dir up to three folders deep: a `Local State` beside a
    /// `Default` or `Profile *` folder. Its key is found by name.
    private static func scan(_ support: URL, claimed: Set<String>) -> [ImportedBrowser] {
        var found: [ImportedBrowser] = []
        func walk(_ folder: URL, depth: Int) {
            for name in children(folder) {
                let dir = folder.appending(path: name)
                guard !claimed.contains(dir.path), isFolder(dir),
                    depth > 0 || !(name.hasPrefix("com.apple.") || guarded.contains(name))
                else { continue }
                let names = children(dir)
                if names.contains("Local State"), names.contains(where: { $0 == "Default" || $0.hasPrefix("Profile ") }) {
                    let path = String(dir.path.dropFirst(support.path.count + 1))
                    let label = String(path.prefix { $0 != "/" })
                    found.append(browser(Entry(label, path, [], []), root: dir))
                } else if depth < 2 {
                    walk(dir, depth: depth + 1)
                }
            }
        }
        walk(support, depth: 0)
        return found
    }

    private static func browser(_ entry: Entry, root: URL) -> ImportedBrowser {
        let state = json(root.appending(path: "Local State"))
        let cards = value(state, "profile.info_cache") as? [String: Any] ?? [:]
        var profiles = entry.vendor == .opera ? opera(entry, root) : listed(entry, root, state, cards)
        profiles.removeAll { profile in
            !["Preferences", "History", "Bookmarks", "Sessions"].contains { exists(profile.folder.appending(path: $0)) }
        }
        for i in profiles.indices {
            let folder = profiles[i].folder
            let history = folder.appending(path: "History")
            if exists(history) {
                profiles[i].history = .chromium(history)
                profiles[i].historyCount = ChromiumData.historyCount(history)
            }
            if let jar = ChromiumData.cookieFile(in: folder) {
                profiles[i].cookies = [.chromium(jar)]
                profiles[i].cookieCount = ChromiumData.cookieCount(jar)
            }
            let logins = ChromiumData.loginFiles(in: folder)
            if !logins.isEmpty {
                profiles[i].logins = .chromium(logins)
                profiles[i].loginCount = ChromiumData.loginCount(logins)
            }
            fill(&profiles[i], entry, card: cards[profiles[i].key] as? [String: Any], key: nil)
        }
        return ImportedBrowser(
            name: entry.name, bundleID: entry.bundleID, family: entry.family, root: root, profiles: profiles,
            keychain: entry.keychain)
    }

    // MARK: - Profiles

    /// `profile.info_cache` in `profile.profiles_order`, the rest after it
    private static func listed(_ entry: Entry, _ root: URL, _ state: Any?, _ cards: [String: Any])
        -> [ImportedProfile]
    {
        var keys = (value(state, "profile.profiles_order") as? [String] ?? []).filter { cards[$0] != nil }
        keys += cards.keys.filter { !keys.contains($0) }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return (keys.isEmpty ? ["Default"] : keys).map { key in
            let card = cards[key] as? [String: Any] ?? [:]
            var name = nonEmpty(card["name"]) ?? key
            if card["is_using_default_name"] as? Bool == true, let gaia = nonEmpty(card["gaia_name"]) { name = gaia }
            return ImportedProfile(
                id: Importers.stableID("\(entry.bundleID)/profile/\(key)"), key: key, name: name,
                icon: avatar(card["avatar_icon"] as? String), isDefault: key == "Default",
                folder: root.appending(path: key))
        }
    }

    /// Opera's root is its default profile; side profiles live in `_side_profiles/<id>`
    private static func opera(_ entry: Entry, _ root: URL) -> [ImportedProfile] {
        let sides = root.appending(path: "_side_profiles")
        let ids = children(sides).filter { isFolder(sides.appending(path: $0)) }
        return [
            ImportedProfile(
                id: Importers.stableID("\(entry.bundleID)/profile/Default"), key: "Default", name: entry.name,
                isDefault: true, folder: root)
        ]
            + ids.enumerated().map { n, id in
                let folder = sides.appending(path: id)
                let card = json(folder.appending(path: "\(id)_sideprofile.json"))
                    ?? json(sides.appending(path: "\(id)_sideprofile.json"))
                return ImportedProfile(
                    id: Importers.stableID("\(entry.bundleID)/profile/_side_profiles/\(id)"),
                    key: "_side_profiles/\(id)", name: nonEmpty(value(card, "side-profile-name")) ?? "\(entry.name) \(n + 2)",
                    folder: folder)
            }
    }

    /// Chromium's avatar index → SF Symbol
    private static let avatars = Array(repeating: "person.crop.circle", count: 8) + [
        "eyeglasses", "bolt", "figure.run", "briefcase", "figure.martial.arts", "sparkles", "face.smiling",
        "camera.macro", "fork.knife", "soccerball", "takeoutbag.and.cup.and.straw", "cat", "birthday.cake", "dog",
        "figure.equestrian.sports", "wineglass", "music.note", "cloud.sun", "person.crop.circle", "cat", "dog",
        "flame", "pawprint", "pawprint", "pawprint", "pawprint", "bird", "ladybug", "hare", "sparkles", "basketball",
        "bicycle", "bird", "fork.knife", "football", "takeoutbag.and.cup.and.straw", "sunglasses", "fish",
        "gamecontroller", "opticaldisc", "leaf", "cup.and.saucer", "snowflake", "drop", "carrot", "fork.knife",
        "fork.knife", "fork.knife",
    ]

    /// `chrome://theme/IDR_PROFILE_AVATAR_<n>`
    private static func avatar(_ icon: String?) -> String? {
        guard let icon, let marker = icon.range(of: "IDR_PROFILE_AVATAR_"), let n = Int(icon[marker.upperBound...]),
            avatars.indices.contains(n)
        else { return nil }
        return avatars[n]
    }

    /// the first set of the theme colours, else the profile's highlight; ARGB ints
    private static func colors(_ prefs: Any?, _ card: [String: Any]?) -> [RGBA] {
        let picks: [(Any?, needsAlpha: Bool)] = [
            (value(prefs, "browser.theme.user_color2"), true), (value(prefs, "browser.theme.user_color"), true),
            (value(prefs, "autogenerated.theme.color"), false), (card?["profile_highlight_color"], false),
        ]
        for (raw, needsAlpha) in picks {
            guard let number = raw as? NSNumber else { continue }
            let argb = UInt32(truncatingIfNeeded: number.int64Value)
            if needsAlpha, argb >> 24 == 0 { continue }
            let channel = { (shift: UInt32) in Double(argb >> shift & 0xFF) / 255 }
            return [RGBA(channel(16), channel(8), channel(0), channel(24))]
        }
        return []
    }

    // MARK: - Spaces, archive, bookmarks

    /// what `unlock` re-reads; leaves `locked` holding what still needs the key
    private static func fill(_ profile: inout ImportedProfile, _ entry: Entry, card: [String: Any]?, key: Data?) {
        profile.locked = []
        let namespace = "\(entry.bundleID)/\(profile.key)"
        if entry.family == .dia {
            if let tabs = DiaTabs.read(profile: profile.folder, key: key, namespace: namespace) {
                (profile.spaces, profile.favourites) = (tabs.spaces, tabs.favourites)
            } else {
                profile.locked = [.spaces, .favourites]
            }
        } else {
            let prefs = json(profile.folder.appending(path: "Preferences"))
            let palette = colors(prefs, card)
            profile.spaces = []
            switch ChromiumSession.pick(profile.folder, .session, key: key) {
            case .commands(let commands, _):
                let session = ChromiumSession.replay(commands, dialect: entry.vendor == .vivaldi ? .vivaldi : .upstream)
                profile.spaces = spaces(
                    session, profile, namespace: namespace, colors: palette,
                    workspaces: entry.vendor == .vivaldi ? workspaces(prefs) : [])
            case .sealed:
                profile.locked.insert(.spaces)
            case .none:
                let pinned = (value(prefs, "pinned_tabs") as? [[String: Any]] ?? []).compactMap { pin in
                    nonEmpty(pin["url"]).map { ImportedItem.tab(ImportedTab(url: $0)) }
                }
                if !pinned.isEmpty {
                    profile.spaces = [
                        ImportedSpace(
                            id: Importers.stableID("\(namespace)/space/session"), name: profile.name, colors: palette,
                            pinned: pinned)
                    ]
                }
            }
            profile.archive = []
            switch ChromiumSession.pick(profile.folder, .tabs, key: key) {
            case .commands(let commands, let written):
                profile.archive = ChromiumSession.closed(commands, written: written).map { [name = profile.name] tab in
                    ImportedArchive(url: tab.url, title: tab.title ?? tab.url, archivedAt: tab.closedAt, spaceName: name)
                }
            case .sealed:
                profile.locked.insert(.archive)
            case .none:
                break
            }
        }
        let read = bookmarks(profile.folder, key: key)
        profile.bookmarks = read.items
        if read.locked { profile.locked.insert(.bookmarks) }
    }

    private struct Strip {
        var tab: ImportedTab
        var pinned: Bool
        var group: String?
        var split: String?
        /// the pane's place in its split
        var order: Int
        var extras: [String: String]
    }

    /// The untitled windows merge into the profile's space; each titled window,
    /// and each Vivaldi workspace, is a space of its own. Empty spaces are dropped.
    private static func spaces(
        _ session: ChromiumSession.Session, _ profile: ImportedProfile, namespace: String, colors: [RGBA],
        workspaces: [(id: Int64, name: String, emoji: String?)]
    ) -> [ImportedSpace] {
        var keys = ["session"]
        var names = ["session": profile.name]
        var icons: [String: String] = [:]
        var windowSpace: [Int32: String] = [:]
        for window in session.windows {
            guard let title = window.title, !title.isEmpty else { continue }
            var name = title
            var copy = 1
            while names["window/\(name)"] != nil {
                copy += 1
                name = "\(title) #\(copy)"
            }
            windowSpace[window.id] = "window/\(name)"
            keys.append("window/\(name)")
            names["window/\(name)"] = name
        }
        for workspace in workspaces where names["workspace/\(workspace.id)"] == nil {
            keys.append("workspace/\(workspace.id)")
            names["workspace/\(workspace.id)"] = workspace.name
            icons["workspace/\(workspace.id)"] = workspace.emoji
        }

        var groups = session.groups
        var splits = session.splits
        var strips: [String: [Strip]] = [:]
        for window in session.windows {
            for tab in window.tabs {
                var space = windowSpace[window.id] ?? "session"
                var strip = Strip(
                    tab: ImportedTab(url: tab.url, title: tab.title), pinned: tab.pinned,
                    group: tab.group, split: tab.split, order: strips[space]?.count ?? 0, extras: tab.extras)
                if let ext = tab.extData.flatMap({ try? JSONSerialization.jsonObject(with: Data($0.utf8)) })
                    as? [String: Any]
                {
                    if nonEmpty(ext["panelId"]) != nil || ext["panelId"] is NSNumber { continue }
                    if let id = (ext["workspaceId"] as? NSNumber).flatMap({ Int64(exactly: $0.doubleValue.rounded()) }) {
                        space = workspaces.contains { $0.id == id } ? "workspace/\(id)" : "session"
                        strip.order = strips[space]?.count ?? 0
                    }
                    strip.tab.name = nonEmpty(ext["fixedTitle"])
                    if let stack = nonEmpty(ext["group"]) {
                        strip.group = "vivaldi/\(stack)"
                        if groups[strip.group!] == nil {
                            groups[strip.group!] = .init(title: nonEmpty(ext["fixedGroupTitle"]) ?? "", collapsed: false)
                        }
                    }
                    if let tiling = ext["tiling"] as? [String: Any], let id = nonEmpty(tiling["id"]) {
                        strip.split = "vivaldi/\(id)"
                        strip.order = (tiling["index"] as? NSNumber)?.intValue ?? 0
                        splits[strip.split!] = tiling["layout"] as? String == "row" ? .rows : .columns
                    }
                }
                strips[space, default: []].append(strip)
            }
        }

        return keys.compactMap { key in
            let strip = strips[key] ?? []
            let space = ImportedSpace(
                id: Importers.stableID("\(namespace)/space/\(key)"), name: names[key]!, icon: icons[key], colors: colors,
                pinned: items(strip.filter(\.pinned), groups, splits),
                today: items(strip.filter { !$0.pinned }, groups, splits))
            return space.pinned.isEmpty && space.today.isEmpty ? nil : space
        }
    }

    /// `vivaldi.workspaces.list`; ids are ms-epoch doubles
    private static func workspaces(_ prefs: Any?) -> [(id: Int64, name: String, emoji: String?)] {
        (value(prefs, "vivaldi.workspaces.list") as? [[String: Any]] ?? []).compactMap { workspace in
            guard let id = (workspace["id"] as? NSNumber).flatMap({ Int64(exactly: $0.doubleValue.rounded()) }) else {
                return nil
            }
            return (id, nonEmpty(workspace["name"]) ?? "Workspace", nonEmpty(workspace["emoji"]))
        }
    }

    /// Splits gather at their first tab, then groups gather their panes into
    /// folders, then Brave's tree nests what is left.
    private static func items(
        _ strip: [Strip], _ groups: [String: ChromiumSession.Group], _ splits: [String: SplitOrientation]
    ) -> [ImportedItem] {
        var panes: [[Strip]] = []
        var paneAt: [String: Int] = [:]
        for tab in strip {
            if let split = tab.split, let at = paneAt[split] {
                panes[at].append(tab)
                continue
            }
            if let split = tab.split { paneAt[split] = panes.count }
            panes.append([tab])
        }
        var units: [(head: Strip, items: [ImportedItem])] = []
        var unitAt: [String: Int] = [:]
        for pane in panes {
            let item: ImportedItem =
                pane.count == 1
                ? .tab(pane[0].tab)
                : .split(pane.sorted { $0.order < $1.order }.map(\.tab), splits[pane[0].split!] ?? .columns)
            if let group = pane[0].group, let at = unitAt[group] {
                units[at].items.append(item)
                continue
            }
            if let group = pane[0].group { unitAt[group] = units.count }
            units.append((pane[0], [item]))
        }
        let items = units.map { unit -> ImportedItem in
            guard let group = unit.head.group else { return unit.items[0] }
            return .folder(
                name: nonEmpty(groups[group]?.title) ?? "Group", expanded: groups[group]?.collapsed != true, unit.items)
        }
        return tree(units.map(\.head), items)
    }

    /// Brave's tree tabs: a unit whose head names a parent node nests in a folder
    /// named after that parent, the parent first
    private static func tree(_ heads: [Strip], _ items: [ImportedItem]) -> [ImportedItem] {
        var nodes: [String: Int] = [:]
        for (at, head) in heads.enumerated() {
            if let node = nonEmpty(head.extras["brave_tree_node_id"]), nodes[node] == nil { nodes[node] = at }
        }
        var parent = heads.map { $0.extras["brave_tree_parent_node_id"].flatMap { nodes[$0] } }
        for at in parent.indices {
            var up = parent[at]
            for _ in heads.indices {
                guard let link = up else { break }
                if link == at {
                    parent[at] = nil
                    break
                }
                up = parent[link]
            }
        }
        var children = Array(repeating: [Int](), count: heads.count)
        for (at, link) in parent.enumerated() { if let link { children[link].append(at) } }
        func build(_ at: Int) -> ImportedItem {
            guard !children[at].isEmpty else { return items[at] }
            let tab = heads[at].tab
            return .folder(
                name: tab.name ?? tab.title ?? tab.url, expanded: heads[at].extras["brave_tree_node_collapsed"] != "1",
                [items[at]] + children[at].map(build))
        }
        return parent.indices.filter { parent[$0] == nil }.map(build)
    }

    /// (`Bookmarks`, `EncryptedBookmarks2`), then the account pair; the twin is read
    /// only when the cleartext is missing or more than 60 s older
    private static func bookmarks(_ folder: URL, key: Data?) -> (items: [ImportedItem], locked: Bool) {
        var items: [ImportedItem] = []
        var locked = false
        for (clear, twin) in [("Bookmarks", "EncryptedBookmarks2"), ("AccountBookmarks", "EncryptedAccountBookmarks2")] {
            let plain = folder.appending(path: clear)
            let sealed = folder.appending(path: twin)
            let parse = { (data: Data?) in
                value(data.flatMap { try? JSONSerialization.jsonObject(with: $0) }, "roots") as? [String: Any]
            }
            var roots = parse(try? Data(contentsOf: plain))
            if let sealedAt = ChromiumData.modified(sealed),
                ChromiumData.modified(plain).map({ $0 < sealedAt - 60 }) ?? true
            {
                guard let key else {
                    locked = true
                    continue
                }
                roots = parse((try? Data(contentsOf: sealed)).flatMap { BrowserKeychain.open($0, key: key) }) ?? roots
            }
            for (root, fallback) in [
                ("bookmark_bar", "Bookmarks Bar"), ("other", "Other Bookmarks"), ("synced", "Mobile Bookmarks"),
            ] {
                guard let node = roots?[root] as? [String: Any] else { continue }
                var seen: Set<String> = []
                let children = bookmarkItems(node, &seen)
                if !children.isEmpty {
                    items.append(.folder(name: nonEmpty(node["name"]) ?? fallback, expanded: false, children))
                }
            }
        }
        return (items, locked)
    }

    private static func bookmarkItems(_ node: [String: Any], _ seen: inout Set<String>) -> [ImportedItem] {
        var out: [ImportedItem] = []
        for child in node["children"] as? [[String: Any]] ?? [] {
            if child["type"] as? String == "folder" {
                out.append(.folder(name: child["name"] as? String ?? "", expanded: false, bookmarkItems(child, &seen)))
            } else if let url = nonEmpty(child["url"]), seen.insert(url).inserted {
                out.append(.tab(ImportedTab(url: url, title: nonEmpty(child["name"]))))
            }
        }
        return out
    }

    // MARK: - Files

    private static func json(_ file: URL) -> Any? {
        (try? Data(contentsOf: file)).flatMap { try? JSONSerialization.jsonObject(with: $0) }
    }

    /// a dotted path through nested dictionaries
    private static func value(_ json: Any?, _ path: String) -> Any? {
        path.split(separator: ".").reduce(json) { ($0 as? [String: Any])?[String($1)] }
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        (value as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func exists(_ file: URL) -> Bool {
        FileManager.default.fileExists(atPath: file.path)
    }

    private static func isFolder(_ url: URL) -> Bool {
        var folder: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &folder) && folder.boolValue
    }

    private static func children(_ folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}
