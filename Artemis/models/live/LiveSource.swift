// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import Foundation

/// one line a live source returned, a folder's item or a preview card's row. the text is the
/// site's own and is only ever shown as plain text; `link` is always http or https
nonisolated struct LiveRow: Hashable, Sendable, Identifiable {
    /// the same item keeps its id across fetches and, for GitHub, across sources
    let id: String
    let title: String
    let subtitle: String
    let link: URL
    let date: Date?
    let state: LiveState?

    nonisolated static let maxLength = 200

    /// nil unless `link` is http or https with a host
    init?(id: String, title: String, subtitle: String = "", link: URL?, date: Date? = nil, state: LiveState? = nil) {
        guard let link, ["http", "https"].contains(link.scheme?.lowercased()), link.host()?.isEmpty == false
        else { return nil }
        self.id = String(id.prefix(512))
        self.title = Self.plain(title)
        self.subtitle = Self.plain(subtitle)
        self.link = link
        self.date = date
        self.state = state
    }

    /// one line of untrusted text: controls become spaces, format characters other than the joiners
    /// and emoji tags go (bidi controls among them), whitespace collapses, and it stops at `maxLength`
    static func plain(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in text.unicodeScalars {
            let category = scalar.properties.generalCategory
            if scalar.properties.isWhitespace || category == .control {
                pendingSpace = !scalars.isEmpty
                continue
            }
            if category == .format, !["\u{200C}", "\u{200D}"].contains(scalar),
                !(0xE0020...0xE007F).contains(scalar.value)
            {
                continue
            }
            if pendingSpace { scalars.append(" ") }
            pendingSpace = false
            scalars.append(scalar)
        }
        let line = String(scalars)
        guard line.count > maxLength else { return line }
        return line.prefix(maxLength - 1).trimmingCharacters(in: .whitespaces) + "…"
    }
}

/// a GitHub item's state; approval and requested changes leave a pull request `open`
nonisolated enum LiveState: String, Codable, Sendable {
    case open, draft, merged, closed
}

/// what a source gave back. a refusal or a failure is never an empty list
nonisolated enum LiveOutcome: Sendable {
    /// newest first. `total` is the site's own count where it states one, as Gmail's unread count
    case rows([LiveRow], total: Int?)
    /// the site turned the profile's cookies away: signed out there, or the route no longer works
    case needsSignIn
    case unavailable(LiveFailure)
}

nonisolated enum LiveFailure: Error, Sendable, Equatable {
    /// an incognito, Scout or locked space, which neither fetches nor shows
    case refused
    /// unreachable, timed out, or a server error
    case network
    case rateLimited
    /// not what the source serves: not a feed, a page whose markup changed, or past the size cap
    case unreadable
}

/// where a live folder or a preview card gets its rows. cases only grow, and a case from a later
/// build fails to decode: a folder decodes its source with `try?` so that leaves a plain folder
nonisolated enum LiveSource: Codable, Hashable, Sendable {
    /// an RSS, RDF, Atom or JSON feed, fetched without cookies
    case feed(URL)
    /// the unread inbox of the account at `/mail/u/<account>/`, with the profile's Google cookies
    case gmail(account: Int)
    /// pull requests or issues for the account the profile is signed in to on github.com, kept to
    /// one repository, `owner/name`, when `repo` names one
    case github(GitHubQuery, repo: String? = nil)
    /// a repository's latest open issues and pull requests
    case githubRepo(owner: String, name: String)
    /// the profile's own recent pages on a host, from its history
    case history(host: String)
    /// the last notifications a tab posted, held in memory
    case notifications(tab: UUID)
    /// the unread inbox of the Apple Account signed in to icloud.com, or to icloud.com.cn
    case icloudMail(china: Bool)
    /// the unread inbox an Outlook tab's own page shows; `base` is its mailbox's root
    case outlook(tab: UUID, base: URL)
    /// another webmail's unread inbox, for the tab at `page`
    case webmail(Webmail, page: URL, tab: UUID)
}

nonisolated enum GitHubQuery: String, Codable, Sendable, CaseIterable {
    case created, reviewRequested, teamReviewRequested, assignedIssues
}

@MainActor
extension LiveSource {
    /// the profile live sources read for `space`; nil for a locked space, and for an incognito or
    /// Scout one, which is never in `BrowserCore.spaces`
    static func admittedProfile(of space: Space) -> Profile.ID? {
        guard BrowserCore.shared.spaces.contains(where: { $0 === space }), !SpaceLock.shared.isLocked(space)
        else { return nil }
        return space.profileID
    }

