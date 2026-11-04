// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import SwiftUI

/// the sidebar's one drag, fed by tab rows and favourite tiles alike. every
/// gesture reports into `contentSpace`, where the ghost and drop indicators draw
/// above the scroll view's clip
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
    /// bumped on release; the sidebar observes it to commit the drop
    var dropTick = 0
    /// the cursor is over the content area as a split drop (not over the
    /// sidebar), so the drop tiles instead of reordering
    var isOverContent = false
    /// the sidebar's window-space frame (pinned or floating overlay), so the
    /// content drop-to-split can ignore drags that are still over the sidebar —
    /// the overlay sidebar floats above the web card, so geometry alone isn't enough
    @ObservationIgnored var sidebarFrame: CGRect = .zero

    /// frames of the space icons at the sidebar's foot, in `contentSpace`, while
    /// the switcher is on screen, so a tab dropped on one moves into that space
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

    func begin(_ tab: BrowserTab, fromEssentials: Bool, at p: CGPoint, grab: CGSize) {
        self.tab = tab
        group = nil
        folder = nil
        self.fromEssentials = fromEssentials
        grabOffset = grab
        location = p
    }

    /// begin dragging a whole split as a unit (move it, don't break it apart)
    func beginGroup(_ group: SplitGroup, representative: BrowserTab, at p: CGPoint, grab: CGSize) {
        self.group = group
        tab = representative
        folder = nil
        fromEssentials = false
        grabOffset = grab
        location = p
    }

    /// begin dragging a folder — everything filed under it moves with it
    func beginFolder(_ folder: TabFolder, at p: CGPoint, grab: CGSize) {
        self.folder = folder
        tab = nil
        group = nil
        fromEssentials = false
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
        isOverContent = false
        spaceDropTarget = nil
    }
}

/// the favourites grid's balanced-row geometry, computed rather than read back
/// from the reflowing tile frames: one source for the layout and the drag math
struct EssentialsGridMath {
    /// at most this many favourites share a row
    private static let maxPerRow = 5

    var width: CGFloat
    var origin: CGPoint
    var spacing: CGFloat
    var tileHeight: CGFloat
    var minTileWidth: CGFloat

    /// the tile count for each row, top to bottom, for a grid of `count` tiles
    func rowCounts(_ count: Int) -> [Int] {
        guard count > 0, width > 0 else { return count > 0 ? [count] : [] }
        let fit = max(1, min(Self.maxPerRow, Int((width + spacing) / (minTileWidth + spacing))))
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

    /// the row-major slot a point would insert at, among `count` tiles: each row
    /// owns down to the middle of the gap below it and columns split at tile
    /// centres, so it never oscillates
    func insertionIndex(at p: CGPoint, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let rows = rowCounts(count)
        var idx = 0
        var y = origin.y
        for (r, n) in rows.enumerated() {
            let isLast = r == rows.count - 1
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
