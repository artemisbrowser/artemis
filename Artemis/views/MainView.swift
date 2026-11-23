// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import SwiftUI

struct MainView: View {
    @Environment(TabManager.self) private var tabManager
    @Environment(TooltipState.self) private var tooltipState
    @Environment(\.openSettings) private var openSettings
    @AppStorage("sidebarWidth") private var sidebarWidth = 250.0
    @AppStorage("agentPanelWidth") private var agentPanelWidth = 360.0

    private static let sidebarWidthRange = 160.0...450.0
    private static let agentPanelWidthRange = 300.0...560.0
    /// a page narrower than this beside the agent panel keeps its width, and the panel floats over it
    private static let narrowestPageBesidePanel: CGFloat = 500
    /// how far the overlay's hover region hangs off its leading edge, so the
    /// peek's bounce past the window edge still counts as over the sidebar
    private static let overlayOvershootSlack: CGFloat = 12
    /// the peeking overlay's grab strip and trailing hover buffer
    private static let overlayGripWidth: CGFloat = 18
    private static let overlayBufferWidth: CGFloat = 10

    private var isSidebarCollapsed: Bool { tabManager.isSidebarCollapsed }
    /// the rim between the window edge and the web card; 0 makes the page the whole window
    @AppStorage(WindowChrome.edgeInsetKey) private var edgeInset = WindowChrome.defaultEdgeInset
    @AppStorage(BrowserToolbar.shownKey) private var showsToolbar = false
    @AppStorage(WindowChrome.sidebarOnRightKey) private var sidebarOnRight = false
    /// ms the cursor dwells on the edge before the sidebar peeks
    @AppStorage("sidebarRevealDelay") private var sidebarRevealDelay = 100.0
    /// width in pt of the window-edge strip that catches the hover
    @AppStorage("sidebarHoverAreaWidth") private var sidebarHoverAreaWidth = 8.0
    /// seconds the peek's slide-in runs; its bounce is fixed
    @AppStorage("sidebarRevealDuration") private var sidebarRevealDuration = 0.2
    /// set only from the onChange handlers, never mid-render
    @State private var isSidebarOverlayVisible = false
    /// the overlay's panel: mounted while collapsed, but not while the pinned sidebar slides away
    @State private var isOverlayPanelUp = false
    @State private var overlayPanelMount: Task<Void, Never>?
    @State private var isOverlayHovered = false
    /// a context menu takes the cursor's hover for as long as it is open
    @State private var isMenuOpen = false
    /// the overlay is springing in; its overshoot uncovering the edge strip is not "mouse left"
    @State private var overlayEntering = false
    @State private var overlayEnterTask: Task<Void, Never>?
    /// waits out the spring of a sidebar pinned from off the window before it counts as settled
    @State private var pinSlide: Task<Void, Never>?
    @State private var isResizingSidebar = false
    @State private var isFullScreen = false
    @State private var windowSize = CGSize(width: 1000, height: 700)
    @State private var edgeHoverTask: Task<Void, Never>?
    @State private var overlayDismissTask: Task<Void, Never>?
    @State private var collapseDismissTask: Task<Void, Never>?

    /// owned here, not by Sidebar, so a tab dragged out of the list can drop onto the page
    @State private var drag = SidebarDragState()
    /// a pane being dragged around its split to re-tile it
    @State private var rearrange = RearrangeDragState()
    @State private var frames = CardFrames()
    @State private var contentDragMonitor: Any?
    /// outlives the dragged pane's handle, which unmounts once the pane leaves the layout
    @State private var rearrangeMonitor: Any?

    /// fullscreen with the sidebar away: pure content, no rim, no rounding
    private var isEdgeToEdge: Bool { isFullScreen && isSidebarCollapsed }

    /// the sidebar as drawn: the Library has its own width, the same in every space
    private var shownSidebarWidth: CGFloat {
        tabManager.isLibraryOpen ? LibrarySidebar.sidebarWidth : sidebarWidth
    }

