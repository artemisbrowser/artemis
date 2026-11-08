// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import SwiftUI

/// shown in the web card when a load fails
struct ErrorPage: View {
    let tab: BrowserTab
    /// the card's ink, not the system's: this is drawn on the space's card base
    @Environment(\.chromeInk) private var ink

    private static let certificateWarning =
        "Artemis couldn't verify this server's identity. Continue only if you know who runs it, "
        + "since someone could be pretending to be this site."
    private static let secureConnectionRequired =
        "This site requires a secure connection, so you can't continue past this error. "
        + "Try again later or on another network."

    var body: some View {
        let crashed = tab.loadError == BrowserTab.crashLoopError
        VStack(spacing: 12) {
            Image(systemName: crashed ? "exclamationmark.triangle" : "wifi.exclamationmark")
                .font(.system(size: 40))
                .foregroundStyle(ink.opacity(0.6))

            Text(crashed ? "This page keeps crashing" : "Couldn't load page")
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
                Button(crashed ? "Reload" : "Try Again") {
                    tab.retry()
                }
                .controlSize(.large)
                .tooltip("Reload this page")

                if tab.certificateFailure != nil {
                    Button("Show Certificate") {
                        let host = tab.lastAttemptedURL?.host() ?? ""
                        CertificateTrust.showViewer(trust: tab.serverTrusts[host])
                    }
                    .controlSize(.large)
                    .tooltip("Look at what this server presented")
                }

                // the only failure with a way past; accepting trusts that one certificate
                if tab.certificateFailure == .overridable {
                    Button("Continue Anyway") {
                        tab.acceptCertificateAndRetry()
                    }
                    .controlSize(.large)
                    .tooltip("Trust this certificate for this site")
                }
            }
            .padding(.top, 6)

            if let failure = tab.certificateFailure {
                Text(failure == .final ? Self.secureConnectionRequired : Self.certificateWarning)
                    .font(.caption)
                    .foregroundStyle(ink.opacity(0.4))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
