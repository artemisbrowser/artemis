// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import SwiftUI

/// over a local web archive: where it was saved from, and the way to the live page
struct SavedCopyLabel: View {
    let tab: BrowserTab
    var body: some View {
        if let reader = tab.reader, tab.loadError == nil {
            HStack(spacing: 8) {
                Image(systemName: "archivebox")
                Text(reader.saved.map { "Saved copy of \($0.absoluteString)" } ?? "Saved copy of a local page")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("saved-copy-label")
                if let live = reader.saved {
                    Button("Open Live Page") { tab.onOpenLink?(live, .foregroundTab) }
                        .buttonStyle(.borderless)
                        .tooltip("Open \(live.host() ?? "the page") in a new tab")
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .glassEffect(.regular.tint(.black.opacity(0.45)), in: .capsule)
            // over any page, light or dark: a dark capsule with light text
            .environment(\.colorScheme, .dark)
            .frame(maxWidth: 560)
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
    }
}