    var body: some View {
        let _ = Bench.tick("MainView")
        let _ = Bench.markOnce("MainView: first body")
        // the sidebar floats over the card; both are AppKit-placed hosts. the
        // traffic lights live inside the sidebar, so they move with its view
        BrowserShell(
            sidebar: hosted(sidebarRig),
            content: hosted(cardArea),
            panel: hosted(agentPanel),
            placement: shellPlacement,
            cause: .init(
                collapsed: isSidebarCollapsed, overlayVisible: isSidebarOverlayVisible,
                libraryOpen: tabManager.isLibraryOpen, panelOpen: tabManager.isAgentPanelVisible),
            revealDuration: sidebarRevealDuration, sidebarScroll: tabManager.sidebarScroll)
        .onChange(of: drag.isDragging) { _, dragging in
            if dragging { startContentDragMonitor() } else { stopContentDragMonitor() }
        }
        .onChange(of: rearrange.isDragging) { _, dragging in
            // incoming sidebar drags are driven by the content monitor + sidebar
            // commit; only the in-split pane rearrange needs this monitor
            if dragging, !rearrange.incoming { startRearrangeMonitor() }
            else if !dragging { stopRearrangeMonitor() }
        }
        // posted for every window, WebKit's element fullscreen too: each reads this window's mask
        .onReceive(
            NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)
        ) { _ in
            isFullScreen = BrowserWindows.shared.window(of: tabManager)?.styleMask.contains(.fullScreen) == true
        }
        .onReceive(
            NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)
        ) { _ in
            isFullScreen = BrowserWindows.shared.window(of: tabManager)?.styleMask.contains(.fullScreen) == true
        }
        // the grab strip when the rim is too thin to hold one; it must sit above
        // the sidebar's overlay or the sidebar's side of the seam loses its clicks
        .overlay(alignment: .leading) {
            if !isSidebarCollapsed, edgeInset < WindowChrome.minGrabWidth {
                resizeHandle(width: Self.seamGrabWidth)
                    // padding, not .offset: offset is render-only and leaves the AppKit hit area behind
                    .padding(.leading, pinnedFootprint - Self.seamGrabWidth / 2)
            }
        }
        .animation(Motion.panel, value: tabManager.isLibraryOpen)
        // the panel's edge, gripped as the sidebar's is: the whole rim when it is wide enough, else astride the seam
        .overlay(alignment: .trailing) {
            if tabManager.isAgentPanelVisible {
                let inRim = isAgentPanelDocked && rim >= WindowChrome.minGrabWidth
                SidebarResizeHandle(width: $agentPanelWidth, range: Self.agentPanelWidthRange)
                    // a drag away from the window's edge widens the panel
                    .environment(\.layoutDirection, direction == .leftToRight ? .rightToLeft : .leftToRight)
                    .frame(width: inRim ? rim : Self.seamGrabWidth)
                    .padding(.trailing, agentPanelWidth - (inRim ? 0 : Self.seamGrabWidth / 2))
            }
        }
        .overlay(alignment: .bottomLeading) {
            // the sidebar's download pill is off-screen with it, so downloads show over the page's corner
            if isSidebarCollapsed, !isSidebarOverlayVisible {
                DownloadPill(isLanding: true)
                    .frame(width: 240)
                    .padding(.leading, max(edgeInset, 0) + 12)
                    .padding(.bottom, max(edgeInset, 0) + 12)
                    .environment(\.chromeInk, tabManager.blendedInk)
            }
        }
        .animation(Motion.pop, value: isSidebarCollapsed && DownloadManager.shared.shelf.isEmpty)
        .overlay(alignment: .leading) {
            // collapsed with the rig away: hover the window edge to peek it back
            if isSidebarCollapsed, !isSidebarOverlayVisible {
                edgeRevealZone
                    // its top corner, out to the rim, drags the window like the band beside it
                    .overlay(alignment: .topLeading) {
                        WindowDragStrip()
                            .frame(width: max(rim, sidebarHoverAreaWidth), height: max(rim, PageDragBand.height))
                    }
            }
        }
        // right mode is left mode laid out right to left; the hosts take it in `hosted`
        .environment(\.layoutDirection, direction)
        .onChange(of: isSidebarCollapsed) { _, collapsed in
            // collapsing under the pointer hands over to the overlay in place until the mouse leaves;
            // from the keyboard or a menu, with the pointer elsewhere, it slides away now
            let handOver = collapsed && (isOverlayHovered || pointerInsideRig)
            // an address grown from the sidebar's pill closes into it as the sidebar goes;
            // handed over to the overlay, it stays open on the pill
            if collapsed, !handOver, let origin = tabManager.addressBarOrigin, !origin.isEmpty {
                withAnimation(Motion.address) {
                    tabManager.addressBarOrigin = origin.offsetBy(dx: sidebarOnRight ? rigContentWidth : -rigContentWidth, dy: 0)
                    tabManager.isCommandBarVisible = false
                }
            }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                isSidebarOverlayVisible = handOver
                if !collapsed { isOverlayPanelUp = false }
            }
            if handOver { withAnimation(Motion.sidebar) { isOverlayPanelUp = true } }
            collapseDismissTask?.cancel()
            if handOver {
                collapseDismissTask = Task {
                    try? await Task.sleep(for: .seconds(2))
                    if !Task.isCancelled, !overlayHeld, !isMenuOpen, !tabManager.isSidebarPopoverOpen {
                        isSidebarOverlayVisible = false
                    }
                }
            }
        }
        // a window drag begun on the overlay holds it open; released with the
        // cursor off it, it goes — the same rule as the resize handle
        .onChange(of: tabManager.isDraggingWindow) { _, dragging in
            if !dragging, isSidebarCollapsed, isSidebarOverlayVisible, !overlayHeld {
                isSidebarOverlayVisible = false
            }
        }
        .onChange(of: isSidebarOverlayVisible) { _, visible in
            if visible, isSidebarCollapsed { isOverlayPanelUp = true }
            overlayEnterTask?.cancel()
            if visible {
                overlayEntering = true
                overlayEnterTask = Task {
                    try? await Task.sleep(for: .milliseconds(500))
                    if !Task.isCancelled { overlayEntering = false }
                }
            } else {
                overlayEntering = false
            }
        }
        .onChange(of: tabManager.sidebarPeekRequest) {
            if isSidebarCollapsed { isSidebarOverlayVisible = true }
        }
        .onChange(of: tabManager.sidebarGlanceRequest) {
            guard isSidebarCollapsed else { return }
            isSidebarOverlayVisible = true
            collapseDismissTask?.cancel()
            collapseDismissTask = Task {
                try? await Task.sleep(for: .seconds(2))
                if !Task.isCancelled, !overlayHeld, !isMenuOpen, !tabManager.isSidebarPopoverOpen {
                    isSidebarOverlayVisible = false
                }
            }
        }
        .onChange(of: tabManager.isSidebarPopoverOpen) { _, open in
            if !open { releaseOverlayHold() }
        }
        .onChange(of: isEditingPillAddress) { _, editing in
            if !editing { releaseOverlayHold() }
        }
        // hidden, the panel mounts once the slide has gone, so a first peek finds its frost ready
        .onChange(of: isSidebarRevealed, initial: true) { _, revealed in
            overlayPanelMount?.cancel()
            guard !revealed else { return }
            overlayPanelMount = Task {
                try? await Task.sleep(for: .seconds(Motion.sidebarSpring.settlingDuration))
                if !Task.isCancelled, isSidebarCollapsed { isOverlayPanelUp = true }
            }
        }
        .onChange(of: isSidebarRevealed && !overlayEntering, initial: true) { was, settled in
            pinSlide?.cancel()
            guard settled, !was, !isSidebarCollapsed else { return tabManager.isSidebarSettled = settled }
            pinSlide = Task {
                try? await Task.sleep(for: .seconds(Motion.sidebarSpring.settlingDuration))
                if !Task.isCancelled { tabManager.isSidebarSettled = true }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in
            isMenuOpen = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)) { _ in
            isMenuOpen = false
            releaseOverlayHold()
        }
        // each overlay animates only its own subtree: a root-level animation
        // would also animate whatever else changes in the same transaction
        .overlay { OnboardingOverlay() }
        .overlay { WhatsNewOverlay() }
        .overlay { CommandBarOverlay() }
        // ⌘L, a new blank tab, first launch
        .onChange(of: tabManager.urlFieldFocusRequest) { tabManager.editAddress() }
        .overlay {
            spaceCreatorOverlay
                .animation(Motion.fade, value: tabManager.isSpaceCreatorVisible)
        }
        .overlay {
            importOverlay
                .animation(Motion.fade, value: tabManager.importer == nil)
        }
        .overlay {
            Group {
                if let peek = tabManager.peekTab {
                    PeekView(tab: peek)
                }
            }
            .animation(Motion.fade, value: tabManager.peekTab?.id)
        }
        .overlay { TabSwitcherOverlay() }
        .overlay {
            feedbackOverlay
                .animation(Motion.fade, value: tabManager.feedback == nil)
        }
        .overlay {
            liveFolderOverlay
                .animation(Motion.fade, value: tabManager.liveFolderDraft == nil)
        }
        .overlay {
            giftOverlay
                .animation(Motion.pop, value: tabManager.isGiftVisible)
        }
        .background {
            // pinning from the peek swaps in place
            WindowBackdrop(sidebarPinned: !isSidebarCollapsed, animatesPin: !isSidebarOverlayVisible)
                .animation(Motion.panel, value: tabManager.isLibraryOpen)
                // the pinned sidebar's frost strip sits on its leading side
                .environment(\.layoutDirection, direction)
        }
        .onGeometryChange(for: CGSize.self, of: { $0.size }) { windowSize = $0 }
        .background {
            WindowTransparency(onWindow: { window in
                if PerfFlags.dragsWindowDirectly { window.isMovable = false }
                tooltipState.window = window
            })
        }
        .ignoresSafeArea()
        // the window drags itself: from the rim and the chrome's empty rows (see
        // WindowDragStrip), and from wherever a page meets the window's top edge
        .background { PageDragBand() }
        .overlay { TooltipLayer() }
        .frame(minWidth: max(440, isSidebarCollapsed ? 0 : pinnedFootprint), minHeight: 280)
        .onAppear { SettingsView.openSettingsAction = openSettings }
        .task {
            // a window opening on an empty space or a blank page shows the ⌘T bar
            if tabManager.selectedTab?.isBlank ?? true, !SpaceLock.shared.isLocked(tabManager.currentSpace) {
                tabManager.openNewTabBar()
            }
            // everything below runs once per app, not per window
            guard BrowserWindows.shared.claimLaunchWork() else { return }

            if Intelligence.isOn(Intelligence.tidyTitlesKey) {
                Task { await Intelligence.shared.prewarmChores() }
            }
            // dev hook: ARTEMIS_DIAG=ext dumps extension runtime state
            if SelfTest.isExtensionsDiagRequested {
                Task { await SelfTest.runExtensionsDiag(manager: tabManager) }
            }
            // dev hook: ARTEMIS_DIAG=popup reads what an extension's popup renders
            if SelfTest.isPopupDiagRequested {
                Task { await SelfTest.runPopupDiag(manager: tabManager) }
            }
            if ExtensionLab.isSweep {
                Task { await ExtensionLab.run(manager: tabManager) }
            }
            // dev hook: ARTEMIS_DIAG=ai checks the on-device model inside the sandbox
            if SelfTest.isIntelligenceDiagRequested {
                Task { await SelfTest.runIntelligenceDiag(manager: tabManager) }
            }
            // dev hook: ARTEMIS_DIAG=capture checks a real getUserMedia grant
            if SelfTest.isCaptureDiagRequested {
                Task { await SelfTest.runCaptureDiag(manager: tabManager) }
            }
            // dev hook: ARTEMIS_DIAG=pw installs/inspects Bitwarden end to end
            if SelfTest.isPasswordDiagRequested {
                Task { await SelfTest.runPasswordManagerDiag(manager: tabManager) }
            }
            // dev hook: ARTEMIS_DIAG=names benches tab renaming (speed + stability)
            if SelfTest.isNameBenchRequested {
                Task { await SelfTest.runNameBench() }
            }
            // dev hook: ARTEMIS_DIAG=corpus records what real sites offer a tab namer
            if SelfTest.isCorpusDiagRequested {
                Task { await SelfTest.runCorpusDiag(manager: tabManager) }
            }
            // dev hook: ARTEMIS_DIAG=corpus-clean takes that corpus back out of history
            if SelfTest.isCorpusCleanRequested {
                Task { await SelfTest.runCorpusClean(manager: tabManager) }
            }
            // dev hook: ARTEMIS_DIAG=sweep replays that corpus against every prompt × context depth
            if SelfTest.isSweepDiagRequested {
                Task { await SelfTest.runSweepDiag() }
            }
            // dev hook: ARTEMIS_BENCH=launch times the cold start and quits
            if Bench.isLaunchRequested {
                await Bench.reportLaunch()
            }
            // dev hook: ARTEMIS_BENCH drives the perf script and quits
            if Bench.isRequested {
                try? await Task.sleep(for: .seconds(1))
                await Bench.run(manager: tabManager)
            }
            // dev hook: ARTEMIS_SELFTEST runs the end-to-end suite and quits
            if SelfTest.isRequested {
                try? await Task.sleep(for: .seconds(1))
                await SelfTest.run(manager: tabManager)
            }
            // dev hook: ARTEMIS_TEST_URL loads a page once the UI is up
            if let raw = ProcessInfo.processInfo.environment["ARTEMIS_TEST_URL"],
                let url = URL(string: raw)
            {
                try? await Task.sleep(for: .seconds(1))
                tabManager.selectedTab?.load(url)
            }
        }
        // outermost, so the sidebar, its overlay and the content share one drag state
        .environment(drag)
        .environment(rearrange)
    }

    /// the new-space dialog, modal over everything: a scrim dims the window and
    /// a tap on it cancels (no space exists until the dialog's Create)
    @ViewBuilder
    private var spaceCreatorOverlay: some View {
        if tabManager.isSpaceCreatorVisible {
            ZStack {
                Color.black.opacity(0.25)
                    .contentShape(Rectangle())
                    .onTapGesture { tabManager.isSpaceCreatorVisible = false }
                SpaceCreator()
                    .offset(y: -20)  // optically centered, slightly high
            }
        }
    }

    /// import from another browser, modal over everything like the space creator:
    /// the scrim's tap cancels unless an import is running
    @ViewBuilder
    private var importOverlay: some View {
        if let model = tabManager.importer {
            ZStack {
                Color.black.opacity(0.25)
                    .contentShape(Rectangle())
                    .onTapGesture { model.cancel(in: tabManager) }
                ImportSheet(model: model)
                    .offset(y: -20)
            }
        }
    }

    /// Send Feedback, modal like the space creator. The scrim only closes it
    /// while nothing has been written
    @ViewBuilder
    private var feedbackOverlay: some View {
        if let draft = tabManager.feedback {
            ZStack {
                Color.black.opacity(0.25)
                    .contentShape(Rectangle())
                    .onTapGesture { if draft.message.isEmpty { tabManager.feedback = nil } }
                FeedbackSheet(draft: draft)
                    .offset(y: -20)
            }
        }
    }

    /// New Live Folder, modal like Send Feedback
    @ViewBuilder
    private var liveFolderOverlay: some View {
        if let draft = tabManager.liveFolderDraft {
            ZStack {
                Color.black.opacity(0.25)
                    .contentShape(Rectangle())
                    .onTapGesture { tabManager.liveFolderDraft = nil }
                LiveFolderSheet(draft: draft)
                    .offset(y: -20)
            }
        }
    }

    /// Gift Artemis to a Friend; the scrim closes it
    private var giftOverlay: some View {
        ZStack {
            if tabManager.isGiftVisible {
                Color.black.opacity(0.25)
                    .contentShape(Rectangle())
                    .onTapGesture { tabManager.isGiftVisible = false }
                    .transition(.opacity)
                GiftCard(manager: tabManager)
                    .offset(y: -20)
                    .transition(Motion.grow(from: 0.9))
            }
        }
    }

    /// a menu or popover that held the overlay open has let go: dismiss it if the
    /// cursor wandered off meanwhile. the delay lets a follow-on popover claim it
    private func releaseOverlayHold() {
        guard isSidebarCollapsed, isSidebarOverlayVisible else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            if !overlayHeld, !isMenuOpen, !tabManager.isSidebarPopoverOpen {
                isSidebarOverlayVisible = false
            }
        }
    }

    /// thin strip on the window edge, and the band past it off the window; a pointer that came for either peeks the sidebar
    private var edgeRevealZone: some View {
        Color.clear
            .frame(width: sidebarHoverAreaWidth)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .background(EdgeOverhang(strip: sidebarHoverAreaWidth, onHover: edgeHovered))
    }

    private func edgeHovered(_ hovering: Bool, offWindow: Bool) {
        let window = BrowserWindows.shared.window(of: tabManager)
        edgeHoverTask?.cancel()
        guard hovering else { return }
        edgeHoverTask = Task {
            try? await Task.sleep(for: .milliseconds(Int(sidebarRevealDelay)))
            guard !Task.isCancelled else { return }
            isSidebarOverlayVisible = true
            guard offWindow else { return }
            // the overlay's own hover never began, so its leaving is watched here until it does
            overlayDismissTask?.cancel()
            overlayDismissTask = Task {
                repeat {
                    try? await Task.sleep(for: .milliseconds(150))
                } while !Task.isCancelled
                    && (EdgeOverhang.contains(window) || pointerInsideRig)
                guard !Task.isCancelled, !overlayHeld, !isMenuOpen, !tabManager.isSidebarPopoverOpen else { return }
                isSidebarOverlayVisible = false
            }
        }
    }

    // MARK: - The sidebar rig

    /// the sidebar is on screen — pinned, or peeking as the overlay
    private var isSidebarRevealed: Bool { !isSidebarCollapsed || isSidebarOverlayVisible }

    /// the pointer is over the overlay rig, measured in this window whether or
    /// not it is key. geometry, not hover: AppKit views inside the sidebar (the
    /// drag strip, the url field) take the pointer from SwiftUI's hover
    private var pointerInsideRig: Bool {
        guard let window = BrowserWindows.shared.window(of: tabManager) else { return false }
        let p = window.mouseLocationOutsideOfEventStream
        let x = sidebarOnRight ? window.frame.width - p.x : p.x
        return x >= 0 && x <= rigContentWidth && p.y >= 0 && p.y <= window.frame.height
    }

    /// what every dismiss path asks before letting the overlay go
    private var overlayHeld: Bool { isOverlayHovered || pointerInsideRig || isEditingPillAddress }
    /// the address bar grown out of the overlay's pill keeps the overlay up until it closes
    private var isEditingPillAddress: Bool { tabManager.addressBarOrigin.map { !$0.isEmpty } ?? false }

    /// the grab strip beside the sidebar: its own width in the overlay, the rim
    /// when pinned, or nothing when the rim is too thin to grab (the seam handle covers it)
    private var rigGripWidth: CGFloat {
        if isSidebarCollapsed { return Self.overlayGripWidth }
        return edgeInset >= WindowChrome.minGrabWidth ? edgeInset : 0
    }

    /// what the card yields when the sidebar is pinned; the hover buffer takes no room
    private var pinnedFootprint: CGFloat {
        shownSidebarWidth + rigGripWidth
    }

    /// everything that slides: sidebar + grip + hover buffer
    private var rigContentWidth: CGFloat {
        shownSidebarWidth + rigGripWidth + Self.overlayBufferWidth
    }

    /// the one sidebar, floating at the window's leading edge in both modes;
    /// BrowserShell slides its host
    private var sidebarRig: some View {
        HStack(spacing: 0) {
            Sidebar(width: sidebarWidth)
                .frame(width: shownSidebarWidth)
                .frame(maxHeight: .infinity)
                // overlay mode: empty sidebar areas must not click through to the page
                .background {
                    if isOverlayPanelUp { Color.black.opacity(0.001) }
                }
                // pinned mode shows the window's backdrop instead
                .background(alignment: .leading) {
                    if isOverlayPanelUp {
                        OverlayPanelBackground(
                            width: shownSidebarWidth + edgeInset,
                            windowWidth: windowSize.width)
                    }
                }

            if tabManager.isLibraryOpen {
                Color.clear.frame(width: rigGripWidth)
            } else {
                resizeHandle(width: rigGripWidth)
            }

            // extends the overlay's hover area past the grip
            Color.clear
                .frame(width: Self.overlayBufferWidth)
                .frame(maxHeight: .infinity)
        }
        .padding(.leading, Self.overlayOvershootSlack)
        .overlay(alignment: .leading) {
            Color.clear
                .frame(width: Self.overlayOvershootSlack)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .onHover { hovering in
            guard isSidebarCollapsed else { return }
            isOverlayHovered = hovering
            overlayDismissTask?.cancel()
            guard !hovering else { return }
            // a context menu or brief overshoot steals hover for a moment
            overlayDismissTask = Task {
                try? await Task.sleep(for: .milliseconds(120))
                while pointerInsideRig {
                    try? await Task.sleep(for: .milliseconds(150))
                    if Task.isCancelled { return }
                }
                guard !Task.isCancelled, !isOverlayHovered, !isEditingPillAddress, !isResizingSidebar,
                    !tabManager.isDraggingWindow, !overlayEntering, !isMenuOpen,
                    !tabManager.isSidebarPopoverOpen
                else { return }
                isSidebarOverlayVisible = false
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // pinning or unpinning snaps the rig, which keeps its pinned look while it slides;
        // only the overlay wears the panel
        .animation(nil, value: isSidebarCollapsed)
        .animation(Motion.panel, value: tabManager.isLibraryOpen)
    }

    /// where the shell puts the sidebar and the card. the sidebar host is as wide
    /// as the rig ever gets, so pinning or opening the Library never resizes it;
    /// past the grip it passes clicks through unless a folder's peek hangs there
    private var shellPlacement: BrowserShell<AnyView, AnyView, AnyView>.Placement {
        let slack = Self.overlayOvershootSlack
        let rig = shownSidebarWidth
        let peek = tabManager.isFolderPeekOpen ? FolderPeek.width + 10 : 0
        let hostWidth =
            slack + max(sidebarWidth, LibrarySidebar.sidebarWidth) + max(Self.overlayGripWidth, edgeInset)
            + Self.overlayBufferWidth + peek
        return .init(
            sidebarX: isSidebarRevealed ? -slack : -hostWidth,
            sidebarWidth: hostWidth,
            sidebarPassLeading: slack,
            sidebarPassTrailing: peek > 0 ? 0 : hostWidth - (slack + rig + rigGripWidth),
            contentX: contentX,
            contentTrailing: isAgentPanelDocked ? agentPanelWidth : 0,
            panelInset: tabManager.isAgentPanelVisible ? agentPanelWidth : 0,
            panelWidth: agentPanelWidth)
    }

    private var contentX: CGFloat { isSidebarCollapsed ? (isEdgeToEdge ? 0 : edgeInset) : pinnedFootprint }

    /// the panel takes its width from the page rather than floating over it
    private var isAgentPanelDocked: Bool {
        tabManager.isAgentPanelVisible && !isAgentPanelFloating
    }

    private var isAgentPanelFloating: Bool {
        windowSize.width - contentX - agentPanelWidth - rim < Self.narrowestPageBesidePanel
    }

    /// on the window edge opposite the sidebar: docked on the backdrop, or floating with the overlay sidebar's glass
    private var agentPanel: some View {
        AgentPanel()
            .background {
                if isAgentPanelFloating {
                    OverlayPanelBackground(width: agentPanelWidth, windowWidth: windowSize.width)
                        .environment(\.layoutDirection, sidebarOnRight ? .leftToRight : .rightToLeft)
                }
            }
            .environment(\.chromeInk, tabManager.blendedInk)
            .environment(\.colorScheme, RGBA(tabManager.blendedInk).brightness < 0.5 ? .light : .dark)
            .environment(\.layoutDirection, .leftToRight)
    }

    /// a modal over the window takes the pointer from everything under it
    private var isModalOverlayUp: Bool {
        tabManager.peekTab != nil || tabManager.isSpaceCreatorVisible
            || tabManager.importer != nil
            || tabManager.feedback != nil || tabManager.liveFolderDraft != nil || tabManager.isGiftVisible
    }

    /// a hosted region gets none of the window root's environment on its own
    private func hosted(_ view: some View) -> AnyView {
        AnyView(
            view
                .allowsHitTesting(!isModalOverlayUp)
                .ignoresSafeArea()
                .environment(tabManager)
                .environment(tooltipState)
                .environment(ExtensionManager.shared)
                .environment(drag)
                .environment(rearrange)
                .environment(\.layoutDirection, direction))
    }

    private var direction: LayoutDirection { sidebarOnRight ? .rightToLeft : .leftToRight }

    private var rim: CGFloat { isEdgeToEdge ? 0 : CGFloat(edgeInset) }
    /// below the toolbar the page keeps its rim, but never touches the row
    private var toolbarGap: CGFloat { max(rim, BrowserToolbar.top) }

    /// the web card with its rim, as the shell's content host shows it
    private var cardArea: some View {
        VStack(spacing: 0) {
            if showsToolbar {
                BrowserToolbar()
                    .animation(Motion.sidebar) {
                        $0.padding(.top, BrowserToolbar.top)
                            .padding(.leading, rim == 0 && isSidebarCollapsed ? BrowserToolbar.top : 0)
                            .padding(.trailing, toolbarGap)
                    }
            }
            webCard
                .overlay { LinkHoverCapsule().allowsHitTesting(false) }
                // only the rim animates: the host's own resize, already glided by the shell, lands as is
                .animation(Motion.sidebar) {
                    $0.padding(.top, showsToolbar ? toolbarGap : rim)
                        .padding([.trailing, .bottom], rim)
                }
                // the visible card frame, for drag-to-split
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) {
                    frames.contentFrame = $0
                }
        }
        // behind everything: the rim, the toolbar row's gaps and an empty space's card
        .background(WindowDragStrip())
    }

    /// invisible grab strip between sidebar and web card
    private func resizeHandle(width: CGFloat) -> some View {
        SidebarResizeHandle(
            width: $sidebarWidth,
            range: Self.sidebarWidthRange,
            scrollerThumb: { [drag] in drag.scrollerThumb },
            scroll: tabManager.sidebarScroll,
            onDraggingChanged: { dragging in
                isResizingSidebar = dragging
                if !dragging, !overlayHeld {
                    isSidebarOverlayVisible = false
                }
            }
        )
        .frame(width: width)
    }

    /// the grab strip's width when it straddles the seam rather than sitting in a rim
    private static let seamGrabWidth: CGFloat = 16

    /// flush to a pinned sidebar, the card rounds its sidebar side so the sidebar reads as tucked behind it
    private var cardShape: UnevenRoundedRectangle {
        let radius = isEdgeToEdge ? 0 : WindowChrome.cardRadius(inset: edgeInset)
        let near = radius == 0 && !isSidebarCollapsed ? WindowChrome.outerWindowRadius : radius
        let far = radius == 0 && isAgentPanelDocked ? WindowChrome.outerWindowRadius : radius
        return UnevenRoundedRectangle(
            topLeadingRadius: near, bottomLeadingRadius: near,
            bottomTrailingRadius: far, topTrailingRadius: far, style: .continuous)
    }

    @ViewBuilder
    private var webCard: some View {
        GeometryReader { geo in
            CardStack(shape: cardShape)
            // GeometryReader places content at its natural size
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // the rearrange gesture, the panes' frames and this overlay all share
            // one space, anchored to the card's top-left
            .coordinateSpace(.named(splitRearrangeSpace))
            .onAppear {
                rearrange.containerSize = geo.size
                frames.cardFrame = geo.frame(in: .global)
            }
            .onChange(of: geo.size) { _, s in rearrange.containerSize = s }
            .onChange(of: geo.frame(in: .global)) { _, f in frames.cardFrame = f }
        }
        .overlay { CommandBarPageShield() }
        .overlay(alignment: .topTrailing) { CardCornerControls() }
        // a site's camera, microphone or location request sits over its page
        .overlay(alignment: .topLeading) {
            if let request = tabManager.currentPermissionRequest {
                PermissionPrompt(request: request)
                    .environment(\.layoutDirection, .leftToRight)
                    .padding(14)
                    .transition(Motion.slide(.top))
            }
        }
        .animation(Motion.panel, value: tabManager.currentPermissionRequest?.id)
    }

    // MARK: - Drag-to-split

    /// whether dropping the dragged tab on the page would do something: add to the
    /// shown split (with room), or tile with a distinct focused page
    private func contentSplitEligible(_ tab: BrowserTab) -> Bool {
        if let group = tabManager.displayedSplitGroup {
            return group.tabIDs.count < SplitGroup.maxPanes && !group.contains(tab.id)
        }
        guard let focused = tabManager.selectedTab, focused.id != tab.id, !focused.isEssential,
            tabManager.currentSpace.tabs.contains(where: { $0.id == focused.id }),
            tabManager.currentSpace.splitGroup(containing: tab.id) == nil
        else { return false }
        return true
    }

    /// while a sidebar drag is live, follows the cursor over the page; the event passes through untouched
    private func startContentDragMonitor() {
        stopContentDragMonitor()
        contentDragMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged]) { event in
            updateContentDrop(event)
            return event
        }
    }

    private func stopContentDragMonitor() {
        if let contentDragMonitor { NSEvent.removeMonitor(contentDragMonitor) }
        contentDragMonitor = nil
        drag.isOverContent = false
        if rearrange.incoming { rearrange.clear() }
    }

    /// drives the rearrange overlay as an incoming drag while a sidebar tab is over
    /// the content
    private func updateContentDrop(_ event: NSEvent) {
        guard drag.isDragging, let tab = drag.tab, !tab.isEssential,
            drag.group == nil,  // dragging a whole split isn't a content drop
            frames.contentFrame != .zero, contentSplitEligible(tab),
            let content = event.window?.contentView
        else {
            clearContentDrop()
            return
        }
        // NSEvent is bottom-left origin; SwiftUI .global is top-left
        let point = CGPoint(
            x: event.locationInWindow.x,
            y: content.bounds.height - event.locationInWindow.y)
        // the overlay sidebar sits inside contentFrame but isn't a content drop
        guard frames.contentFrame.contains(point), !drag.sidebarFrame.contains(point) else {
            clearContentDrop()
            return
        }

        if !drag.isOverContent { drag.isOverContent = true }

        let group = tabManager.displayedSplitGroup
        let single = group == nil ? tabManager.selectedTab?.id : nil
        let local = CGPoint(x: point.x - frames.cardFrame.minX, y: point.y - frames.cardFrame.minY)
        rearrange.beginIncoming(tab: tab.id, group: group, singlePaneTab: single, at: local)
    }

    private func clearContentDrop() {
        if drag.isOverContent { drag.isOverContent = false }
        if rearrange.incoming { rearrange.clear() }
    }

    // MARK: - In-split pane rearrange monitor

    private func startRearrangeMonitor() {
        stopRearrangeMonitor()
        rearrangeMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDragged, .leftMouseUp]
        ) { event in
            if event.type == .leftMouseUp {
                commitRearrange()
            } else {
                updateRearrangeCursor(event)
            }
            return event
        }
    }

    private func stopRearrangeMonitor() {
        if let rearrangeMonitor { NSEvent.removeMonitor(rearrangeMonitor) }
        rearrangeMonitor = nil
    }

    private func updateRearrangeCursor(_ event: NSEvent) {
        guard rearrange.isDragging, !rearrange.incoming,
            let content = event.window?.contentView
        else { return }
        // NSEvent is bottom-left origin; SwiftUI .global is top-left
        let point = CGPoint(
            x: event.locationInWindow.x,
            y: content.bounds.height - event.locationInWindow.y)
        rearrange.cursor = CGPoint(x: point.x - frames.cardFrame.minX, y: point.y - frames.cardFrame.minY)
    }

    private func commitRearrange() {
        defer {
            rearrange.clear()
            stopRearrangeMonitor()
        }
        guard !rearrange.incoming, let group = rearrange.group,
            let action = rearrange.commitAction()
        else { return }
        withAnimation(Motion.pop) { tabManager.rearrangeSplit(group, action) }
    }
}

