// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import AppKit
import WebKit

/// one window's ⌃⇥ switcher over `TabManager.recentTabs`. a tap flips to the last tab; held past
/// `reveal`, the tabs show as cards until ⌃ goes up, which switches to the selected one
@Observable
final class TabSwitcher {
    static let cap = 8
    /// ⌃ held this long shows the cards; a quicker tap switches without them
    static let reveal: Duration = .milliseconds(170)
    /// how often ⌃ is read while active, which catches a release inside another tracking loop
    static let poll: Duration = .milliseconds(50)
    /// the widest a card draws, in points, and so the width its page is snapshotted at
    static let frameWidth: CGFloat = 180

    /// while active: the window's own tab first, when it has one, then the rest most recent first
    private(set) var cards: [BrowserTab] = []
    private(set) var selection = 0
    /// ⌃ is down and Tab, ⇧Tab and Esc belong to the switcher
    private(set) var isActive = false
    private(set) var isShown = false
    /// the cards' pages, in memory only so an incognito page never reaches disk
    private(set) var frames: [BrowserTab.ID: NSImage] = [:]

    /// stands in for the keyboard's ⌃ in the self-test, whose synthesised events never reach it
    @ObservationIgnored var controlOverride: Bool?

    @ObservationIgnored private weak var manager: TabManager?
    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var watching: Task<Void, Never>?

    init(manager: TabManager) {
        self.manager = manager
    }

    private var isControlDown: Bool { controlOverride ?? NSEvent.modifierFlags.contains(.control) }

    /// selects the `offset`th most recent other tab; unless ⌃ is still down and no other window
    /// of the app is key, it switches there at once
    func begin(offset: Int = 1) {
        guard !isActive, let manager else { return }
        let recent = manager.recentTabs
        guard !recent.isEmpty else { return }
        let current = manager.selectedTab.map { [$0] } ?? []
        cards = Array((current + recent).prefix(Self.cap))
        selection = min(current.count + offset - 1, cards.count - 1)
        guard isControlDown, let window = BrowserWindows.shared.window(of: manager),
            !NSApp.windows.contains(where: { $0 !== window && $0.isKeyWindow })
        else {
            return commit()
        }
        isActive = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown, .leftMouseDown, .leftMouseUp]) {
            [weak self, weak window] event in
            guard let self else { return event }
            return handle(event, in: window)
        }
        observers = [
            (NSWindow.didResignKeyNotification, window), (NSApplication.didResignActiveNotification, NSApp),
        ].map { name, object in
            NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.cancel() }
            }
        }
        watching = Task { [weak self] in
            try? await Task.sleep(for: Self.reveal)
            guard !Task.isCancelled else { return }
            self?.show()
            while !Task.isCancelled, let self, isActive {
                guard isControlDown else { return commit() }
                try? await Task.sleep(for: Self.poll)
            }
        }
    }

    func pick(_ index: Int) {
        selection = index
        commit()
    }

    func cancel() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        watching?.cancel()
        watching = nil
        isActive = false
        isShown = false
        cards = []
        frames = [:]
    }

    /// moves the selection, wrapping at either end
    private func step(by delta: Int) {
        guard !cards.isEmpty else { return }
        selection = ((selection + delta) % cards.count + cards.count) % cards.count
        if isShown { announce(cards[selection].displayTitle) }
    }

    private func commit() {
        let tab = cards.indices.contains(selection) ? cards[selection] : nil
        cancel()
        if let tab { manager?.focus(tab) }
    }

    private func show() {
        guard isControlDown else { return commit() }
        isShown = true
        announce("Recent tabs, \(cards[selection].displayTitle)")
        for tab in cards where tab.pendingURL == nil && !tab.isHibernated { capture(tab) }
    }

    private func announce(_ text: String) {
        NSAccessibility.post(
            element: NSApp as Any, notification: .announcementRequested,
            userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    private func capture(_ tab: BrowserTab) {
        let id = tab.id
        let configuration = WKSnapshotConfiguration()
        configuration.snapshotWidth = NSNumber(value: Double(Self.frameWidth))
        configuration.afterScreenUpdates = false
        tab.webView.takeSnapshot(with: configuration) { [weak self] image, _ in
            MainActor.assumeIsolated {
                if let image, let self, self.isShown { self.frames[id] = image }
            }
        }
    }

    private func handle(_ event: NSEvent, in window: NSWindow?) -> NSEvent? {
        guard event.modifierFlags.contains(.control) else {
            commit()
            return event
        }
        guard event.type != .flagsChanged, event.window === window else { return event }
        switch event.type {
        case .keyDown where event.keyCode == 48:  // Tab
            step(by: event.modifierFlags.contains(.shift) ? -1 : 1)
            return nil
        case .keyDown where event.keyCode == 53:  // Esc
            cancel()
            return nil
        case .leftMouseDown where isShown, .leftMouseUp where isShown:
            // a held ⌃ would make the click a context-menu click; the cards take a plain one
            return NSEvent.mouseEvent(
                with: event.type, location: event.locationInWindow,
                modifierFlags: event.modifierFlags.subtracting(.control), timestamp: event.timestamp,
                windowNumber: event.windowNumber, context: nil, eventNumber: event.eventNumber,
                clickCount: event.clickCount, pressure: event.pressure) ?? event
        default:
            return event
        }
    }
}
