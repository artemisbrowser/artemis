// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import AppKit
import SwiftUI
import WebKit

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
    @AppStorage(DownloadManager.folderKey) private var downloadsFolder = ""
    @AppStorage(DownloadManager.asksEachTimeKey) private var downloadsAsk = false
    @AppStorage(TabManager.swipeNavigationKey) private var swipeNavigation = true
    private static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    /// bumped after the default-browser prompt, so the section reads the new answer
    @State private var defaultBrowserCheck = 0

    private func chooseDownloadsFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = DownloadManager.folder
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        $downloadsFolder.undoable("Download Folder").wrappedValue = url.path
    }

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
                    Picker(selection: Binding(
                        get: { updateChannel },
                        set: { updateChannel = $0; Updates.shared.channelChanged() }
                    ).undoable("Update Channel")) {
                        Text("Release").tag("release")
                        Text("Beta").tag("beta")
                    } label: {
                        InfoLabel(
                            "Channel",
                            info: "Beta gets new features first and may have bugs. Leaving Beta takes effect at the next release.")
                    }
                    Toggle("Check for updates automatically", isOn: Binding(
                        get: { Updates.shared.checksAutomatically },
                        set: { Updates.shared.checksAutomatically = $0 }
                    ).undoable("Automatic Updates"))
                    LabeledContent("Artemis \(Self.version)") {
                        Button("Check Now") { Updates.shared.checkNow() }
                    }
                }
            }

            Section("Navigation") {
                Toggle(isOn: Binding(
                    get: { swipeNavigation },
                    set: { on in
                        swipeNavigation = on
                        for manager in BrowserWindows.shared.allManagers {
                            for tab in manager.allTabs { tab.webView.allowsBackForwardNavigationGestures = on }
                        }
                    }
                ).undoable("Swipe Navigation")) {
                    InfoLabel("Swipe between pages", info: "Swipe left or right with two fingers to go back or forward.")
                }
            }

            Section("Downloads") {
                LabeledContent {
                    HStack {
                        Text(downloadsFolder.isEmpty ? "Downloads" : DownloadManager.folder.lastPathComponent)
                            .foregroundStyle(.secondary)
                        Button("Choose…") { chooseDownloadsFolder() }
                    }
                } label: {
                    InfoLabel("Save downloads to", info: "Where files you download go.")
                }
                Toggle(isOn: $downloadsAsk.undoable("Download Prompt")) {
                    InfoLabel("Ask where to save each file", info: "Pick a folder and name for every download.")
                }
            }

            Section("Memory") {
                Picker(selection: $hibernateAfterMinutes.undoable("Tab Sleep")) {
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
                Toggle(isOn: $autoPictureInPicture.undoable("Auto Picture in Picture")) {
                    InfoLabel(
                        "Auto-enter when another app covers the window",
                        info: "A playing video moves to a mini-player when another app hides it, and returns when you come back. ⌘⇧P toggles it any time.")
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
                    Slider(value: $pipCornerRadius.undoable("Mini-Player Corners"), in: 0...28, step: 1)
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
            }
        ).undoable("Mini-Player Buttons")
    }
}
