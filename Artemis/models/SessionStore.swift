// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import Foundation

/// durable home for the browsing session: `session.json`, written through
/// `AppStorageLocation`'s rotating `.bak`
enum SessionStore {
    static let fileURL = AppStorageLocation.file("session.json")

    // legacy UserDefaults keys, read once at migration then removed
    private static let legacySpacesKey = "spacesDataV1"
    private static let legacyEssentialsKey = "essentialURLsV1"
    private static let legacySelectedSpaceKey = "selectedSpaceID"

    /// the stored session, lifted out of the pre-file `UserDefaults` keys the first time
    static func load() -> BrowsingSession? {
        if let session = AppStorageLocation.loadDurable(BrowsingSession.self, from: fileURL) {
            return session
        }
        return migrateFromDefaults()
    }

    static func save(_ session: BrowsingSession) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        AppStorageLocation.writeDurableNow(data, to: fileURL)
    }

    /// the ordinary save path: encodes and writes off the main thread
    static func saveInBackground(_ session: BrowsingSession) {
        let url = fileURL
        let takenAt = AppStorageLocation.snapshotTime()
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(session) else { return }
            AppStorageLocation.writeDurable(data, to: url, takenAt: takenAt)
        }
    }

    /// one-time lift of the pre-file layout into `session.json`; the defaults keys
    /// are cleared afterwards
    private static func migrateFromDefaults() -> BrowsingSession? {
        let defaults = UserDefaults.standard
        guard let blob = defaults.data(forKey: legacySpacesKey),
            let spaces = try? JSONDecoder().decode([SpaceData].self, from: blob)
        else { return nil }

        var session = BrowsingSession(
            spaces: spaces,
            essentialURLs: (defaults.array(forKey: legacyEssentialsKey) as? [String]) ?? [],
            selectedSpaceID: defaults.string(forKey: legacySelectedSpaceKey).flatMap(UUID.init))
        session.migrateToProfiles()
        save(session)
        debugLog("session: migrated \(spaces.count) spaces from UserDefaults into session.json")
        defaults.removeObject(forKey: legacySpacesKey)
        defaults.removeObject(forKey: legacyEssentialsKey)
        defaults.removeObject(forKey: legacySelectedSpaceKey)
        return session
    }
}
