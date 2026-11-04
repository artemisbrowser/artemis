// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import Foundation

/// what a tab is called when that isn't the page's title, keyed by url so the
/// name outlives the tab object. `custom` is typed and never overwritten;
/// `generated` is the on-device model's, replaced when the page changes
@MainActor
@Observable
final class TabNameStore {
    static let shared = TabNameStore()

    nonisolated struct Names: Codable {
        var custom: String?
        var generated: String?
        /// the page title the generated name was made from; a match means the
        /// model needn't be asked again
        var generatedFrom: String?

        var isEmpty: Bool { custom == nil && generated == nil }
    }

    private(set) var names: [String: Names] = [:]
    private static let fileName = "tabnames.json"

    private init() {
        names =
            AppStorageLocation.loadDurable(
                [String: Names].self, from: AppStorageLocation.file(Self.fileName)) ?? [:]
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

    /// the page title this url's generated name was made from, if any
    func generatedFrom(for url: URL?) -> String? {
        Self.key(url).flatMap { names[$0]?.generatedFrom }
    }

    /// forget the model's suggestion but keep anything typed
    func clearGenerated(for url: URL?) {
        guard let key = Self.key(url), var entry = names[key] else { return }
        entry.generated = nil
        entry.generatedFrom = nil
        write(entry, at: key)
    }

    /// forget the model's names, and the page titles they came from, except at `urls`;
    /// anything typed stays
    func clearAllGenerated(keeping urls: [URL?] = []) {
        let kept = Set(urls.compactMap(Self.key))
        let stale = names.filter {
            ($0.value.generated != nil || $0.value.generatedFrom != nil) && !kept.contains($0.key)
        }
        guard !stale.isEmpty else { return }
        for (key, var entry) in stale {
            entry.generated = nil
            entry.generatedFrom = nil
            names[key] = entry.isEmpty ? nil : entry
        }
        save()
    }

    private func write(_ entry: Names, at key: String) {
        names[key] = entry.isEmpty ? nil : entry
        save()
    }

    /// tracking and playback parameters, which never change which page a url names
    private static let ignoredParameters: Set<String> = [
        "utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content",
        "fbclid", "gclid", "msclkid", "mc_cid", "mc_eid", "igshid", "ref", "ref_src",
        "pp", "si", "feature", "app", "t", "start_radio", "ab_channel",
    ]

    /// computed keys by absolute url string. every sidebar row asks for its name
    /// on every body pass, so a hit must not allocate
    private static var keyCache: [String: String] = [:]

    /// the url without its fragment or tracking parameters. the rest of the query
    /// is kept: on many sites (`youtube.com/watch?v=…`) it is the page
    static func key(_ url: URL?) -> String? {
        guard let url, let scheme = url.scheme, scheme == "http" || scheme == "https",
            let host = url.host()
        else { return nil }
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

    /// coalesced: each save re-encodes the whole map
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
        AppStorageLocation.writeDurable(data, to: AppStorageLocation.file(Self.fileName))
    }

    @ObservationIgnored private var needsWrite = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    /// write any outstanding names synchronously, for `applicationWillTerminate`.
    /// a flushed write is already queued ahead of this one
    func saveNow() {
        saveTask?.cancel()
        guard needsWrite, let data = try? JSONEncoder().encode(names) else { return }
        needsWrite = false
        AppStorageLocation.writeDurableNow(data, to: AppStorageLocation.file(Self.fileName))
    }
}
