import CoreGraphics
import Foundation
import Network
import Security
import WebKit

/// Native half of the chrome.proxy compat layer (`ExtensionCompat` is the JS
/// half): receives the shim's `sendNativeMessage` traffic and drives real
/// WebKit proxying via `WKWebsiteDataStore.proxyConfigurations` (macOS 14+).
///
/// What the API gives us (verified): per-datastore proxies, runtime-swappable
/// on live stores (new connections adopt them; kept-alive connections migrate
/// as they close), covering subresources, fetch/XHR and WebSockets. What it
/// can't do: route per-scheme (DTS: impossible — `singleProxy` semantics only),
/// proxy WebRTC/UDP, or stop DNS-prefetch/WebTransport leaks — those are
/// WebKit-wide and hit iCloud Private Relay too.
///
/// Credentials arrive separately ("proxy.credentials"): WebKit's
/// `webRequest.onAuthRequired` ignores extension return values, so the shim
/// invokes the extension's own auth handler itself and forwards what it
/// returns; `ProxyConfiguration.applyCredential` answers the 407 natively.
@MainActor
final class ExtensionProxyBridge {
    static let shared = ExtensionProxyBridge()

    /// one profile's proxy: a VPN applies only to the profiles it is enabled in
    private struct Slot {
        /// the chrome-side `ProxyConfig` value as last set. **Persisted**: a VPN
        /// restores "connected" from its own storage on launch and may not re-assert
        /// the proxy, so the browser must come back up proxied (fail-closed)
        var value: [String: Any]?
        /// the context that set it; Chrome reverts the setting when it goes
        var owner: String?
        var credentials: (username: String, password: String)?
        var active: BuiltProxy?
        /// a clear held briefly so a server switch doesn't fall through to direct
        var pendingClear: Task<Void, Never>?
    }
    private var slots: [UUID: Slot] = [:]
    private static let ownerKey = "artemisOwner"
    /// non-proxy ChromeSettings (webRTCIPHandlingPolicy etc.) — stored and
    /// echoed back so extension UIs stay coherent; not yet enforced natively
    private var settingValues: [String: Any] = [:]

    /// what the current chrome value compiled down to — for the self-test and
    /// the Settings diagnostics row
    struct BuiltProxy {
        var kind: String  // "https-connect" | "http-connect" | "socks5"
        var host: String
        var port: UInt16
        var excludedDomains: [String]
        var hasCredentials: Bool
        var config: ProxyConfiguration
    }
    func activeProxy(in profile: UUID) -> BuiltProxy? { slots[profile]?.active }

    func chromeProxyValue(in profile: UUID) -> [String: Any]? { slots[profile]?.value }

    /// the proxy credentials as a URLCredential, for answering 407 challenges
    /// in the navigation delegate (backstop to `applyCredential`, and what
    /// suppresses macOS's own proxy-password dialog)
    func proxyURLCredential(in profile: UUID) -> URLCredential? {
        guard let credentials = slots[profile]?.credentials else { return nil }
        return URLCredential(
            user: credentials.username, password: credentials.password, persistence: .forSession)
    }

    /// whether the screen is currently locked — feeds the chrome.idle shim's
    /// "locked" state, which vault-timeout code treats as "lock now". the
    /// distributed notifications are the only public signal for this
    private(set) var screenIsLocked = false

    init() {
        let center = DistributedNotificationCenter.default()
        let locked = "com.apple.screenIsLocked", unlocked = "com.apple.screenIsUnlocked"
        center.addObserver(
            forName: .init(locked), object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.screenIsLocked = true } }
        center.addObserver(
            forName: .init(unlocked), object: nil, queue: .main
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
                let value = slots[profile]?.value
                return [
                    "value": value ?? ["mode": "system"],
                    "levelOfControl": value == nil
                        ? "controllable_by_this_extension" : "controlled_by_this_extension",
                ]
            }
            guard let value = settingValues[name] else { return [:] }
            return ["value": value, "levelOfControl": "controlled_by_this_extension"]

        case "setting.set":
            guard let name else { return [:] }
            if name == "proxy" {
                let value = message["value"] as? [String: Any]
                if value != nil { slots[profile, default: Slot()].owner = sender }
                setProxy(value, in: profile)
            } else {
                if let value = message["value"] { settingValues[name] = value }
                debugLog("compat: setting \(name) = \(String(describing: message["value"]))")
            }
            return ["ok": true]