/// the command bar over the window, in a view of its own so opening and closing
/// it re-runs this rather than the window body
private struct CommandBarOverlay: View {
    @Environment(TabManager.self) private var tabManager
    @Environment(TooltipState.self) private var tooltipState

    var body: some View {
        // no scrim: the page and the sidebar's edge reveal stay live
        let shown = tabManager.isCommandBarVisible && tabManager.addressBarOrigin == nil
        ZStack {
            GeometryReader { geo in
                if let origin = tabManager.addressBarOrigin {
                    let window = geo.frame(in: .global).origin
                    AddressBar(
                        origin: origin.isEmpty ? .zero : origin.offsetBy(dx: -window.x, dy: -window.y),
                        size: geo.size)
                        .transition(.asymmetric(insertion: .identity, removal: .opacity))
                }
            }
            CommandBarLayer(
                shown: shown, address: tabManager.commandBarEditsAddress, tabManager: tabManager,
                tooltipState: tooltipState)
                .allowsHitTesting(shown)
        }
        .animation(Motion.pop, value: tabManager.isCommandBarVisible)
    }
}

/// the ⌘T bar in a hosting view of its own, whose layer runs the grow and fade
/// in Core Animation on `Motion.popSpring`, scaled about the overlay's top centre
private struct CommandBarLayer: NSViewRepresentable {
    let shown: Bool
    let address: Bool
    let tabManager: TabManager
    let tooltipState: TooltipState

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: CommandBarHost, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    func makeNSView(context: Context) -> CommandBarHost {
        let host = CommandBarHost(rootView: CommandBarRoot(environment: environment(context)))
        host.holdEarlyKeys()
        host.sizingOptions = []
        host.safeAreaRegions = []
        host.isHidden = true
        return host
    }

