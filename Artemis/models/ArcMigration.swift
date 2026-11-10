// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import AppKit

/// File ▸ Import from Arc…: the import sheet opened on Arc
@MainActor
enum ArcMigration {
    static func run(into manager: TabManager) {
        guard manager.importer == nil, let root = locate() else { return }
        Task {
            let arc = await Task.detached { ArcImport.read(root: root) }.value
            guard let arc, arc.profiles.contains(where: { profile in
                ImportCategory.allCases.contains { ImportModel.has(profile, $0) }
            }) else {
                let alert = NSAlert()
                alert.messageText = "Artemis couldn't read Arc's data."
                alert.informativeText = "It looks for StorableSidebar.json in ~/Library/Application Support/Arc."
                alert.runModal()
                return
            }
            ImportModel.open(in: manager, adding: arc)
        }
    }

    /// Arc's own folder, else the one the person picks
    private static func locate() -> URL? {
        if ArcImport.isReadable() { return ArcImport.dataDirectory }
        let panel = NSOpenPanel()
        panel.message = "Choose Arc's data folder (Application Support ▸ Arc)."
        panel.directoryURL = ArcImport.dataDirectory
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        guard panel.runModal() == .OK, let picked = panel.urls.first else { return nil }
        return picked.hasDirectoryPath ? picked : picked.deletingLastPathComponent()
    }
}
