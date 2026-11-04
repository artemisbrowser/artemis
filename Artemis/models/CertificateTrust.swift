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
    private static var exceptions: [String: Data] = load()
    /// accepted in incognito: never written, and applied to incognito pages only
    private static var ephemeralExceptions: [String: Data] = [:]
    private static let file = "certificate-exceptions.json"

    static func hasException(for host: String, ephemeral: Bool = false) -> Bool {
        (ephemeral && ephemeralExceptions[host] != nil) || exceptions[host] != nil
    }

    /// apply a stored exception, returning true only when the trust then
    /// evaluates; a blob for another certificate leaves it untouched
    static func applyException(to trust: SecTrust, host: String, ephemeral: Bool) -> Bool {
        guard let blob = (ephemeral ? ephemeralExceptions[host] : nil) ?? exceptions[host] else { return false }
        guard SecTrustSetExceptions(trust, blob as CFData) else { return false }
        var error: CFError?
        return SecTrustEvaluateWithError(trust, &error)
    }

    /// trust the certificate `trust` holds for this host; false when there is no
    /// exception to bind. an `ephemeral` one lasts until incognito closes
    @discardableResult
    static func addException(for host: String, trust: SecTrust, ephemeral: Bool) -> Bool {
        guard let blob = SecTrustCopyExceptions(trust) as Data? else { return false }
        if ephemeral {
            ephemeralExceptions[host] = blob
            return true
        }
        exceptions[host] = blob
        save()
        return true
    }

    static func forget(_ host: String) {
        ephemeralExceptions.removeValue(forKey: host)
        exceptions.removeValue(forKey: host)
        save()
    }

    /// for Clear Browsing Data
    static func forgetAll() {
        ephemeralExceptions = [:]
        exceptions = [:]
        AppStorageLocation.discardUnreadable(of: AppStorageLocation.file(file))
        save(keepsBackup: false)
    }

    /// the last incognito window closed: its exceptions go with it
    static func forgetEphemeral() {
        ephemeralExceptions = [:]
    }

    private static func load() -> [String: Data] {
        AppStorageLocation.loadDurable(
            [String: Data].self, from: AppStorageLocation.file(file)) ?? [:]
    }

    private static func save(keepsBackup: Bool = true) {
        guard let data = try? JSONEncoder().encode(exceptions) else { return }
        AppStorageLocation.writeDurableNow(data, to: AppStorageLocation.file(file), keepsBackup: keepsBackup)
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
