import Foundation

/// Per-tab session blobs — `WKWebView.interactionState`, which carries scroll
/// position, form contents and the whole back/forward list.
///
/// One file per tab rather than a field in `session.json`: the blobs are large
/// and binary, and inlining them would make the file that holds every space and
/// tab both slow to write on each navigation and expensive to lose. A blob is
/// also disposable — a tab whose state is missing or stale still restores from
/// its url — so this store never fails a caller, it just returns nil.
///
/// Nothing from a burner space is ever written here: the blob contains form
/// contents.
enum TabStateStore {
    /// Above this a blob is dropped rather than written. A tab with a very long
    /// back/forward list is exactly the one whose state is least worth a
    /// megabyte on every save; it still comes back at its current url.
    private static let maxBlobBytes = 512 * 1024

    private static let directory: URL = {
        let dir = AppStorageLocation.directory.appendingPathComponent("tabstate", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static func file(_ id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).state")
    }

    /// `state` is WebKit's opaque `interactionState`; anything that isn't `Data`
    /// is not something we can write, and not something worth complaining about
    ///
    /// `immediately` is for app termination: a detached write is killed with the
    /// process before it lands, so quitting would drop whatever changed since
    /// the last debounced save — the scroll position of the page you were on
    static func save(_ state: Any?, for id: UUID, immediately: Bool = false) {
        guard let data = state as? Data, !data.isEmpty else { return remove(id) }
        guard data.count <= maxBlobBytes else { return remove(id) }
        let url = file(id)
        guard !immediately else {
            try? data.write(to: url, options: .atomic)
            return
        }
        Task.detached(priority: .utility) {
            try? data.write(to: url, options: .atomic)
        }
    }

    static func load(_ id: UUID) -> Data? {
        try? Data(contentsOf: file(id))
    }

    static func remove(_ id: UUID) {
        try? FileManager.default.removeItem(at: file(id))
    }

    /// drop blobs for tabs that no longer exist. A crash between closing a tab
    /// and the next save leaves a file behind, so the set is reconciled at launch
    /// rather than trusted to stay in step
    static func sweep(keeping ids: Set<UUID>) {
        guard
            let files = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)
        else { return }
        for url in files where url.pathExtension == "state" {
            let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent)
            if id == nil || !ids.contains(id!) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    /// used by Clear Browsing Data: these blobs hold form contents and history
    static func removeAll() {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}
