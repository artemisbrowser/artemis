import AppKit
import WebKit

/// presents Artemis's single browser window to the WebExtensions runtime so
/// `chrome.windows` / `chrome.tabs` have something to enumerate. Artemis is a
/// one-window-per-scene browser with spaces, so we map "the window" onto the
/// current space's tab set rather than inventing a window per space.
final class ExtensionWindow: NSObject, WKWebExtensionWindow {
    weak var tabManager: TabManager?

    init(tabManager: TabManager) {
        self.tabManager = tabManager
    }

    /// the window the user is in (a Scout's page included), or the browser they
    /// were last in when an incognito one has focus. the runtime attaches to the
    /// first manager built, which outlives its own window and need not be on screen
    @MainActor
    var scope: TabManager? {
        if let current = BrowserWindows.shared.current, current.kind != .incognito { return current }
        return BrowserWindows.shared.browserScope ?? tabManager
    }

    /// what a profile's extensions see of this window: the space you're in when it
    /// is theirs, else the first of their own. never another profile's tabs
    @MainActor
    private func space(for context: WKWebExtensionContext) -> (tabs: [BrowserTab], selected: BrowserTab?) {
        guard let scope else { return ([], nil) }
        let profile = context.webExtensionController.flatMap(WebExtensionRuntime.profile(of:))
            ?? Profile.defaultID
        let space = scope.currentSpace.profileID == profile
            ? scope.currentSpace : scope.spaces.first { $0.profileID == profile }
        let essentials = scope.core.profile(profile)?.essentials ?? []
        let selected = space?.selectedTab ?? essentials.first
        return (((space?.tabs ?? []) + essentials).filter { !$0.isPrivate }, selected)
    }

    /// favourites are open tabs too, and WebKit throws the whole list away when
    /// it doesn't contain `activeTab` — leaving `tabs.query` with nothing
    @MainActor
    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] {
        space(for: context).tabs
    }

    @MainActor
    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        space(for: context).selected.flatMap { $0.isPrivate ? nil : $0 }
    }

    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType {
        .normal
    }

    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState {
        guard let window = NSApp.keyWindow else { return .normal }
        if window.styleMask.contains(.fullScreen) { return .fullscreen }
        return window.isMiniaturized ? .minimized : .normal
    }

    func isPrivate(for context: WKWebExtensionContext) -> Bool { false }

    func frame(for context: WKWebExtensionContext) -> CGRect {
        NSApp.keyWindow?.frame ?? .zero
    }

    func screenFrame(for context: WKWebExtensionContext) -> CGRect {
        NSApp.keyWindow?.screen?.frame ?? NSScreen.main?.frame ?? .zero
    }

    func focus(for context: WKWebExtensionContext) async throws {
        await MainActor.run { NSApp.keyWindow?.makeKeyAndOrderFront(nil) }
    }
}
