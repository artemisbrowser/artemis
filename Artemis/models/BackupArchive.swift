import AppKit
import UniformTypeIdentifiers

extension BackupArchive {
    /// keys carried across a backup. an explicit list, not "everything in
    /// UserDefaults": restoring window frames, one-off UI flags or extension
    /// grants from another machine causes more confusion than it saves
    static let preferenceKeys: [String] = [
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

/// Save/open panels and the apply step for backups.
@MainActor
enum BackupIO {
    static let fileExtension = "artemisbackup"

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
        guard let data = try? encoder.encode(archive) else { return }
        try? data.write(to: url, options: .atomic)
        debugLog("backup: exported \(archive.session.spaces.count) spaces to \(url.lastPathComponent)")
    }

    /// read a backup file the user picks; nil if it isn't one
    static func chooseArchive() -> BackupArchive? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.json, .data]
        panel.message = "Choose an Artemis backup file."
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].resolvingSymlinksInPath()
        guard panel.runModal() == .OK, let url = panel.url,
            let data = try? Data(contentsOf: url)
        else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(BackupArchive.self, from: data)
    }

    /// apply a backup. spaces are *replaced*, not merged — merging two sets of
    /// spaces produces a mess nobody wants; Boosts merge, since that's a shelf
    /// where more is fine
    static func restore(
        _ archive: BackupArchive, options: RestoreOptions, into manager: TabManager
    ) {
        if options.preferences {
            for (key, value) in archive.preferences where BackupArchive.preferenceKeys.contains(key) {
                UserDefaults.standard.set(value.raw, forKey: key)
            }
        }
        if options.boosts {
            BoostStore.shared.merge(archive.boosts)
        }
        for (host, zoom) in archive.zoomLevels {
            ZoomStore.shared.setZoom(zoom, for: URL(string: "https://\(host)/"))
        }
        if options.spaces {
            // the session file is the source of truth on launch, so write it and
            // restore from it — one code path, no second deserializer to keep in
            // step with `makeSpace(from:)`
            SessionStore.save(archive.session)
            manager.reloadFromDisk()
        }
        debugLog("backup: restored \(archive.session.spaces.count) spaces")
    }
}
