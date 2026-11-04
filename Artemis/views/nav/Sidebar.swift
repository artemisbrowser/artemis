import AppKit
import QuartzCore
import SwiftUI

/// a tab row's position within the drag coordinate space
private struct SidebarRowFrame: Equatable {
    /// the entry the row draws — a split reports one frame per pane, all naming
    /// their own tab, so the merge math still sees the panes individually
    let entry: SidebarEntry
    /// the folder (or section) the row is a child of, and how deep that sits
    let container: SidebarContainer
    let section: SidebarSection
    let depth: Int
    let rect: CGRect

    var tabID: BrowserTab.ID? {
        if case .tab(let id) = entry { return id }
        return nil
    }
}

private struct SidebarRowFrameKey: PreferenceKey {
    static let defaultValue: [SidebarRowFrame] = []
    static func reduce(value: inout [SidebarRowFrame], nextValue: () -> [SidebarRowFrame]) {
        value.append(contentsOf: nextValue())
    }
}

private struct NewTabBoundaryKey: PreferenceKey {
    static let defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        value = nextValue() ?? value
    }
}

/// where a drop would land: a slot among a container's own children (the line
/// shows it, indented to that container's depth), or inside a folder's row
private enum DropResolution: Equatable {
    case list(container: SidebarContainer, index: Int, lineY: CGFloat, depth: Int)
    case intoFolder(TabFolder.ID)
}

private enum HorizontalSide { case left, right }

/// how a press on a split row resolved: still deciding, moving the whole split,
/// or having lifted a single pane out to drag alone
private enum SplitGestureMode { case undecided, group, pane }

/// the live preview while a dragged tab dwells over another: which tab it's over,
/// the side it'll land on (single-tab target), and the slot it'll take (split
/// target). drives the shrink/grey-half and insertion-gap previews
private struct MergePreview: Equatable {
    let targetID: BrowserTab.ID
    let side: HorizontalSide
    let insertIndex: Int
}

/// the sidebar — artemis has no top toolbar; navigation, url and tabs all live here
struct Sidebar: View {
    @Environment(TabManager.self) private var tabManager
    private var isSidebarCollapsed: Bool { tabManager.isSidebarCollapsed }
    /// the window rim, read here (not via WindowChrome's static) so dragging the
    /// thickness slider re-lays out the sidebar's trailing margin as it moves
    @AppStorage(WindowChrome.edgeInsetKey) private var edgeInset = WindowChrome.defaultEdgeInset
    /// the url pill and navigation live in the toolbar instead
    @AppStorage(BrowserToolbar.shownKey) private var showsToolbar = false

    private let metrics = SidebarMetrics.standard
    /// the settled space's ink, not the blended one: the tab lists slide away with
    /// their own space, so re-tinting per frame would invalidate every mounted row.
    /// chrome over the backdrop takes `BlendedInk` instead
    private var ink: Color { tabManager.currentSpace.appearance.chromeInk }
    @State private var isPeekVisible = false
    @State private var isPeekHovered = false
    @State private var peekTask: Task<Void, Never>?
    /// the folded folder whose contents hang beside the list, if any
    @State private var peekedFolder: TabFolder.ID?
    @State private var isFolderPeekHovered = false
    @State private var folderPeekTask: Task<Void, Never>?

    @State private var clickMonitor: Any?

    /// shared with the content area (MainView owns it), so a tab dragged out of
    /// the sidebar can be dropped onto the page to split
    @Environment(SidebarDragState.self) private var drag
    /// the content-area tiling drag: over the page a sidebar tab becomes its
    /// "incoming" ghost, and the drop reads its target
    @Environment(RearrangeDragState.self) private var rearrange
    /// frames the drag and peek logic hit-test against, in an unobserved box as
    /// they move on every frame of a swipe; their readers redraw on drag or peek
    /// changes
    @State private var measured = SidebarGeometry()
    /// the pointer's last spot in the tab area, where a context-menu folder lands.
    /// an unobserved box: written on every mouse move, read only by the menu
    @State private var menuPoint = LastPoint()
    @State private var tabsScrolled = false
    /// the Library is built only while open or sliding out
    @State private var isLibraryMounted = false
    @State private var libraryUnmountTask: Task<Void, Never>?
    @State private var renameDraft = ""

    private var renamingBinding: Binding<Bool> {
        Binding(
            get: { tabManager.renamingTab != nil },
            set: { if !$0 { tabManager.renamingTab = nil } })
    }

    // drag-to-split: dwelling a dragged tab over another (~mergeDwellMS) previews
    // merging them into one split row. `mergeAnchorRect` locks detection to the
    // target's original bounds so the shrink/gap preview can't make it oscillate
    @State private var merge: MergePreview?
    @State private var dwellRowID: BrowserTab.ID?
    @State private var dwellTask: Task<Void, Never>?
    @State private var mergeAnchorRect: CGRect = .zero
    // gap between panes once a split is focused; an unfocused split sits flush
    // with a hairline divider instead
    private static let splitSegmentGap: CGFloat = 3
    private static let mergeDwellMS = 360
    // which unfocused split row the cursor is over, for its whole-row hover
    @State private var hoveredSplitID: SplitGroup.ID?

    // split-row gesture: a quick drag moves the whole split; pressing and holding
    // (~paneLiftHoldMS) on a pane lifts just that one out to drag alone; a click
    // re-opens the split. one drag at a time, so one set of state suffices
    @State private var splitGestureGroupID: SplitGroup.ID?
    @State private var splitGestureMode: SplitGestureMode = .undecided
    @State private var splitGesturePaneID: BrowserTab.ID?
    @State private var splitHoldTask: Task<Void, Never>?
    @State private var splitGestureLocation: CGPoint = .zero
    @State private var liftedPaneID: BrowserTab.ID?
    // a lifted pane floats as the ghost, leaving a grey gap at `liftSlot` (nil once
    // the cursor pulls clear of the row); `liftAnchorRect` locks the slot math to
    // the split's original bounds so the gap doesn't oscillate as the row reflows
    @State private var liftSlot: Int?
    @State private var liftAnchorRect: CGRect = .zero
    private static let paneLiftHoldMS = 350
    private static let splitMoveThreshold: CGFloat = 6

    // with no favourites yet, the drop zone stays closed until a dragged tab is
    // pulled up past the space header — then it opens (latched for the drag) so
    // the space name doesn't jump down the moment any drag starts
    @State private var revealEmptyEssentials = false

    // the pager's centred position is `tabManager.spacePagePosition`, in page
    // units; a click animates it, a swipe drives it by hand. isSwiping/isSettling
    // keep the two drivers apart; panelWidth feeds the pitch and snap threshold
    @State private var isSwiping = false
    @State private var isSettling = false
    // the position the carousel is settling toward, and a token so an in-flight
    // settle's completion bails if a newer swipe has superseded it — together
    // these make the settle interruptible
    @State private var pendingTarget: Int?
    /// the uncommitted target a run of quick swipes is carrying on from
    @State private var chainBase: Int?
    @State private var settleToken = 0
    // where the in-flight settle started, where it is headed, and when it began —
    // enough to ask `Motion.carouselSpring` where the strip is on screen right
    // now, which the stored position cannot answer mid-animation
    @State private var settleFrom: Double = 0
    @State private var settleStart: CFTimeInterval = 0
    // where the carousel sat when the current swipe began (may be mid-settle, so
    // fractional) — the drag is measured from here so a chained swipe continues
    // seamlessly instead of snapping to an integer
    @State private var swipeAnchor: Double = 0
    @State private var panelWidth: CGFloat = 0
    /// the folder a drop would file into, kept as state so rows redraw when it
    /// changes rather than on every move of the drag
    @State private var folderTarget: TabFolder.ID?
    /// the spaces the pager last came to rest on; the built panels trail a switch
    @State private var settledIndex: Int?
    @State private var previousSettledIndex: Int?

    var width: Double = 250

    /// below this width the toggle folds into the nav's … menu: where its box
    /// would touch the nav group (lights 69 + gap + toggle + nav + 12 insets)
    private var isCompact: Bool { width < 240 }

    /// the sidebar's own margin: how far its content sits from the panel edge.
    /// the leading side is exactly this; the trailing side is this *minus*
    /// whatever the window rim already contributes (see `trailingInset`)
    static let contentInset: CGFloat = 12

    /// what follows the sidebar's frame is rim (the resize grip, or the overlay's
    /// overhang) and reads as part of its right margin, so the padding here only
    /// makes up the difference
    private var trailingInset: CGFloat {
        Self.trailingInset(rim: edgeInset, collapsed: isSidebarCollapsed)
    }

    /// how much space follows the sidebar's frame: floating, the overlay's
    /// overhang, always the full rim; pinned, the resize grip, which isn't laid
    /// out below the minimum grab width
    static func rimContribution(rim: Double, collapsed: Bool) -> CGFloat {
        if collapsed { return rim }
        return rim >= WindowChrome.minGrabWidth ? rim : 0
    }

    /// static so the suite can check the margin lands evenly at every rim
    static func trailingInset(rim: Double, collapsed: Bool) -> CGFloat {
        max(0, contentInset - rimContribution(rim: rim, collapsed: collapsed))
    }

    private static let contentSpace = SidebarDragState.contentSpace

    var body: some View {
        let _ = Bench.tick("Sidebar")
        VStack(alignment: .leading, spacing: 10) {
            // top row sits on the traffic lights' line:
            // sidebar toggle right of the lights, nav buttons right-aligned
            HStack(spacing: 0) {
                // the real traffic lights, laid out here so they move with the
                // sidebar (see TrafficLightMount); they sit 9pt into the mount,
                // so −9 lands the close button at window x=12
                TrafficLightMount()
                    .frame(width: TrafficLightMount.width, height: TrafficLightMount.height)
                    .padding(.leading, -9)
                if !isCompact || showsToolbar {
                    // clears the zoom button by one light gap
                    SidebarToggleButton()
                        .padding(.leading, 9)
                }
                Spacer(minLength: 0)
                if !showsToolbar {
                    NavigationControls(isCompact: isCompact) {
                        tabManager.isSidebarCollapsed.toggle()
                    }
                }
            }
            // glass buttons are url-bar tall, so their row is too, sitting
            // BrowserToolbar.top from the window top; the lights ride its centre
            .frame(height: SidebarMetrics.glassSide)
            // the bar the row sits in is the sidebar's top inset plus the gap
            // below; the drag has to cover all of it or only the middle band
            // moves the window
            .background(WindowDragStrip().padding(.top, -BrowserToolbar.top).padding(.bottom, -Self.dragBarOverhang))
            .modifier(BlendedInk())

            // library and spaces slide by one panel width as an .offset: a .move
            // transition snaps the NSScrollView-backed lists to their final spot
            // instead of interpolating
            GeometryReader { geo in
                let lib = libraryContentWidth
                let pitch = lib + Self.libraryGutter
                HStack(spacing: Self.libraryGutter) {
                    Group {
                        if isLibraryMounted { LibrarySidebar(width: width) } else { Color.clear }
                    }
                    .frame(width: lib)
                    spaceContent
                        .frame(width: baseContentWidth)
                }
                .frame(height: geo.size.height, alignment: .topLeading)
                // content widths are fixed (not the live, animating frame width),
                // so as the sidebar grows by the rail width on open the rows never
                // re-truncate — only the surrounding frame widens, revealing them
                .offset(x: tabManager.isLibraryOpen ? 0 : -pitch)
                .animation(Motion.panel, value: tabManager.isLibraryOpen)
            }
            .onChange(of: tabManager.isLibraryOpen, initial: true) { _, open in
                libraryUnmountTask?.cancel()
                if open {
                    isLibraryMounted = true
                } else {
                    // held through the slide out, then released
                    libraryUnmountTask = Task {
                        try? await Task.sleep(for: .milliseconds(600))
                        if !Task.isCancelled { isLibraryMounted = false }
                    }
                }
            }
            .frame(maxHeight: .infinity)
            // clip so the off-screen panel stays hidden under the sidebar's edge
            .clipped()
            // one coordinate space spanning favourites + tabs, so the unified
            // drag's ghost and indicators (drawn here, above the clip) line up
            // with both zones. frames are reported into this same space
            .coordinateSpace(.named(Self.contentSpace))
            // what follows the cursor lives in leaves of its own, so a drag
            // re-runs them rather than this whole body on every move
            .overlay { Live { dragOverlay } }
            .overlay { folderPeekOverlay }
            .onChange(of: drag.dropTick) { _, _ in commitDrop() }
            .background {
                Live {
                    Color.clear.onChange(of: drag.location) { _, _ in
                        updateDwell()
                        updateLift()
                        updateEmptyEssentialsReveal()
                        let target = folderDropTarget
                        if target != folderTarget { folderTarget = target }
                    }
                }
            }

            // the card sits flush on the bar, so an absent card leaves no gap
            VStack(spacing: 0) {
                NowPlayingCard()
                bottomBar
            }
            .modifier(BlendedInk())
        }
        .onChange(of: tabManager.renamingTab) { _, tab in
            if let tab { renameDraft = tab.displayTitle }
        }
        .alert("Rename Tab", isPresented: renamingBinding) {
            TextField("Name", text: $renameDraft)
            Button("Rename") {
                if let tab = tabManager.renamingTab { tabManager.rename(tab, to: renameDraft) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Leave it empty to go back to the page's own title.")
        }
        .environment(\.chromeInk, ink)
        .environment(\.spaceAccent, tabManager.currentSpace.appearance.accent)
        .padding(.leading, Self.contentInset)
        .padding(.trailing, trailingInset)
        .padding(.top, BrowserToolbar.top)
        .padding(.bottom, 10)
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear {
                        drag.sidebarFrame = proxy.frame(in: .global)
                    }
                    .onChange(of: proxy.frame(in: .global)) { _, f in
                        drag.sidebarFrame = f
                    }
            }
        }
        // two-finger horizontal swipe anywhere on the sidebar drags the next
        // space's tabs in gradually, then snaps on release
        .background {
            SpaceSwipeDetector(
                onChanged: { handleSwipeChanged($0) },
                onEnded: { handleSwipeEnded($0) })
        }
        .overlay(alignment: .bottom) {
            // recent downloads peek while hovering the inbox
            if isPeekVisible, !tabManager.isLibraryOpen {
                RecentDownloadsPeek()
                    .padding(.horizontal, 12)
                    .padding(.bottom, 44)  // sits just above the bottom bar
                    .transition(Motion.slide(.bottom))
                    .onHover { hovering in
                        isPeekHovered = hovering
                        if !hovering {
                            setPeek(visible: false)
                        }
                    }
            }
        }
        .animation(Motion.pop, value: isPeekVisible)
        .onAppear { startClickMonitor() }
        .onDisappear { stopClickMonitor() }
    }