    func updateNSView(_ host: CommandBarHost, context: Context) {
        host.update(
            shown: shown, address: address, environment: environment(context),
            animated: !context.transaction.disablesAnimations)
    }

    private func environment(_ context: Context) -> CommandBarRoot.Environment {
        .init(
            tabManager: tabManager, tooltipState: tooltipState, colorScheme: context.environment.colorScheme,
            layoutDirection: context.environment.layoutDirection)
    }
}

struct CommandBarRoot: View {
    /// nil while unmounted
    var bar: Bar?
    let environment: Environment
    var report: (CGRect) -> Void = { _ in }

    var body: some View {
        GeometryReader { geo in
            if let bar {
                // a fresh bar each time it opens or switches between new tab and address
                CommandBar(address: bar.address, live: bar.live)
                    .id(bar.mount)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("commandBarHost")) } action: { report($0) }
                    .frame(maxWidth: .infinity)
                    .padding(.top, geo.size.height * 0.2)
            }
        }
        .coordinateSpace(.named("commandBarHost"))
        .environment(environment.tabManager)
        .environment(environment.tooltipState)
        .environment(ExtensionManager.shared)
        .environment(\.colorScheme, environment.colorScheme)
        .environment(\.layoutDirection, environment.layoutDirection)
    }

    struct Bar {
        let address: Bool
        let mount: Int
        /// false from the moment it starts to close
        let live: () -> Bool
    }

    /// a hosted view gets none of the window root's environment on its own
    struct Environment {
        let tabManager: TabManager
        let tooltipState: TooltipState
        let colorScheme: ColorScheme
        let layoutDirection: LayoutDirection
    }
}

