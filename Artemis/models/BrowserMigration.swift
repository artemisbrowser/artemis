import AppKit
import UniformTypeIdentifiers

/// The import sheet's state: which browser profile, what to take from it,
/// which profile here it lands in, and how it went.
@MainActor
@Observable
final class BrowserImportModel {
    struct Selection {
        var bookmarks = true
        var history = true
        var workspaces = true
    }

    enum Phase: Equatable {
        case choosing
        case working(String)
        case done([String])
    }

    let sources: [BrowserImport.Source]
    /// Arc's data is on this Mac, so its own importer is offered beside the rest
    let offersArc: Bool
    private(set) var source: BrowserImport.Source?
    /// nil while the chosen source is being read
    private(set) var survey: BrowserImport.Survey?
    var selection = Selection()
    /// an exported password CSV to bring along
    var passwordFile: URL?
    var profileID: Profile.ID
    var phase: Phase = .choosing

    init(sources: [BrowserImport.Source], offersArc: Bool, profileID: Profile.ID) {
        self.sources = sources
        self.offersArc = offersArc
        self.profileID = profileID
    }

    /// File ▸ Import from Browser…, the command bar, and General settings
    static func open(in manager: TabManager) {
        guard manager.browserImport == nil else { return }
        let target = manager.currentProfile.id
        Task {
            let home = ArcImport.home
            let sources = await Task.detached { BrowserImport.detect(home: home) }.value
            guard manager.browserImport == nil else { return }
            let model = BrowserImportModel(
                sources: sources, offersArc: ArcImport.isReadable(), profileID: target)
            manager.browserImport = model
            if let first = sources.first { model.choose(first) }
        }
    }

    func choose(_ source: BrowserImport.Source) {
        guard phase == .choosing else { return }
        self.source = source
        survey = nil
        passwordFile = nil
        Task {
            let read = await Task.detached { BrowserImport.survey(source) }.value
            guard self.source == source else { return }
            survey = read
        }
    }

    /// Safari's bookmarks without Full Disk Access: the HTML file its File menu exports
    func chooseExportedBookmarks() {
        let panel = NSOpenPanel()
        panel.message = "Choose the bookmarks file Safari exported."
        panel.directoryURL = Self.downloads
        panel.allowedContentTypes = [.html]
        guard panel.runModal() == .OK, let url = panel.url,
            let parsed = (try? Data(contentsOf: url)).flatMap(BookmarkImport.parse)
        else { return }
        survey?.bookmarks = parsed
        selection.bookmarks = true
    }

    func choosePasswordFile() {
        let panel = NSOpenPanel()
        panel.message = "Choose the passwords CSV you exported."
        panel.directoryURL = Self.downloads
        panel.allowedContentTypes = [.commaSeparatedText]
        if panel.runModal() == .OK { passwordFile = panel.url }
    }

    private static var downloads: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].resolvingSymlinksInPath()
    }

    var canImport: Bool {
        guard phase == .choosing, let survey else { return false }
        return (selection.bookmarks && survey.bookmarks != nil)
            || (selection.history && !survey.history.isEmpty)
            || (selection.workspaces && survey.workspaces != nil)
            || passwordFile != nil
    }

    func cancel(in manager: TabManager) {
        if case .working = phase { return }
        manager.browserImport = nil
    }

    func run(into manager: TabManager) {
        guard canImport else { return }
        Task { await perform(into: manager) }
    }

    func perform(into manager: TabManager) async {
        guard canImport, let survey else { return }
        let profile = manager.core.profile(profileID) ?? manager.core.defaultProfile
        var landed: [String] = []

        if selection.workspaces, let workspaces = survey.workspaces {
            phase = .working("Workspaces…")
            landed.append(land(workspaces, from: "workspaces", into: profile, manager: manager))
        }
        if selection.bookmarks, let bookmarks = survey.bookmarks {
            phase = .working("Bookmarks…")
            landed.append(land(bookmarks, from: "bookmarks", into: profile, manager: manager))
        }
        if selection.history, !survey.history.isEmpty {
            phase = .working("History…")
            let added = profile.history.merge(survey.history)
            landed.append(added == 0 ? "History was already here" : "\(Self.count(added, "page")) of history")
        }
        if let passwordFile {
            phase = .working("Passwords…")
            let text = (try? String(contentsOf: passwordFile, encoding: .utf8))
                ?? (try? String(contentsOf: passwordFile, encoding: .isoLatin1))
            if let text, let summary = await PasswordStore.shared.importCSV(text, into: profile.id) {
                let taken = summary.added + summary.updated
                landed.append(taken == 0 ? "No new passwords" : "\(Self.count(taken, "password")). Now delete the CSV file")
            } else {
                landed.append("No passwords came in. That file isn't a passwords CSV")
            }
        }
        phase = .done(landed)
    }

    /// what one translation added, counted from the profile before and after
    private func land(
        _ result: BookmarkImport.Result, from what: String, into profile: Profile, manager: TabManager
    ) -> String {
        func tally() -> (spaces: Int, pins: Int, favourites: Int) {
            let mine = manager.spaces.filter { $0.profileID == profile.id }
            return (mine.count, mine.reduce(0) { $0 + $1.pinnedTabs.count }, profile.essentials.count)
        }
        let before = tally()
        manager.importBookmarks(result, into: profile.id)
        let after = tally()
        var parts: [String] = []
        if after.spaces > before.spaces { parts.append(Self.count(after.spaces - before.spaces, "space")) }
        if after.pins > before.pins { parts.append(Self.count(after.pins - before.pins, "pinned tab")) }
        if after.favourites > before.favourites {
            parts.append(Self.count(after.favourites - before.favourites, "favourite"))
        }
        return parts.isEmpty ? "Your \(what) were already here" : parts.joined(separator: ", ")
    }

    static func count(_ n: Int, _ noun: String) -> String {
        "\(n.formatted(.number.grouping(.automatic))) \(noun)\(n == 1 ? "" : "s")"
    }
}
