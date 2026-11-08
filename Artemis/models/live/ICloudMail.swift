// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import Foundation

/// iCloud Mail's unread inbox, read as icloud.com's own Mail tile reads it: `validate` names the
/// account and its mail host, then a thread search returns the unread threads and the unread count
enum ICloudMail {
    /// the web build icloud.com stamps on its requests; unchecked today
    private static let build = "2640Build24"

    static func unread(china: Bool, in profile: UUID) async throws(LiveFailure) -> LiveOutcome {
        let domain = china ? "icloud.com.cn" : "icloud.com"
        // setup refuses a request without icloud.com's own Origin
        let headers = ["Origin": "https://www.\(domain)", "Referer": "https://www.\(domain)/mail/"]
        let stamp = "clientBuildNumber=\(build)&clientMasteringNumber=\(build)"
        let validated = try await ProfileFetch.send(
            URL(string: "https://setup.\(domain)/setup/ws/1/validate?\(stamp)")!, body: Data(), headers: headers,
            accept: "application/json", withCookies: true, in: profile)
        guard let account = await account(from: validated) else { return refusal(validated) }
        var search = URLComponents(
            url: account.gateway.appending(path: "mailws2/v1/thread/search"), resolvingAgainstBaseURL: false)!
        // a fresh client id, so none ties the accounts of two profiles together
        search.percentEncodedQuery = "\(stamp)&clientId=\(UUID().uuidString.lowercased())&dsid=\(account.dsid)"
        let query = #"""
            {"responseType":"THREAD_DIGEST","includeFolderStatus":true,"maxResults":10,"filters":{"unseen":true},
            "sessionHeaders":{"folder":"INBOX","modseq":null,"threadmodseq":null,"condstore":1,"qresync":1,"threadmode":1}}
            """#
        let found = try await ProfileFetch.send(
            search.url!, body: Data(query.utf8), headers: headers.merging(["Content-Type": "application/json"]) { $1 },
            accept: "application/json", withCookies: true, in: profile)
        return await rows(from: found, domain: domain)
    }

    /// the account's dsid and its own mail host, from a validate reply; nil for anything else
    @concurrent
    nonisolated static func account(from response: ProfileFetch.Response) async -> (dsid: String, gateway: URL)? {
        guard (200..<300).contains(response.status),
            let json = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
            json["hsaChallengeRequired"] as? Bool != true,
            let info = json["dsInfo"] as? [String: Any],
            let dsid = info["dsid"] as? String ?? (info["dsid"] as? NSNumber)?.stringValue,
            !dsid.isEmpty, dsid.allSatisfy { $0.isASCII && $0.isNumber },
            let services = json["webservices"] as? [String: Any],
            let gateway = ((services["mccgateway"] as? [String: Any])?["url"] as? String).flatMap(URL.init(string:)),
            gateway.scheme == "https",
            let host = gateway.host()?.lowercased(), host.hasSuffix(".icloud.com") || host.hasSuffix(".icloud.com.cn")
        else { return nil }
        return (dsid, gateway)
    }

    /// what a reply that named no account or threads means. a missing Origin is a fault in the
    /// request, never a signed-out session
    nonisolated static func refusal(_ response: ProfileFetch.Response) -> LiveOutcome {
        let json = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any]
        switch response.status {
        case 401, 403, 409, 421, 450:
            return (json?["error"] as? String)?.contains("Origin") == true ? .unavailable(.unreadable) : .needsSignIn
        case 200..<300:
            return json?["hsaChallengeRequired"] as? Bool == true ? .needsSignIn : .unavailable(.unreadable)
        case 429, 503: return .unavailable(.rateLimited)
        case 500...: return .unavailable(.network)
        default: return .unavailable(.unreadable)
        }
    }

    private nonisolated struct Search: Decodable {
        nonisolated struct Thread: Decodable {
            let threadId: String
            /// epoch milliseconds
            let timestamp: Double
            let senders: [String]?
            let subject: String?
            let flags: [String]?
        }
        nonisolated struct Status: Decodable {
            let unseenUndeletedMessages: Int?
            let unseenUndeletedThreads: Int?
        }
        let threadList: [Thread]?
        let folderStatus: Status?
    }

    /// newest first, as subject over sender; `total` is the inbox's unread count. logs counts only
    @concurrent
    nonisolated static func rows(from response: ProfileFetch.Response, domain: String) async -> LiveOutcome {
        guard (200..<300).contains(response.status) else {
            debugLog("icloud mail: HTTP \(response.status)")
            return refusal(response)
        }
        guard let found = try? JSONDecoder().decode(Search.self, from: response.body), let threads = found.threadList
        else { return .unavailable(.unreadable) }
        let rows = threads.filter { !($0.flags ?? []).contains(#"\Seen"#) }.compactMap { thread in
            LiveRow(
                id: thread.threadId, title: thread.subject ?? "", subtitle: sender(thread.senders?.first ?? ""),
                link: link(thread: thread.threadId, domain: domain), date: Date(timeIntervalSince1970: thread.timestamp / 1000))
        }
        let total = found.folderStatus.flatMap { $0.unseenUndeletedMessages ?? $0.unseenUndeletedThreads }
        debugLog("icloud mail: \(rows.count) unread threads, total \(total.map(String.init) ?? "none")")
        return .rows(rows, total: total)
    }

    /// "Jane Doe <jane@x.example>" is "Jane Doe"; a bare address stays itself
    private nonisolated static func sender(_ from: String) -> String {
        guard let open = from.lastIndex(of: "<") else { return from }
        let name = from[..<open].trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "\"")))
        return name.isEmpty ? String(from[from.index(after: open)...].prefix { $0 != ">" }) : name
    }

    /// icloud.com opens a thread only for an id of letters, digits, - and _; any other goes to the inbox
    private nonisolated static func link(thread: String, domain: String) -> URL? {
        let opens = !thread.isEmpty && thread.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_".contains($0)) }
        return URL(string: "https://www.\(domain)/mail/" + (opens ? "open?id=\(thread)" : ""))
    }
}
