// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import AppKit
import Foundation

/// Arc's sidebar file, spaces plus a flat pool of items linked by parent/child
/// ids, read as one `ImportedBrowser`
nonisolated enum ArcImport {
    static let bundleID = "company.thebrowser.Browser"
    static let keychain = [
        KeychainItem(service: "Arc Safe Storage", account: "Arc"), KeychainItem(service: "Arc Safe Storage", account: nil),
        KeychainItem(service: "Arc", account: "Arc"),
    ]

    // MARK: - Finding Arc

    static var dataDirectory: URL { URL.homeDirectory.appending(path: "Library/Application Support/Arc") }

    static func isReadable(_ directory: URL = dataDirectory) -> Bool {
        FileManager.default.isReadableFile(
            atPath: directory.appending(path: "StorableSidebar.json").path)
    }

    // MARK: - Reading

    static func detect(home: URL) -> [ImportedBrowser] {
        read(root: home.appending(path: "Library/Application Support/Arc")).map { [$0] } ?? []
    }

    /// Arc's folder as one browser: Default, plus each Arc profile that owns a space or top
    /// apps. Default also takes the other profiles' passwords; their cookies and history stay, named in `leftBehind`.
    /// Without a readable sidebar, Default still offers its history, cookies and passwords.
    static func read(root: URL) -> ImportedBrowser? {
        let sidebar = (try? Data(contentsOf: root.appending(path: "StorableSidebar.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let containers = (sidebar?["sidebar"] as? [String: Any])?["containers"] as? [[String: Any]]
        let container = containers?.first(where: { $0["spaces"] != nil }) ?? [:]
        guard !container.isEmpty || FileManager.default.fileExists(atPath: root.appending(path: "User Data/Default").path)
        else { return nil }
        let items = pairs(container["items"] as? [Any] ?? [])
        let pool = Dictionary(items, uniquingKeysWith: { _, last in last })

        var folders = ["Default"]
        var machines: [String: String] = [:]
        var spaces: [String: [ImportedSpace]] = [:]
        var favourites: [String: [ImportedTab]] = [:]
        var spaceOwners: [String: (name: String, folder: String)] = [:]
        var order: [UUID] = []
        func own(_ profile: [String: Any]?) -> String {
            guard let profile, profile["default"] == nil, let custom = payload(profile, "custom"),
                let folder = custom["directoryBasename"] as? String
            else { return "Default" }
            if machines[folder] == nil { machines[folder] = custom["machineID"] as? String ?? "" }
            if !folders.contains(folder) { folders.append(folder) }
            return folder
        }

        for (arcID, space) in pairs(container["spaces"] as? [Any] ?? []) {
            let name = (space["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Space"
            let folder = own(space["profile"] as? [String: Any])
            let sections = sectionIDs(space)
            var walk = Walk(pool: pool)
            let (colors, grain) = palette(space)
            let id = Importers.stableID("arc-space/\(arcID)")
            order.append(id)
            spaces[folder, default: []].append(
                ImportedSpace(
                    id: id, name: name, icon: icon(space), colors: colors,
                    grain: grain, pinned: walk.items(under: sections.pinned),
                    today: walk.items(under: sections.unpinned)))
            spaceOwners[arcID] = (name, folder)
        }
        for (id, item) in items {
            guard let type = (item["data"] as? [String: Any])?["itemContainer"] as? [String: Any],
                let owner = (type["containerType"] as? [String: Any]).flatMap({ payload($0, "topApps") })
            else { continue }
            var walk = Walk(pool: pool)
            let tabs = Walk.tabs(in: walk.items(under: id))
            guard !tabs.isEmpty else { continue }
            favourites[own(owner), default: []] += tabs
        }

        var archive: [String: [ImportedArchive]] = [:]
        if let data = try? Data(contentsOf: root.appending(path: "StorableArchiveItems.json")),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            for (_, item) in pairs(json["items"] as? [Any] ?? []) {
                guard let sidebar = item["sidebarItem"] as? [String: Any],
                    let info = (sidebar["data"] as? [String: Any])?["tab"] as? [String: Any],
                    let raw = info["savedURL"] as? String
                else { continue }
                let source = ((item["source"] as? [String: Any])?["space"] as? [String: Any])?["_0"] as? String
                let space = source.flatMap { spaceOwners[$0] }
                archive[space?.folder ?? "Default", default: []].append(
                    ImportedArchive(
                        url: raw,
                        title: (sidebar["title"] as? String) ?? (info["savedTitle"] as? String)
                            ?? URL(string: raw)?.host() ?? raw,
                        archivedAt: (item["archivedAt"] as? Double).map(Date.init(timeIntervalSinceReferenceDate:)) ?? Date(),
                        spaceName: space?.name ?? "Arc"))
            }
        }

        let names = profileNames(in: root)
        let data = root.appending(path: "User Data")
        let rowless = profiles(in: root).filter { !folders.contains($0.lastPathComponent) }
        let rows = folders.map { folder -> ImportedProfile in
            let directory = data.appending(path: folder)
            let history = directory.appending(path: "History")
            let cookies = ChromiumData.cookieFile(in: directory)
            let logins = ChromiumData.loginFiles(in: directory)
                + (folder == "Default" ? rowless.flatMap(ChromiumData.loginFiles(in:)) : [])
            let hasHistory = FileManager.default.fileExists(atPath: history.path)
            return ImportedProfile(
                id: Importers.stableID(
                    folder == "Default" ? "arc-profile/Default" : "arc-profile/\(machines[folder] ?? "")/\(folder)"),
                key: folder, name: names[folder] ?? folder, isDefault: folder == "Default", folder: directory,
                spaces: spaces[folder] ?? [], favourites: favourites[folder] ?? [], bookmarks: [],
                archive: archive[folder] ?? [], history: hasHistory ? .chromium(history) : nil,
                cookies: cookies.map { [.chromium($0)] } ?? [], logins: logins.isEmpty ? nil : .chromium(logins),
                historyCount: hasHistory ? ChromiumData.historyCount(history) : 0,
                cookieCount: cookies.map(ChromiumData.cookieCount) ?? 0, loginCount: ChromiumData.loginCount(logins))
        }
        let leftBehind = rowless.filter {
            ChromiumData.cookieFile(in: $0) != nil || FileManager.default.fileExists(atPath: $0.appending(path: "History").path)
        }
        return ImportedBrowser(
            name: "Arc", bundleID: bundleID, family: .arc, root: root, profiles: rows, keychain: keychain,
            spaceOrder: order, leftBehind: leftBehind.map { names[$0.lastPathComponent] ?? $0.lastPathComponent })
    }

    /// Walks Arc's item pool under one container into importer items.
    private struct Walk {
        let pool: [String: [String: Any]]
        /// containers already walked: a damaged file can list a folder under itself
        var walked: Set<String> = []

        mutating func items(under id: String?) -> [ImportedItem] {
            guard let id, walked.insert(id).inserted, let node = pool[id] else { return [] }
            var out: [ImportedItem] = []
            for childID in node["childrenIds"] as? [String] ?? [] {
                guard let child = pool[childID], let data = child["data"] as? [String: Any] else { continue }
                if data["tab"] != nil {
                    if let tab = Self.tab(child) { out.append(.tab(tab)) }
                } else if data["list"] != nil {
                    guard !walked.contains(childID) else { continue }
                    out.append(.folder(name: child["title"] as? String ?? "Folder", expanded: true, items(under: childID)))
                } else if let info = data["splitView"] as? [String: Any] {
                    let panes = (child["childrenIds"] as? [String] ?? []).compactMap { pool[$0].flatMap(Self.tab) }
                    out.append(.split(panes, info["layoutOrientation"] as? String == "vertical" ? .rows : .columns))
                }
            }
            return out
        }

        static func tabs(in items: [ImportedItem]) -> [ImportedTab] {
            items.flatMap { item -> [ImportedTab] in
                switch item {
                case .tab(let tab): [tab]
                case .folder(_, _, let children): tabs(in: children)
                case .split(let panes, _): panes
                }
            }
        }

        private static func tab(_ item: [String: Any]) -> ImportedTab? {
            guard let info = (item["data"] as? [String: Any])?["tab"] as? [String: Any],
                let raw = info["savedURL"] as? String
            else { return nil }
            return ImportedTab(
                url: raw, title: info["savedTitle"] as? String,
                name: (item["title"] as? String).flatMap { $0.isEmpty ? nil : $0 })
        }
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

    /// the names Arc shows for its profiles, from Chromium's `Local State`
    private static func profileNames(in directory: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: directory.appending(path: "User Data/Local State")),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let cache = (root["profile"] as? [String: Any])?["info_cache"] as? [String: [String: Any]]
        else { return [:] }
        return cache.compactMapValues { ($0["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } }
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

    /// a space's theme colours and grain, as Arc stored them
    private static func palette(_ space: [String: Any]) -> (colors: [RGBA], grain: Double) {
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
        let modifiers = style?["modifiers"] as? [String: Any]
        return (colors, (modifiers?["noiseFactor"] as? Double) ?? 0)
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
        if let code = type["emoji"] as? Int,
            let scalar = UInt32(exactly: code).flatMap(UnicodeScalar.init)
        {
            return String(Character(scalar))
        }
        guard let name = type["icon"] as? String else { return "square.stack" }
        if let symbol = symbols[name] { return symbol }
        return NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil ? name : "square.stack"
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
}
