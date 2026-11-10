// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import AppKit
import UniformTypeIdentifiers
import WebKit

/// The import sheet's state: which browser, where each of its profiles lands, what to take,
/// and how it went. Readers run detached; only the landing runs here, on main.
@MainActor
@Observable
final class ImportModel {
    enum Phase: Equatable {
        case choosing
        case working(String)
        case done([String])
        case failed(String)
    }

    private(set) var browsers: [ImportedBrowser]
    private(set) var browser: ImportedBrowser?
    /// source profile id → its Artemis profile; one mapped to its own id is a new profile
    var destinations: [UUID: UUID] = [:]
    var included: Set<UUID> = []
    /// what is ticked; only what `available` has is ever taken
    var selection: Set<ImportCategory> = []
    /// a plain-text copy of the unsealed passwords, in Downloads
    var loginsFile = false
    /// the CSV a browser without readable passwords exported
    var passwordFile: URL?
    /// Yab's spaces are on their way over AppleScript
    private(set) var reading = false
    /// Safari export zips unpacked to a temporary folder, deleted with the model
    @ObservationIgnored private var unpacked: [URL] = []
    var phase: Phase = .choosing

    init(browsers: [ImportedBrowser]) {
        self.browsers = browsers
    }

    deinit {
        for folder in unpacked { try? FileManager.default.removeItem(at: folder) }
    }

    /// File ▸ Import from Browser…, the command bar and General settings. `adding` is a
    /// browser already read, shown chosen in place of the detected one.
    static func open(in manager: TabManager, adding extra: ImportedBrowser? = nil) {
        guard manager.importer == nil else { return }
        Task {
            var found = await Task.detached { Importers.detect(home: .homeDirectory) }.value
            guard manager.importer == nil else { return }
            if let extra {
                found.removeAll { $0.family == extra.family }
                found.insert(extra, at: 0)
            }
            let model = ImportModel(browsers: found)
            manager.importer = model
            // reading Yab sends it an Apple Event, so it waits to be picked
            if let first = extra ?? found.first(where: { $0.family != .yab }) { model.choose(first) }
        }
    }

    func choose(_ pick: ImportedBrowser) {
        guard phase == .choosing, !reading else { return }
        select(pick)
        if pick.family == .yab, pick.wall == nil { readLive() }
    }

    /// asks Yab for its spaces, which may raise the Automation prompt
    func readLive() {
        guard let pick = browser, pick.family == .yab, !reading else { return }
        reading = true
        Task {
            let live = await YabImport.live(pick)
            reading = false
            guard browser?.id == pick.id else { return }
            replace(pick, with: live)
        }
    }

    private func select(_ pick: ImportedBrowser) {
        browser = pick
        included = Set(pick.profiles.map(\.id))
        // a browser that names no default profile lands its first there
        let home = (pick.profiles.first(where: \.isDefault) ?? pick.profiles.first)?.id
        destinations = Dictionary(
            pick.profiles.map { ($0.id, $0.id == home ? Profile.defaultID : $0.id) }, uniquingKeysWith: { first, _ in first })
        selection = Set(available).subtracting([.passwords])
        loginsFile = false
        passwordFile = nil
    }

    private func replace(_ old: ImportedBrowser, with new: ImportedBrowser) {
        if let index = browsers.firstIndex(where: { $0.id == old.id }) { browsers[index] = new }
        select(new)
    }

    // MARK: - What there is

    var chosen: [ImportedProfile] { browser?.profiles.filter { included.contains($0.id) } ?? [] }

    /// what the included profiles have, or keep behind the browser's key
    var available: [ImportCategory] {
        let profiles = chosen
        return ImportCategory.allCases.filter { category in profiles.contains { Self.has($0, category) } }
    }