        case "setting.clear":
            guard let name else { return [:] }
            if name == "proxy" { setProxy(nil, in: profile) } else { settingValues[name] = nil }
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
                guard let tab = ExtensionManager.shared.currentTab else { return [] }
                guard tab.profileID == profile else { return [] }
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
            // the chrome.idle shim asks for the real system idle clock: seconds
            // since the last keyboard/mouse/scroll event, plus whether the
            // screen is locked. this is what lets a password manager's
            // "lock the vault when the machine idles" actually mean something
            let seconds = CGEventSource.secondsSinceLastEventType(
                .hidSystemState, eventType: CGEventType(rawValue: ~0)!)
            return ["seconds": Int(seconds), "locked": screenIsLocked]

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
            // self-test only: plant a SameSite=Lax cookie in the shared jar so
            // the bridge's discrimination + carry can be proven end-to-end
            // without depending on page-side cookie writes. limited to the
            // suite's echo host so it can't be abused as a cookie写 primitive
            guard let raw = message["url"] as? String, let url = URL(string: raw),
                url.host() == "httpbin.org",
                let cookie = HTTPCookie(properties: [
                    .name: "artemislax", .value: "1", .domain: "httpbin.org",
                    .path: "/", .secure: "TRUE", .sameSitePolicy: "lax",
                ])
            else { return [:] }
            await WKWebsiteDataStore.default().httpCookieStore.setCookie(cookie)
            return ["ok": true]

        case "cookies.dump":
            // diag: what does the jar hold for this URL, and how is each
            // cookie's SameSite recorded? (probe-only introspection)
            guard let raw = message["url"] as? String, let url = URL(string: raw),
                let host = url.host()
            else { return [:] }
            let jar = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
            let rows = jar.compactMap { cookie -> String? in
                let domain = cookie.domain.hasPrefix(".")
                    ? String(cookie.domain.dropFirst()) : cookie.domain
                guard host == domain || host.hasSuffix("." + domain) else { return nil }
                return "\(cookie.name) sameSite=\(cookie.sameSitePolicy?.rawValue ?? "nil")"
            }
            return ["cookies": rows.joined(separator: ", ")]

        case "fetch.perform":
            return await Self.performBridgedFetch(message, in: profile)

        case "probe.report":
            // the self-test's probe extension reports live runtime behaviour
            // (tabs.query results etc.) through the same channel
            probeReports.append(message)
            return ["ok": true]

        case "proxy.credentials":
            guard let username = message["username"] as? String else { return [:] }
            slots[profile, default: Slot()].credentials = (username, message["password"] as? String ?? "")
            // rebuild so applyCredential lands on the active config
            if let value = slots[profile]?.value { applyProxy(value, in: profile) }
            persist(profile)
            debugLog("compat: proxy credentials received for \(username)")
            return ["ok": true]

