// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import SwiftUI

/// every setting the Settings search can find; each case marks its row with `.settingsAnchor`
nonisolated enum SettingID: String, CaseIterable, Sendable {
    case defaultBrowser
    case importBrowser
    case showOnboarding
    case updateChannel
    case autoUpdate
    case checkForUpdates
    case swipeNavigation
    case downloadsFolder
    case downloadsAsk
    case tabSleep
    case autoPictureInPicture
    case miniPlayerCorners
    case miniPlayerSkip
    case miniPlayerSiteButtons
    case edgeThickness
    case nowPlaying
    case folderSecondLine
    case folderTabCount
    case appIcon
    case profileList
    case profileName
    case searchEngine
    case searchSuggestions
    case archiveAfter
    case translateTo
    case translationRules
    case deleteProfile
    case savedPasswords
    case suggestedPasswords
    case leakCheck
    case offerToSavePasswords
    case fillPasswords
    case unlockPasswords
    case neverSaved
    case importExportPasswords
    case addresses
    case cards
    case fillAddresses
    case fillCards
    case offerToSaveAutofill
    case unlockCards
    case unlockAddresses
    case clearTimeRange
    case clearHistory
    case clearCookies
    case clearCache
    case clearArchive
    case clearPageText
    case clearAutofill
    case clearDownloads
    case clearZoom
    case clearPermissions
    case clearNow
    case blockAds
    case filterLists
    case updateBlocklists
    case incognitoTouchID
    case fingerprintDefence
    case sitePermissions
    case forgetAllSites
    case appleEventsJavaScript
    case incognitoAppleScript
    case spotlight
    case errorReports
    case sendFeedback
    case dataFolder
    case revealDelay
    case hoverArea
    case revealSpeed
    case spaceSwitchSpeed
    case pinnedSeparation
    case splitOffDestination
    case tabPreviews
    case previewSites
    case splitDirection
    case autoResizePanes
    case dimInactivePanes
    case linkedSplits
    case dropGuides
    case routingRules
    case describeRule
    case externalLinks
    case peekCorner
    case scoutFrame
    case bangs
    case indexPageText
    case eraseIndex
    case extensionsEnabled
    case boosts
    case installedExtensions
    case extensionStore
    case suggestedExtensions
    case extensionFromDisk
    case onDeviceModel
    case tidyTabNames
    case askAboutPage
    case agentsEnabled
    case agentSetup
    case agentSpaces
    case agentScripts
    case approvedAgents
    case connectedAgents
}

nonisolated struct SettingsEntry: Sendable {
    let pane: SettingsPane
    /// the profile page the row sits on, nil when it's on the pane itself
    var page: ProfilesNavigator.Page? = nil
    let title: String
    /// the visible section header above the row
    var section: String? = nil
    /// words a person might search for that the title doesn't say
    var keywords: [String] = []
}