    /// how far the top row's window-drag bar reaches below the row
    private static let dragBarOverhang: CGFloat = 8

    /// a press that lands on this window's sidebar closes the command bar and
    /// blurs before its target sees it, so a sidebar field still focuses; the
    /// top row's window chrome (lights, toggle, nav, drag bar) leaves both alone
    private func startClickMonitor() {
        stopClickMonitor()
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            guard let window = event.window, BrowserWindows.shared.manager(for: window) === tabManager,
                let hit = window.contentView?.hitTest(event.locationInWindow),
                let host = sequence(first: hit, next: \.superview).first(where: {
                    $0 is PassthroughHostingView<AnyView>
                })
            else { return event }
            let chrome = BrowserToolbar.top + SidebarMetrics.glassSide + Self.dragBarOverhang
            if host.convert(event.locationInWindow, from: nil).y > chrome {
                tabManager.isCommandBarVisible = false
                window.makeFirstResponder(nil)
            }
            return event
        }
    }

    private func stopClickMonitor() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
    }

    /// the folder whose panel belongs on screen: hovered, and still folded —
    /// opening it puts the tabs in the list, so the panel has nothing to add
    private var peekingFolder: TabFolder? {
        guard let id = peekedFolder, let folder = tabManager.currentSpace.folder(id),
            !folder.isExpanded
        else { return nil }
        return folder
    }

    /// the hovered folder's contents, hanging off the row's trailing edge. it
    /// lives above the list's clip, so it can reach past the sidebar
    @ViewBuilder private var folderPeekOverlay: some View {
        GeometryReader { proxy in
            if let folder = peekingFolder,
                let row = measured.rowFrames.first(where: { $0.entry == .folder(folder.id) })
            {
                let height = min(FolderPeek.maxHeight, proxy.size.height)
                FolderPeek(folder: folder) { dismissFolderPeek() }
                    .fixedSize()
                    .onHover { hovering in
                        isFolderPeekHovered = hovering
                        if !hovering { setFolderPeek(nil, visible: false) }
                    }
                    .position(
                        x: row.rect.maxX + 10 + FolderPeek.width / 2,
                        y: min(max(row.rect.midY, height / 2), proxy.size.height - height / 2))
                    .transition(.opacity)
            }
        }
        .allowsHitTesting(peekingFolder != nil)
        .animation(Motion.fade, value: peekingFolder?.id)
        .onChange(of: peekingFolder?.id) { _, showing in
            if showing == nil, peekedFolder != nil { dismissFolderPeek() }
        }
    }

    private func dismissFolderPeek() {
        folderPeekTask?.cancel()
        peekedFolder = nil
        isFolderPeekHovered = false
        tabManager.isSidebarPopoverOpen = false
        tabManager.isFolderPeekOpen = false
    }

    /// debounced show/hide, and never for a folder that is already open — its
    /// tabs are on screen already
    private func setFolderPeek(_ folder: TabFolder?, visible: Bool) {
        folderPeekTask?.cancel()
        let id = folder?.id
        folderPeekTask = Task {
            try? await Task.sleep(for: .milliseconds(visible ? 320 : 180))
            guard !Task.isCancelled else { return }
            if visible, let folder, !folder.isExpanded, !drag.isDragging,
                !tabManager.currentSpace.tabIDs(under: .folder(folder.id)).isEmpty
            {
                peekedFolder = id
                tabManager.isSidebarPopoverOpen = true
                tabManager.isFolderPeekOpen = true
            } else if !isFolderPeekHovered, peekedFolder != nil {
                // only release the hold this peek took, never another popover's
                peekedFolder = nil
                tabManager.isSidebarPopoverOpen = false
                tabManager.isFolderPeekOpen = false
            }
        }
    }

    /// debounced show/hide so cursor trips between button and peek don't flicker
    private func setPeek(visible: Bool) {
        peekTask?.cancel()
        peekTask = Task {
            try? await Task.sleep(for: .milliseconds(visible ? 150 : 200))
            guard !Task.isCancelled else { return }
            if visible {
                // nothing to peek at → don't show anything
                guard await !DownloadFile.loadAllOffMain().isEmpty else { return }
                guard !Task.isCancelled else { return }
                isPeekVisible = true
            } else if !isPeekHovered {
                isPeekVisible = false
            }
        }
    }

    /// the full tab area: pinned section, divider, New Tab, today section. a
    /// neighbour's panel is the same view, so it becomes live without a rebuild;
    /// only the live one reports frames, scroll and pointer to the shared state
    private func tabArea(_ space: Space, live: Bool) -> some View {
        let selectedID = live ? tabManager.selectedTabID : tabManager.selectedTabID(in: space)
        let ink = live ? self.ink : space.appearance.chromeInk
        return ScrollView {
            VStack(spacing: metrics.tabSpacing) {
                if !space.pinnedCollapsed {
                    ForEach(space.rows(in: .pinned)) { row in
                        liveRow(row, selectedID: selectedID)
                            .zIndex(-Double(row.depth))
                            .transition(row.depth > 0 ? .folderUnfurl : .identity)
                    }
                }

                if !space.pinnedTabs.isEmpty {
                    Rectangle()
                        .fill(ink.opacity(0.12))
                        .frame(height: 1)
                        .padding(.horizontal, 4)
                        // equal breathing room on both sides of the divider,
                        // independent of the uniform tab-to-tab spacing
                        .padding(.vertical, metrics.pinnedDividerGap - metrics.tabSpacing)
                        // the only mark between pinned and today tabs, so VoiceOver hears it as a heading
                        .accessibilityElement()
                        .accessibilityLabel("Today")
                        .accessibilityAddTraits(.isHeader)
                }

                NewTabRow(suppressHover: drag.isDragging)
                    .background(boundaryReader)

                ForEach(space.rows(in: .today)) { row in
                    liveRow(row, selectedID: selectedID)
                        .zIndex(-Double(row.depth))
                        .transition(row.depth > 0 ? .folderUnfurl : .identity)
                }
            }
        }
        .scrollIndicators(.automatic)
        .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y + $0.contentInsets.top > 0.5 } action: {
            _, scrolled in
            if live, scrolled != tabsScrolled {
                withAnimation(Motion.fade) { tabsScrolled = scrolled }
            }
        }
        // the empty room below the rows is still the sidebar, and a right-click
        // there is how a folder gets made. rows are hit first, so their own
        // menus still win
        .contentShape(Rectangle())
        .onContinuousHover(coordinateSpace: .named(Self.contentSpace)) { phase in
            if live, case .active(let point) = phase { menuPoint.value = point }
        }
        .contextMenu { sidebarMenu }
        // a link dragged in from a page or another app becomes a tab where it
        // lands; above the New Tab row it arrives pinned
        .dropDestination(for: URL.self, action: { urls, location -> Bool in
            guard let url = urls.first,
                let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https"
            else { return false }
            // the ScrollView's own space, lifted into the shared one the
            // resolver works in
            let point = CGPoint(x: location.x + measured.tabContentRect.minX, y: location.y + measured.tabContentRect.minY)
            switch resolveDrop(at: point, excluding: []) {
            case .list(let container, let index, _, _):
                tabManager.addTab(from: url, to: container, at: index)
            case .intoFolder(let id):
                tabManager.addTab(from: url, to: .folder(id), at: 0)
            case nil:
                tabManager.addTab(from: url, to: .section(.today), at: 0)
            }
            return true
        }, isTargeted: { _ in })
        // the tab list's bounds in the shared space, so the insertion line spans
        // the right width when a favourite (with no row frame) is dragged in
        .background {
            if live {
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { measured.tabContentRect = proxy.frame(in: .named(Self.contentSpace)) }
                        .onChange(of: proxy.frame(in: .named(Self.contentSpace))) { _, f in measured.tabContentRect = f }
                }
            }
        }
        // a hairline under the header, fading in once tabs scroll beneath it
        .overlay(alignment: .top) {
            Rectangle()
                .fill(ink.opacity(0.12))
                .frame(height: 1)
                .padding(.horizontal, 4)
                .opacity(live && tabsScrolled ? 1 : 0)
        }
        .onPreferenceChange(SidebarRowFrameKey.self) { if live { measured.rowFrames = $0 } }
        .onPreferenceChange(NewTabBoundaryKey.self) { if live { measured.newTabBoundaryY = $0 } }
        .environment(\.isLivePanel, live)
        .accessibilityHidden(!live)
    }

    /// right-clicking the sidebar where no row is: the other way a folder is
    /// made. it appears exactly where the click landed, pinned section included,
    /// resolved the same way a drop at that point would be
    @ViewBuilder
    private var sidebarMenu: some View {
        Button {
            switch menuPoint.value.flatMap({ resolveDrop(at: $0, excluding: []) }) {
            case .list(let container, let index, _, _):
                tabManager.newFolder(in: container, at: index)
            case .intoFolder(let id):
                tabManager.newFolder(in: .folder(id), at: 0)
            case nil:
                tabManager.newFolder()
            }
        } label: {
            Label("New Folder", systemImage: "folder.badge.plus").labelStyle(.titleAndIcon)
        }
    }

    /// how far a row at this depth is inset. the indent is part of the row's
    /// reported frame, so hit-testing and the insertion line agree with it
    private static let folderIndent: CGFloat = 12

    private func indent(_ depth: Int) -> CGFloat { CGFloat(depth) * Self.folderIndent }

    private func rowWidth(_ depth: Int) -> CGFloat {
        max(baseContentWidth - indent(depth), 1)
    }

    private func draggableRow(
        _ tab: BrowserTab, in row: SidebarRow, selectedID: BrowserTab.ID?
    ) -> some View {
        let folder: String? =
            if case .folder(let id) = row.container { tabManager.currentSpace.folder(id)?.name } else { nil }
        return TabRow(
            tab: tab, isSelected: tab.id == selectedID,
            dragInProgress: drag.isDragging, folder: folder
        )
        // source slot stays in place, dimmed, while it's being dragged
        .opacity(drag.tab?.id == tab.id ? 0.6 : 1)
        .background { rowFrameReporter(.tab(tab.id), in: row) }
        .padding(.leading, indent(row.depth))
        .gesture(
            dragGesture(
                tab, size: CGSize(width: rowWidth(row.depth), height: metrics.rowHeight)))
    }

    private func rowFrameReporter(_ entry: SidebarEntry, in row: SidebarRow) -> some View {
        LivePanelOnly {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: SidebarRowFrameKey.self,
                    value: [
                        SidebarRowFrame(
                            entry: entry, container: row.container, section: row.section,
                            depth: row.depth, rect: proxy.frame(in: .named(Self.contentSpace)))
                    ])
            }
        }
    }

    /// a live tab-list entry: a folder header, a draggable row, a split's merged
    /// segment row, or — while a dragged tab dwells over a single tab — the merge
    /// preview (the tab shrunk to one half, a grey drop highlight on the other)
    @ViewBuilder
    private func liveRow(_ row: SidebarRow, selectedID: BrowserTab.ID?) -> some View {
        switch row.kind {
        case .folder(let folder):
            FolderRow(
                folder: folder, isDropTarget: folderTarget == folder.id,
                dragInProgress: drag.isDragging,
                onHoverChanged: { setFolderPeek(folder, visible: $0) })
                .opacity(drag.folder?.id == folder.id ? 0.6 : 1)
                .background { rowFrameReporter(.folder(folder.id), in: row) }
                .padding(.leading, indent(row.depth))
                .gesture(
                    folderDragGesture(
                        folder,
                        size: CGSize(width: rowWidth(row.depth), height: metrics.rowHeight)))
        case .tab(let tab):
            if let merge, merge.targetID == tab.id,
                tabManager.currentSpace.splitGroup(containing: tab.id) == nil
            {
                mergePreviewRow(tab, in: row, side: merge.side)
            } else {
                draggableRow(tab, in: row, selectedID: selectedID)
            }
        case .group(let group, let members):
            // the grey gap is a merge (another tab coming in) or a lift (a pane of
            // this split). one stable liveSplitRow call either way: branching the
            // view shape here would tear out the row's in-flight drag gesture
            let liftedHere = liftedPaneID.flatMap { group.contains($0) ? $0 : nil }
            let gap = liftedHere != nil
                ? liftSlot
                : merge.flatMap { group.contains($0.targetID) ? $0.insertIndex : nil }
            liveSplitRow(group: group, members: members, insertIndex: gap, in: row)
        }
    }

    /// a split as one row: panes as pills while shown or previewing a drop, else
    /// flush with hairline dividers. a quick drag moves the whole split, a
    /// press-and-hold lifts one pane out, a click re-opens it
    private func liveSplitRow(
        group: SplitGroup, members allMembers: [BrowserTab], insertIndex: Int?, in row: SidebarRow
    ) -> some View {
        // a lifted pane leaves the row (it floats as the ghost); the segments
        // still slide, their identities being tab ids
        let members = allMembers.filter { $0.id != liftedPaneID }
        let isShown = tabManager.displayedSplitGroup?.id == group.id
        let pills = isShown || insertIndex != nil
        let groupDragging = drag.group?.id == group.id
        let control = splitControl(group, members: allMembers)
        let count = members.count + (insertIndex == nil ? 0 : 1)
        let gap: CGFloat = pills ? Self.splitSegmentGap : 0
        let segW = max((rowWidth(row.depth) - CGFloat(count - 1) * gap) / CGFloat(max(count, 1)), 1)
        return HStack(spacing: gap) {
            ForEach(Array(members.enumerated()), id: \.element.id) { i, tab in
                if insertIndex == i { greyPlaceholder }
                splitSegment(tab, pill: pills, control: control(tab), in: row)
                if !pills, i < members.count - 1 {
                    Rectangle().fill(ink.opacity(0.18)).frame(width: 1, height: 16)
                }
            }
            if insertIndex == members.count { greyPlaceholder }
        }
        .frame(height: metrics.rowHeight)
        // unshown split lights as one row on hover, like a normal tab
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(ink.opacity(!pills && hoveredSplitID == group.id && !drag.isDragging ? 0.09 : 0)))
        .padding(.leading, indent(row.depth))
        .opacity(groupDragging ? 0.6 : 1)
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { hovering in
            if hovering { hoveredSplitID = group.id }
            else if hoveredSplitID == group.id { hoveredSplitID = nil }
        }
        .gesture(splitRowGesture(group: group, members: members, segW: segW))
        .contextMenu { MenuEntriesView(entries: Self.splitRowMenuEntries(group, in: tabManager)) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(allMembers.map(\.displayTitle).joined(separator: ", "))
        .accessibilityValue(isShown ? "split view, selected" : "split view")
        .accessibilityAddTraits(isShown ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { focusSplitAsWhole(group) }
        .accessibilityActions { MenuEntryActions(entries: Self.splitRowMenuEntries(group, in: tabManager)) }
        .animation(Motion.pop, value: insertIndex)
        .animation(Motion.hover, value: hoveredSplitID == group.id)
    }

    /// one pane of a split row. the row owns the gestures, so a lifted pane can
    /// leave the layout without cancelling the row's in-flight drag
    private func splitSegment(
        _ tab: BrowserTab, pill: Bool, control: SplitSegmentCell.Control?, in row: SidebarRow
    ) -> some View {
        SplitSegmentCell(tab: tab, plain: !pill, lit: pill, control: drag.isDragging ? nil : control)
            .background { rowFrameReporter(.tab(tab.id), in: row) }
    }

    /// a pane's hover control, the tab row's one slot: an open pinned split
    /// offers − for the whole split; otherwise ✕ closes (or archives) that pane
    private func splitControl(
        _ group: SplitGroup, members: [BrowserTab]
    ) -> (BrowserTab) -> SplitSegmentCell.Control {
        let pinned = members.first?.isPinned == true
        let keepsPin = pinned && members.contains { $0.pendingURL == nil }
        return { tab in
            keepsPin
                ? .init(isCross: false, help: "Close Split and Keep Pinned", keys: ["⌘", "W"]) {
                    tabManager.requestClose(group, keepingPin: true)
                }
                : .init(
                    isCross: true, help: pinned ? "Archive Pinned Tab" : "Close Tab",
                    keys: pinned ? [] : ["⌘", "W"]
                ) { tabManager.requestClose(tab) }
        }
    }

    /// re-open a split from the sidebar — restoring its last-focused pane (or the
    /// first). a no-op when it's already the shown split, so a click can't sneak
    /// a pane-focus change (that's the content window's job)
    private func focusSplitAsWhole(_ group: SplitGroup) {
        tabManager.clearSelection()
        let pane = group.lastFocusedID.flatMap { group.contains($0) ? $0 : nil } ?? group.tabIDs.first
        tabManager.selectedTabID = pane
        tabManager.isCommandBarVisible = false
    }

    /// the split row's context menu, which VoiceOver also offers as actions
    static func splitRowMenuEntries(_ group: SplitGroup, in tabManager: TabManager) -> [MenuEntry] {
        let members = tabManager.currentSpace.tabs(in: group)
        let pinned = members.first?.isPinned == true
        var entries: [MenuEntry] = [
            .button(pinned ? "Unpin Split" : "Pin Split", pinned ? "pin.slash" : "pin") { tabManager.togglePin(group) },
            .divider,
            .button(group.isLinked ? "Unlink Panes" : "Open Links in Next Pane", "link") {
                tabManager.toggleSplitLinked(group)
            },
            .button("Unsplit", "rectangle") { tabManager.dissolveSplit(group) },
            .divider,
        ]
        if pinned, members.contains(where: { $0.pendingURL == nil }) {
            entries.append(.button("Close Split and Keep Pinned", "minus") {
                tabManager.requestClose(group, keepingPin: true)
            })
        }
        entries.append(.button(pinned ? "Archive Pinned Split" : "Close Split", "xmark") { tabManager.requestClose(group) })
        return entries
    }

    // MARK: - Split row gesture (click re-opens / drag moves whole / hold lifts one)

    private func splitRowGesture(group: SplitGroup, members: [BrowserTab], segW: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.contentSpace))
            .onChanged { onSplitDragChanged(group, members, segW, $0) }
            .onEnded { onSplitDragEnded(group, $0) }
    }

    private func onSplitDragChanged(
        _ group: SplitGroup, _ members: [BrowserTab], _ segW: CGFloat, _ value: DragGesture.Value
    ) {
        splitGestureLocation = value.location
        // press start: note the pane under the cursor and arm the lift timer
        if splitGestureGroupID != group.id {
            splitGestureGroupID = group.id
            splitGestureMode = .undecided
            liftedPaneID = nil
            splitGesturePaneID = members.first { member in
                measured.rowFrames.first(where: { $0.tabID == member.id })?.rect.contains(value.startLocation)
                    ?? false
            }?.id
            splitHoldTask?.cancel()
            splitHoldTask = Task {
                try? await Task.sleep(for: .milliseconds(Self.paneLiftHoldMS))
                guard !Task.isCancelled, splitGestureMode == .undecided,
                    splitGestureGroupID == group.id,
                    let paneID = splitGesturePaneID,
                    let pane = members.first(where: { $0.id == paneID })
                else { return }
                // held in place → lift this pane out: it floats as the ghost and
                // its slot becomes the grey gap (seeded where it sat). lock the slot
                // math to the row's current bounds so the gap can't oscillate
                splitGestureMode = .pane
                liftedPaneID = paneID
                let memberRects = members.compactMap { m in measured.rowFrames.first { $0.tabID == m.id }?.rect }
                liftAnchorRect = unionRect(memberRects) ?? .zero
                liftSlot = members.firstIndex { $0.id == paneID }
                let paneRect = measured.rowFrames.first { $0.tabID == paneID }?.rect
                let grab = paneRect.map {
                    CGSize(
                        width: value.startLocation.x - $0.minX,
                        height: value.startLocation.y - $0.minY)
                } ?? .zero
                drag.begin(
                    pane, fromEssentials: false,
                    sourceSize: CGSize(width: segW, height: metrics.rowHeight),
                    at: splitGestureLocation, grab: grab)
            }
            return
        }
        let moved = hypot(
            value.location.x - value.startLocation.x, value.location.y - value.startLocation.y)
        switch splitGestureMode {
        case .undecided:
            // moved before the hold fired → move the whole split as a unit
            if moved > Self.splitMoveThreshold {
                splitHoldTask?.cancel()
                splitGestureMode = .group
                let rowRect = unionRect(members.compactMap { m in measured.rowFrames.first { $0.tabID == m.id }?.rect })
                let grab = rowRect.map {
                    CGSize(width: value.startLocation.x - $0.minX, height: value.startLocation.y - $0.minY)
                } ?? .zero
                drag.beginGroup(
                    group, representative: members[0],
                    sourceSize: CGSize(width: baseContentWidth, height: metrics.rowHeight),
                    at: value.location, grab: grab)
            }
        case .group, .pane:
            drag.location = value.location
        }
    }

    private func onSplitDragEnded(_ group: SplitGroup, _ value: DragGesture.Value) {
        let mode = splitGestureMode
        let moved = hypot(value.translation.width, value.translation.height)
        splitHoldTask?.cancel()
        splitHoldTask = nil
        splitGestureGroupID = nil
        splitGestureMode = .undecided
        splitGesturePaneID = nil

        switch mode {
        case .undecided:
            // a click (no drag, no lift) → re-open the split if it isn't shown
            liftedPaneID = nil
            if tabManager.displayedSplitGroup?.id != group.id { focusSplitAsWhole(group) }
        case .group:
            liftedPaneID = nil
            drag.end()
        case .pane:
            withAnimation(Motion.pop) { liftedPaneID = nil }
            // lifted but barely moved → cancel; the pane stays in the split
            if moved < 10 {
                withAnimation(Motion.pop) { drag.clear() }
                resetMerge()
                resetLift()
            } else {
                drag.end()
            }
        }
    }

    /// the merge preview over a single tab: the tab in one half, a grey drop
    /// highlight in the other. reports the *full*-row frame (not the shrunk cell)
    /// so the dwell stays locked while the cursor is anywhere over the row
    private func mergePreviewRow(_ tab: BrowserTab, in row: SidebarRow, side: HorizontalSide) -> some View {
        HStack(spacing: Self.splitSegmentGap) {
            if side == .left { greyPlaceholder }
            SplitSegmentCell(tab: tab)
            if side == .right { greyPlaceholder }
        }
        .background { rowFrameReporter(.tab(tab.id), in: row) }
        .padding(.leading, indent(row.depth))
        .animation(Motion.pop, value: side)
    }

    private var greyPlaceholder: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(ink.opacity(0.12))
            .frame(maxWidth: .infinity)
            .frame(height: metrics.rowHeight)
    }

    // MARK: - Drag-to-split (dwell-over-tab)

    /// called as the drag moves: hold a merge preview while the cursor stays over
    /// its locked target, otherwise look for a new tab to dwell on
    private func updateDwell() {
        guard drag.isDragging, let dragged = drag.tab, !dragged.isEssential,
            drag.group == nil,  // moving a whole split never merges
            drag.folder == nil,  // nor does moving a folder
            !essentialZoneActive, drag.contentDropZone == nil
        else { resetMerge(); return }

        // locked onto a target: keep it while the cursor stays within its row
        if merge != nil, mergeAnchorRect.insetBy(dx: -4, dy: -4).contains(drag.location) {
            refreshMerge()
            return
        }

        // find a fresh tab/segment under the cursor to dwell on. nested rows
        // overlap, so the deepest hit wins — the first one is undefined
        let hits = measured.rowFrames.filter {
            $0.tabID != nil && $0.tabID != dragged.id && $0.rect.contains(drag.location)
        }
        guard let frame = hits.max(by: { $0.depth < $1.depth }), let frameTabID = frame.tabID
        else {
            resetMerge()
            return
        }
        // only the middle vertical third of a tab is the merge zone — the top and
        // bottom thirds stay reorder zones (insert above / below)
        let third = frame.rect.height / 3
        guard drag.location.y > frame.rect.minY + third,
            drag.location.y < frame.rect.maxY - third
        else {
            resetMerge()
            return
        }
        // can't merge a tab into a split it's already part of
        if let group = tabManager.currentSpace.splitGroup(containing: frameTabID),
            group.contains(dragged.id)
        {
            resetMerge()
            return
        }
        if dwellRowID != frameTabID {
            dwellRowID = frameTabID
            merge = nil
            dwellTask?.cancel()
            let targetID = frameTabID
            dwellTask = Task {
                try? await Task.sleep(for: .milliseconds(Self.mergeDwellMS))
                guard !Task.isCancelled, dwellRowID == targetID, drag.isDragging else { return }
                fireMerge(targetID)
            }
        }
    }

    /// the dwell fired — capture the target's full-row bounds and show the preview
    private func fireMerge(_ targetID: BrowserTab.ID) {
        let space = tabManager.currentSpace
        if let group = space.splitGroup(containing: targetID) {
            let rects = group.tabIDs.compactMap { id in measured.rowFrames.first { $0.tabID == id }?.rect }
            guard group.tabIDs.count < SplitGroup.maxPanes, let rect = unionRect(rects) else {
                resetMerge()
                return
            }
            mergeAnchorRect = rect
            merge = MergePreview(
                targetID: targetID, side: .left,
                insertIndex: slotIndex(drag.location.x, in: rect, slots: group.tabIDs.count + 1))
        } else {
            guard let rect = measured.rowFrames.first(where: { $0.tabID == targetID })?.rect else { return }
            mergeAnchorRect = rect
            merge = MergePreview(
                targetID: targetID,
                side: drag.location.x < rect.midX ? .left : .right, insertIndex: 0)
        }
    }

    /// recompute side / insertion slot from the cursor while the target is locked
    private func refreshMerge() {
        guard let current = merge else { return }
        if let group = tabManager.currentSpace.splitGroup(containing: current.targetID) {
            let idx = slotIndex(drag.location.x, in: mergeAnchorRect, slots: group.tabIDs.count + 1)
            if idx != current.insertIndex {
                merge = MergePreview(targetID: current.targetID, side: .left, insertIndex: idx)
            }
        } else {
            let side: HorizontalSide = drag.location.x < mergeAnchorRect.midX ? .left : .right
            if side != current.side {
                merge = MergePreview(targetID: current.targetID, side: side, insertIndex: 0)
            }
        }
    }

    private func resetMerge() {
        dwellTask?.cancel()
        dwellTask = nil
        if dwellRowID != nil { dwellRowID = nil }
        if merge != nil { merge = nil }
        if mergeAnchorRect != .zero { mergeAnchorRect = .zero }
    }

    // MARK: - Lift-out (pane pulled from its own split)

    /// while a pane is lifted out, track the slot it'd drop back into over its
    /// source row, or clear it once the cursor pulls clear and the list's
    /// insertion line takes over
    private func updateLift() {
        guard let lifted = liftedPaneID, liftAnchorRect != .zero,
            let group = tabManager.currentSpace.splitGroup(containing: lifted)
        else {
            if liftSlot != nil { liftSlot = nil }
            return
        }
        guard liftAnchorRect.insetBy(dx: 0, dy: -6).contains(drag.location) else {
            if liftSlot != nil { withAnimation(Motion.pop) { liftSlot = nil } }
            return
        }
        let slot = slotIndex(drag.location.x, in: liftAnchorRect, slots: group.tabIDs.count)
        if liftSlot != slot { withAnimation(Motion.pop) { liftSlot = slot } }
    }

    private func resetLift() {
        if liftSlot != nil { liftSlot = nil }
        if liftAnchorRect != .zero { liftAnchorRect = .zero }
    }

    /// open the empty-favourites drop zone while a dragged tab is held above the
    /// space header. opening pushes the header down, so the close threshold sits
    /// a zone's height below the open one
    private func updateEmptyEssentialsReveal() {
        // non-empty grids are always shown; an incognito window has none to drop into
        guard tabManager.kind == .main, tabManager.essentials.isEmpty else { return }
        let shouldReveal =
            drag.isDragging && drag.group == nil && drag.folder == nil
            && measured.spaceHeaderRect != .zero && drag.location.y < measured.spaceHeaderRect.midY
        if shouldReveal != revealEmptyEssentials {
            withAnimation(Motion.pop) { revealEmptyEssentials = shouldReveal }
        }
    }

    private func slotIndex(_ x: CGFloat, in rect: CGRect, slots: Int) -> Int {
        guard rect.width > 0, slots > 0 else { return 0 }
        let raw = Int((x - rect.minX) / rect.width * CGFloat(slots))
        return min(max(raw, 0), slots - 1)
    }

    private func unionRect(_ rects: [CGRect]) -> CGRect? {
        guard var u = rects.first else { return nil }
        for r in rects.dropFirst() { u = u.union(r) }
        return u
    }

    /// drop while a merge preview is up: tile the dragged tab with the target
    private func commitMergeDrop(_ tab: BrowserTab, _ preview: MergePreview) {
        let space = tabManager.currentSpace
        if let group = space.splitGroup(containing: preview.targetID) {
            tabManager.addToSplit(group, tab: tab, at: preview.insertIndex)
        } else if let target = space.tabs.first(where: { $0.id == preview.targetID }),
            target.id != tab.id
        {
            let members = preview.side == .left ? [tab, target] : [target, tab]
            tabManager.createSplit(members, anchor: target)
        }
    }

    private var boundaryReader: some View {
        LivePanelOnly {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: NewTabBoundaryKey.self,
                    value: proxy.frame(in: .named(Self.contentSpace)).midY)
            }
        }
    }

    private func dragGesture(_ tab: BrowserTab, size: CGSize) -> some Gesture {
        // instant drag; a small threshold keeps plain clicks selecting.
        // on macOS, scrolling is wheel/trackpad — no conflict with click-drag
        DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.contentSpace))
            .onChanged { value in
                if drag.tab == nil {
                    let origin = measured.rowFrames.first { $0.tabID == tab.id }?.rect.origin ?? value.startLocation
                    let grab = CGSize(
                        width: value.startLocation.x - origin.x,
                        height: value.startLocation.y - origin.y)
                    drag.begin(
                        tab, fromEssentials: false, sourceSize: size, at: value.location, grab: grab)
                } else {
                    drag.location = value.location
                }
            }
            .onEnded { value in
                drag.location = value.location
                drag.end()
            }
    }

    /// a folder is dragged whole — press-drag on its header row, exactly like a
    /// tab row, and its subtree travels with it
    private func folderDragGesture(_ folder: TabFolder, size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.contentSpace))
            .onChanged { value in
                if drag.folder == nil {
                    let origin =
                        measured.rowFrames.first { $0.entry == .folder(folder.id) }?.rect.origin
                        ?? value.startLocation
                    drag.beginFolder(
                        folder, sourceSize: size, at: value.location,
                        grab: CGSize(
                            width: value.startLocation.x - origin.x,
                            height: value.startLocation.y - origin.y))
                } else {
                    drag.location = value.location
                }
            }
            .onEnded { value in
                drag.location = value.location
                drag.end()
            }
    }

    /// the drag is over the favourites. the border is the space name's midline
    /// rather than the grid's own edge: one landmark you can aim at, with the
    /// pinned section owning everything below it. a folder is never a favourite
    private var essentialZoneActive: Bool {
        guard drag.isDragging, drag.folder == nil, measured.essentialsFrame != .zero else { return false }
        guard measured.spaceHeaderRect != .zero else { return measured.essentialsFrame.contains(drag.location) }
        return drag.location.y < measured.spaceHeaderRect.midY
    }

    /// the favourites grid's analytic geometry (the dragged tile excluded from
    /// the count, since it's pulled out of the layout while dragging)
    private var essentialsMath: EssentialsGridMath {
        EssentialsGridMath(
            width: measured.essentialsFrame.width, origin: measured.essentialsFrame.origin,
            spacing: metrics.tabSpacing, tileHeight: metrics.essentialTileHeight,
            minTileWidth: metrics.essentialTileMin)
    }

    /// the favourites laid out while dragging (the dragged one removed)
    private var essentialBaseCount: Int {
        tabManager.essentials.count - (drag.fromEssentials ? 1 : 0)
    }

    /// row-major insertion slot among the favourites for the current cursor,
    /// derived analytically so it tracks the cursor cleanly without glitching
    private var essentialDropIndex: Int {
        essentialsMath.insertionIndex(at: drag.location, count: essentialBaseCount)
    }

    /// the folder the drop would file into, so its row can show it
    private var folderDropTarget: TabFolder.ID? {
        if case .intoFolder(let id) = dropTarget { return id }
        return nil
    }

    @ViewBuilder
    private var dragOverlay: some View {
        if drag.isDragging {
            // the insertion line — only when the drop lands in the tab list: the
            // favourites grid opens a gap instead, and a dwell shows the merge
            // preview. its indent is what names the container it resolved to
            if merge == nil, liftSlot == nil, !essentialZoneActive,
                drag.contentDropZone == nil,  // over the content → the card overlay owns the preview
                case .list(_, _, let lineY, let depth) = dropTarget
            {
                let inset = indent(depth)
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(ink.opacity(0.85))
                    .frame(width: max(measured.tabContentRect.width - inset - 8, 0), height: 3)
                    .position(x: measured.tabContentRect.midX + inset / 2, y: lineY)
            }

            // one ghost following the cursor: a split as its pill row, a tab as a
            // row that morphs to a tile over the favourites. over the content the
            // content area's own ghost takes over
            if rearrange.incoming {
                EmptyView()
            } else if let folder = drag.folder {
                FolderDragGhost(folder: folder, rowSize: ghostRowSize)
                    .position(ghostCenter(size: ghostRowSize))
                    .allowsHitTesting(false)
            } else if let group = drag.group {
                SplitDragGhost(
                    members: tabManager.currentSpace.tabs(in: group),
                    gap: Self.splitSegmentGap, rowSize: ghostRowSize)
                    .position(ghostCenter(size: ghostRowSize))
                    .allowsHitTesting(false)
            } else if let tab = drag.tab {
                DragGhost(
                    tab: tab, overEssentials: essentialZoneActive,
                    tileSize: ghostTileSize, rowSize: ghostRowSize)
                    .position(ghostCenter(size: essentialZoneActive ? ghostTileSize : ghostRowSize))
                    .allowsHitTesting(false)
            }
        }
    }

    private func commitDrop() {
        // a folder drag carries no tab, and lands only in the list
        if let folder = drag.folder {
            if case .list(let container, let index, _, _) = dropTarget {
                tabManager.moveFolder(folder, to: container, at: index)
            } else if case .intoFolder(let id) = dropTarget {
                tabManager.moveFolder(folder, to: .folder(id), at: 0)
            }
            withAnimation(Motion.pop) { drag.clear() }
            resetMerge()
            resetLift()
            return
        }
        guard let tab = drag.tab else { return }
        let pendingMerge = merge
        // a pane lifted from its split and released back over that row → reorder it
        // to the gap's slot rather than treating it as a list move
        let liftReorder: (SplitGroup, Int)? = liftSlot.flatMap { slot in
            tabManager.currentSpace.splitGroup(containing: tab.id).map { ($0, slot) }
        }
        defer {
            withAnimation(Motion.pop) { drag.clear() }
            resetMerge()
            resetLift()
            if revealEmptyEssentials { withAnimation(Motion.pop) { revealEmptyEssentials = false } }
        }

        // dropped on a space icon → move the tab into that space
        if let spaceID = drag.spaceDropTarget,
            let destination = tabManager.spaces.first(where: { $0.id == spaceID })
        {
            tabManager.moveTab(tab, toSpace: destination)
            return
        }

        // moving a whole split as a unit → reorder all its panes together
        if let group = drag.group {
            switch dropTarget {
            case .list(let container, let index, _, _):
                tabManager.moveGroup(group, to: container, at: index)
            case .intoFolder(let id):
                tabManager.moveGroup(group, to: .folder(id), at: 0)
            case nil:
                break
            }
            return
        }

        // lifted a pane back into its own split at a new slot → reorder it there
        if let (group, slot) = liftReorder {
            tabManager.movePaneInSplit(group, tab: tab, to: slot)
            return
        }

        // dropped onto the content area → tile into a split
        if drag.contentDropZone != nil {
            commitContentSplit(tab)
            return
        }

        // released while dwelling over a tab → merge them into a split
        if let pendingMerge {
            commitMergeDrop(tab, pendingMerge)
            return
        }

        // dropped in the favourites grid → reorder there, or promote into it
        if essentialZoneActive {
            if tab.isEssential {
                tabManager.reorderEssential(tab, to: essentialDropIndex)
            } else {
                tabManager.promoteEssential(tab, at: essentialDropIndex)
            }
            return
        }
        // dropped in the tab list
        let container: SidebarContainer
        let index: Int
        switch dropTarget {
        case .list(let resolved, let slot, _, _): (container, index) = (resolved, slot)
        case .intoFolder(let id): (container, index) = (.folder(id), 0)
        case nil: return
        }
        if tab.isEssential {
            tabManager.demoteEssential(tab, to: container, at: index)
        } else {
            tabManager.moveTab(tab, to: container, at: index)
        }
    }

    /// a tab dropped on the content area, at the rearrange overlay's target: into
    /// the shown split, else tiled with the lone focused page on that side;
    /// without a resolved target, appended to the split or tiled on the right
    private func commitContentSplit(_ tab: BrowserTab) {
        guard !tab.isEssential else { return }
        let target = rearrange.target
        if let group = tabManager.displayedSplitGroup,
            group.leafCount < SplitGroup.maxPanes, !group.contains(tab.id)
        {
            if let target { tabManager.addPane(tab, to: group, target: target) }
            else { tabManager.addToSplit(group, tab: tab) }
        } else if let focused = tabManager.selectedTab, focused.id != tab.id,
            !focused.isEssential,
            tabManager.currentSpace.tabs.contains(where: { $0.id == focused.id }),
            tabManager.currentSpace.splitGroup(containing: tab.id) == nil
        {
            tabManager.createSplit(
                dropping: tab, onto: focused, edge: target?.edge ?? .right)
        }
    }

    /// the entries the current drag carries — a folder's whole subtree, a split's
    /// every pane, or the one tab. They're excluded from the insertion maths, and
    /// no resolution may land inside them
    private var draggedEntries: Set<SidebarEntry> {
        let space = tabManager.currentSpace
        if let folder = drag.folder {
            var carried: Set<SidebarEntry> = [.folder(folder.id)]
            for id in space.tabIDs(under: .folder(folder.id)) { carried.insert(.tab(id)) }
            for id in space.folderIDs(under: .folder(folder.id)) { carried.insert(.folder(id)) }
            return carried
        }
        if let group = drag.group { return Set(group.tabIDs.map { SidebarEntry.tab($0) }) }
        return drag.tab.map { [.tab($0.id)] } ?? []
    }

    /// where the current drag would land
    private var dropTarget: DropResolution? {
        guard drag.isDragging else { return nil }
        // a folder has nowhere to go outside the sidebar, so a release there
        // cancels instead of filing it wherever the cursor's y happened to point
        if drag.folder != nil, drag.location.x > measured.tabContentRect.maxX + metrics.rowTrailingPadding {
            return nil
        }
        return resolveDrop(at: drag.location, excluding: draggedEntries)
    }

    /// resolve a point in the sidebar's shared space to a drop position. A gap
    /// between two rows names as many candidate parents as the deeper row has
    /// ancestors, and the cursor's x picks between them by indent.
    private func resolveDrop(at point: CGPoint, excluding excluded: Set<SidebarEntry>)
        -> DropResolution?
    {
        guard let boundary = measured.newTabBoundaryY else { return nil }
        let space = tabManager.currentSpace
        let section: SidebarSection = point.y < boundary ? .pinned : .today
        let rows =
            measured.rowFrames
            .filter { $0.section == section && !excluded.contains($0.entry) }
            .sorted { $0.rect.midY < $1.rect.midY }

        // over a folder's own row: its middle band files the drop *into* it,
        // which is the only way a tab joins a folder
        if let folder = rows.last(where: { frame in
            if case .folder = frame.entry { return frame.rect.contains(point) }
            return false
        }), case .folder(let id) = folder.entry {
            let edge = folder.rect.height / 4
            if point.y > folder.rect.minY + edge, point.y < folder.rect.maxY - edge {
                return .intoFolder(id)
            }
        }

        let above = rows.last { $0.rect.midY < point.y }
        let below = rows.first { $0.rect.midY >= point.y }

        // the containers this gap could belong to: everything from the deepest
        // side up to the shallower one
        var candidates: [SidebarContainer] = []
        if let above {
            // just under an *expanded* folder's header, the first candidate is
            // inside it — that gap is its first child slot
            if case .folder(let id) = above.entry, space.folder(id)?.isExpanded == true,
                !excluded.contains(.folder(id))
            {
                candidates.append(.folder(id))
            }
            var current: SidebarContainer? = above.container
            while let container = current {
                candidates.append(container)
                if case .folder(let id) = container { current = space.parent(of: .folder(id)) }
                else { current = nil }
            }
        }
        let floor = below?.container ?? .section(section)
        // never resolve above the row below's own container — a drop between two
        // siblings can't land outside them
        if let cut = candidates.firstIndex(of: floor) {
            candidates = Array(candidates.prefix(through: cut))
        } else if candidates.isEmpty {
            candidates = [floor]
        }
        // deepest first is the order the cursor reads left-to-right in reverse
        let chosen =
            candidates.first { space.depth(of: $0) <= depthFor(x: point.x) }
            ?? candidates.last ?? .section(section)
        // a resolution inside the dragged folder would make the tree a cycle
        if case .folder(let id) = chosen, excluded.contains(.folder(id)) { return nil }

        let index = rows.filter { $0.container == chosen && $0.rect.midY < point.y }.count
        return .list(
            container: chosen, index: index,
            lineY: lineY(above: above, below: below, in: section, boundary: boundary),
            depth: space.depth(of: chosen))
    }

    /// the indent level the drag aims at, read from the ghost's leading edge —
    /// the cursor's own x carries the grab offset, which would pick the parent.
    /// each level is a band centred on its indent, so straight down keeps depth
    private func depthFor(x: CGFloat) -> Int {
        guard drag.isDragging else {
            return max(0, Int((x - measured.tabContentRect.minX - metrics.rowLeadingPadding) / Self.folderIndent))
        }
        let lead = x - min(max(drag.grabOffset.width, 0), ghostRowSize.width) - measured.tabContentRect.minX
        return max(0, Int(lead / Self.folderIndent + 0.5))
    }

    private func lineY(
        above: SidebarRowFrame?, below: SidebarRowFrame?, in section: SidebarSection,
        boundary: CGFloat
    ) -> CGFloat {
        let spacing = metrics.tabSpacing
        switch (above, below) {
        case (nil, nil): return section == .pinned ? boundary - 22 : boundary + 22
        case (nil, .some(let b)): return b.rect.minY - spacing / 2
        case (.some(let a), nil): return a.rect.maxY + spacing / 2
        case (.some(let a), .some(let b)): return (a.rect.maxY + b.rect.minY) / 2
        }
    }

    /// the ghost's centre for a rendered `size`, keeping the cursor on the spot it
    /// grabbed; the grab offset is clamped so a ghost morphed smaller than its
    /// source stays under the cursor
    private func ghostCenter(size: CGSize) -> CGPoint {
        let gx = min(max(drag.grabOffset.width, 0), size.width)
        let gy = min(max(drag.grabOffset.height, 0), size.height)
        return CGPoint(
            x: drag.location.x - gx + size.width / 2,
            y: drag.location.y - gy + size.height / 2)
    }

    /// the ghost's size over the tab list — a full-width tab row
    private var ghostRowSize: CGSize {
        CGSize(width: max(measured.tabContentRect.width, 120), height: metrics.rowHeight)
    }

    /// the ghost's size over the favourites — the exact width of the slot it'll
    /// land in, i.e. the gap's row in the previewed (count + the gap) layout
    private var ghostTileSize: CGSize {
        let w = essentialsMath.tileWidth(forSlot: essentialDropIndex, count: essentialBaseCount + 1)
        let width = (w.isFinite && w > 0) ? w : (measured.essentialsFrame.width > 0 ? measured.essentialsFrame.width : measured.tabContentRect.width)
        return CGSize(width: width, height: metrics.essentialTileHeight)
    }

    // MARK: - Space carousel

    /// empty gutter between panels in the swipe filmstrip, so the next space's
    /// tabs arrive after a window-edge gap rather than flush against the last
    private static let spaceGutter: CGFloat = 14

    /// same window-edge gap, but between the library panel and the spaces, so
    /// neither shows while the other is centred
    private static let libraryGutter: CGFloat = 14

    /// the content column's fixed width with the library closed: exactly what the
    /// margins leave, so rows don't re-truncate while the sidebar animates
    private var baseContentWidth: CGFloat {
        Self.contentWidth(sidebarWidth: width, rim: edgeInset, collapsed: isSidebarCollapsed)
    }

    /// static so the suite can check the content fits between the margins
    static func contentWidth(sidebarWidth: Double, rim: Double, collapsed: Bool) -> CGFloat {
        CGFloat(sidebarWidth) - contentInset - trailingInset(rim: rim, collapsed: collapsed)
    }
    /// wider by the library's icon rail, which the whole sidebar grows to fit
    /// (see MainView.libraryRailExtra). fixing the panel at this width keeps the
    /// list from reflowing while that growth animates
    private var libraryContentWidth: CGFloat { baseContentWidth + LibrarySidebar.railWidth }

    /// the normal sidebar contents — url field, fixed favourites, and the space
    /// carousel — i.e. everything shown when the library is closed. lives beside
    /// the library panel so the pair can slide between the two
    private var spaceContent: some View {
        VStack(alignment: .leading, spacing: metrics.urlToTabsGap) {
            if !showsToolbar {
                UrlField()
                    .modifier(BlendedInk())
            }
            // global favourites stay fixed here, above the swiping space pager,
            // so they persist across space switches. with none yet, the drop zone
            // opens only once a dragged tab is pulled up past the space header
            Live {
                if !tabManager.essentials.isEmpty || (drag.isDragging && revealEmptyEssentials) {
                    EssentialsGrid(
                        previewIndex: essentialZoneActive ? essentialDropIndex : nil,
                        hiddenID: drag.fromEssentials ? drag.tab?.id : nil,
                        dragActive: drag.isDragging)
                        .modifier(BlendedInk())
                        .background {
                            GeometryReader { proxy in
                                Color.clear
                                    .onAppear { measured.essentialsFrame = proxy.frame(in: .named(Self.contentSpace)) }
                                    .onChange(of: proxy.frame(in: .named(Self.contentSpace))) { _, f in measured.essentialsFrame = f }
                            }
                        }
                }
            }
            spacePager
        }
    }

    private var currentIndex: Int {
        tabManager.stripSpaces.firstIndex { $0.id == tabManager.selectedSpaceID } ?? 0
    }

    /// where a swipe starts from: the current space, or the uncommitted target
    /// of a run of quick swipes
    private var swipeBase: Int { chainBase ?? currentIndex }

    /// a space's header and tab list. The current space's is live (drag to
    /// reorder, selection, rename, edit); a neighbour's is the same tab list,
    /// parked, so switching only changes which one is interactive
    private func panel(_ space: Space, live: Bool) -> some View {
        VStack(alignment: .leading, spacing: metrics.headerToTabsGap) {
            if live {
                SpaceHeader()
                    // track the header's position so a drag pulled up past it can open
                    // the (empty) favourites drop zone
                    .background {
                        GeometryReader { proxy in
                            Color.clear
                                .onAppear { measured.spaceHeaderRect = proxy.frame(in: .named(Self.contentSpace)) }
                                .onChange(of: proxy.frame(in: .named(Self.contentSpace))) { _, f in
                                    measured.spaceHeaderRect = f
                                }
                        }
                    }
            } else {
                ParkedSpaceHeader(space: space)
            }
            if SpaceLock.shared.isLocked(space) {
                LockedTabsNote(space: space)
            } else {
                tabArea(space, live: live)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.chromeInk, live ? ink : space.appearance.chromeInk)
        .environment(\.spaceAccent, live ? tabManager.currentSpace.appearance.accent : space.appearance.accent)
    }

    /// space switching as a filmstrip: every built space side by side, scrolled
    /// to the selected one. only the current space's panel is live
    private var spacePager: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let pitch = w + Self.spaceGutter
            let built = builtSlots
            let slots = tabManager.stripSpaces.enumerated().filter {
                !PerfFlags.windowsFilmstripPanels || built.contains($0.offset)
            }
            ZStack(alignment: .topLeading) {
                ForEach(slots, id: \.element.id) { i, space in
                    let live = space.id == tabManager.selectedSpaceID
                    PanelSlot(space: space, live: live) { panel(space, live: live) }
                        .equatable()
                        .frame(width: w)
                        .offset(x: CGFloat(i) * pitch)
                        .allowsHitTesting(live)
                }
            }
            .modifier(PagerOffset(pitch: pitch))
            .frame(width: w, height: geo.size.height, alignment: .topLeading)
            .clipped()
            .onAppear {
                panelWidth = w
                tabManager.spacePagePosition = Double(currentIndex)
                tabManager.backdropPosition = Double(currentIndex)
            }
            .onChange(of: w) { _, new in panelWidth = new }
            .task(id: currentIndex) {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled, settledIndex != currentIndex else { return }
                previousSettledIndex = settledIndex
                settledIndex = currentIndex
            }
        }
    }

    /// panels kept built: the current slot, the slot it slid in from, the settled
    /// space and its neighbours, and the space settled before. a run of quick
    /// swipes keeps only the live panel and the run's own reach
    private var builtSlots: Set<Int> {
        if let chainBase { return [currentIndex, chainBase - 1, chainBase, chainBase + 1] }
        let from = currentIndex + (tabManager.spaceSwitchForward ? -1 : 1)
        let settled = settledIndex ?? currentIndex
        var built: Set<Int> = [currentIndex, from, settled - 1, settled, settled + 1]
        if !tabManager.switchSlides { built.formUnion([currentIndex - 1, currentIndex + 1]) }
        if let previousSettledIndex { built.insert(previousSettledIndex) }
        return built
    }

    /// finger travel needed to move one full page, as a multiple of the page
    /// pitch — above 1 makes the swipe less sensitive (drag further per space)
    private static let swipeResistance: CGFloat = 1.3

    private func handleSwipeChanged(_ translation: CGFloat) {
        // library sits left of the first space but isn't in the pager strip;
        // leave the (hidden) pager parked so it doesn't switch spaces behind it.
        // the open/close decision lands on release. an incognito window has one space
        guard tabManager.kind == .main, !tabManager.isLibraryOpen else { return }
        let travel = (panelWidth + Self.spaceGutter) * Self.swipeResistance
        guard travel > 0 else { return }

        // a new swipe (even one starting mid-settle) takes over the carousel,
        // anchored to the live position so it continues seamlessly
        if !isSwiping { beginInteractiveSwipe() }

        // finger right (positive) reveals the previous (left) space, so the
        // position decreases. cap at the immediate neighbours and the row ends
        let base = Double(swipeBase)
        var pos = swipeAnchor - Double(translation) / Double(travel)
        pos = max(base - 1, min(base + 1, pos))
        pos = max(0, min(Double(tabManager.spaces.count - 1), pos))
        tabManager.spacePagePosition = pos
        tabManager.backdropPosition = pos  // colour tracks the drag 1:1
    }

    /// take over the carousel for a freshly-started swipe. a settle in flight
    /// hands its target over as the chain's base: the switch commits only when a
    /// settle finishes undisturbed
    private func beginInteractiveSwipe() {
        isSwiping = true
        settleToken += 1  // invalidate any in-flight settle's completion
        if isSettling, let pending = pendingTarget {
            chainBase = pending
            pendingTarget = nil
        }
        swipeAnchor = onScreenPosition
        isSettling = false
        // the drag writes the position un-animated from here, which cancels the
        // spring — so hand it the value the spring was actually showing, or the
        // strip jumps from mid-flight to wherever the model had already landed
        tabManager.spacePagePosition = swipeAnchor
    }

    /// where the filmstrip is on screen: `withAnimation` stores the destination at
    /// once and interpolates only the rendered `.offset`
    private var onScreenPosition: Double {
        guard isSettling else { return tabManager.spacePagePosition }
        let target = tabManager.spacePagePosition - settleFrom
        let elapsed = CACurrentMediaTime() - settleStart
        return settleFrom + Motion.carouselSpring.value(target: target, time: elapsed)
    }

    private func handleSwipeEnded(_ translation: CGFloat) {
        // released now, not at settle, so the next swipe can take over at once
        let wasSwiping = isSwiping
        isSwiping = false
        guard tabManager.kind == .main else { return }
        let travel = (panelWidth + Self.spaceGutter) * Self.swipeResistance
        let threshold = travel * 0.25  // a quarter-page of finger travel commits

        // library behaves like the page left of space 0: swipe left (finger
        // left, negative) slides back out to the spaces
        if tabManager.isLibraryOpen {
            if translation < -threshold {
                withAnimation(Motion.panel) {
                    tabManager.isLibraryOpen = false
                }
            }
            return
        }

        guard wasSwiping else { return }
        let base = swipeBase
        let last = tabManager.spaces.count - 1

        // already at the leftmost space and swiping further right → open the
        // Library (Archive/Downloads/History), arc's "swipe past the edge" feel
        if translation > threshold, base == 0 {
            withAnimation(Motion.panel) {
                tabManager.isLibraryOpen = true
            }
            return
        }

        // commit relative to where the carousel actually sits now (a chained
        // swipe may have started mid-settle), not the raw finger translation
        var target = base
        if tabManager.spacePagePosition < Double(base) - 0.25, base - 1 >= 0 {
            target = base - 1
        } else if tabManager.spacePagePosition > Double(base) + 0.25, base + 1 <= last {
            target = base + 1
        }

        // at release: show the target space's (already-mounted) page now, so the
        // content crossfades in lockstep with the slide instead of snapping in
        // when the carousel settles. the pager's own reslot stays at completion
        // slots are `stripSpaces` order, which a click-jump's glide reorders
        let landing = tabManager.stripSpaces[target]
        if target != base, let index = tabManager.spaces.firstIndex(where: { $0.id == landing.id }) {
            tabManager.beginContentSwitch(toSpaceAt: index)
        }

        isSettling = true
        pendingTarget = target
        settleFrom = tabManager.spacePagePosition
        settleStart = CACurrentMediaTime()
        settleToken += 1
        let token = settleToken
        // the colour eases straight to the target with no overshoot, so the
        // spring's bounce can't flash the next space's colour mid-settle
        withAnimation(Motion.spaceColorSettle) {
            tabManager.backdropPosition = Double(target)
        }
        withAnimation(Motion.carousel) {
            tabManager.spacePagePosition = Double(target)
        } completion: {
            // bail if a newer swipe superseded this settle (it carries on the chain)
            guard token == settleToken else { return }
            if target != currentIndex {
                if chainBase != nil {
                    settledIndex = target
                    previousSettledIndex = nil
                }
                tabManager.selectSpace(landing)  // model catches up; panel reslots
            } else {
                tabManager.endContentSwitch()
            }
            chainBase = nil
            isSettling = false
            pendingTarget = nil
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 8) {
            DownloadPill()
            UpdatePill()
            bottomRow
        }
        .animation(Motion.pop, value: Updates.shared.readyVersion ?? Updates.shared.availableVersion)
        .animation(Motion.pop, value: DownloadManager.shared.shelf.map(\.id))
    }

    private var bottomRow: some View {
        HStack(spacing: 8) {
            if tabManager.kind == .incognito {
                IncognitoBadge()
                Spacer(minLength: 0)
            } else if tabManager.isLibraryOpen {
                HoverIconButton("chevron.left", size: 14, weight: .semibold, standalone: true) {
                    tabManager.isLibraryOpen = false
                }
                .tooltip("Back to Spaces")
                Spacer(minLength: 0)
            } else {
                LibraryButton {
                    isPeekVisible = false
                    tabManager.isLibraryOpen = true
                } onHoverChanged: { hovering in
                    setPeek(visible: hovering)
                }

                // spaces fill the middle, between the library and the profile
                SpaceSwitcher()

                ProfileButton()
            }
        }
        .animation(Motion.panel, value: tabManager.isLibraryOpen)
    }
}

