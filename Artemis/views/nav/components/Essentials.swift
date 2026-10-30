import SwiftUI

/// the global favourites ("essentials") grid at the top of the sidebar — a
/// responsive row of favicon tiles shared across every space. tiles grow to
/// fill the available width.
///
/// rows are balanced: one favourite spans the full width, two split it in half,
/// three in thirds, and so on. a tile never shrinks below `essentialTileMin`
/// (two tiles inline at the narrowest sidebar), and a row holds at most five.
/// when the count won't fit on one line the favourites split into the fewest
/// rows possible, then spread evenly across them — five in a sidebar that only
/// fits four become a 3+2 rather than 4+1, so every tile keeps some room.
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

    /// the favourites actually laid out (the dragged one removed)
    private var items: [BrowserTab] {
        tabManager.essentials.filter { $0.id != hiddenID }
    }

    /// where the reflow gap sits in the rendered sequence, if shown at all
    private var phantom: Int? {
        if let previewIndex { return max(0, min(previewIndex, items.count)) }
        if items.isEmpty && dragActive { return 0 }
        return nil
    }

    /// the rendered sequence: the favourites with the empty reflow gap spliced
    /// in. each carries a stable identity (its tab id, or the gap sentinel) so
    /// the layout *moves* tiles to their new spots — sliding with a spring —
    /// rather than fading content between fixed slots as the gap travels
    private var slots: [GridSlot] {
        var s = items.map { GridSlot.tile($0) }
        if let p = phantom { s.insert(.gap, at: min(p, s.count)) }
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
                        // landing in the grid springs up into place; picking one
                        // up cuts straight to the ghost — a zero-duration removal,
                        // so the tile is gone the same frame the ghost appears and
                        // the two highlights never overlap and flash
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.55).combined(with: .opacity),
                            removal: .opacity.animation(.linear(duration: 0))))
                case .gap:
                    Color.clear
                }
            }
        }
        .animation(Motion.pop, value: slotIDs)
        .onPreferenceChange(EssentialFrameKey.self) { frames = $0 }
        .gesture(dragGesture)
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

/// lays the favourites out in balanced rows (1 full-width, 2 half, 3 thirds …),
/// never below `minTileWidth`, at most `maxPerRow` per row, splitting into the
/// fewest rows and spreading evenly across them. one container for every tile,
/// so a slot order change animates each tile gliding to its new spot — across
/// rows included — instead of cross-fading between fixed positions
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
            // resting tiles are glass at half strength, so the row reads as a
            // soft shelf rather than three buttons
            .background(
                Color.clear
                    .chromeGlass(in: RoundedRectangle(cornerRadius: 10, style: .continuous), lit: isSelected || showsHover)
                    .opacity(isSelected || showsHover ? 1 : 0.5))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(accent.opacity(isSelected ? 0.9 : 0), lineWidth: 1.5)
            )
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
            .onTapGesture {
                tabManager.selectedTabID = tab.id
                tabManager.isCommandBarVisible = false
            }
            .onHover { isHovering = $0 }
            .tooltip(tab.displayTitle)
            .contextMenu {
                Button {
                    tabManager.toggleEssential(tab)
                } label: {
                    Label("Move to Tabs", systemImage: "pin.slash")
                        .labelStyle(.titleAndIcon)
                }
                Button(role: .destructive) {
                    tabManager.removeEssential(tab)
                } label: {
                    Label("Remove from Favourites", systemImage: "star.slash")
                        .labelStyle(.titleAndIcon)
                }
            }
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
