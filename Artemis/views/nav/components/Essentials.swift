// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import SwiftUI

/// the favourites grid at the top of the sidebar, shared across every space:
/// favicon tiles in balanced rows (see `BalancedTileLayout`)
struct EssentialsGrid: View {
    @Environment(TabManager.self) private var tabManager
    @Environment(\.sidebarMetrics) private var metrics
    @Environment(SidebarDragState.self) private var drag
    @State private var frames: [EssentialFrame] = []

    /// the slot the favourites open a gap at while a drag hovers (nil = none).
    /// the gap is empty — the floating ghost shows what lands there
    var previewIndex: Int?
    /// the favourite being dragged: pulled out of the layout entirely so the
    /// grid closes up and its slot is free for the rest to reflow into
    var hiddenID: BrowserTab.ID?
    /// a drag is active even if not over the grid — lets an empty grid (no
    /// favourites yet) open a slot so the first favourite has somewhere to land
    var dragActive = false

    private static let maxPerRow = 5

    /// the dragged favourite is left out
    private var items: [BrowserTab] {
        tabManager.essentials.filter { $0.id != hiddenID }
    }

    /// where the reflow gap sits in the rendered sequence, if shown at all
    private var phantom: Int? {
        if let previewIndex { return max(0, min(previewIndex, items.count)) }
        if items.isEmpty && dragActive { return 0 }
        return nil
    }

    /// the favourites with the reflow gap spliced in; stable ids make the layout
    /// move tiles as the gap travels rather than cross-fade between fixed slots
    private var slots: [GridSlot] {
        var s = items.map { GridSlot.tile($0) }
        if let p = phantom { s.insert(.gap, at: p) }
        return s
    }

    /// the order signature the reflow animation keys off
    private var slotIDs: [GridSlot.ID] { slots.map(\.id) }

    var body: some View {
        BalancedTileLayout(
            spacing: metrics.tabSpacing,
            tileHeight: metrics.essentialTileHeight,
            minTileWidth: metrics.essentialTileMin,
            maxPerRow: Self.maxPerRow
        ) {
            ForEach(slots) { slot in
                switch slot {
                case .tile(let tab):
                    EssentialTile(tab: tab)
                        // removal takes zero time: the tile must be gone the
                        // frame its ghost appears, or the two highlights flash
                        .transition(.asymmetric(
                            insertion: Motion.grow(from: 0.55),
                            removal: .opacity.animation(.linear(duration: 0))))
                case .gap:
                    Color.clear
                }
            }
        }
        .animation(Motion.pop, value: slotIDs)
        .onPreferenceChange(EssentialFrameKey.self) { frames = $0 }
        .gesture(dragGesture)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Favourites")
    }

    /// pick a favourite up into the shared drag system. the gesture lives on the
    /// grid (not the tile) so the dragged tile can be pulled from the layout
    /// without cancelling the drag. a tap still falls through to tile selection
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named(SidebarDragState.contentSpace))
            .onChanged { value in
                if drag.tab == nil {
                    guard let hit = frames.first(where: { $0.rect.contains(value.startLocation) }),
                        let tab = tabManager.essentials.first(where: { $0.id == hit.id })
                    else { return }
                    let grab = CGSize(
                        width: value.startLocation.x - hit.rect.minX,
                        height: value.startLocation.y - hit.rect.minY)
                    drag.begin(
                        tab, fromEssentials: true, sourceSize: hit.rect.size, at: value.location,
                        grab: grab)
                } else {
                    drag.location = value.location
                }
            }
            .onEnded { value in
                guard drag.isDragging else { return }
                drag.location = value.location
                drag.end()
            }
    }
}

/// a slot in the favourites grid — a real favourite or the empty reflow gap
private enum GridSlot: Identifiable {
    case tile(BrowserTab)
    case gap

    var id: AnyHashable {
        switch self {
        case .tile(let tab): AnyHashable(tab.id)
        case .gap: AnyHashable("essentials-gap")
        }
    }
}

/// balanced rows: the fewest rows that keep tiles at `minTileWidth` or wider and
/// at most `maxPerRow` each, filled evenly (five that fit four a row go 3+2).
/// one container for every tile, so a reorder glides tiles across rows
private struct BalancedTileLayout: Layout {
    var spacing: CGFloat
    var tileHeight: CGFloat
    var minTileWidth: CGFloat
    var maxPerRow: Int

