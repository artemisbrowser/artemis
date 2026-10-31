import WebKit

/// The user-content controllers tabs share: one per profile, and one per profile
/// for its incognito pages. A WebExtensionController injects its content scripts
/// into every controller its pages use, so profiles can't share one without
/// carrying one profile's extensions into another's pages. Artemis's own scripts
/// and rule lists go in through `everywhere`, which also reaches controllers made later.
enum SharedWebContent {
    private static var profiles: [UUID: WKUserContentController] = [:]
    private static var privates: [UUID: WKUserContentController] = [:]
    private static var installers: [(WKUserContentController) -> Void] = []

    /// `isPrivate`: the profile's incognito pages, where only extensions allowed there inject
    static func userContentController(for profile: UUID, isPrivate: Bool = false) -> WKUserContentController {
        if let existing = (isPrivate ? privates : profiles)[profile] { return existing }
        let controller = WKUserContentController()
        if isPrivate { privates[profile] = controller } else { profiles[profile] = controller }
        for install in installers { install(controller) }
        return controller
    }

    static var all: [WKUserContentController] { Array(profiles.values) + privates.values }

    static func remove(_ profile: UUID) {
        profiles[profile] = nil
        privates[profile] = nil
    }

    /// run `install` on every controller now and on each one made later
    static func everywhere(_ install: @escaping (WKUserContentController) -> Void) {
        installers.append(install)
        for controller in all { install(controller) }
    }
}
