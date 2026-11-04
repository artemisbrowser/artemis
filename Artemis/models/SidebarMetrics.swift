// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import SwiftUI

/// every spacing dimension in the sidebar, in points: one source of truth for
/// the row, header and url views
struct SidebarMetrics {
    /// height of a tab/url/header highlight
    let rowHeight: CGFloat
    /// gap between adjacent tab rows
    let tabSpacing: CGFloat
    /// gap from the url pill down to the space highlight
    let urlToTabsGap: CGFloat
    /// gap from the space header highlight down to the first tab
    let headerToTabsGap: CGFloat
    /// gap on each side of the pinned/unpinned divider line (last pinned tab
    /// above, New Tab row below), measured between highlight edges
    let pinnedDividerGap: CGFloat
    /// side of the per-tab ✕ close button's hit box
    let closeBoxSize: CGFloat
    /// point size of tab titles, space names and the New Tab label (not the url)
    let fontSize: CGFloat
    /// leading inset of a row's content (favicon / icon)
    let rowLeadingPadding: CGFloat
    /// trailing inset of a row, sized to frame the ✕ box symmetrically
    let rowTrailingPadding: CGFloat
    /// minimum width of a favourite tile, sized so exactly two tiles fit inline
    /// at the narrowest sidebar (160pt − 14 inset = 146 inner; padded half).
    /// rows grow tiles past this to fill the width
    let essentialTileMin: CGFloat
    /// height of a favourite tile in the essentials grid
    let essentialTileHeight: CGFloat
    /// favicon size inside a favourite tile
    let essentialFaviconSize: CGFloat

    /// vertical padding that grows a 16pt icon/text row to `rowHeight`
    var rowVPadding: CGFloat { (rowHeight - 16) / 2 }
    /// vertical padding around the 22pt space-header content
    var headerVPadding: CGFloat { (rowHeight - 22) / 2 }

    static let standard = SidebarMetrics(
        rowHeight: 36, tabSpacing: 5, urlToTabsGap: 8, headerToTabsGap: 0,
        pinnedDividerGap: 15, closeBoxSize: 24, fontSize: 14,
        rowLeadingPadding: 11, rowTrailingPadding: 7,
        essentialTileMin: 70, essentialTileHeight: 48, essentialFaviconSize: 20)
    /// diameter of a standalone glass button: as tall as the url bar
    static let glassSide = standard.rowHeight
}
