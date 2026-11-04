// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import AppKit
import WebKit

/// one `WKWebExtensionController` per profile, made with the profile's first tab; each keeps its
/// own extension storage and answers from its profile's jar. the default profile's runs on
/// `Configuration.default()`, where its extensions' storage lives
enum WebExtensionRuntime {
    private(set) static var controllers: [UUID: WKWebExtensionController] = [:]

    static func controller(for profile: UUID) -> WKWebExtensionController {
        if let existing = controllers[profile] { return existing }
        let configuration: WKWebExtensionController.Configuration =
            profile == Profile.defaultID ? .default() : .init(identifier: profile)
        configuration.defaultWebsiteDataStore = ProfileStore.dataStore(for: profile)
        if ExtensionLab.isRequested {
            let webViews = configuration.webViewConfiguration ?? WKWebViewConfiguration()
            ExtensionLab.quiet(webViews.preferences)
            configuration.webViewConfiguration = webViews
        }
        let controller = WKWebExtensionController(configuration: configuration)
        controller.delegate = ExtensionManager.shared
        controllers[profile] = controller
        ExtensionManager.shared.controllerCreated(for: profile)
        return controller
    }

    /// nil is WebKit's default store, the default profile's
    static func profile(of store: WKWebsiteDataStore?) -> UUID {
        store?.identifier ?? Profile.defaultID
    }

    static func profile(of controller: WKWebExtensionController) -> UUID? {
        controllers.first { $0.value === controller }?.key
    }

    static func remove(_ profile: UUID) -> WKWebExtensionController? {
        controllers.removeValue(forKey: profile)
    }
}

/// errors surfaced from the install pipeline
enum ExtensionError: LocalizedError {
    case alreadyInstalled(String)

    var errorDescription: String? {
        switch self {
        case .alreadyInstalled(let name): "“\(name)” is already installed."
        }
    }
}

/// owns the installed extensions and drives each profile's controller. an extension is granted
/// only what its manifest requested, after the consent UI; the master switch unloads every one
/// without forgetting its state
@Observable
final class ExtensionManager: NSObject, WKWebExtensionControllerDelegate {
    static let shared = ExtensionManager()

    /// the controller of the profile the user is in
    var controller: WKWebExtensionController { WebExtensionRuntime.controller(for: currentProfile) }

    /// the profile of the space the user is in; an incognito window's parent while it has focus
    var currentProfile: UUID {
        let windows = BrowserWindows.shared
        let scope = windows.current?.kind == .incognito ? windows.current : windows.browserScope
        return (scope ?? tabManager)?.currentSpace.profileID ?? Profile.defaultID
    }

    private var allProfiles: Set<UUID> {
        Set((tabManager?.profiles ?? []).map(\.id) + [Profile.defaultID])
    }

    private(set) var installed: [InstalledExtension] = []

    /// master "compatibility mode" switch — when off, every context is unloaded
    /// but each extension's own enabled state is remembered for when it flips on
    var isMasterEnabled: Bool {
        didSet {
            guard oldValue != isMasterEnabled else { return }
            UserDefaults.standard.set(isMasterEnabled, forKey: Self.masterKey)
            applyMasterState()
        }
    }

    /// an extension's request to show its popup; a repeat from the same extension is still a new value
    struct PopupRequest: Equatable {
        let extensionID: String
        let id = UUID()
    }

    /// set when an extension asks to show its popup; the focused window's site-settings button presents it
    var pendingPopup: PopupRequest?

    @ObservationIgnored weak var tabManager: TabManager?
    @ObservationIgnored private var window: ExtensionWindow?
    /// each incognito window, presented to its parent profile's controller as a private one
    @ObservationIgnored private var privateWindows: [ObjectIdentifier: ExtensionWindow] = [:]
    /// the window WebKit last heard had focus: every focus event reaches every extension
    @ObservationIgnored private var focusedWindow: ExtensionWindow?

    private static let recordsKey = "extensionRecordsV1"
    private static let masterKey = "extensionsMasterEnabledV1"

    private override init() {
        isMasterEnabled = UserDefaults.standard.object(forKey: Self.masterKey) as? Bool ?? true
        super.init()
        for scheme in ["chrome-extension", "moz-extension"] {
            WKWebExtension.MatchPattern.registerCustomURLScheme(scheme)
        }
    }