    private func math(width: CGFloat, origin: CGPoint = .zero) -> EssentialsGridMath {
        EssentialsGridMath(
            width: width, origin: origin, spacing: spacing,
            tileHeight: tileHeight, minTileWidth: minTileWidth, maxPerRow: maxPerRow)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.replacingUnspecifiedDimensions(by: CGSize(width: minTileWidth, height: tileHeight)).width
        let rows = math(width: width).rowCounts(subviews.count)
        let height = rows.isEmpty
            ? 0
            : CGFloat(rows.count) * tileHeight + CGFloat(rows.count - 1) * spacing
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let m = math(width: bounds.width, origin: bounds.origin)
        let rows = m.rowCounts(subviews.count)
        var i = 0
        var y = bounds.minY
        for n in rows {
            let tileW = m.tileWidth(perRow: n)
            var x = bounds.minX
            for _ in 0 ..< n {
                subviews[i].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: tileW, height: tileHeight))
                x += tileW + spacing
                i += 1
            }
            y += tileHeight + spacing
        }
    }
}

/// a single favourite: favicon on a rounded tile, accent ring when it's the
/// active tab, drag to reorder / out to the tabs, right-click to remove
private struct EssentialTile: View {
    @Environment(TabManager.self) private var tabManager
    @Environment(\.sidebarMetrics) private var metrics
    @Environment(\.chromeInk) private var ink
    @Environment(SidebarDragState.self) private var drag
    let tab: BrowserTab
    @State private var isHovering = false

    private var isSelected: Bool { tabManager.activeEssentialID == tab.id }
    /// the ring matches the favicon's own colour, falling back to the space
    /// accent until the icon (and its colour) resolves
    private var accent: Color { tab.faviconAccent ?? tabManager.blendedAccent }
    /// hover highlight is suppressed while a drag is in flight, so tiles don't
    /// light up as the ghost passes over them
    private var showsHover: Bool { isHovering && !drag.isDragging }

    var body: some View {
        favicon
            .frame(maxWidth: .infinity)
            .frame(height: metrics.essentialTileHeight)
            .background(
                Color.clear
                    .chromeGlass(in: RoundedRectangle(cornerRadius: 10, style: .continuous), lit: isSelected || showsHover)
                    .opacity(isSelected || showsHover ? 1 : 0.5))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(accent.opacity(isSelected ? 0.9 : 0), lineWidth: 1.5)
            )
            .overlay(alignment: .topTrailing) {
                if let unread = tab.unread {
                    UnreadBadge(badge: unread)
                        .padding(4)
                        .transition(.opacity)
                }
            }
            .animation(Motion.hover, value: tab.unread)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .animation(Motion.hover, value: isHovering)
            .animation(Motion.pop, value: isSelected)
            // report each tile's frame in the shared drag space, so the grid can
            // tell which tile was grabbed and where a drop would slot in
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: EssentialFrameKey.self,
                        value: [EssentialFrame(
                            id: tab.id,
                            rect: proxy.frame(in: .named(SidebarDragState.contentSpace)))])
                }
            }
            .onTapGesture { select() }
            .onHover { isHovering = $0 }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(tab.badgedTitle)
            .accessibilityValue(accessibilityState)
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { select() }
            .accessibilityActions { MenuEntryActions(entries: menuEntries) }
            .focusable(interactions: .activate)
            .onKeyPress(keys: [.return, .space]) { _ in
                select()
                return .handled
            }
            .tooltip(tab.badgedTitle)
            .contextMenu { MenuEntriesView(entries: menuEntries) }
    }

    private var menuEntries: [MenuEntry] {
        [
            .button("Move to Tabs", "pin.slash") { tabManager.toggleEssential(tab) },
            .button("Remove from Favourites", "star.slash", role: .destructive) { tabManager.removeEssential(tab) },
        ]
    }

    private func select() {
        tabManager.selectedTabID = tab.id
        tabManager.isCommandBarVisible = false
    }

    private var accessibilityState: String {
        var parts = ["favourite"]
        if isSelected { parts.append("selected") }
        if let unread = tab.unread { parts.append(UnreadBadge.spoken(unread)) }
        if tab.isMuted { parts.append("muted") }
        else if tab.isPlayingMediaContent { parts.append("playing audio") }
        if let host = (tab.url ?? tab.pendingURL)?.host() { parts.append(host) }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder
    private var favicon: some View {
        if let favicon = tab.favicon {
            Image(nsImage: favicon)
                .resizable()
                .scaledToFit()
                .frame(width: metrics.essentialFaviconSize, height: metrics.essentialFaviconSize)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        } else {
            Image(systemName: "globe")
                .font(.system(size: metrics.essentialFaviconSize - 2))
                .foregroundStyle(ink.opacity(0.6))
                .frame(width: metrics.essentialFaviconSize, height: metrics.essentialFaviconSize)
        }
    }
}
