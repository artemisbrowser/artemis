// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import SwiftUI

struct AboutSettings: View {
    @Environment(TabManager.self) private var tabManager
    @AppStorage(Updates.channelKey) private var updateChannel = "release"
    @AppStorage(Reports.enabledKey) private var sendsErrorReports = false
    @AppStorage(AppIconChoice.storageKey) private var iconRaw = AppIconChoice.bundled.rawValue
    @AppStorage(WhatsNew.enabledKey) private var showsWhatsNew = true

    static var version: String {
        "Version \(Updates.running) (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"))"
    }

    private func link(_ title: String, _ detail: String, _ address: String, id: SettingID) -> some View {
        LabeledContent {
            Button {
                guard let url = URL(string: address) else { return }
                tabManager.revealTab(tabManager.newTab(url: url))
            } label: {
                Image(systemName: "arrow.up.right")
            }
            .accessibilityLabel("Open \(title)")
        } label: {
            Text(title)
            Text(detail)
        }
        .settingsAnchor(id)
    }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 4) {
                    let icon = AppIconChoice(rawValue: iconRaw) ?? .bundled
                    Image(nsImage: icon.image(dark: AppIconChoice.iconsAreDark) ?? NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 84, height: 84)
                    Text("Artemis").font(.title2.weight(.semibold))
                    Text(Self.version).font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }

            if Updates.shared.isEnabled {
                Section("Updates") {
                    Picker(selection: Binding(
                        get: { updateChannel },
                        set: { updateChannel = $0; Updates.shared.channelChanged() }
                    ).undoable("Update Channel")) {
                        Text("Release").tag("release")
                        Text("Beta").tag("beta")
                        Text("Nightly").tag("nightly")
                    } label: {
                        InfoLabel(
                            "Channel",
                            info: "Beta gets new features first and Nightly gets every change as it lands. Both may have bugs, and leaving takes effect at the next update.")
                    }
                    .settingsAnchor(.updateChannel)
                    Toggle("Check for updates automatically", isOn: Binding(
                        get: { Updates.shared.checksAutomatically },
                        set: { Updates.shared.checksAutomatically = $0 }
                    ).undoable("Automatic Updates"))
                    .settingsAnchor(.autoUpdate)
                    Toggle(isOn: Binding(
                        get: { Updates.shared.installsAutomatically },
                        set: { Updates.shared.installsAutomatically = $0 }
                    ).undoable("Automatic Installs")) {
                        InfoLabel(
                            "Install updates automatically",
                            info: "Downloads an update in the background and installs it when you quit. When off, Artemis tells you and waits for you to press Download.")
                    }
                    .disabled(!Updates.shared.checksAutomatically)
                    .settingsAnchor(.autoInstall)
                    let flow = Updates.shared.flow
                    LabeledContent {
                        Button(flow.offer?.title ?? "Check Now") { Updates.shared.act() }
                            .disabled(flow.isBusy)
                    } label: {
                        Text("Artemis \(Updates.running)")
                        if case .failed(let why) = flow { Text(why) } else if let title = flow.title { Text(title) }
                    }
                    .settingsAnchor(.checkForUpdates)
                }
            }

            Section {
                LabeledContent {
                    Button("Show") {
                        Onboarding.replay.target = tabManager
                        BrowserWindows.shared.window(of: tabManager)?.makeKeyAndOrderFront(nil)
                    }
                } label: {
                    InfoLabel("Show onboarding", info: "Plays the intro and the setup cards again.")
                }
                .settingsAnchor(.showOnboarding)
                if WhatsNew.note != nil {
                    LabeledContent("What's new in Artemis \(Updates.running)") {
                        Button("Show") {
                            WhatsNew.replay.target = tabManager
                            BrowserWindows.shared.window(of: tabManager)?.makeKeyAndOrderFront(nil)
                        }
                    }
                    .settingsAnchor(.whatsNew)
                }
                Toggle(isOn: $showsWhatsNew.undoable("What's New")) {
                    InfoLabel(
                        "Show what's new after an update",
                        info: "Plays a short look at what changed the first time an update opens.")
                }
                .settingsAnchor(.showWhatsNew)
                link("Changelog", "Every release and what changed in it.", WhatsNew.changelog, id: .changelog)
            }

            Section("Feedback & Community") {
                LabeledContent {
                    Button("Send Feedback…") { FeedbackDraft.open(in: tabManager) }
                } label: {
                    Text("Feedback")
                    Text("Report a bug or ask for a feature.")
                }
                .settingsAnchor(.sendFeedback)
                LabeledContent {
                    Button("Export Logs…") { Reports.exportLogs(from: tabManager) }
                } label: {
                    Text("Logs")
                    Text("Recent errors and crash reports in one file. Nothing is sent.")
                }
                .settingsAnchor(.exportLogs)
                link("Discord", "Help, ideas and news.", "https://discord.gg/Tn8CcPdt2x", id: .discord)
                link("X", "@artemisbrowser", "https://x.com/artemisbrowser", id: .socialX)
                link("Bluesky", "@artemisbrowser.app", "https://bsky.app/profile/artemisbrowser.app", id: .bluesky)
                link("Reddit", "u/artemisbrowser", "https://www.reddit.com/user/artemisbrowser", id: .reddit)
                link("Source code", "Artemis is open source.", "https://github.com/artemisbrowser/artemis", id: .sourceCode)
            }

            Section("Privacy") {
                LabeledContent {
                    Text("Stored on this Mac")
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([AppStorageLocation.directory])
                    }
                } label: {
                    InfoLabel("Browsing data", info: "Your browsing data is stored as plain JSON files in one folder on this Mac.")
                }
                .settingsAnchor(.dataFolder)
                LabeledContent("Usage analytics", value: "None")
                    .settingsAnchor(.usageAnalytics)
                LabeledContent {
                    Text(sendsErrorReports ? "On" : "Off")
                    Button("Change…") { SettingsSpotlight.shared.reveal(.errorReports) }
                } label: {
                    InfoLabel("Error reports", info: Reports.disclosure)
                }
                .settingsAnchor(.errorReportsState)
            }

            Section("Backup") {
                LabeledContent {
                    Button("Export Backup…") { BackupIO.export(from: tabManager) }
                } label: {
                    Text("Export")
                    Text("Spaces, tabs, favourites and settings in one file.")
                }
                .settingsAnchor(.exportBackup)
                LabeledContent {
                    Button("Restore from Backup…") { BackupIO.chooseAndRestore(into: tabManager) }
                } label: {
                    Text("Restore")
                    Text("Replaces your spaces and tabs with a backup's.")
                }
                .settingsAnchor(.restoreBackup)
            }

            Section("Reset") {
                LabeledContent {
                    Button("Hard Reset…", role: .destructive) { HardReset.ask() }
                } label: {
                    Text("Hard reset")
                    Text("Erases everything Artemis keeps on this Mac and reopens it as new.")
                }
                .settingsAnchor(.hardReset)
            }

            Section {
                link("Licence", "GNU General Public License 3.0", "https://github.com/artemisbrowser/artemis/blob/main/LICENSE", id: .licence)
                link(
                    "Acknowledgements", "The open source work Artemis builds on.",
                    "https://github.com/artemisbrowser/artemis/blob/main/THIRD-PARTY-NOTICES.md", id: .acknowledgements)
                link("Website", "artemisbrowser.app", "https://artemisbrowser.app", id: .website)
            } header: {
                Text("Credits")
            } footer: {
                Text("Artemis is made by Fin.")
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
            }
        }
        .formStyle(.grouped)
    }
}
