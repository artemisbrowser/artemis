// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import Foundation
import SQLite3

/// Firefox, LibreWolf, Waterfox, Mullvad, Zen and Floorp.
nonisolated enum GeckoImport {
    /// detected by data root under Application Support; `bundleID` names every namespace, whichever build is installed
    private static let browsers: [(name: String, bundleID: String, root: String, flavour: GeckoSession.Flavour)] = [
        ("Firefox", "org.mozilla.firefox", "Firefox", .firefox),
        ("Zen", "app.zen-browser.zen", "zen", .zen),
        ("Floorp", "app.floorp.Floorp", "Floorp", .floorp),
        ("LibreWolf", "net.librewolf.librewolf", "librewolf", .firefox),
        ("Waterfox", "net.waterfox.waterfox", "Waterfox", .firefox),
        ("Mullvad Browser", "net.mullvad.mullvadbrowser", "MullvadBrowser", .firefox),
    ]

    /// other builds sharing a data root, for the icon
    private static let aliases: [String: [String]] = [
        "org.mozilla.firefox": ["org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly"],
        "app.zen-browser.zen": ["org.mozilla.com.zen.browser"],
        "app.floorp.Floorp": ["one.ablaze.floorp"],
        "net.librewolf.librewolf": ["io.gitlab.librewolf-community.librewolf"],
        "net.waterfox.waterfox": ["org.waterfoxproject.waterfox"],
    ]

    /// Firefox's profile-manager avatars
    private static let avatars = [
        "barbell": "dumbbell.fill", "bike": "bicycle", "book": "book.fill", "briefcase": "briefcase.fill",
        "canvas": "paintpalette.fill", "craft": "scissors", "default-favicon": "globe", "diamond": "diamond.fill",
        "flower": "camera.macro", "folder": "folder.fill", "hammer": "hammer.fill", "heart": "heart.fill",
        "heart-rate": "waveform.path.ecg", "history": "clock.arrow.circlepath", "leaf": "leaf.fill",
        "lightbulb": "lightbulb.fill", "makeup": "sparkles", "message": "message.fill", "musical-note": "music.note",
        "palette": "paintpalette.fill", "paw-print": "pawprint.fill", "plane": "airplane", "present": "gift.fill",
        "shopping": "cart.fill", "soccer": "soccerball", "sparkle-single": "sparkle", "star": "star.fill",
        "video-game-controller": "gamecontroller.fill",
    ]

    static func detect(home: URL) -> [ImportedBrowser] {
        let support = home.appending(path: "Library/Application Support")
        return browsers.compactMap { browser in
            let root = support.appending(path: browser.root)
            guard let ini = try? String(contentsOf: root.appending(path: "profiles.ini"), encoding: .utf8) else {
                return nil
            }
            let profiles = found(ini, root: root).flatMap { found in
                let key = found.folder.lastPathComponent
                let layout = GeckoSession.layout(
                    browser.flavour, folder: found.folder, name: found.name,
                    namespace: "\(browser.bundleID)/\(key)/space/", theme: found.theme)
                return profiles(found, key: key, layout: layout, of: browser)
            }
            guard !profiles.isEmpty else { return nil }
            return ImportedBrowser(
                name: browser.name, bundleID: browser.bundleID, family: .gecko, root: root, profiles: profiles,
                aliases: aliases[browser.bundleID] ?? [])
        }
    }

    // MARK: - Profiles

    private struct Found {
        var folder: URL
        var name: String
        var icon: String? = nil
        /// a CSS colour
        var theme: String? = nil
        var isDefault = false
    }

    /// profiles.ini's profiles and every Profile Group row, once each by folder, keeping those that hold data
    private static func found(_ ini: String, root: URL) -> [Found] {
        var sections: [(header: String, values: [String: String])] = []
        for raw in ini.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                sections.append((line, [:]))
            } else if let equals = line.firstIndex(of: "="), !sections.isEmpty {
                sections[sections.count - 1].values[String(line[..<equals])] = String(line[line.index(after: equals)...])
            }
        }
        func folder(_ path: String) -> URL { path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appending(path: path) }
        // APFS matches names without case
        func id(_ path: String) -> String { folder(path).standardizedFileURL.path.lowercased() }

        let listed = sections.filter { $0.header.hasPrefix("[Profile") }
        var out: [Found] = []
        var at: [String: Int] = [:]
        for section in listed {
            guard let path = section.values["Path"], at[id(path)] == nil else { continue }
            at[id(path)] = out.count
            out.append(Found(folder: folder(path), name: section.values["Name"] ?? folder(path).lastPathComponent))
        }
        // a group stands for its lowest-id row; its ini path names whichever member ran last
        var first: [String: String] = [:]
        for store in Set(listed.compactMap { $0.values["StoreID"] }).sorted() {
            SQLiteCopy.withDatabase(at: root.appending(path: "Profile Groups/\(store).sqlite")) { db in
                var lowest: String?
                SQLiteCopy.rows(db, "SELECT path, name, avatar, themeBg FROM Profiles ORDER BY id;") { row in
                    guard let path = SQLiteCopy.text(row, 0) else { return }
                    let key = id(path)
                    let i = at[key] ?? out.count
                    if i == out.count {
                        at[key] = i
                        out.append(Found(folder: folder(path), name: folder(path).lastPathComponent))
                    }
                    if let name = SQLiteCopy.text(row, 1), !name.isEmpty { out[i].name = name }
                    out[i].icon = SQLiteCopy.text(row, 2).flatMap { avatars[$0] }
                    out[i].theme = SQLiteCopy.text(row, 3)
                    lowest = lowest ?? key
                    first[key] = lowest
                }
            }
        }
        func chosen(_ path: String) -> Int? { at[first[id(path)] ?? id(path)] }
        let installs = Set(
            sections.filter { $0.header.hasPrefix("[Install") }.compactMap { $0.values["Default"] }
                .map { first[id($0)] ?? id($0) })
        let preferred = listed.first { $0.values["Default"] == "1" }?.values["Path"].flatMap(chosen)
        // installs that disagree leave no profile the default
        if let index = installs.count > 1 ? nil : installs.first.flatMap({ at[$0] }) ?? preferred {
            out[index].isDefault = true
        }
        let data = ["places.sqlite", "cookies.sqlite", "sessionstore.jsonlz4", "sessionstore-backups", "zen-sessions.jsonlz4"]
        return out.filter { profile in
            data.contains { FileManager.default.fileExists(atPath: profile.folder.appending(path: $0).path) }
        }
    }

    /// the profile itself, then one per container that something lands in
    private static func profiles(
        _ found: Found, key: String, layout: GeckoSession.Layout,
        of browser: (name: String, bundleID: String, root: String, flavour: GeckoSession.Flavour)
    ) -> [ImportedProfile] {
        let places = found.folder.appending(path: "places.sqlite")
        let cookies = found.folder.appending(path: "cookies.sqlite")
        let jar = FileManager.default.fileExists(atPath: cookies.path)
        let source = ImportedProfile(
            id: Importers.stableID("\(browser.bundleID)/profile/\(key)"), key: key, name: found.name, icon: found.icon,
            isDefault: found.isDefault, folder: found.folder, spaces: layout.spaces[0] ?? [],
            favourites: layout.favourites[0] ?? [], bookmarks: bookmarks(places), archive: layout.archive,
            history: FileManager.default.fileExists(atPath: places.path) ? .gecko(places) : nil,
            cookies: jar ? [.gecko(cookies, container: 0)] : [],
            logins: .csvOnly(
                hint: "In \(browser.name), open about:logins and choose Export Passwords from the menu. Then choose the saved file here."
            ),
            historyCount: SQLiteCopy.count(
                places, "SELECT count(*) FROM moz_places WHERE hidden = 0 AND last_visit_date > 0 AND visit_count > 0;"),
            cookieCount: jar ? cookieCount(cookies, container: 0) : 0)
        return [source]
            + layout.containers.sorted { $0.key < $1.key }.compactMap { n, container in
                guard layout.spaces[n] != nil || layout.favourites[n] != nil else { return nil }
                return ImportedProfile(
                    id: Importers.stableID("\(browser.bundleID)/\(key)/container/\(n)"), key: "\(key)/container/\(n)",
                    name: container.name, icon: container.icon, folder: found.folder, spaces: layout.spaces[n] ?? [],
                    favourites: layout.favourites[n] ?? [], cookies: jar ? [.gecko(cookies, container: n)] : [],
                    cookieCount: jar ? cookieCount(cookies, container: n) : 0)
            }
    }

    // MARK: - Bookmarks

    /// the toolbar, menu, other and mobile roots, each a folder when it holds anything; tags stay out
    private static func bookmarks(_ places: URL) -> [ImportedItem] {
        SQLiteCopy.withDatabase(at: places) { db in
            var roots: [String: Int64] = [:]
            var children: [Int64: [(id: Int64, type: Int32, title: String, url: String?)]] = [:]
            SQLiteCopy.rows(
                db,
                """
                SELECT b.id, b.parent, b.type, b.title, p.url, b.guid FROM moz_bookmarks b
                LEFT JOIN moz_places p ON p.id = b.fk ORDER BY b.parent, b.position;
                """
            ) { row in
                let id = sqlite3_column_int64(row, 0)
                if let guid = SQLiteCopy.text(row, 5) { roots[guid] = id }
                children[sqlite3_column_int64(row, 1), default: []].append(
                    (id, sqlite3_column_int(row, 2), SQLiteCopy.text(row, 3) ?? "", SQLiteCopy.text(row, 4)))
            }
            // bounded, since a corrupt parent chain can cycle
            func items(_ parent: Int64, depth: Int = 0) -> [ImportedItem] {
                guard depth < 32 else { return [] }
                return (children[parent] ?? []).compactMap { child in
                    switch child.type {
                    case 1: child.url.map { .tab(ImportedTab(url: $0, title: child.title.isEmpty ? nil : child.title)) }
                    case 2: .folder(name: child.title, expanded: false, items(child.id, depth: depth + 1))
                    default: nil
                    }
                }
            }
            return [
                ("toolbar_____", "Bookmarks Toolbar"), ("menu________", "Bookmarks Menu"),
                ("unfiled_____", "Other Bookmarks"), ("mobile______", "Mobile Bookmarks"),
            ].compactMap { guid, name in
                let inside = roots[guid].map { items($0) } ?? []
                return inside.isEmpty ? nil : .folder(name: name, expanded: false, inside)
            }
        } ?? []
    }

    // MARK: - History

    /// newest first; times are microseconds since 1970, and a typed visit is `visit_type` 2
    static func history(_ places: URL) -> [ImportedVisit] {
        SQLiteCopy.withDatabase(at: places) { db in
            var out: [ImportedVisit] = []
            SQLiteCopy.rows(
                db,
                """
                SELECT p.url, p.title, p.last_visit_date, p.visit_count,
                       (SELECT count(*) FROM moz_historyvisits v WHERE v.place_id = p.id AND v.visit_type = 2)
                FROM moz_places p WHERE p.hidden = 0 AND p.last_visit_date > 0 AND p.visit_count > 0
                ORDER BY p.last_visit_date DESC LIMIT \(Importers.historyLimit);
                """
            ) { row in
                guard let url = SQLiteCopy.text(row, 0) else { return }
                out.append(
                    ImportedVisit(
                        url: url, title: SQLiteCopy.text(row, 1) ?? "",
                        lastVisited: Date(timeIntervalSince1970: Double(sqlite3_column_int64(row, 2)) / 1_000_000),
                        visitCount: Int(sqlite3_column_int(row, 3)), typedCount: Int(sqlite3_column_int(row, 4))))
            }
            return out
        } ?? []
    }

    // MARK: - Cookies

    /// one container's jar: 0 is rows with no `userContextId`; partitioned rows stay out
    static func cookies(_ file: URL, container: Int) -> ImportedCookies {
        SQLiteCopy.withDatabase(at: file) { db in
            var read = ImportedCookies()
            var seen: Set<String> = []
            // `expiry` is seconds through schema 15, milliseconds after
            let perSecond: Double = SQLiteCopy.scalar(db, "PRAGMA user_version;") <= 15 ? 1 : 1000
            let sameSite = SQLiteCopy.columns(db, "moz_cookies").contains("sameSite") ? "sameSite" : "0"
            let jar = container == 0 ? nil : String(container)
            let now = Date()
            SQLiteCopy.rows(
                db,
                """
                SELECT host, name, value, path, expiry, isSecure, isHttpOnly, \(sameSite), originAttributes
                FROM moz_cookies;
                """
            ) { row in
                // `^key=value&key=value`
                var attributes: [Substring: String] = [:]
                for pair in (SQLiteCopy.text(row, 8) ?? "").dropFirst().split(separator: "&") {
                    let parts = pair.split(separator: "=", maxSplits: 1)
                    guard let key = parts.first else { continue }
                    attributes[key] = parts.dropFirst().first.map(String.init) ?? ""
                }
                guard attributes["partitionKey"] == nil, attributes["userContextId"] == jar else { return }
                read.rows += 1
                guard let host = SQLiteCopy.text(row, 0), !host.isEmpty, let name = SQLiteCopy.text(row, 1),
                    // under first-party isolation, only the copy set on the cookie's own site; an encoded
                    // value, "(scheme,host)" or an IPv6 address, is kept unchecked
                    attributes["firstPartyDomain"].map({ $0.contains("%") || host == $0 || host.hasSuffix(".\($0)") })
                        ?? true,
                    seen.insert("\(host)\u{1}\(name)\u{1}\(SQLiteCopy.text(row, 3) ?? "")").inserted
                else { return }
                let expiry = Date(timeIntervalSince1970: Double(sqlite3_column_int64(row, 4)) / perSecond)
                guard expiry > now else { return }
                var properties: [HTTPCookiePropertyKey: Any] = [
                    .name: name, .value: SQLiteCopy.text(row, 2) ?? "", .domain: host,
                    .path: SQLiteCopy.text(row, 3) ?? "/", .expires: expiry,
                ]
                if sqlite3_column_int(row, 5) != 0 { properties[.secure] = "TRUE" }
                if sqlite3_column_int(row, 6) != 0 { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
                switch sqlite3_column_int(row, 7) {
                case 1: properties[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteLax.rawValue
                case 2: properties[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteStrict.rawValue
                default: break
                }
                if let cookie = HTTPCookie(properties: properties) { read.cookies.append(cookie) }
            }
            return read
        } ?? ImportedCookies()
    }

    /// a cheap count of `cookies(_:container:)`'s rows, expired ones included
    private static func cookieCount(_ file: URL, container: Int) -> Int {
        let jar =
            container == 0
            ? "originAttributes NOT LIKE '%userContextId=%'"
            : "(originAttributes = '^userContextId=\(container)' OR originAttributes LIKE '^userContextId=\(container)&%')"
        return SQLiteCopy.count(
            file, "SELECT count(*) FROM moz_cookies WHERE \(jar) AND originAttributes NOT LIKE '%partitionKey=%';")
    }
}
