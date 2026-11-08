// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import AppKit
import SwiftUI

/// the one hover card on screen. the pointer resting on a pinned tab or favourite for `dwell`
/// reads its live source and shows the card in a panel beside the sidebar, standing in for the
/// tooltip, until the pointer has left both the row and the card for `grace`
@MainActor
final class TabPreviews {
    static let shared = TabPreviews()
    private static let dwell: Duration = .milliseconds(600)
    /// a source fetched this many seconds ago is shown again without a fetch
    static let maxAge: TimeInterval = 60
    private static let grace: Duration = .milliseconds(250)
    /// how long a fetch runs before the card shows it is loading
    private static let patience: Duration = .milliseconds(300)
    private static let gap: CGFloat = 8

    /// screen points, y up
    struct Place {
        var row: CGRect
        /// the sidebar's trailing edge, which the card hangs off
        var edge: CGFloat
    }

    /// the tab whose card is on screen, and what it shows
    private(set) var shown: (tab: BrowserTab.ID, card: TabPreviewCard)?
    /// how a dwell reads its source, given the age it may reuse; the suite swaps in its own
    var load: @MainActor (LiveSource, Space, TimeInterval) async -> LiveOutcome = { await $0.load(in: $1, maxAge: $2) }

    private struct Attempt: Equatable {
        let id = UUID()
        let tab: BrowserTab.ID
    }
    /// the latest hover whose card may still show; a result for any other is stale
    private var live: Attempt?
    private var dwelling: Task<Void, Never>?
    private var hovered: BrowserTab.ID?
    private var watch: Task<Void, Never>?
    /// where the pointer keeps the card up: the row, the card, and the strip between them
    private var zone: [CGRect] = []
    private var panel: NSPanel?
    private var host: NSHostingView<TabPreviewCardView>?
    private weak var quietTooltips: TooltipState?
    /// the window whose floating sidebar the card holds open, given back on dismiss
    private weak var heldSidebar: TabManager?

    /// what a card over `tab` reads, and the space it reads for; nil for a tab that gets no card:
    /// not pinned or a favourite, the one on screen, private, or in a refused space
    static func source(for tab: BrowserTab, in manager: TabManager) -> (source: LiveSource, space: Space)? {
        guard TabPreviewCard.isEnabled, manager.kind == .main, tab.isPinned || tab.isEssential, !tab.isPrivate,
            manager.selectedTab?.id != tab.id,
            let space = tab.isEssential ? manager.currentSpace : manager.space(of: tab),
            // a live folder's item stands for its row: a card's line would load another page into it
            !space.folders.contains(where: { $0.live?.items[tab.id] != nil }),
            LiveSource.admittedProfile(of: space) != nil, let url = tab.url ?? tab.pendingURL,
            let source = LiveSource.preview(for: url, tab: tab.id), TabPreviewCard.Kind(source)?.isOn == true
        else { return nil }
        return (source, space)
    }

    /// the pointer came onto `tab`'s row; `place` is read when the card shows
    func enter(_ tab: BrowserTab, in manager: TabManager, at place: @escaping () -> Place) {
        hovered = tab.id
        if shown?.tab == tab.id, live?.tab == tab.id { return }
        dwelling?.cancel()
        live = nil
        guard shown?.tab != tab.id, case let (source, space)? = Self.source(for: tab, in: manager) else { return }
        let attempt = Attempt(tab: tab.id)
        live = attempt
        dwelling = Task {
            try? await Task.sleep(for: Self.dwell)
            guard !Task.isCancelled, live == attempt, Self.source(for: tab, in: manager) != nil else { return }
            let loading = Task {
                try? await Task.sleep(for: Self.patience)
                guard !Task.isCancelled, live == attempt, let card = TabPreviewCard(source, nil) else { return }
                present(card, for: tab, in: manager, at: place())
            }
            let outcome = await load(source, space, Self.maxAge)
            loading.cancel()
            guard live == attempt else { return }
            if let card = TabPreviewCard(source, outcome) {
                present(card, for: tab, in: manager, at: place())
            } else {
                dismiss(tab.id)
            }
        }
    }

    /// the pointer left `tab`'s row: a pending card is dropped, a shown one waits out the grace
    func leave(_ tab: BrowserTab.ID) {
        if hovered == tab { hovered = nil }
        guard live?.tab == tab, shown?.tab != tab else { return }
        live = nil
        dwelling?.cancel()
    }