        default:
            return [:]
        }
    }

    // MARK: - Persistence

    /// the default profile keeps the file and keychain item it always had
    private static func stateFile(_ profile: UUID) -> String {
        profile == Profile.defaultID ? "proxy-state.json" : "proxy-state-\(profile.uuidString).json"
    }
    private static func keychainService(_ profile: UUID) -> String {
        // another bundle ID keeps its own items in the shared login keychain
        let id = Bundle.main.bundleIdentifier ?? "dev.findles.Artemis"
        let base = id.hasPrefix("dev.findles.Artemis") ? "app.artemis.proxy-credentials" : "\(id).proxy-credentials"
        return profile == Profile.defaultID ? base : "\(base).\(profile.uuidString)"
    }

    /// restore every profile's proxy across launches so protection resumes with the
    /// browser rather than after the user notices it is missing. called before any
    /// tab loads (from `ExtensionManager.attach`)
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
            slot.credentials = Self.loadCredentials(profile)
            slot.owner = value[Self.ownerKey] as? String
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
        Self.saveCredentials(slot?.credentials, profile)
    }

    /// proxy credentials belong in the keychain, not a plist — they are a
    /// living service credential for the user's VPN account
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

    /// run a held clear immediately instead of waiting out the grace period,
    /// so the suite can assert the disconnect path without a 25s pause
    func finishPendingClearForTesting(in profile: UUID) {
        guard slots[profile]?.pendingClear != nil else { return }
        slots[profile]?.pendingClear?.cancel()
        slots[profile]?.pendingClear = nil
        slots[profile]?.value = nil
        persist(profile)
        clearProxy(in: profile)
    }

    /// drop in-memory proxy state without touching what's on disk — lets the
    /// self-test prove a real restore rather than reading back its own memory
    func forgetForTesting(in profile: UUID) {
        slots[profile] = nil
        ProfileStore.setProxyConfigurations([], for: profile)
    }

    /// the extension that set a profile's proxy is gone from it (removed, disabled,
    /// or not back after a relaunch): clear at once, since no switch can follow
    func release(owner id: String, in profile: UUID) {
        guard slots[profile]?.owner == id else { return }
        slots[profile]?.pendingClear?.cancel()
        slots[profile] = Slot(credentials: slots[profile]?.credentials)
        persist(profile)
        clearProxy(in: profile)
    }

    func releaseUnless(loaded: (_ owner: String, _ profile: UUID) -> Bool) {
        for (profile, slot) in slots {
            if let owner = slot.owner, !loaded(owner, profile) { release(owner: owner, in: profile) }
        }
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

    /// how long a clear is held before it is believed. A switch (disconnect →
    /// pick server → reconnect) can take ~20s, and dropping to direct in that
    /// window leaks the real IP with the VPN's UI still saying "connected" —
    /// which is exactly what a VPN must never do. A genuine disconnect is
    /// simply protected for a few seconds longer, which is the safe direction
    /// to be wrong in.
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
                // credentials survive a disconnect on purpose: they are
                // account-level (any server accepts them) and already in the
                // keychain, so the next connect authenticates instantly
                // instead of opening a window where the proxy is applied
                // without them — which is when the system prompts for a
                // password the user doesn't have
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
            guard let built = Self.build(from: value, credentials: slots[profile]?.credentials) else {
                debugLog("compat: proxy rules unusable, clearing")
                return clearProxy(in: profile)
            }
            slots[profile, default: Slot()].active = built
            ProfileStore.setProxyConfigurations([built.config], for: profile)
            // only reload once we can actually authenticate: reloading into a
            // credential-less proxy races the auth handshake, every request
            // 407s, and macOS puts up its own password dialog. When creds
            // arrive they re-apply and the reload happens then.
            if reloadTabs && built.hasCredentials {
                Self.reloadLiveTabs(reason: "proxy on", in: profile)
            }
            debugLog(
                "compat: proxy ON — \(built.kind) \(built.host):\(built.port), "
                    + "\(built.excludedDomains.count) bypassed, creds=\(built.hasCredentials)")
        case "pac_script":
            // no PAC on this stack (would need app-side JSC evaluation with
            // host-suffix fidelity only) — treat as direct rather than lie
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

    /// A proxy change only affects *new* connections — anything already
    /// keep-alive keeps using the old path, so a page loaded a moment ago
    /// still shows the old exit until something forces it to reconnect. That
    /// is why toggling the VPN appeared to do nothing until a manual reload.
    /// Reload the profile's live pages (its incognito ones included) so the
    /// switch takes effect immediately.
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

        // fail closed: a dead proxy must never silently fall back to direct —
        // that's the difference between a VPN and a decoration
        config.allowFailover = false

        let excluded = excludedDomains(fromBypassList: rules["bypassList"] as? [Any] ?? [])
        config.excludedDomains = excluded

        // A proxy applied with no credential at all makes the network stack ask
        // the *user* for a proxy password — for a server they never chose and
        // whose password they don't know. Applying a placeholder keeps that
        // prompt away: connections fail closed until the extension's real
        // credentials arrive (moments later), which re-applies and reloads.
        config.applyCredential(
            username: credentials?.username ?? "artemis-pending",
            password: credentials?.password ?? "")

        return BuiltProxy(
            kind: kind, host: host, port: port, excludedDomains: excluded,
            hasCredentials: credentials != nil, config: config)
    }

    // MARK: - SameSite fetch bridge

    /// does the shared jar hold cookies for this URL that WebKit would
    /// withhold from a cross-site (extension-origin) request? those are the
    /// SameSite Lax/Strict ones — the exact class Chrome exempts extensions
    /// from and WebKit doesn't (Surfshark's `_sstk` session cookie is Lax)
    static func hasSameSiteRestrictedCookies(for url: URL, in profile: UUID) async -> Bool {
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

    /// perform the request natively with the jar's cookies attached — the
    /// SameSite exemption Chrome gives host-permitted extension requests.
    /// Set-Cookie responses are written back into the shared jar so a login
    /// flow's session survives the detour
    static func performBridgedFetch(_ message: [String: Any], in profile: UUID) async -> [String: Any] {
        guard let raw = message["url"] as? String, let url = URL(string: raw),
            let scheme = url.scheme, scheme == "https" || scheme == "http"
        else { return [:] }

        let cookieStore = ProfileStore.dataStore(for: profile).httpCookieStore
        let jar = await cookieStore.allCookies()
        let matching = jar.filter { cookie in
            let domain = cookie.domain.hasPrefix(".")
                ? String(cookie.domain.dropFirst()) : cookie.domain
            guard let host = url.host() else { return false }
            let domainOK = host == domain || host.hasSuffix("." + domain)
            let pathOK = url.path.isEmpty || url.path.hasPrefix(cookie.path)
                || cookie.path == "/"
            let secureOK = !cookie.isSecure || scheme == "https"
            return domainOK && pathOK && secureOK
        }

        var request = URLRequest(url: url)
        request.httpMethod = (message["method"] as? String) ?? "GET"
        for (key, value) in (message["headers"] as? [String: String]) ?? [:] {
            // the cookie header is ours to write; hop-by-hop headers stay out
            guard !["cookie", "host", "content-length"].contains(key.lowercased()) else { continue }
            request.setValue(value, forHTTPHeaderField: key)
        }
        if !matching.isEmpty {
            request.setValue(
                matching.map { "\($0.name)=\($0.value)" }.joined(separator: "; "),
                forHTTPHeaderField: "Cookie")
        }
        if let body = message["body"] as? String { request.httpBody = Data(body.utf8) }
        request.httpShouldHandleCookies = false

        do {
            let (data, response) = try await bridgedSession(for: profile).data(for: request)
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
                for cookie in HTTPCookie.cookies(withResponseHeaderFields: fields, for: url) {
                    await cookieStore.setCookie(cookie)
                }
            }
            debugLog("compat: bridged fetch \(request.httpMethod ?? "?") \(url.host() ?? "?") → \(http.statusCode)")
            return [
                "status": http.statusCode,
                "statusText": HTTPURLResponse.localizedString(forStatusCode: http.statusCode),
                "headers": headers,
                "bodyBase64": data.count <= 4_000_000 ? data.base64EncodedString() : "",
            ]
        } catch {
            debugLog("compat: bridged fetch failed — \(error.localizedDescription)")
            return [:]
        }
    }

    /// cookie-blind session: the jar of record is the WebKit store; letting
    /// URLSession keep its own copy would fork the session state. rebuilt
    /// whenever the profile's proxy changes so bridged fetches ride the same
    /// proxy as its web views — without this they'd bypass the VPN entirely
    /// (a leak, and the extension would keep seeing the real IP)
    private static var bridgedSessions: [String: URLSession] = [:]

    @MainActor
    private static func bridgedSession(for profile: UUID) -> URLSession {
        let active = ExtensionProxyBridge.shared.activeProxy(in: profile)
        let signature = active.map { "\($0.kind):\($0.host):\($0.port):\($0.hasCredentials)" }
            ?? "direct"
        if let cached = bridgedSessions[signature] { return cached }
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        if let active { config.proxyConfigurations = [active.config] }
        let session = URLSession(configuration: config)
        bridgedSessions[signature] = session
        return session
    }

    /// chrome bypassList → `excludedDomains`, which matches host *suffixes*
    /// only. entries the platform can't express (CIDR blocks, scheme/port
    /// patterns, `<local>`) are dropped — a too-narrow bypass just means that
    /// traffic also goes through the proxy, which errs on the safe side
    static func excludedDomains(fromBypassList list: [Any]) -> [String] {
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
