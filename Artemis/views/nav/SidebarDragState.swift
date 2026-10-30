import SwiftUI

/// shared state for the sidebar's one unified drag system. both tab rows and
/// favourite tiles feed it, so a tab can be dragged up into the favourites grid
/// and a favourite dragged back down into the tabs, with a single floating ghost
/// that morphs between the two shapes as it crosses the boundary.
///
/// the gesture lives on each draggable view but reports into one sidebar-wide
/// coordinate space (`contentSpace`), so the ghost and drop indicators — drawn
/// at the sidebar-content level, not clipped inside the scroll view — line up
/// with both zones.
/// the edge of the content area a dragged tab is hovering, for drag-to-split.
/// the content area sets this live as the cursor moves over it during a sidebar
/// drag; the sidebar's drop commit reads it to tile instead of reorder
enum ContentDropZone: Equatable {
    case left, right, top, bottom
}

@Observable
final class SidebarDragState {
    /// the shared coordinate space the gesture, frames and overlay all use
    static let contentSpace = "sidebarContent"

    /// the item being dragged, or nil at rest
    var tab: BrowserTab?
    /// when dragging a whole split as a unit, the group being moved (`tab` holds a
    /// representative pane for the ghost). nil for ordinary single-tab drags
    var group: SplitGroup?
    /// when dragging a folder, the folder itself — it carries no tab, so every
    /// path that assumes one has to ask for this first
    var folder: TabFolder?
    /// whether it was picked up from the favourites grid (vs the tab list)
    var fromEssentials = false
    /// the cursor in `contentSpace`
    var location: CGPoint = .zero {
        didSet {
            let target = dropTarget(at: location)
            if target != spaceDropTarget { spaceDropTarget = target }
        }
    }
    /// the cursor's offset from the dragged item's top-left corner at pickup, so
    /// the ghost keeps the grab alignment (grab the left edge → ghost's left edge
    /// stays under the cursor) instead of snapping its centre to the cursor
    var grabOffset: CGSize = .zero
    /// the source tile/row size, so the ghost can start at the right dimensions
    var sourceSize: CGSize = .zero
    /// bumped on release; the sidebar observes it to commit the drop
    var dropTick = 0
    /// the content-area edge the cursor is over (drag-to-split), or nil when the
    /// cursor is in the sidebar / not eligible to split
    var contentDropZone: ContentDropZone?
    /// the sidebar's window-space frame (pinned or floating overlay), so the
    /// content drop-to-split can ignore drags that are still over the sidebar —
    /// the overlay sidebar floats above the web card, so geometry alone isn't enough
    @ObservationIgnored var sidebarFrame: CGRect = .zero

    /// frames of the space icons at the sidebar's foot, in `contentSpace`.
    /// published while the switcher is on screen so a tab dragged over one can be
    /// dropped *into that space* — the cross-space move Arc never shipped
    @ObservationIgnored var spaceDropFrames: [UUID: CGRect] = [:]

    var isDragging: Bool { tab != nil || folder != nil }

    /// the space icon under the cursor mid-drag, or nil. Stored, so the icons
    /// redraw when the cursor crosses onto or off one, not on every move
    private(set) var spaceDropTarget: UUID?

    /// favourites are global, so they're never a candidate for moving into a
    /// space; nor is a folder, which would have to take its whole subtree across
    private func dropTarget(at point: CGPoint) -> UUID? {
        guard let tab, !tab.isEssential, group == nil, folder == nil else { return nil }
        return spaceDropFrames.first { $0.value.contains(point) }?.key
    }

    func begin(
        _ tab: BrowserTab, fromEssentials: Bool, sourceSize: CGSize, at p: CGPoint,
        grab: CGSize = .zero
    ) {
        self.tab = tab
        group = nil
        folder = nil
        self.fromEssentials = fromEssentials
        self.sourceSize = sourceSize
        grabOffset = grab
        location = p
    }

