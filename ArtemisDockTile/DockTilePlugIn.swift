// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import AppKit

/// runs inside the Dock and draws Artemis's tile while the app is quit: the
/// bundle's custom icon when one is set, the Dock's own drawing otherwise
@objc(ArtemisDockTilePlugIn)
final class ArtemisDockTilePlugIn: NSObject, NSDockTilePlugIn {
    private var tile: NSDockTile?
    private var observer: NSObjectProtocol?

    /// Artemis.app, from Contents/PlugIns/ArtemisDockTile.docktileplugin
    private let appPath = Bundle(for: ArtemisDockTilePlugIn.self).bundleURL
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path

    func setDockTile(_ dockTile: NSDockTile?) {
        tile = dockTile
        if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
        observer = nil
        guard dockTile != nil else { return }
        // must match AppIconChoice.changedNotification
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("dev.findles.Artemis.appIconChanged"), object: appPath, queue: .main
        ) { [weak self] _ in self?.redraw() }
        redraw()
    }

    private func redraw() {
        guard let tile else { return }
        if FileManager.default.fileExists(atPath: appPath + "/Icon\r") {
            let view = NSImageView(frame: NSRect(origin: .zero, size: tile.size))
            view.image = NSWorkspace.shared.icon(forFile: appPath)
            view.imageScaling = .scaleProportionallyUpOrDown
            tile.contentView = view
        } else {
            tile.contentView = nil
        }
        tile.display()
    }
}
