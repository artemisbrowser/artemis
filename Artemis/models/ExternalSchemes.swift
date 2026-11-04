// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import AppKit

/// links in schemes WebKit doesn't render (`mailto:`, `zoommtg:`…) and which sites
/// may hand them to another app. a consent boundary, not a security one: each
/// site-and-scheme asks first, and is remembered only when the user says so
@MainActor
enum ExternalSchemes {
    /// schemes WebKit renders, redirects, or resolves internally
    private static let internallyHandled: Set<String> = [
        "http", "https", "about", "data", "blob", "javascript", "file",
        // extension pages resolve inside web views built from the extension runtime
        "webkit-extension", "safari-web-extension", "chrome-extension", "moz-extension",
    ]

    /// schemes never handed out, whatever the user clicks
    private static let blocked: Set<String> = [
        "x-apple-helpbasic", "help", "ftp", "afp", "smb", "vnc", "ssh", "telnet", "x-man-page",
        "applescript", "shortcuts", "x-apple.systempreferences", "settings-navigation",
    ]

    static func isInternal(_ scheme: String?) -> Bool {
        guard let scheme else { return true }
        return internallyHandled.contains(scheme.lowercased())
    }

    /// true when this link may be offered to another app at all
    static func canOffer(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), !scheme.isEmpty else { return false }
        return !internallyHandled.contains(scheme) && !blocked.contains(scheme)
    }

    /// display name of the app macOS would open this with; nil when nothing claims it
    static func handlerName(for url: URL) -> String? {
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: url) else { return nil }
        return FileManager.default.displayName(atPath: app.path)
            .replacingOccurrences(of: ".app", with: "")
    }

    // MARK: - Remembered answers

    private static var allowed: Set<String> = load()
    private static let file = "external-schemes.json"

    private static func key(site: String, scheme: String) -> String {
        "\(site.lowercased())|\(scheme.lowercased())"
    }

    static func isAllowed(site: String, scheme: String) -> Bool {
        allowed.contains(key(site: site, scheme: scheme))
    }

    static func allow(site: String, scheme: String) {
        allowed.insert(key(site: site, scheme: scheme))
        save()
    }

    /// clears every remembered answer; part of Clear Browsing Data
    static func forgetAll() {
        allowed = []
        AppStorageLocation.discardUnreadable(of: AppStorageLocation.file(file))
        save(keepsBackup: false)
    }

    private static func load() -> Set<String> {
        let url = AppStorageLocation.file(file)
        return Set(AppStorageLocation.loadDurable([String].self, from: url) ?? [])
    }

    private static func save(keepsBackup: Bool = true) {
        guard let data = try? JSONEncoder().encode(Array(allowed).sorted()) else { return }
        AppStorageLocation.writeDurableNow(data, to: AppStorageLocation.file(file), keepsBackup: keepsBackup)
    }
}
