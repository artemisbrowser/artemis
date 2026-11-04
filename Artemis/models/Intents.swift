// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import AppIntents
import AppKit

// Shortcuts, Siri, Spotlight and Focus actions. Each runs the same model
// operation its AppleScript counterpart does, and none can reach incognito.

enum IntentFailure: Error, CustomLocalizedStringResourceConvertible {
    case noWindow, unsupportedURL, notFound, locked

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .noWindow: "No Artemis window is open."
        case .unsupportedURL: "Artemis only opens web and file addresses."
        case .notFound: "Artemis couldn't find that."
        case .locked: "That space is locked."
        }
    }
}

/// the front browser window, waiting out the launch an intent may have caused
@MainActor private func frontBrowser() async throws -> TabManager {
    for _ in 0..<60 {
        if let manager = BrowserWindows.shared.browserScope { return manager }
        try await Task.sleep(for: .milliseconds(50))
    }
    throw IntentFailure.noWindow
}

@MainActor private func live(_ entity: TabEntity) throws -> BrowserTab {
    guard let tab = Scripting.tabs(incognito: false).first(where: { $0.id == entity.id }) else {
        throw IntentFailure.notFound
    }
    return tab
}

@MainActor private func live(_ entity: SpaceEntity) throws -> Space {
    guard let space = BrowserCore.shared.spaces.first(where: { $0.id == entity.id }) else {
        throw IntentFailure.notFound
    }
    guard !SpaceLock.shared.isLocked(space) else { throw IntentFailure.locked }
    return space
}

/// a new tab in front of `space` in its window
@MainActor private func openTab(_ url: URL?, in space: Space, of manager: TabManager) -> TabEntity {
    manager.selectSpace(space)
    let tab = manager.newTab(url: url, select: true, in: space)
    manager.revealTab(tab)
    return TabEntity(tab)
}

nonisolated private func checked(_ url: URL) throws -> URL {
    guard ["http", "https", "file"].contains(url.scheme?.lowercased()) else { throw IntentFailure.unsupportedURL }
    return url
}

struct OpenURLIntent: AppIntent {
    static let title: LocalizedStringResource = "Open URL"
    static let description = IntentDescription(
        "Opens a web page or local file in a new tab. It lands in the space you choose, or the one that suits it.")
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "URL") var url: URL
    @Parameter(title: "Space") var space: SpaceEntity?
    @Parameter(title: "Profile", description: "Opens in this profile's first space when no space is chosen.")
    var profile: ProfileEntity?
    @Parameter(title: "New Window", default: false) var newWindow: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$url)") {
            \.$space
            \.$profile
            \.$newWindow
        }
    }

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<TabEntity> {
        let url = try checked(url)
        var manager = try await frontBrowser()
        let destination: Space
        if let space {
            destination = try live(space)
        } else if let profile {
            guard let first = manager.spaces.first(where: { $0.profileID == profile.id }) else {
                throw IntentFailure.notFound
            }
            destination = first
        } else {
            destination = manager.preferredSpace(for: url)
        }
        guard !SpaceLock.shared.isLocked(destination) else { throw IntentFailure.locked }
        if newWindow {
            guard let made = await Scripting.openWindow(incognito: false, on: destination.id) else {
                throw IntentFailure.noWindow
            }
            manager = made
        } else if let own = Scripting.manager(for: destination) {
            manager = own
        }
        return .result(value: openTab(url, in: destination, of: manager))
    }
}

struct NewTabIntent: AppIntent {
    static let title: LocalizedStringResource = "New Tab in Space"
    static let description = IntentDescription("Opens a new tab in a space, on a page if you give one.")
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Space") var space: SpaceEntity
    @Parameter(title: "URL") var url: URL?

    static var parameterSummary: some ParameterSummary {
        Summary("New tab in \(\.$space)") { \.$url }
    }

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<TabEntity> {
        let url = try url.map(checked)
        let space = try live(space)
        guard let manager = Scripting.manager(for: space) else { throw IntentFailure.noWindow }
        return .result(value: openTab(url, in: space, of: manager))
    }
}