/// current space name + icon, aligned to the tab rows. hovering highlights the
/// row and reveals an edit button on the right that opens the space editor
private struct SpaceHeader: View {
    @Environment(TabManager.self) private var tabManager
    @Environment(\.sidebarMetrics) private var metrics
    @Environment(\.chromeInk) private var ink
    // suppress hover affordances while a tab is being dragged, so the icon stays
    // put (no chevron swap / pencil) and slides with the row as the layout shifts
    @Environment(SidebarDragState.self) private var drag
    @State private var isHovering = false
    @State private var isEditing = false
    @State private var isRenaming = false
    @State private var draftName = ""
    @FocusState private var nameFocused: Bool
    @State private var rowFrame = FrameBox()
    @State private var clickMonitor: Any?
    @State private var editHover = false
    @State private var chevronHover = false

    var body: some View {
        let _ = Bench.tick("SpaceHeader")
        let space = tabManager.currentSpace
        // a drag passing over the header must not trigger hover UI, and an
        // incognito window's space is not one you edit
        let hoverActive = isHovering && !drag.isDragging && tabManager.kind == .main
        let active = hoverActive || isEditing || isRenaming
        HStack(spacing: 8) {
            // hovering swaps the space icon for a chevron that folds the pinned
            // section away; it points down when open, right (−90°) when collapsed
            if hoverActive {
                Button {
                    withAnimation(Motion.pop) { space.pinnedCollapsed.toggle() }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(ink.opacity(chevronHover ? 0.95 : 0.7))
                        .rotationEffect(.degrees(space.pinnedCollapsed ? -90 : 0))
                        .frame(width: 16, height: 16)
                        // 22pt highlight centred on the 16pt glyph, so it reads
                        // like the other buttons without shifting the name
                        .background(
                            Capsule()
                                .fill(ink.opacity(chevronHover ? 0.12 : 0))
                                .frame(width: 22, height: 22))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { chevronHover = $0 }
                .animation(Motion.hover, value: chevronHover)
                .tooltip(space.pinnedCollapsed ? "Show pinned tabs" : "Hide pinned tabs")
                .transition(.opacity)
            } else {
                SpaceGlyph(icon: space.icon, size: 13)
                    .frame(width: 16, height: 16)
                    .foregroundStyle(space.appearance.accent)
                    .transition(.opacity)
            }

            if isRenaming {
                TextField("Name", text: $draftName)
                    .textFieldStyle(.plain)
                    .font(.system(size: metrics.fontSize, weight: .bold))
                    .foregroundStyle(ink)
                    .focused($nameFocused)
                    .onSubmit { commitRename(space) }
                    .onExitCommand { isRenaming = false }  // esc discards
                    .onChange(of: nameFocused) { _, focused in
                        if !focused { commitRename(space) }  // click-away commits
                    }
            } else {
                Text(space.name)
                    .font(.system(size: metrics.fontSize, weight: .bold))
                    .foregroundStyle(ink.opacity(0.7))
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if active, !isRenaming {
                Button {
                    isEditing = true
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(ink.opacity(editHover ? 0.95 : 0.7))
                        .frame(width: 22, height: 22)
                        .background(
                            Capsule()
                                .fill(ink.opacity(editHover ? 0.13 : 0)))
                        .animation(Motion.hover, value: editHover)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { editHover = $0 }
                .tooltip("Edit Space…")
            }
        }
        // reserve the edit button's height so the row doesn't grow on hover
        .frame(height: 22)
        .padding(.leading, metrics.rowLeadingPadding)
        .padding(.trailing, metrics.rowTrailingPadding)
        .padding(.vertical, metrics.headerVPadding)  // 22 + padding = rowHeight, matching a tab row
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(ink.opacity(active ? 0.08 : 0))
        )
        .animation(Motion.hover, value: active)
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        // its buttons only appear on hover, so they're offered as actions instead
        .accessibilityElement(children: isRenaming ? .contain : .ignore)
        .accessibilityLabel(space.name)
        .accessibilityValue(space.pinnedCollapsed ? "pinned tabs hidden" : "")
        .accessibilityAddTraits(.isHeader)
        .accessibilityActions {
            if tabManager.kind == .main {
                Button(space.pinnedCollapsed ? "Show Pinned Tabs" : "Hide Pinned Tabs") {
                    withAnimation(Motion.pop) { space.pinnedCollapsed.toggle() }
                }
                Button("Rename Space") { beginRename(space) }
                Button("Edit Space…") { isEditing = true }
            }
        }
        .onHover { isHovering = $0 }
        // tap the row (not the edit button) to rename inline
        .onTapGesture { if !isRenaming, tabManager.kind == .main { beginRename(space) } }
        // track the row's window-space frame so a click-away can tell "outside"
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { rowFrame.value = proxy.frame(in: .global) }
                    .onChange(of: proxy.frame(in: .global)) { _, f in rowFrame.value = f }
            }
        )
        // while renaming, any mouse-down outside the row commits (like Return),
        // since macOS won't resign the field's focus on a plain background click
        .onChange(of: isRenaming) { _, renaming in
            renaming ? startClickMonitor(space) : stopClickMonitor()
        }
        .onDisappear { stopClickMonitor() }
        // the bottom icons' "Edit Space…" routes here so there's only ever one editor
        .onChange(of: tabManager.editSpaceRequest) { isEditing = true }
        // the gradient eye launches a full-window preview: tuck the editor away
        // while it's up, then reopen it (the editor resumes the stashed edit) once
        // the preview closes
        .onChange(of: tabManager.gradientPreview) { _, preview in
            if preview != nil {
                isEditing = false
            } else if tabManager.resumeGradientEdit != nil {
                isEditing = true
            }
        }
        // anchored to the stable row, not the hover-only button, so moving onto
        // the popover doesn't unhover and dismiss it
        .popover(isPresented: $isEditing) {
            SpaceEditor(space: space)
        }
    }

