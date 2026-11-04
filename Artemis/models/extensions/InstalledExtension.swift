// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import AppKit
import WebKit

/// where an installed extension came from
enum ExtensionSource: String, Codable {
    case disk  // sideloaded folder / archive
    case chrome  // chrome web store
    case firefox  // addons.mozilla.org
    case catalog  // curated in-app list

    /// a source this build doesn't know reads as a sideload, so one record can't fail them all
    init(from decoder: any Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .disk
    }

    var label: String {
        switch self {
        case .disk: "Disk"
        case .chrome: "Chrome Web Store"
        case .firefox: "Firefox Add-ons"
        case .catalog: "Catalog"
        }
    }
}

/// one installed extension: the package WebKit parsed, the profiles it runs in, and a context
/// per profile, each with its own storage. every context's id is the stored id, so `runtime.id`
/// matches the store's id in every profile
@Observable
final class InstalledExtension: Identifiable {
    let id: String
    let source: ExtensionSource
    @ObservationIgnored let webExtension: WKWebExtension
    @ObservationIgnored private(set) var contexts: [UUID: WKWebExtensionContext] = [:]

    /// the profiles it is switched on in
    var profiles: Set<UUID>
    /// pinned extensions surface their action icon directly in the url bar
    var isPinned: Bool
    /// runs in its profiles' incognito windows too
    var allowsIncognito = false {
        didSet { for context in contexts.values { context.hasAccessToPrivateData = allowsIncognito } }
    }
    /// another profile's first instance starts as a copy of the default profile's storage
    @ObservationIgnored var seedsFromDefault = false
    /// bumped when WebKit reports a change to one of its actions, which aren't observable
    var actionRevision = 0

    var isEnabled: Bool { !profiles.isEmpty }

    init(
        id: String, source: ExtensionSource, webExtension: WKWebExtension,
        profiles: Set<UUID>, isPinned: Bool
    ) {
        self.id = id
        self.source = source
        self.webExtension = webExtension
        self.profiles = profiles
        self.isPinned = isPinned
    }

    @MainActor
    func forget(_ profile: UUID) {
        contexts[profile] = nil
        profiles.remove(profile)
    }

    /// its context in one profile, built the first time that profile needs it
    func context(in profile: UUID) -> WKWebExtensionContext {
        if let existing = contexts[profile] { return existing }
        let context = WKWebExtensionContext(for: webExtension)
        context.uniqueIdentifier = id
        if let url = ExtensionCompat.baseURL(storedID: id) { context.baseURL = url }
        context.isInspectable = true
        context.hasAccessToPrivateData = allowsIncognito
        contexts[profile] = context
        return context
    }

    /// its context in the profile the user is in
    @MainActor
    var context: WKWebExtensionContext { context(in: ExtensionManager.shared.currentProfile) }

    var name: String {
        webExtension.displayName ?? webExtension.displayShortName ?? "Untitled Extension"
    }

    var version: String? { webExtension.displayVersion ?? webExtension.version }

    /// the manifest's `"incognito": "not_allowed"`
    var refusesIncognito: Bool { webExtension.manifest["incognito"] as? String == "not_allowed" }

    var summary: String? { webExtension.displayDescription }

    /// toolbar/menu icon for the action, falling back to the extension icon
    func icon(size: CGFloat) -> NSImage? {
        let dimension = CGSize(width: size, height: size)
        return webExtension.actionIcon(for: dimension) ?? webExtension.icon(for: dimension)
    }

    /// the manifest keys WebKit drops that the compat bridge acts on
    private static let bridgedPermissions: Set<String> = [
        "browsingData", "clipboardRead", "downloads", "fontSettings", "history", "identity", "idle",
        "notifications", "offscreen", "proxy", "search", "sessions", "sidePanel", "system.display",
        "topSites", "userScripts",
    ]

    /// human-readable permissions the extension asks for, for the consent UI: WebKit's own, and
    /// the required `bridgedPermissions`, less those the compat patch added
    var requestedPermissionLabels: [String] {
        let declared = ((webExtension.manifest["permissions"] as? [Any]) ?? []).compactMap { $0 as? String }
            .filter(Self.bridgedPermissions.contains)
        let added = ((webExtension.manifest[ExtensionCompat.addedPermissionsKey] as? [Any]) ?? [])
            .compactMap { $0 as? String }.filter(ExtensionCompat.patchPermissions.contains)
        return Set(webExtension.requestedPermissions.map(\.rawValue) + declared).subtracting(added).sorted()
    }

    /// host match patterns the extension wants to read/modify
    var requestedHostLabels: [String] {
        webExtension.requestedPermissionMatchPatterns.map(\.string).sorted()
    }

    /// what it will be able to do, in plain words, for the install consent
    var consentLines: [String] {
        var lines: [String] = []
        let hosts = requestedHostLabels
        if hosts.contains("<all_urls>") || hosts.contains("*://*/*") {
            lines.append("Read and change data on all websites you visit")
        } else if !hosts.isEmpty {
            lines.append("Read and change data on: \(hosts.joined(separator: ", "))")
        }
        lines += requestedPermissionLabels.map(Self.consentLabel)
        return lines.isEmpty ? ["Run with no special permissions"] : lines
    }

    /// plain-language gloss for the common WebExtension permissions
    private static func consentLabel(_ permission: String) -> String {
        switch permission {
        case "tabs": "See your open tabs and their addresses"
        case "storage", "unlimitedStorage": "Store data on your device"
        case "cookies": "Read and change cookies"
        case "history": "Read and delete your browsing history"
        case "browsingData": "Delete your browsing data"
        case "sessions": "See and reopen recently closed tabs"
        case "topSites": "See your most visited sites"
        case "downloads": "Manage your downloads"
        case "fontSettings": "See your installed fonts"
        case "identity": "Open sign-in pages"
        case "idle": "See when you're away"
        case "notifications": "Show notifications"
        case "offscreen": "Run hidden pages in the background"
        case "search": "Search with your search engine"
        case "sidePanel": "Show a side panel"
        case "system.display": "See your displays"
        case "clipboardRead": "Read what you copy"
        case "clipboardWrite": "Write to the clipboard"
        case "proxy": "Route your traffic through a proxy"
        case "userScripts": "Run user scripts on pages"
        case "contextMenus", "menus": "Add items to context menus"
        case "webNavigation": "See where you navigate"
        case "webRequest": "Observe your network requests"
        case "declarativeNetRequest", "declarativeNetRequestWithHostAccess":
            "Block or modify network requests"
        case "scripting": "Run scripts on pages"
        case "alarms": "Schedule background tasks"
        case "nativeMessaging": "Communicate with native apps"
        default: permission
        }
    }

    /// load errors WebKit reported while parsing the manifest/resources
    @MainActor
    var loadErrorText: String? {
        let errs = webExtension.errors + context.errors
        guard !errs.isEmpty else { return nil }
        return errs.map { ($0 as NSError).localizedDescription }.joined(separator: "\n")
    }
}

/// the persisted form of an installed extension; a nil `profiles` runs in every profile
struct ExtensionRecord: Codable {
    var id: String
    var source: ExtensionSource
    var isEnabled: Bool
    var isPinned: Bool
    var profiles: [UUID]?
    var allowsIncognito: Bool?
}
