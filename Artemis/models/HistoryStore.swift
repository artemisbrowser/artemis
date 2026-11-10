// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import Foundation

/// one visited page
nonisolated struct HistoryEntry: Codable, Identifiable {
    var url: URL
    private(set) var title: String
    var lastVisited: Date
    var visitCount: Int
    /// times this page was reached by typing it in the command bar
    var typedCount: Int

    /// lowercased "title url"; derived, so rebuilt on decode rather than stored
    private(set) var searchKey: String
    /// lowercased host and title, which ranking matches by prefix
    private(set) var searchHost: String
    private(set) var searchTitle: String
    /// which a–z and 0–9 `searchKey` holds. a query needing a letter this page
    /// hasn't got can't match it, and that rejection is a single AND
    private(set) var searchMask: UInt64
    /// host with `www.` dropped, which is what the bar autofills against
    private(set) var autofillHost: String

    var id: URL { url }

    init(url: URL, title: String, lastVisited: Date, visitCount: Int, typedCount: Int = 0) {
        self.url = url
        self.title = title
        self.lastVisited = lastVisited
        self.visitCount = visitCount
        self.typedCount = typedCount
        searchKey = ""
        searchHost = ""
        searchTitle = ""
        searchMask = 0
        autofillHost = ""
        reindex()
    }

    mutating func update(title: String) {
        self.title = title
        reindex()
    }

    /// how much this page is worth right now: visits weighted by how you got
    /// there, halving every 30 days
    func frecency(now: Date) -> Double {
        let days = max(0, now.timeIntervalSince(lastVisited) / 86400)
        return (Double(visitCount) + 3 * Double(typedCount)) * pow(2, -days / 30)
    }

    private mutating func reindex() {
        searchKey = (title + " " + url.absoluteString).lowercased()
        searchHost = (url.host() ?? "").lowercased()
        searchTitle = title.lowercased()
        searchMask = CommandMatcher.mask(searchKey.utf8)
        autofillHost =
            searchHost.hasPrefix("www.") ? String(searchHost.dropFirst(4)) : searchHost
    }

    private enum CodingKeys: String, CodingKey {
        case url, title, lastVisited, visitCount, typedCount
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = try c.decode(URL.self, forKey: .url)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? (url.host() ?? "")
        lastVisited = try c.decodeIfPresent(Date.self, forKey: .lastVisited) ?? Date()
        visitCount = try c.decodeIfPresent(Int.self, forKey: .visitCount) ?? 1
        typedCount = try c.decodeIfPresent(Int.self, forKey: .typedCount) ?? 0
        searchKey = ""
        searchHost = ""
        searchTitle = ""
        searchMask = 0
        autofillHost = ""
        reindex()
    }
}

/// a history hit and what it scored, with the offsets the bar highlights
struct HistoryMatch {
    let entry: HistoryEntry
    let score: Int
    let titleRanges: [Range<Int>]
}

/// one profile's browsing trail, newest first: recorded on every committed
/// navigation, capped at `maxEntries`, and kept only on this Mac
@Observable
final class HistoryStore {
    private(set) var entries: [HistoryEntry] = []

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private static let maxEntries = 5000

    /// `entries` from `read(_:)` skips the load, so a caller can decode off main
    init(fileURL: URL, entries: [HistoryEntry]? = nil) {
        self.fileURL = fileURL
        if let entries { self.entries = entries } else { load() }
    }

    nonisolated static func read(_ url: URL) -> [HistoryEntry]? {
        AppStorageLocation.loadDurable([HistoryEntry].self, from: url)
    }

    /// record a visit; collapses repeats of the same url into one entry that
    /// floats to the front with a bumped count
    func record(url: URL, title: String) {
        guard url.scheme == "http" || url.scheme == "https" else { return }

        if let index = entries.firstIndex(where: { $0.url == url }) {
            var entry = entries.remove(at: index)
            entry.update(title: title)
            entry.lastVisited = Date()
            entry.visitCount += 1
            entries.insert(entry, at: 0)
        } else {
            entries.insert(
                HistoryEntry(url: url, title: title, lastVisited: Date(), visitCount: 1), at: 0)
            if entries.count > Self.maxEntries {
                entries.removeLast(entries.count - Self.maxEntries)
            }
        }
        scheduleSave()
    }

    /// fold another browser's trail in: a url already known keeps the higher
    /// counts and the later visit. returns how many new pages the cap left in
    @discardableResult
    func merge(_ imported: [HistoryEntry]) -> Int {
        guard !imported.isEmpty else { return 0 }
        var byURL: [URL: Int] = [:]
        var fresh: Set<URL> = []
        for (i, entry) in entries.enumerated() { byURL[entry.url] = i }
        for entry in imported {
            guard let i = byURL[entry.url] else {
                byURL[entry.url] = entries.count
                entries.append(entry)
                fresh.insert(entry.url)
                continue
            }
            entries[i].visitCount = max(entries[i].visitCount, entry.visitCount)
            entries[i].typedCount = max(entries[i].typedCount, entry.typedCount)
            entries[i].lastVisited = max(entries[i].lastVisited, entry.lastVisited)
        }
        entries.sort { $0.lastVisited > $1.lastVisited }
        if entries.count > Self.maxEntries { entries.removeLast(entries.count - Self.maxEntries) }
        scheduleSave()
        return entries.count { fresh.contains($0.url) }
    }

