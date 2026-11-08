// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import Foundation
import WebKit

/// the other webmail a hover card reads with the profile's own sign-in, each the way its own web
/// app or a maintained notifier reads it. Zoho alone is read off its tab's title, count only
nonisolated enum Webmail: String, Codable, Sendable, CaseIterable {
    case yahoo, aol, proton, hey, fastmail, zoho

    var name: String {
        switch self {
        case .yahoo: "Yahoo Mail"
        case .aol: "AOL Mail"
        case .proton: "Proton Mail"
        case .hey: "HEY"
        case .fastmail: "Fastmail"
        case .zoho: "Zoho Mail"
        }
    }

    static func service(of url: URL) -> Webmail? {
        guard url.scheme?.lowercased() == "https", let host = url.host()?.lowercased() else { return nil }
        switch host {
        case "mail.yahoo.com": return .yahoo
        case "mail.aol.com": return .aol
        case "mail.proton.me": return .proton
        case "app.hey.com": return .hey
        case "app.fastmail.com", "app.beta.fastmail.com": return .fastmail
        case "mail.zohocloud.ca": return .zoho
        default: return host.hasPrefix("mail.zoho.") ? .zoho : nil
        }
    }

    /// a new message in the tab `page` is from
    func compose(from page: URL) -> URL? {
        switch self {
        case .yahoo: URL(string: "https://mail.yahoo.com/mrd/mail/any/compose")
        case .aol: URL(string: "https://mail.aol.com/d/compose")
        case .proton: URL(string: Self.protonRoot(of: page) + "/inbox#mailto=mailto:")
        case .hey: URL(string: "https://app.hey.com/messages/new")
        case .fastmail: Self.fastmailURL(page, path: "/mail/compose")
        case .zoho: nil
        }
    }

    // MARK: Yahoo and AOL, one backend

    /// unread across the account's own Inbox folders, linked accounts aside; a row per conversation
    static func ymailOutcome(from response: ProfileFetch.Response, link: ([String: Any]) -> URL?) -> LiveOutcome {
        if let refused = refusal(response) { return refused }
        guard let responses = ((json(response) as? [String: Any])?["result"] as? [String: Any])?["responses"]
            as? [[String: Any]]
        else { return .unavailable(.unreadable) }
        if responses.contains(where: { $0["httpCode"] as? Int == 401 }) { return .needsSignIn }
        var folders: [[String: Any]] = []
        var messages: [[String: Any]] = []
        for part in responses {
            let result = (part["response"] as? [String: Any])?["result"] as? [String: Any]
            folders += result?["folders"] as? [[String: Any]] ?? []
            messages += result?["messages"] as? [[String: Any]] ?? []
        }
        func inInbox(_ folder: [String: Any]?) -> Bool { (folder?["types"] as? [String])?.contains("INBOX") ?? true }
        let inboxes = folders.filter { inInbox($0) && ($0["acctId"] as? String ?? "1") == "1" }
        var seen = Set<String>()
        let rows = messages.compactMap { message -> LiveRow? in
            guard (message["flags"] as? [String: Any])?["read"] as? Bool != true,
                inInbox(message["folder"] as? [String: Any]),
                let id = message["conversationId"] as? String ?? message["id"] as? String, seen.insert(id).inserted
            else { return nil }
            let headers = message["headers"] as? [String: Any]
            let from = (headers?["from"] as? [[String: Any]])?.first
            let date = (headers?["date"] as? NSNumber)?.doubleValue
            return LiveRow(
                id: id, title: headers?["subject"] as? String ?? "",
                subtitle: from?["name"] as? String ?? from?["email"] as? String ?? "", link: link(message),
                date: date.map { Date(timeIntervalSince1970: $0 > 1e12 ? $0 / 1000 : $0) })
        }
        return .rows(rows, total: inboxes.isEmpty ? nil : inboxes.reduce(0) { $0 + (($1["unread"] as? NSNumber)?.intValue ?? 0) })
    }

    // MARK: Proton

    /// `https://mail.proton.me/u/<n>`: the signed-in account the tab is on
    static func protonRoot(of page: URL) -> String {
        let parts = page.pathComponents
        let account = parts.count > 2 && parts[1] == "u" && Int(parts[2]) != nil ? parts[2] : "0"
        return "https://mail.proton.me/u/" + account
    }

    /// the uids of the `AUTH-<uid>` cookies a request to mail.proton.me/api carries
    static func protonSessions(in cookies: [HTTPCookie]) -> Set<String> {
        Set(
            cookies.filter {
                $0.name.hasPrefix("AUTH-") && ["mail.proton.me", ".mail.proton.me", ".proton.me"].contains($0.domain.lowercased())
                    && ["/", "/api", "/api/"].contains($0.path)
            }
            .map { String($0.name.dropFirst(5)) })
    }

    /// Proton keeps subjects and senders outside its end-to-end encryption
    static func protonOutcome(count: ProfileFetch.Response, list: ProfileFetch.Response, page: URL) -> LiveOutcome {
        if let refused = refusal(list) ?? refusal(count) { return refused }
        guard let messages = (json(list) as? [String: Any])?["Messages"] as? [[String: Any]] else {
            return .unavailable(.unreadable)
        }
        let counts = (json(count) as? [String: Any])?["Counts"] as? [[String: Any]]
        let inbox = counts?.first { "\($0["LabelID"] ?? "")" == "0" }
        let root = protonRoot(of: page)
        let rows = messages.compactMap { message -> LiveRow? in
            guard let id = message["ID"] as? String else { return nil }
            let sender = message["Sender"] as? [String: Any]
            let conversation = message["ConversationID"] as? String ?? id
            return LiveRow(
                id: id, title: message["Subject"] as? String ?? "",
                subtitle: (sender?["Name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? sender?["Address"] as? String ?? "",
                link: URL(string: root + "/inbox/" + (conversation.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "")),
                date: (message["Time"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) })
        }
        return .rows(rows, total: (inbox?["Unread"] as? NSNumber)?.intValue)
    }

    // MARK: HEY

    /// HEY has no unread flag: "new for you" is a posting neither seen nor bubbled up. a first page
    /// all new gives no total, since it can't say how many more there are
    static func heyOutcome(from response: ProfileFetch.Response) -> LiveOutcome {
        if let refused = refusal(response) { return refused }
        if response.url.path().hasPrefix("/sign_in") { return .needsSignIn }
        guard let root = json(response) as? [String: Any],
            let postings = (root["postings"] ?? (root["box"] as? [String: Any])?["postings"]) as? [[String: Any]]
        else { return .unavailable(.unreadable) }
        let fresh = postings.filter {
            $0["seen"] as? Bool != true && $0["bubbled_up"] as? Bool != true && $0["muted"] as? Bool != true
        }
        let rows = fresh.compactMap { posting -> LiveRow? in
            guard let id = posting["id"].map({ "\($0)" }) else { return nil }
            let creator = posting["creator"] as? [String: Any]
            let link = (posting["app_bundle_url"] ?? posting["app_url"]) as? String
            return LiveRow(
                id: id, title: posting["name"] as? String ?? "",
                subtitle: posting["alternative_sender_name"] as? String ?? creator?["name"] as? String ?? "",
                link: link.flatMap(URL.init(string:)),
                date: ((posting["active_at"] ?? posting["created_at"]) as? String).flatMap(isoDate))
        }
        return .rows(rows, total: fresh.count < postings.count ? fresh.count : nil)
    }

    // MARK: Fastmail

    /// `path` on the tab's own origin, keeping the `?u=` account it routes by
    static func fastmailURL(_ page: URL, path: String) -> URL? {
        guard var parts = URLComponents(url: page, resolvingAgainstBaseURL: false) else { return nil }
        let user = parts.queryItems?.first { $0.name == "u" }
        parts.path = path
        parts.queryItems = user.map { [$0] }
        parts.fragment = nil
        return parts.url
    }

    static func fastmailOutcome(counts: ProfileFetch.Response, list: ProfileFetch.Response, page: URL) -> LiveOutcome {
        if let refused = refusal(list) ?? refusal(counts) { return refused }
        func call(_ response: ProfileFetch.Response, _ name: String) -> [String: Any]? {
            let calls = (json(response) as? [String: Any])?["methodResponses"] as? [[Any]]
            return calls?.first { $0.first as? String == name }?.dropFirst().first as? [String: Any]
        }
        guard let emails = call(list, "Email/get")?["list"] as? [[String: Any]] else { return .unavailable(.unreadable) }
        let inbox = (call(counts, "Mailbox/get")?["list"] as? [[String: Any]])?.first
        let rows = emails.compactMap { email -> LiveRow? in
            guard let id = email["id"] as? String else { return nil }
            let from = (email["from"] as? [[String: Any]])?.first
            let thread = email["threadId"] as? String
            return LiveRow(
                id: id, title: email["subject"] as? String ?? "",
                subtitle: (from?["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? from?["email"] as? String ?? "",
                link: fastmailURL(page, path: "/mail/Inbox/" + (thread.map { "\($0)." } ?? "") + id),
                date: (email["receivedAt"] as? String).flatMap(isoDate))
        }
        return .rows(rows, total: (inbox?["unreadEmails"] as? NSNumber)?.intValue)
    }

    // MARK: Zoho

    /// Zoho's title leads with the open folder's unread count, "(6,736) - Inbox - Zoho Mail (…)",
    /// and drops it at none; nil for a title that isn't Zoho Mail's Inbox
    static func zohoCount(title: String) -> Int? {
        guard let end = title.range(of: " - Zoho Mail")?.lowerBound else { return nil }
        var folder = title[..<end]
        var count = 0
        if folder.hasPrefix("("), let close = folder.firstIndex(of: ")") {
            count = Int(folder[folder.index(after: folder.startIndex)..<close].filter(\.isNumber)) ?? 0
            folder = folder[folder.index(after: close)...]
        }
        return folder.trimmingPrefix(" - ") == "Inbox" ? count : nil
    }

    // MARK: Shared

    static func json(_ response: ProfileFetch.Response) -> Any? { try? JSONSerialization.jsonObject(with: response.body) }

    /// what a reply that isn't a 2xx means
    static func refusal(_ response: ProfileFetch.Response) -> LiveOutcome? {
        switch response.status {
        case 200..<300: nil
        case 401, 403: .needsSignIn
        case 429: .unavailable(.rateLimited)
        case 500...: .unavailable(.network)
        default: .unavailable(.unreadable)
        }
    }

    static func isoDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}

@MainActor
extension Webmail {
    /// Zoho is read off its tab and never fetched
    func unread(page: URL, tab: UUID, in profile: UUID) async throws(LiveFailure) -> LiveOutcome {
        switch self {
        case .yahoo: return try await Self.yahoo(in: profile)
        case .aol: return try await Self.aol(in: profile)
        case .proton: return try await Self.proton(page: page, tab: tab, in: profile)
        case .hey:
            let imbox = try await ProfileFetch.send(
                URL(string: "https://app.hey.com/imbox.json")!, accept: "application/json", withCookies: true, in: profile)
            return Self.heyOutcome(from: imbox)
        case .fastmail: return try await Self.fastmail(page: page, in: profile)
        case .zoho: return .unavailable(.refused)
        }
    }

    private static func yahoo(in profile: UUID) async throws(LiveFailure) -> LiveOutcome {
        let query =
            #" userQuery:("is:unread") acctId:1 groupBy:conversationId count:20 offset:0 "#
            + "-folderType:(TRASH)-folderType:(BULK)-folderType:(SYNC)-folderType:(INVISIBLE)"
        let q = query.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_.!~*'()"))) ?? ""
        let batch: [String: Any] = [
            "responseType": "json",
            "requests": [[
                "id": "GetMailboxId", "uri": "/ws/v3/mailboxes/", "method": "GET", "suppressResponse": true,
                "filters": ["select": ["mailboxId": "$..mailboxes[?(@.isPrimary==true)].id"]],
                "requests": [
                    ["id": "GetFolders", "uri": "/ws/v3/mailboxes/@.id==$(mailboxId)/folders", "method": "GET"],
                    ["id": "GetMessages", "uri": "/ws/v3/mailboxes/@.id==$(mailboxId)/messages/@.select==q?q=" + q, "method": "GET"],
                ],
            ]],
        ]
        // the web app posts the batch as a form field, not a JSON body
        let boundary = "artemis-" + UUID().uuidString
        var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"batchJson\"\r\n\r\n".utf8)
        body += (try? JSONSerialization.data(withJSONObject: batch)) ?? Data()
        body += Data("\r\n--\(boundary)--\r\n".utf8)
        let response = try await ProfileFetch.send(
            URL(string: "https://mail.yahoo.com/ws/v3/batch")!, body: body,
            headers: [
                "Content-Type": "multipart/form-data; boundary=\(boundary)", "Origin": "https://mail.yahoo.com",
                "Referer": "https://mail.yahoo.com/",
            ],
            accept: "application/json", withCookies: true, in: profile)
        return ymailOutcome(from: response) { message in
            let folder = (message["folder"] as? [String: Any])?["id"] as? String ?? "1"
            let id = message["conversationId"] as? String ?? message["id"] as? String ?? ""
            return URL(string: "https://mail.yahoo.com/n/folders/\(folder)/messages/\(id)")
        }
    }

    /// AOL's page names the request id and its mailbox call the session token the batch needs
    private static func aol(in profile: UUID) async throws(LiveFailure) -> LiveOutcome {
        let page = try await ProfileFetch.send(
            URL(string: "https://mail.aol.com/")!, accept: "text/html", withCookies: true, in: profile)
        guard page.url.host() == "mail.aol.com" else { return .needsSignIn }
        guard let guid = first(#""guidHash"\s*:\s*"([^"]+)""#, in: page.body) else { return refusal(page) ?? .needsSignIn }
        let mailboxes = try await ProfileFetch.send(
            URL(string: "https://mail.aol.com/ws/v3/mailboxes?appid=aolwebmail&ymreqid=\(guid)")!,
            accept: "application/json", withCookies: true, in: profile)
        if let refused = refusal(mailboxes) { return refused }
        guard let wssid = first(#""wssid"\s*:\s*"([^"]+)""#, in: mailboxes.body),
            let mailbox = (((json(mailboxes) as? [String: Any])?["result"] as? [String: Any])?["mailboxes"]
                as? [[String: Any]])?.first?["id"] as? String
        else { return .unavailable(.unreadable) }
        let batch: [String: Any] = [
            "responseType": "json",
            "requests": [
                ["id": "ListFolders", "uri": "/ws/v3/mailboxes/@.id==\(mailbox)/folders", "method": "GET"],
                [
                    "id": "ListMessages", "method": "GET",
                    "uri": "/ws/v3/mailboxes/@.id==\(mailbox)/messages/@.select==q?&q=folderId%3A1%20offset%3A0%20count%3A40%20sort%3A(-date)",
                ],
            ],
        ]
        let response = try await ProfileFetch.send(
            URL(string: "https://mail.aol.com/ws/v3/batch?appid=aolwebmail&ymreqid=\(guid)&webstdver=95.0&wssid=\(wssid)")!,
            body: (try? JSONSerialization.data(withJSONObject: batch)) ?? Data(),
            headers: ["Content-Type": "application/json", "Origin": "https://mail.aol.com"],
            accept: "application/json", withCookies: true, in: profile)
        return ymailOutcome(from: response) { message in
            URL(string: "https://mail.aol.com/d/folders/1/messages/\(message["id"] as? String ?? "")")
        }
    }

    /// Proton signs its API with the session's `AUTH-<uid>` cookie and that uid as a header; an
    /// expired access token refreshes once from the `REFRESH-<uid>` cookie
    private static func proton(page: URL, tab id: UUID, in profile: UUID) async throws(LiveFailure) -> LiveOutcome {
        let uids = protonSessions(in: await ProfileStore.dataStore(for: profile).httpCookieStore.allCookies())
        guard !uids.isEmpty else { return .needsSignIn }
        // the open page's storage names the session its /u/<n> account signed in with
        let localID = URL(string: protonRoot(of: page))?.lastPathComponent ?? "0"
        let tab = BrowserWindows.shared.allManagers.lazy.flatMap(\.allTabs).first { $0.id == id }
        var stored: String?
        if let tab, tab.pendingURL == nil, tab.webView.url?.host()?.lowercased() == "mail.proton.me" {
            stored = try? await tab.webView.callAsyncJavaScript(
                "return localStorage.getItem(key)", arguments: ["key": "ps-" + localID], contentWorld: .defaultClient)
                as? String
        }
        let uid: String
        if let session = stored.flatMap({ (try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])?["UID"] as? String }) {
            guard uids.contains(session) else { return .needsSignIn }
            uid = session
        } else {
            guard uids.count == 1, let only = uids.first else { return .unavailable(.unreadable) }
            uid = only
        }
        if protonVersion == nil {
            let version = try? await ProfileFetch.send(
                URL(string: "https://mail.proton.me/assets/version.json")!, accept: "application/json", withCookies: false,
                in: profile)
            protonVersion = version.flatMap { (json($0) as? [String: Any])?["version"] as? String }
        }
        guard let version = protonVersion else { return .unavailable(.network) }
        let headers = ["x-pm-uid": uid, "x-pm-appversion": "web-mail@" + version]
        let accept = "application/vnd.protonmail.v1+json"
        func get(_ path: String) async throws(LiveFailure) -> ProfileFetch.Response {
            try await ProfileFetch.send(
                URL(string: "https://mail.proton.me/api/mail/v4/" + path)!, headers: headers, accept: accept,
                withCookies: true, in: profile)
        }
        let listPath = "messages?LabelID=0&Unread=1&Sort=Time&Desc=1&Page=0&PageSize=6&Limit=6"
        var list = try await get(listPath)
        if list.status == 401 {
            let refreshed = try await ProfileFetch.send(
                URL(string: "https://mail.proton.me/api/auth/refresh")!, body: Data(), headers: headers, accept: accept,
                withCookies: true, in: profile)
            guard (200..<300).contains(refreshed.status) else { return .needsSignIn }
            list = try await get(listPath)
        }
        return protonOutcome(count: try await get("messages/count"), list: list, page: page)
    }
    /// the web app's own version, which Proton's API requires of every call
    private static var protonVersion: String?

    /// Fastmail's sessions endpoint hands a signed-in jar the JMAP token its web app uses
    private static func fastmail(page: URL, in profile: UUID) async throws(LiveFailure) -> LiveOutcome {
        guard let host = page.host()?.lowercased(), host.hasPrefix("app.") else { return .unavailable(.unreadable) }
        let origin = "https://" + host
        let sessions = try await ProfileFetch.send(
            URL(string: "https://api." + host.dropFirst(4) + "/auth/sessions")!, headers: ["Origin": origin],
            accept: "application/json", withCookies: true, in: profile)
        if let refused = refusal(sessions) { return refused }
        let user = URLComponents(url: page, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "u" }?.value
        let all = json(sessions) as? [[String: Any]] ?? []
        let chosen: [String: Any]? =
            if let user { all.first { $0["userId"] as? String == user } } else { all.count == 1 ? all.first : nil }
        guard let session = chosen,
            let token = session["accessToken"] as? String, let apiURL = session["apiUrl"] as? String,
            let userID = session["userId"] as? String,
            let account = (session["primaryAccounts"] as? [String: Any])?["urn:ietf:params:jmap:mail"] as? String,
            let api = URL(string: apiURL + (apiURL.contains("?") ? "&" : "?") + "u=" + userID)
        else { return all.isEmpty ? .needsSignIn : .unavailable(.unreadable) }
        let using = ["urn:ietf:params:jmap:core", "urn:ietf:params:jmap:mail"]
        func call(_ methods: [Any]) async throws(LiveFailure) -> ProfileFetch.Response {
            try await ProfileFetch.send(
                api, body: (try? JSONSerialization.data(withJSONObject: ["using": using, "methodCalls": methods])) ?? Data(),
                headers: ["Authorization": "Bearer " + token, "Content-Type": "application/json"], accept: "application/json",
                withCookies: true, in: profile)
        }
        let counts = try await call([
            ["Mailbox/query", ["accountId": account, "filter": ["role": "inbox"]], "q"],
            [
                "Mailbox/get",
                [
                    "accountId": account, "#ids": ["resultOf": "q", "name": "Mailbox/query", "path": "/ids"],
                    "properties": ["id", "unreadEmails"],
                ], "m",
            ],
        ])
        let mailboxes = ((json(counts) as? [String: Any])?["methodResponses"] as? [[Any]])?
            .first { $0.first as? String == "Mailbox/get" }?.dropFirst().first as? [String: Any]
        guard let inbox = ((mailboxes?["list"] as? [[String: Any]])?.first)?["id"] as? String else {
            return refusal(counts) ?? .unavailable(.unreadable)
        }
        let list = try await call([
            [
                "Email/query",
                [
                    "accountId": account, "filter": ["inMailbox": inbox, "notKeyword": "$seen"],
                    "sort": [["property": "receivedAt", "isAscending": false]], "limit": 6,
                ], "q",
            ],
            [
                "Email/get",
                [
                    "accountId": account, "#ids": ["resultOf": "q", "name": "Email/query", "path": "/ids"],
                    "properties": ["id", "threadId", "from", "subject", "receivedAt"],
                ], "g",
            ],
        ])
        return fastmailOutcome(counts: counts, list: list, page: page)
    }

    private nonisolated static func first(_ pattern: String, in body: Data) -> String? {
        guard let text = String(data: body, encoding: .utf8),
            let match = text.range(of: pattern, options: .regularExpression)
        else { return nil }
        let found = String(text[match])
        guard let open = found.lastIndex(of: ":"), let value = found[open...].split(separator: "\"").last else { return nil }
        return String(value)
    }
}