    /// what a preview card over a tab at `url` shows: Gmail, iCloud Mail, Outlook, a GitHub repo, recent
    /// pages on the document sites, else the tab's own notifications; nil when it has none
    static func preview(for url: URL, tab: UUID) -> LiveSource? {
        guard let host = url.host()?.lowercased(), ["http", "https"].contains(url.scheme?.lowercased())
        else { return nil }
        if host == "mail.google.com", ["", "/"].contains(url.path()) || url.path().hasPrefix("/mail"),
            let account = Gmail.account(in: url)
        {
            return .gmail(account: account)
        }
        let site = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        if ["icloud.com", "icloud.com.cn"].contains(site), url.path().hasPrefix("/mail") || url.fragment == "mail" {
            return .icloudMail(china: site == "icloud.com.cn")
        }
        if let base = OutlookPage.base(of: url), ["", "/"].contains(url.path()) || url.path().hasPrefix("/mail") {
            return .outlook(tab: tab, base: base)
        }
        if let service = Webmail.service(of: url) { return .webmail(service, page: url, tab: tab) }
        if let repo = GitHub.repository(in: url) { return .githubRepo(owner: repo.owner, name: repo.name) }
        let documents = ["notion.so", "linear.app", "figma.com", "atlassian.net"]
        if documents.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return .history(host: host) }
        return WebNotifications.shared.recent[tab]?.isEmpty == false ? .notifications(tab: tab) : nil
    }

    /// this source's rows for `space`'s profile, reusing a result younger than `maxAge` seconds.
    /// concurrent loads of one source share a fetch; a repo card's rows are reused for 5 minutes
    func load(in space: Space, maxAge: TimeInterval = 0) async -> LiveOutcome {
        guard let profile = Self.admittedProfile(of: space) else { return .unavailable(.refused) }
        switch self {
        case .history(let host): return Self.history(on: host, in: space)
        case .notifications(let id): return Self.notifications(of: id, in: space)
        case .outlook(let id, let base):
            let tabs = space.tabs + BrowserCore.shared.profile(of: space).essentials
            guard let tab = tabs.first(where: { $0.id == id }) else { return .unavailable(.unreadable) }
            let outcome = await OutlookPage.unread(in: tab, base: base)
            return Self.admittedProfile(of: space) == profile ? outcome : .unavailable(.refused)
        case .webmail(.zoho, _, let id):
            let tabs = space.tabs + BrowserCore.shared.profile(of: space).essentials
            guard let tab = tabs.first(where: { $0.id == id }), tab.pendingURL == nil, tab.url != nil,
                let count = Webmail.zohoCount(title: tab.title)
            else { return .unavailable(.unreadable) }
            return .rows([], total: count)
        default: break
        }
        let key = "\(profile) \(self)"
        let reuse = if case .githubRepo = self { max(maxAge, 300) } else { maxAge }
        if let hit = Self.cache[key], -hit.at.timeIntervalSinceNow < reuse { return hit.outcome }
        let task = Self.inFlight[key] ?? Task { await fetch(in: profile) }
        Self.inFlight[key] = task
        let outcome = await task.value
        // the first caller back keeps the result, unless `forget` dropped the fetch meanwhile
        if Self.inFlight[key] == task {
            Self.inFlight[key] = nil
            if case .rows = outcome {
                Self.cache = Self.cache.filter { -$0.value.at.timeIntervalSinceNow < 3600 }
                Self.cache[key] = (Date(), outcome)
            }
        }
        // the space may have locked while the fetch ran
        return Self.admittedProfile(of: space) == profile ? outcome : .unavailable(.refused)
    }

    /// keyed `<profile> <source>`, which `forget` matches by prefix
    private static var cache: [String: (at: Date, outcome: LiveOutcome)] = [:]
    private static var inFlight: [String: Task<LiveOutcome, Never>] = [:]

    /// drops what the profile's sources fetched, cached or in flight, as its data is cleared or it goes
    static func forget(_ profile: Profile.ID) {
        let prefix = "\(profile) "
        cache = cache.filter { !$0.key.hasPrefix(prefix) }
        inFlight = inFlight.filter { !$0.key.hasPrefix(prefix) }
    }

    private func fetch(in profile: UUID) async -> LiveOutcome {
        do throws(LiveFailure) {
            switch self {
            case .feed(let url):
                let response = try await ProfileFetch.send(url, accept: Feeds.accept, withCookies: false, in: profile)
                return await Feeds.rows(from: response)
            case .gmail(let account):
                let response = try await ProfileFetch.send(
                    Gmail.feedURL(account: account), accept: Feeds.accept, withCookies: true, in: profile)
                return await Gmail.rows(from: response)
            case .github(let query, let repo):
                return try await GitHub.search(query.terms(in: repo), pulls: query != .assignedIssues, in: profile)
            case .githubRepo(let owner, let name):
                return try await GitHub.repo(owner: owner, name: name, in: profile)
            case .icloudMail(let china):
                return try await ICloudMail.unread(china: china, in: profile)
            case .webmail(let service, let page, let tab):
                return try await service.unread(page: page, tab: tab, in: profile)
            case .history, .notifications, .outlook:
                return .unavailable(.refused)
            }
        } catch {
            return .unavailable(error)
        }
    }

    /// pages on `host` or a subdomain, `www.` aside, newest first; the site's front page is left out
    private static func history(on host: String, in space: Space) -> LiveOutcome {
        let site = host.lowercased().hasPrefix("www.") ? String(host.lowercased().dropFirst(4)) : host.lowercased()
        let rows = BrowserCore.shared.profile(of: space).history.entries
            .filter { $0.autofillHost == site || $0.autofillHost.hasSuffix("." + site) }
            .filter { $0.url.path().count > 1 }
            .sorted { $0.lastVisited > $1.lastVisited }
            .prefix(Feeds.maxItems)
            .compactMap { entry in
                LiveRow(
                    id: entry.url.absoluteString, title: entry.title.isEmpty ? entry.url.path() : entry.title,
                    link: entry.url, date: entry.lastVisited)
            }
        return .rows(rows, total: nil)
    }

    /// what the tab posted, newest first, each row opening the tab's page
    private static func notifications(of id: UUID, in space: Space) -> LiveOutcome {
        let tabs = space.tabs + BrowserCore.shared.profile(of: space).essentials
        guard let tab = tabs.first(where: { $0.id == id }) else { return .rows([], total: nil) }
        let rows = (WebNotifications.shared.recent[id] ?? []).compactMap { posted in
            LiveRow(
                id: "\(posted.id) \(posted.date.timeIntervalSince1970)", title: posted.title, subtitle: posted.body,
                link: tab.url ?? tab.pendingURL, date: posted.date)
        }
        return .rows(rows, total: nil)
    }
}
