// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import AppKit
import SwiftUI
import UserNotifications

/// `Artemis mcp` is the agents' stdio server, and must branch before SwiftUI builds
/// the app — the app's `@State` alone loads the whole session
@main
enum Launch {
    static func main() {
        if CommandLine.arguments.dropFirst().first == "mcp" { AgentStdio.run() }
        ArtemisApp.main()
    }
}

struct ArtemisApp: App {
    /// first: stored properties initialise in order, and the session loads below
    private let containerMigration: Void = ContainerMigration.run()
    @Environment(\.openWindow) private var openWindow
    @Environment(\.scenePhase) private var scenePhase
    /// the manager that loads the session; the first window takes it
    @State private var seedManager = TabManager()
    @State private var windows = BrowserWindows.shared
    /// the focused window's manager, mirrored into `@State`: menu items refresh
    /// only against `@State`, never against `windows.current`
    @State private var focusedManager: TabManager?
    /// the Edit menu's Undo and Redo, which `UndoRoute` names and routes
    @State private var undoRoute = UndoRoute.shared
    /// which pinned extension ⌘E reaches next
    @State private var extensionCycleIndex = 0
    @AppStorage(BrowserToolbar.shownKey) private var showsToolbar = false
    // owns external links, so the WindowGroup never spawns a window per URL
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// the window a menu command belongs to: whichever browser window has focus,
    /// else the manager the next window takes
    private var tabManager: TabManager { focusedManager ?? windows.seed ?? seedManager }

    /// commands only the full browser can answer — a new tab, the Library, the
    /// spaces — belong to a browser window even when a Scout window has focus
    private var browser: TabManager {
        if let focusedManager, focusedManager.kind == .main { return focusedManager }
        return windows.browserScope ?? windows.seed ?? seedManager
    }

    /// `manager`, once a window is on its way to show it: with every browser
    /// window closed the next one takes it
    private func shown(_ manager: TabManager) -> TabManager {
        if manager.kind == .main, windows.window(of: manager) == nil { openWindow(id: Self.browserWindowID) }
        return manager
    }

    /// the focused window's own tabs, sidebar and splits; a Scout window has none
    private var strip: TabManager? { tabManager.kind == .scout ? nil : tabManager }

    /// the browser window group, by name — New Window opens another one
    static let browserWindowID = "browser"

    init() {
        Bench.mark("ArtemisApp.init")
        WindowChrome.clampStoredEdgeInset()
        // before any window exists, or AppKit's window-tab items stay in the menus
        NSWindow.allowsAutomaticWindowTabbing = false
        BrowserWindows.shared.seed = seedManager
    }