    private func startClickMonitor(_ space: Space) {
        stopClickMonitor()
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            guard let content = event.window?.contentView else { return event }
            // NSEvent is bottom-left origin; SwiftUI .global is top-left
            let point = CGPoint(
                x: event.locationInWindow.x,
                y: content.bounds.height - event.locationInWindow.y)
            if !rowFrame.value.contains(point) {
                commitRename(space)
            }
            return event  // let the click still do its thing
        }
    }

    private func stopClickMonitor() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
    }

    private func beginRename(_ space: Space) {
        draftName = space.name
        isRenaming = true
        DispatchQueue.main.async { nameFocused = true }
    }

    private func commitRename(_ space: Space) {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != space.name {
            tabManager.updateSpace(space, name: trimmed)
        }
        isRenaming = false
    }
}

/// full-width "+ new tab" row with hover highlight
private struct NewTabRow: View {
    @Environment(TabManager.self) private var tabManager
    @Environment(\.sidebarMetrics) private var metrics
    @Environment(\.chromeInk) private var ink
    var suppressHover = false
    @State private var isHovering = false

    var body: some View {
        let _ = Bench.tick("NewTabRow")
        Button {
            tabManager.openNewTabBar()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .bold))
                Text("New Tab")
                    .font(.system(size: metrics.fontSize))
                Spacer(minLength: 0)
            }
            .foregroundStyle(ink.opacity(0.7))
            .padding(.leading, metrics.rowLeadingPadding)
            .padding(.trailing, metrics.rowTrailingPadding)
            .padding(.vertical, metrics.rowVPadding)
            .background(RowHighlight(opacity: isHovering && !suppressHover ? 0.09 : 0))
            .animation(Motion.hover, value: isHovering)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

