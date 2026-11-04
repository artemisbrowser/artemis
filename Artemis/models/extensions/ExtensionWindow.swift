// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import AppKit
import WebKit

/// a browser window as `chrome.windows` sees it: one for the browser, mapped onto the current
/// space's tabs rather than one per space, and one per incognito window, private to its parent
/// profile's controller
final class ExtensionWindow: NSObject, WKWebExtensionWindow {
    weak var tabManager: TabManager?
    /// an incognito window's parent profile; nil for the browser
    private let parent: UUID?

    init(tabManager: TabManager, privateTo parent: UUID? = nil) {
        self.tabManager = tabManager
        self.parent = parent
    }

    /// the controller an incognito window belongs to
    @MainActor
    var controller: WKWebExtensionController? { parent.flatMap { WebExtensionRuntime.controllers[$0] } }

    /// the window the user is in (a Scout's page included), or the browser they
    /// were last in when an incognito one has focus. the runtime attaches to the
    /// first manager built, which outlives its own window and need not be on screen
    @MainActor
    var scope: TabManager? {
        if parent != nil { return tabManager }
        if let current = BrowserWindows.shared.current, current.kind != .incognito { return current }
        return BrowserWindows.shared.browserScope ?? tabManager
    }

    /// what a profile's extensions see of this window: the space you're in when it
    /// is theirs, else the first of their own. never another profile's tabs, and
    /// incognito ones only in an incognito window
    @MainActor
    private func space(for context: WKWebExtensionContext) -> (tabs: [BrowserTab], selected: BrowserTab?) {
        guard let scope else { return ([], nil) }
        if parent != nil { return (scope.currentSpace.tabs, scope.currentSpace.selectedTab) }
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
        space(for: context).selected.flatMap { $0.isPrivate == (parent != nil) ? $0 : nil }
    }

    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType {
        .normal
    }

    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState {
        guard let window = NSApp.keyWindow else { return .normal }
        if window.styleMask.contains(.fullScreen) { return .fullscreen }
        return window.isMiniaturized ? .minimized : .normal
    }

    func isPrivate(for context: WKWebExtensionContext) -> Bool { parent != nil }

    func frame(for context: WKWebExtensionContext) -> CGRect {
        NSApp.keyWindow?.frame ?? .zero
    }

    func screenFrame(for context: WKWebExtensionContext) -> CGRect {
        NSApp.keyWindow?.screen?.frame ?? NSScreen.main?.frame ?? .zero
    }

    func focus(for context: WKWebExtensionContext) async throws {
        await MainActor.run {
            let own = parent == nil ? nil : tabManager.flatMap(BrowserWindows.shared.window(of:))
            (own ?? NSApp.keyWindow)?.makeKeyAndOrderFront(nil)
        }
    }
}
