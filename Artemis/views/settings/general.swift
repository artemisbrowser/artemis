import AppKit
import SwiftUI

/// Whether Artemis is the browser macOS hands links to, and the one-click way to make it so.
@MainActor
enum DefaultBrowser {
    static var isArtemis: Bool {
        guard let handler = NSWorkspace.shared.urlForApplication(
            toOpen: URL(string: "https://example.com")!)
        else { return false }
        return handler == Bundle.main.bundleURL
    }

    static var currentName: String? {
        guard let handler = NSWorkspace.shared.urlForApplication(
            toOpen: URL(string: "https://example.com")!)
        else { return nil }
        return FileManager.default.displayName(atPath: handler.path)
            .replacingOccurrences(of: ".app", with: "")
    }

    /// macOS asks the user to confirm before it changes the browser
    static func makeArtemis() async {
        try? await NSWorkspace.shared.setDefaultApplication(
            at: Bundle.main.bundleURL, toOpenURLsWithScheme: "http")
    }
}

struct GeneralSettings: View {
    @AppStorage(TabManager.autoPictureInPictureKey) private var autoPictureInPicture = false
    @AppStorage(TabManager.hibernateAfterMinutesKey) private var hibernateAfterMinutes =
        TabManager.defaultHibernateAfterMinutes
    @AppStorage(MiniPlayer.cornerRadiusKey) private var pipCornerRadius = MiniPlayer.defaultCornerRadius
    @AppStorage(MiniPlayer.skipSecondsKey) private var pipSkipSeconds = MiniPlayer.defaultSkipSeconds
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
                }

                HStack {
                    InfoLabel("Skip buttons jump", info: "How far the skip buttons either side of play jump.")
                    Spacer()
                    TextField("", value: $pipSkipSeconds, format: .number)
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

/// the per-site checklist of page buttons the mini-player may proxy as pills.
/// catalog fills itself while the mini-player is used; toggles apply live (the
/// player re-reads the allowlist every poll tick).
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
        // the mini-player catalogs buttons while Settings sits open — refresh
        // live so new finds appear without closing/reopening the window
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
