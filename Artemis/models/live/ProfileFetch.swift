// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import Foundation
import WebKit

/// a GET, or a POST of `body`, made for a profile outside any page: through the profile's extension
/// proxy, with no cookie store or cache of its own, refused past `maxBytes` or 15 seconds
enum ProfileFetch {
    nonisolated struct Response: Sendable {
        let status: Int
        /// where any redirects ended
        let url: URL
        /// lowercased names; Set-Cookie never reaches here
        let headers: [String: String]
        let body: Data
    }

    nonisolated static let maxBytes = 2 << 20

    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) "
        + "Version/\(BrowserTab.currentSafariVersion) Safari/605.1.15"

    /// `withCookies` sends the profile's cookies for `url` and keeps the live ones a successful reply
    /// sets for the same host; without it nothing is sent or kept. a redirect elsewhere carries no cookies
    static func send(
        _ url: URL, body: Data? = nil, headers: [String: String] = [:], accept: String, withCookies: Bool,
        in profile: UUID
    ) async throws(LiveFailure) -> Response {
        guard ["http", "https"].contains(url.scheme?.lowercased()) else { throw .unreadable }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpShouldHandleCookies = false
        if let body {
            request.httpMethod = "POST"
            request.httpBody = body
        }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if withCookies, let cookies = await ExtensionProxyBridge.cookieHeader(for: url, in: profile) {
            request.setValue(cookies, forHTTPHeaderField: "Cookie")
        }
        let configuration = ExtensionProxyBridge.sessionConfiguration(in: profile)
        configuration.timeoutIntervalForResource = 15
        let session = URLSession(configuration: configuration, delegate: BridgedFetchRedirects(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (response, setCookie) = try await download(request, via: session)
        // a refusal's Set-Cookie may expire the session the open tab still uses
        if withCookies, (200..<300).contains(response.status), let setCookie, response.url.host() == url.host() {
            let store = ProfileStore.dataStore(for: profile).httpCookieStore
            let now = Date()
            for cookie in HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": setCookie], for: response.url)
            where (cookie.expiresDate ?? .distantFuture) > now {
                await store.setCookie(cookie)
            }
        }
        return response
    }

    @concurrent
    nonisolated private static func download(_ request: URLRequest, via session: URLSession) async throws(LiveFailure)
        -> (Response, setCookie: String?)
    {
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do { (bytes, response) = try await session.bytes(for: request) } catch { throw .network }
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse, let url = http.url else { throw .network }
        guard http.expectedContentLength <= maxBytes else { throw .unreadable }
        var body = Data()
        var tooLarge = false
        do {
            for try await byte in bytes {
                body.append(byte)
                if body.count > maxBytes {
                    tooLarge = true
                    break
                }
            }
        } catch { throw .network }
        if tooLarge { throw .unreadable }
        var headers: [String: String] = [:]
        var setCookie: String?
        for (key, value) in http.allHeaderFields {
            guard let key = (key as? String)?.lowercased(), let value = value as? String else { continue }
            if key == "set-cookie" { setCookie = value } else { headers[key] = value }
        }
        return (Response(status: http.statusCode, url: url, headers: headers, body: body), setCookie)
    }
}
