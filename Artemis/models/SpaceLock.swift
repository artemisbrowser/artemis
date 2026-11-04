// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import AppKit
import LocalAuthentication
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
                BrowserWindows.shared.current?.offerHandoff()
            }
        }
    }

    func isLocked(_ space: Space) -> Bool { space.requiresUnlock && !unlocked.contains(space.id) }

    /// turning the lock on is done by the person at the keyboard, so it starts unlocked
    func setRequiresUnlock(_ on: Bool, for space: Space) {
        space.requiresUnlock = on
        if on { unlocked.insert(space.id) }
    }

    /// applies to incognito windows already open as well as new ones
    func setIncognitoRequiresUnlock(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.incognitoRequiresUnlockKey)
        for manager in BrowserWindows.shared.allManagers where manager.kind == .incognito {
            setRequiresUnlock(on, for: manager.currentSpace)
        }
    }

    func unlock(_ space: Space) async {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else { return }
        isAuthenticating = true
        defer { isAuthenticating = false }
        let isIncognito = BrowserWindows.shared.allManagers.contains {
            $0.kind == .incognito && $0.currentSpace === space
        }
        let reason = isIncognito ? "open your incognito window" : "open the \u{201C}\(space.name)\u{201D} space"
        if (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) == true {
            unlocked.insert(space.id)
            BrowserWindows.shared.current?.offerHandoff()
        }
    }
}

/// stands in for a locked space's page until Touch ID or the account password opens it
struct LockedSpaceView: View {
    @Environment(\.chromeInk) private var ink
    let space: Space

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.fill")
                .font(.system(size: 30, weight: .semibold))
            Text("\(space.name) is locked")
                .font(.system(size: 17, weight: .semibold))
            Button("Unlock") { Task { await SpaceLock.shared.unlock(space) } }
                .buttonStyle(.glass)
        }
        .foregroundStyle(ink.opacity(0.85))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// the sidebar's tab list while its space is locked
struct LockedTabsNote: View {
    @Environment(\.chromeInk) private var ink
    let space: Space

    var body: some View {
        Button {
            Task { await SpaceLock.shared.unlock(space) }
        } label: {
            Label("Locked — click to unlock", systemImage: "lock.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(ink.opacity(0.55))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
