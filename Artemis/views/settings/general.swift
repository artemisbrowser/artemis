// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import AppKit
import SwiftUI

/// whether Artemis is the browser macOS hands links to, and the one-click way to make it so
@MainActor
private enum DefaultBrowser {
    private static var handler: URL? {
        NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!)
    }

    static var isArtemis: Bool { handler == Bundle.main.bundleURL }

    static var currentName: String? {
        handler.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
    }

    /// macOS asks the user to confirm before it changes the browser
    static func makeArtemis() async {
        try? await NSWorkspace.shared.setDefaultApplication(
            at: Bundle.main.bundleURL, toOpenURLsWithScheme: "http")
    }
}

struct GeneralSettings: View {
    @Environment(TabManager.self) private var tabManager
    @AppStorage(TabManager.autoPictureInPictureKey) private var autoPictureInPicture = false
    @AppStorage(TabManager.hibernateAfterMinutesKey) private var hibernateAfterMinutes =
        TabManager.defaultHibernateAfterMinutes
    @AppStorage(MiniPlayer.cornerRadiusKey) private var pipCornerRadius = MiniPlayer.defaultCornerRadius
    @AppStorage(MiniPlayer.skipSecondsKey) private var pipSkipSeconds = MiniPlayer.defaultSkipSeconds
    @AppStorage(Updates.channelKey) private var updateChannel = "release"
    private static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    /// bumped after the default-browser prompt, so the section reads the new answer
    @State private var defaultBrowserCheck = 0

    private var currentBrowserLine: String {
        guard let name = DefaultBrowser.currentName else {
            return "Links from other apps don't open in Artemis."
        }
        return "Links from other apps open in \(name)."
    }

    var body: some View {
        Form {
            Section("Default Browser") {
                let _ = defaultBrowserCheck
                if DefaultBrowser.isArtemis {
                    Label("Artemis opens links from other apps.", systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(currentBrowserLine)
                        Button("Make Artemis Your Default Browser") {
                            Task {
                                await DefaultBrowser.makeArtemis()
                                defaultBrowserCheck += 1
                            }
                        }
                    }
                }
            }

            Section {
                LabeledContent {
                    Button("Import…") {
                        BrowserImportModel.open(in: tabManager)
                        BrowserWindows.shared.window(of: tabManager)?.makeKeyAndOrderFront(nil)
                    }
                } label: {
                    InfoLabel(
                        "Import from another browser",
                        info: "Brings bookmarks, history, spaces and passwords into the profile you choose.")
                }
            }

            if Updates.shared.isEnabled {
                Section("Updates") {
                    Picker(selection: $updateChannel) {
                        Text("Release").tag("release")
                        Text("Beta").tag("beta")
                    } label: {
                        InfoLabel(
                            "Channel",
                            info: "Beta gets new features first and may have bugs. Leaving Beta takes effect at the next release.")
                    }
                    .onChange(of: updateChannel) { Updates.shared.channelChanged() }
                    Toggle("Check for updates automatically", isOn: Binding(
                        get: { Updates.shared.checksAutomatically },
                        set: { Updates.shared.checksAutomatically = $0 }))
                    LabeledContent("Artemis \(Self.version)") {
                        Button("Check Now") { Updates.shared.checkNow() }
                    }
                }
            }

            Section("Memory") {
                Picker(selection: $hibernateAfterMinutes) {
                    ForEach([0.0, 5, 15, 30, 60, 180], id: \.self) { minutes in
                        Text(sleepLabel(for: minutes)).tag(minutes)
                    }
                } label: {
                    InfoLabel(
                        "Sleep background tabs after",
                        info: "A sleeping tab frees its memory and comes back as you left it. Tabs on screen or playing media never sleep.")
                }
            }

            Section("Picture in Picture") {
                Toggle(isOn: $autoPictureInPicture) {
                    InfoLabel(
                        "Auto-enter when switching away",
                        info: "A playing video moves to a mini-player when you switch away and returns when you come back. ⌘⇧P toggles it any time.")
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        InfoLabel(
                            "Corner rounding",
                            info: "How rounded the mini-player's corners are, from 0 for square up to 28.")
                        Spacer()
                        Text("\(Int(pipCornerRadius)) pt")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $pipCornerRadius, in: 0...28, step: 1)
                        .accessibilityLabel("Corner rounding")
                }

                HStack {
                    InfoLabel("Skip buttons jump", info: "How far the skip buttons either side of play jump.")
                    Spacer()
                    TextField("", value: $pipSkipSeconds, format: .number)
                        .accessibilityLabel("Skip buttons jump")
                        .frame(width: 56)
                        .multilineTextAlignment(.trailing)
                        .textFieldStyle(.roundedBorder)
                    Text("seconds")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                PiPSiteButtonsList()
            } header: {
                InfoLabel(
                    "Mini-Player Site Buttons",
                    info: "Artemis lists the buttons a site shows while the mini-player is open. Tick one to add it to the mini-player as a pill.")
            }
        }
        .formStyle(.grouped)
    }

    private func sleepLabel(for minutes: Double) -> String {
        switch minutes {
        case 0: return "Never"
        case ..<60: return "\(Int(minutes)) minutes"
        case 60: return "1 hour"
        default: return "\(Int(minutes / 60)) hours"
        }
    }
}

/// the per-site checklist of page buttons the mini-player may proxy as pills; the
/// player re-reads the allowlist every poll tick, so toggles apply live
private struct PiPSiteButtonsList: View {
    @State private var catalog: [String: [String: Bool]] = [:]

    var body: some View {
        Group {
            if catalog.isEmpty {
                Text("Nothing yet — open the mini-player on a site and its buttons will show up here.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(catalog.keys.sorted(), id: \.self) { host in
                    DisclosureGroup {
                        ForEach((catalog[host] ?? [:]).keys.sorted(), id: \.self) { label in
                            Toggle(label, isOn: binding(host: host, label: label))
                        }
                        Button("Forget This Site", role: .destructive) {
                            PiPSiteButtons.forget(host: host)
                            catalog = PiPSiteButtons.all()
                        }
                    } label: {
                        HStack {
                            Text(host)
                            Spacer()
                            Text("\((catalog[host] ?? [:]).values.filter { $0 }.count) allowed")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        }
                    }
                }
            }
        }
        .onAppear { catalog = PiPSiteButtons.all() }
        // the mini-player catalogs buttons while Settings is open
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            let fresh = PiPSiteButtons.all()
            if fresh != catalog { catalog = fresh }
        }
    }

    private func binding(host: String, label: String) -> Binding<Bool> {
        Binding(
            get: { catalog[host]?[label] ?? false },
            set: { on in
                PiPSiteButtons.setAllowed(on, host: host, label: label)
                catalog[host]?[label] = on
            })
    }
}