struct SwitchSpaceIntent: OpenIntent {
    static let title: LocalizedStringResource = "Switch to Space"
    static let description = IntentDescription("Shows a space in the front window.")
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Space") var target: SpaceEntity

    @MainActor func perform() async throws -> some IntentResult {
        let space = try live(target)
        guard let manager = Scripting.manager(for: space) else { throw IntentFailure.noWindow }
        manager.selectSpace(space)
        BrowserWindows.shared.window(of: manager)?.makeKeyAndOrderFront(nil)
        return .result()
    }
}

struct FindTabIntent: AppIntent {
    static let title: LocalizedStringResource = "Find Tab"
    static let description = IntentDescription("Finds the first open tab whose title or address contains the text.")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Text") var text: String
    @Parameter(title: "Space") var space: SpaceEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Find the tab matching \(\.$text)") { \.$space }
    }

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<TabEntity> {
        guard let tab = try await TabQuery().entities(matching: text).first(where: { space == nil || $0.space?.id == space?.id })
        else { throw IntentFailure.notFound }
        return .result(value: tab)
    }
}

struct ShowTabIntent: OpenIntent {
    static let title: LocalizedStringResource = "Show Tab"
    static let description = IntentDescription("Brings a tab to the front, switching to its space.")
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Tab") var target: TabEntity

    @MainActor func perform() async throws -> some IntentResult {
        let tab = try live(target)
        guard let manager = Scripting.manager(for: Scripting.space(of: tab)) else { throw IntentFailure.noWindow }
        manager.revealTab(tab)
        return .result()
    }
}

struct CloseTabIntent: AppIntent {
    static let title: LocalizedStringResource = "Close Tab"
    static let description = IntentDescription("Closes a tab. A closed pinned tab goes to the Library.")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Tab") var target: TabEntity

    static var parameterSummary: some ParameterSummary { Summary("Close \(\.$target)") }

    @MainActor func perform() async throws -> some IntentResult {
        let tab = try live(target)
        Scripting.manager(for: Scripting.space(of: tab))?.close(tab)
        return .result()
    }
}

struct GetCurrentPageIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Current Page"
    static let description = IntentDescription(
        "Returns the page's title, address and text as Markdown. Without a tab it reads the front window's page.")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Tab") var tab: TabEntity?

    static var parameterSummary: some ParameterSummary { Summary("Get the page in \(\.$tab)") }

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<PageEntity> {
        let page: BrowserTab
        if let tab {
            page = try live(tab)
        } else {
            guard let selected = try await frontBrowser().selectedTab,
                Scripting.tabs(incognito: false).contains(where: { $0 === selected })
            else { throw IntentFailure.notFound }
            page = selected
        }
        await page.wake()
        // again once awake: the wake can take 15 s, and the space may lock meanwhile
        guard Scripting.tabs(incognito: false).contains(where: { $0 === page }) else { throw IntentFailure.notFound }
        return .result(value: await PageEntity(page))
    }
}

struct SearchHistoryIntent: AppIntent {
    static let title: LocalizedStringResource = "Search History"
    static let description = IntentDescription("Finds pages you've visited whose title or address matches.")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Text") var text: String
    @Parameter(title: "Profile") var profile: ProfileEntity?
    @Parameter(title: "Limit", default: 20) var limit: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Search history for \(\.$text)") {
            \.$profile
            \.$limit
        }
    }

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<[HistoryEntryEntity]> {
        let profiles = BrowserCore.shared.profiles.filter { profile == nil || $0.id == profile?.id }
        let found = HistoryStore.search(text, in: profiles.map(\.history), limit: max(limit, 0))
        return .result(value: found.map(HistoryEntryEntity.init))
    }
}

