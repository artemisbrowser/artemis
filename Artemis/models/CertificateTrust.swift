// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import AppKit
import Foundation
import Security
import SecurityInterface

/// one profile's hosts whose refused certificate the user chose to trust. each exception
/// is a `SecTrustCopyExceptions` blob, bound to one certificate: a host that
/// presents a different one is refused, and asked about, again
@MainActor
final class CertificateTrust {
    private var exceptions: [String: Data]
    /// accepted in this profile's incognito windows: never written, and applied to incognito pages only
    private var ephemeralExceptions: [String: Data] = [:]
    private let fileURL: URL

    /// hosts that sent Strict-Transport-Security over a trusted connection
    private struct StrictHost: Codable {
        var expires: Date
        var includesSubdomains: Bool
    }
    private var strictHosts: [String: StrictHost]
    /// learned in incognito: never written
    private var ephemeralStrictHosts: [String: StrictHost] = [:]
    private let strictURL: URL
    private static let maxStrictAge: TimeInterval = 365 * 86_400

    init(fileURL: URL, strictURL: URL) {
        self.fileURL = fileURL
        self.strictURL = strictURL
        exceptions = AppStorageLocation.loadDurable([String: Data].self, from: fileURL) ?? [:]
        let now = Date()
        strictHosts = (AppStorageLocation.loadDurable([String: StrictHost].self, from: strictURL) ?? [:])
            .filter { $0.value.expires > now }
    }

    func hasException(for host: String, ephemeral: Bool = false) -> Bool {
        (ephemeral && ephemeralExceptions[host] != nil) || exceptions[host] != nil
    }

    /// apply a stored exception, returning true only when the trust then evaluates; a blob
    /// for another certificate leaves it untouched, and none applies where a secure connection is required
    func applyException(to trust: SecTrust, host: String, ephemeral: Bool) -> Bool {
        guard let blob = (ephemeral ? ephemeralExceptions[host] : nil) ?? exceptions[host],
            !requiresSecureConnection(host, ephemeral: ephemeral)
        else { return false }
        guard SecTrustSetExceptions(trust, blob as CFData) else { return false }
        var error: CFError?
        return SecTrustEvaluateWithError(trust, &error)
    }

    /// trust the certificate `trust` holds for this host; false when there is no
    /// exception to bind. an `ephemeral` one lasts until incognito closes
    @discardableResult
    func addException(for host: String, trust: SecTrust, ephemeral: Bool) -> Bool {
        guard let blob = SecTrustCopyExceptions(trust) as Data? else { return false }
        if ephemeral {
            ephemeralExceptions[host] = blob
            return true
        }
        exceptions[host] = blob
        save()
        return true
    }

    func forget(_ host: String) {
        ephemeralExceptions.removeValue(forKey: host)
        exceptions.removeValue(forKey: host)
        save()
    }

    /// for Clear Browsing Data
    func forgetAll() {
        ephemeralExceptions = [:]
        exceptions = [:]
        AppStorageLocation.discardUnreadable(of: fileURL)
        save(keepsBackup: false)
        ephemeralStrictHosts = [:]
        strictHosts = [:]
        AppStorageLocation.discardUnreadable(of: strictURL)
        saveStrict(keepsBackup: false)
    }

    static let strictSeededKey = "certificateTrust.strictSeeded"

    /// once: every profile existing when learned hosts became per profile keeps the app-wide list
    static func seedStrictHosts(into profiles: [Profile]) {
        guard !UserDefaults.standard.bool(forKey: strictSeededKey) else { return }
        UserDefaults.standard.set(true, forKey: strictSeededKey)
        for profile in profiles where !profile.isDefault {
            profile.certificateTrust.learnStrictHosts(from: AppStorageLocation.file("strict-transport.json"))
        }
    }

    /// adds `url`'s unexpired learned hosts; a host this profile already holds keeps its own entry
    func learnStrictHosts(from url: URL) {
        let now = Date()
        let seeded = (AppStorageLocation.loadDurable([String: StrictHost].self, from: url) ?? [:])
            .filter { $0.value.expires > now }
        guard !seeded.isEmpty else { return }
        strictHosts.merge(seeded) { mine, _ in mine }
        saveStrict()
    }

    /// the last incognito window closed: its exceptions go with it
    func forgetEphemeral() {
        ephemeralExceptions = [:]
        ephemeralStrictHosts = [:]
    }

    private func save(keepsBackup: Bool = true) {
        guard let data = try? JSONEncoder().encode(exceptions) else { return }
        AppStorageLocation.writeDurableNow(data, to: fileURL, keepsBackup: keepsBackup)
    }

