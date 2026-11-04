import SwiftUI

/// the on-device intelligence pane: one master switch, off by default, with every
/// feature under it disabled until it is on
struct IntelligenceSettings: View {
    @AppStorage(Intelligence.enabledKey) private var isEnabled = false
    @AppStorage(Intelligence.tidyTitlesKey) private var tidyTitles = true
    @AppStorage(Intelligence.askPageKey) private var askPage = true
    @AppStorage(Intelligence.tidyDownloadsKey) private var tidyDownloads = true

    private var readiness: Intelligence.Readiness { Intelligence.readiness }

    var body: some View {
        Form {
            Section {
                Toggle("Use the on-device model", isOn: $isEnabled)
                    .disabled(!Intelligence.isReady)
                    .onChange(of: isEnabled) { _, on in
                        if !on {
                            // switching off puts every generated name back to the
                            // page's own; names you typed yourself are untouched
                            TabNameStore.shared.clearAllGenerated()
                            Task { await Intelligence.shared.reset() }
                        }
                    }
                Label(readiness.explanation, systemImage: Intelligence.isReady ? "checkmark.seal" : "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(Intelligence.isReady ? Color.secondary : Color.orange)
                if !Intelligence.isReady {
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
                Toggle(isOn: $tidyTitles) {
                    InfoLabel(
                        "Tidy tab names",
                        info: "Gives pinned tabs and favourites short names. Tabs you named yourself are never changed."
                    )
                }
                Toggle(isOn: $askPage) {
                    InfoLabel(
                        "Ask about this page (⌘F)",
                        info: "Adds a question mode to Find that answers only from the current page."
                    )
                }
                Toggle(isOn: $tidyDownloads) {
                    InfoLabel(
                        "Suggest download names",
                        info: "Suggests a better name for a download based on its page. Files are only renamed if you accept."
                    )
                }
            }
            .disabled(!isEnabled || !Intelligence.isReady)

            Section("What this will never do") {
                Text(
                    "Artemis will not browse for you. No filling in forms, no clicking things, no acting on your behalf while you watch. A web page can say anything, including instructions aimed at a model reading it, and a browser that lets a page's text drive real actions with your logged-in sessions has a security hole rather than a feature. Everything here reads; nothing here acts."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        // readiness changes when Apple Intelligence is switched on in System Settings
        .onAppear { Intelligence.refreshReadiness() }
    }
}
