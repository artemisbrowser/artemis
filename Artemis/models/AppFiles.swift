// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import Foundation

/// where Artemis keeps its on-device data, and the durable write and load every
/// store goes through
nonisolated enum AppStorageLocation {
    /// whether this process runs inside an App Sandbox container
    static let isContainerised = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil

    /// the data folder's and Keychain services' name when the Info.plist's `ArtemisStorageName` gives one
    static let storageName = Bundle.main.object(forInfoDictionaryKey: "ArtemisStorageName") as? String

    /// outside a container every build on the Mac shares ~/Library: the original
    /// bundle keeps "Artemis", any other (a tester build, a lab) gets its bundle ID
    static let folderName: String = {
        if let storageName { return storageName }
        let id = Bundle.main.bundleIdentifier ?? "dev.findles.Artemis"
        return isContainerised || id == "dev.findles.Artemis" ? "Artemis" : id
    }()

    /// `~/Library/Application Support/<folderName>`, created on first use
    static let directory: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(folderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// the extension compatibility lab (`ARTEMIS_DIAG=extlab` or `perf`) runs signed differently, so
    /// anything that could prompt on the user's screen stays fenced off
    static let isExtensionLab = ["extlab", "perf"].contains(ProcessInfo.processInfo.environment["ARTEMIS_DIAG"])
    /// a lab copy or a self-test run: nobody is there to answer a macOS prompt, so the Keychain is
    /// a dictionary and the downloads folder sits in the data folder
    static let isTestRun = isExtensionLab || ProcessInfo.processInfo.environment["ARTEMIS_SELFTEST"] != nil
    /// whether this launch reports and updates itself: never a test run, nor a perflab or extlab
    /// copy started without its script, which the bundle id both scripts write still marks
    static func reportsAndUpdates(
        testRun: Bool = AppStorageLocation.isTestRun, bundleID: String? = Bundle.main.bundleIdentifier
    ) -> Bool {
        !testRun && bundleID?.hasPrefix("dev.findles.Artemis.") != true
    }
    /// `ARTEMIS_DIAG=ext`: the extension runtime traces its compat calls
    static let isExtensionsDiag = ProcessInfo.processInfo.environment["ARTEMIS_DIAG"] == "ext"

    static func file(_ name: String) -> URL {
        directory.appendingPathComponent(name)
    }

    /// `~/Library/Logs/Artemis/<stem>.<ext>`, the one folder for self-test, diag and bench output;
    /// a lab copy "Artemis <ID>" gets `<stem>-<ID>.<ext>`, so parallel runs never share a file
    static func devFile(_ stem: String, _ ext: String) -> URL {
        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appending(path: "Logs/Artemis", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let bundleName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Artemis"
        let lab = bundleName.dropFirst("Artemis".count).trimmingCharacters(in: .whitespaces)
        return logs.appending(path: lab.isEmpty ? "\(stem).\(ext)" : "\(stem)-\(lab).\(ext)")
    }

    /// serialises every durable write in the process: overlapping rotations could
    /// copy a half-written primary over the backup
    private static let writes = DispatchQueue(label: "com.artemis.durable-write")

    /// when each file's newest written snapshot was taken; touched only on `writes`
    nonisolated(unsafe) private static var newestWritten: [URL: UInt64] = [:]

    /// a monotonic stamp for a snapshot, to pass to `writeDurable(_:to:takenAt:)`
    static func snapshotTime() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    /// write atomically, keeping the previous non-empty copy as `<name>.bak` for
    /// `loadDurable` to fall back to. queued, not awaited; writes land in call order,
    /// except that one stamped older than a write already made to `url` is dropped
    static func writeDurable(_ data: Data, to url: URL, takenAt: UInt64? = nil) {
        writes.async {
            if let takenAt {
                guard takenAt >= newestWritten[url, default: 0] else { return }
                newestWritten[url] = takenAt
            }
            rotate(data, to: url)
        }
    }

    /// `writeDurable`, finished before it returns: for `applicationWillTerminate`
    /// and the other save-now paths, where a queued write dies with the process.
    /// a clear passes `keepsBackup: false`, so the `.bak` can't hold what it erased
    static func writeDurableNow(_ data: Data, to url: URL, keepsBackup: Bool = true) {
        let takenAt = snapshotTime()
        writes.sync {
            newestWritten[url] = takenAt
            rotate(data, to: url, keepsBackup: keepsBackup)
        }
    }

    /// runs `work` on the durable-write queue, after every write queued before it
    static func enqueueDurable(_ work: @escaping @Sendable () -> Void) {
        writes.async(execute: work)
    }

    /// `enqueueDurable`, finished before it returns: for the quit and background paths
    static func enqueueDurableNow(_ work: () -> Void) {
        writes.sync(execute: work)
    }

    /// a self-test's stand-in for a failing disk: the error a write to this URL throws; touched only on `writes`
    nonisolated(unsafe) static var writeFailure: (@Sendable (URL) -> (any Error)?)?

    private static func write(_ data: Data, to url: URL) throws {
        if let error = writeFailure?(url) { throw error }
        try data.write(to: url, options: .atomic)
    }

    /// why saves are failing, for the sidebar's notice
    enum SaveFailure: Sendable { case diskFull, other }

    /// each file's newest failed write, until a write lands there; touched only on `writes`
    nonisolated(unsafe) private static var unsaved: [URL: (data: Data, keepsBackup: Bool)] = [:] {
        didSet {
            guard unsaved.isEmpty else { return }
            retryRounds = 0
            logged = []
            show(nil)
        }
    }
    /// whether a `retryUnsaved` is already queued; touched only on `writes`
    nonisolated(unsafe) private(set) static var isRetryQueued = false
    /// seconds from a failed write to its first retry; each failed round after it waits
    /// twice as long, up to tenfold. touched only on `writes`
    nonisolated(unsafe) static var retryBase = 30.0
    /// retries queued since nothing was unsaved, at most 4; touched only on `writes`
    nonisolated(unsafe) private static var retryRounds = 0
    /// the causes logged since nothing was unsaved; touched only on `writes`
    nonisolated(unsafe) private static var logged: Set<String> = []
    /// what the notice shows; touched only on `writes`
    nonisolated(unsafe) private static var shown: SaveFailure?

    /// `.other` never replaces `.diskFull`; runs on `writes` only
    private static func show(_ failure: SaveFailure?) {
        guard failure != shown, failure != .other || shown == nil else { return }
        shown = failure
        DispatchQueue.main.async { StorageNotice.shared.failure = failure }
    }

    /// writes every failed write again; runs on `writes` only, through `enqueueDurable`
    static func retryUnsaved() {
        for (url, write) in unsaved { rotate(write.data, to: url, keepsBackup: write.keepsBackup) }
    }

    /// `retryUnsaved` for a quit, waited on for at most `seconds`: a stalled volume can't hold the quit
    static func retryUnsavedNow(within seconds: Double = 2) {
        let done = DispatchSemaphore(value: 0)
        writes.async {
            retryUnsaved()
            done.signal()
        }
        _ = done.wait(timeout: .now() + seconds)
    }

    /// forgets the failed write to each of `urls`, for a caller removing them; runs on `writes` only
    static func forgetUnsaved(_ urls: [URL]) {
        for url in urls { unsaved[url] = nil }
    }

    /// folders whose writes are dropped, each path ending in "/"; touched only on `writes`
    nonisolated(unsafe) private static var discarded: Set<String> = []

    /// drops every failed and later write under `folder`, until `keepWrites(under:)`;
    /// writes queued before it still land
    static func discardWrites(under folder: URL) {
        let prefix = folder.path + "/"
        writes.async {
            discarded.insert(prefix)
            unsaved = unsaved.filter { !$0.key.path.hasPrefix(prefix) }
        }
    }

    static func keepWrites(under folder: URL) {
        let prefix = folder.path + "/"
        writes.async { discarded.remove(prefix) }
    }

    /// removes `folder` after the writes queued before it, unless `keepWrites(under:)` followed its discard
    static func removeDiscarded(_ folder: URL) {
        let prefix = folder.path + "/"
        writes.async {
            guard discarded.contains(prefix) else { return }
            try? FileManager.default.removeItem(at: folder)
        }
    }

    private static func rotate(_ data: Data, to url: URL, keepsBackup: Bool = true) {
        guard !discarded.contains(where: { url.path.hasPrefix($0) }) else { return }
        // a clear yet to land stays a clear: the primary still holds what it erased
        let keepsBackup = keepsBackup && unsaved[url]?.keepsBackup != false
        let backup = url.appendingPathExtension("bak")
        let previous = keepsBackup ? (try? Data(contentsOf: url)) : nil
        do {
            do { try write(data, to: url) } catch {
                let folder = url.deletingLastPathComponent()
                if !FileManager.default.fileExists(atPath: folder.path) {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                } else {
                    // a failed clear frees its backup's space for one more try, only while a
                    // loadable primary remains; the primary itself is never removed
                    guard !keepsBackup, (try? Data(contentsOf: url))?.isEmpty == false,
                        (try? FileManager.default.removeItem(at: backup)) != nil
                    else { throw error }
                }
                try write(data, to: url)
            }
            // only behind a landed write: a failed one leaves both files as they were
            if let previous, !previous.isEmpty { try? write(previous, to: backup) }
            if !keepsBackup { try? FileManager.default.removeItem(at: backup) }
            unsaved[url] = nil
        } catch {
            let failure = error as NSError
            let reason =
                switch (failure.domain, failure.code) {
                case (NSCocoaErrorDomain, NSFileWriteOutOfSpaceError): "disk full"
                case (NSCocoaErrorDomain, NSFileWriteNoPermissionError): "no permission"
                case (NSCocoaErrorDomain, NSFileWriteVolumeReadOnlyError): "read-only volume"
                default: "\(failure.domain) \(failure.code)"
                }
            // one event per cause until nothing is unsaved; it names no file or volume
            if logged.insert(reason).inserted {
                Diagnostics.record(area: "storage", message: "save failed: \(reason)", level: .warning)
            }
            show(reason == "disk full" ? .diskFull : .other)
            unsaved[url] = (data: data, keepsBackup: keepsBackup)
            if !isRetryQueued {
                isRetryQueued = true
                writes.asyncAfter(deadline: .now() + min(retryBase * Double(1 << retryRounds), retryBase * 10)) {
                    isRetryQueued = false
                    retryUnsaved()
                }
                retryRounds = min(retryRounds + 1, 4)
            }
        }
    }

    /// decode `url`, falling back to its `.bak` sibling when the primary is
    /// missing, empty, or unreadable. returns nil only when neither is usable.
    /// an undecodable file is first copied once to `.unreadable`, where no rotation reaches it
    static func loadDurable<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        let decoder = JSONDecoder()
        for candidate in [url, url.appendingPathExtension("bak")] {
            guard let data = try? Data(contentsOf: candidate), !data.isEmpty else { continue }
            do { return try decoder.decode(type, from: data) } catch {
                debugLog("store: failed to decode \(candidate.lastPathComponent), trying backup")
                let aside = candidate.appendingPathExtension("unreadable")
                if !FileManager.default.fileExists(atPath: aside.path) { try? data.write(to: aside, options: .atomic) }
                // the case alone: a decoding error's text names the keys on its path,
                // and some stores are keyed by host or by what was typed
                let reason =
                    switch error as? DecodingError {
                    case .typeMismatch: "typeMismatch"
                    case .valueNotFound: "valueNotFound"
                    case .keyNotFound: "keyNotFound"
                    case .dataCorrupted: "dataCorrupted"
                    default: "\(Swift.type(of: error))"
                    }
                Diagnostics.record(
                    area: "storage", message: "\(candidate.lastPathComponent) failed to decode: \(reason)")
            }
        }
        return nil
    }

    /// for a clear that empties the store at `url` for good: what `loadDurable` set aside goes too
    static func discardUnreadable(of url: URL) {
        for candidate in [url, url.appendingPathExtension("bak")] {
            try? FileManager.default.removeItem(at: candidate.appendingPathExtension("unreadable"))
        }
    }
}
