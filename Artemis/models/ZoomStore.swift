// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import Foundation

/// page zoom per site: every page on a host opens at the level last set there.
/// keyed by host with a leading `www.` stripped
@Observable
@MainActor
final class ZoomStore {
    static let shared = ZoomStore()

    /// the zoom steps ⌘+/⌘- walk through — Safari's ladder
    static let steps: [Double] = [0.5, 0.75, 0.85, 1.0, 1.15, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]
    static let defaultZoom: Double = 1.0

    /// host → zoom factor; only non-default levels are kept
    private(set) var levels: [String: Double] = [:]

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    /// `fileURL` is for the test suite
    init(fileURL: URL = AppStorageLocation.file("zoom.json")) {
        self.fileURL = fileURL
        levels = AppStorageLocation.loadDurable([String: Double].self, from: fileURL) ?? [:]
    }

    /// nil for a url without a host, which never zooms
    static func key(for url: URL?) -> String? {
        guard let host = url?.host()?.lowercased(), !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    func zoom(for url: URL?) -> Double {
        guard let key = Self.key(for: url) else { return Self.defaultZoom }
        return levels[key] ?? Self.defaultZoom
    }

    func setZoom(_ zoom: Double, for url: URL?) {
        guard let key = Self.key(for: url) else { return }
        if abs(zoom - Self.defaultZoom) < 0.001 {
            guard levels[key] != nil else { return }
            levels.removeValue(forKey: key)
        } else {
            guard levels[key] != zoom else { return }
            levels[key] = zoom
        }
        scheduleSave()
    }

    /// the next step up (or down) from `current`, clamped at the ends
    static func step(from current: Double, by delta: Int) -> Double {
        let index = steps.enumerated().min {
            abs($0.element - current) < abs($1.element - current)
        }?.offset ?? steps.firstIndex(of: defaultZoom)!
        return steps[min(max(index + delta, 0), steps.count - 1)]
    }

    /// forget every per-site zoom
    func clear() {
        guard !levels.isEmpty else { return }
        levels = [:]
        scheduleSave()
    }

    /// write synchronously, for app termination, where a debounced write dies
    /// with the process
    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        guard let data = try? JSONEncoder().encode(levels) else { return }
        AppStorageLocation.writeDurableNow(data, to: fileURL)
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = levels
        let takenAt = AppStorageLocation.snapshotTime()
        let url = fileURL
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await Task.detached(priority: .utility) {
                guard let data = try? JSONEncoder().encode(snapshot) else { return }
                AppStorageLocation.writeDurable(data, to: url, takenAt: takenAt)
            }.value
        }
    }
}
