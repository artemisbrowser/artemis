import AppIntents
import AppKit
import CoreSpotlight
import CoreTransferable
import SwiftUI
import WebKit

// What Shortcuts, Siri and Spotlight can name. Built from `Scripting`'s view
// with incognito always excluded, so these never reach a private window or page.

struct ProfileEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Profile"
    static let defaultQuery = ProfileQuery()

    let id: UUID
    @Property(title: "Name") var name: String
    private let icon: String
    private let image: DisplayRepresentation.Image?

    @MainActor init(_ profile: Profile) {
        id = profile.id
        icon = profile.icon
        image = profile.icon.isEmojiIcon ? nil : .init(systemName: profile.icon)
        name = profile.name
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: image == nil ? "\(icon) \(name)" : "\(name)", image: image)
    }
}

struct ProfileQuery: EntityStringQuery, EnumerableEntityQuery {
    @MainActor func entities(for identifiers: [UUID]) async throws -> [ProfileEntity] {
        try await allEntities().filter { identifiers.contains($0.id) }
    }

    @MainActor func entities(matching string: String) async throws -> [ProfileEntity] {
        try await allEntities().filter { $0.name.localizedStandardContains(string) }
    }

    @MainActor func allEntities() async throws -> [ProfileEntity] { BrowserCore.shared.profiles.map(ProfileEntity.init) }
}

struct SpaceEntity: IndexedEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Space"
    static let defaultQuery = SpaceQuery()

    let id: UUID
    @Property(title: "Name") var name: String
    /// an SF Symbol name or an emoji
    @Property(title: "Icon") var icon: String
    /// the space's accent as `#RRGGBB`
    @Property(title: "Colour") var colour: String
    @Property(title: "Profile") var profile: ProfileEntity
    private let image: DisplayRepresentation.Image?

    @MainActor init(_ space: Space) {
        id = space.id
        image = space.icon.isEmojiIcon ? nil : .init(systemName: space.icon)
        name = space.name
        icon = space.icon
        let rgb = NSColor(space.appearance.accent).usingColorSpace(.sRGB) ?? .white
        colour = String(
            format: "#%02X%02X%02X", Int(rgb.redComponent * 255), Int(rgb.greenComponent * 255),
            Int(rgb.blueComponent * 255))
        profile = ProfileEntity(BrowserCore.shared.profile(of: space))
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: image == nil ? "\(icon) \(name)" : "\(name)", subtitle: "\(profile.name)", image: image)
    }
}

struct SpaceQuery: EntityStringQuery, EnumerableEntityQuery {
    @MainActor func entities(for identifiers: [UUID]) async throws -> [SpaceEntity] {
        try await allEntities().filter { identifiers.contains($0.id) }
    }

    @MainActor func entities(matching string: String) async throws -> [SpaceEntity] {
        try await allEntities().filter { $0.name.localizedStandardContains(string) }
    }

    @MainActor func allEntities() async throws -> [SpaceEntity] { Scripting.spaces(incognito: false).map(SpaceEntity.init) }
}

struct TabEntity: IndexedEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Tab"
    static let defaultQuery = TabQuery()

    /// the tab's own id, kept across relaunches
    let id: UUID
    @Property(title: "Title") var title: String
    @Property(title: "URL") var url: URL?
    /// nil for a favourite, which belongs to a profile rather than a space
    @Property(title: "Space") var space: SpaceEntity?

    @MainActor init(_ tab: BrowserTab) {
        id = tab.id
        title = tab.displayTitle
        url = tab.url ?? tab.pendingURL ?? tab.lastAttemptedURL
        space = Scripting.space(of: tab).map(SpaceEntity.init)
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(url?.host() ?? space?.name ?? "")")
    }
}

struct TabQuery: EntityStringQuery {
    @MainActor func entities(for identifiers: [UUID]) async throws -> [TabEntity] {
        Scripting.tabs(incognito: false).filter { identifiers.contains($0.id) }.map(TabEntity.init)
    }

    /// tabs whose title or address holds `string`
    @MainActor func entities(matching string: String) async throws -> [TabEntity] {
        Scripting.tabs(incognito: false).map(TabEntity.init).filter {
            $0.title.localizedStandardContains(string)
                || $0.url?.absoluteString.localizedStandardContains(string) == true
        }
    }

    @MainActor func suggestedEntities() async throws -> [TabEntity] {
        guard let manager = BrowserWindows.shared.browserScope else { return [] }
        return (manager.essentials + Scripting.tabs(of: manager.currentSpace, incognito: false)).map(TabEntity.init)
    }
}

/// a page's words for Shortcuts and Apple Intelligence; as text it is the Markdown
struct PageEntity: TransientAppEntity, Transferable {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Page"
    static var transferRepresentation: some TransferRepresentation { ProxyRepresentation(exporting: \.markdown) }

    @Property(title: "Title") var title: String
    @Property(title: "URL") var url: URL?
    /// headed by the title; the article alone where Reader finds one, else all the page's text
    @Property(title: "Markdown") var markdown: String

    init() {}

