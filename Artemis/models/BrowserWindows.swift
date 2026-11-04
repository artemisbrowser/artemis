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
    /// the first window's manager: the one that owns app-wide work (session
    /// restore, the extension runtime) and the fallback for menu commands
    private(set) var primary: TabManager?

    private var registry: [ObjectIdentifier: (window: NSWindow, manager: TabManager)] = [:]
    @ObservationIgnored private var launchWorkClaimed = false

    /// the space a window about to open should land on — set by New Window, read
    /// by the root view as it builds its manager
    @ObservationIgnored var pendingSpaceID: Space.ID?

    /// the manager the app builds before any window exists — the menu bar needs
    /// something to talk to at launch. The first window takes it rather than
    /// making a second one
    @ObservationIgnored var seed: TabManager?

    private init() {
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let window = note.object as? NSWindow else { return }
                if let manager = self?.registry[ObjectIdentifier(window)]?.manager {
                    self?.current = manager
                    ExtensionManager.shared.windowDidFocus(manager)
                }
            }
        }
    }

    func register(_ manager: TabManager, for window: NSWindow) {
        registry[ObjectIdentifier(window)] = (window, manager)
        if primary == nil { primary = manager }
        if window.isKeyWindow || current == nil { current = manager }
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.unregister(window) }
        }
    }

    private func unregister(_ window: NSWindow) {
        guard let entry = registry.removeValue(forKey: ObjectIdentifier(window)) else { return }
        entry.manager.windowWillClose()
        if current === entry.manager { current = registry.values.first?.manager ?? primary }
        if primary === entry.manager { primary = registry.values.first?.manager }
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
        return mainManagers.first ?? primary.flatMap { $0.kind == .main ? $0 : nil }
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
