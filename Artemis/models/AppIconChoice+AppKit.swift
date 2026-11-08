// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import AppKit

/// any choice but the bundled one is written onto the app bundle as a Finder custom icon
extension AppIconChoice {
    /// what the bundle's custom icon was last written as: "<choice>-<dark>", "" for none
    private static let writtenKey = "appIconWritten"

    func image(dark: Bool) -> NSImage? {
        NSImage(named: "icon-\(rawValue)-\(dark ? "dark" : "light")")
    }

    /// the icon style in System Settings › Appearance, which can differ from the system's
    static var iconsAreDark: Bool {
        let theme = UserDefaults.standard.string(forKey: "AppleIconAppearanceTheme") ?? ""
        if theme.hasSuffix("Dark") { return true }
        if theme.hasSuffix("Light") { return false }
        return NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    /// shows the choice in the running Dock tile, and on disk for Finder and a quit Dock
    static func apply() {
        let choice = current, dark = iconsAreDark
        let image = choice == bundled ? nil : choice.image(dark: dark)
        NSApp.applicationIconImage = image

        let bundle = Bundle.main.bundlePath
        let stamp = image == nil ? "" : "\(choice.rawValue)-\(dark)"
        // an update replaces the bundle and drops the custom icon with it
        let onDisk = FileManager.default.fileExists(atPath: bundle + "/Icon\r")
            ? UserDefaults.standard.string(forKey: writtenKey) ?? "?" : ""
        guard onDisk != stamp, NSWorkspace.shared.setIcon(image, forFile: bundle, options: []) else { return }
        UserDefaults.standard.set(stamp, forKey: writtenKey)
        NSWorkspace.shared.noteFileSystemChanged(bundle)
        DistributedNotificationCenter.default().postNotificationName(
            changedNotification, object: bundle, deliverImmediately: true)
    }
}
