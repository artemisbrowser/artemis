import AppKit
import SwiftUI

/// the app icon's colour. macOS has no alternate-icon API, so any choice but the
/// bundled one is written onto the app bundle as a Finder custom icon; iOS uses its own
enum AppIconChoice: String, CaseIterable, Identifiable {
    case rigel
    case aurora
    case hydrogenAlpha
    case oxygenIII
    case neptune
    case mars
    case betelgeuse
    case io
    case moon
    case cosmicLatte

    var id: String { rawValue }

    static let storageKey = "appIcon"
    /// the colour AppIcon.icon is drawn in
    static let bundled = AppIconChoice.rigel
    /// tells the Dock tile plugin to redraw; the object is the bundle path
    static let changedNotification = Notification.Name("dev.findles.Artemis.appIconChanged")

    static var current: AppIconChoice {
        let raw = UserDefaults.standard.string(forKey: storageKey)
        return raw.flatMap(AppIconChoice.init) ?? bundled
    }

    var label: String {
        switch self {
        case .aurora: "Aurora"
        case .hydrogenAlpha: "Hydrogen-alpha"
        case .oxygenIII: "Oxygen III"
        case .neptune: "Neptune"
        case .rigel: "Rigel"
        case .mars: "Mars"
        case .betelgeuse: "Betelgeuse"
        case .io: "Io"
        case .moon: "The Moon"
        case .cosmicLatte: "Cosmic Latte"
        }
    }

    /// the A and comet's colour, light end then base, for anything drawn to match the icon
    var glyph: (light: Color, base: Color) {
        switch self {
        case .aurora: (rgb(0x57c89a), rgb(0x2f8f68))
        case .hydrogenAlpha: (rgb(0xda8097), rgb(0xc2385a))
        case .oxygenIII: (rgb(0x40ccd8), rgb(0x1f8f99))
        case .neptune: (rgb(0x6785dc), rgb(0x2a4fb8))
        case .rigel: (rgb(0x9ac0e9), rgb(0x4a8fd8))
        case .mars: (rgb(0xd98b6b), rgb(0xb5562e))
        case .betelgeuse: (rgb(0xe8a77c), rgb(0xd9702a))
        case .io: (rgb(0xe2bf55), rgb(0xb8921f))
        case .moon: (rgb(0xaeb1b6), rgb(0x7b8088))
        case .cosmicLatte: (rgb(0xccbea9), rgb(0xa8906c))
        }
    }
}

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

private func rgb(_ hex: Int) -> Color {
    Color(red: Double(hex >> 16 & 255) / 255, green: Double(hex >> 8 & 255) / 255, blue: Double(hex & 255) / 255)
}
