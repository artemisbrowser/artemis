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
        if let icon = customIcon() {
            let view = NSImageView(frame: NSRect(origin: .zero, size: tile.size))
            view.image = icon
            view.imageScaling = .scaleProportionallyUpOrDown
            tile.contentView = view
        } else {
            tile.contentView = nil
        }
        tile.display()
    }

    /// the icns `NSWorkspace.setIcon` wrote into the bundle's `Icon\r` resource fork. read directly:
    /// in the Dock, IconServices hands back its blank placeholder and never redraws the tile
    private func customIcon() -> NSImage? {
        let file = appPath + "/Icon\r"
        let size = getxattr(file, XATTR_RESOURCEFORK_NAME, nil, 0, 0, 0)
        guard size > 8 else { return nil }
        var fork = [UInt8](repeating: 0, count: size)
        guard getxattr(file, XATTR_RESOURCEFORK_NAME, &fork, size, 0, 0) == size else { return nil }
        // big-endian: the fork's data starts at word 0, and its one resource is a length then the icns
        func word(_ at: Int) -> Int { fork[at..<at + 4].reduce(0) { $0 << 8 | Int($1) } }
        let start = word(0) + 4
        guard start <= size, start + word(start - 4) <= size else { return nil }
        return NSImage(data: Data(fork[start..<start + word(start - 4)]))
    }
}