final class CommandBarHost: NSHostingView<CommandBarRoot> {
    private(set) var shown = false
    /// where the bar is, in this view's flipped coordinates; clicks elsewhere pass through
    private var barRect = CGRect.zero
    /// the grow's progress: 0 hidden, 1 shown, on `Motion.popSpring` from `start`
    private var from: CGFloat = 0
    private var target: CGFloat = 0
    private var startVelocity: CGFloat = 0
    private var start: CFTimeInterval = 0
    private var generation = 0

    private var address = false
    private var mount = 0

    func update(shown: Bool, address: Bool, environment: CommandBarRoot.Environment, animated: Bool) {
        if shown {
            if !self.shown || address != self.address { mount += 1 }
            self.address = address
        }
        let changed = shown != self.shown
        self.shown = shown
        if changed {
            hadKeyboard = false
            shownAt = CACurrentMediaTime()
            staleField = (window?.firstResponder as? NSTextView)?.delegate
        }
        if shown || changed && !PerfFlags.leavesClosingBarAlone { render(environment) }
        guard changed else { return }
        generation += 1
        if shown {
            isHidden = false
            layoutSubtreeIfNeeded()
        }
        guard animated, let layer else { return finish(generation) }
        let now = CACurrentMediaTime()
        let progress = self.progress(at: now)
        let target: CGFloat = shown ? 1 : 0
        if Motion.reduceMotion {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            fade.duration = 0.12
            run([fade], from: progress, to: target, on: layer, at: now, velocity: 0)
        } else {
            let spring = Motion.popSpring
            let speed = progress == target ? 0 : velocity(at: now) / (target - progress)
            let animations = ["opacity", "transform"].map { key in
                let animation = CASpringAnimation(keyPath: key)
                animation.mass = spring.mass
                animation.stiffness = spring.stiffness
                animation.damping = spring.damping
                animation.initialVelocity = speed
                animation.duration = spring.settlingDuration
                return animation
            }
            run(animations, from: progress, to: target, on: layer, at: now, velocity: velocity(at: now))
        }
    }

