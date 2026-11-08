// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import WebKit

/// the browser-data namespaces' matching, shapes, website data and user-script files, which
/// the bridge uses to answer from its profiles
nonisolated enum ExtensionData {
    /// WebKit drops the permission keys it doesn't implement, so the manifest is the record. only
    /// required ones count: nothing grants an optional one WebKit doesn't know
    static func declares(_ permission: String, _ context: WKWebExtensionContext) -> Bool {
        ((context.webExtension.manifest["permissions"] as? [Any]) ?? []).contains { $0 as? String == permission }
    }

    // MARK: - History

    /// Chrome's history.search: every word in the url or title, within the time
    /// range (the last 24 hours unless given), newest first; a `url` matches exactly
    static func history(_ entries: [HistoryEntry], matching query: [String: Any]) -> [HistoryEntry] {
        let date = { (key: String) in (query[key] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) } }
        if let url = query["url"] as? String {
            return entries.filter { $0.url.absoluteString == url }
        }
        let words = (query["text"] as? String ?? "").lowercased().split(separator: " ")
        let start = date("startTime") ?? date("start") ?? Date().addingTimeInterval(-86_400)
        let end = date("endTime") ?? date("end") ?? .distantFuture
        let limit = max(0, query["maxResults"] as? Int ?? 100)
        return entries
            .filter { entry in
                guard entry.lastVisited >= start, entry.lastVisited <= end else { return false }
                let haystack = (entry.url.absoluteString + " " + entry.title).lowercased()
                return words.allSatisfy { haystack.contains($0) }
            }
            .sorted { $0.lastVisited > $1.lastVisited }
            .prefix(limit).map { $0 }
    }

    static func item(_ entry: HistoryEntry) -> [String: Any] {
        ["url": entry.url.absoluteString, "title": entry.title,
         "lastVisitTime": entry.lastVisited.timeIntervalSince1970 * 1000,
         "visitCount": entry.visitCount, "typedCount": entry.typedCount]
    }

    static func sessionTab(id: String, url: URL, title: String, pinned: Bool) -> [String: Any] {
        ["sessionId": id, "url": url.absoluteString, "title": title, "index": -1, "windowId": -1,
         "active": false, "pinned": pinned, "highlighted": false, "incognito": false,
         "selected": false, "discarded": false, "autoDiscardable": true, "groupId": -1]
    }

    // MARK: - Browsing data

    /// passwords and form data stay: the vault is the user's, not an extension's to wipe
    private static let dataTypes: [String: [String]] = [
        "appcache": [WKWebsiteDataTypeOfflineWebApplicationCache],
        "cache": [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeFetchCache],
        "cacheStorage": [WKWebsiteDataTypeFetchCache],
        "cookies": [WKWebsiteDataTypeCookies],
        "fileSystems": [WKWebsiteDataTypeFileSystem],
        "indexedDB": [WKWebsiteDataTypeIndexedDBDatabases],
        "localStorage": [WKWebsiteDataTypeLocalStorage, WKWebsiteDataTypeSessionStorage],
        "serviceWorkers": [WKWebsiteDataTypeServiceWorkerRegistrations],
        "webSQL": [WKWebsiteDataTypeWebSQLDatabases],
    ]

    /// the website-data half of browsingData.remove, in one profile's store; false, removing
    /// nothing, for a `since` with an origin filter, as a site's records carry no date
    static func removeWebsiteData(
        _ requested: [String], _ message: [String: Any], from store: WKWebsiteDataStore
    ) async -> Bool {
        let since = Date(timeIntervalSince1970: (message["since"] as? Double ?? 0) / 1000)
        let types = Set(requested.flatMap { dataTypes[$0] ?? [] })
        guard !types.isEmpty else { return true }
        let hosts = { (key: String) in
            Set(((message[key] as? [String]) ?? []).compactMap { URL(string: $0)?.host() })
        }
        let only = hosts("origins"), except = hosts("excludeOrigins")
        guard !only.isEmpty || !except.isEmpty else {
            await store.removeData(ofTypes: types, modifiedSince: since)
            return true
        }
        guard since.timeIntervalSince1970 <= 0 else { return false }
        // records are kept per registrable domain, so a host matches its domain's record
        let covers = { (hosts: Set<String>, domain: String) in
            hosts.contains { $0 == domain || $0.hasSuffix("." + domain) }
        }
        let records = await store.dataRecords(ofTypes: types).filter { record in
            only.isEmpty ? !covers(except, record.displayName) : covers(only, record.displayName)
        }
        await store.removeData(ofTypes: types, for: records)
        return true
    }

    // MARK: - User scripts

    /// user-script code lives as files in the extension's own package, where
    /// scripting.registerContentScripts can name it; nothing outside that folder. each profile has
    /// its own files and registry, the default profile's at the folder's top
    static func userScriptFiles(
        _ type: String, _ message: [String: Any], for context: WKWebExtensionContext, in profile: UUID
    ) -> [String: Any] {
        guard let root = ExtensionInstaller.resourceURL(forStoredID: context.uniqueIdentifier)
        else { return ["ok": false] }
        let relative = "__artemis/user" + (profile == Profile.defaultID ? "" : "/" + profile.uuidString)
        let folder = root.appendingPathComponent(relative, isDirectory: true)
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let safe = { (name: String) in
            String(name.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "-" ? Character($0) : "_" })
        }
        switch type {
        case "userScripts.write":
            guard let name = message["name"] as? String, let code = message["code"] as? String
            else { return ["ok": false] }
            let file = safe(name) + ".js"
            // a byte-order mark keeps non-ASCII code UTF-8 however it is loaded
            guard (try? (Data([0xEF, 0xBB, 0xBF]) + Data(code.utf8))
                .write(to: folder.appendingPathComponent(file))) != nil
            else { return ["ok": false] }
            return ["ok": true, "path": relative + "/" + file]
        case "userScripts.delete":
            for name in (message["names"] as? [String]) ?? [] {
                try? fm.removeItem(at: folder.appendingPathComponent(safe(name) + ".js"))
            }
            return ["ok": true]
        default:
            let registry = folder.appendingPathComponent("registry.json")
            if let value = message["set"] {
                guard let data = try? JSONSerialization.data(withJSONObject: value) else { return ["ok": false] }
                try? data.write(to: registry)
                return ["ok": true]
            }
            let stored = (try? Data(contentsOf: registry))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? [:]
            return ["ok": true, "registry": stored]
        }
    }
}
