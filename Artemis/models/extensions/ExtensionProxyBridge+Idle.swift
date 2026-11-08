// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import CoreGraphics
import Foundation

extension ExtensionProxyBridge {
    /// the screen locking and unlocking: the distributed notifications are the only public signal
    static let lockSignals: (center: NotificationCenter, locked: Notification.Name, unlocked: Notification.Name) = (
        DistributedNotificationCenter.default(), .init("com.apple.screenIsLocked"), .init("com.apple.screenIsUnlocked")
    )

    /// seconds since the last input event
    static var secondsSinceInput: TimeInterval {
        CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!)
    }
}
