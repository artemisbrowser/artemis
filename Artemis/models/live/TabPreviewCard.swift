// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import Foundation

/// what the hover card over a pinned tab or favourite shows, made from its source's outcome. the
/// text is the site's own, already plain; the card draws it only as `Text`
struct TabPreviewCard: Equatable {
    nonisolated enum Kind: String, CaseIterable, Identifiable {
        case gmail, icloudMail, outlook, webmail, github, recentPages, notifications

        var id: String { rawValue }

        var label: String {
            switch self {
            case .gmail: "Gmail"
            case .icloudMail: "iCloud Mail"
            case .outlook: "Outlook"
            case .webmail: "Other email"
            case .github: "GitHub"
            case .recentPages: "Recent pages"
            case .notifications: "Notifications"
            }
        }

        /// on unless switched off, like the master switch
        var storageKey: String { "tabPreviews." + rawValue }
        var isOn: Bool { UserDefaults.standard.object(forKey: storageKey) as? Bool ?? true }

        init?(_ source: LiveSource) {
            switch source {
            case .gmail: self = .gmail
            case .icloudMail: self = .icloudMail
            case .outlook: self = .outlook
            case .webmail: self = .webmail
            case .githubRepo: self = .github
            case .history: self = .recentPages
            case .notifications: self = .notifications
            case .feed, .github: return nil
            }
        }
    }

    struct Line: Equatable, Identifiable {
        let id: String
        let title: String
        let detail: String
        let date: Date?
        /// an SF Symbol drawn before the title
        let symbol: String?
        let link: URL
    }

    static let enabledKey = "tabPreviews"
    static var isEnabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
    private static let maxLines = 6

    let kind: Kind
    let heading: String
    /// beside the heading, as Gmail's unread count
    private(set) var count: String?
    private(set) var lines: [Line] = []
    /// plain text in place of `lines`: loading, empty, signed out or unreachable
    private(set) var message: String?
    /// an inbox with nothing unread, whose two-line `message` is drawn larger and centred
    private(set) var isAllClear = false
    private(set) var compose: URL?

    /// nil for no card: a refused space, or recent pages or notifications with none to show.
    /// a nil `outcome` is still loading
    init?(_ source: LiveSource, _ outcome: LiveOutcome?) {
        guard let kind = Kind(source) else { return nil }
        if case .unavailable(.refused) = outcome { return nil }
        self.kind = kind
        switch source {
        case .gmail(let account):
            heading = "Gmail"
            compose = URL(string: "https://mail.google.com/mail/u/\(account)/#inbox?compose=new")
        case .icloudMail:
            heading = "iCloud Mail"
        case .outlook(_, let base):
            heading = "Outlook"
            compose = base.appending(path: "deeplink/compose")
        case .webmail(let service, let page, _):
            heading = service.name
            compose = service.compose(from: page)
        case .githubRepo(let owner, let name):
            heading = "\(owner)/\(name)"
        case .history(let host):
            heading = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        default:
            heading = "Notifications"
        }
        // read off its open tab, as Outlook's and Zoho's are
        let fromTab = if case .webmail(.zoho, _, _) = source { true } else { kind == .outlook }
        let service = kind == .webmail ? heading : kind.label
        guard case .rows(let rows, let total) = outcome else {
            message =
                switch outcome {
                case nil: "Loading…"
                case .needsSignIn:
                    kind == .github
                        ? "Sign in to GitHub in this profile to see this repository."
                        : "Sign in to \(service) in this profile to see unread email."
                case .unavailable(.rateLimited): "\(service) is busy. Try again in a minute."
                case .unavailable(.unreadable) where fromTab: "Open the Inbox in this tab to see unread email."
                default: "Couldn't reach \(service) just now."
                }
            return
        }
        let shown = rows.prefix(Self.maxLines)
        switch kind {
        case .gmail, .icloudMail, .outlook, .webmail:
            if fromTab, rows.isEmpty, let total, total > 0 { message = "Open this tab to see them." }
            if rows.isEmpty, (total ?? 0) == 0 {
                message = "No unread emails!\nYou can rest 😌"
                isAllClear = true
            }
            if let total, total > 0 { count = "\(total) unread" }
            lines = shown.map { row in
                Line(
                    id: row.id, title: row.subtitle.isEmpty ? "Unknown sender" : row.subtitle,
                    detail: row.title.isEmpty ? "No subject" : row.title, date: row.date, symbol: nil, link: row.link)
            }
        case .github:
            if rows.isEmpty { message = "No open issues or pull requests." }
            lines = shown.map { row in
                Line(
                    id: row.id, title: row.title, detail: row.subtitle + (row.state == .draft ? " · draft" : ""),
                    date: row.date,
                    symbol: row.link.path().contains("/pull/") ? "arrow.triangle.pull" : "smallcircle.filled.circle",
                    link: row.link)
            }
        case .recentPages, .notifications:
            guard !rows.isEmpty else { return nil }
            lines = shown.map { row in
                Line(id: row.id, title: row.title, detail: row.subtitle, date: row.date, symbol: nil, link: row.link)
            }
        }
    }

    /// how long ago, as a card's corner shows it: "now", "12m", "3h", "2d", then the date
    static func age(of date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(Int(seconds / 60))m"
        case ..<86400: return "\(Int(seconds / 3600))h"
        case ..<(7 * 86400): return "\(Int(seconds / 86400))d"
        default: return date.formatted(.dateTime.day().month(.abbreviated))
        }
    }
}
