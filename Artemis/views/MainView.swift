// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import SwiftUI

struct MainView: View {
    @Environment(TabManager.self) private var tabManager
    @Environment(TooltipState.self) private var tooltipState
    @Environment(\.openSettings) private var openSettings
    @AppStorage("sidebarWidth") private var sidebarWidth = 250.0

    private static let sidebarWidthRange = 160.0...450.0
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
    /// ms the cursor dwells on the edge before the sidebar peeks
    @AppStorage("sidebarRevealDelay") private var sidebarRevealDelay = 100.0
    /// width in pt of the window-edge strip that catches the hover
    @AppStorage("sidebarHoverAreaWidth") private var sidebarHoverAreaWidth = 8.0
    /// seconds the peek's slide-in runs; its bounce is fixed
    @AppStorage("sidebarRevealDuration") private var sidebarRevealDuration = 0.2
    /// set only from the onChange handlers, never mid-render
    @State private var isSidebarOverlayVisible = false
    @State private var isOverlayHovered = false
    /// a context menu takes the cursor's hover for as long as it is open
    @State private var isMenuOpen = false
    /// the overlay is springing in; its overshoot uncovering the edge strip is not "mouse left"
    @State private var overlayEntering = false
    @State private var overlayEnterTask: Task<Void, Never>?
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

    /// the Library's icon rail widens the whole sidebar, so its list keeps full width
    private var libraryRailExtra: CGFloat {
        tabManager.isLibraryOpen ? LibrarySidebar.railWidth : 0
    }

