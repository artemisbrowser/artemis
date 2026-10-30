import SwiftUI

/// Arc's View ▸ Show Toolbar: the url pill and navigation leave the sidebar for
/// a row above the page, on the window's backdrop
struct BrowserToolbar: View {
    static let shownKey = "showsToolbar"
    static let fullURLKey = "toolbarShowsFullURL"
    /// the row's distance from the window top, shared with the sidebar's top row
    static let top: CGFloat = 8
    static let height = SidebarMetrics.standard.rowHeight

    static var isShown: Bool { UserDefaults.standard.bool(forKey: shownKey) }

    @Environment(TabManager.self) private var tabManager
    @State private var navigationWidth: CGFloat = 0

    var body: some View {
        ZStack {
            HStack(spacing: 6) {
                // the lights and toggle ride the sidebar off-window
                if tabManager.isSidebarCollapsed { SidebarToggleButton() }
                NavigationControls()
            }
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { navigationWidth = $0 }
            .frame(maxWidth: .infinity, alignment: .leading)
            // centred on the toolbar, kept clear of the navigation on both sides
            UrlField(inToolbar: true)
                .padding(.horizontal, navigationWidth + 6)
        }
        .frame(height: Self.height)
        .environment(\.chromeInk, tabManager.blendedInk)
        .environment(\.spaceAccent, tabManager.blendedAccent)
    }
}