    /// the system certificate sheet for `trust`'s chain, over the key window
    static func showViewer(trust: SecTrust?) {
        guard let trust, let window = Lobby.keyWindow,
            let certificates = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
            !certificates.isEmpty
        else { return }
        SFCertificatePanel().beginSheet(
            for: window, modalDelegate: nil, didEnd: nil, contextInfo: nil,
            certificates: certificates, showGroup: true)
    }

    /// record a Strict-Transport-Security header (RFC 6797) from a connection no exception opened.
    /// `max-age=0` forgets the host
    func noteStrictTransport(_ header: String, host: String, ephemeral: Bool) {
        let directives = header.split(separator: ";").map {
            $0.trimmingCharacters(in: .whitespaces).lowercased()
        }
        // delta-seconds is digits alone (RFC 6797), held to a year at most
        guard
            let age = directives.lazy.compactMap({ directive -> TimeInterval? in
                guard directive.hasPrefix("max-age=") else { return nil }
                let digits = directive.dropFirst(8).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                guard !digits.isEmpty, digits.allSatisfy({ ("0"..."9").contains($0) }) else { return nil }
                return min(TimeInterval(digits) ?? Self.maxStrictAge, Self.maxStrictAge)
            }).first
        else { return }
        let host = host.lowercased()
        let entry = StrictHost(
            expires: Date().addingTimeInterval(age), includesSubdomains: directives.contains("includesubdomains"))
        if ephemeral {
            ephemeralStrictHosts[host] = age == 0 ? nil : entry
            return
        }
        let known = strictHosts[host]
        if age == 0 {
            guard known != nil else { return }
            strictHosts[host] = nil
        } else {
            // the file is rewritten only when a record changes by more than a day
            if let known, known.includesSubdomains == entry.includesSubdomains,
                abs(known.expires.timeIntervalSince(entry.expires)) < 86_400
            {
                return
            }
            strictHosts[host] = entry
        }
        saveStrict()
    }

    /// `host` or a parent that covers its subdomains sent Strict-Transport-Security, unexpired
    private func isLearnedStrict(_ host: String, ephemeral: Bool) -> Bool {
        let labels = host.lowercased().split(separator: ".")
        let now = Date()
        return labels.indices.contains { start in
            let candidate = labels[start...].joined(separator: ".")
            return [ephemeral ? ephemeralStrictHosts[candidate] : nil, strictHosts[candidate]].contains {
                guard let entry = $0, entry.expires > now else { return false }
                return start == 0 || entry.includesSubdomains
            }
        }
    }

    private func saveStrict(keepsBackup: Bool = true) {
        guard let data = try? JSONEncoder().encode(strictHosts) else { return }
        if keepsBackup {
            AppStorageLocation.writeDurable(data, to: strictURL)
        } else {
            AppStorageLocation.writeDurableNow(data, to: strictURL, keepsBackup: false)
        }
    }

    private typealias HSTSCheck = @convention(c) (CFURL, UnsafeRawPointer?) -> DarwinBoolean
    /// with no session, CFNetwork answers from the HSTS preload list (Chromium's), not from the hosts
    /// WebKit's network process learned. Looked up in every loaded image (RTLD_DEFAULT)
    private nonisolated static let isKnownHSTSHost = dlsym(
        UnsafeMutableRawPointer(bitPattern: -2), "_CFNetworkIsKnownHSTSHostWithSession"
    ).map { unsafeBitCast($0, to: HSTSCheck.self) }

    /// an HSTS site, preloaded or learned: none of its certificate failures may be accepted.
    /// every host is one when the preload check is missing
    func requiresSecureConnection(_ host: String, ephemeral: Bool = false) -> Bool {
        guard let isKnownHSTSHost = Self.isKnownHSTSHost, let url = URL(string: "https://\(host)/") else { return true }
        return isKnownHSTSHost(url as CFURL, nil).boolValue || isLearnedStrict(host, ephemeral: ephemeral)
    }

    /// the certificate failures a user may choose to accept; every other TLS
    /// error is final
    static func isOverridable(_ error: NSError) -> Bool {
        guard error.domain == NSURLErrorDomain else { return false }
        return [
            NSURLErrorServerCertificateUntrusted,
            NSURLErrorServerCertificateHasBadDate,
            NSURLErrorServerCertificateHasUnknownRoot,
            NSURLErrorServerCertificateNotYetValid,
        ].contains(error.code)
    }
}