/// one tab inside a split's merged sidebar row: favicon + title in a rounded
/// pill. the focused pane (the one the url bar drives) is brighter; the others
/// carry a standing light-grey highlight. tapping a pane focuses it
private struct SplitSegmentCell: View {
    @Environment(\.sidebarMetrics) private var metrics
    @Environment(\.chromeInk) private var ink
    let tab: BrowserTab
    /// no pill background — for an unshown split, where the row carries the
    /// highlight and hairline dividers separate the panes. the cell is purely
    /// visual: the split row owns all gestures (tap / move-whole / lift-one)
    var plain: Bool = false
    /// a pane of the shown split in the list: wears the selected tab's look
    var lit: Bool = false
    /// shown on hover; nil in ghosts, previews and mid-drag
    var control: Control?
    @State private var isHovering = false

    struct Control {
        let isCross: Bool
        let help: String
        let keys: [String]
        let action: () -> Void
    }

    var body: some View {
        let shown = isHovering ? control : nil
        HStack(spacing: 6) {
            favicon
            Text(tab.displayTitle)
                .font(.system(size: metrics.fontSize))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(ink)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let shown {
                HoverIconButton(boxSize: metrics.closeBoxSize, action: shown.action) {
                    MinusCrossGlyph(isCross: shown.isCross)
                }
                .frame(height: 16)
                .tooltip(shown.help, keys: shown.keys)
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, shown == nil ? 8 : 2)
        .frame(height: metrics.rowHeight)
        .background(RowHighlight(opacity: plain ? 0 : 0.12, isSelected: lit && !plain))
        .onHover { isHovering = $0 }
        .animation(Motion.hover, value: shown == nil)
    }

    @ViewBuilder
    private var favicon: some View {
        if let icon = tab.favicon {
            Image(nsImage: icon)
                .resizable()
                .scaledToFit()
                .frame(width: 16, height: 16)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        } else {
            Image(systemName: "globe")
                .font(.system(size: 12))
                .foregroundStyle(ink.opacity(0.6))
                .frame(width: 16, height: 16)
        }
    }
}

/// single tab row: favicon, title, loading spinner / close-on-hover. internal so
/// the self-test can render a real row
struct TabRow: View {
    @Environment(TabManager.self) private var tabManager
    @Environment(\.sidebarMetrics) private var metrics
    @Environment(\.chromeInk) private var ink
    let tab: BrowserTab
    let isSelected: Bool
    var dragInProgress = false
    /// the folder the row is filed under, for VoiceOver
    var folder: String?
    @State private var isHovering = false
    @State private var iconHovering = false
    @State private var textHovering = false
    @State private var cmdHeld = false
    @State private var flagsMonitor: Any?
    @State private var draftName = ""
    /// renaming inline, in the row itself — click the tab you're already on
    @State private var isEditing = false
    @FocusState private var nameFocused: Bool
    /// true for two seconds once the dust has settled, so the hint can point
    /// out that the name you were just given is yours to change
    @State private var justRenamed = false
    @State private var hintTask: Task<Void, Never>?

