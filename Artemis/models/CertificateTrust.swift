// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import AppKit
import Foundation
import Security
import SecurityInterface

/// the hosts whose refused certificate the user chose to trust. each exception
/// is a `SecTrustCopyExceptions` blob, bound to one certificate: a host that
/// presents a different one is refused, and asked about, again
@MainActor
enum CertificateTrust {
    /// the trust from each host's most recent challenge. a failed load carries
    /// none, so the certificate being asked about is the one kept here
    private static var seen: [String: SecTrust] = [:]

    private static var exceptions: [String: Data] = load()
    private static let file = "certificate-exceptions.json"

    static func remember(_ trust: SecTrust, for host: String) {
        seen[host] = trust
    }

    /// the certificate chain the user is being asked about, for the viewer
    static func trust(for host: String) -> SecTrust? { seen[host] }

    static func hasException(for host: String) -> Bool { exceptions[host] != nil }

    /// apply a stored exception, returning true only when the trust then
    /// evaluates; a blob for another certificate leaves it untouched
    static func applyException(to trust: SecTrust, host: String) -> Bool {
        guard let blob = exceptions[host] else { return false }
        guard SecTrustSetExceptions(trust, blob as CFData) else { return false }
        var error: CFError?
        return SecTrustEvaluateWithError(trust, &error)
    }

    /// trust the certificate this host most recently presented; false when there
    /// is none to bind the exception to
    @discardableResult
    static func addException(for host: String) -> Bool {
        guard let trust = seen[host],
            let blob = SecTrustCopyExceptions(trust) as Data?
        else { return false }
        exceptions[host] = blob
        save()
        return true
    }

    static func forget(_ host: String) {
        exceptions.removeValue(forKey: host)
        save()
    }

    /// for Clear Browsing Data
    static func forgetAll() {
        exceptions = [:]
        save()
    }

    private static func load() -> [String: Data] {
        AppStorageLocation.loadDurable(
            [String: Data].self, from: AppStorageLocation.file(file)) ?? [:]
    }

    private static func save() {
        guard let data = try? JSONEncoder().encode(exceptions) else { return }
        AppStorageLocation.writeDurableNow(data, to: AppStorageLocation.file(file))
    }

    /// the system certificate sheet for `trust`'s chain, over the key window
    static func showViewer(trust: SecTrust?) {
        guard let trust, let window = NSApp.keyWindow,
            let certificates = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
            !certificates.isEmpty
        else { return }
        SFCertificatePanel().beginSheet(
            for: window, modalDelegate: nil, didEnd: nil, contextInfo: nil,
            certificates: certificates, showGroup: true)
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