    /// wire the manager to the live tab model and rehydrate persisted
    /// extensions. called once, early, from `TabManager`.
    func attach(tabManager: TabManager) {
        guard self.tabManager == nil else { return }
        self.tabManager = tabManager
        self.window = ExtensionWindow(tabManager: tabManager)
        focusedWindow = window
        installCommandKeyMonitor()
        SharedWebContent.everywhere { StorePageCleaner.install(into: $0) }
        // before any tab loads: a VPN extension restores "connected" from its own storage and
        // may never set its proxy again
        ExtensionProxyBridge.shared.restorePersisted()
        Task { @MainActor in await loadPersisted() }
    }

    /// the single browser window exposed to the runtime (nil until attached)
    var browserWindow: (any WKWebExtensionWindow)? { window }

    /// those on in the profile the user is in
    var enabledExtensions: [InstalledExtension] {
        guard isMasterEnabled else { return [] }
        let profile = currentProfile
        return installed.filter { $0.profiles.contains(profile) }
    }

    /// pinned + enabled extensions, shown directly in the url bar
    var pinnedExtensions: [InstalledExtension] {
        enabledExtensions.filter(\.isPinned)
    }

    /// what a window offers: an incognito one, only the extensions allowed there
    func enabledExtensions(in window: TabManager) -> [InstalledExtension] {
        window.kind == .incognito ? enabledExtensions.filter(\.allowsIncognito) : enabledExtensions
    }

    @MainActor
    func setAllowsIncognito(_ ext: InstalledExtension, _ allowed: Bool) {
        ext.allowsIncognito = allowed && !ext.refusesIncognito
        persist()
    }

    // MARK: - Install

    /// sideload a folder, .zip, .xpi or .crx, added switched off: the caller's consent sheet
    /// enables it
    @MainActor
    func installFromDisk(_ url: URL) async throws -> InstalledExtension {
        try await register(id: ExtensionInstaller.install(from: url), source: .disk)
    }

    /// install from a Chrome Web Store or Firefox Add-ons page, added switched off like a sideload
    @MainActor
    func installFromStore(pageURL: URL) async throws -> InstalledExtension {
        let (tempFile, source) = try await ExtensionStores.download(from: pageURL)
        defer { try? FileManager.default.removeItem(at: tempFile) }
        return try await register(id: ExtensionInstaller.install(from: tempFile), source: source)
    }

    /// add freshly stored resources as an extension in no profile; a failure removes them
    @MainActor
    private func register(id: String, source: ExtensionSource) async throws -> InstalledExtension {
        do {
            guard let resourceURL = await ExtensionCompat.prepare(storedID: id) else {
                throw ExtensionInstaller.InstallError.holdsLink
            }
            let ext = try await WKWebExtension(resourceBaseURL: resourceURL)

            // a second copy is matched by name, the one id shared by every store and disk
            let name = ext.displayName ?? ext.displayShortName ?? ""
            if let existing = installed.first(where: {
                $0.name.caseInsensitiveCompare(name) == .orderedSame
            }) {
                throw ExtensionError.alreadyInstalled(existing.name)
            }

            let installedExt = InstalledExtension(
                id: id, source: source, webExtension: ext, profiles: [], isPinned: false)
            installed.append(installedExt)
            persist()
            return installedExt
        } catch {
            ExtensionInstaller.removeStorage(forID: id)
            if !(error is ExtensionError) {
                Diagnostics.record(area: "extensions", message: "install failed: \(error.localizedDescription)")
            }
            throw error
        }
    }

    /// grants exactly what the manifest requested, nothing broader
    @MainActor
    private func grantRequestedAccess(for ext: InstalledExtension, in profile: UUID) {
        let context = ext.context(in: profile)
        let status = WKWebExtensionContext.PermissionStatus.grantedExplicitly
        for permission in ext.webExtension.requestedPermissions {
            context.setPermissionStatus(status, for: permission)
        }
        for pattern in ext.webExtension.requestedPermissionMatchPatterns {
            context.setPermissionStatus(status, for: pattern)
        }
    }

    // MARK: - Lifecycle

