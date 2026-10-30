import Foundation

/// What a tab is called, when that isn't just the page's title.
///
/// Two kinds of name live here and the difference matters:
///
/// - **`custom`** — a name you typed. It is never overwritten, never
///   regenerated, and survives the intelligence layer being switched off. If you
///   named a tab, that's its name.
/// - **`generated`** — a name the on-device model suggested for a long page
///   title. Replaced whenever the page changes, dropped wholesale when the
///   feature is switched off, and always revertible.
///
/// Keyed by url rather than stored on the tab, for the same reason per-site zoom
/// is: a pinned tab *is* its url, it gets rebuilt when it crosses a container,
/// and it comes back from a restore as a fresh object. A name that lived on the
/// tab object would quietly evaporate at each of those points.
@MainActor
@Observable
final class TabNameStore {
    static let shared = TabNameStore()

    nonisolated struct Names: Codable {
        var custom: String?
        var generated: String?
        /// the page title the generated name was made from. asking the model
        /// again for a page it has already named is a second of its time spent
        /// reaching the same answer — this is what makes a re-pin instant
        var generatedFrom: String?

        var isEmpty: Bool { custom == nil && generated == nil }
    }

    private(set) var names: [String: Names] = [:]
    nonisolated private static let fileName = "tabnames.json"

    /// `names` from `read()` skips the load, so a caller can decode off main
    init(names: [String: Names]? = nil) {
        if let stored = names ?? Self.read() { self.names = stored }
    }

    nonisolated static func read() -> [String: Names]? {
        AppStorageLocation.loadDurable([String: Names].self, from: AppStorageLocation.file(fileName))
    }

    /// the name to show: yours, then the model's, then nothing (meaning "use the
    /// page title")
    func name(for url: URL?) -> String? {
        guard let key = Self.key(url) else { return nil }
        guard let entry = names[key] else { return nil }
        return entry.custom ?? entry.generated
    }

    func custom(for url: URL?) -> String? {
        Self.key(url).flatMap { names[$0]?.custom }
    }

    func hasGenerated(for url: URL?) -> Bool {
        Self.key(url).flatMap { names[$0]?.generated } != nil
    }

    func setCustom(_ name: String?, for url: URL?) {
        guard let key = Self.key(url) else { return }
        var entry = names[key] ?? Names()
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        entry.custom = (trimmed?.isEmpty ?? true) ? nil : trimmed
        write(entry, at: key)
    }

    func setGenerated(_ name: String?, from pageTitle: String? = nil, for url: URL?) {
        guard let key = Self.key(url) else { return }
        var entry = names[key] ?? Names()
        entry.generated = name
        entry.generatedFrom = name == nil ? nil : pageTitle
        write(entry, at: key)
    }

    /// the page title this url's generated name was made from, if any — a
    /// match means the model has already answered this exact question
    func generatedFrom(for url: URL?) -> String? {
        Self.key(url).flatMap { names[$0]?.generatedFrom }
    }

    /// forget the model's suggestion but keep anything you typed — what
    /// switching the feature off should do, and what "Use Page Title" does for
    /// one tab
    func clearGenerated(for url: URL?) {
        guard let key = Self.key(url), var entry = names[key] else { return }
        entry.generated = nil
        write(entry, at: key)
    }

    func clearAllGenerated() {
        for (key, var entry) in names where entry.generated != nil {
            entry.generated = nil
            names[key] = entry.isEmpty ? nil : entry
        }
        save()
    }

    func clearAll() {
        names = [:]
        save()
    }

    private func write(_ entry: Names, at key: String) {
        names[key] = entry.isEmpty ? nil : entry
        save()
    }

    /// Tracking and playback noise a site appends to its own URLs. Dropping
    /// these is what stops `?utm_source=…` minting a second name — and, on
    /// YouTube, what stops the parameters the player adds a second after load
    /// from orphaning the name that was just generated.
    private static let ignoredParameters: Set<String> = [
        "utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content",
        "fbclid", "gclid", "msclkid", "mc_cid", "mc_eid", "igshid", "ref", "ref_src",
        "pp", "si", "feature", "app", "t", "start_radio", "ab_channel",
    ]

    /// the fragment is dropped and tracking parameters are stripped, but what's
    /// left of the query is kept: a pinned tab is a place, and on plenty of
    /// sites the query *is* the place (`youtube.com/watch?v=…` — dropping it
    /// gave every video on earth one shared name)
    /// keys for URLs that carry a query, memoised. every sidebar row asks its
    /// tab what it's called on every pass of the sidebar's body — sixty times a
    /// second during an animation, times the number of rows — so this must stay
    /// a lookup. query-less URLs (most of them) never reach the cache: their
    /// key is pure string work
    nonisolated(unsafe) private static var keyCache: [String: String] = [:]

    static func key(_ url: URL?) -> String? {
        guard let url, let scheme = url.scheme, scheme == "http" || scheme == "https",
            let host = url.host()
        else { return nil }
        // the cache is consulted on the url's own string, before anything is
        // built. every sidebar row asks for this on every pass of the sidebar's
        // body — sixty times a second during an animation, times the row count —
        // so composing a lookup key first made the cache cost an allocation to
        // avoid a computation
        let absolute = url.absoluteString
        if let cached = keyCache[absolute] { return cached }

        let path = url.path()
        let base = "\(scheme)://\(host)\(path.isEmpty ? "/" : path)"
        let computed: String
        if let query = url.query(), !query.isEmpty {
            let kept = (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
                .filter { !ignoredParameters.contains($0.name.lowercased()) }
                .map { "\($0.name)=\($0.value ?? "")" }
                .sorted()  // parameter order is not identity
            computed = kept.isEmpty ? base : "\(base)?\(kept.joined(separator: "&"))"
        } else {
            computed = base
        }
        if keyCache.count > 500 { keyCache.removeAll(keepingCapacity: true) }
        keyCache[absolute] = computed
        return computed
    }

    /// Coalesced: every name is the whole map re-encoded, so a run of them —
    /// importing a folder of bookmarks, the model tidying a batch of titles —
    /// would otherwise be one full encode and one rotating write per name.
    private func save() {
        needsWrite = true
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    private func flush() {
        guard needsWrite, let data = try? JSONEncoder().encode(names) else { return }
        needsWrite = false
        let url = AppStorageLocation.file(Self.fileName)
        pendingWrite = data
        Task { [weak self] in
            await Self.write(data, to: url)
            // only clear if nothing newer arrived while this was in flight
            if self?.pendingWrite == data { self?.pendingWrite = nil }
        }
    }

    @concurrent
    private static func write(_ data: Data, to url: URL) async {
        AppStorageLocation.writeDurable(data, to: url)
    }

    @ObservationIgnored private var needsWrite = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    /// the most recent encoding not yet known to have reached disk. names are
    /// written off the main thread, and a rename made moments before quitting
    /// would otherwise die with the process — the one case where a background
    /// write is exactly as good as no write at all
    @ObservationIgnored private var pendingWrite: Data?

    /// write any outstanding names synchronously. called from
    /// `applicationWillTerminate`, where there is no later
    func saveNow() {
        saveTask?.cancel()
        // a name set within the debounce window has no encoding yet
        if needsWrite, let data = try? JSONEncoder().encode(names) {
            needsWrite = false
            pendingWrite = data
        }
        guard let pendingWrite else { return }
        AppStorageLocation.writeDurableNow(pendingWrite, to: AppStorageLocation.file(Self.fileName))
        self.pendingWrite = nil
    }
}
