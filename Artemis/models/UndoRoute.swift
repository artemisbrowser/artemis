// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import AppKit
import WebKit

/// where ⌘Z and ⇧⌘Z go, and what the Edit menu calls them: a browser window's sidebar acts
/// undo on its `TabManager.undo`, while typing, page editing and Settings use the window's own
/// stack. the menu reads this through `@State`, so every title change is a published one
@Observable
final class UndoRoute {
    static let shared = UndoRoute()

    private(set) var undoTitle = "Undo"
    private(set) var redoTitle = "Redo"
    private(set) var canUndo = false
    private(set) var canRedo = false

    @ObservationIgnored private var refreshQueued = false
    @ObservationIgnored private var responderWatches: [ObjectIdentifier: NSKeyValueObservation] = [:]

    private init() {
        // never `.NSUndoManagerCheckpoint`: reading `canRedo` posts it
        let names: [Notification.Name] = [
            .NSUndoManagerDidCloseUndoGroup, .NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange,
            NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
            NSMenu.didBeginTrackingNotification,
        ]
        for name in names {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
    }

    /// the browser stack ⌘Z reaches in `window`; nil when the text or page being edited undoes natively
    static func browserStack(in window: NSWindow) -> UndoManager? {
        // a popover's acts belong to the window it hangs off
        guard let manager = BrowserWindows.shared.manager(for: window.parent ?? window), manager.kind != .scout
        else { return nil }
        guard let responder = window.firstResponder as? NSView else { return manager.undo }
        if responder is NSText { return nil }
        guard let page = sequence(first: responder, next: \.superview).first(where: { $0 is WKWebView }) else {
            return manager.undo
        }
        // the Web Inspector's own view counts as editing
        return (page as? ArtemisWebView)?.owningTab?.isEditingText == false ? manager.undo : nil
    }

    /// ⌘Z or ⇧⌘Z in the key window. the native path goes down the responder chain, so WebKit
    /// runs its own undo and a page's editor hears it
    func perform(redo: Bool) {
        guard let window = NSApp.keyWindow else { return }
        if let stack = Self.browserStack(in: window), redo ? stack.canRedo : stack.canUndo {
            redo ? stack.redo() : stack.undo()
        } else {
            NSApp.sendAction(Selector((redo ? "redo:" : "undo:")), to: nil, from: nil)
        }
        refresh()
    }

    /// the menu follows a browser window's focus as well as its stacks
    func watch(_ window: NSWindow) {
        responderWatches[ObjectIdentifier(window)] = window.observe(\.firstResponder) { _, _ in
            MainActor.assumeIsolated { UndoRoute.shared.refresh() }
        }
    }

    func unwatch(_ window: NSWindow) {
        responderWatches[ObjectIdentifier(window)] = nil
    }

    /// recompute the titles once this turn of the run loop is done
    func refresh() {
        guard !refreshQueued else { return }
        refreshQueued = true
        DispatchQueue.main.async { [weak self] in self?.update() }
    }

    /// a missed refresh can only leave an item enabled with nothing behind it, never
    /// disable a ⌘Z a field still had
    private func update() {
        refreshQueued = false
        let window = NSApp.keyWindow
        let stack = window.flatMap(Self.browserStack(in:))
        let native = window?.undoManager
        let undoable = stack?.canUndo == true ? stack : native
        let redoable = stack?.canRedo == true ? stack : native
        let titles = (undoable?.undoMenuItemTitle ?? "Undo", redoable?.redoMenuItemTitle ?? "Redo")
        let enabled = (
            stack?.canUndo == true || native?.canUndo == true, stack?.canRedo == true || native?.canRedo == true
        )
        if undoTitle != titles.0 { undoTitle = titles.0 }
        if redoTitle != titles.1 { redoTitle = titles.1 }
        if canUndo != enabled.0 { canUndo = enabled.0 }
        if canRedo != enabled.1 { canRedo = enabled.1 }
    }
}