    private func run(
        _ animations: [CABasicAnimation], from progress: CGFloat, to target: CGFloat, on layer: CALayer,
        at now: CFTimeInterval, velocity: CGFloat
    ) {
        self.from = progress
        self.target = target
        startVelocity = velocity
        start = now
        animations[0].delegate = Ending { [weak self, generation] in self?.finish(generation) }
        for animation in animations {
            let isOpacity = animation.keyPath == "opacity"
            animation.fromValue = isOpacity ? progress : transform(progress, layer)
            animation.toValue = isOpacity ? target : transform(target, layer)
            // the clock starts where `progress` was read, not at the commit
            animation.beginTime = layer.convertTime(now, from: nil)
            animation.fillMode = .both
            animation.isRemovedOnCompletion = false
            layer.add(animation, forKey: animation.keyPath)
        }
    }

    private final class Ending: NSObject, CAAnimationDelegate {
        let done: () -> Void
        init(_ done: @escaping () -> Void) { self.done = done }
        func animationDidStop(_ animation: CAAnimation, finished: Bool) { if finished { done() } }
    }

    /// scale about the top centre of this view, in the superlayer's space
    private func transform(_ progress: CGFloat, _ layer: CALayer) -> NSValue {
        let scale = 0.97 + 0.03 * progress
        let frame = layer.frame
        let down = layer.superlayer?.contentsAreFlipped() ?? false
        let dx = frame.midX - layer.position.x
        let dy = (down ? frame.minY : frame.maxY) - layer.position.y
        var t = CATransform3DMakeTranslation(-dx, -dy, 0)
        t = CATransform3DConcat(t, CATransform3DMakeScale(scale, scale, 1))
        t = CATransform3DConcat(t, CATransform3DMakeTranslation(dx, dy, 0))
        return NSValue(caTransform3D: t)
    }

    private func progress(at now: CFTimeInterval) -> CGFloat {
        guard !Motion.reduceMotion, now - start < Motion.popSpring.settlingDuration else { return target }
        return from + Motion.popSpring.value(target: target - from, initialVelocity: startVelocity, time: now - start)
    }

    private func velocity(at now: CFTimeInterval) -> CGFloat {
        guard !Motion.reduceMotion, now - start < Motion.popSpring.settlingDuration else { return 0 }
        return Motion.popSpring.velocity(target: target - from, initialVelocity: startVelocity, time: now - start)
    }

    private func finish(_ generation: Int) {
        guard generation == self.generation else { return }
        from = shown ? 1 : 0
        target = from
        startVelocity = 0
        layer?.removeAllAnimations()
        guard !shown else { return }
        isHidden = true
        barRect = .zero
        render(rootView.environment)
    }

