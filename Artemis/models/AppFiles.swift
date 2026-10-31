import Foundation

/// one place that knows where Artemis keeps its on-device data, and how it writes
/// it. every store (history, archive, zoom, spaces, boosts) goes
/// through here so the container layout is defined once and the durable-write
/// rules can't drift between them.
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

    /// write atomically, keeping the previous good copy as `<name>.bak`.
    ///
    /// atomic alone protects against a torn file, but not against writing a
    /// *valid* file with bad content (a decode bug, an empty model after a
    /// failed migration). the rotation gives `loadDurable` something to fall back
    /// to, which is what makes losing a year of spaces to one bad launch
    /// impossible.
    /// Serialises every durable write in the process. The rotation is a
    /// read-then-two-writes sequence, and stores save from detached tasks — two
    /// overlapping saves could otherwise copy a half-written primary over the
    /// good backup, which is the one file the fallback depends on.
    private static let writes = DispatchQueue(label: "com.artemis.durable-write")

    /// The ordinary path: the rotation is queued, not awaited. Ordering is still
    /// the queue's, so a later save can't overtake an earlier one — the caller
    /// simply stops waiting for the disk.
    ///
    /// It used to wait, and on the main thread that meant waiting behind every
    /// background store's write. A profile of a loaded machine caught exactly
    /// that: the main thread parked in `_dispatch_lane_barrier_sync_invoke_and_complete`
    /// while eight cooperative threads queued writes ahead of it.
    static func writeDurable(_ data: Data, to url: URL) {
        writes.async { rotate(data, to: url) }
    }

    /// The same write, finished before it returns — for `applicationWillTerminate`
    /// and the other save-now paths, where a queued write dies with the process.
    static func writeDurableNow(_ data: Data, to url: URL) {
        writes.sync { rotate(data, to: url) }
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
