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

    init(survey: ArcImport.Survey) {
        self.survey = survey
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
        manager.arcImport = nil
    }

    func run(into manager: TabManager) {
        guard canImport, phase == .choosing else { return }
        phase = .working("Reading Arc…")
        Task { await perform(into: manager) }
    }

    private func perform(into manager: TabManager) async {
        var landed: [String] = []
        var key: Data?

        if needsKey {
            phase = .working("Waiting for the keychain…")
            // the consent prompt blocks whichever thread asks, and that must not
            // be the one drawing this sheet
            key = await Task.detached(priority: .userInitiated) { try? ArcSecrets.key() }.value
            guard key != nil else {
                phase = .failed(
                    "macOS didn't hand over Arc's key, so cookies and passwords stayed behind. "
                        + "Nothing else was touched — run the import again to take the rest.")
                return
            }
        }

        // after the key, so a refusal leaves nothing behind; before the cookies, which need their jars
        if let sidebar = survey.sidebar, selection.cookies || selection.history || selection.logins {
            manager.adoptProfiles(sidebar.profiles)
        }

        // cookies first: the space this lands you in loads its page the moment
        // it arrives, and a page loaded before its cookies is a signed-out one
        if selection.cookies, let key {
            switch await importCookies(key: key, into: manager) {
            case .landed(let line): landed.append(line)
            case .wrongKey(let reason):
                phase = .failed(reason)
                return
            }
        }

        if var result = survey.sidebar, selection.spaces || selection.favourites || selection.archive
        {
            phase = .working("Spaces and tabs…")
            if !selection.spaces { result.spaces = [] }
            if !selection.favourites { result.favourites = [] }
            if !selection.archive { result.archived = [] }
            let (made, archived) = manager.importArc(result)
            if !made.isEmpty {
                landed.append("\(made.count) spaces, \(made.reduce(0) { $0 + $1.tabs.count }) tabs")
            }
            if selection.favourites, survey.favourites > 0 {
                landed.append("\(survey.favourites) favourites")
            }
            if archived > 0 {
                landed.append("\(archived) archived tabs")
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

        phase = .done(landed)
    }

    /// Cookies go to the profile their Arc profile became. One with neither
    /// spaces nor favourites in Arc's sidebar has no profile here, and its cookies
    /// are left behind rather than poured into someone else's jar.
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
        present(source, into: manager)
    }

    /// A fresh install that finds Arc offers the move on first launch.
    static func offerOnFirstLaunch(into manager: TabManager) {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: offeredKey), ArcImport.isInstalled, ArcImport.isReadable(),
            manager.spaces.count == 1, manager.spaces[0].tabs.count <= 1
        else { return }
        defaults.set(true, forKey: offeredKey)
        present(ArcImport.dataDirectory, into: manager, asked: false)
    }

    /// `asked` is false for the first-launch offer, which stays quiet when
    /// there turns out to be nothing to move
    private static func present(
        _ source: URL, into manager: TabManager, asked: Bool = true
    ) {
        Task {
            let survey = await Task.detached { ArcImport.survey(source) }.value
            // a picker opened while one is already up would strand the first
            guard manager.arcImport == nil else { return }
            guard !survey.isEmpty else {
                guard asked else { return }
                let alert = NSAlert()
                alert.messageText = "Artemis couldn't read Arc's data."
                alert.informativeText =
                    "It looks for “StorableSidebar.json” in Arc's folder — "
                    + "~/Library/Application Support/Arc."
                alert.runModal()
                return
            }
            manager.arcImport = ArcImportModel(survey: survey)
        }
    }

    /// Arc's own folder, else the one the person picks
    private static func locate() -> URL? {
        if ArcImport.isReadable() { return ArcImport.dataDirectory }
        let panel = NSOpenPanel()
        panel.message = "Choose Arc's data folder (Application Support ▸ Arc)."
        panel.directoryURL = ArcImport.dataDirectory
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        guard panel.runModal() == .OK, let picked = panel.urls.first else { return nil }
        return picked.hasDirectoryPath ? picked : picked.deletingLastPathComponent()
    }
}
