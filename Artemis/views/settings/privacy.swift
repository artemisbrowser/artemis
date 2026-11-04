import SwiftUI

/// Privacy & Security: the native content blocker, incognito, fingerprinting, site
/// permissions and error reports. Clearing a profile's data lives under Profiles.
struct PrivacySettings: View {
    @Environment(TabManager.self) private var tabManager
    @AppStorage(SpaceLock.incognitoRequiresUnlockKey) private var incognitoRequiresUnlock = false

    private var blocker = ContentBlocker.shared
    private var permissions = SitePermissionStore.shared
    @AppStorage(FingerprintNoise.enabledKey) private var fingerprintDefence = true
    @AppStorage(Reports.enabledKey) private var sendsErrorReports = false
    @AppStorage(Scripting.allowsJavaScriptKey) private var allowsScriptedJavaScript = false
    @AppStorage(Scripting.showsIncognitoKey) private var showsIncognitoToScripts = true
    @AppStorage(SpotlightIndex.enabledKey) private var showsInSpotlight = SpotlightIndex.enabledByDefault

    var body: some View {
        Form {
            Section {
                Toggle("Block ads and trackers", isOn: blockingBinding)
                Text(blocker.statusLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(ContentBlocker.catalog) { list in
                    Toggle(
                        isOn: Binding(
                            get: { list.isEnabled },
                            set: { blocker.setList(list, enabled: $0) })
                    ) {
                        InfoLabel(list.name, info: list.detail)
                    }
                    .disabled(!blocker.isEnabled || blocker.isUpdating)
                }

                HStack {
                    Button("Update Blocklists") {
                        Task { await blocker.updateLists(force: true) }
                    }
                    .disabled(blocker.isUpdating || !blocker.isEnabled)
                    if blocker.isUpdating {
                        ProgressView().controlSize(.small)
                        Text("Downloading and compiling…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                InfoLabel(
                    "Content Blocking",
                    info: "A blocked request never leaves your Mac. Lists update themselves every few days.")
            }

            Section {
                Toggle(
                    isOn: Binding(
                        get: { incognitoRequiresUnlock },
                        set: { SpaceLock.shared.setIncognitoRequiresUnlock($0) })
                ) {
                    InfoLabel(
                        "Always require Touch ID for incognito windows",
                        info: "Incognito windows lock whenever Artemis isn't the active app. Your password works too.")
                }
                Button("Clear Browsing Data…") {
                    ProfilesNavigator.show(.clearData, for: tabManager.currentProfile.id)
                }
            } header: {
                InfoLabel(
                    "Incognito and Your Data",
                    info: "Nothing from an incognito window is saved. Each profile clears its own history and cookies.")
            }

            Section("Fingerprint Defence") {
                Toggle(isOn: $fingerprintDefence) {
                    InfoLabel(
                        "Randomise fingerprintable readings",
                        info: "Gives each site slightly different hardware readings, so trackers can't build a stable fingerprint. Takes effect on the next launch.")
                }
            }

            Section {
                if permissions.sorted.isEmpty {
                    Text(
                        "No site has been given the camera, the microphone, your location or notifications yet. Artemis asks the first time a site wants one, and remembers your answer here."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else {
                    ForEach(permissions.sorted) { record in
                        HStack(alignment: .firstTextBaseline) {
                            Text(record.origin.replacingOccurrences(of: "https://", with: ""))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 12)
                            ForEach(SitePermission.allCases) { permission in
                                if let decision = record.decisions[permission] {
                                    Label(
                                        permission.label,
                                        systemImage: decision == .allow
                                            ? permission.icon : "\(permission.icon).slash"
                                    )
                                    .labelStyle(.iconOnly)
                                    .foregroundStyle(decision == .allow ? .green : .secondary)
                                    .tooltip(
                                        "\(permission.label): "
                                            + (decision == .allow ? "allowed" : "blocked"))
                                }
                            }
                            Button("Forget") { permissions.forget(record.origin) }
                                .buttonStyle(.link)
                        }
                    }
                    Button("Forget All Sites", role: .destructive) {
                        permissions.forgetAll()
                        ExternalSchemes.forgetAll()
                    }
                }
            } header: {
                InfoLabel(
                    "Site Permissions",
                    info: "A site only gets what you granted to its exact origin. Answers given in incognito are never saved to disk.")
            }

            Section("Automation") {
                Toggle(isOn: $allowsScriptedJavaScript) {
                    InfoLabel(
                        "Allow JavaScript from Apple Events",
                        info: "Lets AppleScript and Shortcuts run code inside your pages. Only turn this on for scripts you trust.")
                }
                Toggle(isOn: $showsIncognitoToScripts) {
                    InfoLabel(
                        "Incognito tabs visible in AppleScript",
                        info: "When off, scripts can't see or change incognito windows' tabs.")
                }
                Toggle(isOn: $showsInSpotlight) {
                    InfoLabel(
                        "Show spaces and tabs in Spotlight",
                        info: "Spotlight can find your spaces and open tabs. Incognito and locked spaces never appear.")
                }
                .onChange(of: showsInSpotlight) { SpotlightIndex.enabledDidChange() }
            }

            Section("Reports") {
                Toggle(isOn: $sendsErrorReports) {
                    InfoLabel(
                        "Send error reports",
                        info: "Sends errors and crash reports with your Artemis and macOS versions. Never your pages or browsing.")
                }
                Button("Send Feedback…") { FeedbackDraft.open(in: tabManager) }
            }

            Section {
                Button("Show Data Folder in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([AppStorageLocation.directory])
                }
            } header: {
                InfoLabel(
                    "On-Device Data",
                    info: "Your browsing data is stored as plain JSON files on this Mac. None of it is ever uploaded.")
            }
        }
        .formStyle(.grouped)
    }

    private var blockingBinding: Binding<Bool> {
        Binding(get: { blocker.isEnabled }, set: { blocker.isEnabled = $0 })
    }
}