    /// commit an inline rename once, whether it ended by Enter or by clicking
    /// away (both paths fire, and the second must not re-apply a stale draft)
    private func commitInlineRename() {
        guard isEditing else { return }
        isEditing = false
        // an emptied field means "back to the page's own title" — the policy
        // lives in rename(_:to:) so the menu's dialog behaves the same way
        tabManager.rename(tab, to: draftName)
    }

    /// hover affordances are suppressed while a drag is happening, so other
    /// rows don't light up as the ghost passes over them
    private var showsHover: Bool { isHovering && !dragInProgress }

    /// "Click to rename" shows only just after a rename lands, and only on the
    /// selected tab — on any other row a click selects instead
    private var showsRenameHint: Bool {
        isSelected && !isEditing && justRenamed
    }
    /// a pinned tab sitting somewhere other than its saved page
    private var offPinned: Bool { tab.isOffPinnedURL }
    /// only a pinned row carries the unread badge
    private var shownTitle: String { tab.isPinned ? tab.badgedTitle : tab.displayTitle }
    /// staged for a split via ⌘/⇧-click
    private var multiSelected: Bool { tabManager.selection.contains(tab.id) }
    /// the accent of the space this row is drawn for — a neighbour panel in the
    /// carousel is not the current space
    @Environment(\.spaceAccent) private var accent
    private var highlightOpacity: Double {
        if isSelected { return 0.22 }
        if multiSelected { return 0.16 }
        if showsHover { return 0.09 }
        return 0
    }

