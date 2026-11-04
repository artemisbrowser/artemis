import AppKit
import UniformTypeIdentifiers

extension BackupArchive {
    /// the settings a backup carries; window frames, one-off UI flags and
    /// extension grants stay with the machine
    fileprivate static let preferenceKeys: [String] = [
        TabManager.autoArchiveHoursKey,
        TabManager.autoPictureInPictureKey,
        TabManager.hibernateAfterMinutesKey,
        SearchEngine.storageKey,
        SplitOrientation.defaultKey,
        PinnedSeparationKeep.storageKey,
        PinnedSeparationDestination.storageKey,
        PeekControlsCorner.storageKey,
        MiniPlayer.cornerRadiusKey,
        MiniPlayer.skipSecondsKey,
        "contentBlockingEnabledV1",
        "sidebarWidth",
        "sidebarRevealDelay",
        "sidebarHoverAreaWidth",
        "sidebarRevealDuration",
        "spaceTransitionDuration",
        "dimInactivePanes",
        "autoResizeSplitOnDrag",
        "defaultSplitLinked",
        "showSplitDropGuides",
    ]

    @MainActor
    static func make(from manager: TabManager) -> BackupArchive {
        var preferences: [String: BackupValue] = [:]
        for key in preferenceKeys {
            if let value = UserDefaults.standard.object(forKey: key),
                let wrapped = BackupValue(value) {
                preferences[key] = wrapped
            }
        }
        return BackupArchive(
            session: manager.sessionSnapshot(),
            boosts: BoostStore.shared.boosts,
            zoomLevels: ZoomStore.shared.levels,
            preferences: preferences)
    }
}

/// save/open panels and the apply step for backups
@MainActor
enum BackupIO {
    private static let fileExtension = "artemisbackup"

    /// what a restore is allowed to touch
    struct RestoreOptions {
        var spaces = true
        var boosts = true
        var preferences = true
    }

    static func export(from manager: TabManager) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Artemis \(Date().formatted(date: .numeric, time: .omitted)).\(fileExtension)"
        panel.allowedContentTypes = [.json]
        panel.allowsOtherFileTypes = true
        panel.message = "Everything: spaces, tabs, favourites, Boosts and settings."
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let archive = BackupArchive.make(from: manager)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            try encoder.encode(archive).write(to: url, options: .atomic)
            debugLog("backup: exported \(archive.session.spaces.count) spaces to \(url.lastPathComponent)")
        } catch {
            alert("The backup couldn't be saved.", error)
        }
    }

    /// read a backup file the user picks; nil if they cancel or it can't be read, which they're told
    static func chooseArchive() -> BackupArchive? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.json, .data]
        panel.message = "Choose an Artemis backup file."
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].resolvingSymlinksInPath()
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(BackupArchive.self, from: Data(contentsOf: url))
        } catch is DecodingError {
            alert("\(url.lastPathComponent) isn't an Artemis backup.", nil)
        } catch {
            alert("\(url.lastPathComponent) couldn't be read.", error)
        }
        return nil
    }

    private static func alert(_ message: String, _ error: Error?) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = error?.localizedDescription ?? ""
        alert.alertStyle = .warning
        alert.runModal()
    }

    /// apply a backup: spaces are replaced, Boosts merged
    static func restore(
        _ archive: BackupArchive, options: RestoreOptions, into manager: TabManager
    ) {
        if options.preferences {
            for (key, value) in archive.preferences where BackupArchive.preferenceKeys.contains(key) {
                UserDefaults.standard.set(value.raw, forKey: key)
            }
            for (host, zoom) in archive.zoomLevels {
                ZoomStore.shared.setZoom(zoom, for: URL(string: "https://\(host)/"))
            }
        }
        if options.boosts {
            BoostStore.shared.merge(archive.boosts)
        }
        if options.spaces {
            // restored through the session file, the same path as a launch
            SessionStore.save(archive.session)
            manager.reloadFromDisk()
        }
        debugLog("backup: restored \(archive.session.spaces.count) spaces")
    }
}
