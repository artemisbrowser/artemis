// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import AppKit
import SwiftUI

/// which spaces asking for Touch ID are open right now — incognito windows'
/// included. Every one of them locks again the moment Artemis stops being the active app
@MainActor
@Observable
final class SpaceLock {
    static let shared = SpaceLock()

    /// Settings › Privacy & Security: every incognito window asks for Touch ID once Artemis has been away
    static let incognitoRequiresUnlockKey = "incognitoRequiresUnlock"

    private var unlocked: Set<UUID> = []
    /// spaces another device stopped locking: the lock comes off here at the next unlock
    var lockOffElsewhere: Set<UUID> = []
    /// the system prompt deactivates the app; that must not relock what it is unlocking
    @ObservationIgnored private var isAuthenticating = false
    @ObservationIgnored private var observer: NSObjectProtocol?

    private init() {
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                guard !SpaceLock.shared.isAuthenticating else { return }
                SpaceLock.shared.unlocked.removeAll()
                let player = BrowserCore.shared.miniPlayer
                if let tab = player.tab, tab.manager?.space(of: tab).map(SpaceLock.shared.isLocked) == true {
                    player.exitIfActive(for: tab)
                }
                for manager in BrowserWindows.shared.allManagers {
                    if manager.currentSpace.requiresUnlock { manager.closePeek() }
                    for space in manager.spaces + [manager.currentSpace] where space.requiresUnlock {
                        for tab in space.tabs { tab.closeInspector() }
                    }
                }
                BrowserWindows.shared.current?.offerHandoff()
            }
        }
    }

    func isLocked(_ space: Space) -> Bool { space.requiresUnlock && !unlocked.contains(space.id) }

    /// `tab`, or nil while it is locked `space`'s own page
    func unlocked(_ tab: BrowserTab?, in space: Space?) -> BrowserTab? {
        tab.flatMap { $0.isEssential || space.map(isLocked) != true ? $0 : nil }
    }

    /// done by the person at the keyboard, so the space starts unlocked
    func requireUnlock(for space: Space) {
        space.requiresUnlock = true
        unlocked.insert(space.id)
    }

    /// a space locked right now keeps its lock unless the owner passes the check
    func stopRequiringUnlock(for space: Space) async {
        guard await unlock(space, to: "stop locking the \u{201C}\(space.name)\u{201D} space") else { return }
        space.requiresUnlock = false
    }

    /// applies to incognito windows already open as well as new ones. while one is locked,
    /// turning it off needs the owner, and stays on when they refuse
    func setIncognitoRequiresUnlock(_ on: Bool) async {
        if !on, let shut = incognitoSpaces.first(where: isLocked),
            !(await unlock(shut, to: "stop locking incognito windows"))
        {
            return
        }
        UserDefaults.standard.set(on, forKey: Self.incognitoRequiresUnlockKey)
        for space in incognitoSpaces {
            if on { requireUnlock(for: space) } else { space.requiresUnlock = false }
        }
    }

    /// true once `space` is open, asking the owner only while it is locked
    @discardableResult
    func unlock(_ space: Space, to reason: String? = nil) async -> Bool {
        guard isLocked(space) else { return true }
        guard !isAuthenticating else { return false }
        isAuthenticating = true
        defer { isAuthenticating = false }
        let isIncognito = incognitoSpaces.contains { $0 === space }
        let reason = reason ?? (isIncognito ? "open your incognito window" : "open the \u{201C}\(space.name)\u{201D} space")
        guard await OwnerUnlock.check(reason) else { return false }
        unlocked.insert(space.id)
        if lockOffElsewhere.remove(space.id) != nil {
            space.requiresUnlock = false
            BrowserWindows.shared.mainManagers.first?.scheduleSave()
        }
        BrowserWindows.shared.current?.offerHandoff()
        LiveRefresh.shared.reschedule()
        return true
    }

    private var incognitoSpaces: [Space] {
        BrowserWindows.shared.allManagers.filter { $0.kind == .incognito }.map(\.currentSpace)
    }
}

/// stands in for a locked space's page until Touch ID or the account password opens it
struct LockedSpaceView: View {
    @Environment(\.chromeInk) private var ink
    @Environment(\.controlActiveState) private var activeState
    let space: Space

    var body: some View {
        VStack(spacing: 12) {
            Button { Task { await SpaceLock.shared.unlock(space) } } label: {
                Image(systemName: LockedSpaceView.glyph)
                    .font(.system(size: 48, weight: .light))
                    .frame(width: 96, height: 96)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .tooltip("Unlock \(space.name)")
            .accessibilityLabel("Unlock \(space.name)")
            if SpaceLock.shared.lockOffElsewhere.contains(space.id) {
                Text("Lock turned off on another device.")
                    .font(.system(size: 13))
            }
        }
        .foregroundStyle(ink.opacity(0.85))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // arriving on the space in the key window asks at once; a cancel waits for a click.
        // a self-test locks spaces in place under a check that always passes
        .task(id: space.id) {
            if activeState == .key, !SelfTest.isRequested { await SpaceLock.shared.unlock(space) }
        }
    }

    static var glyph: String { OwnerUnlock.method == "Touch ID" ? "touchid" : "lock.fill" }
}

/// the sidebar's tab list while its space is locked
struct LockedTabsNote: View {
    @Environment(\.chromeInk) private var ink
    let space: Space

    var body: some View {
        Button {
            Task { await SpaceLock.shared.unlock(space) }
        } label: {
            Label("Click to unlock", systemImage: LockedSpaceView.glyph)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(ink.opacity(0.55))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
