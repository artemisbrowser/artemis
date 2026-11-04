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

    /// a better name worked out on-device from the source page: offered, and
    /// applied only by `applySuggestedName`
    private(set) var suggestedName: String?
    /// what it was called before you accepted a suggestion, so it can go back
    private(set) var previousName: String?

    /// from an incognito window: shown as "Private download", never by name
    let isPrivate: Bool

    /// the page this came from, which is the only real clue to what the file is
    @ObservationIgnored let sourceTitle: String
    @ObservationIgnored let sourceHost: String

    @ObservationIgnored private var download: WKDownload?
    @ObservationIgnored private var progressObservation: NSKeyValueObservation?
    /// the name the requester chose, over the one the response suggests
    @ObservationIgnored private let preferredFilename: String?
    /// where WebKit writes until the download finishes: `name.download`, so Finder,
    /// Spotlight and launchers never offer a half-written file under its real name
    @ObservationIgnored private var partial: URL?

    init(
        download: WKDownload, sourceTitle: String = "", sourceHost: String = "",
        filename: String? = nil
    ) {
        self.download = download
        self.sourceTitle = sourceTitle
        self.sourceHost = sourceHost
        preferredFilename = filename
        isPrivate = download.webView.map { !$0.configuration.websiteDataStore.isPersistent } ?? false
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
    /// checks an app inside it before it first runs
    private func quarantine(_ file: URL, from source: URL?) {
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

    // MARK: - Suggested name

    /// ask the on-device model what this file should be called
    @MainActor
    func proposeName() {
        guard Intelligence.isOn(Intelligence.tidyDownloadsKey), Intelligence.isReady,
            !sourceTitle.isEmpty, state == .finished
        else { return }
        let current = filename
        Task { [weak self] in
            guard let name = await Intelligence.shared.filename(
                for: current, pageTitle: sourceTitle, host: sourceHost)
            else { return }
            guard let self, name != current else { return }
            suggestedName = name
        }
    }

    /// the only place a suggestion moves the file
    func applySuggestedName() {
        guard let suggestedName, let destination else { return }
        let target = Self.uniqueURL(for: destination.deletingLastPathComponent()
            .appendingPathComponent(suggestedName))
        do {
            try FileManager.default.moveItem(at: destination, to: target)
            previousName = filename
            self.destination = target
            filename = target.lastPathComponent
            self.suggestedName = nil
        } catch {
            debugLog("download rename failed: \(error)")
            self.suggestedName = nil
        }
    }

    /// move it back to the name it had before `applySuggestedName`
    func undoRename() {
        guard let previousName, let destination else { return }
        let target = Self.uniqueURL(for: destination.deletingLastPathComponent()
            .appendingPathComponent(previousName))
        guard (try? FileManager.default.moveItem(at: destination, to: target)) != nil else { return }
        self.destination = target
        filename = target.lastPathComponent
        self.previousName = nil
    }

    func dismissSuggestion() {
        suggestedName = nil
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
    /// picks a non-clashing destination in ~/Downloads. must stay the
    /// completion-handler form: WebKit never calls the async one
    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping (URL?) -> Void
    ) {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let url = Self.uniqueURL(
            for: downloads.appendingPathComponent(preferredFilename ?? suggestedFilename))
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
            // another download may have taken the name meanwhile
            let target = Self.uniqueURL(for: destination)
            do {
                try FileManager.default.moveItem(at: partial, to: target)
                self.destination = target
                filename = target.lastPathComponent
                quarantine(target, from: download.originalRequest?.url)
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
        Task { @MainActor in proposeName() }
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

    func register(
        _ download: WKDownload, sourceTitle: String = "", sourceHost: String = "",
        filename: String? = nil
    ) {
        debugLog("download registered: \(download.originalRequest?.url?.absoluteString ?? "nil")")
        let item = DownloadItem(
            download: download, sourceTitle: sourceTitle, sourceHost: sourceHost, filename: filename)
        items.insert(item, at: 0)
        shelf.insert(item, at: 0)
        updateDock()
    }

    func clearFinished() {
        items.removeAll { $0.state != .downloading }
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
