// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import AppKit

/// the last click or key press Artemis itself received, and the view it landed in: a page can't
/// forge either, unlike its own `navigator.userActivation`
@MainActor
enum UserGesture {
    private static var at = Date.distantPast
    /// the view hit by a click, or the first responder for a key; a held key's repeats don't count
    private static weak var target: NSView?
    private static var monitor: Any?

    static func watch() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .keyDown]) { event in
            MainActor.assumeIsolated {
                guard event.type != .keyDown || !event.isARepeat else { return }
                let window = event.window
                at = Date()
                target =
                    event.type == .keyDown
                    ? window?.firstResponder as? NSView
                    // the frame view takes window coordinates, as AppKit's own hit test does
                    : window?.contentView?.superview?.hitTest(event.locationInWindow)
            }
            return event
        }
    }

    /// when the last press inside `view` was made, if it was within `seconds`
    static func recent(in view: NSView, within seconds: TimeInterval) -> Date? {
        guard let target, target.isDescendant(of: view), Date().timeIntervalSince(at) < seconds else { return nil }
        return at
    }
}
