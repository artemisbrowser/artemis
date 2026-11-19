// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import AppKit
import WebKit

/// the namespaces that read or change the browser itself, answered from the profile the asking
/// instance runs in, never another. each answers only if the manifest declares its permission
extension ExtensionAPIBridge {
    func handleBrowserData(
        _ type: String, _ message: [String: Any], for context: WKWebExtensionContext
    ) async -> [String: Any]? {
        let manager = BrowserWindows.shared.browserScope ?? ExtensionManager.shared.tabManager
        let profileID = context.webExtensionController.flatMap(WebExtensionRuntime.profile(of:))
        let profile = profileID.flatMap { id in manager?.core.profile(id) }
        let closedTabs = (manager?.closedTabs ?? []).filter { closed in
            manager?.spaces.first { $0.id == closed.spaceID }?.profileID == profileID
        }
        switch type {
        case "history.search":
            guard ExtensionData.declares("history", context), let profile else { return ["items": []] }
            return ["items": ExtensionData.history(shown(profile, to: context), matching: message).map(ExtensionData.item)]

        case "history.add":
            guard ExtensionData.declares("history", context), let profile,
                let url = (message["url"] as? String).flatMap(URL.init(string:)),
                url.scheme == "http" || url.scheme == "https", !ContentBlocker.shared.isAdult(url)
            else { return ["ok": false] }
            let title = message["title"] as? String ?? ""
            let hidden = profile.history.entries.contains { $0.url == url && $0.isHidden(by: SpaceLock.shared.lockedIDs) }
            guard hidden || ExtensionManager.shared.isVisitedPrivately(url) else {
                profile.history.record(url: url, title: title)
                return ["ok": true]
            }
            let key = Self.key(of: context, in: profile.id)
            let earlier = Self.added[key]?[url]?.visitCount ?? 0
            Self.added[key, default: [:]][url] = HistoryEntry(url: url, title: title, lastVisited: Date(), visitCount: earlier + 1)
            return ["ok": true]

        case "history.delete":
            guard ExtensionData.declares("history", context), let profile else { return ["urls": []] }
            if message["all"] as? Bool == true, let manager {
                await clearHistory(since: nil, in: profile, for: context, manager: manager)
                return ["urls": []]
            }
            let doomed = Set(ExtensionData.history(shown(profile, to: context), matching: message.merging(
                ["maxResults": Int.max, "text": ""]) { $1 }).map(\.url))
            let key = Self.key(of: context, in: profile.id)
            Self.added[key] = Self.added[key]?.filter { !doomed.contains($0.key) }
            let locked = SpaceLock.shared.lockedIDs
            profile.history.forget { doomed.contains($0.url) && !$0.isHidden(by: locked) }
            return ["urls": doomed.map(\.absoluteString)]

        case "topSites.get":
            guard ExtensionData.declares("topSites", context), let profile else { return ["sites": []] }
            let top = shown(profile, to: context).sorted { $0.visitCount > $1.visitCount }.prefix(10)
            return ["sites": top.map { ["url": $0.url.absoluteString, "title": $0.title] }]

        case "sessions.recent":
            guard ExtensionData.declares("sessions", context), let manager else { return ["sessions": []] }
            let limit = max(0, message["maxResults"] as? Int ?? 25)
            return ["sessions": closedTabs.prefix(limit).map { closed in
                ["lastModified": Int(closed.closedAt.timeIntervalSince1970),
                 "tab": ExtensionData.sessionTab(id: closed.id.uuidString, url: closed.url, title: closed.title,
                    pinned: closed.isPinned)]
            }]

        case "sessions.restore":
            guard ExtensionData.declares("sessions", context), let manager else { return [:] }
            let wanted = (message["sessionId"] as? String).flatMap { id in
                closedTabs.first { $0.id.uuidString == id }
            } ?? closedTabs.first
            guard let tab = wanted.map({ manager.reopen($0) }) ?? nil,
                let url = tab.url ?? tab.pendingURL
            else { return [:] }
            return ["session": ["lastModified": Int(Date().timeIntervalSince1970),
                "tab": ExtensionData.sessionTab(id: tab.id.uuidString, url: url, title: tab.title, pinned: tab.isPinned)]]

        case "browsingData.remove":
            guard ExtensionData.declares("browsingData", context), let profile, let manager else { return ["ok": false] }
            return ["ok": await removeBrowsingData(message, from: profile, for: context, manager: manager)]

        case "userScripts.write", "userScripts.delete", "userScripts.registry":
            guard ExtensionData.declares("userScripts", context), let profileID else { return ["ok": false] }
            let reply = ExtensionData.userScriptFiles(type, message, for: context, in: profileID)
            if message["set"] != nil { UserScriptWorld.sync(context, in: profileID) }
            return reply

        case "userScripts.reply", "userScripts.port", "userScripts.execute", "userScripts.tabMessage":
            guard ExtensionData.declares("userScripts", context), let profileID else { return ["ok": false] }
            return await UserScriptWorld.handle(type, message, for: context, in: profileID)

        case "system.display":
            guard ExtensionData.declares("system.display", context) else { return ["displays": []] }
            return ["displays": Self.displays()]

        case "fontSettings.list":
            guard ExtensionData.declares("fontSettings", context) else { return ["fonts": []] }
            return ["fonts": NSFontManager.shared.availableFontFamilies.sorted()
                .map { ["fontId": $0, "displayName": $0] }]

        default:
            return nil
        }
    }

