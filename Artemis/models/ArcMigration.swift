// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import AppKit
import WebKit

/// The move from Arc, end to end: finding it, counting what is there, asking
/// what to take, and landing it. The parsing lives in `ArcImport`, the
/// unsealing in `ArcSecrets`; this is the ceremony around them.
@MainActor
@Observable
final class ArcImportModel {
    /// what to take; passwords, and their plain-text copy, only when ticked
    struct Selection {
        var spaces = true
        var favourites = true
        var archive = true
        var history = true
        var cookies = true
        var logins = false
        var loginsFile = false
    }

    enum Phase: Equatable {
        case choosing
        case working(String)
        case done([String])
        case failed(String)
    }

    let survey: ArcImport.Survey
    var selection: Selection
    var phase: Phase = .choosing

    /// held only while the import runs — the folder grant from an open panel
    private let scoped: URL?
    private var released = false

    init(survey: ArcImport.Survey, scoped: URL? = nil) {
        self.survey = survey
        self.scoped = scoped
        // a category with nothing in it is hidden from the sheet, so it must not
        // stay selected underneath — an invisible tick would ask for the
        // keychain to import no cookies
        var selection = Selection()
        selection.spaces = survey.spaces > 0
        selection.favourites = survey.favourites > 0
        selection.archive = survey.archived > 0
        selection.history = survey.history > 0
        selection.cookies = survey.cookies > 0
        self.selection = selection
    }

    var canImport: Bool {
        let s = selection
        return s.spaces || s.favourites || s.archive || s.history || s.cookies || s.logins
    }

    /// cookies and passwords are the two that need the keychain
    var needsKey: Bool { selection.cookies || selection.logins }

    func cancel(in manager: TabManager) {
        release()
        manager.arcImport = nil
    }

    private func release() {
        guard !released else { return }
        released = true
        scoped?.stopAccessingSecurityScopedResource()
    }

    func run(into manager: TabManager) {
        guard canImport, phase == .choosing else { return }
        phase = .working("Reading Arc…")
        Task { await perform(into: manager) }
    }

    private func perform(into manager: TabManager) async {
        var landed: [String] = []
        var key: Data?

        // Arc's profiles exist here before anything lands in them
        if let sidebar = survey.sidebar,
            selection.spaces || selection.cookies || selection.history || selection.logins
        {
            manager.adoptProfiles(sidebar.profiles)
        }

        // cookies first: the space this lands you in loads its page the moment
        // it arrives, and a page loaded before its cookies is a signed-out one
        if needsKey {
            phase = .working("Waiting for the keychain…")
            // the consent prompt blocks whichever thread asks, and that must not
            // be the one drawing this sheet
            key = await Task.detached(priority: .userInitiated) { try? ArcSecrets.key() }.value
            guard let key else {
                phase = .failed(
                    "macOS didn't hand over Arc's key, so cookies and passwords stayed behind. "
                        + "Nothing else was touched — run the import again to take the rest.")
                release()
                return
            }
            if selection.cookies {
                switch await importCookies(key: key, into: manager) {
                case .landed(let line): landed.append(line)
                case .wrongKey(let reason):
                    phase = .failed(reason)
                    release()
                    return
                }
            }
        }

        if var result = survey.sidebar, selection.spaces || selection.favourites || selection.archive
        {
            phase = .working("Spaces and tabs…")
            if !selection.spaces {
                result.spaces = []
                // the names belong to the tabs that aren't coming
                result.renames = [:]
            }
            if !selection.favourites { result.favouriteURLs = [] }
            if !selection.archive { result.archived = [] }
            manager.importArc(result)
            if selection.spaces {
                landed.append("\(survey.spaces) spaces, \(survey.tabs) tabs")
            }
            if selection.favourites, survey.favourites > 0 {
                landed.append("\(survey.favourites) favourites")
            }
            if selection.archive, survey.archived > 0 {
                landed.append("\(survey.archived) archived tabs")
            }
        }

        if selection.history {
            phase = .working("History…")
            var added = 0
            for folder in ArcImport.profiles(in: survey.directory) {
                guard let profile = destination(for: folder.lastPathComponent, in: manager) else { continue }
                let entries = await Task.detached { BrowserImport.chromiumHistory(folder) }.value
                added += profile.history.merge(entries)
            }
            landed.append("\(added) pages of history")
        }

        if selection.logins, let key {
            phase = .working("Passwords…")
            landed.append(await importLogins(key: key, into: manager))
        }

        release()
        phase = .done(landed)
    }

    /// Cookies go to the profile their Arc profile became. One with no spaces in
    /// Arc's sidebar has no profile here, and its cookies are left behind rather
    /// than poured into someone else's jar.
    private func importCookies(key: Data, into manager: TabManager) async -> CookieOutcome {
        var written = 0
        var rows = 0
        var unsealed = 0
        var skipped: [String] = []

        for profile in ArcImport.profiles(in: survey.directory) {
            let name = profile.lastPathComponent
            guard let store = destination(for: name, in: manager)?.dataStore else {
                skipped.append(name)
                continue
            }
            let read = await Task.detached { ArcImport.cookies(in: profile, key: key) }.value
            rows += read.rows
            unsealed += read.unsealed
            for (index, cookie) in read.cookies.enumerated() {
                await store.httpCookieStore.setCookie(cookie)
                if index % 100 == 0 {
                    phase = .working("Cookies… \(written + index) of \(rows)")
                }
            }
            written += read.cookies.count
        }

        // the survey counted rows that the import then couldn't read at all
        if rows == 0, survey.cookies > 0 {
            return .wrongKey(
                "Arc's cookie database couldn't be read this time, so no cookies were imported. "
                    + "Quitting Arc first usually fixes it.")
        }
        // a key that unseals nothing is a wrong key, not an empty browser
        if rows > 0, unsealed == 0 {
            return .wrongKey(
                "Arc's key didn't unseal a single cookie, so none were imported. "
                    + "Everything that doesn't need the key is unaffected.")
        }
        var line = "\(written) cookies — you stay signed in"
        if !skipped.isEmpty {
            line += " (Arc's \(skipped.joined(separator: ", ")) skipped: no profile here to hold them)"
        }
        return .landed(line)
    }