    var body: some View {
        let _ = Bench.tick("TabRow")
        Group {
            if offPinned { splitRow } else { plainRow }
        }
        .contentShape(Rectangle())
        // one element to VoiceOver, not a favicon plus a label plus two hover
        // buttons: the row *is* the control, and its name is the tab's name
        .accessibilityElement(children: .combine)
        .accessibilityLabel(shownTitle)
        .accessibilityValue(accessibilityState)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { select() }
        .accessibilityActions { TabRowMenu(row: self, spoken: true) }
        .focusable(interactions: .activate)
        .onKeyPress(keys: [.return, .space]) { _ in
            select()
            return .handled
        }
        // ⌘-click stages this tab for a split; ⇧-click extends the range; a plain
        // click selects it (and clears any staging)
        .overlay {
            if multiSelected {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(accent.opacity(0.85), lineWidth: 1.5)
                    .allowsHitTesting(false)
            }
        }
        .onTapGesture {
            let flags = NSEvent.modifierFlags
            if flags.contains(.command) {
                tabManager.toggleSelection(tab)
            } else if flags.contains(.shift) {
                tabManager.extendSelection(to: tab)
            } else if isSelected && !dragInProgress && !isEditing {
                // clicking the tab you're already on renames it in place —
                // no menu, no dialog. Finder's rename gesture, on a tab
                draftName = tab.displayTitle
                isEditing = true
            } else {
                select()
            }
        }
        // a tab you've navigated away from is no longer the one you were naming
        .onChange(of: isSelected) { _, selected in
            if !selected { isEditing = false }
        }
        // a name that changed by itself: point out that it's yours to change.
        // keyed off the stored *name*, not the displayed text — a page
        // retitling itself mid-load is not a rename
        .onChange(of: TabNameStore.shared.name(for: tab.url ?? tab.pendingURL) ?? "") { old, new in
            guard isSelected, !isEditing, !old.isEmpty, old != new else { return }
            hintTask?.cancel()
            hintTask = Task { @MainActor in
                // wait for the dust to settle, then show it for two seconds
                try? await Task.sleep(for: .seconds(RenamingTitle.duration))
                guard !Task.isCancelled else { return }
                justRenamed = true
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                justRenamed = false
            }
        }
        .onDisappear {
            hintTask?.cancel()
            justRenamed = false
        }
        .onHover { isHovering = $0 }
        .onDisappear { stopFlagsMonitor() }
        .contextMenu { TabRowMenu(row: self) }
    }

    /// picking a tab is a decision: it also dismisses the command bar
    private func select() {
        tabManager.clearSelection()
        tabManager.selectedTabID = tab.id
        tabManager.isCommandBarVisible = false
    }

    /// true when this row is part of a multi-selection worth acting on as one
    private var isMultiSelected: Bool {
        tabManager.selection.count > 1 && tabManager.selection.contains(tab.id)
    }

    /// the context menu, which VoiceOver also offers as actions. several selected
    /// tabs get the same verbs applied to all of them: the single-tab items would
    /// be a lie, as you right-clicked five tabs, not one
    fileprivate var menuEntries: [MenuEntry] { isMultiSelected ? bulkMenuEntries : singleTabMenuEntries }

    private var bulkMenuEntries: [MenuEntry] {
        let chosen = tabManager.selectedTabs
        let count = chosen.count
        let allPinned = chosen.allSatisfy(\.isPinned)
        let allMuted = chosen.allSatisfy(\.isMuted)
        var entries: [MenuEntry] = [
            MenuEntry(title: "\(count) tabs selected", kind: .header),
            .button("New Folder with \(count) Tabs", "folder.badge.plus") { tabManager.newFolder(with: chosen) },
            .button(allPinned ? "Unpin \(count) Tabs" : "Pin \(count) Tabs", allPinned ? "pin.slash" : "pin") {
                tabManager.setPinnedForSelection(!allPinned)
            },
            .button(
                allMuted ? "Unmute \(count) Tabs" : "Mute \(count) Tabs",
                allMuted ? "speaker.wave.2" : "speaker.slash"
            ) { tabManager.setMutedForSelection(!allMuted) },
            .button("Put \(count) Tabs to Sleep", "moon.zzz") { tabManager.hibernateSelection() },
        ]
        if tabManager.kind == .main, tabManager.spaces.count > 1 {
            entries.append(MenuEntry(
                title: "Move \(count) Tabs to Space", systemImage: "arrow.right.square",
                kind: .submenu(
                    otherSpaces { tabManager.moveSelection(to: $0) }, spokenPrefix: "Move \(count) Tabs to")))
        }
        entries += [.divider] + splitMenuEntries + [.divider]
        entries.append(.button("Close \(count) Tabs", "xmark") { tabManager.closeSelection() })
        return entries
    }

    private var singleTabMenuEntries: [MenuEntry] {
        let isIncognito = tabManager.kind == .incognito
        var entries: [MenuEntry] = []
        if !isIncognito {
            entries.append(.button("Add to Favourites", "star") { tabManager.toggleEssential(tab) })
        }
        entries.append(
            .button(tab.isPinned ? "Unpin Tab" : "Pin Tab", tab.isPinned ? "pin.slash" : "pin") {
                tabManager.togglePin(tab)
            })
        if tab.isOffPinnedURL, let here = tab.url {
            entries.append(.button("Make This the Pinned Page", "pin.circle") {
                tab.pinnedURL = here
                tabManager.scheduleSave()
            })
        }
        entries.append(
            .button(tab.isMuted ? "Unmute Tab" : "Mute Tab", tab.isMuted ? "speaker.wave.2" : "speaker.slash") {
                tab.toggleMuted()
            })
        if tab.isCapturing {
            entries.append(.button("Stop Camera and Microphone", "video.slash") { tab.stopCapture() })
        }
        entries += [
            .divider,
            .button("Copy Link", "link") { tab.copyLink() },
            .button("Duplicate Tab", "plus.square.on.square") { tabManager.duplicateTab(tab) },
        ]
        if tab.pendingURL == nil {
            entries.append(.button("Reload Tab", "arrow.clockwise") { tab.reload() })
        }
        entries.append(
            .button(
                tab.keepsLoaded ? "Stop Keeping Loaded" : "Keep Loaded", tab.keepsLoaded ? "lock.open" : "lock"
            ) {
                tab.keepsLoaded.toggle()
                tabManager.scheduleSave()
            })
        if !isIncognito, tabManager.spaces.count > 1 {
            entries.append(MenuEntry(
                title: "Move to Space", systemImage: "arrow.right.square",
                kind: .submenu(otherSpaces { tabManager.moveTab(tab, toSpace: $0) }, spokenPrefix: "Move to")))
        }
        entries.append(.divider)
        // a name is remembered on disk, so incognito tabs keep the page's own
        if !isIncognito {
            entries.append(.button("Rename Tab…", "pencil") { tabManager.renamingTab = tab })
        }
        // only offered when there's something to revert *to* — a tab showing
        // its own page title has nothing to put back
        if TabNameStore.shared.name(for: tab.url ?? tab.pendingURL) != nil {
            entries.append(.button("Use Page Title", "arrow.uturn.backward") { tabManager.usePageTitle(for: tab) })
        }
        entries += [.divider] + splitMenuEntries + [.divider]
        if tab.isPinned, tab.pendingURL == nil {
            entries.append(.button("Close and Keep Pinned", "minus") { tabManager.requestClose(tab, keepingPin: true) })
        }
        entries.append(.button(tab.isPinned ? "Archive Pinned Tab" : "Close Tab", "xmark") { tabManager.requestClose(tab) })
        if !tab.isPinned {
            entries += [
                .button("Close Tabs Below", "arrow.down.to.line") {
                    tabManager.closeTodayTabs(besides: tab, onlyBelow: true)
                },
                .button("Close Other Tabs", "xmark.square") {
                    tabManager.closeTodayTabs(besides: tab, onlyBelow: false)
                },
            ]
        }
        return entries
    }

    /// every space but the current one, each moving the tab(s) there
    private func otherSpaces(_ move: @escaping (Space) -> Void) -> [MenuEntry] {
        tabManager.spaces.filter { $0.id != tabManager.selectedSpaceID }.map { space in
            .button(space.name) { move(space) }
        }
    }

    /// split-view actions, contextual to whether this tab is already a pane, a
    /// split is currently shown, or there's a focused tab to split alongside
    private var splitMenuEntries: [MenuEntry] {
        let space = tabManager.currentSpace
        if tabManager.selection.count >= SplitGroup.minPanes, tabManager.selection.contains(tab.id) {
            return [
                .button("Open \(tabManager.selection.count) Tabs in Split View", "rectangle.split.2x1") {
                    tabManager.createSplitFromSelection()
                }
            ]
        } else if let group = space.splitGroup(containing: tab.id) {
            return [
                .button("Remove from Split", "rectangle.split.2x1.slash") { tabManager.removeFromSplit(tab) },
                .button("Unsplit", "rectangle") { tabManager.dissolveSplit(group) },
            ]
        } else if let group = tabManager.displayedSplitGroup, group.tabIDs.count < SplitGroup.maxPanes {
            return [.button("Add to Split View", "plus.rectangle") { tabManager.addToSplit(group, tab: tab) }]
        } else if let focused = tabManager.selectedTab, focused.id != tab.id,
            !focused.isEssential, space.tabs.contains(where: { $0.id == focused.id })
        {
            return [
                .button("Open in Split View", "rectangle.split.2x1") {
                    tabManager.createSplit([focused, tab], anchor: focused)
                }
            ]
        }
        return []
    }

    /// the ordinary row: favicon, title and accessory under one full-width highlight
    private var plainRow: some View {
        HStack(spacing: 8) {
            faviconView

            // the name, and — on the tab you're already on — the hint that says
            // what clicking it again does. the hint slides up from under the
            // name exactly as the pinned row's "Back to pinned URL" does
            VStack(alignment: .leading, spacing: 1) {
                titleText
                if showsRenameHint {
                    Text("Click to rename")
                        .font(.system(size: 10))
                        .foregroundStyle(ink.opacity(0.3))
                        .lineLimit(1)
                        .transition(Motion.slide(.bottom))
                }
            }
            .animation(Motion.pop, value: showsRenameHint)
            .frame(maxWidth: .infinity, alignment: .leading)
            // keep 12pt between text end and whatever is to its right
            // (accessory when shown, row edge when not)
            .padding(.trailing, showsHover ? 0 : 3)

            accessory(visible: showsHover)
        }
        .padding(.leading, metrics.rowLeadingPadding)
        .padding(.trailing, metrics.rowTrailingPadding)  // frames the ✕ box
        // a fixed height rather than padding around the content: the hint makes
        // the column taller while it's showing, and the row must not grow with
        // it (the same reason the off-pinned row is a fixed height)
        .frame(height: metrics.rowHeight)
        .background(RowHighlight(opacity: highlightOpacity, isSelected: isSelected))
        // hover, selection and multi-select all land in one number, so one
        // animation covers them; the split row already eases its own
        .animation(Motion.hover, value: highlightOpacity)
    }

