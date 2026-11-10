// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import CryptoKit
import Foundation

// What every browser reader hands over. Spaces, favourites, bookmarks and the
// archive are read in full; history, cookies and logins stay as file locations
// until the user ticks them.

nonisolated struct ImportedTab: Sendable, Equatable {
    /// the page the tab is on
    var url: String
    var title: String? = nil
    /// the name the user gave the tab
    var name: String? = nil
    /// a pin's home page; nil when it is `url`
    var home: String? = nil
}

nonisolated indirect enum ImportedItem: Sendable, Equatable {
    case tab(ImportedTab)
    case folder(name: String, expanded: Bool, [ImportedItem])
    case split([ImportedTab], SplitOrientation)
}

nonisolated struct ImportedSpace: Sendable, Equatable {
    /// `Importers.stableID("<bundleID>/<profileKey>/space/<key>")`
    var id: UUID
    var name: String
    /// an emoji or an SF Symbol name
    var icon: String? = nil
    /// sRGB, at most 3 used; empty takes a preset
    var colors: [RGBA] = []
    /// 0…1
    var grain: Double = 0
    var pinned: [ImportedItem] = []
    var today: [ImportedItem] = []
}

nonisolated struct ImportedArchive: Sendable, Equatable {
    var url: String
    var title: String
    var name: String? = nil
    var archivedAt: Date
    var spaceName: String
}

nonisolated struct ImportedVisit: Sendable, Equatable {
    var url: String
    var title: String
    var lastVisited: Date
    var visitCount: Int
    var typedCount: Int = 0
}

/// held only until it reaches the Keychain
nonisolated struct ImportedLogin: Sendable {
    var title: String
    var url: String
    var username: String
    var password: String
}

/// `rows` counts every cookie row read and `unsealed` those that needed the key:
/// a Chromium jar with rows and nothing unsealed means the key was wrong
nonisolated struct ImportedCookies: Sendable {
    var cookies: [HTTPCookie] = []
    var rows = 0
    var unsealed = 0
}

nonisolated struct ImportedProfile: Sendable {
    /// the id a "New profile" destination gets; never `Profile.defaultID`
    var id: UUID
    /// stable within its browser: the folder name, store id or uuid the source uses
    var key: String
    var name: String
    var icon: String? = nil
    var isDefault = false
    var folder: URL
    var spaces: [ImportedSpace] = []
    var favourites: [ImportedTab] = []
    /// one collapsed folder per bookmark root
    var bookmarks: [ImportedItem] = []
    var archive: [ImportedArchive] = []
    var history: HistorySource? = nil
    var cookies: [CookieSource] = []
    var logins: LoginSource? = nil
    /// counted without the key, so the sheet can hide what is empty
    var historyCount = 0
    var cookieCount = 0
    var loginCount = 0
    /// read by `Importers.unlock` once the key is in hand
    var locked: Set<Locked> = []
}

nonisolated struct ImportedBrowser: Sendable, Identifiable {
    var name: String
    var bundleID: String
    var family: Family
    /// the data root detection found
    var root: URL
    var profiles: [ImportedProfile] = []
    /// tried in order; when every one is missing, `BrowserKeychain` searches by `name`
    var keychain: [KeychainItem] = []
    var wall: Wall? = nil
    /// other bundle ids that draw the icon when `bundleID` isn't installed
    var aliases: [String] = []
    /// space ids in the source's sidebar order across profiles; empty keeps profile order
    var spaceOrder: [UUID] = []
    /// names of source profiles whose cookies and history have nowhere to land
    var leftBehind: [String] = []

    var id: String { bundleID + "|" + root.path }
}

nonisolated struct KeychainItem: Sendable, Equatable {
    var service: String
    /// nil matches any account
    var account: String?
}

nonisolated enum Family: Sendable { case arc, chromium, dia, gecko, nook, refrax, safari, orion, yab }

nonisolated enum Wall: Sendable { case fullDiskAccess, notRunning, automationDenied, noWindow, noReply }

nonisolated enum Locked: Sendable { case spaces, favourites, bookmarks, archive }

