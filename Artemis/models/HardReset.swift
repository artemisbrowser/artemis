// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import AppKit

/// Hard reset: everything Artemis keeps on this Mac is erased and it reopens as a fresh install.
/// The files go once the app has quit, so nothing it writes on the way out survives.
enum HardReset {
    /// what is Artemis' alone under `library`, ContainerMigration's backups of it included; nothing when a
    /// name is missing, since that would name a shared folder
    nonisolated static func paths(library: URL, folder: String, bundleID: String) -> [URL] {
        guard !folder.isEmpty, !bundleID.isEmpty else { return [] }
        let own = [
            "Application Support/\(folder)", "Caches/\(folder)", "Caches/\(bundleID)", "WebKit/\(bundleID)",
            "HTTPStorages/\(bundleID)", "HTTPStorages/\(bundleID).binarycookies",
        ].map { library.appending(path: $0) }
        let backups = own.flatMap { path in
            let prefix = "\(path.lastPathComponent).\(ContainerMigration.backup)", parent = path.deletingLastPathComponent()
            return ((try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? [])
                .filter { $0.hasPrefix(prefix) && $0.count > prefix.count && $0.dropFirst(prefix.count).allSatisfy { $0.isASCII && $0.isNumber } }
                .map { parent.appending(path: $0) }
        }
        return own + backups
    }

    /// the marker that stops ContainerMigration copying the old container back in on the next launch
    nonisolated static func marker(library: URL, folder: String) -> URL {
        library.appending(path: "Application Support/\(folder)/\(ContainerMigration.marker)")
    }

    /// a shell that outlives the app: once `pid` is gone it removes `paths` and the defaults `domain`,
    /// leaves an empty `marker`, then opens `app`
    @discardableResult
    nonisolated static func sweep(after pid: Int32, paths: [URL], marker: URL?, domain: String, reopening app: URL?) -> Process {
        let script = """
            while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
            sleep 0.5
            domain=$2; app=$3; marker=$4; shift 4
            for path; do rm -rf "$path"; done
            if [ -n "$domain" ]; then defaults delete "$domain" 2>/dev/null; fi
            if [ -n "$marker" ]; then mkdir -p "$(dirname "$marker")" && touch "$marker"; fi
            if [ -n "$app" ]; then open -n "$app"; fi
            """
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", script, "sh", String(pid), domain, app?.path ?? "", marker?.path ?? ""] + paths.map(\.path)
        try? shell.run()
        return shell
    }

    /// every service's items Hard Reset erases; the passwords and passkeys only when asked
    nonisolated static func eraseKeychain(passwords: Bool) {
        let services = [IntelligenceEngine.keychain, Keychain.cards] + (passwords ? [Keychain.passwords, Keychain.passkeys] : [])
        for service in services {
            for account in Keychain.accounts(service) { Keychain.delete(service, account) }
        }
    }

    static func ask() {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Erase everything and reset Artemis?"
        alert.informativeText =
            "Your spaces, tabs, history, profiles, extensions, website data and settings on this Mac are erased, and Artemis reopens as new. This can't be undone."
        let erase = alert.addButton(withTitle: "Erase and Reopen")
        erase.hasDestructiveAction = true
        // Return must not erase
        erase.keyEquivalent = ""
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Also erase saved passwords and passkeys"
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        PasswordStore.saveNow()
        eraseKeychain(passwords: alert.suppressionButton?.state == .on)
        for profile in BrowserCore.shared.profiles { ExtensionProxyBridge.saveCredentials(nil, profile.id) }
        let bundle = Bundle.main, library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let folder = AppStorageLocation.folderName, id = bundle.bundleIdentifier ?? ""
        sweep(
            after: ProcessInfo.processInfo.processIdentifier, paths: paths(library: library, folder: folder, bundleID: id),
            marker: folder.isEmpty ? nil : marker(library: library, folder: folder), domain: id, reopening: bundle.bundleURL)
        // not terminate: its saves would only write what the sweep is about to remove
        exit(0)
    }
}
