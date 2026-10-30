import Foundation

/// one auto-archived tab — a Today tab that aged out and was closed for you
nonisolated struct ArchiveEntry: Codable, Identifiable {
    var id: UUID
    var url: URL
    var title: String
    var archivedAt: Date
    /// the space the tab was archived from, for grouping/labels later
    var spaceName: String

    init(id: UUID = UUID(), url: URL, title: String, archivedAt: Date = Date(), spaceName: String) {
        self.id = id
        self.url = url
        self.title = title
        self.archivedAt = archivedAt
        self.spaceName = spaceName
    }
}

/// the auto-archive: Today tabs that went stale get closed and land here, newest
/// first, browsable and restorable from the Library. persisted to a JSON file in
/// the app container — stays entirely on-device (privacy pillar)
@Observable
final class ArchiveStore {
    private(set) var entries: [ArchiveEntry] = []

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private static let maxEntries = 5000

    /// `entries` from `read(_:)` skips the load, so a caller can decode off main
    init(fileURL: URL, entries: [ArchiveEntry]? = nil) {
        self.fileURL = fileURL
        if let entries { self.entries = entries } else { load() }
    }

    nonisolated static func read(_ url: URL) -> [ArchiveEntry]? {
        AppStorageLocation.loadDurable([ArchiveEntry].self, from: url)
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

    func clear() { clear(since: .distantPast) }

    /// drop matching entries, so a test run can take itself back out
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
        let url = fileURL
        saveTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            // encode as well as write off the main actor — this fires a second
            // after every navigation and the list runs to thousands of entries,
            // so encoding on the caller lands a stall in the middle of browsing
            await Task.detached(priority: .utility) {
                if let data = try? JSONEncoder().encode(snapshot) {
                    AppStorageLocation.writeDurable(data, to: url)
                }
            }.value
        }
    }

    private func load() {
        guard let decoded = Self.read(fileURL) else { return }
        entries = decoded
    }
}
