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
            return ["items": ExtensionData.history(profile.history.entries, matching: message).map(ExtensionData.item)]

        case "history.add":
            guard ExtensionData.declares("history", context), let profile,
                let url = (message["url"] as? String).flatMap(URL.init(string:)),
                !ExtensionManager.shared.isVisitedPrivately(url)
            else { return ["ok": false] }
            profile.history.record(url: url, title: message["title"] as? String ?? "")
            return ["ok": true]

        case "history.delete":
            guard ExtensionData.declares("history", context), let profile else { return ["urls": []] }
            if message["all"] as? Bool == true, let manager {
                await PrivacyCleaner.clear(.history, range: .all, in: profile, manager: manager)
                return ["urls": []]
            }
            let doomed = Set(ExtensionData.history(profile.history.entries, matching: message.merging(
                ["maxResults": Int.max, "text": ""]) { $1 }).map(\.url))
            profile.history.forget { doomed.contains($0.url) }
            return ["urls": doomed.map(\.absoluteString)]

        case "topSites.get":
            guard ExtensionData.declares("topSites", context), let profile else { return ["sites": []] }
            let top = profile.history.entries.sorted { $0.visitCount > $1.visitCount }.prefix(10)
            return ["sites": top.map { ["url": $0.url.absoluteString, "title": $0.title] }]

        case "sessions.recent":
            guard ExtensionData.declares("sessions", context), let manager else { return ["sessions": []] }
            let limit = message["maxResults"] as? Int ?? 25
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
            await removeBrowsingData(message, from: profile, manager: manager)
            return ["ok": true]

        case "userScripts.write", "userScripts.delete", "userScripts.registry":
            guard ExtensionData.declares("userScripts", context) else { return ["ok": false] }
            return ExtensionData.userScriptFiles(type, message, for: context)

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

    private func removeBrowsingData(_ message: [String: Any], from profile: Profile, manager: TabManager) async {
        let requested = (message["types"] as? [String]) ?? []
        let since = Date(timeIntervalSince1970: (message["since"] as? Double ?? 0) / 1000)
        // all of history clears as Settings' Clear Browsing Data does, input history and tab
        // session blobs with it
        if requested.contains("history") {
            if since.timeIntervalSince1970 <= 0 {
                await PrivacyCleaner.clear(.history, range: .all, in: profile, manager: manager)
            } else {
                profile.history.clear(since: since)
                SpotlightIndex.forget(.profile(profile.id))
            }
        }

        await ExtensionData.removeWebsiteData(requested, message, from: profile.dataStore)
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
