// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import Foundation

/// the command bar's habit memory: what was picked for what was typed, boosted
/// above the generic ranking
@MainActor
final class InputHistory {
    /// typed query → target key → use count, asymptotic to 10
    private var counts: [String: [String: Double]] = [:]
    private var lastDecay = Date()
    private let fileURL: URL
    private var saveTask: Task<Void, Never>?

    private static let maxQueries = 2000

    init(fileURL: URL) {
        self.fileURL = fileURL
        if let saved = AppStorageLocation.loadDurable(Snapshot.self, from: fileURL) {
            counts = saved.counts
            lastDecay = saved.lastDecay
        }
        decayIfDue()
    }

    /// boost per target key for this input; scans every query, so call it once per
    /// keystroke, never per candidate
    func boosts(for input: String) -> [String: Int] {
        let typed = Self.normalize(input)
        guard !typed.isEmpty else { return [:] }
        var out: [String: Int] = [:]
        for (query, targets) in counts where query.hasPrefix(typed) {
            let exact = query == typed
            for (key, count) in targets {
                let boost = exact ? 320 + Int(38 * count) : 180 + Int(20 * count)
                out[key] = max(out[key] ?? 0, boost)
            }
        }
        return out
    }

    /// remember that `key` is what this input meant
    func record(input: String, key: String) {
        let typed = Self.normalize(input)
        guard !typed.isEmpty, !key.isEmpty else { return }
        var targets = counts[typed] ?? [:]
        targets[key] = min(10, (targets[key] ?? 0) * 0.9 + 1)
        counts[typed] = targets
        prune()
        scheduleSave()
    }

    /// drop every target whose key matches, and any query left with none
    func forget(_ matches: (String) -> Bool) {
        counts = counts.compactMapValues { targets in
            let kept = targets.filter { !matches($0.key) }
            return kept.isEmpty ? nil : kept
        }
        scheduleSave()
    }

    func clear() {
        AppStorageLocation.discardUnreadable(of: fileURL)
        counts = [:]
        saveNow(keepsBackup: false)
    }

    private static func normalize(_ input: String) -> String {
        input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// counts lose 2.5% per whole day; a target below 0.1 is dropped
    private func decayIfDue() {
        let days = Int(Date().timeIntervalSince(lastDecay) / 86400)
        guard days >= 1 else { return }
        let factor = pow(0.975, Double(days))
        for (query, targets) in counts {
            var kept: [String: Double] = [:]
            for (key, count) in targets where count * factor >= 0.1 {
                kept[key] = count * factor
            }
            counts[query] = kept.isEmpty ? nil : kept
        }
        lastDecay = Date()
        scheduleSave()
    }

    private func prune() {
        guard counts.count > Self.maxQueries else { return }
        let ranked = counts.sorted { ($0.value.values.max() ?? 0) > ($1.value.values.max() ?? 0) }
        counts = Dictionary(uniqueKeysWithValues: ranked.prefix(Self.maxQueries).map { ($0, $1) })
    }

    // MARK: - Persistence

    private nonisolated struct Snapshot: Codable {
        var counts: [String: [String: Double]]
        var lastDecay: Date
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = Snapshot(counts: counts, lastDecay: lastDecay)
        let takenAt = AppStorageLocation.snapshotTime()
        let url = fileURL
        saveTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await Task.detached(priority: .utility) {
                guard let data = try? JSONEncoder().encode(snapshot) else { return }
                AppStorageLocation.writeDurable(data, to: url, takenAt: takenAt)
            }.value
        }
    }

    func saveNow(keepsBackup: Bool = true) {
        saveTask?.cancel()
        let snapshot = Snapshot(counts: counts, lastDecay: lastDecay)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        AppStorageLocation.writeDurableNow(data, to: fileURL, keepsBackup: keepsBackup)
    }
}
