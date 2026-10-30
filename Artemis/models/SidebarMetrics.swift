import SwiftUI

/// every spacing dimension in the sidebar, in points, read through the
/// environment so the row/header/url views share one source of truth
struct SidebarMetrics: Equatable {
    /// height of a tab/url/header highlight
    var rowHeight: CGFloat
    /// gap between adjacent tab rows
    var tabSpacing: CGFloat
    /// gap from the url pill down to the space highlight
    var urlToTabsGap: CGFloat
    /// gap from the space header highlight down to the first tab
    var headerToTabsGap: CGFloat
    /// gap on each side of the pinned/unpinned divider line (last pinned tab
    /// above, New Tab row below), measured between highlight edges
    var pinnedDividerGap: CGFloat
    /// side of the per-tab ✕ close button's hit box
    var closeBoxSize: CGFloat
    /// point size of tab titles, space names and the New Tab label (not the url)
    var fontSize: CGFloat
    /// leading inset of a row's content (favicon / icon)
    var rowLeadingPadding: CGFloat
    /// trailing inset of a row, sized to frame the ✕ box symmetrically
    var rowTrailingPadding: CGFloat
    /// minimum width of a favourite tile, sized so exactly two tiles fit inline
    /// at the narrowest sidebar (160pt − 14 inset = 146 inner; padded half).
    /// rows grow tiles past this to fill the width
    var essentialTileMin: CGFloat
    /// height of a favourite tile in the essentials grid
    var essentialTileHeight: CGFloat
    /// favicon size inside a favourite tile
    var essentialFaviconSize: CGFloat

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

extension EnvironmentValues {
    @Entry var sidebarMetrics = SidebarMetrics.standard
}