    // MARK: - Browsing data

    /// false, removing nothing, when the website data can't be removed as asked
    private func removeBrowsingData(
        _ message: [String: Any], from profile: Profile, for context: WKWebExtensionContext, manager: TabManager
    ) async -> Bool {
        let requested = (message["types"] as? [String]) ?? []
        let since = Date(timeIntervalSince1970: (message["since"] as? Double ?? 0) / 1000)
        guard await ExtensionData.removeWebsiteData(requested, message, from: profile.dataStore) else { return false }
        if requested.contains("history") {
            await clearHistory(since: since.timeIntervalSince1970 <= 0 ? nil : since, in: profile, for: context, manager: manager)
        }
        return true
    }

    // MARK: - History

    /// visits `history.add` gave a page a locked space hides or a private tab shows, by extension and
    /// profile: only that extension sees them, as it would a page never visited, and none is stored
    private static var added: [String: [URL: HistoryEntry]] = [:]

    /// the trail an extension may read or delete from: a locked space's visits are not in it, the
    /// visits it added itself are
    private func shown(_ profile: Profile, to context: WKWebExtensionContext) -> [HistoryEntry] {
        let entries = profile.history.entries(hiding: SpaceLock.shared.lockedIDs)
        guard var added = Self.added[Self.key(of: context, in: profile.id)], !added.isEmpty else { return entries }
        return entries.map { entry in
            guard let extra = added.removeValue(forKey: entry.url) else { return entry }
            let later = extra.lastVisited > entry.lastVisited ? extra : entry
            return HistoryEntry(url: entry.url, title: later.title, lastVisited: later.lastVisited,
                visitCount: entry.visitCount + extra.visitCount, typedCount: entry.typedCount)
        } + added.values
    }

    /// all of history (nil) clears as Settings' Clear Browsing Data does, input history and tab
    /// session blobs with it. while a locked space hides visits, only the pages shown go
    private func clearHistory(
        since: Date?, in profile: Profile, for context: WKWebExtensionContext, manager: TabManager
    ) async {
        let key = Self.key(of: context, in: profile.id)
        Self.added[key] = Self.added[key]?.filter { entry in since.map { entry.value.lastVisited < $0 } ?? false }
        let locked = SpaceLock.shared.lockedIDs
        if profile.history.entries.contains(where: { $0.isHidden(by: locked) }) {
            profile.history.forget { !$0.isHidden(by: locked) && $0.lastVisited >= since ?? .distantPast }
        } else if let since {
            profile.history.clear(since: since)
        } else {
            return await PrivacyCleaner.clear(.history, range: .all, in: profile, manager: manager)
        }
        SpotlightIndex.forget(.profile(profile.id))
    }

    // MARK: - Displays

    /// Chrome's DisplayUnitInfo, in its top-left screen space
    private static func displays() -> [[String: Any]] {
        let height = NSScreen.screens.first?.frame.height ?? 0
        let rect = { (r: CGRect) -> [String: Any] in
            ["left": Int(r.minX), "top": Int(height - r.maxY), "width": Int(r.width), "height": Int(r.height)]
        }
        return NSScreen.screens.enumerated().map { index, screen in
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            let dpi = 72 * screen.backingScaleFactor
            return [
                "id": number?.stringValue ?? String(index), "name": screen.localizedName,
                "isPrimary": index == 0, "isEnabled": true, "isUnified": false,
                "isInternal": number.map { CGDisplayIsBuiltin($0.uint32Value) != 0 } ?? false,
                "bounds": rect(screen.frame), "workArea": rect(screen.visibleFrame),
                "dpiX": dpi, "dpiY": dpi, "rotation": 0, "mirroringSourceId": "",
                "mirroringDestinationIds": [], "modes": [], "displayZoomFactor": 1,
                "availableDisplayZoomFactors": [], "hasTouchSupport": false,
                "hasAccelerometerSupport": false,
                "overscan": ["left": 0, "top": 0, "right": 0, "bottom": 0],
            ]
        }
    }
}
