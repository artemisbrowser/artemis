// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import Foundation

/// where Artemis keeps its on-device data, and the durable write and load every
/// store goes through
nonisolated enum AppStorageLocation {
    /// whether this process runs inside an App Sandbox container
    static let isContainerised = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil

    /// outside a container every build on the Mac shares ~/Library: the original
    /// bundle keeps "Artemis", any other (a tester build, a lab) gets its bundle ID
    static let folderName: String = {
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
    /// anything that could prompt on the user's screen stays fenced off. ExtensionLab.isRequested and
    /// the Keychain fence both read this one switch
    static let isExtensionLab = ["extlab", "perf"].contains(ProcessInfo.processInfo.environment["ARTEMIS_DIAG"])
    /// `ARTEMIS_DIAG=ext`: the extension runtime traces its compat calls
    static let isExtensionsDiag = ProcessInfo.processInfo.environment["ARTEMIS_DIAG"] == "ext"

    static func file(_ name: String) -> URL {
        directory.appendingPathComponent(name)
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
    /// and the other save-now paths, where a queued write dies with the process
    static func writeDurableNow(_ data: Data, to url: URL) {
        let takenAt = snapshotTime()
        writes.sync {
            newestWritten[url] = takenAt
            rotate(data, to: url)
        }
    }

    private static func rotate(_ data: Data, to url: URL) {
        let backup = url.appendingPathExtension("bak")
        if let existing = try? Data(contentsOf: url), !existing.isEmpty {
            try? existing.write(to: backup, options: .atomic)
        }
        do { try data.write(to: url, options: .atomic) } catch {
            Diagnostics.record(
                area: "storage", message: "\(url.lastPathComponent) failed to save: \(error.localizedDescription)")
        }
    }

    /// decode `url`, falling back to its `.bak` sibling when the primary is
    /// missing, empty, or unreadable. returns nil only when neither is usable.
    static func loadDurable<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        let decoder = JSONDecoder()
        for candidate in [url, url.appendingPathExtension("bak")] {
            guard let data = try? Data(contentsOf: candidate), !data.isEmpty else { continue }
            do { return try decoder.decode(type, from: data) } catch {
                debugLog("store: failed to decode \(candidate.lastPathComponent), trying backup")
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
}
