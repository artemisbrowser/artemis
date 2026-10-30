import WebKit

/// The user-content controllers tabs share: one per profile, plus incognito's.
/// A WebExtensionController injects its content scripts into every controller its
/// pages use, so profiles can't share one without carrying one profile's
/// extensions into another's pages. Artemis's own scripts and rule lists go in
/// through `everywhere`, which also reaches controllers made later.
enum SharedWebContent {
    /// incognito pages' controller: Artemis's scripts and rule lists, no extensions
    static let privateUserContentController = WKUserContentController()

    private static var profiles: [UUID: WKUserContentController] = [:]
    private static var installers: [(WKUserContentController) -> Void] = []

    static func userContentController(for profile: UUID) -> WKUserContentController {
        if let existing = profiles[profile] { return existing }
        let controller = WKUserContentController()
        profiles[profile] = controller
        for install in installers { install(controller) }
        return controller
    }

    static var all: [WKUserContentController] { [privateUserContentController] + profiles.values }

    static func remove(_ profile: UUID) { profiles[profile] = nil }

    /// run `install` on every controller now and on each one made later
    static func everywhere(_ install: @escaping (WKUserContentController) -> Void) {
        installers.append(install)
        for controller in all { install(controller) }
    }
}
