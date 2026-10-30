import SwiftUI

/// shown in the web card when a load fails
struct ErrorPage: View {
    let tab: BrowserTab
    /// the card's ink, not the system's: this is drawn on the space's own card
    /// base, so following the system appearance put near-black text on a dark
    /// card whenever macOS was in Light mode
    @Environment(\.chromeInk) private var ink

    private static let certificateWarning =
        "Artemis couldn't verify this server's identity. Continue only if you know who runs it — "
        + "someone could be impersonating the site."

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 40))
                .foregroundStyle(ink.opacity(0.6))

            Text("Couldn't load page")
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundStyle(ink)

            if let attempted = tab.lastAttemptedURL {
                Text(attempted.absoluteString)
                    .font(.callout)
                    .foregroundStyle(ink.opacity(0.6))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 420)
            }

            if let error = tab.loadError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(ink.opacity(0.4))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }

            HStack(spacing: 10) {
                Button("Try Again") {
                    tab.retry()
                }
                .controlSize(.large)
                .tooltip("Reload this page")

                // a certificate the system refuses is the one failure worth
                // offering a way past — see the host's own certificate, then
                // decide. Accepting is scoped to that one certificate
                if tab.canOverrideCertificate {
                    Button("Show Certificate") {
                        let host = tab.lastAttemptedURL?.host() ?? ""
                        CertificateTrust.showViewer(trust: CertificateTrust.trust(for: host))
                    }
                    .controlSize(.large)
                    .tooltip("Look at what this server presented")

                    Button("Continue Anyway") {
                        tab.acceptCertificateAndRetry()
                    }
                    .controlSize(.large)
                    .tooltip("Trust this certificate for this site")
                }
            }
            .padding(.top, 6)

            if tab.canOverrideCertificate {
                Text(Self.certificateWarning)
                    .font(.caption)
                    .foregroundStyle(ink.opacity(0.4))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
