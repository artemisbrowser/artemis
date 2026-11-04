// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import Network
import WebKit

/// a browsing identity: its own cookies and site data, favourites, history,
/// archive, page index and saved passwords. every space belongs to exactly one
@Observable
final class Profile: Identifiable {
    /// the profile every install starts with. its jar is `WKWebsiteDataStore.default()`
    /// and its files are the app's top-level ones, so it can never be deleted
    nonisolated static let defaultID = UUID(uuidString: "A27E0000-0000-4000-8000-000000000001")!

    let id: UUID
    var name: String
    /// SF Symbol name or emoji glyph, like a space's
    var icon: String
    /// the favourites grid shown above every space in this profile
    var essentials: [BrowserTab] = []

    // the default profile also writes its choices to the app-wide keys, which
    // backups and older builds read
    var searchEngine: SearchEngine {
        didSet { mirror(searchEngine.rawValue, SearchEngine.storageKey) }
    }
    var suggestsSearches: Bool {
        didSet { mirror(suggestsSearches, SearchSuggest.enabledKey) }
    }
    /// how long an untouched Today tab waits before it's archived; 0 is never
    var archiveAfterHours: Double {
        didSet { mirror(archiveAfterHours, TabManager.autoArchiveHoursKey) }
    }

    @ObservationIgnored private(set) lazy var history = HistoryStore(fileURL: file("history.json"))
    @ObservationIgnored private(set) lazy var archive = ArchiveStore(fileURL: file("archive.json"))
    @ObservationIgnored private(set) lazy var inputHistory = InputHistory(
        fileURL: file("input-history.json"))
    @ObservationIgnored private(set) lazy var pageIndex = FullTextIndex(fileURL: file("pagetext.sqlite"))
    @ObservationIgnored private(set) lazy var translationRules = TranslationRules(
        fileURL: file("translation-rules.json"))

    /// unset settings start from the app-wide ones, which are the default profile's
    init(
        id: UUID = UUID(), name: String, icon: String, searchEngine: SearchEngine? = nil,
        suggestsSearches: Bool? = nil, archiveAfterHours: Double? = nil
    ) {
        let defaults = UserDefaults.standard
        self.id = id
        self.name = name
        self.icon = icon
        self.searchEngine = searchEngine ?? SearchEngine.stored
        self.suggestsSearches = suggestsSearches ?? defaults.bool(forKey: SearchSuggest.enabledKey)
        self.archiveAfterHours = archiveAfterHours
            ?? defaults.object(forKey: TabManager.autoArchiveHoursKey) as? Double
            ?? TabManager.defaultAutoArchiveHours
    }

    var isDefault: Bool { id == Self.defaultID }

    private func mirror(_ value: Any, _ key: String) {
        if isDefault { UserDefaults.standard.set(value, forKey: key) }
    }

    var dataStore: WKWebsiteDataStore { ProfileStore.dataStore(for: id) }

    /// where this profile keeps a file of its own
    func file(_ name: String) -> URL {
        guard !isDefault else { return AppStorageLocation.file(name) }
        let dir = Self.directory(for: id)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(name)
    }

    static func directory(for id: UUID) -> URL {
        AppStorageLocation.directory.appendingPathComponent("Profiles", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
    }
}

/// resolves a profile to its live `WKWebsiteDataStore`, one instance per profile,
/// and mints the throwaway stores incognito windows browse in
enum ProfileStore {
    private static var stores: [UUID: WKWebsiteDataStore] = [:]
    /// live incognito stores and the profile each was opened from
    private static let privateStores = NSMapTable<WKWebsiteDataStore, NSUUID>.weakToStrongObjects()

    /// each profile's proxy (the chrome.proxy compat bridge), set by a VPN enabled
    /// in it; its incognito windows inherit it, as Chrome's do
    private static var proxyConfigurations: [UUID: [ProxyConfiguration]] = [:]

    static func setProxyConfigurations(_ configs: [ProxyConfiguration], for profile: UUID) {
        proxyConfigurations[profile] = configs
        dataStore(for: profile).proxyConfigurations = configs
        for case let store as WKWebsiteDataStore in privateStores.keyEnumerator()
        where privateStores.object(forKey: store) as UUID? == profile {
            store.proxyConfigurations = configs
        }
    }

    static func dataStore(for id: UUID) -> WKWebsiteDataStore {
        guard id != Profile.defaultID else { return .default() }
        if let store = stores[id] { return store }
        let store = WKWebsiteDataStore(forIdentifier: id)
        store.proxyConfigurations = proxyConfigurations[id] ?? []
        stores[id] = store
        return store
    }

    /// a fresh non-persistent jar; whoever holds it decides how long it lives
    static func makePrivate(parent: UUID) -> WKWebsiteDataStore {
        let store = WKWebsiteDataStore.nonPersistent()
        store.proxyConfigurations = proxyConfigurations[parent] ?? []
        privateStores.setObject(parent as NSUUID, forKey: store)
        return store
    }

    /// the profile whose proxy a store browses through: its own, or its incognito window's parent
    static func proxyProfile(of store: WKWebsiteDataStore) -> UUID {
        profileID(of: store) ?? (privateStores.object(forKey: store) as UUID?) ?? Profile.defaultID
    }

    /// the profile a store belongs to; nil for an incognito store
    static func profileID(of store: WKWebsiteDataStore) -> UUID? {
        guard store.isPersistent else { return nil }
        return store.identifier ?? Profile.defaultID
    }

    /// erase a profile's site data without deleting the profile
    static func clear(_ id: UUID) async {
        await dataStore(for: id).removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }

    /// drop a deleted profile's jar from disk, after a delay: removal fails while a
    /// web view or the cached store still holds it. `reconcile` is the backstop
    static func destroy(_ id: UUID) {
        guard id != Profile.defaultID else { return }
        stores[id] = nil
        proxyConfigurations[id] = nil
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            do {
                try await WKWebsiteDataStore.remove(forIdentifier: id)
                debugLog("profile store destroyed: \(id)")
            } catch {
                debugLog("profile store removal failed (\(id)): \(error)")
            }
        }
    }

    /// on launch, delete any on-disk jar no profile owns
    static func reconcile(keeping ids: Set<UUID>) {
        Task {
            // the fetch answers on WebKit's main run loop, which only the default store starts
            _ = WKWebsiteDataStore.default()
            for id in await WKWebsiteDataStore.allDataStoreIdentifiers where !ids.contains(id) {
                try? await WKWebsiteDataStore.remove(forIdentifier: id)
                debugLog("profile reconcile: swept orphan store \(id)")
            }
        }
    }
}
