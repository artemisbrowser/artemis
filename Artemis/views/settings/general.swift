// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import AppKit
import SwiftUI
import WebKit

/// whether Artemis is the browser macOS hands links to, and the one-click way to make it so
@MainActor
enum DefaultBrowser {
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
    @AppStorage(DownloadManager.folderKey) private var downloadsFolder = ""
    @AppStorage(DownloadManager.asksEachTimeKey) private var downloadsAsk = false
    @AppStorage(TabManager.swipeNavigationKey) private var swipeNavigation = true
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
                Group {
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
                .settingsAnchor(.defaultBrowser)
            }

            Section {
                LabeledContent {
                    Button("Import…") {
                        ImportModel.open(in: tabManager)
                        BrowserWindows.shared.window(of: tabManager)?.makeKeyAndOrderFront(nil)
                    }
                } label: {
                    InfoLabel(
                        "Import from another browser",
                        info: "Brings bookmarks, history, spaces and passwords into the profile you choose.")
                }
                .settingsAnchor(.importBrowser)
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
                .settingsAnchor(.swipeNavigation)
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
                .settingsAnchor(.downloadsFolder)
                Toggle(isOn: $downloadsAsk.undoable("Download Prompt")) {
                    InfoLabel("Ask where to save each file", info: "Pick a folder and name for every download.")
                }
                .settingsAnchor(.downloadsAsk)
            }
        }
        .formStyle(.grouped)
    }
}