nonisolated extension SettingID {
    var entry: SettingsEntry {
        switch self {
        case .defaultBrowser:
            SettingsEntry(
                pane: .general, title: "Make Artemis Your Default Browser", section: "Default Browser",
                keywords: ["default app", "link handler", "set as default"])
        case .importBrowser:
            SettingsEntry(
                pane: .general, title: "Import from another browser",
                keywords: ["arc", "chrome", "safari", "bookmarks", "migrate"])
        case .showOnboarding:
            SettingsEntry(pane: .general, title: "Show onboarding", keywords: ["intro", "welcome", "setup", "first run", "tour"])
        case .updateChannel:
            SettingsEntry(
                pane: .general, title: "Channel", section: "Updates",
                keywords: ["beta", "release channel", "prerelease", "nightly"])
        case .autoUpdate:
            SettingsEntry(
                pane: .general, title: "Check for updates automatically", section: "Updates",
                keywords: ["auto update", "software update", "sparkle"])
        case .checkForUpdates:
            SettingsEntry(
                pane: .general, title: "Check Now", section: "Updates",
                keywords: ["update", "version", "upgrade"])
        case .swipeNavigation:
            SettingsEntry(
                pane: .general, title: "Swipe between pages", section: "Navigation",
                keywords: ["gestures", "trackpad", "back", "forward", "two finger swipe"])
        case .downloadsFolder:
            SettingsEntry(
                pane: .general, title: "Save downloads to", section: "Downloads",
                keywords: ["download location", "download folder", "save path"])
        case .downloadsAsk:
            SettingsEntry(
                pane: .general, title: "Ask where to save each file", section: "Downloads",
                keywords: ["save as", "download prompt", "choose location"])
        case .tabSleep:
            SettingsEntry(
                pane: .general, title: "Sleep background tabs after", section: "Memory",
                keywords: ["hibernate", "memory saver", "discard tabs", "tab suspender", "ram"])
        case .autoPictureInPicture:
            SettingsEntry(
                pane: .general, title: "Auto-enter when another app covers the window", section: "Picture in Picture",
                keywords: ["pip", "mini-player", "floating video", "auto pip"])
        case .miniPlayerCorners:
            SettingsEntry(
                pane: .general, title: "Corner rounding", section: "Picture in Picture",
                keywords: ["mini-player", "pip", "corner radius"])
        case .miniPlayerSkip:
            SettingsEntry(
                pane: .general, title: "Skip buttons jump", section: "Picture in Picture",
                keywords: ["mini-player", "seek", "skip seconds", "rewind"])
        case .miniPlayerSiteButtons:
            SettingsEntry(
                pane: .general, title: "Mini-Player Site Buttons", section: "Mini-Player Site Buttons",
                keywords: ["pip buttons", "pills", "media controls"])
        case .edgeThickness:
            SettingsEntry(
                pane: .appearance, title: "Edge thickness", section: "Window",
                keywords: ["border", "padding", "inset", "frame", "margin"])
        case .nowPlaying:
            SettingsEntry(
                pane: .appearance, title: "Show Now Playing", section: "Sidebar",
                keywords: ["media controls", "music", "audio", "playback"])
        case .folderSecondLine:
            SettingsEntry(
                pane: .appearance, title: "Second line", section: "Folders",
                keywords: ["folder preview", "hover", "subtitle"])
        case .folderTabCount:
            SettingsEntry(
                pane: .appearance, title: "Tab count", section: "Folders",
                keywords: ["folder badge", "number of tabs"])
        case .appIcon:
            SettingsEntry(
                pane: .appearance, title: "App Icon", section: "App Icon",
                keywords: ["dock icon", "theme", "alternate icon"])
        case .profileList:
            SettingsEntry(
                pane: .profiles, title: "Your Profiles",
                keywords: ["new profile", "add profile", "delete profile", "favourites", "identities"])
        case .profileName:
            SettingsEntry(
                pane: .profiles, title: "Rename",
                keywords: ["profile name", "profile icon", "change icon"])
        case .searchEngine:
            SettingsEntry(
                pane: .profiles, title: "Search engine", section: "Search",
                keywords: ["default search", "google", "duckduckgo", "search provider"])
        case .searchSuggestions:
            SettingsEntry(
                pane: .profiles, title: "Search engine suggestions", section: "Search",
                keywords: ["autocomplete", "completions", "suggest"])
        case .archiveAfter:
            SettingsEntry(
                pane: .profiles, title: "Archive tabs after", section: "Tabs",
                keywords: ["auto-archive", "close old tabs", "tab cleanup"])
        case .translateTo:
            SettingsEntry(
                pane: .profiles, title: "Translate pages to", section: "Translation",
                keywords: ["translation language", "foreign", "locale"])
        case .translationRules:
            SettingsEntry(
                pane: .profiles, title: "Translation rules", section: "Translation",
                keywords: ["always translate", "never translate", "translate exceptions"])
        case .deleteProfile:
            SettingsEntry(
                pane: .profiles, title: "Delete Profile…",
                keywords: ["remove profile", "erase profile"])
        case .savedPasswords:
            SettingsEntry(
                pane: .profiles, page: .passwords, title: "Passwords", section: "Passwords",
                keywords: ["logins", "passkeys", "saved passwords", "credentials", "keychain"])
        case .suggestedPasswords:
            SettingsEntry(
                pane: .profiles, page: .passwords, title: "Add Suggested Password…", section: "Suggested Passwords",
                keywords: ["password generator", "recipe", "root password", "strong password"])
        case .leakCheck:
            SettingsEntry(
                pane: .profiles, page: .passwords, title: "Check roots against known leaks", section: "Suggested Passwords",
                keywords: ["have i been pwned", "breach", "compromised", "leaked passwords"])
        case .offerToSavePasswords:
            SettingsEntry(
                pane: .profiles, page: .passwords, title: "Offer to save passwords", section: "Options",
                keywords: ["save logins", "password prompt", "remember passwords"])
        case .fillPasswords:
            SettingsEntry(
                pane: .profiles, page: .passwords, title: "Fill from suggestions", section: "Options",
                keywords: ["autofill passwords", "fill logins", "login suggestions"])
        case .unlockPasswords:
            SettingsEntry(
                pane: .profiles, page: .passwords, title: "Passwords", section: "Ask for Touch ID",
                keywords: ["lock passwords", "require authentication", "biometric", "password timeout"])
        case .neverSaved:
            SettingsEntry(
                pane: .profiles, page: .passwords, title: "Never Saved", section: "Never Saved",
                keywords: ["blocked sites", "never save", "exceptions"])
        case .importExportPasswords:
            SettingsEntry(
                pane: .profiles, page: .passwords, title: "Import CSV…", section: "Import & Export",
                keywords: ["export passwords", "import passwords", "1password", "bitwarden", "backup"])
        case .addresses:
            SettingsEntry(
                pane: .profiles, page: .autofill, title: "Add Address…", section: "Addresses",
                keywords: ["saved addresses", "shipping address", "home address", "contact info"])
        case .cards:
            SettingsEntry(
                pane: .profiles, page: .autofill, title: "Add Card…", section: "Cards",
                keywords: ["credit card", "debit card", "payment methods", "saved cards"])
        case .fillAddresses:
            SettingsEntry(
                pane: .profiles, page: .autofill, title: "Fill addresses", section: "Options",
                keywords: ["autofill address", "form fill"])
        case .fillCards:
            SettingsEntry(
                pane: .profiles, page: .autofill, title: "Fill cards", section: "Options",
                keywords: ["autofill card", "payment autofill", "credit card"])
        case .offerToSaveAutofill:
            SettingsEntry(
                pane: .profiles, page: .autofill, title: "Offer to save", section: "Options",
                keywords: ["save addresses", "save cards", "remember forms"])
        case .unlockCards:
            SettingsEntry(
                pane: .profiles, page: .autofill, title: "Cards", section: "Ask for Touch ID",
                keywords: ["lock cards", "require authentication", "biometric"])
        case .unlockAddresses:
            SettingsEntry(
                pane: .profiles, page: .autofill, title: "Addresses", section: "Ask for Touch ID",
                keywords: ["lock addresses", "require authentication", "biometric"])
        case .clearTimeRange:
            SettingsEntry(
                pane: .profiles, page: .clearData, title: "Time range",
                keywords: ["last hour", "all time", "period", "clear browsing data"])
        case .clearHistory:
            SettingsEntry(
                pane: .profiles, page: .clearData, title: "Browsing history",
                keywords: ["visited pages", "delete history", "clear browsing data"])
        case .clearCookies:
            SettingsEntry(
                pane: .profiles, page: .clearData, title: "Cookies and site data",
                keywords: ["sign out", "local storage", "delete cookies"])
        case .clearCache:
            SettingsEntry(
                pane: .profiles, page: .clearData, title: "Cached files and images",
                keywords: ["cache", "temporary files", "free space"])
        case .clearArchive:
            SettingsEntry(
                pane: .profiles, page: .clearData, title: "Archived tabs",
                keywords: ["archive", "library", "old tabs"])
        case .clearPageText:
            SettingsEntry(
                pane: .profiles, page: .clearData, title: "Indexed page text",
                keywords: ["full text index", "page index", "search index"])
        case .clearAutofill:
            SettingsEntry(
                pane: .profiles, page: .clearData, title: "Saved addresses and cards",
                keywords: ["autofill", "credit cards", "form data"])
        case .clearDownloads:
            SettingsEntry(
                pane: .profiles, page: .clearData, title: "Downloads list", section: "Every Profile",
                keywords: ["download history", "clear downloads"])
        case .clearZoom:
            SettingsEntry(
                pane: .profiles, page: .clearData, title: "Per-site zoom levels", section: "Every Profile",
                keywords: ["page zoom", "text size", "magnification"])
        case .clearPermissions:
            SettingsEntry(
                pane: .profiles, page: .clearData, title: "Site permissions", section: "Every Profile",
                keywords: ["camera", "microphone", "location", "reset permissions"])
        case .clearNow:
            SettingsEntry(
                pane: .profiles, page: .clearData, title: "Clear…",
                keywords: ["clear browsing data", "delete data", "wipe", "erase history"])
        case .blockAds:
            SettingsEntry(
                pane: .privacy, title: "Block ads and trackers", section: "Content Blocking",
                keywords: ["adblock", "ublock", "advertising", "tracking", "filter lists"])
        case .filterLists:
            SettingsEntry(
                pane: .privacy, title: "EasyList", section: "Content Blocking",
                keywords: ["blocklists", "easyprivacy", "cookie notices", "cookie banners", "social widgets"])
        case .updateBlocklists:
            SettingsEntry(
                pane: .privacy, title: "Update Blocklists", section: "Content Blocking",
                keywords: ["refresh filters", "download lists"])
        case .incognitoTouchID:
            SettingsEntry(
                pane: .privacy, title: "Always require Touch ID for incognito windows", section: "Incognito and Your Data",
                keywords: ["private browsing", "lock incognito", "private window", "biometric"])
        case .fingerprintDefence:
            SettingsEntry(
                pane: .privacy, title: "Randomise fingerprintable readings", section: "Fingerprint Defence",
                keywords: ["fingerprinting", "canvas", "anonymity"])
        case .sitePermissions:
            SettingsEntry(
                pane: .privacy, title: "Site Permissions", section: "Site Permissions",
                keywords: ["camera", "microphone", "location", "notifications", "allowed sites"])
        case .forgetAllSites:
            SettingsEntry(
                pane: .privacy, title: "Forget All Sites", section: "Site Permissions",
                keywords: ["reset permissions", "clear permissions", "revoke"])
        case .appleEventsJavaScript:
            SettingsEntry(
                pane: .privacy, title: "Allow JavaScript from Apple Events", section: "Automation",
                keywords: ["applescript", "shortcuts", "osascript", "scripting"])
        case .incognitoAppleScript:
            SettingsEntry(
                pane: .privacy, title: "Incognito tabs visible in AppleScript", section: "Automation",
                keywords: ["scripting", "private windows", "apple events"])
        case .spotlight:
            SettingsEntry(
                pane: .privacy, title: "Show spaces and tabs in Spotlight", section: "Automation",
                keywords: ["siri", "system search", "shortcuts", "core spotlight"])
        case .errorReports:
            SettingsEntry(
                pane: .privacy, title: "Send error reports", section: "Reports",
                keywords: ["crash reports", "diagnostics", "telemetry", "analytics"])
        case .sendFeedback:
            SettingsEntry(
                pane: .privacy, title: "Send Feedback…", section: "Reports",
                keywords: ["bug report", "contact", "feature request", "support"])
        case .dataFolder:
            SettingsEntry(
                pane: .privacy, title: "Show Data Folder in Finder", section: "On-Device Data",
                keywords: ["storage location", "json files", "profile folder", "local data"])
        case .revealDelay:
            SettingsEntry(
                pane: .sidebar, title: "Reveal delay", section: "Reveal",
                keywords: ["hover delay", "auto-hide sidebar", "peek sidebar"])
        case .hoverArea:
            SettingsEntry(
                pane: .sidebar, title: "Hover area", section: "Reveal",
                keywords: ["edge width", "hot zone", "trigger area"])
        case .revealSpeed:
            SettingsEntry(
                pane: .sidebar, title: "Reveal speed", section: "Reveal",
                keywords: ["animation speed", "slide duration"])
        case .spaceSwitchSpeed:
            SettingsEntry(
                pane: .sidebar, title: "Switching speed", section: "Spaces",
                keywords: ["space animation", "transition", "swipe spaces"])
        case .pinnedSeparation:
            SettingsEntry(
                pane: .tabs, title: "When separating", section: "Pinned Tabs",
                keywords: ["split pinned tab", "pinned slot", "duplicate pinned"])
        case .splitOffDestination:
            SettingsEntry(
                pane: .tabs, title: "Split-off tab goes to", section: "Pinned Tabs",
                keywords: ["separate tab", "today", "new tab position"])
        case .tabPreviews:
            SettingsEntry(
                pane: .tabs, title: "Show previews", section: "Previews",
                keywords: ["hover cards", "tab preview", "unread count", "pinned tab card"])
        case .previewSites:
            SettingsEntry(
                pane: .tabs, title: "Gmail", section: "Previews",
                keywords: ["github", "outlook", "icloud mail", "notifications", "recent pages"])
        case .splitDirection:
            SettingsEntry(
                pane: .tabs, title: "New splits open", section: "Split View",
                keywords: ["split screen", "columns", "rows", "side by side", "tiling"])
        case .autoResizePanes:
            SettingsEntry(
                pane: .tabs, title: "Auto-resize panes on drag", section: "Split View",
                keywords: ["equal sizes", "split sizes", "rearrange"])
        case .dimInactivePanes:
            SettingsEntry(
                pane: .tabs, title: "Dim inactive panes", section: "Split View",
                keywords: ["focus", "fade", "highlight active"])
        case .linkedSplits:
            SettingsEntry(
                pane: .tabs, title: "Open links in the next pane", section: "Split View",
                keywords: ["linked", "linked splits", "link panes"])
        case .dropGuides:
            SettingsEntry(
                pane: .tabs, title: "Show drop guides while dragging", section: "Split View",
                keywords: ["drag targets", "drop zones", "split overlay"])
        case .routingRules:
            SettingsEntry(
                pane: .links, title: "Rules", section: "Rules",
                keywords: ["routing", "air traffic control", "open site in space", "redirect"])
        case .describeRule:
            SettingsEntry(
                pane: .links, title: "Describe a rule", section: "Describe a rule",
                keywords: ["ai rule", "natural language", "draft rule", "routing"])
        case .externalLinks:
            SettingsEntry(
                pane: .links, title: "A link that matches a rule", section: "Links from other apps",
                keywords: ["external links", "other apps", "open in scout"])
        case .peekCorner:
            SettingsEntry(
                pane: .links, title: "Controls corner", section: "Peek",
                keywords: ["link preview", "shift click", "peek buttons"])
        case .scoutFrame:
            SettingsEntry(
                pane: .links, title: "Frame", section: "Scout",
                keywords: ["little arc", "scout colour", "popup window", "mini browser"])
        case .bangs:
            SettingsEntry(
                pane: .search, title: "Bangs", section: "Shortcuts",
                keywords: ["!bang", "duckduckgo bangs", "custom bangs", "search shortcuts", "keywords"])
        case .indexPageText:
            SettingsEntry(
                pane: .search, title: "Index the text of pages I visit", section: "Search Page Contents",
                keywords: ["full text", "history search", "page index", "content search"])
        case .eraseIndex:
            SettingsEntry(
                pane: .search, title: "Erase Index", section: "Search Page Contents",
                keywords: ["delete index", "clear page text", "full text"])
        case .extensionsEnabled:
            SettingsEntry(
                pane: .extensions, title: "Enable extensions",
                keywords: ["add-ons", "plugins", "webextensions", "disable all"])
        case .boosts:
            SettingsEntry(
                pane: .extensions, title: "Add Boost", section: "Boosts",
                keywords: ["custom css", "user styles", "userscripts", "site styles", "javascript"])
        case .installedExtensions:
            SettingsEntry(
                pane: .extensions, title: "Installed", section: "Installed",
                keywords: ["manage extensions", "remove extension", "pin to url bar", "extension permissions", "allow in incognito"])
        case .extensionStore:
            SettingsEntry(
                pane: .extensions, title: "Add from a Store", section: "Add from a Store",
                keywords: ["chrome web store", "firefox add-ons", "install extension", "store url"])
        case .suggestedExtensions:
            SettingsEntry(
                pane: .extensions, title: "Suggested", section: "Suggested",
                keywords: ["recommended extensions", "popular extensions", "bitwarden"])
        case .extensionFromDisk:
            SettingsEntry(
                pane: .extensions, title: "Add from Disk…",
                keywords: ["sideload", "unpacked", "crx", "xpi", "zip"])
        case .onDeviceModel:
            SettingsEntry(
                pane: .intelligence, title: "Use the on-device model", section: "On-Device Intelligence",
                keywords: ["ai", "apple intelligence", "llm", "foundation models"])
        case .tidyTabNames:
            SettingsEntry(
                pane: .intelligence, title: "Tidy tab names", section: "Features",
                keywords: ["ai", "rename tabs", "short titles", "clean titles"])
        case .askAboutPage:
            SettingsEntry(
                pane: .intelligence, title: "Ask about this page (⌘F)", section: "Features",
                keywords: ["ai", "chat with page", "summarise", "question"])
        case .agentsEnabled:
            SettingsEntry(
                pane: .agents, title: "Allow coding agents to use Artemis",
                keywords: ["mcp", "claude code", "codex", "ai agents", "automation"])
        case .agentSetup:
            SettingsEntry(
                pane: .agents, title: "Setup", section: "Setup",
                keywords: ["mcp command", "claude code", "codex", "json config", "install mcp"])
        case .agentSpaces:
            SettingsEntry(
                pane: .agents, title: "Spaces Agents Can Reach", section: "Spaces Agents Can Reach",
                keywords: ["agent access", "allowed spaces", "mcp spaces"])
        case .agentScripts:
            SettingsEntry(
                pane: .agents, title: "Let agents run scripts in pages", section: "Spaces Agents Can Reach",
                keywords: ["javascript", "execute script", "mcp"])
        case .approvedAgents:
            SettingsEntry(
                pane: .agents, title: "Approved Agents", section: "Approved Agents",
                keywords: ["trusted agents", "forget agent", "mcp clients"])
        case .connectedAgents:
            SettingsEntry(
                pane: .agents, title: "Connected", section: "Connected",
                keywords: ["active sessions", "disconnect", "mcp sessions"])
        }
    }

    /// false while the row's feature is switched off or not built in
    @MainActor var isAvailable: Bool {
        switch self {
        case .updateChannel, .autoUpdate, .checkForUpdates: Updates.shared.isEnabled
        case .translationRules:
            !ProfilesNavigator.shared.profile.translationRules.languages.isEmpty
                || !ProfilesNavigator.shared.profile.translationRules.sites.isEmpty
        case .deleteProfile: !ProfilesNavigator.shared.profile.isDefault
        case .neverSaved: !PasswordStore.shared.neverSave.isEmpty
        case .filterLists, .updateBlocklists: ContentBlocker.shared.isEnabled
        case .forgetAllSites: !SitePermissionStore.shared.sorted.isEmpty
        case .previewSites: TabPreviewCard.isEnabled
        case .tidyTabNames, .askAboutPage: Intelligence.isEnabled && Intelligence.isReady
        default: true
        }
    }
}

