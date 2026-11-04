// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import AppKit

/// where a modified link click opens. matched on the exact set of modifiers
/// held, so ⇧⌘ is never read as ⌘; a middle click counts as ⌘ held
enum LinkClick: Equatable {
    case peek, backgroundTab, foregroundTab, split, scout

    static func route(_ flags: NSEvent.ModifierFlags, middle: Bool = false) -> LinkClick? {
        var held = flags.intersection([.shift, .control, .option, .command])
        if middle { held.insert(.command) }
        switch held {
        case .shift: return .peek
        case .command: return .backgroundTab
        case [.shift, .command]: return .foregroundTab
        case .option: return .split
        case [.option, .command]: return .scout
        default: return nil
        }
    }
}
