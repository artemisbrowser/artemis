// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import Foundation

/// Gmail's unread inbox, from the Atom feed it serves a signed-in session: up to 20 entries and
/// `fullcount`, the whole unread count
enum Gmail {
    nonisolated static func feedURL(account: Int) -> URL {
        URL(string: "https://mail.google.com/mail/u/\(max(0, account))/feed/atom")!
    }

    /// the `<n>` of a `/mail/u/<n>/` url, 0 when it names none; nil when it names an account
    /// some other way, as by address
    nonisolated static func account(in url: URL) -> Int? {
        let parts = url.pathComponents
        guard let u = parts.firstIndex(of: "u"), u > 0, parts[u - 1] == "mail", parts.indices.contains(u + 1)
        else { return 0 }
        return Int(parts[u + 1]).map { max(0, $0) }
    }

    /// a refusal (401, 403, or a redirect off mail.google.com, as to the sign-in page) is
    /// `.needsSignIn`, never an empty inbox. logs the status and counts only
    @concurrent
    nonisolated static func rows(from response: ProfileFetch.Response) async -> LiveOutcome {
        let ok = (200..<300).contains(response.status)
        let refused = [401, 403].contains(response.status) || response.url.host()?.lowercased() != "mail.google.com"
        let feed = ok && !refused ? Feeds.parse(response.body, base: response.url) : nil
        debugLog(
            "gmail feed: HTTP \(response.status), \(feed?.rows.count ?? 0) entries, "
                + "fullcount \(feed?.fullcount.map(String.init) ?? "none")")
        if refused { return .needsSignIn }
        guard ok else { return .unavailable(response.status == 429 ? .rateLimited : .network) }
        guard let feed, feed.fullcount != nil else { return .unavailable(.unreadable) }
        return .rows(feed.rows, total: feed.fullcount)
    }
}
