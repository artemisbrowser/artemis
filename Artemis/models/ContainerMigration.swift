import Foundation

/// Artemis ran in the App Sandbox until 0.9.0, so its data sits in the app's
/// container. The first run outside it copies that data to where an unsandboxed
/// app keeps it; the container stays untouched as a backup.
nonisolated enum ContainerMigration {
    /// runs before anything reads settings or stores: the first stored property of ArtemisApp
    static func run() {
        guard !AppStorageLocation.isContainerised, let id = Bundle.main.bundleIdentifier else { return }
        let fm = FileManager.default
        let library = URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Library")
        let old = library.appending(path: "Containers/\(id)/Data/Library")
        let folder = AppStorageLocation.folderName
        // not AppStorageLocation.directory: reading that creates the folder this replaces
        let support = library.appending(path: "Application Support/\(folder)")
        let marker = support.appending(path: ".from-container")
        guard fm.fileExists(atPath: old.path), !fm.fileExists(atPath: marker.path) else { return }
        // unreadable (App Data protection refused): try again next launch rather than mark it done
        guard let entries = try? fm.contentsOfDirectory(atPath: old.path), !entries.isEmpty else {
            debugLog("container migration: container unreadable")
            return
        }

        let stamp = Int(Date().timeIntervalSince1970)
        for (from, target) in [
            ("Application Support/Artemis", support),
            ("WebKit", library.appending(path: "WebKit/\(id)")),
            ("Caches/Artemis", library.appending(path: "Caches/\(folder)")),
        ] {
            let source = old.appending(path: from)
            guard fm.fileExists(atPath: source.path) else { continue }
            do {
                if fm.fileExists(atPath: target.path) {
                    try fm.moveItem(at: target, to: target.appendingPathExtension("pre-container-\(stamp)"))
                }
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: source, to: target)
                debugLog("container migration: copied \(from)")
            } catch {
                debugLog("container migration: \(from) failed: \(error)")
                return
            }
        }

        if let settings = NSDictionary(contentsOf: old.appending(path: "Preferences/\(id).plist")) as? [String: Any] {
            UserDefaults.standard.setPersistentDomain(settings, forName: id)
            debugLog("container migration: copied \(settings.count) settings")
        }
        try? fm.createDirectory(at: support, withIntermediateDirectories: true)
        fm.createFile(atPath: marker.path, contents: Data())
    }
}
