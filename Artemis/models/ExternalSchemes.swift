import AppKit

/// Links in schemes WebKit doesn't render — `mailto:`, `zoommtg:`, `slack:`,
/// `msteams:` — and which site is allowed to hand them to another app.
///
/// Handing a link to `NSWorkspace` launches an application, so it is asked
/// once per site-and-scheme and remembered only when the user says so. Nothing
/// here is a security boundary on its own: the receiving app still validates
/// its own URLs. It is a consent boundary, so a page can't launch apps by
/// navigating an invisible iframe.
@MainActor
enum ExternalSchemes {
    /// schemes WebKit renders, redirects, or resolves internally. Everything
    /// else is somebody else's job.
    private static let internallyHandled: Set<String> = [
        "http", "https", "about", "data", "blob", "javascript", "file",
        // extension pages — options, popups, anything an extension navigates to.
        // These resolve only inside a web view built from the runtime's
        // configuration, and belong to us however alien the scheme looks
        "webkit-extension", "safari-web-extension", "chrome-extension", "moz-extension",
    ]

    /// schemes that are never handed out, whatever the user clicks. They exist
    /// to reach the shell or the browser's own internals, and a page has no
    /// business asking for them.
    private static let blocked: Set<String> = [
        "x-apple-helpbasic", "help", "ftp", "afp", "smb", "vnc", "ssh", "telnet",
        "applescript", "shortcuts", "x-apple-systempreferences",
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

    /// the app macOS would open this with, by display name. nil when nothing
    /// claims the scheme — worth saying out loud rather than silently failing
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

    /// used by Clear Browsing Data: these are site-scoped permissions and belong
    /// with the rest of what a site was allowed to do
    static func forgetAll() {
        allowed = []
        save()
    }

    private static func load() -> Set<String> {
        let url = AppStorageLocation.file(file)
        return Set(AppStorageLocation.loadDurable([String].self, from: url) ?? [])
    }

    private static func save() {
        guard let data = try? JSONEncoder().encode(Array(allowed).sorted()) else { return }
        AppStorageLocation.writeDurableNow(data, to: AppStorageLocation.file(file))
    }

    // MARK: - Handoff

    /// hand the link to whichever app claims it. Returns false when the launch
    /// itself failed, which the caller reports rather than swallowing
    @discardableResult
    static func open(_ url: URL) -> Bool {
        NSWorkspace.shared.open(url)
    }
}
