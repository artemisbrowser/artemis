// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import Foundation

/// Handoff: the selected tab's page, offered to the user's other devices as one
/// `NSUserActivityTypeBrowsingWeb` activity re-pointed as the selection changes
@MainActor
final class Continuity {
    private var activity: NSUserActivity?

    /// the page currently being advertised, or nil when nothing is
    var advertisedURL: URL? { activity?.webpageURL }

    /// offer `url` as the page being read. a private page, or anything but
    /// http(s), withdraws the offer instead
    func offer(_ url: URL?, title: String, isPrivate: Bool) {
        guard !isPrivate, let url, let scheme = url.scheme,
            scheme == "http" || scheme == "https"
        else { return withdraw() }

        let current = activity ?? NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb)
        current.webpageURL = url
        current.title = title.isEmpty ? (url.host() ?? url.absoluteString) : title
        // eligibility must be set before `becomeCurrent`
        current.isEligibleForHandoff = true
        activity = current
        current.becomeCurrent()
    }

    func withdraw() {
        activity?.invalidate()
        activity = nil
    }
}