    /// an off-pinned row: separate hover highlights for the favicon square and the
    /// text, one continuous highlight once focused. the text's leading inset
    /// mirrors the close button's gap to the row's right edge
    private var splitRow: some View {
        HStack(spacing: 0) {
            faviconView
                .frame(width: metrics.rowHeight, height: metrics.rowHeight)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        // shows on hover whether or not the tab is focused; when
                        // focused it layers over the full-width highlight, reading
                        // as extra ink on the favicon
                        .fill(ink.opacity(iconHovering && !dragInProgress ? 0.09 : 0)))
                .animation(Motion.hover, value: iconHovering)
                .contentShape(Rectangle())
                .onHover { setIconHover($0) }
                .onTapGesture {
                    // cmd forks the current page into a new normal tab; a plain tap
                    // returns the pinned tab to its anchor
                    if NSEvent.modifierFlags.contains(.command) {
                        tabManager.separateFromPinned(tab)
                    } else {
                        tabManager.returnToPinnedURL(tab)
                    }
                }

            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    titleText
                    if iconHovering && !dragInProgress {
                        // hint sliding up into the highlight while the favicon is
                        // hovered; cmd swaps it to describe the fork action
                        Text(cmdHeld ? "Separate from pinned tab" : "Back to pinned URL")
                            .font(.system(size: 10))
                            .foregroundStyle(ink.opacity(0.3))
                            .lineLimit(1)
                            .transition(Motion.slide(.bottom))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                accessory(visible: textHovering && !dragInProgress)
            }
            .animation(Motion.pop, value: iconHovering)
            .padding(.leading, metrics.rowTrailingPadding)
            .padding(.trailing, metrics.rowTrailingPadding)
            .frame(height: metrics.rowHeight)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(ink.opacity(!isSelected && textHovering && !dragInProgress ? 0.09 : 0))
                    // reaches 3pt over the favicon square for an 8pt inset without
                    // moving the text; hover keeps the un-extended bounds, so the
                    // favicon wins where the two overlap
                    .padding(.leading, -3))
            .animation(Motion.hover, value: textHovering)
            .contentShape(Rectangle())
            .onHover { textHovering = $0 }
        }
        // focused: a single continuous highlight across the whole row, like a
        // normal tab — sits behind the (now transparent) per-zone highlights
        .background(RowHighlight(opacity: isSelected ? 0.22 : 0, isSelected: isSelected))
        .animation(Motion.hover, value: isSelected)
        // slash centred near the seam (favicon square is rowHeight wide). hovering
        // the favicon always hides it (the hint takes over); a focused tab keeps it
        // even while the text is hovered
        .overlay {
            if !iconHovering && (isSelected || !textHovering) {
                GeometryReader { geo in
                    // a slim capsule leaning less than a glyph "/" would, so it
                    // reads as a divider rather than a slash
                    Capsule()
                        // same dimmed grey as a disabled nav arrow
                        .fill(ink.opacity(0.3))
                        .frame(width: 2.5, height: 16)
                        .rotationEffect(.degrees(10))
                        .position(x: metrics.rowHeight - 2, y: geo.size.height / 2)  // 2pt left of the seam
                }
                .allowsHitTesting(false)
            }
        }
    }

    // non-breaking spaces force character-level truncation
    // ("Hello at Du…", not "Hello at…")
    @ViewBuilder
    private var titleText: some View {
        if isEditing {
            // the row's own name becomes the field, so the text neither moves nor
            // restyles; enter or click-away commits, escape discards
            TextField("Name", text: $draftName)
                .textFieldStyle(.plain)
                .font(.system(size: metrics.fontSize))
                .foregroundStyle(ink)
                .focused($nameFocused)
                .onSubmit { commitInlineRename() }
                .onExitCommand { isEditing = false }
                .onChange(of: nameFocused) { _, focused in
                    if !focused { commitInlineRename() }
                }
                .onAppear {
                    nameFocused = true
                    // the whole name arrives selected, so typing replaces it
                    // (SwiftUI won't do this on programmatic focus; the field
                    // editor is the first responder by the next runloop turn)
                    DispatchQueue.main.async {
                        (NSApp.keyWindow?.firstResponder as? NSTextView)?.selectAll(nil)
                    }
                }
        } else {
            // what you called the tab, else what the model called it, else the
            // page's title; it sparkles when it changes on the same page. no I-beam
            // here: that belongs to the field
            RenamingTitle(
                title: shownTitle,
                // the stored name, not the text on screen: a page retitling
                // itself is not a rename
                renameToken: TabNameStore.shared.name(for: tab.url ?? tab.pendingURL) ?? "",
                identity: (tab.url ?? tab.pendingURL)?.absoluteString ?? "",
                fontSize: metrics.fontSize,
                ink: ink)
        }
    }

    @ViewBuilder
    private var faviconView: some View {
        if let favicon = tab.favicon {
            Image(nsImage: favicon)
                .resizable()
                .scaledToFit()
                .frame(width: 16, height: 16)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        } else {
            Image(systemName: "globe")
                .font(.system(size: 12))
                .foregroundStyle(ink.opacity(0.6))
                .frame(width: 16, height: 16)
        }
    }

    /// what a sighted user reads off the row's own decoration — pin, sound,
    /// sleep — said out loud instead
    private var accessibilityState: String {
        var parts: [String] = []
        if isSelected { parts.append("selected") }
        if tab.isPinned { parts.append("pinned") }
        if let folder { parts.append("in folder \(folder)") }
        if tab.isMuted { parts.append("muted") }
        else if tab.isPlayingMediaContent { parts.append("playing audio") }
        if tab.isHibernated { parts.append("asleep") }
        if tab.isPinned, let unread = tab.unread { parts.append(UnreadBadge.spoken(unread)) }
        if let host = (tab.url ?? tab.pendingURL)?.host() { parts.append(host) }
        return parts.joined(separator: ", ")
    }

    /// track favicon hover, watching the cmd key (so the hint can switch between
    /// "back to pinned URL" and "separate from pinned tab") only while hovering
    private func setIconHover(_ hovering: Bool) {
        iconHovering = hovering
        stopFlagsMonitor()
        guard hovering else { return }
        cmdHeld = NSEvent.modifierFlags.contains(.command)
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            cmdHeld = event.modifierFlags.contains(.command)
            return event
        }
    }

    private func stopFlagsMonitor() {
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        flagsMonitor = nil
        cmdHeld = false
    }

    @ViewBuilder
    private func accessory(visible: Bool) -> some View {
        HStack(spacing: 2) {
            if let agent = tab.agentName {
                Image(systemName: "sparkles")
                    .font(.system(size: 10))
                    .foregroundStyle(ink.opacity(0.6))
                    .frame(height: 16)
                    .tooltip("Used by \(agent)")
            }
            if tab.isCapturing {
                HoverIconButton(
                    tab.usesCamera ? "video.fill" : "mic.fill",
                    boxSize: metrics.closeBoxSize
                ) {
                    tab.stopCapture()
                }
                .frame(height: 16)
                .tooltip(tab.usesCamera
                    ? "Using Your Camera — Click to Stop" : "Using Your Microphone — Click to Stop")
                .transition(.opacity)
            }
            // the speaker rides alongside the ✕ rather than replacing it, so a
            // noisy tab can be muted without losing the close button — and stays
            // put when the row isn't hovered, which is how you *find* the noise
            if showsAudioControl {
                HoverIconButton(
                    tab.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                    boxSize: metrics.closeBoxSize
                ) {
                    tab.toggleMuted()
                }
                .frame(height: 16)
                .tooltip(tab.isMuted ? "Unmute Tab" : "Mute Tab", keys: ["⌘", "⇧", "M"])
                .transition(.opacity)
            }
            // the ✕ takes the badge's place while hovered
            if tab.isPinned, !visible, let unread = tab.unread {
                UnreadBadge(badge: unread)
                    .frame(height: 16)
                    .transition(.opacity)
            }
            if visible {
                // a pinned tab's one slot: "–" while open closes the page and
                // keeps the pin; once dormant "✕" archives it. never both at once
                let keepsPin = tab.isPinned && tab.pendingURL == nil
                // one button for both, so the – can turn into the ✕ in place
                HoverIconButton(boxSize: metrics.closeBoxSize) {
                    tabManager.requestClose(tab, keepingPin: keepsPin)
                } icon: {
                    MinusCrossGlyph(isCross: !keepsPin)
                }
                .frame(height: 16)  // keep the row height stable on hover
                .tooltip(
                    keepsPin ? "Close and Keep Pinned"
                        : tab.isPinned ? "Archive Pinned Tab" : "Close Tab",
                    keys: tab.isPinned && !keepsPin ? [] : ["⌘", "W"])
            }
        }
        .animation(Motion.hover, value: showsAudioControl)
        .animation(Motion.hover, value: tab.isCapturing)
        .animation(Motion.hover, value: tab.isPinned ? tab.unread : nil)
        // the ✕ takes width from the title as it appears; easing it means the
        // name reflows rather than snapping to a new truncation mid-hover
        .animation(Motion.hover, value: visible)
    }

    /// a tab gets the speaker while it's playing, and keeps it while muted (else
    /// muting would hide the only way to undo it)
    private var showsAudioControl: Bool { tab.isPlayingMediaContent || tab.isMuted }
}

/// a pinned tab's or favourite's unread mark: a count, or a dot for a bare flag
struct UnreadBadge: View {
    @Environment(\.chromeInk) private var ink
    let badge: AppBadge

    var body: some View {
        switch badge {
        case .flag:
            Circle()
                .fill(ink.opacity(0.55))
                .frame(width: 6, height: 6)
        case .count(let count):
            Text(count > 99 ? "99+" : "\(count)")
                .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(ink.opacity(0.75))
                .padding(.horizontal, 4)
                .frame(minWidth: 15, minHeight: 15)
                .background(Capsule().fill(ink.opacity(0.13)))
        }
    }

    static func spoken(_ badge: AppBadge) -> String {
        switch badge {
        case .flag: "unread"
        case .count(let count): "\(count) unread"
        }
    }
}

/// the floating ghost for a whole-split drag: every pane as a merged row of
/// segment pills, matching the sidebar block
private struct SplitDragGhost: View {
    let members: [BrowserTab]
    let gap: CGFloat
    let rowSize: CGSize

    var body: some View {
        HStack(spacing: gap) {
            ForEach(members) { tab in
                SplitSegmentCell(tab: tab)
            }
        }
        .frame(width: rowSize.width, height: rowSize.height)
        .opacity(0.6)
    }
}

/// the floating drag ghost, morphing between the zones: over the favourites a
/// centred favicon, over the tabs the favicon at the leading edge with the name
private struct DragGhost: View {
    @Environment(\.sidebarMetrics) private var metrics
    @Environment(\.chromeInk) private var ink
    let tab: BrowserTab
    let overEssentials: Bool
    let tileSize: CGSize
    let rowSize: CGSize

    private var size: CGSize { overEssentials ? tileSize : rowSize }
    /// leading offset that lines the name up after the favicon in row mode
    private var titleInset: CGFloat { metrics.rowLeadingPadding + 16 + 8 }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(ink.opacity(0.14))

            // the name — leading-aligned after the favicon, faded out on a tile.
            // its own quicker fade so it's gone before the favicon slides over
            // its spot, rather than the two stacking mid-morph
            HStack(spacing: 0) {
                Text(tab.displayTitle)
                    .font(.system(size: metrics.fontSize))
                    .lineLimit(1)
                    .foregroundStyle(ink)
                Spacer(minLength: 0)
            }
            .padding(.leading, titleInset)
            .padding(.trailing, 8)
            .opacity(overEssentials ? 0 : 1)
            .animation(.easeOut(duration: 0.13), value: overEssentials)

            // the favicon — slides from the leading edge (row) to centre (tile)
            favicon
                .padding(.leading, overEssentials ? 0 : metrics.rowLeadingPadding)
                .frame(maxWidth: .infinity, alignment: overEssentials ? .center : .leading)
        }
        .frame(width: size.width, height: size.height)
        .opacity(0.6)
        .animation(Motion.morph, value: overEssentials)
    }

    @ViewBuilder
    private var favicon: some View {
        if let f = tab.favicon {
            Image(nsImage: f)
                .resizable()
                .scaledToFit()
                .frame(width: 16, height: 16)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        } else {
            Image(systemName: "globe")
                .font(.system(size: 12))
                .foregroundStyle(ink.opacity(0.6))
                .frame(width: 16, height: 16)
        }
    }
}

/// the backdrop's blended ink and accent, for chrome over the window backdrop.
/// a modifier of its own because it reads the carousel position: inline, the
/// sidebar's whole body would re-run on every frame of a swipe
private struct BlendedInk: ViewModifier {
    @Environment(TabManager.self) private var tabManager

    func body(content: Content) -> some View {
        content
            .environment(\.chromeInk, tabManager.blendedInk)
            .environment(\.spaceAccent, tabManager.blendedAccent)
    }
}

/// a tab row's context menu, or the same entries as accessibility actions. a
/// view of its own so it is handed a value to resolve when asked, instead of the
/// entries being built on every one of the row's body passes
private struct TabRowMenu: View {
    let row: TabRow
    var spoken = false

    var body: some View {
        if spoken {
            MenuEntryActions(entries: row.menuEntries)
        } else {
            MenuEntriesView(entries: row.menuEntries)
        }
    }
}

/// a mutable spot to stash the pointer's last location. deliberately a plain
/// class and not `@Observable`: the point is to be written at pointer rate
/// without invalidating anything that reads it
private final class LastPoint {
    var value: CGPoint?
}

private final class FrameBox {
    var value: CGRect = .zero
}

private final class SidebarGeometry {
    var rowFrames: [SidebarRowFrame] = []
    var essentialsFrame: CGRect = .zero
    var tabContentRect: CGRect = .zero
    var spaceHeaderRect: CGRect = .zero
    var newTabBoundaryY: CGFloat?
}

/// a parked panel's header: the space header's look without its hover, rename
/// or edit machinery
private struct ParkedSpaceHeader: View {
    let space: Space
    @Environment(\.sidebarMetrics) private var metrics

    var body: some View {
        HStack(spacing: 8) {
            SpaceGlyph(icon: space.icon, size: 13)
                .frame(width: 16, height: 16)
                .foregroundStyle(space.appearance.accent)
            Text(space.name)
                .font(.system(size: metrics.fontSize, weight: .bold))
                .foregroundStyle(space.appearance.chromeInk.opacity(0.7))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .frame(height: 22)
        .padding(.leading, metrics.rowLeadingPadding)
        .padding(.trailing, metrics.rowTrailingPadding)
        .padding(.vertical, metrics.headerVPadding)  // matches SpaceHeader's row
    }
}

extension EnvironmentValues {
    /// false inside a parked neighbour's panel, whose rows must not report frames
    @Entry var isLivePanel = true
}

/// content that exists only in the live panel, so a parked one feeds nothing
/// into the shared drag geometry
private struct LivePanelOnly<Content: View>: View {
    @Environment(\.isLivePanel) private var live
    @ViewBuilder let content: Content

    var body: some View {
        if live { content }
    }
}

/// the filmstrip's scroll: the only pager piece that reads the per-frame
/// position, so a swipe re-runs this modifier and not the panels it moves
private struct PagerOffset: ViewModifier {
    @Environment(TabManager.self) private var tabManager
    let pitch: CGFloat

    func body(content: Content) -> some View {
        content.offset(x: -tabManager.spacePagePosition * pitch)
    }
}

/// a pager slot. a parked panel is skipped when the pager re-runs for a switch
/// it had no part in, still updating through its own body's observation; the
/// live panel always re-runs with the sidebar
private struct PanelSlot<Content: View>: View, Equatable {
    let space: Space
    let live: Bool
    @ViewBuilder let content: () -> Content

    var body: some View { content() }

    static func == (lhs: Self, rhs: Self) -> Bool {
        !lhs.live && !rhs.live && lhs.space === rhs.space
    }
}

/// builds its content in its own body, so whatever that content reads
/// invalidates this leaf rather than the view that declared it
private struct Live<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View { content() }
}

/// where an incognito window's profile button would be: it says what the window
/// is, and closing it is the only thing left to do
private struct IncognitoBadge: View {
    @Environment(\.chromeInk) private var ink

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "eyeglasses")
                .font(.system(size: 13, weight: .semibold))
            Text("Incognito")
                .font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(ink.opacity(0.7))
        .padding(.leading, 6)
        .frame(height: 28)
        .tooltip("Nothing from this window is saved. Closing it erases its cookies.")
    }
}
