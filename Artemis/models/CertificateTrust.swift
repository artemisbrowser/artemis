import AppKit
import Foundation
import Security
import SecurityInterface

/// Which hosts you have chosen to trust despite a certificate the system
/// refuses, and the machinery for making that choice safely.
///
/// The exception blob comes from `SecTrustCopyExceptions`, which is bound to the
/// certificate that produced it. That is the security property worth having and
/// it is free: if the host later presents a *different* certificate the blob no
/// longer applies, the load fails again, and the user is asked again. A trust
/// decision here is therefore about one host and one certificate, never "this
/// host is fine forever".
@MainActor
enum CertificateTrust {
    /// the trust object from the most recent challenge, per host. A failed load
    /// carries no trust with it, so the certificate the user is being asked
    /// about has to be kept from the challenge that preceded the failure
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
    /// evaluates. A blob that no longer matches leaves the trust untouched, so
    /// this can't quietly wave through a changed certificate.
    static func applyException(to trust: SecTrust, host: String) -> Bool {
        guard let blob = exceptions[host] else { return false }
        guard SecTrustSetExceptions(trust, blob as CFData) else { return false }
        var error: CFError?
        return SecTrustEvaluateWithError(trust, &error)
    }

    /// record the user's decision for the certificate this host most recently
    /// presented. Returns false when there is no such certificate to bind to,
    /// which is the only honest answer — an exception with nothing to scope it
    /// to would be "trust anything from this host".
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

    /// used by Clear Browsing Data: these are decisions about sites
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

    /// The native certificate viewer — the chain/validity/Trust/Details sheet,
    /// opened straight to the certificate rather than the collapsed prompt.
    static func showViewer(trust: SecTrust?) {
        guard let trust, let window = NSApp.keyWindow,
            let certificates = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
            !certificates.isEmpty
        else { return }
        SFCertificatePanel().beginSheet(
            for: window, modalDelegate: nil, didEnd: nil, contextInfo: nil,
            certificates: certificates, showGroup: true)
    }

    /// Failures worth offering a way past. Deliberately not every TLS error: a
    /// name mismatch or an expired certificate is a mistake you can knowingly
    /// accept on your own staging box, while a failure the system reports for
    /// other reasons is not something a button should paper over.
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