    var body: some Scene {
        // menu items track app state only while they hang off a group with a window
        WindowGroup(id: Self.browserWindowID) {
            BrowserWindowRoot()
                .environment(ExtensionManager.shared)
                .navigationTitle("")
        }
        // external URL events belong to the delegate, never this group
        .handlesExternalEvents(matching: ["artemis-main"])
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { seedManager.save() }
        }
        .onChange(of: windows.current.map(ObjectIdentifier.init), initial: true) { _, _ in
            focusedManager = windows.current
        }
        .defaultSize(width: 1000, height: 640)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
        .windowResizability(.contentMinSize)
        .commands {
            // the standard Close (⌘W) item would race our Close Tab — remove it
            CommandGroup(replacing: .saveItem) {}

            CommandGroup(replacing: .appInfo) {
                Button("About Artemis") { showAboutPanel() }
                if Updates.shared.isEnabled {
                    Button("Check for Updates…") { Updates.shared.checkNow() }
                }
            }

            // replaces `.newItem` so the group's own New Window item isn't shown too
            CommandGroup(replacing: .newItem) {
                Button("New Tab…") {
                    shown(tabManager).requestNewTab()
                }
                .keyboardShortcut("t")
                .disabled(tabManager.kind == .scout)

                Button("New Window") {
                    BrowserWindows.shared.pendingSpaceID = browser.selectedSpaceID
                    openWindow(id: Self.browserWindowID)
                }
                .keyboardShortcut("n")

                Button(strip == nil ? "Close Window" : "Close Tab") {
                    handleCloseShortcut()
                }
                .keyboardShortcut("w")

                // hidden in Scout, where ⌘W itself says "Close Window"
                if strip != nil {
                    Button("Close Window") {
                        NSApp.keyWindow?.performClose(nil)
                    }
                    .keyboardShortcut("w", modifiers: [.command, .shift])
                }

                Button(browser.reopensFolderNext ? "Reopen Closed Folder" : "Reopen Closed Tab") {
                    shown(browser).reopenLastClosedTab()
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(browser.closedTabs.isEmpty && browser.closedFolders.isEmpty)

                Button((strip?.selectedTab?.isPinned ?? false) ? "Unpin Tab" : "Pin Tab") {
                    if let strip, let tab = strip.selectedTab { strip.togglePin(tab) }
                }
                .keyboardShortcut("d")
                .disabled(strip?.selectedTab == nil)

                Button("Duplicate Tab") {
                    if let strip, let tab = strip.selectedTab { strip.duplicateTab(tab) }
                }
                .disabled(strip?.selectedTab?.url == nil)

                Button("Clear Today's Tabs") {
                    strip?.clearTodayTabs()
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .disabled((strip?.currentSpace.todayTabs.count ?? 0) < 2)

                Button("Open Anything…") {
                    GlobalHotkey.shared.fire()
                }
                .keyboardShortcut("n", modifiers: [.command, .option])

                Button("Open File…") {
                    openLocalFile()
                }
                .keyboardShortcut("o")

                Divider()

                Button("Copy Page Link") {
                    tabManager.unlockedContentTab?.copyLink()
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(tabManager.unlockedContentTab?.url == nil)

                Button("Copy Page Link as Markdown") {
                    tabManager.unlockedContentTab?.copyLink(asMarkdown: true)
                }
                .keyboardShortcut("c", modifiers: [.command, .shift, .option])
                .disabled(tabManager.unlockedContentTab?.url == nil)

                Divider()

                Button("Open Location…") {
                    shown(tabManager).urlFieldFocusRequest += 1
                }
                .keyboardShortcut("l")

                Button("Find…") {
                    tabManager.opensFindBarAsking = false
                    tabManager.isFindBarVisible = true
                }
                .keyboardShortcut("f")

                Button("Find Next") {
                    tabManager.findNextRequest += 1
                }
                .keyboardShortcut("g")
                .disabled(!tabManager.isFindBarVisible)

                Button("Find Previous") {
                    tabManager.findPreviousRequest += 1
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(!tabManager.isFindBarVisible)

                Button("Ask About This Page…") {
                    tabManager.opensFindBarAsking = true
                    tabManager.isFindBarVisible = true
                }
                .keyboardShortcut("f", modifiers: [.command, .option])
                .disabled(
                    tabManager.unlockedContentTab?.url == nil
                        || !Intelligence.isOn(Intelligence.askPageKey) || !Intelligence.isReady)

                Divider()

                Button("Export Backup…") { BackupIO.export(from: browser) }
                Button("Restore from Backup…") { restoreBackup() }
                Button("Import Bookmarks…") { importBookmarks() }
                Button("Import from Arc…") { ArcMigration.run(into: browser) }
                    .disabled(browser.arcImport != nil)
                Button("Import from Browser…") { BrowserImportModel.open(in: browser) }
                    .disabled(browser.browserImport != nil)

                Divider()

                Button("Print…") {
                    tabManager.unlockedContentTab?.printPage()
                }
                .keyboardShortcut("p")
                .disabled(tabManager.unlockedContentTab?.url == nil)

                Menu("Export Page") {
                    Button("PDF") { exportPage(.pdf) }
                    Button("Web Archive") { exportPage(.webArchive) }
                    Button("Full-Page Image") { exportPage(.fullPageImage) }
                }
                .disabled(tabManager.unlockedContentTab?.url == nil)
            }

            CommandGroup(replacing: .undoRedo) {
                Button(undoRoute.undoTitle) { undoRoute.perform(redo: false) }
                    .keyboardShortcut("z")
                    .disabled(!undoRoute.canUndo)
                Button(undoRoute.redoTitle) { undoRoute.perform(redo: true) }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!undoRoute.canRedo)
            }

            CommandGroup(replacing: .sidebar) {}
            CommandGroup(replacing: .help) {
                Button("Send Feedback…") { FeedbackDraft.open(in: strip ?? browser) }
            }

            CommandGroup(before: .toolbar) {
                // "+" on the shift-less key, so ⌘= zooms in too
                Button("Zoom In") {
                    tabManager.selectedTab?.zoomIn()
                }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(tabManager.selectedTab?.url == nil)

                Button("Zoom Out") {
                    tabManager.selectedTab?.zoomOut()
                }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(tabManager.selectedTab?.url == nil)

                Button("Actual Size") {
                    tabManager.selectedTab?.resetZoom()
                }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(tabManager.selectedTab?.url == nil)

                Divider()

                Button((tabManager.unlockedContentTab?.isReaderMode ?? false) ? "Hide Reader" : "Show Reader") {
                    let tab = tabManager.unlockedContentTab
                    Task { await tab?.toggleReader() }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(
                    !(tabManager.unlockedContentTab?.isReaderAvailable ?? false)
                        && !(tabManager.unlockedContentTab?.isReaderMode ?? false))

                Button("Translate Selection…") {
                    let tab = tabManager.unlockedContentTab
                    Task { await tab?.translateSelection() }
                }
                .keyboardShortcut("t", modifiers: [.command, .shift, .option])
                .disabled(tabManager.unlockedContentTab?.url == nil)

                Button(tabManager.unlockedContentTab?.pageTranslation.isActive == true ? "Show Original" : "Translate Page") {
                    let tab = tabManager.unlockedContentTab
                    Task { await tab?.toggleTranslation() }
                }
                .keyboardShortcut("t", modifiers: [.command, .option])
                .disabled(tabManager.unlockedContentTab?.url == nil)

                Divider()

                Button((tabManager.selectedTab?.isMuted ?? false) ? "Unmute Tab" : "Mute Tab") {
                    tabManager.selectedTab?.toggleMuted()
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(tabManager.selectedTab?.url == nil)

                Divider()

                Button((strip?.isSidebarCollapsed ?? false) ? "Show Sidebar" : "Hide Sidebar") {
                    strip?.isSidebarCollapsed.toggle()
                }
                .keyboardShortcut("s")
                .disabled(strip == nil)

                // Arc's key for it
                Button(showsToolbar ? "Hide Toolbar" : "Show Toolbar") { showsToolbar.toggle() }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                    .disabled(strip == nil)

                Divider()

                Button(strip?.displayedSplitGroup == nil ? "Split View" : "Unsplit") {
                    strip?.toggleSplit()
                }
                .keyboardShortcut("v", modifiers: [.command, .option])
                .disabled(strip?.selectedTab == nil)

                // Arc's own split keys, alongside Artemis' ⌘⌥V
                Button("Add Split Pane") {
                    guard let strip else { return }
                    let pane = strip.newTab(select: false)
                    strip.openBeside(pane)
                    strip.selectedTabID = pane.id
                    strip.urlFieldFocusRequest += 1
                }
                .keyboardShortcut("+", modifiers: [.control, .shift])
                .disabled(
                    strip?.selectedTab == nil
                        || (strip?.displayedSplitGroup?.leafCount ?? 0) >= SplitGroup.maxPanes)

                Button("Close Split Pane") {
                    if let strip, let tab = strip.selectedTab, strip.displayedSplitGroup != nil {
                        strip.removeFromSplit(tab)
                    }
                }
                .keyboardShortcut("-", modifiers: [.control, .shift])
                .disabled(strip?.displayedSplitGroup == nil)

                Button("Focus Next Pane") {
                    strip?.focusAdjacentPane(1)
                }
                .keyboardShortcut("]", modifiers: [.command, .option])
                .disabled(strip?.displayedSplitGroup == nil)

                Button("Focus Previous Pane") {
                    strip?.focusAdjacentPane(-1)
                }
                .keyboardShortcut("[", modifiers: [.command, .option])
                .disabled(strip?.displayedSplitGroup == nil)

                // ⌃⇧1…4: focus a pane by number, as Arc does
                ForEach(0..<SplitGroup.maxPanes, id: \.self) { index in
                    Button("Focus Pane \(index + 1)") {
                        strip?.focusPane(at: index)
                    }
                    .keyboardShortcut(
                        KeyEquivalent(Character("\(index + 1)")), modifiers: [.control, .shift])
                    .disabled(strip?.displayedSplitGroup == nil)
                }

                Divider()

                Button("Picture in Picture") {
                    tabManager.togglePictureInPicture()
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(tabManager.unlockedContentTab?.url == nil)

                Button(
                    (tabManager.unlockedContentTab?.isInspectorVisible ?? false)
                        ? "Close Web Inspector" : "Show Web Inspector"
                ) {
                    tabManager.unlockedContentTab?.toggleInspector()
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(tabManager.unlockedContentTab?.url == nil)

                // F12: AppKit sends function keys from U+F704 in the private use area
                Button("Web Inspector ") {
                    tabManager.unlockedContentTab?.toggleInspector()
                }
                .keyboardShortcut(KeyEquivalent(Character(UnicodeScalar(0xF70F)!)), modifiers: [])
                .disabled(tabManager.unlockedContentTab?.url == nil)

                Divider()

                // ⌘E, Arc's key for reaching a pinned extension from the keyboard
                Button("Next Extension") {
                    cycleExtensions()
                }
                .keyboardShortcut("e")
                .disabled(!ExtensionManager.shared.enabledExtensions(in: tabManager).contains(where: \.isPinned))
            }

            CommandMenu("Navigate") {
                Button("Reload Page") {
                    tabManager.unlockedContentTab?.reload()
                }
                .keyboardShortcut("r")
                .disabled(tabManager.unlockedContentTab?.url == nil)

                // Safari's key: ⌘⇧R is Reader
                Button("Reload From Origin") {
                    tabManager.unlockedContentTab?.reloadFromOrigin()
                }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(tabManager.unlockedContentTab?.url == nil)

                Button("Back") {
                    tabManager.unlockedContentTab?.goBack()
                }
                .keyboardShortcut("[")
                .disabled(tabManager.unlockedContentTab?.canGoBack != true)

                Button("Forward") {
                    tabManager.unlockedContentTab?.goForward()
                }
                .keyboardShortcut("]")
                .disabled(tabManager.unlockedContentTab?.canGoForward != true)

                // Arc's arrow spellings of the same two
                Button("Back ") {
                    if !textFieldTookKey() { tabManager.unlockedContentTab?.goBack() }
                }
                .keyboardShortcut(.leftArrow, modifiers: .command)
                .disabled(tabManager.unlockedContentTab?.canGoBack != true)

                Button("Forward ") {
                    if !textFieldTookKey() { tabManager.unlockedContentTab?.goForward() }
                }
                .keyboardShortcut(.rightArrow, modifiers: .command)
                .disabled(tabManager.unlockedContentTab?.canGoForward != true)

                Divider()

                Button("Next Tab") {
                    strip?.selectNextTab()
                }
                .keyboardShortcut("]", modifiers: [.command, .shift])
                .disabled(strip == nil)

                Button("Previous Tab") {
                    strip?.selectPreviousTab()
                }
                .keyboardShortcut("[", modifiers: [.command, .shift])
                .disabled(strip == nil)

                // Arc's own keys for the same pair
                Button("Next Tab ") {
                    strip?.selectNextTab()
                }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(strip == nil)

                Button("Previous Tab ") {
                    strip?.selectPreviousTab()
                }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(strip == nil)

                Button("Recent Tab") {
                    strip?.selectRecentTab(offset: 1)
                }
                .keyboardShortcut(.tab, modifiers: .control)
                .disabled(strip == nil)

                Button("Tab Before Last") {
                    strip?.selectRecentTab(offset: 2)
                }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])
                .disabled(strip == nil)

                Divider()

                Button("History") {
                    shown(browser).openLibrary(.history)
                }
                .keyboardShortcut("y")

                Button("Archive") {
                    shown(browser).openLibrary(.archive)
                }
                .keyboardShortcut("y", modifiers: [.command, .shift])

                Button("Downloads") {
                    shown(browser).openLibrary(.downloads)
                }
                .keyboardShortcut("j", modifiers: [.command, .shift])

                Button("Library") {
                    shown(browser).isLibraryOpen.toggle()
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])

                Divider()

                // the Nth sidebar row, favourites first; while the command bar
                // is up the first four pick its scope instead
                Menu("Go to Tab") {
                    ForEach(0..<8, id: \.self) { index in
                        Button("Tab \(index + 1)") {
                            guard let strip else { return }
                            if strip.isCommandBarVisible, CommandScope.allCases.indices.contains(index) {
                                let mode = CommandScope.allCases[index]
                                strip.commandBarScope = strip.commandBarScope == mode ? nil : mode
                            } else {
                                strip.selectSidebarItem(at: index)
                            }
                        }
                        .keyboardShortcut(
                            KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                    }
                }
                .disabled(strip == nil)
            }

            // spaces
            CommandMenu("Spaces") {
                Button("New Space…") {
                    shown(browser).isSpaceCreatorVisible = true
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(tabManager.kind != .main)

                Button("New Incognito Window") {
                    IncognitoWindow.open()
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])

                Divider()

                Button("Previous Space") {
                    shown(browser).cycleSpace(by: -1)
                }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .disabled(tabManager.kind != .main)

                Button("Next Space") {
                    shown(browser).cycleSpace(by: 1)
                }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled(tabManager.kind != .main)

                Divider()

                // ⌃1–⌃9, the way Arc does it — ⌘1–⌘8 walks the sidebar's rows
                ForEach(Array(browser.spaces.prefix(9).enumerated()), id: \.element.id) {
                    index, space in
                    Button(space.name) {
                        shown(browser).selectSpace(space)
                    }
                    .keyboardShortcut(
                        KeyEquivalent(Character("\(index + 1)")), modifiers: .control)
                    .disabled(tabManager.kind != .main)
                }
            }
        }

        // incognito: never restored, opened at launch, or handed an external link
        WindowGroup(id: IncognitoWindow.id) {
            IncognitoWindowRoot()
                .environment(ExtensionManager.shared)
                .navigationTitle("")
        }
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.suppressed)
        .handlesExternalEvents(matching: [])
        .defaultSize(width: 1000, height: 640)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
        .windowResizability(.contentMinSize)
        // a scene's own Close (⌘W) shows while its window has focus and would close it outright
        .commands { CommandGroup(replacing: .saveItem) {} }

        Settings {
            SettingsView()
                .environment(browser)
                .environment(ExtensionManager.shared)
        }
    }

    /// AppKit's standard panel; its credits link the site and the third-party notices
    private func showAboutPanel() {
        let centred = NSMutableParagraphStyle()
        centred.alignment = .center
        let text: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: centred,
        ]
        let credits = NSMutableAttributedString()
        let links = [
            ("artemisbrowser.app", "https://artemisbrowser.app"),
            ("Acknowledgements", "https://github.com/artemisbrowser/artemis/blob/main/THIRD-PARTY-NOTICES.md"),
        ]
        for (title, address) in links {
            if credits.length > 0 { credits.append(NSAttributedString(string: "  ·  ", attributes: text)) }
            var link = text
            link[.link] = URL(string: address)
            credits.append(NSAttributedString(string: title, attributes: link))
        }
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: credits,
            NSApplication.AboutPanelOptionKey(rawValue: "Copyright"):
                "© \(Calendar.current.component(.year, from: .now)) Fin",
        ])
    }

