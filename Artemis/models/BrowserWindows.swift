// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import AppKit
import SwiftUI

/// Which `TabManager` belongs to which window, and which one a menu command
/// acts on. The menu bar is app-wide while the managers are per window, so
/// without this every shortcut lands on the first window's page.
@Observable
@MainActor
final class BrowserWindows {
    static let shared = BrowserWindows()

    /// the manager of the window that last had focus — what ⌘R, ⌘F and the rest
    /// act on
    private(set) var current: TabManager?

    private var registry: [ObjectIdentifier: (window: NSWindow, manager: TabManager)] = [:]
    @ObservationIgnored private var launchWorkClaimed = false

    /// the space a window about to open should land on — set by New Window, read
    /// by the root view as it builds its manager
    @ObservationIgnored var pendingSpaceID: Space.ID?

    /// the manager the next browser window takes rather than making one: the
    /// app's first, built before any window exists, or the last browser window's
    /// once every one has closed, so what was done meanwhile shows up in it
    @ObservationIgnored var seed: TabManager?

    /// posted with the window once its manager is registered, which can come after it turns key
    static let didRegisterNotification = Notification.Name("dev.findles.Artemis.browserWindowDidRegister")

    private init() {
        let center = NotificationCenter.default
        center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) {
            [weak self] note in
            MainActor.assumeIsolated {
                guard let window = note.object as? NSWindow else { return }
                if let manager = self?.registry[ObjectIdentifier(window)]?.manager {
                    self?.current = manager
                    ExtensionManager.shared.windowDidFocus(manager)
                }
            }
        }
        // app-wide, so the registry entry is a window's only strong reference here
        center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) {
            [weak self] note in
            MainActor.assumeIsolated {
                if let window = note.object as? NSWindow { self?.unregister(window) }
            }
        }
    }

    func register(_ manager: TabManager, for window: NSWindow) {
        registry[ObjectIdentifier(window)] = (window, manager)
        UndoRoute.shared.watch(window)
        if window.isKeyWindow || current == nil { current = manager }
        NotificationCenter.default.post(name: Self.didRegisterNotification, object: window)
        LiveRefresh.shared.reschedule()
    }

    private func unregister(_ window: NSWindow) {
        guard let entry = registry.removeValue(forKey: ObjectIdentifier(window)) else { return }
        UndoRoute.shared.unwatch(window)
        entry.manager.windowWillClose()
        if current === entry.manager { current = registry.values.first?.manager }
        if entry.manager.kind == .main, mainManagers.isEmpty { seed = entry.manager }
    }

    /// true once per launch: the first window to ask runs the app-wide warm-ups
    func claimLaunchWork() -> Bool {
        guard !launchWorkClaimed else { return false }
        launchWorkClaimed = true
        return true
    }

    /// the manager driving `window`, if it is one of ours
    func manager(for window: NSWindow?) -> TabManager? {
        guard let window else { return nil }
        return registry[ObjectIdentifier(window)]?.manager
    }

    func window(of manager: TabManager) -> NSWindow? {
        registry.values.first { $0.manager === manager }?.window
    }

    /// every window showing the full browser chrome
    var mainManagers: [TabManager] {
        registry.values.map(\.manager).filter { $0.kind == .main }
    }

    /// every open window's manager, Scout windows included
    var allManagers: [TabManager] { registry.values.map(\.manager) }

    /// the window a command only the full browser can answer belongs to — a new
    /// tab, the Library, the spaces. The focused window when it is one, else any
    /// browser window
    var browserScope: TabManager? {
        if let current, current.kind == .main { return current }
        return mainManagers.first
    }
}

/// registers the window's manager so menu commands can find it
struct WindowBinder: NSViewRepresentable {
    let manager: TabManager

    func makeNSView(context: Context) -> BinderView {
        let view = BinderView()
        view.manager = manager
        return view
    }

    func updateNSView(_ nsView: BinderView, context: Context) {}

    /// AppKit can move it into its window several runloop turns after SwiftUI makes it
    final class BinderView: NSView {
        var manager: TabManager?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, let manager else { return }
            // never inside SwiftUI's own update, which observes `BrowserWindows`
            DispatchQueue.main.async {
                if BrowserWindows.shared.manager(for: window) !== manager {
                    BrowserWindows.shared.register(manager, for: window)
                }
            }
        }
    }
}

extension BrowserWindows {
    /// the manager for a window that is opening: the app's seed for the first
    /// window, a fresh one on `space` after that
    func nextManager(startingOn space: Space.ID?) -> TabManager {
        if let seed {
            self.seed = nil
            return seed
        }
        return TabManager(kind: .main, startingOn: space)
    }
}

extension SearchEngine {
    /// the engine of the profile in the window you're in
    static var current: SearchEngine {
        let windows = BrowserWindows.shared
        return (windows.current ?? windows.browserScope)?.currentProfile.searchEngine ?? stored
    }
}

extension SearchSuggest {
    /// the setting of the profile in the window you're in
    static var isEnabled: Bool {
        let windows = BrowserWindows.shared
        return (windows.current ?? windows.browserScope)?.currentProfile.suggestsSearches
            ?? UserDefaults.standard.bool(forKey: enabledKey)
    }
}