    /// best matches for a query across `stores` — ranked by relevance then recency/frequency
    static func search(_ query: String, in stores: [HistoryStore], limit: Int = 6) -> [HistoryEntry] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        // a page whose mask lacks one of the query's letters can't match
        let mask = CommandMatcher.mask(q.utf8)
        let needle = Array(q.utf8)
        let trails = stores.map(\.entries)
        var scored: [(trail: Int, index: Int, score: Int)] = []
        for (trail, entries) in trails.enumerated() {
            for (index, entry) in entries.enumerated()
            where (mask & ~entry.searchMask) == 0
                && CommandMatcher.contains(needle, entry.searchKey) {
                scored.append((trail, index, score(entry, query: q)))
            }
        }
        scored.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return trails[lhs.trail][lhs.index].lastVisited > trails[rhs.trail][rhs.index].lastVisited
        }
        return scored.prefix(limit).map { trails[$0.trail][$0.index] }
    }

    /// note that this page was reached by typing it, not by following a link
    func markTyped(_ url: URL) {
        guard let index = entries.firstIndex(where: { $0.url == url }) else { return }
        entries[index].typedCount += 1
        scheduleSave()
    }

    /// scored matches for the command bar: match quality on one scale, plus a
    /// frecency lift so a page you live in outranks one you saw once
    func rankedMatches(
        _ needle: [UInt8], mask: UInt64, limit: Int, now: Date = Date()
    ) -> [HistoryMatch] {
        guard !needle.isEmpty else { return [] }
        let entries = entries
        // rank indices and scores alone; only the `limit` survivors become matches
        var ranked: [(index: Int, score: Int, preferTitle: Bool)] = []
        for (index, entry) in entries.enumerated() where (mask & ~entry.searchMask) == 0 {
            let title = CommandMatcher.match(needle, entry.searchTitle)?.score
            let address = CommandMatcher.match(needle, entry.searchKey)?.score
            guard let best = [title, address].compactMap({ $0 }).max() else { continue }
            let lift = min(300, Int(60 * log2(1 + entry.frecency(now: now))))
            ranked.append((index, best + lift, (title ?? -1) >= (address ?? -1)))
        }
        ranked.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return entries[lhs.index].lastVisited > entries[rhs.index].lastVisited
        }
        return ranked.prefix(limit).map { hit in
            let entry = entries[hit.index]
            return HistoryMatch(
                entry: entry, score: hit.score,
                titleRanges: hit.preferTitle
                    ? (CommandMatcher.match(needle, entry.searchTitle)?.ranges ?? []) : [])
        }
    }

    /// pages whose host starts with what's been typed, with their frecency, best
    /// first — the pool the bar autofills from
    func autofillCandidates(_ prefix: String, now: Date = Date()) -> [(entry: HistoryEntry, frecency: Double)] {
        guard !prefix.isEmpty else { return [] }
        return
            entries
            .filter { $0.autofillHost.hasPrefix(prefix) }
            .map { ($0, $0.frecency(now: now)) }
            .sorted { $0.frecency > $1.frecency }
    }

    /// forget specific pages, leaving the rest of the trail alone, so a test or
    /// diagnostic run can take itself back out of the user's history
    func forget(where shouldForget: (HistoryEntry) -> Bool) {
        let gone = entries.filter(shouldForget).map(\.url)
        guard !gone.isEmpty else { return }
        entries.removeAll(where: shouldForget)
        scheduleSave()
    }

    /// drop everything visited since `date`; `.distantPast` wipes the lot
    func clear(since date: Date) {
        if date == .distantPast { AppStorageLocation.discardUnreadable(of: fileURL) }
        let before = entries.count
        entries.removeAll { $0.lastVisited >= date }
        guard entries.count != before else { return }
        saveNow(keepsBackup: false)
    }

    // MARK: - Ranking

    private static func score(_ entry: HistoryEntry, query: String) -> Int {
        var score = 0
        let host = entry.searchHost
        if host.hasPrefix(query) || host.hasPrefix("www." + query) { score += 100 }
        if entry.searchTitle.hasPrefix(query) { score += 50 }
        score += min(entry.visitCount, 20)
        return score
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
            await Task.detached(priority: .utility) {
                if let data = try? JSONEncoder().encode(snapshot) {
                    AppStorageLocation.writeDurable(data, to: url, takenAt: takenAt)
                }
            }.value
        }
    }

    /// write synchronously, for a caller about to quit
    func saveNow(keepsBackup: Bool = true) {
        saveTask?.cancel()
        guard let data = try? JSONEncoder().encode(entries) else { return }
        AppStorageLocation.writeDurableNow(data, to: fileURL, keepsBackup: keepsBackup)
    }

    private func load() {
        guard let decoded = Self.read(fileURL) else { return }
        entries = decoded
    }
}
