import Foundation

/// Handoff — the page you are reading, offered to your other devices.
///
/// One `NSUserActivity` of the system's own browsing type, re-pointed as the
/// selected tab changes. That is the whole mechanism: macOS, iOS and iPadOS all
/// understand `NSUserActivityTypeBrowsingWeb`, so the page appears in the Dock
/// and the app switcher of every device signed into the same Apple Account,
/// and Safari on the iPhone hands its page back the same way.
///
/// No infrastructure, no account of ours, and nothing leaves the user's own
/// devices — which is also why nothing in the Chromium field does it.
@MainActor
final class Continuity {
    private var activity: NSUserActivity?

    /// the page currently being advertised, or nil when nothing is
    var advertisedURL: URL? { activity?.webpageURL }

    /// Offer `url` as the page being read. Anything that isn't an ordinary web
    /// page — a burner space, a local file, an extension page — offers nothing:
    /// broadcasting an incognito page to the user's other devices would be the
    /// exact opposite of what the space is for.
    func offer(_ url: URL?, title: String, isPrivate: Bool) {
        guard !isPrivate, let url, let scheme = url.scheme,
            scheme == "http" || scheme == "https"
        else { return withdraw() }

        let current = activity ?? NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb)
        current.webpageURL = url
        current.title = title.isEmpty ? (url.host() ?? url.absoluteString) : title
        // eligibility is set before `becomeCurrent`: a handoff advertised and
        // then withdrawn is worse than one never advertised
        current.isEligibleForHandoff = true
        activity = current
        current.becomeCurrent()
    }

    /// stop advertising. Called when the page becomes one we wouldn't offer, and
    /// when the tab showing it goes away
    func withdraw() {
        activity?.invalidate()
        activity = nil
    }
}