    /// load an extension in a profile that has a controller. the profile's open tabs are announced
    /// first: restored ones never pass through tabDidOpen, WebKit can't name an unannounced tab as
    /// a sender, and announced after the load they would arrive as tabs.onCreated
    @MainActor
    private func load(_ ext: InstalledExtension, in profile: UUID) {
        guard isMasterEnabled, hasRehydrated, let controller = WebExtensionRuntime.controllers[profile]
        else { return }
        grantRequestedAccess(for: ext, in: profile)
        let context = ext.context(in: profile)
        guard !context.isLoaded else { return }
        prepareStorage(for: ext, in: profile, context: context)
        for tab in openTabs(in: profile) { context.didOpenTab(tab) }
        try? controller.load(context)
    }

    /// a legacy install's first instance in another profile is seeded from the
    /// default profile's storage (storage.local, and WebKit's state, so it isn't
    /// taken for a new install); any other first instance is a real install
    @MainActor
    private func prepareStorage(for ext: InstalledExtension, in profile: UUID, context: WKWebExtensionContext) {
        let target = storageFolder(of: ext, in: profile)
        guard !FileManager.default.fileExists(atPath: target.path) else { return }
        let source = storageFolder(of: ext, in: Profile.defaultID)
        if ext.seedsFromDefault, profile != Profile.defaultID,
            FileManager.default.fileExists(atPath: source.path)
        {
            try? FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.copyItem(at: source, to: target)
        } else {
            installedThisSession.insert(ExtensionAPIBridge.key(of: context, in: profile))
        }
    }

    /// WebKit's storage and registered scripts for one extension in one profile, whether or not
    /// that profile has a controller. WebKit nests its data under the bundle ID unless it runs in
    /// a container
    private func storageFolder(of ext: InstalledExtension, in profile: UUID) -> URL {
        let webKit = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WebKit", isDirectory: true)
        return (AppStorageLocation.isContainerised
            ? webKit : webKit.appendingPathComponent(Bundle.main.bundleIdentifier ?? "", isDirectory: true))
            .appendingPathComponent("WebExtensions", isDirectory: true)
            .appendingPathComponent(
                profile == Profile.defaultID ? "Default" : profile.uuidString.uppercased(), isDirectory: true)
            .appendingPathComponent(ext.id, isDirectory: true)
    }

    @MainActor
    private func unload(_ ext: InstalledExtension, in profile: UUID) {
        guard let context = ext.contexts[profile], context.isLoaded,
            let controller = WebExtensionRuntime.controllers[profile]
        else { return }
        // keyed by the controller, which an unloaded context no longer has
        ExtensionAPIBridge.shared.tearDown(context)
        try? controller.unload(context)
    }

    /// every window's tabs live in the shared core, so one manager lists them all
    @MainActor
    private func openTabs(in profile: UUID) -> [BrowserTab] {
        (tabManager?.allTabs ?? []).filter { !$0.isPrivate && $0.profileID == profile }
    }

    /// a deleted profile takes its extensions' state with it. its controller holds the
    /// profile's data store, which can't be removed from disk while anything uses it
    @MainActor
    func profileDeleted(_ profile: UUID) {
        guard profile != Profile.defaultID else { return }
        for ext in installed {
            unload(ext, in: profile)
            ext.forget(profile)
        }
        if let controller = WebExtensionRuntime.remove(profile),
            let storage = controller.configuration.value(forKey: "_storageDirectoryPath") as? String,
            storage.contains(profile.uuidString)
        {
            try? FileManager.default.removeItem(atPath: storage)
        }
        SharedWebContent.remove(profile)
        ExtensionProxyBridge.shared.forget(profile)
        persist()
    }

    /// a profile's first tab made its controller: its extensions start there, and a proxy restored
    /// for it whose extension didn't start is no one's
    @MainActor
    fileprivate func controllerCreated(for profile: UUID) {
        guard hasRehydrated else { return }
        for ext in installed where ext.profiles.contains(profile) { load(ext, in: profile) }
        ExtensionProxyBridge.shared.releaseUnless(in: profile) { owner in
            installed.contains { $0.id == owner && $0.contexts[profile]?.isLoaded == true }
        }
    }

    /// the extension a context belongs to, whichever profile it runs in
    func owner(of context: WKWebExtensionContext) -> InstalledExtension? {
        installed.first { $0.contexts.values.contains { $0 === context } }
    }

    /// on or off in one profile
    @MainActor
    func setEnabled(_ ext: InstalledExtension, _ enabled: Bool, in profile: UUID) {
        guard ext.profiles.contains(profile) != enabled else { return }
        if enabled {
            ext.profiles.insert(profile)
            load(ext, in: profile)
        } else {
            unload(ext, in: profile)
            ext.profiles.remove(profile)
        }
        persist()
    }

