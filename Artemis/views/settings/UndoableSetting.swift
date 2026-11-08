// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import AppKit
import SwiftUI

extension Binding where Value: Equatable {
    /// a Settings control whose change ⌘Z takes back through this same binding, on the Settings
    /// window's own stack; `stack` stands in for that window's, for the suite
    func undoable(_ setting: String, on stack: UndoManager? = nil) -> Binding {
        Binding(
            get: { wrappedValue },
            set: { new in
                let old = wrappedValue
                guard new != old else { return }
                SettingChange.register(setting, on: stack) { undoable(setting, on: stack).wrappedValue = old }
                wrappedValue = new
            })
    }
}

private enum SettingChange {
    /// the last change registered, so one slider drag stays one undo
    private static var last: (setting: String, stack: ObjectIdentifier, at: Date)?

    static func register(_ setting: String, on given: UndoManager?, inverse: @escaping () -> Void) {
        // a popover or sheet's change belongs to the window it hangs off
        let window = NSApp.keyWindow.map { $0.sheetParent ?? $0.parent ?? $0 }
        guard let stack = given ?? (BrowserWindows.shared.manager(for: window) == nil ? window?.undoManager : nil)
        else { return }
        // a replayed change ends any drag it would otherwise join
        if stack.isUndoing || stack.isRedoing {
            last = nil
        } else if NSEvent.pressedMouseButtons != 0, let last, last.setting == setting,
            last.stack == ObjectIdentifier(stack), -last.at.timeIntervalSinceNow < 1
        {
            self.last?.at = .now
            return
        } else {
            last = (setting, ObjectIdentifier(stack), .now)
        }
        // the undo shows the pane the change was made on
        let pane = UserDefaults.standard.string(forKey: SettingsView.paneKey)
        let (profile, page) = (ProfilesNavigator.shared.selected, ProfilesNavigator.shared.page)
        stack.registerUndo(withTarget: ProfilesNavigator.shared) { navigator in
            UserDefaults.standard.set(pane, forKey: SettingsView.paneKey)
            navigator.selected = profile
            navigator.page = page
            inverse()
        }
        stack.setActionName("Change \(setting)")
    }
}
