// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import Foundation

/// one auto-archived tab — a Today tab that aged out and was closed for you
nonisolated struct ArchiveEntry: Codable, Identifiable {
    var id: UUID
    var url: URL
    var title: String
    var archivedAt: Date
    /// the name of the space the tab was archived from
    var spaceName: String

    init(id: UUID = UUID(), url: URL, title: String, archivedAt: Date = Date(), spaceName: String) {
        self.id = id
        self.url = url
        self.title = title
        self.archivedAt = archivedAt
        self.spaceName = spaceName
    }
}

/// the auto-archive: Today tabs that went stale, newest first, restorable from
/// the Library
@Observable
final class ArchiveStore {
    private(set) var entries: [ArchiveEntry] = []

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    private static let maxEntries = 5000

    init(fileURL: URL) {
        self.fileURL = fileURL
        entries = AppStorageLocation.loadDurable([ArchiveEntry].self, from: fileURL) ?? []
    }

    /// file a freshly-archived tab at the front
    func add(url: URL, title: String, spaceName: String) {
        entries.insert(
            ArchiveEntry(url: url, title: title, spaceName: spaceName), at: 0)
        if entries.count > Self.maxEntries {
            entries.removeLast(entries.count - Self.maxEntries)
        }
        scheduleSave()
    }

    /// fold in another browser's archive; a url already filed here is left alone
    func merge(_ incoming: [ArchiveEntry]) {
        guard !incoming.isEmpty else { return }
        let known = Set(entries.map(\.url))
        entries.append(contentsOf: incoming.filter { !known.contains($0.url) })
        entries.sort { $0.archivedAt > $1.archivedAt }
        if entries.count > Self.maxEntries { entries.removeLast(entries.count - Self.maxEntries) }
        scheduleSave()
    }

    func remove(_ entry: ArchiveEntry) {
        entries.removeAll { $0.id == entry.id }
        scheduleSave()
    }

    /// drop the entries that match
    func forget(where shouldForget: (ArchiveEntry) -> Bool) {
        let before = entries.count
        entries.removeAll(where: shouldForget)
        guard entries.count != before else { return }
        scheduleSave()
    }

    /// write now: a save still waiting on its debounce dies with the process
    func saveNow() {
        saveTask?.cancel()
        guard let data = try? JSONEncoder().encode(entries) else { return }
        AppStorageLocation.writeDurableNow(data, to: fileURL)
    }

    /// drop everything archived since `date` (Clear Browsing Data's time range)
    func clear(since date: Date) {
        let before = entries.count
        entries.removeAll { $0.archivedAt >= date }
        guard entries.count != before else { return }
        scheduleSave()
    }

    /// matches for a query — title or url substring, recency order
    func search(_ query: String) -> [ArchiveEntry] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return entries }
        return entries.filter {
            $0.title.lowercased().contains(q)
                || $0.url.absoluteString.lowercased().contains(q)
        }
    }

    // MARK: - Persistence

    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = entries
        let takenAt = AppStorageLocation.snapshotTime()
        let url = fileURL
        saveTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            // thousands of entries: encode off the main actor too
            await Task.detached(priority: .utility) {
                if let data = try? JSONEncoder().encode(snapshot) {
                    AppStorageLocation.writeDurable(data, to: url, takenAt: takenAt)
                }
            }.value
        }
    }
}
