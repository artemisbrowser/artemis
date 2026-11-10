// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import SwiftUI

/// the on-device intelligence pane: one master switch, off by default, with every
/// feature under it disabled until it is on
struct IntelligenceSettings: View {
    @AppStorage(Intelligence.enabledKey) private var isEnabled = false
    @AppStorage(Intelligence.tidyTitlesKey) private var tidyTitles = true
    @AppStorage(Intelligence.askPageKey) private var askPage = true

    /// a copy the pane can observe: `Intelligence.readiness` is a plain cache
    @State private var readiness = Intelligence.readiness
    private var isReady: Bool { readiness == .ready }

    var body: some View {
        Form {
            Section {
                Toggle("Use the on-device model", isOn: Binding(
                    get: { isEnabled },
                    set: { on in
                        isEnabled = on
                        guard !on else { return }
                        // switching off puts every generated name back to the
                        // page's own; names you typed yourself are untouched
                        TabNameStore.shared.clearAllGenerated()
                        Task { await Intelligence.shared.reset() }
                    }
                ).undoable("On-Device Model"))
                    // only turning it on needs the model; turning it off is what restores page names
                    .disabled(!isReady && !isEnabled)
                    .settingsAnchor(.onDeviceModel)
                Label(readiness.explanation, systemImage: isReady ? "checkmark.seal" : "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(isReady ? Color.secondary : Color.orange)
                if !isReady {
                    Button("Open Apple Intelligence Settings") {
                        if let url = URL(
                            string: "x-apple.systempreferences:com.apple.Siri-Settings.extension")
                        {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            } header: {
                InfoLabel(
                    "On-Device Intelligence",
                    info: "Runs on Apple's on-device model built into macOS. Nothing you read or ask leaves this Mac."
                )
            }

            Section("Features") {
                Toggle(isOn: $tidyTitles.undoable("Tidy Tab Names")) {
                    InfoLabel(
                        "Tidy tab names",
                        info: "Gives pinned tabs and favourites short names. Tabs you named yourself are never changed."
                    )
                }
                .settingsAnchor(.tidyTabNames)
                Toggle(isOn: $askPage.undoable("Ask About This Page")) {
                    InfoLabel(
                        "Ask about this page (⌘F)",
                        info: "Adds a question mode to Find that answers only from the current page."
                    )
                }
                .settingsAnchor(.askAboutPage)
            }
            .disabled(!isEnabled || !isReady)

            Section("What this will never do") {
                Text(
                    "Artemis will not browse for you. No filling in forms, no clicking things, no acting on your behalf while you watch. A web page can say anything, including instructions aimed at a model reading it, and a browser that lets a page's text drive real actions with your logged-in sessions has a security hole rather than a feature. Everything here reads; nothing here acts."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refreshReadiness)
        // coming back from System Settings, where Apple Intelligence is switched on
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshReadiness()
        }
    }

    private func refreshReadiness() {
        Intelligence.refreshReadiness()
        readiness = Intelligence.readiness
    }
}
