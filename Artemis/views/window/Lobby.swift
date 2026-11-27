// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import AppKit

/// An invisible panel that holds Artemis's key slot while another app is in front.
/// Activation raises only the key window, so a link's raises nothing; every other
/// activation hands key back before it lands.
@MainActor
enum Lobby {
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
    }

    private static let panel: Panel = {
        let panel = Panel(
            contentRect: NSRect(x: 0, y: 0, width: 4, height: 4), styleMask: [.borderless],
            backing: .buffered, defer: true)
        panel.alphaValue = 0
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isExcludedFromWindowsMenu = true
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        panel.setAccessibilityElement(false)
        panel.sharingType = .none
        return panel
    }()

    private static weak var prior: NSWindow?
    private static var shownAtResign: Set<ObjectIdentifier> = []
    private static var engagements = 0

    static func isLobby(_ window: NSWindow) -> Bool { window === panel }

    static var isHolding: Bool { panel.isVisible }

    /// `NSApp.keyWindow`, never the lobby
    static var keyWindow: NSWindow? { NSApp.keyWindow.flatMap { isLobby($0) ? nil : $0 } }

    /// once at launch
    static func install() {
        let center = NotificationCenter.default
        center.addObserver(forName: NSApplication.willResignActiveNotification, object: nil, queue: nil) { _ in
            MainActor.assumeIsolated {
                prior = NSApp.keyWindow.flatMap { isLobby($0) ? nil : $0 }
            }
        }
        center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: nil) { _ in
            MainActor.assumeIsolated {
                let shown = NSApp.windows.filter { $0.isVisible && !isLobby($0) }
                guard !NSApp.isActive, !shown.isEmpty else { return }
                shownAtResign = Set(shown.map(ObjectIdentifier.init))
                engagements += 1
                panel.orderFront(nil)
                panel.makeKey()
            }
        }
        center.addObserver(forName: NSApplication.willBecomeActiveNotification, object: nil, queue: nil) { _ in
            MainActor.assumeIsolated {
                guard isHolding else { return }
                // 0x400 in an activation's data2 marks one that opens URLs or documents
                if let event = NSApp.currentEvent, event.type == .appKitDefined,
                    event.subtype == .applicationActivated, event.data2 & 0x400 != 0
                {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { settle() }
                    return
                }
                handBack(raising: false)
            }
        }
        center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: nil) { note in
            MainActor.assumeIsolated {
                guard let window = note.object as? NSWindow, !isLobby(window), isHolding else { return }
                leave()
            }
        }
    }

    /// once an open has had its say: gives key back if nothing else of Artemis took it
    static func settle() {
        guard isHolding, NSApp.isActive, panel.isKeyWindow else { return }
        handBack(raising: true)
    }

    private static func handBack(raising: Bool) {
        let candidates =
            [
                NSApp.windows.last { $0.isVisible && $0.canBecomeKey && !shownAtResign.contains(ObjectIdentifier($0)) && !isLobby($0) },
                prior.flatMap { $0.isVisible ? $0 : nil },
            ].compactMap { $0 } + NSApp.orderedWindows.filter { $0.isVisible && $0.canBecomeKey && !isLobby($0) }
        // as macOS does: a window on the Space shown, else another Space's, which the lobby (on every Space) can't switch to
        let target = candidates.first(where: \.isOnActiveSpace) ?? candidates.first
        // Desktop & Dock's "When switching to an application, switch to a Space with open windows"
        let switchesSpaces = UserDefaults(suiteName: "com.apple.dock")?.object(forKey: "workspaces-auto-swoosh") as? Bool ?? true
        if raising || target?.isOnActiveSpace == false && switchesSpaces { target?.makeKeyAndOrderFront(nil) } else { target?.makeKey() }
        leave()
    }

    /// a turn after another window takes key: leaving in the same turn sends the app's
    /// other windows to the back of every app's
    private static func leave() {
        let engagement = engagements
        DispatchQueue.main.async { if engagements == engagement { panel.orderOut(nil) } }
    }
}