    /// first mounted in a window, where its focus can land; a move between windows keeps it
    private func render(_ environment: CommandBarRoot.Environment) {
        let mounted = (shown || !isHidden) && (window != nil || rootView.bar != nil)
        rootView = CommandBarRoot(
            bar: mounted ? .init(address: address, mount: mount, live: { [weak self] in self?.shown == true }) : nil,
            environment: environment
        ) { [weak self] in self?.barRect = $0 }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard shown, window != nil, rootView.bar == nil else { return }
        render(rootView.environment)
        layoutSubtreeIfNeeded()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard shown, barRect.contains(convert(point, from: superview)) else { return nil }
        return super.hitTest(point)
    }

    // MARK: - Early keys

    /// keys typed while the bar is open but its field hasn't the keyboard (⌘T to mount, or a
    /// re-host as the buttons fold), oldest first, replayed to the field once it has
    private var heldKeys: [NSEvent] = []
    private var heldSince: CFTimeInterval = 0
    private var hadKeyboard = false
    private var shownAt: CFTimeInterval = 0
    private var settled = false
    private var replaying = false
    private var keyMonitor: Any?

    /// the field the keyboard was in as the bar last opened or closed, which a fresh mount replaces
    private weak var staleField: AnyObject?

    private var fieldHasKeyboard: Bool {
        guard let responder = window?.firstResponder as? NSView, responder.isDescendant(of: self) else { return false }
        return (responder as? NSTextView)?.delegate.map { $0 !== staleField } ?? true
    }

    /// what the model says, which is ahead of `shown` until SwiftUI's next update
    private var isOpen: Bool {
        let manager = rootView.environment.tabManager
        return manager.isCommandBarVisible && manager.addressBarOrigin == nil
    }

    func holdEarlyKeys() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return event }
                return self.route(event)
            }
        }
    }

    private func route(_ event: NSEvent) -> NSEvent? {
        guard !replaying, event.window === window, !event.modifierFlags.contains(.command) else { return event }
        // through only to a field that has had the keyboard since before this key, or to wherever the
        // keyboard went once the field let it go, or never took it in the bar's first second
        let ready = shown && fieldHasKeyboard && hadKeyboard
        let away = shown && !fieldHasKeyboard && window?.firstResponder !== window
            && (hadKeyboard || CACurrentMediaTime() - shownAt > 1)
        if shown, fieldHasKeyboard { hadKeyboard = true }
        guard isOpen else {
            releaseHeldKeys()
            return event
        }
        if heldKeys.isEmpty, ready || away { return event }
        heldKeys.append(event)
        if heldKeys.count == 1 {
            heldSince = CACurrentMediaTime()
            settled = false
            awaitKeyboard()
        }
        return nil
    }

    /// one key a turn once the field has had the keyboard for a turn, so SwiftUI takes each
    /// before the next; a field that takes none for a second gets them all wherever they go
    private func awaitKeyboard() {
        guard !heldKeys.isEmpty else { return }
        guard isOpen, CACurrentMediaTime() - heldSince < 1 else { return releaseHeldKeys() }
        if settled, fieldHasKeyboard {
            hadKeyboard = true
            heldSince = CACurrentMediaTime()
            replay(heldKeys.removeFirst())
        }
        settled = fieldHasKeyboard
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.001) { [weak self] in self?.awaitKeyboard() }
    }

    private func releaseHeldKeys() {
        let keys = heldKeys
        heldKeys = []
        for key in keys { replay(key) }
    }

    /// through the app, so every other local monitor sees it as if it had never been held
    private func replay(_ event: NSEvent) {
        replaying = true
        NSApp.sendEvent(event)
        replaying = false
    }

    deinit {
        MainActor.assumeIsolated { keyMonitor.map(NSEvent.removeMonitor) }
    }
}

/// while the command bar is up, one tap on the page dismisses it instead of
/// reaching the content
private struct CommandBarPageShield: View {
    @Environment(TabManager.self) private var tabManager

    var body: some View {
        if tabManager.isCommandBarVisible {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { tabManager.isCommandBarVisible = false }
        }
    }
}

/// the window's space backdrop and the tooltip tint that follows it, in a view of
/// its own so per-frame `backdropPosition` reads invalidate only this
private struct WindowBackdrop: View {
    @Environment(TabManager.self) private var tabManager
    @Environment(TooltipState.self) private var tooltipState
    let sidebarPinned: Bool
    let animatesPin: Bool

    var body: some View {
        SpaceBackdrop(
            spaces: tabManager.stripSpaces, position: tabManager.backdropPosition, sidebarPinned: sidebarPinned)
            // in step with the shell's slide, and only where glass shows the pinned frost
            .animation(
                animatesPin && isGlassInView(tabManager) ? Motion.sidebar : nil, value: sidebarPinned)
            .onChange(of: tabManager.blendedAccent, initial: true) { _, accent in
                tooltipState.accent = accent
            }
            // the tooltip turns light with the rest of the chrome: dark ink means a light space
            .onChange(of: tabManager.blendedInk, initial: true) { _, ink in
                tooltipState.light = RGBA(ink).brightness < 0.5
            }
    }
}

/// the find bar and zoom chip over the card, in a view of their own so the
/// shown tab's changes invalidate this corner rather than the window body
private struct CardCornerControls: View {
    @Environment(TabManager.self) private var tabManager

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            if tabManager.isFindBarVisible, let tab = tabManager.unlockedContentTab {
                FindBar(tab: tab)
                    .id(tab.id)
            }
            if let tab = tabManager.displayedContentTab {
                // the find bar brings its own 12pt margin, so the chip only needs one without it
                ZoomChip(tab: tab)
                    .padding(.top, tabManager.isFindBarVisible ? 0 : 12)
                    .padding(.trailing, 12)
            }
        }
        .animation(Motion.panel, value: tabManager.displayedContentTab?.zoomLevel)
    }
}

/// the web card's pages and which of them stay mounted; owns the warm state, so a
/// switch re-runs this and not the window body
private struct CardStack: View {
    @Environment(TabManager.self) private var tabManager
    @Environment(RearrangeDragState.self) private var rearrange
    let shape: UnevenRoundedRectangle
    // the spaces whose pages are kept mounted (current ± 1), refreshed after a
    // switch settles so the set never changes mid-gesture
    @State private var warmSpaceIDs: Set<Space.ID> = []

    /// a space with no tabs at all — the web card steps aside and lets the
    /// space's own backdrop (theme colour) fill the area, no start page
    private var isEmptySpace: Bool { tabManager.selectedTab == nil }

    private var accent: Color { tabManager.currentSpace.appearance.accent }

