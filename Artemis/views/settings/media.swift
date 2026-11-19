// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import SwiftUI

/// the mini-player a playing video moves into, and the sidebar's playback card
struct MediaSettings: View {
    @AppStorage(TabManager.autoPictureInPictureKey) private var autoPictureInPicture = false
    @AppStorage(MiniPlayer.cornerRadiusKey) private var pipCornerRadius = MiniPlayer.defaultCornerRadius
    @AppStorage(MiniPlayer.skipSecondsKey) private var pipSkipSeconds = MiniPlayer.defaultSkipSeconds
    @AppStorage(NowPlayingCard.enabledKey) private var showsNowPlaying = true

    var body: some View {
        Form {
            Section("Mini-Player") {
                Toggle(isOn: $autoPictureInPicture.undoable("Auto Picture in Picture")) {
                    InfoLabel(
                        "Auto-enter when another app covers the window",
                        info: "A playing video moves to a mini-player when another app hides it, and returns when you come back. ⌘⇧P toggles it any time.")
                }
                .settingsAnchor(.autoPictureInPicture)

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
                .settingsAnchor(.miniPlayerCorners)

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
                .settingsAnchor(.miniPlayerSkip)
            }

            Section {
                PiPSiteButtonsList()
            } header: {
                InfoLabel(
                    "Mini-Player Site Buttons",
                    info: "Artemis lists the buttons a site shows while the mini-player is open. Tick one to add it to the mini-player as a pill.")
            }

            Section("Sidebar") {
                Toggle(isOn: $showsNowPlaying.undoable("Now Playing")) {
                    InfoLabel(
                        "Show Now Playing",
                        info: "Shows media controls above the spaces when a background tab plays audio or video.")
                }
                .settingsAnchor(.nowPlaying)
            }
        }
        .formStyle(.grouped)
    }
}

/// the per-site checklist of page buttons the mini-player may proxy as pills; the
/// player re-reads the allowlist every poll tick, so toggles apply live
private struct PiPSiteButtonsList: View {
    @State private var catalog: [String: [String: Bool]] = [:]

    var body: some View {
        Group {
            if catalog.isEmpty {
                Text("Nothing yet. Open the mini-player on a site and its buttons show up here.")
                    .foregroundStyle(.secondary)
                    .settingsAnchor(.miniPlayerSiteButtons)
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
                    .settingsAnchor(host == catalog.keys.min() ? .miniPlayerSiteButtons : nil)
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