struct OpenIncognitoWindowIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Incognito Window"
    static let description = IntentDescription("Opens a new incognito window.")
    static let supportedModes: IntentModes = .foreground

    @MainActor func perform() async throws -> some IntentResult {
        _ = try await frontBrowser()
        guard await Scripting.openWindow(incognito: true) != nil else { throw IntentFailure.noWindow }
        return .result()
    }
}

/// While a Focus is on, the front window shows its space. When it ends the
/// window goes back, unless you've moved space since.
struct SpaceFocusFilter: SetFocusFilterIntent {
    static let title: LocalizedStringResource = "Set Space"
    static let description = IntentDescription(
        "Switches the front window to a space while this Focus is on. A profile picks its first space.")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Space") var space: SpaceEntity?
    @Parameter(title: "Profile") var profile: ProfileEntity?

    /// the window switched, the space it left and the space it went to
    @MainActor private static var applied: (window: ObjectIdentifier, from: Space.ID, to: Space.ID)?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(space?.name ?? profile?.name ?? "No space")")
    }

    @MainActor func perform() async throws -> some IntentResult {
        let windows = BrowserWindows.shared
        guard space != nil || profile != nil else {
            if let applied = Self.applied,
                let manager = windows.mainManagers.first(where: { ObjectIdentifier($0) == applied.window }),
                manager.selectedSpaceID == applied.to,
                let previous = manager.spaces.first(where: { $0.id == applied.from })
            {
                manager.selectSpace(previous)
            }
            Self.applied = nil
            return .result()
        }
        let manager = try await frontBrowser()
        guard
            let target = space.flatMap({ space in manager.spaces.first { $0.id == space.id } })
                ?? profile.flatMap({ profile in manager.spaces.first { $0.profileID == profile.id } })
        else { throw IntentFailure.notFound }
        // a Focus edited while on keeps the space it first left
        let from = Self.applied.flatMap { $0.window == ObjectIdentifier(manager) ? $0.from : nil }
        Self.applied = (ObjectIdentifier(manager), from ?? manager.selectedSpaceID, target.id)
        manager.selectSpace(target)
        return .result()
    }
}

struct ArtemisShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SwitchSpaceIntent(),
            phrases: [
                "Switch to \(\.$target) in \(.applicationName)",
                "Go to my \(\.$target) space in \(.applicationName)",
                "Switch spaces in \(.applicationName)",
            ],
            shortTitle: "Switch to Space", systemImageName: "square.stack")
        AppShortcut(
            intent: NewTabIntent(),
            phrases: [
                "New \(.applicationName) tab in \(\.$space)",
                "Open a new tab in \(.applicationName)",
            ],
            shortTitle: "New Tab", systemImageName: "plus.square.on.square")
        AppShortcut(
            intent: OpenURLIntent(),
            phrases: ["Open a link in \(.applicationName)", "Open a page in \(.applicationName)"],
            shortTitle: "Open URL", systemImageName: "safari")
        AppShortcut(
            intent: FindTabIntent(),
            phrases: ["Find a tab in \(.applicationName)", "Find an \(.applicationName) tab"],
            shortTitle: "Find Tab", systemImageName: "magnifyingglass")
        AppShortcut(
            intent: GetCurrentPageIntent(),
            phrases: [
                "Get the current page from \(.applicationName)",
                "Get this page's text from \(.applicationName)",
            ],
            shortTitle: "Get Current Page", systemImageName: "doc.text")
        AppShortcut(
            intent: SearchHistoryIntent(),
            phrases: ["Search \(.applicationName) history", "Search my history in \(.applicationName)"],
            shortTitle: "Search History", systemImageName: "clock.arrow.circlepath")
        AppShortcut(
            intent: OpenIncognitoWindowIntent(),
            phrases: [
                "Open an incognito window in \(.applicationName)",
                "Open a private window in \(.applicationName)",
            ],
            shortTitle: "Incognito Window", systemImageName: "eyeglasses")
    }
}
