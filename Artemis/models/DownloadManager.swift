// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import AppKit
import SwiftUI
import WebKit

/// a single in-flight or completed download
@Observable
final class DownloadItem: NSObject, Identifiable {
    enum State {
        case downloading, finished, failed, cancelled
    }

    let id = UUID()
    private(set) var filename = "Download"
    private(set) var state: State = .downloading
    private(set) var fractionCompleted: Double = 0
    private(set) var destination: URL?
    private(set) var errorText: String?

    /// from an incognito window: shown as "Private download", never by name
    let isPrivate: Bool
    /// never started: the site's Downloads setting is Block
    let isBlocked: Bool

    @ObservationIgnored private var download: WKDownload?
    @ObservationIgnored private var progressObservation: NSKeyValueObservation?
    /// the name the requester chose, over the one the response suggests
    @ObservationIgnored private let preferredFilename: String?
    /// where WebKit writes until the download finishes: `name.download`, so Finder,
    /// Spotlight and launchers never offer a half-written file under its real name
    @ObservationIgnored private var partial: URL?
    /// `destination` came from a save panel, which has already confirmed replacing a file there
    @ObservationIgnored private var replacesDestination = false

    init(download: WKDownload, filename: String? = nil) {
        self.download = download
        preferredFilename = filename
        isPrivate = download.webView.map { !$0.configuration.websiteDataStore.isPersistent } ?? false
        isBlocked = false
        super.init()
        download.delegate = self
        // whole percents only: every view showing progress redraws per update
        var sent = -1.0
        progressObservation = download.progress.observe(
            \.fractionCompleted, options: [.initial, .new]
        ) { [weak self] progress, _ in
            let fraction = progress.fractionCompleted
            guard fraction - sent >= 0.01 || fraction >= 1 else { return }
            sent = fraction
            DispatchQueue.main.async {
                self?.fractionCompleted = fraction
            }
        }
    }

    init(blocked filename: String, isPrivate: Bool) {
        if !filename.isEmpty { self.filename = filename }
        preferredFilename = nil
        self.isPrivate = isPrivate
        isBlocked = true
        state = .failed
        super.init()
    }

    /// a file the app wrote itself, such as the PDF viewer's save, or failed to write with `error`
    init(saved file: URL, isPrivate: Bool, error: Error? = nil) {
        filename = file.lastPathComponent
        destination = error == nil ? file : nil
        state = error == nil ? .finished : .failed
        fractionCompleted = error == nil ? 1 : 0
        errorText = error?.localizedDescription
        preferredFilename = nil
        self.isPrivate = isPrivate
        isBlocked = false
        super.init()
    }

    func cancel() {
        download?.cancel()
        state = .cancelled
        discardPartial()
        DownloadManager.shared.changed(self)
    }

    func open() {
        guard state == .finished, let destination else { return }
        NSWorkspace.shared.open(destination)
    }

    /// marks a finished download as a web download, as Safari does, so Gatekeeper
    /// checks an app inside it before it first runs. LaunchServices logs `source`
    /// in a database that outlives the file, so a private download passes none
    nonisolated static func quarantine(_ file: URL, from source: URL?) {
        var properties: [String: Any] = [
            kLSQuarantineAgentNameKey as String: "Artemis",
            kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload as String,
        ]
        if let source { properties[kLSQuarantineDataURLKey as String] = source }
        var values = URLResourceValues()
        values.quarantineProperties = properties
        var file = file
        do { try file.setResourceValues(values) } catch { debugLog("download quarantine failed: \(error)") }
    }

    private func discardPartial() {
        if let partial { try? FileManager.default.removeItem(at: partial) }
        partial = nil
    }

    func revealInFinder() {
        guard let destination else { return }
        NSWorkspace.shared.activateFileViewerSelecting([destination])
    }