    /// on in every profile, or off in all of them
    @MainActor
    func setEnabled(_ ext: InstalledExtension, _ enabled: Bool) {
        let profiles = enabled ? allProfiles : []
        guard ext.profiles != profiles else { return }
        for profile in ext.profiles.subtracting(profiles) { unload(ext, in: profile) }
        ext.profiles = profiles
        for profile in profiles { load(ext, in: profile) }
        persist()
    }

    @MainActor
    func togglePin(_ ext: InstalledExtension) {
        ext.isPinned.toggle()
        persist()
    }

    @MainActor
    func remove(_ ext: InstalledExtension) {
        for profile in ext.contexts.keys { unload(ext, in: profile) }
        installed.removeAll { $0.id == ext.id }
        ExtensionInstaller.removeStorage(forID: ext.id)
        // Chrome's uninstall drops every profile's data, run this session or not
        for profile in allProfiles { try? FileManager.default.removeItem(at: storageFolder(of: ext, in: profile)) }
        ExtensionAPIBridge.shared.forgetPanelSettings(of: ext.id)
        persist()
    }

    /// manifest permissions whose `chrome.*` namespace WebKit leaves undefined
    /// (probed on the shipping runtime), plus the ones it accepts and ignores:
    /// `webRequestBlocking`, `webRequestAuthProvider`, `clipboardRead`, `favicon`
    static let unsupportedAPIs: Set<String> = [
        "bookmarks", "browsingData", "clipboardRead", "contentSettings", "debugger",
        "declarativeContent", "desktopCapture", "downloads", "favicon", "fontSettings", "gcm",
        "history", "identity", "idle", "management", "notifications", "offscreen",
        "pageCapture", "power", "privacy", "proxy", "readingList", "search", "sessions",
        "sidePanel", "system", "tabCapture", "tabGroups", "topSites", "tts", "ttsEngine",
        "userScripts", "vpnProvider", "webRequestAuthProvider", "webRequestBlocking",
    ]

    /// declared permissions, optional ones included, that WebKit can't provide: those the shim fills
    /// and those still missing. read from the manifest, which keeps the keys `requestedPermissions`
    /// drops; `system.display` and kin count as `system`
    func permissionCoverage(for ext: InstalledExtension) -> (bridged: [String], missing: [String]) {
        let manifest = ext.webExtension.manifest
        let declared = Set(
            ["permissions", "optional_permissions"]
                .flatMap { (manifest[$0] as? [Any]) ?? [] }
                .compactMap { ($0 as? String)?.split(separator: ".").first.map(String.init) })
        let gaps = declared.intersection(Self.unsupportedAPIs)
        let bridged = isCompatBridged(ext) ? gaps.intersection(ExtensionCompat.shimmedPermissions) : []
        return (bridged.sorted(), gaps.subtracting(bridged).sorted())
    }

    /// true when this extension's package carries the Artemis compat shim
    func isCompatBridged(_ ext: InstalledExtension) -> Bool {
        ext.webExtension.manifest[ExtensionCompat.markerKey] is NSNumber
    }

    /// the page extensions act on; never an incognito one, which they can't see
    @MainActor
    var currentTab: BrowserTab? {
        actionTab.flatMap { $0.isPrivate ? nil : $0 }
    }

    /// the page an extension's button acts on: incognito ones offer only extensions allowed there
    @MainActor
    var actionTab: BrowserTab? { (BrowserWindows.shared.current ?? tabManager)?.selectedTab }

    /// the action (icon, badge, popup) for an extension in the current tab; a view reading it
    /// redraws on the extension's `actionRevision`
    @MainActor
    func action(for ext: InstalledExtension) -> WKWebExtension.Action? {
        _ = ext.actionRevision
        return ext.context.action(for: actionTab)
    }

    /// click handler shared by the pinned bar and the dropdown grid: run the
    /// action, which either toggles state or asks us to present a popup
    @MainActor
    func performAction(for ext: InstalledExtension) {
        let presentsPopup = action(for: ext)?.presentsPopup ?? false
        guard !ExtensionAPIBridge.shared.handleActionClick(for: ext.context, presentsPopup: presentsPopup)
        else { return }
        ext.context.performAction(for: actionTab)
    }

