// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import WebKit

/// artemisbrowser.app's own frames read the short version from `data-artemis` on their root, and
/// `data-artemis-icon` once a visit has unlocked the Home icon. Nothing runs from a page back to the app
enum HomeEgg {
    static let unlockedKey = "appIconHomeUnlocked"
    static let origins = ["https://artemisbrowser.app", "https://www.artemisbrowser.app"]
    private static let world = WKContentWorld.world(name: "Artemis.Home")

    static var isUnlocked: Bool { UserDefaults.standard.bool(forKey: unlockedKey) }

    /// digits and dots only, so nothing else about this build can reach the page
    static let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
        .filter { $0.isASCII && ($0.isNumber || $0 == ".") }

    static func install(into controller: WKUserContentController) {
        controller.addUserScript(script("artemis", version))
        if isUnlocked { controller.addUserScript(script("artemisIcon", "unlocked")) }
    }

    /// sets one attribute on the root of each frame whose own origin is ours, from a world the page can't reach
    static func script(_ key: String, _ value: String) -> WKUserScript {
        let list = origins.map { "\"\($0)\"" }.joined(separator: ",")
        let source = "if([\(list)].indexOf(location.origin)>=0)document.documentElement.dataset.\(key)=\"\(value)\";"
        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: world)
    }

    /// a main-frame commit at exactly our https origin, outside incognito, on a connection no certificate exception opened
    static func unlocks(_ url: URL?, isSecure: Bool, isPrivate: Bool) -> Bool {
        guard let url, url.scheme == "https", url.user == nil, url.password == nil, url.port == nil || url.port == 443,
            let host = url.host(percentEncoded: true)
        else { return false }
        return origins.contains("https://" + host) && isSecure && !isPrivate
    }

    /// unlocks once the committed page's own certificate chain verifies for its host
    static func pageDidCommit(_ webView: WKWebView, isSecure: Bool, isPrivate: Bool) {
        guard !isUnlocked, unlocks(webView.url, isSecure: isSecure, isPrivate: isPrivate),
            let host = webView.url?.host(percentEncoded: true),
            let certificates = webView.serverTrust.flatMap(SecTrustCopyCertificateChain) as? [SecCertificate]
        else { return }
        let chain = certificates.map { SecCertificateCopyData($0) as Data }
        Task {
            if await verifies(chain, host: host) { unlock() }
        }
    }

    @concurrent nonisolated private static func verifies(_ chain: [Data], host: String) async -> Bool {
        let certificates = chain.compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
        var trust: SecTrust?
        guard certificates.count == chain.count,
            SecTrustCreateWithCertificates(certificates as CFArray, SecPolicyCreateSSL(true, host as CFString), &trust) == errSecSuccess,
            let trust
        else { return false }
        return SecTrustEvaluateWithError(trust, nil)
    }

    /// cosmetic and idempotent: the flag, and the attribute for pages loaded after it
    static func unlock() {
        guard !isUnlocked else { return }
        UserDefaults.standard.set(true, forKey: unlockedKey)
        let icon = script("artemisIcon", "unlocked")
        SharedWebContent.all.forEach { $0.addUserScript(icon) }
    }
}
