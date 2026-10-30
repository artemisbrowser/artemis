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

    /// A better name for this file, worked out on-device from the page it came
    /// from — offered, never applied. A browser that renames your files behind
    /// your back is a browser you stop trusting, and the model is occasionally
    /// wrong in ways only you can see.
    private(set) var suggestedName: String?
    /// what it was called before you accepted a suggestion, so it can go back
    private(set) var previousName: String?

    /// the page this came from, which is the only real clue to what the file is
    @ObservationIgnored let sourceTitle: String
    @ObservationIgnored let sourceHost: String

    @ObservationIgnored private var download: WKDownload?
    @ObservationIgnored private var progressObservation: NSKeyValueObservation?
    /// the name the requester chose, over the one the response suggests
    @ObservationIgnored private let preferredFilename: String?

    init(
        download: WKDownload, sourceTitle: String = "", sourceHost: String = "",
        filename: String? = nil
    ) {
        self.download = download
        self.sourceTitle = sourceTitle
        self.sourceHost = sourceHost
        preferredFilename = filename
        super.init()
        download.delegate = self
        progressObservation = download.progress.observe(
            \.fractionCompleted, options: [.initial, .new]
        ) { [weak self] progress, _ in
            let fraction = progress.fractionCompleted
            DispatchQueue.main.async {
                self?.fractionCompleted = fraction
            }
        }
    }

    func cancel() {
        download?.cancel()
        state = .cancelled
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
            // a suggestion identical to what it's already called is not a
            // suggestion, it's a notification
            guard let self, name != current else { return }
            suggestedName = name
        }
    }

    /// accept the suggestion: this is the only place the file actually moves
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

    /// put it back, for when the suggestion looked better than it was
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

        filename = url.lastPathComponent
        destination = url
        debugLog("download destination chosen: \(url.path)")
        completionHandler(url)
    }

    func downloadDidFinish(_ download: WKDownload) {
        state = .finished
        debugLog("download finished: \(filename)")
        Task { @MainActor in proposeName() }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        debugLog("download FAILED: \(error as NSError) userInfo: \((error as NSError).userInfo)")

        // -999 we didn't ask for = WebKit discarding a duplicate request
        // (sites often fire a navigation and a scripted fetch for one click);
        // safari hides these, so do we
        if (error as NSError).code == NSURLErrorCancelled, state != .cancelled {
            DownloadManager.shared.remove(self)
            return
        }

        state = .failed
        errorText = error.localizedDescription
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

    func register(
        _ download: WKDownload, sourceTitle: String = "", sourceHost: String = "",
        filename: String? = nil
    ) {
        debugLog("download registered: \(download.originalRequest?.url?.absoluteString ?? "nil")")
        items.insert(
            DownloadItem(
                download: download, sourceTitle: sourceTitle, sourceHost: sourceHost,
                filename: filename),
            at: 0)
    }

    func clearFinished() {
        items.removeAll { $0.state != .downloading }
    }

    func remove(_ item: DownloadItem) {
        items.removeAll { $0.id == item.id }
    }
}
