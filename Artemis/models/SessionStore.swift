import Foundation

/// durable home for the browsing session.
///
/// this used to be a blob in `UserDefaults`. that was the single biggest
/// daily-driver risk in the app: defaults are written by the system on its own
/// schedule, are silently truncated on a bad shutdown, and have no second copy —
/// one bad write and a year of spaces is gone. now it's an explicit file in the
/// app container, written atomically with a rotating `.bak`, so a torn or
/// undecodable file falls back to the last good one instead of booting you into
/// an empty browser.
enum SessionStore {
    static let fileURL = AppStorageLocation.file("session.json")

    // legacy UserDefaults keys, read once at migration then removed
    private static let legacySpacesKey = "spacesDataV1"
    private static let legacyEssentialsKey = "essentialURLsV1"
    private static let legacySelectedSpaceKey = "selectedSpaceID"

    /// load the session, migrating from the old UserDefaults blob the first time
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

    /// the ordinary save path: encode on the caller's thread (cheap — it's a few
    /// hundred urls), then push the two file writes off the main thread. a
    /// synchronous write here would land on every tab switch and navigation
    static func saveInBackground(_ session: BrowsingSession) {
        let url = fileURL
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(session) else { return }
            AppStorageLocation.writeDurable(data, to: url)
        }
    }

    /// one-time lift of the pre-file layout into `session.json`. the defaults keys
    /// are cleared afterwards so there's exactly one source of truth
    private static func migrateFromDefaults() -> BrowsingSession? {
        let defaults = UserDefaults.standard
        guard let blob = defaults.data(forKey: legacySpacesKey),
            let spaces = try? JSONDecoder().decode([SpaceData].self, from: blob)
        else { return nil }

        var session = BrowsingSession(
            spaces: spaces,
            essentialURLs: (defaults.array(forKey: legacyEssentialsKey) as? [String]) ?? [],
            selectedSpaceID: defaults.string(forKey: legacySelectedSpaceKey).flatMap(UUID.init))
        session.version = 1
        session.migrateToProfiles()
        save(session)
        debugLog("session: migrated \(spaces.count) spaces from UserDefaults into session.json")
        defaults.removeObject(forKey: legacySpacesKey)
        defaults.removeObject(forKey: legacyEssentialsKey)
        defaults.removeObject(forKey: legacySelectedSpaceKey)
        return session
    }
}