    /// moves a finished `partial` to `destination`, over a file already there when `replacing`, else to a
    /// numbered sibling, since another download may have taken the name meanwhile
    static func place(_ partial: URL, at destination: URL, replacing: Bool) throws -> URL {
        guard replacing, FileManager.default.fileExists(atPath: destination.path) else {
            let target = uniqueURL(for: destination)
            try FileManager.default.moveItem(at: partial, to: target)
            return target
        }
        return try FileManager.default.replaceItemAt(destination, withItemAt: partial) ?? destination
    }

    /// `url`, or a numbered sibling of it: never a file that's already there
    static func uniqueURL(for url: URL) -> URL {
        var candidate = url
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(base) (\(counter))" : "\(base) (\(counter)).\(ext)"
            candidate = url.deletingLastPathComponent().appendingPathComponent(name)
            counter += 1
        }
        return candidate
    }
}

// MARK: - WKDownloadDelegate

extension DownloadItem: WKDownloadDelegate {
    /// a cancelled save panel cancels the download. must stay the completion-handler form: WebKit
    /// never calls the async one
    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping (URL?) -> Void
    ) {
        Self.chooseDestination(for: preferredFilename ?? suggestedFilename, in: download.webView?.window) {
            [weak self] url, picked in
            guard let self, let url else { return completionHandler(nil) }
            replacesDestination = picked
            start(at: url, download, completionHandler)
        }
    }

    /// a non-clashing name in the chosen folder, or where a save panel says when asking each time,
    /// `picked` then meaning the panel already confirmed replacing; nil when the panel is cancelled
    static func chooseDestination(
        for name: String, in window: NSWindow?, _ chosen: @escaping (URL?, _ picked: Bool) -> Void
    ) {
        // WebKit writing to ~/Downloads raises a Downloads folder prompt for a lab copy,
        // and the download waits on its answer
        let folder = SelfTest.isRequested ? FileManager.default.temporaryDirectory : DownloadManager.folder
        guard DownloadManager.asksEachTime, !SelfTest.isRequested else {
            return chosen(uniqueURL(for: folder.appendingPathComponent(name)), false)
        }
        let panel = NSSavePanel()
        panel.directoryURL = folder
        panel.nameFieldStringValue = name
        let answered: (NSApplication.ModalResponse) -> Void = { chosen($0 == .OK ? panel.url : nil, true) }
        // a sheet on the page's window can't open behind it or on another Space
        if let window, window.attachedSheet == nil {
            panel.beginSheetModal(for: window, completionHandler: answered)
        } else {
            panel.begin(completionHandler: answered)
        }
    }

    private func start(at url: URL, _ download: WKDownload, _ completionHandler: @escaping (URL?) -> Void) {
        DownloadFlight.launch(filename: url.lastPathComponent, from: download.webView)

        filename = url.lastPathComponent
        destination = url
        let partial = Self.uniqueURL(for: url.appendingPathExtension("download"))
        self.partial = partial
        debugLog("download destination chosen: \(url.path)")
        completionHandler(partial)
    }

    func downloadDidFinish(_ download: WKDownload) {
        if let partial, let destination {
            do {
                let target = try Self.place(partial, at: destination, replacing: replacesDestination)
                self.destination = target
                filename = target.lastPathComponent
                Self.quarantine(target, from: isPrivate ? nil : download.originalRequest?.url)
            } catch {
                self.destination = partial
                filename = partial.lastPathComponent
                debugLog("download rename failed: \(error)")
            }
            self.partial = nil
        }
        state = .finished
        DownloadManager.shared.changed(self)
        debugLog("download finished: \(filename)")
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        debugLog("download FAILED: \(error as NSError) userInfo: \((error as NSError).userInfo)")
        discardPartial()

        // a -999 we didn't ask for is WebKit dropping a duplicate of another download
        if (error as NSError).code == NSURLErrorCancelled, state != .cancelled {
            DownloadManager.shared.remove(self)
            return
        }

        state = .failed
        errorText = error.localizedDescription
        DownloadManager.shared.changed(self)
        // the description can name the file, so only the code is kept
        Diagnostics.record(
            area: "downloads",
            message: "download failed: \((error as NSError).domain) \((error as NSError).code)",
            level: .warning,
            inPrivate: download.webView.map { !$0.configuration.websiteDataStore.isPersistent } ?? false)
    }
}

