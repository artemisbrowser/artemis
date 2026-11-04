// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import Foundation

/// one file per tab holding its `WKWebView.interactionState`: scroll position,
/// form contents and the back/forward list. a missing blob only costs the tab
/// its history, so failures return nil. never write an incognito tab here
enum TabStateStore {
    /// a larger blob is dropped rather than written; the tab restores at its url
    private static let maxBlobBytes = 512 * 1024

    private static let directory: URL = {
        let dir = AppStorageLocation.directory.appendingPathComponent("tabstate", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static func file(_ id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).state")
    }

    /// `state` is WebKit's opaque `interactionState`; anything but non-empty `Data`
    /// removes the file. `immediately` is for app termination, where a detached
    /// write dies with the process
    static func save(_ state: Any?, for id: UUID, immediately: Bool = false) {
        guard let data = state as? Data, !data.isEmpty else { return remove(id) }
        guard data.count <= maxBlobBytes else { return remove(id) }
        let url = file(id)
        guard !immediately else {
            try? data.write(to: url, options: .atomic)
            return
        }
        Task.detached(priority: .utility) {
            try? data.write(to: url, options: .atomic)
        }
    }

    static func load(_ id: UUID) -> Data? {
        try? Data(contentsOf: file(id))
    }

    static func remove(_ id: UUID) {
        try? FileManager.default.removeItem(at: file(id))
    }

    /// drop blobs for tabs that no longer exist; run at launch, since a crash
    /// between closing a tab and the next save leaves its file behind
    static func sweep(keeping ids: Set<UUID>) {
        guard
            let files = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)
        else { return }
        for url in files where url.pathExtension == "state" {
            if let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent), ids.contains(id) {
                continue
            }
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// for Clear Browsing Data: these blobs hold form contents and history
    static func removeAll() {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}
