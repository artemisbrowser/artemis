// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import AppKit
import LocalAuthentication

/// how long one device-owner check covers a kind of saved item, strictest first
nonisolated enum UnlockPolicy: String, CaseIterable, Identifiable {
    case everyTime, minute, fiveMinutes, quarterHour, hour, untilQuit, never

    var id: Self { self }

    /// seconds a check stays good for; nil never asks
    var window: TimeInterval? {
        switch self {
        case .everyTime: 0
        case .minute: 60
        case .fiveMinutes: 300
        case .quarterHour: 900
        case .hour: 3600
        case .untilQuit: .infinity
        case .never: nil
        }
    }

    var title: String {
        switch self {
        case .everyTime: "Every time"
        case .minute: "After 1 minute"
        case .fiveMinutes: "After 5 minutes"
        case .quarterHour: "After 15 minutes"
        case .hour: "After 1 hour"
        case .untilQuit: "Until Artemis quits"
        case .never: "Never"
        }
    }

    func isLooser(than other: Self) -> Bool {
        (Self.allCases.firstIndex(of: self) ?? 0) > (Self.allCases.firstIndex(of: other) ?? 0)
    }
}

/// Touch ID, a paired watch or the account password, checked once and accepted by each kind for as long as
/// its own policy allows. Locking the screen, sleeping or switching user forgets the check.
@MainActor
enum OwnerUnlock {
    /// one policy each, app-wide
    enum Kind: String, CaseIterable {
        case passwords, cards, addresses

        var key: String { "unlock" + rawValue.capitalized }

        var standard: UnlockPolicy {
            switch self {
            case .passwords: .fiveMinutes
            // `autofillCardsNeedAuth` turned off, the toggle this replaced, reads as Never
            case .cards: UserDefaults.standard.object(forKey: "autofillCardsNeedAuth") as? Bool == false ? .never : .everyTime
            case .addresses: .never
            }
        }

        var policy: UnlockPolicy {
            let chosen = UserDefaults.standard.string(forKey: key).flatMap(UnlockPolicy.init) ?? standard
            return chosen
        }
    }

    /// the only way to the system sheet; the self-test swaps in its own
    static var check: (String) async -> Bool = { reason in
        let evaluated = LAContext()
        guard (try? await evaluated.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) == true
        else { return false }
        return true
    }
    /// when the last check passed; the self-test backdates it
    static var unlockedAt: Date?
    private static var lockTimer: Timer?

    /// what the system sheet asks for, as settings name it
    static var method: String {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) ? "Touch ID" : "Password"
    }

    static func isUnlocked(_ kind: Kind) -> Bool {
        guard let window = kind.policy.window else { return true }
        return unlockedAt.map { Date().timeIntervalSince($0) < window } ?? false
    }

    /// true once the owner has passed a check `kind`'s policy still accepts, asking for one when it doesn't
    static func authenticate(_ kind: Kind, _ reason: String) async -> Bool {
        _ = forgetting
        if !isUnlocked(kind) {
            guard await check(reason) else { return false }
            unlockedAt = Date()
            scheduleLock()
        }
        return true
    }

    /// the last check is forgotten once no kind's window covers it
    private static func scheduleLock() {
        lockTimer?.invalidate()
        guard let longest = Kind.allCases.compactMap(\.policy.window).max(), longest.isFinite else { return }
        lockTimer = Timer.scheduledTimer(withTimeInterval: max(longest, 1), repeats: false) { _ in
            MainActor.assumeIsolated {
                guard !Kind.allCases.contains(where: isUnlocked) else { return }
                forget()
            }
        }
    }

    private static func forget() {
        unlockedAt = nil
    }

    /// the Mac locking, sleeping, or handing the screen to another user
    static let forgetOn: [(NotificationCenter, Notification.Name)] = [
        (NSWorkspace.shared.notificationCenter, NSWorkspace.willSleepNotification),
        (NSWorkspace.shared.notificationCenter, NSWorkspace.screensDidSleepNotification),
        (NSWorkspace.shared.notificationCenter, NSWorkspace.sessionDidResignActiveNotification),
        (DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsLocked")),
    ]

    private static let forgetting: [NSObjectProtocol] = forgetOn.map { center, name in
        center.addObserver(forName: name, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { forget() }
        }
    }
}