/// which setting the Settings window should scroll to and light up
@MainActor @Observable final class SettingsSpotlight {
    static let shared = SettingsSpotlight()
    nonisolated static let space = "settingsPage"

    /// asked for, not yet scrolled to
    var pending: SettingID?
    /// glowing now
    var lit: SettingID?
    /// rows that have appeared on a page, for the self-test
    var seen: Set<SettingID> = []
    /// the lit row's frame in the settings page's coordinate space
    var litFrame: CGRect?

    func reveal(_ id: SettingID) {
        pending = id
        SettingsView.open()
    }
}

extension View {
    func settingsAnchor(_ id: SettingID) -> some View { modifier(SettingsAnchor(id: id)) }

    /// for one row of a ForEach block: nil leaves the row unmarked
    @ViewBuilder func settingsAnchor(_ id: SettingID?) -> some View {
        if let id { settingsAnchor(id) } else { self }
    }
}

private struct SettingsAnchor: ViewModifier {
    let id: SettingID
    @State private var frame = CGRect.zero
    private var spotlight: SettingsSpotlight { .shared }

    func body(content: Content) -> some View {
        let lit = spotlight.lit == id
        content
            .background {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.accentColor.opacity(lit ? 0.22 : 0))
                    .padding(.horizontal, -6)
                    .padding(.vertical, -3)
                    .animation(Motion.fade, value: lit)
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(SettingsSpotlight.space)) } action: {
                frame = $0
                if lit { spotlight.litFrame = $0 }
            }
            .onChange(of: lit) { if lit { spotlight.litFrame = frame } }
            .onAppear { spotlight.seen.insert(id) }
            .id(id)
    }
}