    /// takes down the card, or only `tab`'s
    func dismiss(_ tab: BrowserTab.ID? = nil) {
        guard let shown, tab == nil || tab == shown.tab else { return }
        if live?.tab == shown.tab {
            live = nil
            dwelling?.cancel()
        }
        self.shown = nil
        watch?.cancel()
        watch = nil
        if let panel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        quietTooltips?.isSuppressed = false
        quietTooltips = nil
        heldSidebar?.isSidebarPopoverOpen = false
        heldSidebar = nil
    }

    private func present(_ card: TabPreviewCard, for tab: BrowserTab, in manager: TabManager, at place: Place) {
        guard Self.source(for: tab, in: manager) != nil, let window = BrowserWindows.shared.window(of: manager),
            window.isVisible
        else { return dismiss(tab.id) }
        let view = TabPreviewCardView(card: card) { [weak self, weak tab, weak manager] link in
            guard let self, let tab, let manager else { return }
            open(link, in: tab, manager: manager)
        }
        let panel = panel ?? makePanel()
        self.panel = panel
        let host = host ?? NSHostingView(rootView: view)
        self.host = host
        host.rootView = view
        if panel.contentView !== host { panel.contentView = host }
        host.layout()
        let size = host.fittingSize
        let middle = CGPoint(x: place.row.midX, y: place.row.midY)
        let screen = (NSScreen.screens.first { $0.frame.contains(middle) } ?? window.screen)?.visibleFrame
        var frame = CGRect(
            x: place.edge + Self.gap, y: place.row.midY - size.height / 2, width: size.width, height: size.height)
        // centred on the row like a folder's peek, kept inside the window, then on screen
        for bounds in [window.frame, screen].compactMap(\.self) {
            frame.origin.y = max(bounds.minY, min(frame.minY, bounds.maxY - size.height))
        }
        if let screen { frame.origin.x = max(screen.minX, min(frame.minX, screen.maxX - size.width)) }
        let appearing = shown == nil || !panel.isVisible
        shown = (tab.id, card)
        panel.setFrame(frame, display: true)
        panel.invalidateShadow()
        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
        }
        if appearing {
            panel.alphaValue = 0
            panel.orderFront(nil)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Motion.reduceMotion ? 0.08 : 0.14
                panel.animator().alphaValue = 1
            }
        }
        zone = [
            place.row, frame,
            CGRect(x: place.row.maxX, y: frame.minY, width: max(0, frame.minX - place.row.maxX), height: frame.height),
        ]
        if quietTooltips !== manager.tooltipState {
            quietTooltips?.isSuppressed = false
            quietTooltips = manager.tooltipState
            manager.tooltipState.isSuppressed = true
        }
        if heldSidebar !== manager {
            heldSidebar?.isSidebarPopoverOpen = false
            heldSidebar = nil
            if manager.isSidebarCollapsed, !manager.isSidebarPopoverOpen {
                manager.isSidebarPopoverOpen = true
                heldSidebar = manager
            }
        }
        watchPointer()
    }

    /// the card goes once the pointer has been off its zone, and off its row, for `grace`
    private func watchPointer() {
        guard watch == nil else { return }
        watch = Task {
            var away: ContinuousClock.Instant?
            while !Task.isCancelled, let shown {
                // hiding the app or minimising the window hides the panel and ends no hover
                guard panel?.isVisible == true, panel?.parent?.isVisible == true else { return dismiss() }
                let mouse = NSEvent.mouseLocation
                if hovered == shown.tab || zone.contains(where: { $0.insetBy(dx: -4, dy: -4).contains(mouse) }) {
                    away = nil
                } else if let away, ContinuousClock.now - away >= Self.grace {
                    return dismiss()
                } else if away == nil {
                    away = .now
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    /// a pending tab wakes first, so its own page doesn't load over `link`
    private func open(_ link: URL, in tab: BrowserTab, manager: TabManager) {
        dismiss()
        let current = tab.url ?? tab.pendingURL
        tab.activateIfNeeded()
        // an Outlook line clicks its row in the page; a row not drawn loads the link
        if let conversation = OutlookPage.conversation(in: link) {
            Task { if await !OutlookPage.select(conversation, in: tab) { tab.load(link) } }
        } else if current.map(BrowserTab.normalizedLocation) != BrowserTab.normalizedLocation(link) {
            tab.load(link)
        }
        manager.clearSelection()
        manager.selectedTabID = tab.id
        manager.isCommandBarVisible = false
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.transient, .fullScreenAuxiliary]
        return panel
    }
}

/// hands a pinned row's or favourite's hover to `TabPreviews`, with where it sits on screen
struct TabPreviewHover: ViewModifier {
    @Environment(TabManager.self) private var manager
    @Environment(SidebarDragState.self) private var drag: SidebarDragState?
    let tab: BrowserTab
    /// written on every move, read when a card shows: a box, so the writes redraw nothing
    @State private var spot = Spot()

    @ViewBuilder
    func body(content: Content) -> some View {
        if tab.isPinned || tab.isEssential {
            content
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { spot.frame = $0 }
                .onContinuousHover(coordinateSpace: .global) { phase in
                    switch phase {
                    case .active(let point):
                        let mouse = NSEvent.mouseLocation
                        spot.origin = CGPoint(x: mouse.x - point.x, y: mouse.y + point.y)
                        guard !spot.hovering else { return }
                        spot.hovering = true
                        guard drag?.isDragging != true else { return }
                        TabPreviews.shared.enter(tab, in: manager) { [spot, drag] in
                            spot.place(sidebar: drag?.sidebarFrame)
                        }
                    case .ended:
                        spot.hovering = false
                        TabPreviews.shared.leave(tab.id)
                    }
                }
                .onChange(of: manager.selectedTab?.id == tab.id || drag?.isDragging == true) { _, gone in
                    if gone { drop() }
                }
                .onChange(of: manager.currentSpace.id) { drop() }
                .onDisappear {
                    spot.hovering = false
                    drop()
                }
        } else {
            content
        }
    }

    private func drop() {
        TabPreviews.shared.leave(tab.id)
        TabPreviews.shared.dismiss(tab.id)
    }

    private final class Spot {
        /// in the hosting view's global space, y down
        var frame: CGRect = .zero
        /// where that space's origin sits on screen
        var origin: CGPoint = .zero
        var hovering = false

        func place(sidebar: CGRect?) -> TabPreviews.Place {
            TabPreviews.Place(
                row: CGRect(x: frame.minX + origin.x, y: origin.y - frame.maxY, width: frame.width, height: frame.height),
                edge: max(frame.maxX, sidebar?.maxX ?? 0) + origin.x)
        }
    }
}

/// the card itself: a heading, then up to six lines or one plain message
struct TabPreviewCardView: View {
    let card: TabPreviewCard
    let open: (URL) -> Void

    private static let width: CGFloat = 300

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(card.heading)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                if let count = card.count {
                    Text(count)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if let compose = card.compose {
                    Button {
                        open(compose)
                    } label: {
                        Label("Compose", systemImage: "square.and.pencil")
                            .font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.primary.opacity(0.08)))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 4)
            .padding(.bottom, 2)
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isHeader)
            if let message = card.message {
                Text(message)
                    .font(.system(size: card.isAllClear ? 14 : 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(card.isAllClear ? .center : .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: card.isAllClear ? .center : .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, card.isAllClear ? 10 : 6)
            }
            ForEach(card.lines) { line in
                TabPreviewLine(line: line) { open(line.link) }
            }
        }
        .padding(6)
        .frame(width: Self.width, alignment: .leading)
        .background(VisualEffectView(material: .popover, blending: .behindWindow))
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(card.heading)
    }
}

private struct TabPreviewLine: View {
    let line: TabPreviewCard.Line
    let action: () -> Void
    @State private var isHovering = false

    private var spoken: String {
        [line.title, line.detail, line.date.map { $0.formatted(.relative(presentation: .named)) } ?? ""]
            .filter { !$0.isEmpty }.joined(separator: ", ")
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                if let symbol = line.symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(width: 14)
                }
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(line.title)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        if let date = line.date {
                            Text(TabPreviewCard.age(of: date))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    if !line.detail.isEmpty {
                        Text(line.detail)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(isHovering ? 0.08 : 0)))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(Motion.hover, value: isHovering)
        .accessibilityLabel(spoken)
    }
}