    @MainActor
    func openOptionsPage(for ext: InstalledExtension) {
        guard let url = ext.context.optionsPageURL else { return }
        openTab(url, for: ext.context)
    }

    /// open a store landing page in a new tab so the user can browse for
    /// extensions (the in-page banner then offers one-click install)
    @MainActor
    func openStorePage(_ url: URL) {
        openTab(url, for: nil)
    }

    /// a tab in the front browser window, in `context`'s profile: that window's space when it is
    /// the profile's, else the profile's first, selected only on screen. an extension's own page
    /// needs the loaded context's configuration, or WebKit refuses it (-1008)
    @MainActor
    @discardableResult
    private func openTab(_ url: URL?, for context: WKWebExtensionContext?, select: Bool = true) -> BrowserTab? {
        guard let manager = BrowserWindows.shared.browserScope ?? BrowserWindows.shared.seed ?? tabManager
        else { return nil }
        let profile = context?.webExtensionController.flatMap(WebExtensionRuntime.profile(of:))
        let home = profile.flatMap { id in
            manager.currentSpace.profileID == id ? nil : manager.spaces.first { $0.profileID == id }
        } ?? manager.currentSpace
        let ownPage = url?.scheme == "webkit-extension"
        let configuration = ownPage ? context?.webViewConfiguration : nil
        if ownPage, configuration == nil { return nil }
        return manager.newTab(
            url: url, configuration: configuration, select: select && home === manager.currentSpace, in: home)
    }

    // MARK: - Extension keyboard commands

    /// routes key events to `chrome.commands`. `performCommand(for:)` claims only an exact match for
    /// a declared command, and a declared command wins over an app shortcut, as in Chrome
    @ObservationIgnored private var commandMonitor: Any?

    /// WebKit reports "install" for any extension that loads more than five seconds
    /// after its controller exists; only these instances (`key(of:)`) are new
    @ObservationIgnored private(set) var installedThisSession: Set<String> = []

