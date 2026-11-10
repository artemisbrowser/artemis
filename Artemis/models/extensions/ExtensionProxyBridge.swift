// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import Foundation
import Network
import Security
import WebKit

/// native half of the shim's chrome.proxy and kin, driving each profile's
/// `WKWebsiteDataStore.proxyConfigurations`: one proxy per store, never per scheme, and
/// WebRTC/UDP, DNS prefetch and WebTransport bypass it
@MainActor
final class ExtensionProxyBridge {
    static let shared = ExtensionProxyBridge()

    /// one profile's proxy: a VPN applies only to the profiles it is enabled in
    private struct Slot {
        /// the chrome-side `ProxyConfig` as last set, persisted: a VPN restores "connected" from
        /// its own storage on launch and may never set the proxy again
        var value: [String: Any]?
        /// the context that set it; Chrome reverts the setting when it goes
        var owner: String?
        /// the last `onAuthRequired` answer and the extension that gave it
        var credentials: (supplier: String, username: String, password: String)?
        var active: BuiltProxy?
        /// a clear held briefly so a server switch doesn't fall through to direct
        var pendingClear: Task<Void, Never>?

        /// credentials reach only the proxy of the extension that supplied them
        var ownersCredentials: (username: String, password: String)? {
            credentials.flatMap { $0.supplier == owner ? ($0.username, $0.password) : nil }
        }
    }
    private var slots: [UUID: Slot] = [:]
    private static let ownerKey = "artemisOwner"
    /// non-proxy ChromeSettings (webRTCIPHandlingPolicy etc.), echoed back but not enforced
    private var settingValues: [String: Any] = [:]

    /// what the current chrome value compiled down to
    struct BuiltProxy {
        /// new on every build, so a cache keyed on it never outlives new credentials or bypass rules
        let id = UUID()
        var kind: String  // "https-connect" | "http-connect" | "socks5"
        var host: String
        var port: UInt16
        var excludedDomains: [String]
        var hasCredentials: Bool
        var config: ProxyConfiguration
    }
    func activeProxy(in profile: UUID) -> BuiltProxy? { slots[profile]?.active }

    func chromeProxyValue(in profile: UUID) -> [String: Any]? { slots[profile]?.value }

    /// the navigation delegate's answer to a 407 from the active proxy, which otherwise raises
    /// macOS's own proxy-password dialog; nil for any other proxy, which gets no credentials
    func proxyChallengeAnswer(
        _ space: URLProtectionSpace, in profile: UUID
    ) -> (disposition: URLSession.AuthChallengeDisposition, credential: URLCredential?)? {
        guard let slot = slots[profile], let active = slot.active,
            space.host.lowercased() == active.host.lowercased(), space.port == Int(active.port)
        else { return nil }
        guard let credentials = slot.ownersCredentials else { return (.cancelAuthenticationChallenge, nil) }
        return (.useCredential, URLCredential(
            user: credentials.username, password: credentials.password, persistence: .forSession))
    }

    /// chrome.idle's "locked" state, kept by `lockSignals`
    private var screenIsLocked = false

