// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import Foundation

/// github.com for the profile's own session: the search page's embedded results for anything signed
/// in, and the anonymous REST API for a public repository's card
enum GitHub {
    /// the owner and repository a github.com url points into; nil on GitHub's own pages
    nonisolated static func repository(in url: URL) -> (owner: String, name: String)? {
        guard ["github.com", "www.github.com"].contains(url.host()?.lowercased()) else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 2, !reserved.contains(parts[0].lowercased()) else { return nil }
        let name = parts[1].hasSuffix(".git") ? String(parts[1].dropLast(4)) : parts[1]
        guard isName(parts[0]), isName(name) else { return nil }
        return (parts[0], name)
    }

    nonisolated private static let reserved: Set<String> = [
        "about", "account", "apps", "codespaces", "collections", "contact", "copilot", "dashboard", "enterprise",
        "events", "explore", "features", "issues", "login", "logout", "marketplace", "new", "notifications",
        "organizations", "orgs", "pricing", "pulls", "search", "security", "sessions", "settings", "signup", "site",
        "sponsors", "stars", "team", "topics", "trending", "users", "watching",
    ]

    /// an owner or repository name, which is safe to put in a path as it stands
    nonisolated private static func isName(_ text: String) -> Bool {
        (1...100).contains(text.count) && text != "." && text != ".."
            && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }
    }

    /// shared by search and REST rows, so a folder fed by several sources sees one item
    nonisolated private static func itemID(_ owner: String, _ name: String, _ number: Int) -> String {
        "github:\(owner.lowercased())/\(name.lowercased())#\(number)"
    }

    nonisolated private static func itemURL(_ owner: String, _ name: String, _ number: Int, pull: Bool) -> URL? {
        URL(string: "https://github.com/\(owner)/\(name)/\(pull ? "pull" : "issues")/\(number)")
    }

    // MARK: - Search page

    /// results most recently updated first, or by best match without `byUpdate`
    nonisolated static func searchURL(_ terms: String, pulls: Bool, page: Int = 1, byUpdate: Bool = true) -> URL {
        var components = URLComponents(string: "https://github.com/search")!
        components.queryItems =
            [
                URLQueryItem(name: "q", value: terms),
                URLQueryItem(name: "type", value: pulls ? "pullrequests" : "issues"),
            ]
            + (byUpdate ? [URLQueryItem(name: "s", value: "updated"), URLQueryItem(name: "o", value: "desc")] : [])
            + (page > 1 ? [URLQueryItem(name: "p", value: String(page))] : [])
        return components.url!
    }

    /// up to `pages` pages of ten, most recently updated first. `needsSession` reads a signed-out
    /// page as `.needsSignIn`; `inRepo` leaves the repository out of each subtitle
    static func search(
        _ terms: String, pulls: Bool, in profile: UUID, pages: Int = 3, needsSession: Bool = true, inRepo: Bool = false
    ) async throws(LiveFailure) -> LiveOutcome {
        var rows: [LiveRow] = []
        var total: Int?
        for page in 1...max(1, pages) {
            let response = try await ProfileFetch.send(
                searchURL(terms, pulls: pulls, page: page), accept: "text/html", withCookies: true, in: profile)
            let outcome = await searchOutcome(response, pulls: pulls, needsSession: needsSession, inRepo: inRepo)
            guard case .rows(let found, let count) = outcome else { return outcome }
            total = count
            rows += found.filter { row in !rows.contains { $0.id == row.id } }
            if found.isEmpty || rows.count >= (count ?? 0) { break }
        }
        return .rows(rows, total: total)
    }

    /// a search page's results from the JSON it embeds for its React app. a sign-in page, a 401, or
    /// a signed-out page where `needsSession` is `.needsSignIn`; changed markup is `.unreadable`
    @concurrent
    nonisolated static func searchOutcome(
        _ response: ProfileFetch.Response, pulls: Bool, needsSession: Bool, inRepo: Bool
    ) async -> LiveOutcome {
        if response.status == 401 || response.url.host()?.lowercased() != "github.com"
            || response.url.path().hasPrefix("/login")
        {
            return .needsSignIn
        }
        switch response.status {
        case 200..<300: break
        case 403, 429: return .unavailable(.rateLimited)
        default: return .unavailable(.network)
        }
        guard let route = embeddedSearch(response.body) else { return .unavailable(.unreadable) }
        if needsSession, route["logged_in"] as? Bool != true { return .needsSignIn }
        guard let results = route["results"] as? [[String: Any]], (route["errors"] as? [Any])?.isEmpty != false
        else { return .unavailable(.unreadable) }
        let rows = results.prefix(Feeds.maxItems).compactMap { result -> LiveRow? in
            guard let number = result["number"] as? Int,
                let repository = (result["repo"] as? [String: Any])?["repository"] as? [String: Any],
                let owner = repository["owner_login"] as? String, let name = repository["name"] as? String,
                isName(owner), isName(name)
            else { return nil }
            let state: LiveState? =
                switch result["state"] as? String {
                case "open": .open
                case "draft": .draft
                case "merged": .merged
                case "closed": result["merged"] as? Bool == true ? .merged : .closed
                default: nil
                }
            // search wraps matched words in <em> and escapes the rest
            let title = (result["hl_title"] as? String ?? "")
                .replacingOccurrences(of: "<em>", with: "").replacingOccurrences(of: "</em>", with: "")
            let author = result["author_name"] as? String ?? ""
            return LiveRow(
                id: itemID(owner, name, number), title: Feeds.decodeEntities(title),
                subtitle: inRepo ? "#\(number) · \(author)" : "\(owner)/\(name) #\(number)",
                link: itemURL(owner, name, number, pull: pulls), date: Feeds.date(result["created"] as? String ?? ""),
                state: state)
        }
        return .rows(rows, total: route["result_count"] as? Int)
    }

    nonisolated private static func embeddedSearch(_ body: Data) -> [String: Any]? {
        guard let start = body.range(of: Data(#"data-target="react-app.embeddedData">"#.utf8)),
            let end = body.range(of: Data("</script>".utf8), in: start.upperBound..<body.endIndex),
            let page = try? JSONSerialization.jsonObject(with: body[start.upperBound..<end.lowerBound])
                as? [String: Any]
        else { return nil }
        return (page["payload"] as? [String: Any])?["blackbirdSearchRoute"] as? [String: Any]
    }

    /// a pull request's state from the signed-in search page, for an item that left its query
    /// (reviewed, or its request withdrawn); nil when it can't be told
    static func state(ofPull url: URL, in space: Space) async -> LiveState? {
        guard let profile = LiveSource.admittedProfile(of: space), let lookup = pullLookup(url) else { return nil }
        var seen = 0
        for page in lookup.pages {
            guard let response = try? await ProfileFetch.send(page, accept: "text/html", withCookies: true, in: profile),
                case .rows(let rows, let total) = await searchOutcome(
                    response, pulls: true, needsSession: false, inRepo: false),
                LiveSource.admittedProfile(of: space) == profile
            else { return nil }
            if let row = rows.first(where: { $0.id == lookup.id }) { return row.state }
            seen += rows.count
            if rows.isEmpty || seen >= (total ?? 0) { return nil }
        }
        return nil
    }

    /// the search pages, best match first, that list the pull request `url` points into, and the
    /// id of its row there; nil for any other url
    nonisolated static func pullLookup(_ url: URL) -> (pages: [URL], id: String)? {
        let parts = url.pathComponents.filter { $0 != "/" }
        guard let repo = repository(in: url), parts.count >= 4, parts[2] == "pull", let number = Int(parts[3]),
            number > 0
        else { return nil }
        let terms = "repo:\(repo.owner)/\(repo.name) is:pr \(number)"
        let pages = (1...3).map { searchURL(terms, pulls: true, page: $0, byUpdate: false) }
        return (pages, itemID(repo.owner, repo.name, number))
    }

    // MARK: - Repository card

    /// when the anonymous REST limit lifts
    private static var restResumes = Date.distantPast

    /// the REST API for a public repository, else the signed-in search page: a private repository,
    /// one that doesn't exist, or the anonymous limit spent
    static func repo(owner: String, name: String, in profile: UUID) async throws(LiveFailure) -> LiveOutcome {
        guard isName(owner), isName(name) else { return .unavailable(.unreadable) }
        var needsSession = false
        if restResumes < Date() {
            let url = URL(
                string: "https://api.github.com/repos/\(owner)/\(name)/issues"
                    + "?state=open&sort=updated&direction=desc&per_page=20")!
            let response = try await ProfileFetch.send(
                url, accept: "application/vnd.github+json", withCookies: false, in: profile)
            guard let fallback = searchInstead(after: response) else {
                return await restOutcome(response, owner: owner, name: name)
            }
            needsSession = fallback.needsSession
            restResumes = fallback.resumes ?? restResumes
        }
        var rows: [LiveRow] = []
        for pulls in [true, false] {
            let outcome = try await search(
                "repo:\(owner)/\(name) is:open", pulls: pulls, in: profile, pages: 1, needsSession: needsSession,
                inRepo: true)
            guard case .rows(let found, _) = outcome else { return outcome }
            rows += found
        }
        return .rows(rows.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }, total: nil)
    }

    /// nil to read an anonymous REST reply as it is; else the search page, which needs a session
    /// after a 404 (private, or no such repository), with REST paused until `resumes` when the
    /// reply spent the anonymous limit
    nonisolated static func searchInstead(after response: ProfileFetch.Response)
        -> (needsSession: Bool, resumes: Date?)?
    {
        if response.status == 404 { return (true, nil) }
        guard [403, 429].contains(response.status) else { return nil }
        if let seconds = response.headers["retry-after"].flatMap({ TimeInterval($0) }) {
            return (false, Date(timeIntervalSinceNow: seconds))
        }
        guard response.headers["x-ratelimit-remaining"] == "0" else {
            return response.status == 429 ? (false, Date(timeIntervalSinceNow: 60)) : nil
        }
        let reset = response.headers["x-ratelimit-reset"].flatMap { TimeInterval($0) }
        return (false, reset.map(Date.init(timeIntervalSince1970:)) ?? Date(timeIntervalSinceNow: 3600))
    }

    @concurrent
    nonisolated static func restOutcome(_ response: ProfileFetch.Response, owner: String, name: String) async
        -> LiveOutcome
    {
        guard (200..<300).contains(response.status) else { return .unavailable(.network) }
        guard let items = try? JSONSerialization.jsonObject(with: response.body) as? [[String: Any]] else {
            return .unavailable(.unreadable)
        }
        let rows = items.prefix(Feeds.maxItems).compactMap { item -> LiveRow? in
            guard let number = item["number"] as? Int else { return nil }
            let pull = item["pull_request"] != nil
            let author = (item["user"] as? [String: Any])?["login"] as? String ?? ""
            return LiveRow(
                id: itemID(owner, name, number), title: item["title"] as? String ?? "",
                subtitle: "#\(number) · \(author)", link: itemURL(owner, name, number, pull: pull),
                date: Feeds.date(item["updated_at"] as? String ?? ""),
                state: pull && item["draft"] as? Bool == true ? .draft : .open)
        }
        return .rows(rows, total: nil)
    }
}

extension GitHubQuery {
    /// `is:open`, so only a merge or a close takes a pull request out of `created`; the review
    /// queries also lose one when its review is given, which `GitHub.state(ofPull:in:)` tells apart
    var terms: String {
        switch self {
        case .created: "is:pr is:open archived:false author:@me"
        case .reviewRequested: "is:pr is:open archived:false user-review-requested:@me"
        case .teamReviewRequested: "is:pr is:open archived:false review-requested:@me -user-review-requested:@me"
        case .assignedIssues: "is:issue is:open archived:false assignee:@me"
        }
    }

    /// kept to `repo`, `owner/name`, by the search itself
    func terms(in repo: String?) -> String { repo.map { "\(terms) repo:\($0)" } ?? terms }
}