    @MainActor init(_ tab: BrowserTab) async {
        title = tab.displayTitle
        url = tab.url
        let html = (try? await tab.webView.evaluateJavaScript("document.documentElement.outerHTML")) as? String
        let body =
            if let url, let html, let article = ReaderMode.extract(html: html, url: url) {
                ReaderMode.markdown(for: article)
            } else {
                await PageText.extract(from: tab.webView, minimum: 0) ?? ""
            }
        markdown = body.hasPrefix("# ") ? body : "# \(title)\n\n\(body)"
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(url?.absoluteString ?? "")")
    }
}

struct HistoryEntryEntity: TransientAppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "History Item"

    @Property(title: "Title") var title: String
    @Property(title: "URL") var url: URL
    @Property(title: "Last Visited") var lastVisited: Date

    init() {}

    init(_ entry: HistoryEntry) {
        title = entry.title
        url = entry.url
        lastVisited = entry.lastVisited
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(url.absoluteString)")
    }
}

/// Spotlight's copy of the spaces and their tabs, one domain per profile so a
/// profile goes in one call. Locked spaces, incognito and Scout stay out of it.
enum SpotlightIndex {
    static let enabledKey = "showsSpacesInSpotlight"
    static let enabledByDefault = false

    static var isEnabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? enabledByDefault }

    /// self-test and diagnostic runs never touch the user's Spotlight
    private static let isLab = SelfTest.isRequested || ProcessInfo.processInfo.environment["ARTEMIS_DIAG"] != nil

    enum Removal: Equatable {
        case items(Set<UUID>)
        case profile(Profile.ID)
        case everything
    }

    struct Entry: Equatable {
        let domain: String
        let content: String
    }

    /// where removals go; the self-test swaps it to read what was decided
    static var sink: (Removal) -> Void = { removal in
        guard !isLab else { return }
        Task { try? await apply(removal) }
    }

    private static var pending: Task<Void, Never>?
    /// what Spotlight holds, by id; nil until this launch has cleared the last one's
    private static var indexed: [UUID: Entry]?

    static func enabledDidChange() {
        if isEnabled {
            scheduleRefresh()
        } else {
            pending?.cancel()
            forget(.everything)
        }
    }

    static func scheduleRefresh() {
        guard !isLab, isEnabled else { return }
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            try? await refresh()
        }
    }

    /// forgotten now; a profile's spaces and tabs still open come back on the next refresh
    static func forget(_ removal: Removal) {
        switch removal {
        case .items(let ids): for id in ids { indexed?[id] = nil }
        case .profile(let id):
            indexed = indexed?.filter { $0.value.domain != id.uuidString }
            scheduleRefresh()
        case .everything: indexed = [:]
        }
        sink(removal)
    }

    /// what Spotlight should hold, each under its profile's domain
    static var entries: [(id: UUID, entity: any IndexedEntity, entry: Entry)] {
        func tab(_ tab: BrowserTab, in profile: Profile.ID) -> (UUID, any IndexedEntity, Entry) {
            let entity = TabEntity(tab)
            let content = "\(entity.title)\n\(entity.url?.absoluteString ?? "")\n\(entity.space?.name ?? "")"
            return (tab.id, entity, Entry(domain: profile.uuidString, content: content))
        }
        var out: [(id: UUID, entity: any IndexedEntity, entry: Entry)] = []
        for space in BrowserCore.shared.spaces where !space.requiresUnlock {
            let entity = SpaceEntity(space)
            let content = "\(entity.name)\n\(entity.icon)\n\(entity.colour)\n\(entity.profile.name)"
            out.append((space.id, entity, Entry(domain: space.profileID.uuidString, content: content)))
            out += space.tabs.filter { !$0.isPrivate }.map { tab($0, in: space.profileID) }
        }
        for profile in BrowserCore.shared.profiles {
            out += profile.essentials.filter { !$0.isPrivate }.map { tab($0, in: profile.id) }
        }
        return out
    }

    private static func refresh() async throws {
        guard isEnabled else { return }
        let index = CSSearchableIndex.default()
        if indexed == nil {
            try await index.deleteAllSearchableItems()
            indexed = [:]
        }
        let old = indexed ?? [:]
        var now: [UUID: Entry] = [:]
        var items: [CSSearchableItem] = []
        for (id, entity, entry) in entries {
            now[id] = entry
            guard old[id] != entry else { continue }
            let item = await CSSearchableItem(appEntity: entity)
            item.domainIdentifier = entry.domain
            items.append(item)
        }
        try await index.indexSearchableItems(items)
        try await apply(.items(Set(old.keys).subtracting(now.keys)))
        indexed = now
        ArtemisShortcuts.updateAppShortcutParameters()
    }

    private static func apply(_ removal: Removal) async throws {
        let index = CSSearchableIndex.default()
        switch removal {
        case .items(let ids):
            guard !ids.isEmpty else { return }
            try await index.deleteAppEntities(identifiedBy: Array(ids), ofType: SpaceEntity.self)
            try await index.deleteAppEntities(identifiedBy: Array(ids), ofType: TabEntity.self)
        case .profile(let id):
            try await index.deleteSearchableItems(withDomainIdentifiers: [id.uuidString])
        case .everything:
            try await index.deleteAllSearchableItems()
        }
    }
}