nonisolated enum HistorySource: Sendable {
    case chromium(URL), gecko(URL), safari(URL), orion(URL), safariExport(URL)
    /// rows of `profile`, plus rows with no profile when `includeUnowned`
    case nook(URL, profile: UUID, includeUnowned: Bool)
    /// rows of these spaces
    case refrax(URL, spaces: [UUID])
    case yab(URL)
}

nonisolated enum CookieSource: Sendable {
    case chromium(URL), binary(URL), cookiePlist(URL)
    /// `container` 0 is the default; n is `userContextId=n`
    case gecko(URL, container: Int)
}

nonisolated enum LoginSource: Sendable {
    /// `Login Data` files, sealed with the browser key
    case chromium([URL])
    /// a CSV already in hand
    case csv(URL)
    /// the browser exports a CSV; `hint` says where
    case csvOnly(hint: String)
}

nonisolated enum Importers {
    /// newest first, per profile
    static let historyLimit = 4000

    /// a version 8 UUID over SHA-256 of `namespace`, so a re-import finds what the last one made
    static func stableID(_ namespace: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(namespace.utf8)).prefix(16))
        bytes[6] = bytes[6] & 0x0F | 0x80
        bytes[8] = bytes[8] & 0x3F | 0x80
        return bytes.withUnsafeBytes { UUID(uuid: $0.load(as: uuid_t.self)) }
    }

    /// every browser with data under `home`; never touches the keychain or sends Apple Events
    static func detect(home: URL) -> [ImportedBrowser] {
        ArcImport.detect(home: home) + ChromiumImport.detect(home: home) + GeckoImport.detect(home: home)
            + SafariImport.detect(home: home)
            + OrionImport.detect(home: home) + NookImport.detect(home: home) + RefraxImport.detect(home: home)
            + YabImport.detect(home: home)
    }

    /// re-reads each profile's `locked` parts with the browser key
    static func unlock(_ browser: ImportedBrowser, key: Data) -> ImportedBrowser {
        switch browser.family {
        case .chromium, .dia: ChromiumImport.unlock(browser, key: key)
        case .arc, .gecko, .nook, .refrax, .safari, .orion, .yab: browser
        }
    }

    static func history(_ source: HistorySource) -> [ImportedVisit] {
        switch source {
        case .chromium(let file): ChromiumData.history(file)
        case .gecko(let places): GeckoImport.history(places)
        case .safari(let file): SafariImport.history(file)
        case .safariExport(let json): SafariImport.exportedHistory(json)
        case .orion(let file): OrionImport.history(file)
        case .nook(let store, let profile, let unowned):
            NookImport.history(store, profile: profile, includeUnowned: unowned)
        case .refrax(let store, let spaces): RefraxImport.history(store, spaces: spaces)
        case .yab(let file): YabImport.history(file)
        }
    }

    /// `key` unseals Chromium values; without it only plaintext Chromium cookies come back
    static func cookies(_ source: CookieSource, key: Data?) -> ImportedCookies {
        switch source {
        case .chromium(let file): ChromiumData.cookies(file, key: key)
        case .gecko(let file, let container): GeckoImport.cookies(file, container: container)
        case .binary(let file): ImportedCookies(cookies: BinaryCookies.read(file), rows: BinaryCookies.count(file))
        case .cookiePlist(let file): ImportedCookies(cookies: BinaryCookies.readPlist(file), rows: BinaryCookies.count(file))
        }
    }
}

nonisolated extension RGBA {
    /// `RRGGBB` or `RRGGBBAA`, with or without a leading `#`
    init?(hex: String) {
        let digits = hex.hasPrefix("#") ? hex.dropFirst() : Substring(hex)
        guard digits.count == 6 || digits.count == 8, let value = UInt32(digits, radix: 16) else { return nil }
        let rgba = digits.count == 8 ? value : value << 8 | 0xFF
        self.init(
            Double(rgba >> 24) / 255, Double(rgba >> 16 & 0xFF) / 255, Double(rgba >> 8 & 0xFF) / 255,
            Double(rgba & 0xFF) / 255)
    }
}