    /// pick a backup file and, once confirmed, restore it over the current spaces
    private func restoreBackup() {
        guard let archive = BackupIO.chooseArchive() else { return }
        let alert = NSAlert()
        alert.messageText = "Restore this backup?"
        alert.informativeText = """
            From \(archive.createdAt.formatted(date: .abbreviated, time: .shortened)) \
            (Artemis \(archive.appVersion)).

            \(archive.session.spaces.count) spaces will REPLACE your current spaces and tabs. \
            \(archive.boosts.count) Boosts will be merged in, and saved settings \
            will be applied.
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        BackupIO.restore(archive, options: .init(), into: browser)
    }

    /// another browser's bookmarks, turned into spaces of pinned tabs
    private func importBookmarks() {
        let panel = NSOpenPanel()
        panel.message =
            "Choose a bookmarks file. Any browser can export one (Bookmarks ▸ Export), "
            + "or pick Chrome's own “Bookmarks” file from its profile folder."
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].resolvingSymlinksInPath()
        guard panel.runModal() == .OK, let url = panel.urls.first else { return }

        guard let data = try? Data(contentsOf: url), let parsed = BookmarkImport.parse(data) else {
            let alert = NSAlert()
            alert.messageText = "Artemis couldn't read that file."
            alert.informativeText =
                "It reads bookmark files exported from any browser, and Chrome's own "
                + "“Bookmarks” file. Safari: File ▸ Export ▸ Bookmarks."
            alert.runModal()
            return
        }

        let alert = NSAlert()
        alert.messageText = "Import \(parsed.linkCount) bookmarks?"
        alert.informativeText =
            "\(parsed.folders.count) folders will become spaces, with their links pinned. "
            + (parsed.loose.isEmpty
                ? "" : "\(parsed.loose.count) loose links go into a space called Imported. ")
            + "Nothing you already have is touched, and no page loads but the one you land on."
        alert.addButton(withTitle: "Import")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        browser.importBookmarks(parsed)
    }

    /// ⌘O: each picked file opens in a tab
    private func openLocalFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Choose a file to open in Artemis."
        guard panel.runModal() == .OK else { return }
        let target = shown(strip ?? browser)
        let opened = panel.urls.map { target.newTab(url: $0, select: false) }
        if let first = opened.first { target.revealTab(first) }
    }

    /// main-menu key equivalents beat the field editor: a focused text field gets
    /// ⌘← and ⌘→ back for its own line, through the user's key bindings
    private func textFieldTookKey() -> Bool {
        guard let field = NSApp.keyWindow?.firstResponder as? NSTextView,
            let event = NSApp.currentEvent, event.type == .keyDown
        else { return false }
        field.interpretKeyEvents([event])
        return true
    }

    /// ⌘W closes a browser window's tab and never the window itself, which ⇧⌘W closes; Scout and
    /// every other window close
    private func handleCloseShortcut() {
        guard let window = NSApp.keyWindow else { return }
        guard let manager = BrowserWindows.shared.manager(for: window), manager.kind != .scout
        else { return window.performClose(nil) }
        manager.closeSelectedTab()
    }

    private func exportPage(_ kind: BrowserTab.PageExport) {
        guard let tab = tabManager.unlockedContentTab else { return }
        Task { await tab.export(kind) }
    }

    /// ⌘E: step through the pinned extensions, running each one's action
    private func cycleExtensions() {
        let pinned = ExtensionManager.shared.enabledExtensions(in: tabManager).filter(\.isPinned)
        guard !pinned.isEmpty else { return }
        let next = extensionCycleIndex % pinned.count
        extensionCycleIndex = next + 1
        ExtensionManager.shared.performAction(for: pinned[next])
    }
}

/// routes links opened from other apps into Scout windows, which are plain
/// `NSWindow`s rather than SwiftUI scenes
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// SwiftUI wraps its own delegate around this one, so `NSApp.delegate` is
    /// never it. the command bar needs the real instance to open a Scout window
    static private(set) weak var shared: AppDelegate?

    /// the app icon follows light/dark when the icon style is automatic
    private var iconAppearance: NSKeyValueObservation?

    override init() {
        super.init()
        Self.shared = self
    }

    /// every debounced or queued store write, made synchronously: a quit from
    /// the front never leaves `.active`, so `scenePhase` alone misses it
    func applicationWillTerminate(_ notification: Notification) {
        (BrowserWindows.shared.browserScope ?? BrowserWindows.shared.seed)?.saveNow()
        TabNameStore.shared.saveNow()
        for profile in BrowserCore.shared.profiles { profile.saveNow() }
        ZoomStore.shared.saveNow()
        SitePermissionStore.shared.saveNow()
        RoutingStore.shared.saveNow()
        AutofillStore.shared.saveNow()
        PasswordStore.saveNow()
        // a page's notifications die with its document
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }

    /// opens a window if none exists well after a restore would have landed:
    /// restoration keys off the scene's view type, which a new build can change
    func applicationDidFinishLaunching(_ notification: Notification) {
        // ⌘⌥N from any app
        GlobalHotkey.shared.register(.commandOptionN) { QuickLaunch.toggle() }
        AppIconChoice.apply()
        SpotlightIndex.scheduleRefresh()
        if !SelfTest.isRequested, !AppStorageLocation.isExtensionLab {
            Task { await Reports.run() }
            Updates.shared.start()
        }
        iconAppearance = NSApp.observe(\.effectiveAppearance) { _, _ in
            Task { @MainActor in AppIconChoice.apply() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if BrowserWindows.shared.mainManagers.isEmpty { self.openBrowserWindow() }
        }
        // the offer to move in from Arc, once, after the first window is up
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            Task { @MainActor in
                guard let manager = BrowserWindows.shared.mainManagers.first else { return }
                ArcMigration.offerOnFirstLaunch(into: manager)
            }
        }
    }

    /// clicking the Dock icon with every window closed brings one back
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if BrowserWindows.shared.mainManagers.isEmpty { openBrowserWindow() }
        return true
    }

    /// New Window, found by its shortcut since its title is localised
    private func openBrowserWindow() {
        let items = (NSApp.mainMenu?.items ?? []).compactMap(\.submenu).flatMap(\.items)
        guard
            let item = items.first(where: {
                $0.keyEquivalent == "n" && $0.keyEquivalentModifierMask == .command
            }), let action = item.action
        else { return }
        NSApp.sendAction(action, to: item.target, from: item)
    }

    /// a page handed off from another device opens in a tab, not a Scout window
    func application(
        _ application: NSApplication, continue userActivity: NSUserActivity,
        restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void
    ) -> Bool {
        guard userActivity.activityType == NSUserActivityTypeBrowsingWeb,
            let url = userActivity.webpageURL
        else { return false }
        Task { await openInBrowser([url]) }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        // files get tabs, all in one window; a web link gets a Scout window
        let files = urls.filter(\.isFileURL)
        if !files.isEmpty { Task { await openInBrowser(files) } }
        for url in urls where url.scheme == "http" || url.scheme == "https" { openScoutWindow(url) }
    }

    /// a tab per url in the front browser window, else in one opened for them, else in
    /// the manager the next window takes. before the first window registers,
    /// `Scripting.openWindow` waits for it
    private func openInBrowser(_ urls: [URL]) async {
        let windows = BrowserWindows.shared
        var manager = windows.browserScope
        if manager == nil { manager = await Scripting.openWindow(incognito: false) ?? windows.seed }
        guard let manager else { return }
        for url in urls { manager.revealTab(manager.newTab(url: url, select: true)) }
    }

    /// a Scout window on `url`, or a tab in its routed space when routing is direct
    /// and a browser window is open. needs no manager: the Scout window builds its own
    func openScoutWindow(_ url: URL) {
        if UserDefaults.standard.externalLinkRouting == .direct,
            let manager = BrowserWindows.shared.browserScope,
            let destination = manager.routedSpace(for: url)
        {
            manager.selectSpace(destination)
            let tab = manager.newTab(url: url, select: true)
            manager.revealTab(tab)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        ScoutWindow.open(url)
    }
}