    private func installCommandKeyMonitor() {
        guard commandMonitor == nil else { return }
        commandMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isMasterEnabled, let window = BrowserWindows.shared.current ?? self.tabManager,
                event.modifierFlags.intersection([.command, .control, .option]) != []
            else { return event }
            let profile = self.currentProfile
            for ext in self.enabledExtensions(in: window) {
                guard let context = ext.contexts[profile], context.isLoaded else { continue }
                if context.performCommand(for: event) { return nil }
            }
            return event
        }
    }

    // MARK: - Tab lifecycle bridge

    /// the controller of the tab's profile (an incognito tab's parent); nil until that profile has one
    private func controller(of tab: BrowserTab) -> WKWebExtensionController? {
        WebExtensionRuntime.controllers[ProfileStore.proxyProfile(of: tab.dataStore)]
    }

    /// an incognito window's face to the runtime, once its first page has announced it
    @MainActor
    func privateWindow(of manager: TabManager) -> ExtensionWindow? {
        privateWindows[ObjectIdentifier(manager)]
    }

    @MainActor
    private func openPrivateWindow(of manager: TabManager) {
        // a manager that went without closing its window frees its identifier for another
        for (key, stale) in privateWindows where stale.tabManager == nil {
            privateWindows[key] = nil
            stale.controller?.didCloseWindow(stale)
        }
        guard privateWindows[ObjectIdentifier(manager)] == nil else { return }
        let window = ExtensionWindow(tabManager: manager, privateTo: manager.currentSpace.profileID)
        privateWindows[ObjectIdentifier(manager)] = window
        window.controller?.didOpenWindow(window)
        focusedWindow = window
    }

    /// WebKit's idea of the focused window feeds `currentWindow` and `windows.getLastFocused`
    @MainActor
    func windowDidFocus(_ manager: TabManager) {
        let focused = privateWindows[ObjectIdentifier(manager)] ?? (manager.kind == .incognito ? nil : window)
        guard let focused, focused !== focusedWindow else { return }
        focusedWindow = focused
        if let controller = focused.controller {
            controller.didFocusWindow(focused)
        } else {
            for controller in WebExtensionRuntime.controllers.values { controller.didFocusWindow(focused) }
        }
    }

    @MainActor
    func windowDidClose(_ manager: TabManager) {
        guard let window = privateWindows.removeValue(forKey: ObjectIdentifier(manager)) else { return }
        if focusedWindow === window { focusedWindow = nil }
        window.controller?.didCloseWindow(window)
    }

    /// a page an open incognito window has been to; it never reaches history through an extension
    @MainActor
    func isVisitedPrivately(_ url: URL) -> Bool {
        (tabManager?.allTabs ?? []).contains { tab in
            let list = tab.webView.backForwardList
            return tab.isPrivate && (tab.url == url
                || ([list.currentItem].compactMap { $0 } + list.backList + list.forwardList).contains { $0.url == url })
        }
    }

    func tabDidOpen(_ tab: BrowserTab) {
        if tab.isPrivate, let manager = tab.manager { openPrivateWindow(of: manager) }
        controller(of: tab)?.didOpenTab(tab)
    }

    func tabDidClose(_ tab: BrowserTab, windowIsClosing: Bool = false) {
        controller(of: tab)?.didCloseTab(tab, windowIsClosing: windowIsClosing)
    }

    /// a previous tab of another profile is that profile's business, not this one's
    func tabDidActivate(_ tab: BrowserTab, previous: BrowserTab?) {
        guard let controller = controller(of: tab) else { return }
        let previous = previous.flatMap { controller === self.controller(of: $0) ? $0 : nil }
        controller.didActivateTab(tab, previousActiveTab: previous)
    }

    /// WebKit never derives this from navigation: `chrome.tabs.onUpdated` fires only when told
    func tabDidChange(_ properties: WKWebExtension.TabChangedProperties, for tab: BrowserTab) {
        controller(of: tab)?.didChangeTabProperties(properties, for: tab)
    }

    /// a proxy change reaches only new connections: the profile's live pages reload, its
    /// incognito ones included
    @MainActor
    func reloadLiveTabs(proxyProfile profile: UUID) -> Int {
        guard let manager = tabManager else { return 0 }
        var reloaded = 0
        for tab in manager.allTabs where ProfileStore.proxyProfile(of: tab.dataStore) == profile && !tab.isHibernated && tab.url != nil {
            tab.webView.reload()
            reloaded += 1
        }
        return reloaded
    }

    // MARK: - Master switch

    @MainActor
    private func applyMasterState() {
        for ext in installed {
            for profile in ext.profiles {
                if isMasterEnabled { load(ext, in: profile) } else { unload(ext, in: profile) }
            }
        }
    }

    // MARK: - Persistence

    private func persist() {
        let records = installed.map {
            ExtensionRecord(
                id: $0.id, source: $0.source, isEnabled: $0.isEnabled, isPinned: $0.isPinned,
                profiles: Array($0.profiles), allowsIncognito: $0.allowsIncognito)
        } + unrestored
        if let data = try? JSONEncoder().encode(records) {
            UserDefaults.standard.set(data, forKey: Self.recordsKey)
        }
    }

    @MainActor
    private func loadPersisted() async {
        defer {
            hasRehydrated = true
            for profile in WebExtensionRuntime.controllers.keys { controllerCreated(for: profile) }
        }
        guard let data = UserDefaults.standard.data(forKey: Self.recordsKey),
            let records = try? JSONDecoder().decode([ExtensionRecord].self, from: data)
        else { return }

        unrestored = records
        for record in records {
            guard let resourceURL = await ExtensionCompat.prepare(storedID: record.id) else {
                // a package still on disk was refused for a link: its record stays, as for one that fails to load
                if FileManager.default.fileExists(
                    atPath: ExtensionInstaller.storageRoot.appendingPathComponent(record.id).path)
                {
                    Diagnostics.record(
                        area: "extensions", message: "a stored extension holds a symbolic link and wasn't loaded")
                } else {
                    debugLog("extension \(record.id): resources missing, skipping")
                    unrestored.removeAll { $0.id == record.id }
                }
                continue
            }
            do {
                let ext = try await WKWebExtension(resourceBaseURL: resourceURL)
                let profiles = record.profiles.map(Set.init) ?? (record.isEnabled ? allProfiles : [])
                let installedExt = InstalledExtension(
                    id: record.id, source: record.source, webExtension: ext,
                    profiles: profiles, isPinned: record.isPinned)
                installedExt.seedsFromDefault = record.profiles == nil
                installedExt.allowsIncognito = record.allowsIncognito ?? false
                installed.append(installedExt)
                unrestored.removeAll { $0.id == record.id }
            } catch {
                debugLog("extension \(record.id): failed to load — \(error.localizedDescription)")
                Diagnostics.record(
                    area: "extensions", message: "a stored extension failed to load: \(error.localizedDescription)")
            }
        }
    }

    /// contexts wait for the stored extensions to be rebuilt, so a profile whose
    /// first tab came earlier loads them then
    @ObservationIgnored private(set) var hasRehydrated = false
    /// stored records not rebuilt, still on the way or failing to load: `persist()` keeps them
    @ObservationIgnored private var unrestored: [ExtensionRecord] = []

    // MARK: - WKWebExtensionControllerDelegate

    /// native messaging: the compat shim's bridge and the Safari endpoint Bitwarden's extension
    /// expects. any other host is missing, as Chrome reports it
    func webExtensionController(
        _ controller: WKWebExtensionController, sendMessage message: Any,
        toApplicationWithIdentifier applicationIdentifier: String?,
        for extensionContext: WKWebExtensionContext,
        replyHandler: @escaping (Any?, (any Error)?) -> Void
    ) {
        guard let dict = message as? [String: Any] else { return replyHandler([:], nil) }
        switch applicationIdentifier {
        case ExtensionCompat.nativeAppID:
            Task { @MainActor in
                ExtensionLab.record(dict, from: extensionContext)
                if let reply = await ExtensionAPIBridge.shared.handle(dict, for: extensionContext) {
                    return replyHandler(reply, nil)
                }
                replyHandler(
                    await ExtensionProxyBridge.shared.handle(
                        dict, from: extensionContext.uniqueIdentifier,
                        in: extensionContext.webExtensionController.flatMap(WebExtensionRuntime.profile(of:))
                            ?? Profile.defaultID), nil)
            }
        case PasswordManagerBridge.bitwardenAppID:
            Task { @MainActor in
                guard let reply = PasswordManagerBridge.handle(dict, from: extensionContext) else {
                    return replyHandler(nil, Self.hostNotFound)
                }
                replyHandler(reply, nil)
            }
        default:
            replyHandler(nil, Self.hostNotFound)
        }
    }

    private static let hostNotFound = NSError(
        domain: "ArtemisNativeMessaging", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Specified native messaging host not found."])

    /// the compat shim's push channel; no other native host exists here
    func webExtensionController(
        _ controller: WKWebExtensionController, connectUsing port: WKWebExtension.MessagePort,
        for extensionContext: WKWebExtensionContext
    ) async throws {
        // a port to a missing host disconnects, as in Chrome; WebKit drops the error,
        // so runtime.lastError stays unset in onDisconnect
        guard port.applicationIdentifier == ExtensionCompat.nativeAppID else {
            return port.disconnect(throwing: Self.hostNotFound)
        }
        ExtensionAPIBridge.shared.connect(port, for: extensionContext)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController, openWindowsFor context: WKWebExtensionContext
    ) -> [any WKWebExtensionWindow] {
        (window.map { [$0] } ?? []) + privateWindows.values.filter { $0.controller === controller }
    }

    func webExtensionController(
        _ controller: WKWebExtensionController, focusedWindowFor context: WKWebExtensionContext
    ) -> (any WKWebExtensionWindow)? {
        BrowserWindows.shared.current.flatMap { privateWindows[ObjectIdentifier($0)] }
            .flatMap { $0.controller === controller ? $0 : nil } ?? window
    }

    @MainActor
    func webExtensionController(
        _ controller: WKWebExtensionController,
        openNewTabUsing configuration: WKWebExtension.TabConfiguration,
        for context: WKWebExtensionContext
    ) async throws -> (any WKWebExtensionTab)? {
        // an incognito window's request stays in it; an extension's own pages need a normal one
        if let window = configuration.window as? ExtensionWindow, window.isPrivate(for: context),
            configuration.url?.scheme != "webkit-extension"
        {
            return window.tabManager?.newTab(url: configuration.url, select: configuration.shouldBeActive)
        }
        return openTab(configuration.url, for: context, select: configuration.shouldBeActive)
    }

    @MainActor
    func webExtensionController(
        _ controller: WKWebExtensionController,
        openOptionsPageFor context: WKWebExtensionContext
    ) async throws {
        guard let url = context.optionsPageURL else { return }
        openTab(url, for: context)
    }

    /// `permissions.request()`, and WebKit's lazy grants of declared permissions: what the manifest
    /// declared was consented to at install and is granted silently; anything else is an
    /// escalation the user is asked about
    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissions permissions: Set<WKWebExtension.Permission>,
        in tab: (any WKWebExtensionTab)?,
        for context: WKWebExtensionContext
    ) async -> (Set<WKWebExtension.Permission>, Date?) {
        guard let ext = owner(of: context) else {
            return ([], nil)
        }
        let declared = ext.webExtension.requestedPermissions
        let extra = permissions.subtracting(declared)
        guard !extra.isEmpty else { return (permissions, nil) }
        let allowed = await askToEscalate(
            ext, items: extra.map(\.rawValue).sorted(), kind: "capabilities")
        return (allowed ? permissions : permissions.intersection(declared), nil)
    }

    /// the same escalation, for host access an extension asks for at runtime
    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissionToAccess urls: Set<URL>,
        in tab: (any WKWebExtensionTab)?,
        for context: WKWebExtensionContext
    ) async -> (Set<URL>, Date?) {
        guard let ext = owner(of: context) else {
            return ([], nil)
        }
        let declared = ext.webExtension.requestedPermissionMatchPatterns
        let extra = urls.filter { url in !declared.contains { $0.matches(url) } }
        guard !extra.isEmpty else { return (urls, nil) }
        let allowed = await askToEscalate(
            ext, items: extra.map(\.absoluteString).sorted(), kind: "sites")
        return (allowed ? urls : urls.subtracting(extra), nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>,
        in tab: (any WKWebExtensionTab)?,
        for context: WKWebExtensionContext
    ) async -> (Set<WKWebExtension.MatchPattern>, Date?) {
        guard let ext = owner(of: context) else {
            return ([], nil)
        }
        let declared = ext.webExtension.requestedPermissionMatchPatterns
        let extra = matchPatterns.subtracting(declared)
        guard !extra.isEmpty else { return (matchPatterns, nil) }
        let allowed = await askToEscalate(
            ext, items: extra.map(\.string).sorted(), kind: "sites")
        return (allowed ? matchPatterns : matchPatterns.subtracting(extra), nil)
    }

    /// the escalation alert; Deny is the default button
    @MainActor
    private func askToEscalate(_ ext: InstalledExtension, items: [String], kind: String) async -> Bool {
        // the lab answers from launch: extensions it left installed ask before its run starts
        if let stubbed = escalationAnswerForTesting ?? (ExtensionLab.isRequested ? true : nil) { return stubbed }
        let listed = items.prefix(12).joined(separator: "\n")
        let more = items.count > 12 ? "\n… and \(items.count - 12) more" : ""
        let alert = NSAlert()
        alert.messageText = "“\(ext.name)” wants more access."
        alert.informativeText =
            "It is asking for \(kind) you didn't agree to when you installed it:\n\n"
            + listed + more
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Deny")
        alert.addButton(withTitle: "Allow")
        return alert.runModal() == .alertSecondButtonReturn
    }

    /// answers the escalation alert in place of the modal, for the self-test
    @ObservationIgnored var escalationAnswerForTesting: Bool?

    /// a badge, icon or title changed: the extension's buttons redraw
    func webExtensionController(
        _ controller: WKWebExtensionController, didUpdate action: WKWebExtension.Action,
        forExtensionContext context: WKWebExtensionContext
    ) {
        owner(of: context)?.actionRevision += 1
    }

    /// an extension asked to show its popup programmatically — flag it so the url
    /// bar's settings button presents it from a sensible anchor. a context the focused window doesn't
    /// run is refused and closed, or WebKit holds it open and refuses the next
    @MainActor
    func webExtensionController(
        _ controller: WKWebExtensionController,
        presentActionPopup action: WKWebExtension.Action,
        for context: WKWebExtensionContext
    ) async throws {
        guard let window = BrowserWindows.shared.current,
            enabledExtensions(in: window).contains(where: { $0.contexts[currentProfile] === context })
        else {
            action.closePopup()
            throw Self.noPopupWindow
        }
        pendingPopup = PopupRequest(extensionID: context.uniqueIdentifier)
    }

    /// what a refused `action.openPopup()` rejects with
    private static let noPopupWindow = NSError(
        domain: "ArtemisExtensions", code: 2,
        userInfo: [NSLocalizedDescriptionKey: "Could not find an active browser window."])
}
