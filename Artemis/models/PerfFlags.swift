// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import Foundation

/// performance optimisations that one binary can A/B: each is on unless named in
/// `ARTEMIS_PERF_OFF=name,name`
enum PerfFlags {
    private static let disabled: Set<String> = {
        let raw = ProcessInfo.processInfo.environment["ARTEMIS_PERF_OFF"] ?? ""
        return Set(raw.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        })
    }()

    static func on(_ name: String) -> Bool { !disabled.contains(name) }

    /// drag the window from the sidebar's top row instead of an AppKit-derived
    /// titlebar drag region
    static var dragsWindowDirectly: Bool { on("window-drag") }

    /// build only the filmstrip panels that can be on screen, leaving the rest as
    /// empty slots of the same width
    static var windowsFilmstripPanels: Bool { on("filmstrip-window") }

    /// hide (rather than merely make transparent) a mounted page nobody is
    /// looking at, so WebKit stops rendering it
    static var hidesOffscreenPages: Bool { on("hide-offscreen") }

    /// resize the hosted page once a run of layout changes has stopped, instead
    /// of on every frame of an animation
    static var settlesPageResize: Bool { on("settle-resize") }

    /// keep the outgoing page mounted for the length of the crossfade, so the
    /// fade has an opaque page underneath rather than the card's base colour
    static var holdsCrossfadePage: Bool { on("crossfade-hold") }
}
