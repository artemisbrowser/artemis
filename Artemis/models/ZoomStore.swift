import Foundation

/// remembers page zoom per site, Safari-style: zoom a host once and every page on
/// it (and every future tab that opens it) comes up at that level. persisted to a
/// JSON file in the app container — on-device, like the other stores.
///
/// keyed by host with the leading `www.` stripped, so `www.example.com` and
/// `example.com` share one setting.
@Observable
@MainActor
final class ZoomStore {
    static let shared = ZoomStore()

    /// the zoom steps ⌘+/⌘- walk through — Safari's ladder
    static let steps: [Double] = [0.5, 0.75, 0.85, 1.0, 1.15, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]
    static let defaultZoom: Double = 1.0

    /// host → zoom factor. only non-default entries are kept, so the file stays
    /// small and "reset" really means "forget"
    private(set) var levels: [String: Double] = [:]

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    nonisolated static let defaultFile = AppStorageLocation.file("zoom.json")

    /// `fileURL` is only ever passed by the test suite (see `HistoryStore.init`).
    /// `levels` from `read(_:)` skips the load, so a caller can decode off main
    init(fileURL: URL = defaultFile, levels: [String: Double]? = nil) {
        self.fileURL = fileURL
        if let decoded = levels ?? Self.read(fileURL) { self.levels = decoded }
    }

    nonisolated static func read(_ url: URL = defaultFile) -> [String: Double]? {
        AppStorageLocation.loadDurable([String: Double].self, from: url)
    }

    /// normalized lookup key for a url — nil for non-web urls, which never zoom
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
        // nearest ladder rung to where we are, then move
        let index = steps.enumerated().min {
            abs($0.element - current) < abs($1.element - current)
        }?.offset ?? steps.firstIndex(of: defaultZoom)!
        return steps[min(max(index + delta, 0), steps.count - 1)]
    }

    /// forget every per-site zoom (Privacy settings' clear path)
    func clear() {
        guard !levels.isEmpty else { return }
        levels = [:]
        scheduleSave()
    }

    /// write synchronously, for app termination — the debounce and the detached
    /// write are both killed with the process, so a zoom set in the last moment
    /// before quitting never reaches disk
    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        guard let data = try? JSONEncoder().encode(levels) else { return }
        AppStorageLocation.writeDurableNow(data, to: fileURL)
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = levels
        let url = fileURL
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            _ = self
            await Task.detached(priority: .utility) {
                guard let data = try? JSONEncoder().encode(snapshot) else { return }
                AppStorageLocation.writeDurable(data, to: url)
            }.value
        }
    }
}
