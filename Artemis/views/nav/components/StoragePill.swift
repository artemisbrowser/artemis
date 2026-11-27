// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import SwiftUI

/// whether saves are failing now; `AppStorageLocation` sets it and keeps retrying by itself
@Observable
final class StorageNotice {
    static let shared = StorageNotice()
    var failure: AppStorageLocation.SaveFailure?
}

/// the sidebar footer's word that saves are failing, up from the first failed save until every one has landed
struct StoragePill: View {
    @Environment(\.chromeInk) private var ink

    var body: some View {
        if let failure = StorageNotice.shared.failure {
            let isDiskFull = failure == .diskFull
            Button {
                if isDiskFull {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.settings.Storage")!)
                } else {
                    AppStorageLocation.enqueueDurable { AppStorageLocation.retryUnsaved() }
                }
            } label: {
                Label(isDiskFull ? "Disk Full" : "Can’t Save Changes", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(ink.opacity(0.9))
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, minHeight: 28)
                    .chromeGlass(in: .capsule, interactive: true)
                    .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .tooltip(
                isDiskFull
                    ? "Changes aren’t being saved. Click to open Storage settings."
                    : "Changes aren’t being saved. Click to try again."
            )
            .transition(Motion.grow(from: 0.95))
            // space is freed in another app
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                AppStorageLocation.enqueueDurable { AppStorageLocation.retryUnsaved() }
            }
        }
    }
}
