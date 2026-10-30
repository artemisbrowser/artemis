import AppKit
import WebKit

/// where an installed extension came from — drives the install pipeline and the
/// little source badge in the manager UI
enum ExtensionSource: String, Codable {
    case disk  // sideloaded folder / archive
    case chrome  // chrome web store
    case firefox  // addons.mozilla.org
    case catalog  // curated in-app list

    var label: String {
        switch self {
        case .disk: "Disk"
        case .chrome: "Chrome Web Store"
        case .firefox: "Firefox Add-ons"
        case .catalog: "Catalog"
        }
    }
}

/// one installed extension: the package WebKit parsed, the profiles it runs in,
/// and a context per profile (each profile's controller runs its own instance,
/// with its own storage). the context id is the stored id in every profile, so
/// runtime.id and the store's id agree everywhere, as in Chrome
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
    /// installed before profiles had their own extensions: another profile's first
    /// instance starts as a copy of the default profile's, so nothing logs out
    @ObservationIgnored var seedsFromDefault = false

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

    /// its context in one profile, built the first time that profile needs it
    @MainActor
    func forget(_ profile: UUID) {
        contexts[profile] = nil
        profiles.remove(profile)
    }

    func context(in profile: UUID) -> WKWebExtensionContext {
        if let existing = contexts[profile] { return existing }
        let context = WKWebExtensionContext(for: webExtension)
        context.uniqueIdentifier = id
        if let url = ExtensionCompat.baseURL(storedID: id) { context.baseURL = url }
        context.isInspectable = true
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

    var summary: String? { webExtension.displayDescription }

    /// toolbar/menu icon for the action, falling back to the extension icon
    func icon(size: CGFloat) -> NSImage? {
        let dimension = CGSize(width: size, height: size)
        return webExtension.actionIcon(for: dimension) ?? webExtension.icon(for: dimension)
    }

    /// human-readable permissions the extension asks for, for the consent UI
    var requestedPermissionLabels: [String] {
        webExtension.requestedPermissions.map { $0.rawValue }.sorted()
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
        case "history": "Read your browsing history"
        case "downloads": "Manage your downloads"
        case "clipboardWrite": "Write to the clipboard"
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

/// the codable record we persist for each installed extension; the heavy WebKit
/// objects are rebuilt from disk on launch. a record from before per-profile
/// extensions has no `profiles` and runs in every profile, as it did
struct ExtensionRecord: Codable {
    var id: String
    var source: ExtensionSource
    var isEnabled: Bool
    var isPinned: Bool
    var profiles: [UUID]?
}