    static func has(_ profile: ImportedProfile, _ category: ImportCategory) -> Bool {
        switch category {
        case .spaces: !profile.spaces.isEmpty || profile.locked.contains(.spaces)
        case .favourites: !profile.favourites.isEmpty || profile.locked.contains(.favourites)
        case .bookmarks: !profile.bookmarks.isEmpty || profile.locked.contains(.bookmarks)
        case .archive: !profile.archive.isEmpty || profile.locked.contains(.archive)
        case .history: profile.history != nil && profile.historyCount > 0
        case .cookies: !profile.cookies.isEmpty && profile.cookieCount > 0
        case .passwords:
            switch profile.logins {
            case .chromium: profile.loginCount > 0
            case .csv, .csvOnly: true
            case nil: false
            }
        }
    }

    /// passwords count only once there is something to read them from
    var taking: Set<ImportCategory> {
        var out = selection.intersection(available)
        if out.contains(.passwords), passwordsNeedFile, passwordFile == nil { out.remove(.passwords) }
        return out
    }

    /// this browser's passwords come only from a CSV the person exports
    var passwordsNeedFile: Bool {
        chosen.contains { if case .csvOnly = $0.logins { true } else { false } }
    }

    var canImport: Bool { phase == .choosing && !reading && !taking.isEmpty }

    /// cookies and passwords sealed with the browser's key, or parts locked behind it
    var needsKey: Bool {
        let taking = taking
        let locks = Self.locks(taking)
        return chosen.contains { profile in
            (taking.contains(.cookies) && profile.cookies.contains { if case .chromium = $0 { true } else { false } })
                || (taking.contains(.passwords) && { if case .chromium = profile.logins { true } else { false } }())
                || !profile.locked.isDisjoint(with: locks)
        }
    }

    private static func locks(_ taking: Set<ImportCategory>) -> Set<Locked> {
        var out: Set<Locked> = []
        if taking.contains(.spaces) { out.insert(.spaces) }
        if taking.contains(.favourites) { out.insert(.favourites) }
        if taking.contains(.bookmarks) { out.insert(.bookmarks) }
        if taking.contains(.archive) { out.insert(.archive) }
        return out
    }

    // MARK: - Choosing files

