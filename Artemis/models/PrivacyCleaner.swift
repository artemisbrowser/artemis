import WebKit

/// what a clear touches. history, site data, cache, archive and page text are
/// the chosen profile's; the downloads list, zoom and permissions are shared by all.
struct ClearTargets: OptionSet {
    let rawValue: Int

    static let history = ClearTargets(rawValue: 1 << 0)
    static let siteData = ClearTargets(rawValue: 1 << 1)
    static let cache = ClearTargets(rawValue: 1 << 2)
    static let archive = ClearTargets(rawValue: 1 << 3)
    static let downloads = ClearTargets(rawValue: 1 << 4)
    static let zoom = ClearTargets(rawValue: 1 << 5)
    static let permissions = ClearTargets(rawValue: 1 << 6)
    static let pageText = ClearTargets(rawValue: 1 << 7)

    /// what belongs to every profile at once
    static let shared: ClearTargets = [.downloads, .zoom, .permissions]
}

/// how far back a clear reaches
enum ClearRange: String, CaseIterable, Identifiable {
    case hour, day, week, all

    var id: String { rawValue }

    var label: String {
        switch self {
        case .hour: "the last hour"
        case .day: "the last 24 hours"
        case .week: "the last 7 days"
        case .all: "all time"
        }
    }

    /// the cutoff to pass to the stores; `.distantPast` for "everything"
    var since: Date {
        switch self {
        case .hour: Date(timeIntervalSinceNow: -3600)
        case .day: Date(timeIntervalSinceNow: -86_400)
        case .week: Date(timeIntervalSinceNow: -604_800)
        case .all: .distantPast
        }
    }
}

/// runs a clear over one profile's files and WebKit jar, plus whatever shared
/// stores the targets name.
@MainActor
enum PrivacyCleaner {
    /// cookies, storage and databases: the "you are signed in" half
    private static let storageTypes: Set<String> = [
        WKWebsiteDataTypeCookies,
        WKWebsiteDataTypeLocalStorage,
        WKWebsiteDataTypeSessionStorage,
        WKWebsiteDataTypeIndexedDBDatabases,
        WKWebsiteDataTypeWebSQLDatabases,
        WKWebsiteDataTypeServiceWorkerRegistrations,
    ]

    /// the "make it re-download" half, safe to clear without signing you out
    private static let cacheTypes: Set<String> = [
        WKWebsiteDataTypeDiskCache,
        WKWebsiteDataTypeMemoryCache,
        WKWebsiteDataTypeOfflineWebApplicationCache,
        WKWebsiteDataTypeFetchCache,
    ]

    static func clear(
        _ targets: ClearTargets, range: ClearRange, in profile: Profile, manager: TabManager
    ) async {
        let since = range.since

        if targets.contains(.history) {
            profile.history.clear(since: since)
            // what the command bar learned you meant by "gi" is a record of where
            // you went. it isn't timestamped, so a full clear takes all of it
            if range == .all { profile.inputHistory.clear() }
            // the per-tab session blobs carry form contents and each tab's own
            // back/forward list — history by another name. They aren't
            // timestamped, so it's all of the profile's or none
            if range == .all {
                for space in manager.spaces where space.profileID == profile.id {
                    for tab in space.tabs { TabStateStore.remove(tab.id) }
                }
            }
        }
        if targets.contains(.archive) { profile.archive.clear(since: since) }
        if targets.contains(.downloads) { DownloadManager.shared.clearFinished() }
        // zoom levels aren't timestamped — a partial clear would be a lie, so the
        // whole per-site table goes or nothing does
        if targets.contains(.zoom) { ZoomStore.shared.clear() }
        // permissions aren't timestamped either, and half-forgetting which sites
        // may use your camera would be worse than not offering it
        if targets.contains(.permissions) {
            SitePermissionStore.shared.forgetAll()
            // which sites may hand a link to another app, and whose certificate
            // you chose to accept, are the same kind of per-site consent —
            // clearing one without the others is a lie
            ExternalSchemes.forgetAll()
            CertificateTrust.forgetAll()
        }
        // the page-text index *is* timestamped, so a ranged clear is honest here
        // (`.all` is `.distantPast`, which sweeps the lot)
        if targets.contains(.pageText) { await profile.pageIndex.clear(since: since) }

        var types: Set<String> = []
        if targets.contains(.siteData) { types.formUnion(storageTypes) }
        if targets.contains(.cache) { types.formUnion(cacheTypes) }
        guard !types.isEmpty else { return }

        await profile.dataStore.removeData(ofTypes: types, modifiedSince: since)
        debugLog("privacy: cleared \(types.count) data types since \(since) in \(profile.name)")
    }

    /// how many sites hold data in a profile's jar — the "23 sites" line under
    /// the button. a count, not a size: WebKit only reports byte sizes for some
    /// record types, so a total would be quietly wrong
    static func siteRecordCount(in profile: Profile) async -> Int {
        let records = await profile.dataStore.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        return Set(records.map(\.displayName)).count
    }
}
