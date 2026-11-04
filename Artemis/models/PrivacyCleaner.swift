// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import WebKit

/// what a clear touches. history, site data, cache, archive, page text and autofill are
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
    /// saved addresses and cards, card numbers included
    static let autofill = ClearTargets(rawValue: 1 << 8)

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
        SpotlightIndex.forget(.profile(profile.id))

        if targets.contains(.history) {
            profile.history.clear(since: since)
            await Intelligence.shared.reset()
            // the recently closed stack names pages too; a space since deleted counts as this profile's
            func isCleared(_ space: UUID, _ closedAt: Date) -> Bool {
                closedAt >= since && (manager.spaces.first { $0.id == space }?.profileID ?? profile.id) == profile.id
            }
            manager.closedTabs.removeAll { isCleared($0.spaceID, $0.closedAt) }
            manager.closedFolders.removeAll { isCleared($0.spaceID, $0.closedAt) }
            // the command bar's learned inputs, each tab's back/forward list and the
            // model's tab names are history too, but untimestamped: only a full clear takes them
            if range == .all {
                profile.inputHistory.clear()
                TabNameStore.shared.clearAllGenerated()
                for tab in profile.essentials { tab.forgetSessionHistory() }
                for space in manager.spaces where space.profileID == profile.id {
                    for tab in space.tabs {
                        tab.forgetSessionHistory()
                        TabStateStore.remove(tab.id)
                    }
                }
            }
        }
        // an icon on disk names a site visited, and is only a cache
        if !targets.isDisjoint(with: [.history, .cache]) { FaviconStore.shared.removeIcons(since: since) }
        if targets.contains(.archive) { profile.archive.clear(since: since) }
        // the downloads list, zoom and the per-site consents aren't timestamped: any range
        // clears them all
        if targets.contains(.downloads) { DownloadManager.shared.clearFinished() }
        if targets.contains(.zoom) { ZoomStore.shared.clear() }
        if targets.contains(.permissions) {
            SitePermissionStore.shared.forgetAll()
            ExternalSchemes.forgetAll()
            CertificateTrust.forgetAll()
        }
        if targets.contains(.pageText) { await profile.pageIndex.clear(since: since) }
        if targets.contains(.autofill) { AutofillStore.shared.deleteAll(in: profile.id, since: since) }

        var types: Set<String> = []
        if targets.contains(.siteData) { types.formUnion(storageTypes) }
        if targets.contains(.cache) { types.formUnion(cacheTypes) }
        guard !types.isEmpty else { return }

        await profile.dataStore.removeData(ofTypes: types, modifiedSince: since)
        debugLog("privacy: cleared \(types.count) data types since \(since) in \(profile.name)")
    }

    /// how many sites hold data in a profile's jar. a count, not a size: WebKit
    /// reports byte sizes for only some record types
    static func siteRecordCount(in profile: Profile) async -> Int {
        let records = await profile.dataStore.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        return Set(records.map(\.displayName)).count
    }
}