    var body: some View {
        let _ = Bench.tick("CardStack")
        ZStack {
            if tabManager.activeEssentialID == nil, SpaceLock.shared.isLocked(tabManager.currentSpace) {
                // nothing of a locked space is mounted, so nothing of it can be seen or typed into
                LockedSpaceView(space: tabManager.currentSpace)
                    .environment(\.layoutDirection, .leftToRight)
                    .background(alignment: .top) { WindowDragStrip().frame(height: PageDragBand.height) }
                    .background(tabManager.currentSpace.appearance.cardBase)
                    .environment(\.chromeInk, tabManager.currentSpace.appearance.cardInk)
                    .clipShape(shape)
            } else if let split = tabManager.displayedSplitGroup {
                // panes carry their own base, rounding and shadow. keyed, so another split
                // starts with no pane frames or link pick of this one's
                SplitContentView(group: split)
                    .environment(\.layoutDirection, .leftToRight)
                    .id(split.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                singleCard
            }

            // a pane being rearranged, or a sidebar tab dragged into the content
            if rearrange.isDragging {
                RearrangeOverlay(accent: accent)
                    .environment(\.layoutDirection, .leftToRight)
            }
        }
        // seeded at once so the first swipe already has its neighbours mounted
        .onAppear {
            if warmSpaceIDs.isEmpty { warmSpaceIDs = tabManager.neighborSpaceIDs() }
        }
        // mounting a page that is about to show blocks main; unhiding does not. a
        // committed swipe's neighbours mount at once, a slide's after it finishes;
        // loading unloaded neighbours waits for idle
        .task(id: tabManager.contentSpaceID ?? tabManager.selectedSpaceID) {
            if !tabManager.switchSlides || tabManager.contentSpaceID != nil {
                warmSpaceIDs = tabManager.neighborSpaceIDs()
            }
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            tabManager.hydrateNeighbors()
            warmSpaceIDs = tabManager.neighborSpaceIDs()
        }
    }

    /// web views kept mounted: the shown page and the warm neighbours (current ± 1
    /// space). PageStack keeps the page a switch fades from until the fade lands
    private var mountedTabs: [BrowserTab] {
        var tabs: [BrowserTab] = []
        func add(_ tab: BrowserTab?) {
            // a page on its first load mounts too; PageStack holds it clear until it commits
            guard let tab, tab.url != nil || BrowserTab.skipsPaintWait && tab.awaitingMount != nil,
                !tabs.contains(where: { $0.id == tab.id })
            else { return }
            tabs.append(tab)
        }
        // what's shown, even before the warm set refreshes
        add(tabManager.displayedContentTab)
        for space in tabManager.spaces where warmSpaceIDs.contains(space.id) {
            add(tabManager.shownPage(in: space))
        }
        // under a favourite the space's own tab stays mounted, so going back unhides it
        let current = tabManager.currentSpace
        add(tabManager.selectedTab(in: current) ?? current.firstOpenTab)
        return tabs
    }

    /// the single-page card: its mounted web views, the error/start fallbacks, base, rounding and shadow
    @ViewBuilder
    private var singleCard: some View {
        let shown = tabManager.displayedContentTab
        ZStack {
            let shownID = shown?.loadError == nil ? shown?.id : nil
            let tabs = mountedTabs
            PageStack(tabs: tabs, shownID: shownID)
            ForEach(tabs) { tab in
                Color.clear
                    .pageDialog(for: tab, isShown: tab.id == shownID)
                    .translateSelection(for: tab)
                    .opacity(tab.id == shownID ? 1 : 0)
                    .allowsHitTesting(tab.id == shownID)
            }

            if let tab = shown, tab.isMiniPlayerActive {
                MiniPlayerAway()
            } else if let tab = shown, tab.loadError != nil {
                ErrorPage(tab: tab)
            } else if let tab = shown, tab.reader != nil {
                SavedCopyLabel(tab: tab)
            } else if shown?.url == nil {
                // an empty space reveals the window's backdrop, with the mark's glass in the backdrop's scheme
                if isEmptySpace {
                    HeldMark(side: 176)
                        .environment(\.colorScheme, tabManager.currentSpace.appearance.chromeInk == .white ? .dark : .light)
                } else {
                    StartPage()
                }
            }
        }
        // the page is never mirrored; its card's rounding and rim are
        .environment(\.layoutDirection, .leftToRight)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // a card with no page on it drags the window from the same top band
        .background(alignment: .top) { WindowDragStrip().frame(height: PageDragBand.height) }
        // the space's base under a page, so a loading card never flashes white
        .background(isEmptySpace ? Color.clear : tabManager.currentSpace.appearance.cardBase)
        // the start and error pages take the card's ink, not the system appearance's
        .environment(\.chromeInk, tabManager.currentSpace.appearance.cardInk)
        .overlay(alignment: .top) {
            if let shown {
                PageLoadBar(tab: shown, accent: PageLoadBar.accent(for: tabManager.currentSpace.appearance))
                    .id(shown.id)
            }
        }
        .clipShape(shape)
        // no shadow over an empty space, so the card melts into the backdrop
        .shadow(color: .black.opacity(isEmptySpace ? 0 : 0.35), radius: 12, y: 3)
    }
}

/// the overlay sidebar's backdrop: the window's position-driven SpaceBackdrop
/// clipped to the panel, so space transitions stay in lockstep with the window.
/// never hit-tests, so it can't steal the overlay's hover
private struct OverlayPanelBackground: View {
    @Environment(TabManager.self) private var tabManager
    @Environment(\.layoutDirection) private var layoutDirection
    let width: CGFloat
    let windowWidth: CGFloat

    var body: some View {
        let glassInView = isGlassInView(tabManager)
        let onRight = layoutDirection == .rightToLeft
        let edge: Alignment = onRight ? .trailing : .leading
        // laid out left to right with the page side picked by hand: a mirrored clip
        // leaves the frost's page-side corners square
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: onRight ? 14 : 0, bottomLeadingRadius: onRight ? 14 : 0,
            bottomTrailingRadius: onRight ? 0 : 14, topTrailingRadius: onRight ? 0 : 14, style: .continuous)
        SpaceBackdrop(spaces: tabManager.stripSpaces, position: tabManager.backdropPosition, overPage: true)
            .frame(width: max(windowWidth, width), alignment: edge)
            .frame(width: width, alignment: edge)
            .clipShape(shape)
            // the clip crops the substrate's glass rim, so the lens is re-added at the panel shape
            .overlay {
                if glassInView {
                    Rectangle().fill(.clear)
                        .glassEffect(.clear, in: shape)
                        .allowsHitTesting(false)
                }
            }
            // gated to clear rather than branched, so the substrate's VEV stays
            // mounted and never grey-flashes mid-slide
            .shadow(color: .black.opacity(glassInView ? 0 : 0.45), radius: 18, x: onRight ? -6 : 6, y: 0)
            .allowsHitTesting(false)
            .environment(\.layoutDirection, .leftToRight)
    }
}

/// mirrors SpaceBackdrop's own floor/incoming check
@MainActor private func isGlassInView(_ tabManager: TabManager) -> Bool {
    let spaces = tabManager.stripSpaces
    let floor = Int(tabManager.backdropPosition.rounded(.down))
    let floorGlass = spaces.indices.contains(floor) && spaces[floor].appearance.fill == .glass
    let nextGlass = spaces.indices.contains(floor + 1)
        && spaces[floor + 1].appearance.fill == .glass
    return floorGlass || nextGlass
}

/// the web card's window-space frames, written as the card moves and read only
/// by the drag monitors: a reference box, so the writes don't re-run the body
private final class CardFrames {
    var contentFrame: CGRect = .zero
    /// inside the padding: maps the cursor into the rearrange/drop space
    var cardFrame: CGRect = .zero
}

/// a page out in the mini-player leaves its card empty: this says where it went
private struct MiniPlayerAway: View {
    @Environment(\.chromeInk) private var ink

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "pip").font(.system(size: 28)).foregroundStyle(ink.opacity(0.5))
            Text("Playing in the mini-player").font(.system(size: 13, weight: .medium)).foregroundStyle(ink.opacity(0.7))
            Button("Bring It Back") { BrowserCore.shared.miniPlayer.returnToBrowser() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