    /// begin dragging a whole split as a unit (move it, don't break it apart)
    func beginGroup(
        _ group: SplitGroup, representative: BrowserTab, sourceSize: CGSize, at p: CGPoint,
        grab: CGSize = .zero
    ) {
        self.group = group
        tab = representative
        folder = nil
        fromEssentials = false
        self.sourceSize = sourceSize
        grabOffset = grab
        location = p
    }

    /// begin dragging a folder — everything filed under it moves with it
    func beginFolder(
        _ folder: TabFolder, sourceSize: CGSize, at p: CGPoint, grab: CGSize = .zero
    ) {
        self.folder = folder
        tab = nil
        group = nil
        fromEssentials = false
        self.sourceSize = sourceSize
        grabOffset = grab
        location = p
    }

    func end() {
        dropTick &+= 1
    }

    func clear() {
        tab = nil
        group = nil
        folder = nil
        fromEssentials = false
        grabOffset = .zero
        contentDropZone = nil
        spaceDropTarget = nil
    }
}

/// the favourites grid's balanced-row geometry, computed analytically rather
/// than read back from the (reflowing) tile frames. one source of truth for
/// both the real layout and the drag math, so the ghost width and the drop
/// index always agree with where the tiles actually sit — and neither feeds
/// back on the live frames, which is what made dragging glitch near the rows.
struct EssentialsGridMath {
    /// at most this many favourites share a row
    static let maxPerRow = 5

    var width: CGFloat
    var origin: CGPoint
    var spacing: CGFloat
    var tileHeight: CGFloat
    var minTileWidth: CGFloat
    var maxPerRow = EssentialsGridMath.maxPerRow

    /// the tile count for each row, top to bottom, for a grid of `count` tiles
    func rowCounts(_ count: Int) -> [Int] {
        guard count > 0, width > 0 else { return count > 0 ? [count] : [] }
        let fit = max(1, min(maxPerRow, Int((width + spacing) / (minTileWidth + spacing))))
        let rows = Int(ceil(Double(count) / Double(fit)))
        let base = count / rows
        let extra = count % rows
        return (0 ..< rows).map { base + ($0 < extra ? 1 : 0) }
    }

    /// width of a tile in a row that holds `n` of them
    func tileWidth(perRow n: Int) -> CGFloat {
        (width - spacing * CGFloat(max(n, 1) - 1)) / CGFloat(max(n, 1))
    }

    /// width of the tile in whichever row slot `i` falls in, for `count` slots
    func tileWidth(forSlot i: Int, count: Int) -> CGFloat {
        var idx = 0
        for n in rowCounts(count) {
            if i < idx + n { return tileWidth(perRow: n) }
            idx += n
        }
        return width
    }

    /// the row-major slot a point would insert at, among `count` tiles. uses
    /// the row's vertical midpoint as a hard boundary (no overlap between rows)
    /// and each tile's centre X within the row, so it never oscillates
    func insertionIndex(at p: CGPoint, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let rows = rowCounts(count)
        var idx = 0
        var y = origin.y
        for (r, n) in rows.enumerated() {
            let isLast = r == rows.count - 1
            // the row owns everything down to halfway into the gap below it
            if p.y < y + tileHeight + spacing / 2 || isLast {
                let tileW = tileWidth(perRow: n)
                var col = 0
                for c in 0 ..< n {
                    let centreX = origin.x + CGFloat(c) * (tileW + spacing) + tileW / 2
                    if centreX < p.x { col += 1 } else { break }
                }
                return idx + min(col, n)
            }
            idx += n
            y += tileHeight + spacing
        }
        return count
    }
}

/// a favourite tile's frame within `contentSpace`, for hit-testing the drop slot
struct EssentialFrame: Equatable {
    let id: BrowserTab.ID
    let rect: CGRect
}

struct EssentialFrameKey: PreferenceKey {
    static let defaultValue: [EssentialFrame] = []
    static func reduce(value: inout [EssentialFrame], nextValue: () -> [EssentialFrame]) {
        value.append(contentsOf: nextValue())
    }
}