    var body: some View {
        let _ = Bench.tick("MainView")
        let _ = Bench.markOnce("MainView: first body")
        // the sidebar floats over the card; both are AppKit-placed hosts. the
        // real traffic lights live inside the sidebar, so they move with its view
        BrowserShell(
            sidebar: hosted(sidebarRig),
            content: hosted(cardArea),
            placement: shellPlacement,
            cause: .init(
                collapsed: isSidebarCollapsed, overlayVisible: isSidebarOverlayVisible,
                libraryOpen: tabManager.isLibraryOpen),
            revealDuration: sidebarRevealDuration)
        .onChange(of: drag.isDragging) { _, dragging in
            if dragging { startContentDragMonitor() } else { stopContentDragMonitor() }
        }
        .onChange(of: rearrange.isDragging) { _, dragging in
            // incoming sidebar drags are driven by the content monitor + sidebar
            // commit; only the in-split pane rearrange needs this monitor
            if dragging, !rearrange.incoming { startRearrangeMonitor() }
            else if !dragging { stopRearrangeMonitor() }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)
        ) { _ in
            isFullScreen = true
        }
        .onReceive(
            NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)
        ) { _ in
            isFullScreen = false
        }
        // the grab strip when the rim is too thin to hold one; it must sit above
        // the sidebar's overlay or the sidebar's side of the seam loses its clicks
        .overlay(alignment: .leading) {
            if !isSidebarCollapsed, edgeInset < WindowChrome.minGrabWidth {
                resizeHandle(width: Self.seamGrabWidth, centreOffsetFromEdge: libraryRailExtra)
                    // padding, not .offset: offset is render-only and leaves the AppKit hit area behind
                    .padding(.leading, pinnedFootprint - Self.seamGrabWidth / 2)
            }
        }
        .animation(Motion.panel, value: tabManager.isLibraryOpen)
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
        .onChange(of: isSidebarCollapsed) { _, collapsed in
            // the address bar grown from the sidebar's pill would keep a spot that has moved
            if let origin = tabManager.addressBarOrigin, !origin.isEmpty {
                withAnimation(Motion.address) { tabManager.addressBarOrigin = .zero }
            }
            // collapsing hands over to the overlay in place until the mouse leaves; pinning dismisses it
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                isSidebarOverlayVisible = collapsed
            }
            collapseDismissTask?.cancel()
            if collapsed {
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
        .onChange(of: tabManager.isSidebarPopoverOpen) { _, open in
            if !open { releaseOverlayHold() }
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
        .overlay { CommandBarOverlay() }
        // ⌘L, a new blank tab, first launch
        .onChange(of: tabManager.urlFieldFocusRequest) { tabManager.editAddress() }
        .overlay {
            spaceCreatorOverlay
                .animation(Motion.fade, value: tabManager.isSpaceCreatorVisible)
        }
        .overlay {
            arcImportOverlay
                .animation(Motion.fade, value: tabManager.arcImport == nil)
        }
        .overlay {
            browserImportOverlay
                .animation(Motion.fade, value: tabManager.browserImport == nil)
        }
        .overlay {
            Group {
                if let peek = tabManager.peekTab {
                    PeekView(tab: peek)
                }
            }
            .animation(Motion.fade, value: tabManager.peekTab?.id)
        }
        .overlay {
            // the space editor's full-window gradient preview; exiting resumes the editor
            Group {
                if tabManager.gradientPreview != nil {
                    GradientPreview {
                        // the space header resumes the edit once this goes nil
                        if let resume = tabManager.resumeGradientEdit,
                            let space = tabManager.spaces.first(where: { $0.id == resume.id }),
                            let revert = tabManager.previewRevert
                        {
                            tabManager.updateSpace(space, appearance: revert)
                        }
                        tabManager.previewRevert = nil
                        tabManager.gradientPreview = nil
                    }
                    .transition(.opacity)
                }
            }
            .animation(Motion.fade, value: tabManager.gradientPreview != nil)
        }
        .overlay {
            feedbackOverlay
                .animation(Motion.fade, value: tabManager.feedback == nil)
        }
        .background { WindowBackdrop() }
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
            // first-launch: focus the url field once the field is listening
            if tabManager.selectedTab?.url == nil {
                try? await Task.sleep(for: .milliseconds(250))
                tabManager.urlFieldFocusRequest += 1
            }
            // everything below runs once per app, not per window
            guard BrowserWindows.shared.claimLaunchWork() else { return }

            Task { await Intelligence.shared.prewarmChores() }
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

    /// the move-in-from-Arc picker, modal over everything like the space
    /// creator: the scrim's tap cancels, and nothing has moved until its button
    @ViewBuilder
    private var arcImportOverlay: some View {
        if let model = tabManager.arcImport {
            ZStack {
                Color.black.opacity(0.25)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        // a running import is not interruptible
                        if case .working = model.phase {} else { model.cancel(in: tabManager) }
                    }
                ArcImportSheet(model: model)
                    .offset(y: -20)
            }
        }
    }

    /// import from another browser, modal like the Arc picker
    @ViewBuilder
    private var browserImportOverlay: some View {
        if let model = tabManager.browserImport {
            ZStack {
                Color.black.opacity(0.25)
                    .contentShape(Rectangle())
                    .onTapGesture { model.cancel(in: tabManager) }
                BrowserImportSheet(model: model)
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

    /// thin strip on the window edge; dwelling on it peeks the sidebar
    private var edgeRevealZone: some View {
        Color.clear
            .frame(width: sidebarHoverAreaWidth)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { hovering in
                edgeHoverTask?.cancel()
                guard hovering else { return }
                edgeHoverTask = Task {
                    try? await Task.sleep(for: .milliseconds(Int(sidebarRevealDelay)))
                    if !Task.isCancelled {
                        isSidebarOverlayVisible = true
                    }
                }
            }
    }

    /// the overlay sidebar's outline, rounded on its page side
    private var panelShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: 0, bottomLeadingRadius: 0,
            bottomTrailingRadius: 14, topTrailingRadius: 14, style: .continuous)
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
        return p.x >= 0 && p.x <= rigContentWidth && p.y >= 0 && p.y <= window.frame.height
    }

    /// what every dismiss path asks before letting the overlay go
    private var overlayHeld: Bool { isOverlayHovered || pointerInsideRig }

    /// the grab strip beside the sidebar: its own width in the overlay, the rim
    /// when pinned, or nothing when the rim is too thin to grab (the seam handle covers it)
    private var rigGripWidth: CGFloat {
        if isSidebarCollapsed { return Self.overlayGripWidth }
        return edgeInset >= WindowChrome.minGrabWidth ? edgeInset : 0
    }

    /// what the card yields when the sidebar is pinned; the hover buffer takes no room
    private var pinnedFootprint: CGFloat {
        sidebarWidth + libraryRailExtra + rigGripWidth
    }

    /// everything that slides: sidebar + grip + hover buffer
    private var rigContentWidth: CGFloat {
        sidebarWidth + libraryRailExtra + rigGripWidth + Self.overlayBufferWidth
    }

    /// the one sidebar, floating at the window's leading edge in both modes;
    /// BrowserShell slides its host
    private var sidebarRig: some View {
        HStack(spacing: 0) {
            Sidebar(width: sidebarWidth)
                .frame(width: sidebarWidth + libraryRailExtra)
                .frame(maxHeight: .infinity)
                // overlay mode: empty sidebar areas must not click through to the page
                .background {
                    if isSidebarCollapsed { Color.black.opacity(0.001) }
                }
                // pinned mode shows the window's backdrop instead
                .background(alignment: .leading) {
                    if isSidebarCollapsed {
                        OverlayPanelBackground(
                            shape: panelShape,
                            width: sidebarWidth + libraryRailExtra + edgeInset,
                            windowWidth: windowSize.width)
                    }
                }

            resizeHandle(width: rigGripWidth)

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
                guard !Task.isCancelled, !isOverlayHovered, !isResizingSidebar,
                    !tabManager.isDraggingWindow, !overlayEntering, !isMenuOpen,
                    !tabManager.isSidebarPopoverOpen
                else { return }
                isSidebarOverlayVisible = false
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(isSidebarOverlayVisible ? nil : Motion.sidebar, value: isSidebarCollapsed)
        .animation(Motion.panel, value: tabManager.isLibraryOpen)
    }

    /// where the shell puts the sidebar and the card. the sidebar host is as wide
    /// as the rig ever gets, so pinning never resizes it; past the grip it passes
    /// clicks through unless a folder's peek hangs there
    private var shellPlacement: BrowserShell<AnyView, AnyView>.Placement {
        let slack = Self.overlayOvershootSlack
        let rig = sidebarWidth + libraryRailExtra
        let peek = tabManager.isFolderPeekOpen ? FolderPeek.width + 10 : 0
        let hostWidth =
            slack + rig + max(Self.overlayGripWidth, edgeInset) + Self.overlayBufferWidth + peek
        return .init(
            sidebarX: isSidebarRevealed ? -slack : -hostWidth,
            sidebarWidth: hostWidth,
            sidebarPassLeading: slack,
            sidebarPassTrailing: peek > 0 ? 0 : hostWidth - (slack + rig + rigGripWidth),
            contentX: isSidebarCollapsed ? (isEdgeToEdge ? 0 : edgeInset) : pinnedFootprint)
    }

    /// a modal over the window takes the pointer from everything under it
    private var isModalOverlayUp: Bool {
        tabManager.peekTab != nil || tabManager.isSpaceCreatorVisible
            || tabManager.arcImport != nil || tabManager.browserImport != nil
            || tabManager.gradientPreview != nil
            || tabManager.feedback != nil
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
                .environment(rearrange))
    }

    private var rim: CGFloat { isEdgeToEdge ? 0 : CGFloat(edgeInset) }
    /// below the toolbar the page keeps its rim, but never touches the row
    private var toolbarGap: CGFloat { max(rim, BrowserToolbar.top) }

    /// the web card with its rim, as the shell's content host shows it
    private var cardArea: some View {
        VStack(spacing: 0) {
            if showsToolbar {
                BrowserToolbar()
                    .padding(.top, BrowserToolbar.top)
                    .padding(.leading, rim == 0 && isSidebarCollapsed ? BrowserToolbar.top : 0)
                    .padding(.trailing, toolbarGap)
            }
            webCard
                // status capsule for the hovered link, bottom-left of the content
                .overlay(alignment: .bottomLeading) {
                    LinkHoverCapsule()
                        .padding(12)
                        .allowsHitTesting(false)
                }
                .padding(.top, showsToolbar ? toolbarGap : rim)
                .padding([.trailing, .bottom], rim)
                // the visible card frame, for drag-to-split
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) {
                    frames.contentFrame = $0
                }
        }
        // behind everything: the rim, the toolbar row's gaps and an empty space's card
        .background(WindowDragStrip())
        // the rim and corners change with fullscreen pinning; they move with the slide
        .animation(isSidebarOverlayVisible ? nil : Motion.sidebar, value: isSidebarCollapsed)
    }

    /// invisible grab strip between sidebar and web card
    private func resizeHandle(width: CGFloat, centreOffsetFromEdge: CGFloat? = nil) -> some View {
        SidebarResizeHandle(
            width: $sidebarWidth,
            range: Self.sidebarWidthRange,
            onDraggingChanged: { dragging in
                isResizingSidebar = dragging
                if !dragging, !overlayHeld {
                    isSidebarOverlayVisible = false
                }
            },
            centreOffsetFromEdge: centreOffsetFromEdge
        )
        .frame(width: width)
    }

    /// the grab strip's width when it straddles the seam rather than sitting in a rim
    private static let seamGrabWidth: CGFloat = 16

    @ViewBuilder
    private var webCard: some View {
        GeometryReader { geo in
            CardStack(cornerRadius: isEdgeToEdge ? 0 : WindowChrome.cardRadius(inset: edgeInset))
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
            updateContentDropZone(event)
            return event
        }
    }

    private func stopContentDragMonitor() {
        if let contentDragMonitor { NSEvent.removeMonitor(contentDragMonitor) }
        contentDragMonitor = nil
        drag.contentDropZone = nil
        if rearrange.incoming { rearrange.clear() }
    }

    /// drives the rearrange overlay as an incoming drag while a sidebar tab is over
    /// the content; `contentDropZone` doubles as the sidebar's "over content" flag
    private func updateContentDropZone(_ event: NSEvent) {
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

        if drag.contentDropZone == nil { drag.contentDropZone = .right }

        let group = tabManager.displayedSplitGroup
        let single = group == nil ? tabManager.selectedTab?.id : nil
        let local = CGPoint(x: point.x - frames.cardFrame.minX, y: point.y - frames.cardFrame.minY)
        rearrange.beginIncoming(tab: tab.id, group: group, singlePaneTab: single, at: local)
    }

    private func clearContentDrop() {
        if drag.contentDropZone != nil { drag.contentDropZone = nil }
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

    var body: some View {
        // no scrim: the page and the sidebar's edge reveal stay live
        GeometryReader { geo in
            if let origin = tabManager.addressBarOrigin {
                let window = geo.frame(in: .global).origin
                AddressBar(
                    origin: origin.isEmpty ? .zero : origin.offsetBy(dx: -window.x, dy: -window.y),
                    size: geo.size)
                    .transition(.asymmetric(insertion: .identity, removal: .opacity))
            } else if tabManager.isCommandBarVisible {
                // a fresh bar when it switches between new tab and address
                CommandBar(address: tabManager.commandBarEditsAddress)
                    .id(tabManager.commandBarEditsAddress)
                    .frame(maxWidth: .infinity)
                    .padding(.top, geo.size.height * 0.2)
                    .transition(Motion.grow(from: 0.97, anchor: .top))
            }
        }
        .animation(Motion.pop, value: tabManager.isCommandBarVisible)
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

    var body: some View {
        SpaceBackdrop(spaces: tabManager.stripSpaces, position: tabManager.backdropPosition)
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
            if tabManager.isFindBarVisible, let tab = tabManager.selectedTab {
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

/// the web card's pages and which of them stay mounted; owns the warm and
/// crossfade-hold state, so a switch re-runs this and not the window body
private struct CardStack: View {
    @Environment(TabManager.self) private var tabManager
    @Environment(RearrangeDragState.self) private var rearrange
    let cornerRadius: CGFloat
    // the spaces whose pages are kept mounted (current ± 1), refreshed after a
    // switch settles so the set never changes mid-gesture
    @State private var warmSpaceIDs: Set<Space.ID> = []
    // the page the current one is crossfading over: mounted for the length of
    // the fade so there's an opaque page underneath, then released
    @State private var heldTabID: BrowserTab.ID?
    @State private var shownBeforeID: BrowserTab.ID?
    @State private var holdTask: Task<Void, Never>?

    /// a space with no tabs at all — the web card steps aside and lets the
    /// space's own backdrop (theme colour) fill the area, no start page
    private var isEmptySpace: Bool { tabManager.selectedTab == nil }

    private var accent: Color { tabManager.currentSpace.appearance.accent }

    var body: some View {
        ZStack {
            if tabManager.activeEssentialID == nil, SpaceLock.shared.isLocked(tabManager.currentSpace) {
                // nothing of a locked space is mounted, so nothing of it can be seen or typed into
                LockedSpaceView(space: tabManager.currentSpace)
                    .background(alignment: .top) { WindowDragStrip().frame(height: PageDragBand.height) }
                    .background(tabManager.currentSpace.appearance.cardBase)
                    .environment(\.chromeInk, tabManager.currentSpace.appearance.cardInk)
                    .clipShape(
                        RoundedRectangle(
                            cornerRadius: cornerRadius,
                            style: .continuous))
            } else if let split = tabManager.displayedSplitGroup {
                // panes carry their own base, rounding and shadow
                SplitContentView(group: split)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                singleCard
            }

            // a pane being rearranged, or a sidebar tab dragged into the content
            if rearrange.isDragging {
                RearrangeOverlay(accent: accent)
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
        .onChange(of: tabManager.displayedContentTab?.id, initial: true) { _, id in noteShown(id) }
    }

    /// web views kept mounted: the shown page, the page it is crossfading over,
    /// and the warm neighbours (current ± 1 space)
    private var mountedTabs: [BrowserTab] {
        var tabs: [BrowserTab] = []
        func add(_ tab: BrowserTab?) {
            guard let tab, tab.url != nil, !tabs.contains(where: { $0.id == tab.id }) else { return }
            tabs.append(tab)
        }
        // what's shown, even before the warm set refreshes
        add(tabManager.displayedContentTab)
        for space in tabManager.spaces where warmSpaceIDs.contains(space.id) {
            add(tabManager.selectedTab(in: space) ?? space.tabs.first)
        }
        if PerfFlags.holdsCrossfadePage {
            add(heldTabID.flatMap(tab(withID:)))
        }
        return tabs
    }

    private func tab(withID id: BrowserTab.ID) -> BrowserTab? {
        for space in tabManager.spaces {
            if let match = space.tabs.first(where: { $0.id == id }) { return match }
        }
        return tabManager.essentials.first { $0.id == id }
    }

    /// holds the outgoing page mounted for the length of the crossfade only
    private func noteShown(_ id: BrowserTab.ID?) {
        let outgoing = shownBeforeID
        shownBeforeID = id
        guard let outgoing, outgoing != id else { return }
        holdTask?.cancel()
        heldTabID = outgoing
        holdTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            heldTabID = nil
        }
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
                    .pageDialog(for: tab)
                    .translateSelection(for: tab)
                    .opacity(tab.id == shownID ? 1 : 0)
                    .allowsHitTesting(tab.id == shownID)
            }

            if let tab = shown, tab.loadError != nil {
                ErrorPage(tab: tab)
            } else if shown?.url == nil {
                // an empty space reveals the window's backdrop
                if isEmptySpace {
                    Color.clear
                } else {
                    StartPage()
                }
            }
        }
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
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        // no shadow over an empty space, so the card melts into the backdrop
        .shadow(color: .black.opacity(isEmptySpace ? 0 : 0.35), radius: 12, y: 3)
    }
}

/// the overlay sidebar's backdrop: the window's position-driven SpaceBackdrop
/// clipped to the panel, so space transitions stay in lockstep with the window.
/// never hit-tests, so it can't steal the overlay's hover
private struct OverlayPanelBackground: View {
    @Environment(TabManager.self) private var tabManager
    let shape: UnevenRoundedRectangle
    let width: CGFloat
    let windowWidth: CGFloat

    var body: some View {
        let glassInView = isGlassInView
        SpaceBackdrop(spaces: tabManager.stripSpaces, position: tabManager.backdropPosition, overPage: true)
            .frame(width: max(windowWidth, width), alignment: .leading)
            .frame(width: width, alignment: .leading)
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
            .shadow(color: .black.opacity(glassInView ? 0 : 0.45), radius: 18, x: 6, y: 0)
            .allowsHitTesting(false)
    }

    /// mirrors SpaceBackdrop's own floor/incoming check
    private var isGlassInView: Bool {
        let spaces = tabManager.stripSpaces
        let floor = Int(tabManager.backdropPosition.rounded(.down))
        let floorGlass = spaces.indices.contains(floor) && spaces[floor].appearance.fill == .glass
        let nextGlass = spaces.indices.contains(floor + 1)
            && spaces[floor + 1].appearance.fill == .glass
        return floorGlass || nextGlass
    }
}

/// the web card's window-space frames, written as the card moves and read only
/// by the drag monitors: a reference box, so the writes don't re-run the body
private final class CardFrames {
    var contentFrame: CGRect = .zero
    /// inside the padding: maps the cursor into the rearrange/drop space
    var cardFrame: CGRect = .zero
}