    private init() {
        let (center, locked, unlocked) = Self.lockSignals
        center.addObserver(
            forName: locked, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.screenIsLocked = true } }
        center.addObserver(
            forName: unlocked, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.screenIsLocked = false } }
    }

    /// reports posted by the self-test's probe extension ("probe.report")
    private(set) var probeReports: [[String: Any]] = []

    /// recent extension-side console errors, newest last (see the "log" case)
    private(set) var consoleLog: [String] = []

    // MARK: - Message handling

    /// one `sendNativeMessage` payload from the shim → reply dictionary.
    /// unknown messages get an empty reply rather than an error: the shim
    /// treats failures as "keep the cached value", never as fatal
    func handle(_ message: [String: Any], from sender: String, in profile: UUID) async -> [String: Any] {
        guard let type = message["artemisCompat"] as? String else { return [:] }
        let name = message["name"] as? String
        switch type {
        case "setting.get":
            guard let name else { return [:] }
            if name == "proxy" {
                let slot = slots[profile]
                let level = slot?.value == nil ? "controllable_by_this_extension"
                    : isOwner(sender, in: profile) ? "controlled_by_this_extension"
                    : "controlled_by_other_extensions"
                return ["value": slot?.value ?? ["mode": "system"], "levelOfControl": level]
            }
            guard let value = settingValues[name] else { return [:] }
            return ["value": value, "levelOfControl": "controlled_by_this_extension"]

        case "setting.set":
            guard let name else { return [:] }
            if name == "proxy" {
                let value = message["value"] as? [String: Any]
                // another extension may take the proxy over, but only its owner takes it off
                guard value?["mode"] as? String == "fixed_servers" || isOwner(sender, in: profile)
                else { return ["ok": true] }
                if value != nil {
                    slots[profile, default: Slot()].owner = sender
                    if slots[profile]?.credentials?.supplier != sender { slots[profile]?.credentials = nil }
                }
                setProxy(value, in: profile)
            } else {
                if let value = message["value"] { settingValues[name] = value }
                debugLog("compat: setting \(name) = \(String(describing: message["value"]))")
            }
            return ["ok": true]

        case "setting.clear":
            guard let name else { return [:] }
            if name != "proxy" {
                settingValues[name] = nil
            } else if isOwner(sender, in: profile) {
                setProxy(nil, in: profile)
            }
            return ["ok": true]

        case "dnr.matchedRules":
            // WebKit's own getMatchedRules answers {url, timeStamp, tabId} with no
            // rule attached, so a panel that buckets by rulesetId always reads 0.
            // the counts come from Artemis's ledger of what was really blocked.
            let since = (message["minTimeStamp"] as? Double).map {
                Date(timeIntervalSince1970: $0 / 1000)
            }
            let tabID = message["tabId"] as? Int ?? -1
            // the ledger is the current tab's (never a private one), and only an extension in its profile may read it;
            // the shim has already answered empty for any other tab
            let blocked = await MainActor.run { () -> [[String: Any]] in
                guard let tab = ExtensionManager.shared.currentTab, tab.profileID == profile else { return [] }
                return tab.blockedRequests.compactMap { entry in
                    if let since, entry.at <= since { return nil }
                    return [
                        "rule": [
                            "ruleId": 1,
                            "rulesetId": entry.isTracker ? "adBlockerTrackers" : "adBlockerAds",
                        ],
                        "request": ["url": entry.url.absoluteString],
                        "timeStamp": floor(entry.at.timeIntervalSince1970 * 1000),
                        "tabId": tabID,
                    ]
                }
            }
            return ["rulesMatchedInfo": blocked]

        case "trace.enabled":
            // verbose RPC tracing only during an ARTEMIS_DIAG=ext run
            return ["enabled": AppStorageLocation.isExtensionsDiag]

        case "idle.query":
            return ["seconds": Int(Self.secondsSinceInput), "locked": screenIsLocked]

        case "log":
            // extension-side console errors / unhandled rejections, forwarded
            // by the shim because WebKit truncates what it reports natively
            let level = message["level"] as? String ?? "log"
            let text = message["text"] as? String ?? ""
            consoleLog.append("[\(level)] \(text)")
            if consoleLog.count > 200 { consoleLog.removeFirst(consoleLog.count - 200) }
            debugLog("ext console \(level): \(text)")
            return ["ok": true]

        case "fetch.needsBridge":
            guard let raw = message["url"] as? String, let url = URL(string: raw) else {
                return ["bridge": false]
            }
            return ["bridge": await Self.hasSameSiteRestrictedCookies(for: url, in: profile)]

        case "probe.setLaxCookie":
            // self-test only: plants a SameSite=Lax cookie, and only on the suite's echo host
            guard let raw = message["url"] as? String, let url = URL(string: raw),
                url.host() == "httpbin.org",
                let cookie = HTTPCookie(properties: [
                    .name: "artemislax", .value: "1", .domain: "httpbin.org",
                    .path: "/", .secure: "TRUE", .sameSitePolicy: "lax",
                ])
            else { return [:] }
            await WKWebsiteDataStore.default().httpCookieStore.setCookie(cookie)
            return ["ok": true]

        case "probe.report":
            // the self-test's probe extension reports live runtime behaviour
            // (tabs.query results etc.) through the same channel
            probeReports.append(message)
            return ["ok": true]

        case "proxy.credentials":
            // WebKit ignores onAuthRequired's return value, so the shim forwards what it returned
            guard let username = message["username"] as? String else { return [:] }
            slots[profile, default: Slot()].credentials = (sender, username, message["password"] as? String ?? "")
            // rebuild so applyCredential lands on the active config
            if let value = slots[profile]?.value { applyProxy(value, in: profile) }
            persist(profile)
            debugLog("compat: proxy credentials received for \(username)")
            return ["ok": true]

        default:
            return [:]
        }
    }

    /// Chrome reverts only the caller's own setting; a proxy no one has claimed is anyone's
    private func isOwner(_ sender: String, in profile: UUID) -> Bool {
        (slots[profile]?.owner ?? sender) == sender
    }

    // MARK: - Persistence

    private static func stateFile(_ profile: UUID) -> String {
        profile == Profile.defaultID ? "proxy-state.json" : "proxy-state-\(profile.uuidString).json"
    }
    private static func keychainService(_ profile: UUID) -> String {
        // another bundle ID keeps its own items in the shared login keychain
        let id = Bundle.main.bundleIdentifier ?? "dev.findles.Artemis"
        let base = id.hasPrefix("dev.findles.Artemis") ? "app.artemis.proxy-credentials" : "\(id).proxy-credentials"
        return profile == Profile.defaultID ? base : "\(base).\(profile.uuidString)"
    }

    /// restore every profile's saved proxy; call before any tab loads
    func restorePersisted() {
        let folder = AppStorageLocation.file(Self.stateFile(Profile.defaultID)).deletingLastPathComponent()
        let saved = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .compactMap { name -> UUID? in
                if name == Self.stateFile(Profile.defaultID) { return Profile.defaultID }
                guard name.hasPrefix("proxy-state-"), name.hasSuffix(".json") else { return nil }
                return UUID(uuidString: String(name.dropFirst(12).dropLast(5)))
            }
        for profile in saved {
            guard let data = try? Data(contentsOf: AppStorageLocation.file(Self.stateFile(profile))),
                let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            var slot = Slot()
            slot.owner = value[Self.ownerKey] as? String
            if let owner = slot.owner, let saved = Self.loadCredentials(profile) {
                slot.credentials = (owner, saved.username, saved.password)
            }
            slot.value = value.filter { $0.key != Self.ownerKey }
            slots[profile] = slot
            applyProxy(slot.value ?? [:], in: profile, reloadTabs: false)  // nothing is loaded yet
            debugLog("compat: restored proxy for profile \(profile) from last session")
        }
    }

    private func persist(_ profile: UUID) {
        let url = AppStorageLocation.file(Self.stateFile(profile))
        let slot = slots[profile]
        guard let value = slot?.value,
            let data = try? JSONSerialization.data(
                withJSONObject: value.merging([Self.ownerKey: slot?.owner as Any].compactMapValues { $0 }) { $1 })
        else {
            try? FileManager.default.removeItem(at: url)
            Self.saveCredentials(nil, profile)
            return
        }
        AppStorageLocation.writeDurableNow(data, to: url)
        Self.saveCredentials(slot?.ownersCredentials, profile)
    }

    private static func saveCredentials(_ credentials: (username: String, password: String)?, _ profile: UUID) {
        guard !AppStorageLocation.isExtensionLab else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService(profile),
        ]
        SecItemDelete(query as CFDictionary)
        guard let credentials,
            let secret = "\(credentials.username)\n\(credentials.password)".data(using: .utf8)
        else { return }
        var add = query
        add[kSecValueData as String] = secret
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    private static func loadCredentials(_ profile: UUID) -> (username: String, password: String)? {
        guard !AppStorageLocation.isExtensionLab else { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService(profile),
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
            let data = item as? Data, let text = String(data: data, encoding: .utf8)
        else { return nil }
        let parts = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        return (String(parts[0]), String(parts[1]))
    }

    /// run a held clear now instead of after `clearGrace`, for the self-test
    func finishPendingClearForTesting(in profile: UUID) {
        guard slots[profile]?.pendingClear != nil else { return }
        slots[profile]?.pendingClear?.cancel()
        slots[profile]?.pendingClear = nil
        slots[profile]?.value = nil
        persist(profile)
        clearProxy(in: profile)
    }

    /// drop in-memory proxy state without touching what's on disk, for the self-test's restore
    func forgetForTesting(in profile: UUID) {
        slots[profile] = nil
        ProfileStore.setProxyConfigurations([], for: profile)
    }

    /// the extension that set a profile's proxy is gone from it (removed, disabled,
    /// or not back after a relaunch): clear it and its credentials at once, since no switch can follow
    func release(owner id: String, in profile: UUID) {
        guard slots[profile]?.owner == id else { return }
        slots[profile]?.pendingClear?.cancel()
        slots[profile] = Slot()
        persist(profile)
        clearProxy(in: profile)
    }

    func releaseUnless(in profile: UUID, loaded: (_ owner: String) -> Bool) {
        if let owner = slots[profile]?.owner, !loaded(owner) { release(owner: owner, in: profile) }
    }

    /// a deleted profile's proxy, saved state and credentials go with it
    func forget(_ profile: UUID) {
        slots[profile]?.pendingClear?.cancel()
        slots[profile] = nil
        persist(profile)
    }

    /// every profile direct again, owned or not: a lab run starts from no proxy at all
    func releaseAll() {
        for profile in slots.keys {
            slots[profile]?.pendingClear?.cancel()
            slots[profile] = nil
            persist(profile)
            clearProxy(in: profile)
        }
    }

    // MARK: - Proxy application

    /// how long a clear is held before it is believed: a server switch can take ~20s, and going
    /// direct meanwhile leaks the real IP while the VPN still says "connected"
    private static let clearGrace: Duration = .seconds(25)

    private func setProxy(_ value: [String: Any]?, in profile: UUID) {
        slots[profile, default: Slot()].pendingClear?.cancel()
        slots[profile]?.pendingClear = nil

        guard let value else {
            // hold the current proxy rather than going direct immediately
            guard slots[profile]?.active != nil else {
                slots[profile]?.value = nil
                persist(profile)
                return clearProxy(in: profile)
            }
            debugLog("compat: proxy cleared — holding the current one in case this is a switch")
            slots[profile]?.pendingClear = Task { [weak self] in
                try? await Task.sleep(for: Self.clearGrace)
                guard !Task.isCancelled, let self else { return }
                self.slots[profile]?.value = nil
                // credentials survive a disconnect: they are account-level, and a proxy applied
                // without them makes the system prompt for a password
                self.persist(profile)
                self.clearProxy(in: profile)
                debugLog("compat: no new proxy arrived — really disconnected now")
            }
            return
        }

        slots[profile]?.value = value
        applyProxy(value, in: profile)
        persist(profile)
    }

    private func applyProxy(_ value: [String: Any], in profile: UUID, reloadTabs: Bool = true) {
        switch value["mode"] as? String {
        case "fixed_servers":
            guard let built = Self.build(from: value, credentials: slots[profile]?.ownersCredentials) else {
                debugLog("compat: proxy rules unusable, clearing")
                return clearProxy(in: profile)
            }
            slots[profile, default: Slot()].active = built
            ProfileStore.setProxyConfigurations([built.config], for: profile)
            // a reload without credentials 407s every request and macOS prompts for a password;
            // their arrival re-applies and reloads
            if reloadTabs && built.hasCredentials {
                Self.reloadLiveTabs(reason: "proxy on", in: profile)
            }
            debugLog(
                "compat: proxy ON — \(built.kind) \(built.host):\(built.port), "
                    + "\(built.excludedDomains.count) bypassed, creds=\(built.hasCredentials)")
        case "pac_script":
            // no PAC evaluation on this stack
            debugLog("compat: pac_script unsupported, treating as direct")
            clearProxy(in: profile)
        default:  // direct / system / auto_detect / unknown
            clearProxy(in: profile)
        }
    }

    private func clearProxy(in profile: UUID) {
        let wasActive = slots[profile]?.active != nil
        slots[profile]?.active = nil
        ProfileStore.setProxyConfigurations([], for: profile)
        if wasActive { Self.reloadLiveTabs(reason: "proxy off", in: profile) }
        debugLog("compat: proxy OFF")
    }

    private static func reloadLiveTabs(reason: String, in profile: UUID) {
        let reloaded = ExtensionManager.shared.reloadLiveTabs(proxyProfile: profile)
        debugLog("compat: \(reason) — reloaded \(reloaded) live tab(s)")
    }

    /// chrome `ProxyConfig` (mode fixed_servers) → one `ProxyConfiguration`.
    /// per-scheme rule sets collapse to the https rule (single-proxy is all
    /// the platform can express); socks4 and quic schemes are unsupported
    static func build(
        from value: [String: Any], credentials: (username: String, password: String)?
    ) -> BuiltProxy? {
        guard let rules = value["rules"] as? [String: Any] else { return nil }
        let server = (rules["singleProxy"] ?? rules["proxyForHttps"] ?? rules["fallbackProxy"]
            ?? rules["proxyForHttp"]) as? [String: Any]
        guard let server, let host = server["host"] as? String, !host.isEmpty else { return nil }

        let scheme = server["scheme"] as? String ?? "http"
        let defaultPort: UInt16 = scheme == "https" ? 443 : (scheme.hasPrefix("socks") ? 1080 : 80)
        let port = UInt16(exactly: (server["port"] as? NSNumber)?.intValue ?? Int(defaultPort))
            ?? defaultPort
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return nil }
        let endpoint = NWEndpoint.hostPort(host: .init(host), port: nwPort)

        var config: ProxyConfiguration
        let kind: String
        switch scheme {
        case "https":  // TLS to the proxy itself, then CONNECT — Surfshark's shape
            config = ProxyConfiguration(httpCONNECTProxy: endpoint, tlsOptions: .init())
            kind = "https-connect"
        case "http":
            config = ProxyConfiguration(httpCONNECTProxy: endpoint)
            kind = "http-connect"
        case "socks5":
            config = ProxyConfiguration(socksv5Proxy: endpoint)
            kind = "socks5"
        default:
            debugLog("compat: unsupported proxy scheme \(scheme)")
            return nil
        }

        // fail closed: a dead proxy never falls back to direct
        config.allowFailover = false

        let excluded = excludedDomains(fromBypassList: rules["bypassList"] as? [Any] ?? [])
        config.excludedDomains = excluded

        // an empty password is never sent, so the 407 reaches a web view without our delegate and
        // macOS prompts; a refused non-empty placeholder fails closed silently until the real one arrives
        config.applyCredential(
            username: credentials?.username ?? "artemis-pending",
            password: credentials?.password ?? "artemis-pending")

        return BuiltProxy(
            kind: kind, host: host, port: port, excludedDomains: excluded,
            hasCredentials: credentials != nil, config: config)
    }

    // MARK: - SameSite fetch bridge

    /// does the jar hold cookies for this URL that WebKit withholds from an extension-origin
    /// request? those are SameSite Lax/Strict, which Chrome exempts extensions from
    private static func hasSameSiteRestrictedCookies(for url: URL, in profile: UUID) async -> Bool {
        guard let host = url.host() else { return false }
        let cookies = await ProfileStore.dataStore(for: profile).httpCookieStore.allCookies()
        return cookies.contains { cookie in
            // WebKit reports unattributed cookies as "none", not nil — only
            // lax/strict are withheld cross-site, so only they need the bridge
            let policy = cookie.sameSitePolicy?.rawValue.lowercased()
            guard policy == "lax" || policy == "strict" else { return false }
            let domain = cookie.domain.hasPrefix(".")
                ? String(cookie.domain.dropFirst()) : cookie.domain
            return host == domain || host.hasSuffix("." + domain)
        }
    }

    /// the profile's cookies a request to `url` carries, as a Cookie header: RFC 6265 domain, path,
    /// secure and expiry matching, where a domain without a leading dot is that host alone
    static func cookieHeader(for url: URL, in profile: UUID) async -> String? {
        guard let host = url.host()?.lowercased() else { return nil }
        let path = url.path(percentEncoded: true).isEmpty ? "/" : url.path(percentEncoded: true)
        let now = Date()
        let matching = await ProfileStore.dataStore(for: profile).httpCookieStore.allCookies().filter { cookie in
            let domain = cookie.domain.lowercased()
            let domainOK = domain.hasPrefix(".") ? host == domain.dropFirst() || host.hasSuffix(domain) : host == domain
            let pathOK =
                path == cookie.path
                || path.hasPrefix(cookie.path)
                    && (cookie.path.hasSuffix("/") || path.dropFirst(cookie.path.count).hasPrefix("/"))
            return domainOK && pathOK && (!cookie.isSecure || url.scheme == "https")
                && (cookie.expiresDate ?? .distantFuture) > now
        }
        guard !matching.isEmpty else { return nil }
        return matching.sorted { $0.path.count > $1.path.count }.map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
    }

    /// cookie-blind and cacheless, so the WebKit store stays the only jar, and out through the
    /// profile's proxy
    static func sessionConfiguration(in profile: UUID) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        if let active = shared.activeProxy(in: profile) { configuration.proxyConfigurations = [active.config] }
        return configuration
    }

    /// perform the request natively with the jar's cookies attached, as Chrome's SameSite exemption
    /// for extensions would; Set-Cookie responses go back into the jar. a redirect to a url the
    /// context can't access ends the fetch in a network error, which hides where it pointed
    static func performBridgedFetch(
        _ message: [String: Any], for context: WKWebExtensionContext, in profile: UUID
    ) async -> [String: Any] {
        guard let raw = message["url"] as? String, let url = URL(string: raw),
            url.scheme == "https" || url.scheme == "http"
        else { return [:] }

        let cookieStore = ProfileStore.dataStore(for: profile).httpCookieStore
        var request = URLRequest(url: url)
        request.httpMethod = (message["method"] as? String) ?? "GET"
        for (key, value) in (message["headers"] as? [String: String]) ?? [:] {
            // the cookie header is ours to write; hop-by-hop headers stay out
            guard !["cookie", "host", "content-length"].contains(key.lowercased()) else { continue }
            request.setValue(value, forHTTPHeaderField: key)
        }
        if let cookies = await cookieHeader(for: url, in: profile) {
            request.setValue(cookies, forHTTPHeaderField: "Cookie")
        }
        if let body = message["bodyBase64"] as? String { request.httpBody = Data(base64Encoded: body) }
        request.httpShouldHandleCookies = false

        let session = URLSession(
            configuration: sessionConfiguration(in: profile),
            delegate: BridgedFetchRedirects { context.hasAccess(to: $0) }, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return [:] }
            var headers: [String: String] = [:]
            for (key, value) in http.allHeaderFields {
                guard let key = key as? String, let value = value as? String else { continue }
                // Set-Cookie goes back into the jar, not to the page (fetch
                // hides it from JS anyway)
                if key.lowercased() == "set-cookie" { continue }
                headers[key] = value
            }
            if let fields = http.allHeaderFields as? [String: String] {
                for cookie in HTTPCookie.cookies(withResponseHeaderFields: fields, for: http.url ?? url) {
                    await cookieStore.setCookie(cookie)
                }
            }
            debugLog("compat: bridged fetch \(request.httpMethod ?? "?") \(url.host() ?? "?") → \(http.statusCode)")
            return [
                "status": http.statusCode,
                "statusText": HTTPURLResponse.localizedString(forStatusCode: http.statusCode),
                "headers": headers,
                "bodyBase64": data.base64EncodedString(),
            ]
        } catch URLError.cancelled {
            debugLog("compat: bridged fetch \(url.host() ?? "?") redirected out of reach")
            return ["networkError": true]
        } catch {
            debugLog("compat: bridged fetch failed — \(error.localizedDescription)")
            return [:]
        }
    }

    /// chrome bypassList → `excludedDomains`, which matches host suffixes only. entries it can't
    /// express (CIDR blocks, scheme/port patterns, `<local>`) are dropped, proxying that traffic
    private static func excludedDomains(fromBypassList list: [Any]) -> [String] {
        list.compactMap { raw in
            guard var entry = raw as? String else { return nil }
            if entry.contains("://") { entry = String(entry.split(separator: "/").dropFirst().first ?? "") }
            guard !entry.isEmpty, entry != "<local>", !entry.contains("/") else { return nil }
            if entry.hasPrefix("*.") { entry = String(entry.dropFirst(2)) }
            // strip a :port — suffix matching has no port dimension
            if let colon = entry.lastIndex(of: ":"), entry[entry.index(after: colon)...].allSatisfy(\.isNumber) {
                entry = String(entry[..<colon])
            }
            return entry.isEmpty ? nil : entry
        }
    }
}

/// a cookie-carrying fetch's redirects: the cookie header it attached is for the first url's scheme
/// and host only, and URLSession would carry it to wherever the server points. a redirect to a url
/// `reaches` refuses cancels the task
nonisolated final class BridgedFetchRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    private let reaches: (@MainActor @Sendable (URL) -> Bool)?

    init(reaches: (@MainActor @Sendable (URL) -> Bool)? = nil) {
        self.reaches = reaches
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        let from = task.originalRequest?.url, to = request.url
        var next = request
        if to?.host() != from?.host() || to?.scheme != from?.scheme {
            next.setValue(nil, forHTTPHeaderField: "Cookie")
        }
        guard let reaches else { return completionHandler(next) }
        Task { @MainActor [next] in
            guard to.map(reaches) == true else {
                task.cancel()
                return completionHandler(nil)
            }
            completionHandler(next)
        }
    }
}