/// owns all downloads for the app
@Observable
final class DownloadManager {
    static let shared = DownloadManager()
    /// a folder path the user picked; absent means ~/Downloads
    static let folderKey = "downloadsFolder"
    static let asksEachTimeKey = "downloadsAskEachTime"

    /// the picked folder while it is a writable directory, else ~/Downloads
    static var folder: URL {
        var isDirectory: ObjCBool = false
        guard let path = UserDefaults.standard.string(forKey: folderKey), !path.isEmpty,
            FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue,
            FileManager.default.isWritableFile(atPath: path)
        else { return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0] }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
    static var asksEachTime: Bool { UserDefaults.standard.bool(forKey: asksEachTimeKey) }

    private(set) var items: [DownloadItem] = []

    var hasActiveDownloads: Bool {
        items.contains { $0.state == .downloading }
    }

    /// what the sidebar's download pill shows: running and failed downloads, and
    /// finished ones for a few seconds
    private(set) var shelf: [DownloadItem] = []

    /// the share of everything on the shelf still running that has arrived
    var fraction: Double {
        let running = shelf.filter { $0.state == .downloading }
        guard !running.isEmpty else { return 1 }
        return running.map(\.fractionCompleted).reduce(0, +) / Double(running.count)
    }

    func register(_ download: WKDownload, filename: String? = nil) {
        debugLog("download registered: \(download.originalRequest?.url?.absoluteString ?? "nil")")
        let item = DownloadItem(download: download, filename: filename)
        items.insert(item, at: 0)
        shelf.insert(item, at: 0)
        updateDock()
    }

    /// the PDF viewer's save: a file the page already holds, written where a download would go
    func save(_ data: Data, as name: String, from source: URL?, in webView: WKWebView) {
        let isPrivate = !webView.configuration.websiteDataStore.isPersistent
        DownloadItem.chooseDestination(for: name.isEmpty ? "Download" : name, in: webView.window) { [weak self] url, _ in
            guard let self, let url else { return }
            let source = isPrivate ? nil : source
            Task {
                // off main: a network or iCloud volume can take seconds
                let error = await Task.detached { () -> Error? in
                    do {
                        try data.write(to: url, options: .atomic)
                        DownloadItem.quarantine(url, from: source)
                        return nil
                    } catch { return error }
                }.value
                if error == nil { DownloadFlight.launch(filename: url.lastPathComponent, from: webView) }
                let item = DownloadItem(saved: url, isPrivate: isPrivate, error: error)
                self.items.insert(item, at: 0)
                self.shelf.insert(item, at: 0)
                self.changed(item)
            }
        }
    }

    /// a download the site's Block setting stopped, shown on the shelf as blocked
    func refuse(_ filename: String, isPrivate: Bool) {
        let item = DownloadItem(blocked: filename, isPrivate: isPrivate)
        items.insert(item, at: 0)
        shelf.insert(item, at: 0)
    }

    /// everything but what's still running, from the Library and the sidebar's shelf
    func clearFinished() {
        items.removeAll { $0.state != .downloading }
        shelf.removeAll { $0.state != .downloading }
    }

    func remove(_ item: DownloadItem) {
        items.removeAll { $0.id == item.id }
        dismiss(item)
    }

    func dismiss(_ item: DownloadItem) {
        shelf.removeAll { $0.id == item.id }
        updateDock()
    }

    /// a download finished, failed or was cancelled
    func changed(_ item: DownloadItem) {
        switch item.state {
        case .cancelled:
            dismiss(item)
        case .finished:
            updateDock()
            if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
            Task {
                try? await Task.sleep(for: .seconds(5))
                dismiss(item)
            }
        case .failed, .downloading:
            updateDock()
        }
    }

    /// the Dock icon counts what's still arriving
    private func updateDock() {
        let running = shelf.filter { $0.state == .downloading }.count
        NSApp.dockTile.badgeLabel = running > 0 ? "\(running)" : nil
    }
}
