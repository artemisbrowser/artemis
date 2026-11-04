import WebKit

/// the user-content controllers tabs share: one per profile plus one for its incognito pages. a
/// WebExtensionController injects into every controller its pages use, so profiles never share
/// one. Artemis's own scripts and rule lists go in through `everywhere`
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
