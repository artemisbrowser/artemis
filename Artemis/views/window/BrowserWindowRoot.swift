import SwiftUI

/// One browser window: its own `TabManager` (its space, its selection, its find
/// bar) over the shared `BrowserCore`, and its own tooltip layer — the bubble
/// draws in a panel of its own, so a second window needs a second one or the tip
/// follows the wrong pointer.
struct BrowserWindowRoot: View {
    @Environment(\.openWindow) private var openWindow
    @State private var box = ManagerBox()

    var body: some View {
        let manager = box.resolve()
        MainView()
            .environment(manager)
            .environment(manager.tooltipState)
            .background(WindowBinder(manager: manager))
            .onAppear { IncognitoWindow.openWindow = openWindow }
    }
}

/// holds this window's manager for as long as the window lives. `@State`'s
/// initial value is rebuilt on every struct init, so the manager is made on first
/// body instead — only the retained box is ever asked
@MainActor
final class ManagerBox {
    private var manager: TabManager?

    func resolve() -> TabManager {
        if let manager { return manager }
        let windows = BrowserWindows.shared
        let resolved = windows.nextManager(startingOn: windows.pendingSpaceID)
        windows.pendingSpaceID = nil
        manager = resolved
        return resolved
    }
}
