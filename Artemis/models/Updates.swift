import Sparkle
import SwiftUI

/// Sparkle, for builds that carry a feed (the tester releases); a build without
/// one never updates itself. Scheduled updates download quietly and wait in the
/// sidebar's Relaunch to Update pill: nothing opens over browsing on its own.
@Observable
final class Updates: NSObject {
    static let shared = Updates()
    /// "beta" adds the beta channel; anything else is release only
    static let channelKey = "updateChannel"

    /// the version waiting to install, once Sparkle has it downloaded
    private(set) var readyVersion: String?
    /// a scheduled check found a version Sparkle couldn't fetch quietly
    private(set) var availableVersion: String?
    @ObservationIgnored private var install: (() -> Void)?
    @ObservationIgnored private var controller: SPUStandardUpdaterController?

    /// fixed by the build, so the menu knows before the updater starts
    let isEnabled = !((Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String) ?? "").isEmpty
    private var updater: SPUUpdater? { controller?.updater }

    var checksAutomatically: Bool {
        get { updater?.automaticallyChecksForUpdates ?? false }
        set { updater?.automaticallyChecksForUpdates = newValue }
    }

    func start() {
        // `-previewUpdatePill YES` at launch: the pill with nothing behind it, to see how it looks
        if UserDefaults.standard.bool(forKey: "previewUpdatePill") { readyVersion = "0.9.3" }
        guard isEnabled else { return }
        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
    }

    func checkNow() { controller?.checkForUpdates(nil) }

    /// installs the downloaded version and relaunches into it; otherwise asks Sparkle to show what's on offer
    func act() {
        if let install { install() } else { checkNow() }
    }

    /// a background check, so leaving or joining Beta doesn't wait for the next schedule
    func channelChanged() {
        guard let updater, !updater.sessionInProgress else { return }
        updater.checkForUpdatesInBackground()
    }
}

extension Updates: @preconcurrency SPUUpdaterDelegate {
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        UserDefaults.standard.string(forKey: Self.channelKey) == "beta" ? ["beta"] : []
    }

    func updater(
        _ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock: @escaping () -> Void
    ) -> Bool {
        install = immediateInstallationBlock
        readyVersion = item.displayVersionString
        debugLog("update ready: \(item.displayVersionString) (\(item.versionString))")
        availableVersion = nil
        return true
    }
}

extension Updates: @preconcurrency SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool { false }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        if !handleShowingUpdate, readyVersion == nil { availableVersion = update.displayVersionString }
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        availableVersion = nil
    }
}

/// the sidebar footer's offer to finish an update; Updates.act does the rest
struct UpdatePill: View {
    @Environment(\.chromeInk) private var ink
    private var updates: Updates { .shared }

    var body: some View {
        if updates.readyVersion != nil || updates.availableVersion != nil {
            Button { updates.act() } label: {
                Label(
                    updates.readyVersion != nil ? "Relaunch to Update" : "Update Available",
                    systemImage: "arrow.down.circle")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(ink.opacity(0.9))
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, minHeight: 28)
                    .chromeGlass(in: .capsule, interactive: true)
                    .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .tooltip("Artemis \(updates.readyVersion ?? updates.availableVersion ?? "")")
            .transition(.opacity.combined(with: .scale(scale: 0.95)))
        }
    }
}