    /// cookies either arrived, or the key was wrong — which is worth stopping for
    private enum CookieOutcome {
        case landed(String)
        case wrongKey(String)
    }

    /// the Artemis profile an Arc profile folder became
    private func destination(for folder: String, in manager: TabManager) -> Profile? {
        guard folder != "Default" else { return manager.core.defaultProfile }
        return manager.core.profile(survey.sidebar?.profileIDs[folder])
    }

    /// into Artemis Passwords, and to a plain-text file in Downloads only when asked
    private func importLogins(key: Data, into manager: TabManager) async -> String {
        let directory = survey.directory
        let byFolder = await Task.detached {
            ArcImport.profiles(in: directory).map { ($0.lastPathComponent, ArcImport.logins(in: $0, key: key)) }
        }.value
        let all = byFolder.flatMap(\.1)
        guard !all.isEmpty else { return "no saved passwords to take" }
        let store = PasswordStore.shared
        var taken = 0
        var skipped = 0
        var failed = false
        // each Arc profile's logins go to its profile here; one with none falls back to the default
        for (folder, logins) in byFolder where !logins.isEmpty {
            let profile = destination(for: folder, in: manager) ?? manager.core.defaultProfile
            guard let summary = await store.importCSV(Self.csv(logins), into: profile.id) else {
                failed = true
                continue
            }
            taken += summary.added + summary.updated
            skipped += summary.skipped
        }
        var line = failed && taken == 0
            ? "passwords couldn't be imported" : "\(taken) passwords into Artemis Passwords"
        if skipped > 0 { line += " (\(skipped) already there or unusable)" }
        if selection.loginsFile {
            line += "; " + store.writePlaintext(Self.csv(all), suggesting: "arc-passwords.csv", count: all.count)
        }
        return line
    }

    private static func csv(_ logins: [ArcImport.Login]) -> String {
        PasswordStore.csv(
            logins.map { (name: $0.title, url: $0.url, username: $0.username, password: $0.password, code: "") })
    }
}

/// Opening the picker: from the File menu, or once on a first launch that finds
/// Arc on the Mac.
@MainActor
enum ArcMigration {
    /// asked at most once per install, whatever the answer
    private static let offeredKey = "arcImportOffered"

    /// File ▸ Import from Arc…
    static func run(into manager: TabManager) {
        guard manager.arcImport == nil, let source = locate() else { return }
        present(source.folder, into: manager, scoped: source.scoped)
    }

    /// A fresh install that finds Arc offers the move on first launch.
    static func offerOnFirstLaunch(into manager: TabManager) {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: offeredKey), ArcImport.isInstalled, ArcImport.isReadable(),
            manager.spaces.count == 1, manager.spaces[0].tabs.count <= 1
        else { return }
        present(ArcImport.dataDirectory, into: manager) { defaults.set(true, forKey: offeredKey) }
    }

    /// counting means copying Arc's databases, which is disk work — off the
    /// main thread, so the window doesn't hang while it happens
    private static func present(
        _ source: URL, into manager: TabManager, scoped: URL? = nil,
        offered: (() -> Void)? = nil
    ) {
        Task {
            let survey = await Task.detached { ArcImport.survey(source) }.value
            if landed(survey, into: manager, scoped: scoped) { offered?() }
        }
    }

    @discardableResult
    private static func landed(
        _ survey: ArcImport.Survey, into manager: TabManager, scoped: URL?
    ) -> Bool {
        // a picker opened while one is already up would strand the first
        guard manager.arcImport == nil else {
            scoped?.stopAccessingSecurityScopedResource()
            return false
        }
        guard !survey.isEmpty else {
            scoped?.stopAccessingSecurityScopedResource()
            let alert = NSAlert()
            alert.messageText = "Artemis couldn't read Arc's data."
            alert.informativeText =
                "It looks for “StorableSidebar.json” in Arc's folder — "
                + "~/Library/Application Support/Arc."
            alert.runModal()
            return false
        }
        manager.arcImport = ArcImportModel(survey: survey, scoped: scoped)
        return true
    }

    /// the folder to read: Arc's own if the sandbox lets us at it, else whatever
    /// the person points at — the panel is the grant
    private static func locate() -> (folder: URL, scoped: URL?)? {
        if ArcImport.isReadable() { return (ArcImport.dataDirectory, nil) }
        let panel = NSOpenPanel()
        panel.message = "Choose Arc's data folder (Application Support ▸ Arc)."
        panel.directoryURL = ArcImport.dataDirectory
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        guard panel.runModal() == .OK, let picked = panel.urls.first else { return nil }
        let folder = picked.hasDirectoryPath ? picked : picked.deletingLastPathComponent()
        return (folder, folder.startAccessingSecurityScopedResource() ? folder : nil)
    }
}
