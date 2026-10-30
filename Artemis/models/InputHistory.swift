import Foundation

/// what you picked, for what you typed. the command bar's habit memory: two
/// letters keep landing on the page they landed on last time, whatever the
/// generic ranking would have said.
@MainActor
final class InputHistory {
    /// typed query → target key → use count, asymptotic to 10
    private var counts: [String: [String: Double]] = [:]
    private var lastDecay = Date()
    private let fileURL: URL
    private var saveTask: Task<Void, Never>?

    /// beyond this the tail is queries typed once and never again
    private static let maxQueries = 2000

    /// `saved` from `read(_:)` skips the load, so a caller can decode off main
    init(fileURL: URL, saved: Snapshot? = nil) {
        self.fileURL = fileURL
        if let saved { apply(saved) } else { load() }
        decayIfDue()
    }

    nonisolated static func read(_ url: URL) -> Snapshot? {
        AppStorageLocation.loadDurable(Snapshot.self, from: url)
    }

    /// the boost every candidate should get for this input, looked up by target
    /// key. built once per keystroke — a per-candidate scan of every query ever
    /// typed is the shape that makes a bar feel slow
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
        counts = [:]
        scheduleSave()
    }

    private static func normalize(_ input: String) -> String {
        input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// unused entries fade rather than being kept forever: a habit you dropped
    /// months ago should stop outranking the page you actually want
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

    nonisolated struct Snapshot: Codable {
        var counts: [String: [String: Double]]
        var lastDecay: Date
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = Snapshot(counts: counts, lastDecay: lastDecay)
        let url = fileURL
        saveTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await Task.detached(priority: .utility) {
                guard let data = try? JSONEncoder().encode(snapshot) else { return }
                AppStorageLocation.writeDurable(data, to: url)
            }.value
        }
    }

    func saveNow() {
        saveTask?.cancel()
        let snapshot = Snapshot(counts: counts, lastDecay: lastDecay)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        AppStorageLocation.writeDurableNow(data, to: fileURL)
    }

    private func load() {
        if let snapshot = Self.read(fileURL) { apply(snapshot) }
    }

    private func apply(_ snapshot: Snapshot) {
        counts = snapshot.counts
        lastDecay = snapshot.lastDecay
    }
}