    /// Safari without Full Disk Access: the zip or HTML file its File menu exports
    func chooseExport() {
        guard let current = browser else { return }
        let panel = NSOpenPanel()
        panel.message = "Choose the file Safari exported."
        panel.directoryURL = Self.downloads
        panel.allowedContentTypes = [.zip, .html]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            guard let read = await SafariImport.readExport(url) else {
                let alert = NSAlert()
                alert.messageText = "Artemis couldn't read that file."
                alert.informativeText = "Choose the file from Safari's File menu, Export Browsing Data."
                alert.runModal()
                return
            }
            if read.root != url.deletingLastPathComponent() { unpacked.append(read.root) }
            guard browser?.id == current.id else { return }
            replace(current, with: read)
        }
    }

    func choosePasswordFile() {
        let panel = NSOpenPanel()
        panel.message = "Choose the passwords CSV you exported."
        panel.directoryURL = Self.downloads
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        passwordFile = url
        selection.insert(.passwords)
    }

    private static var downloads: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].resolvingSymlinksInPath()
    }

    // MARK: - Importing

    func cancel(in manager: TabManager) {
        if case .working = phase { return }
        manager.importer = nil
    }

    func run(into manager: TabManager) {
        guard canImport, let browser else { return }
        phase = .working("Reading \(browser.name)…")
        Task { await perform(browser, into: manager) }
    }

    /// The key, then the cookies read and checked, so a failure lands nothing. Then profiles, which
    /// the cookies need for their jars, and cookies before spaces: a page that loads before its
    /// cookies is signed out.
    private func perform(_ source: ImportedBrowser, into manager: TabManager) async {
        let taking = taking
        let name = source.name
        var routes = destinations.filter { included.contains($0.key) }
        var landed: [String] = []
        var key: Data?

        if needsKey {
            phase = .working("Waiting for the keychain…")
            let candidates = source.keychain
            // the prompt blocks whichever thread asks, and that must not be the one drawing this sheet
            key = await Task.detached(priority: .userInitiated) { try? BrowserKeychain.key(for: candidates, browser: name) }
                .value
            guard key != nil else {
                phase = .failed(
                    "macOS didn't hand over \(name)'s key, so nothing was imported. Untick what needs the key to bring the rest.")
                return
            }
        }

        var jars: [(profile: ImportedProfile, read: ImportedCookies)] = []
        if taking.contains(.cookies) {
            phase = .working("Cookies…")
            var rows = 0
            var sealed = 0
            var unsealed = 0
            var expected = 0
            for profile in source.profiles where routes[profile.id] != nil {
                expected += profile.cookieCount
                for jar in profile.cookies {
                    let read = await Task.detached { Importers.cookies(jar, key: key) }.value
                    rows += max(read.rows, read.cookies.count)
                    if case .chromium = jar {
                        sealed += read.rows
                        unsealed += read.unsealed
                    }
                    jars.append((profile, read))
                }
            }
            if rows == 0, expected > 0 {
                phase = .failed("\(name)'s cookies couldn't be read, so nothing was imported. Quitting \(name) first usually fixes it.")
                return
            }
            if key != nil, sealed > 0, unsealed == 0 {
                phase = .failed("\(name)'s key didn't unseal a single cookie, so nothing was imported.")
                return
            }
        }

        var source = source
        let locks = Self.locks(taking)
        if let key, source.profiles.contains(where: { routes[$0.id] != nil && !$0.locked.isDisjoint(with: locks) }) {
            phase = .working("Unsealing \(name)…")
            source = await Task.detached { [source] in Importers.unlock(source, key: key) }.value
            if source.profiles.contains(where: { routes[$0.id] != nil && !$0.locked.isDisjoint(with: locks) }) {
                landed.append("Some of \(name)'s tabs couldn't be unsealed and stayed behind")
            }
        }

        let names = Set(manager.profiles.map(\.name))
        let structure = taking.intersection([.spaces, .favourites, .bookmarks, .archive])
        var haul = await Task.detached { [source, routes] in
            ImportBuilder.haul(source, into: routes, taking: structure, names: names)
        }.value
        // a new profile only when something lands in it; a password CSV lands in one profile
        let filled = Set(haul.spaces.compactMap(\.profileID))
            .union(haul.favourites.filter { !$0.value.isEmpty }.keys).union(haul.archive.filter { !$0.value.isEmpty }.keys)
        let routed = source.profiles.filter { routes[$0.id] != nil }
        let csvTarget = (routed.first(where: \.isDefault) ?? routed.first)?.id
        func lands(_ profile: ImportedProfile) -> Bool {
            if jars.contains(where: { $0.profile.id == profile.id && !$0.read.cookies.isEmpty }) { return true }
            if taking.contains(.history), Self.has(profile, .history) { return true }
            guard taking.contains(.passwords) else { return false }
            if passwordFile != nil, profile.id == csvTarget { return true }
            if case .csvOnly = profile.logins { return false }
            return Self.has(profile, .passwords)
        }
        routes = routes.filter { id, into in
            into != id || filled.contains(into) || source.profiles.contains { $0.id == id && lands($0) }
        }
        haul.profiles = ImportBuilder.haul(source, into: routes, taking: [], names: names).profiles
        manager.adoptProfiles(haul.profiles)
        func home(_ profile: ImportedProfile) -> Profile {
            manager.core.profile(routes[profile.id]) ?? manager.core.defaultProfile
        }

        if taking.contains(.cookies) {
            let total = jars.reduce(0) { $0 + $1.read.cookies.count }
            var written = 0
            for (profile, read) in jars {
                let store = home(profile).dataStore
                for cookie in read.cookies {
                    await store.httpCookieStore.setCookie(cookie)
                    written += 1
                    if written % 100 == 0 { phase = .working("Cookies… \(written) of \(total)") }
                }
            }
            landed.append(
                written > 0
                    ? "\(Self.count(written, "cookie")), so you stay signed in" : "None of \(name)'s cookies were still usable")
        }

        if !structure.isEmpty {
            phase = .working("Spaces and tabs…")
            let (made, favourites, archived) = manager.importBrowser(haul)
            if !made.isEmpty {
                landed.append(
                    "\(Self.count(made.count, "space")), \(Self.count(made.reduce(0) { $0 + $1.tabs.count }, "tab"))")
            } else if !haul.spaces.isEmpty {
                landed.append("Its spaces were already here")
            }
            if favourites > 0 { landed.append(Self.count(favourites, "favourite")) }
            if archived > 0 { landed.append(Self.count(archived, "archived tab")) }
        }

        if taking.contains(.history) {
            phase = .working("History…")
            var added = 0
            var read = 0
            var expected = 0
            for profile in source.profiles where routes[profile.id] != nil {
                guard let history = profile.history else { continue }
                let entries = await Task.detached { ImportBuilder.history(Importers.history(history)) }.value
                read += entries.count
                expected += profile.historyCount
                added += home(profile).history.merge(entries)
            }
            landed.append(
                added > 0
                    ? "\(Self.count(added, "page")) of history"
                    : read == 0 && expected > 0 ? "\(name)'s history couldn't be read" : "History was already here")
        }

        if taking.contains(.passwords) {
            phase = .working("Passwords…")
            let profiles = source.profiles.filter { routes[$0.id] != nil }
            landed.append(await importLogins(profiles, key: key, from: name, home: home))
        }

        if !source.leftBehind.isEmpty, !taking.isDisjoint(with: [.cookies, .history]) {
            let list = source.leftBehind.joined(separator: ", ")
            landed.append("\(name) kept the cookies and history of profiles with no spaces: \(list)")
        }
        phase = .done(landed)
    }

    /// into Artemis Passwords per profile, and to a plain-text file in Downloads only when asked
    private func importLogins(
        _ profiles: [ImportedProfile], key: Data?, from name: String, home: (ImportedProfile) -> Profile
    ) async -> String {
        let store = PasswordStore.shared
        var all: [ImportedLogin] = []
        var taken = 0
        var skipped = 0
        var failed = false
        func land(_ text: String, into profile: ImportedProfile) async {
            guard let summary = await store.importCSV(text, into: home(profile).id) else {
                failed = true
                return
            }
            taken += summary.added + summary.updated
            skipped += summary.skipped
        }
        for profile in profiles {
            switch profile.logins {
            case .chromium(let files):
                guard let key else { continue }
                let logins = await Task.detached { ChromiumData.logins(files, key: key) }.value
                all += logins
                if !logins.isEmpty { await land(Self.csv(logins), into: profile) } else if profile.loginCount > 0 { failed = true }
            case .csv(let file):
                if let text = Self.text(file) { await land(text, into: profile) } else { failed = true }
            case .csvOnly, nil:
                break
            }
        }
        if let passwordFile, let target = profiles.first(where: \.isDefault) ?? profiles.first {
            if let text = Self.text(passwordFile) { await land(text, into: target) } else { failed = true }
        }
        var line = failed && taken == 0 ? "No passwords came in" : "\(Self.count(taken, "password")) into Artemis Passwords"
        if skipped > 0 { line += " (\(skipped) already there or unusable)" }
        if passwordFile != nil, taken > 0 { line += ". Now delete the CSV file" }
        if loginsFile, !all.isEmpty {
            line += "; " + store.writePlaintext(
                Self.csv(all), suggesting: "\(name.lowercased())-passwords.csv", count: all.count)
        }
        return line
    }

    private static func text(_ file: URL) -> String? {
        (try? String(contentsOf: file, encoding: .utf8)) ?? (try? String(contentsOf: file, encoding: .isoLatin1))
    }

    private static func csv(_ logins: [ImportedLogin]) -> String {
        PasswordStore.csv(
            logins.map { (name: $0.title, url: $0.url, username: $0.username, password: $0.password, code: "") })
    }

    static func count(_ n: Int, _ noun: String) -> String {
        "\(n.formatted(.number.grouping(.automatic))) \(noun)\(n == 1 ? "" : "s")"
    }
}
