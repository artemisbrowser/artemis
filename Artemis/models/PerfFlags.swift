import Foundation

/// Env-var switches for the performance work, so an A/B can be run against a
/// *single* binary.
///
/// Building twice to compare an optimisation sounds fine until the two builds
/// disagree for reasons that have nothing to do with the change (a warm page
/// cache, a different compile, the machine getting busier). Every optimisation
/// that could plausibly be wrong lands behind a flag here, defaults to on, and
/// gets turned off with `ARTEMIS_PERF_OFF=name,name` for the control run. Once a
/// change has proven itself the flag can go.
enum PerfFlags {
    private static let disabled: Set<String> = {
        let raw = ProcessInfo.processInfo.environment["ARTEMIS_PERF_OFF"] ?? ""
        return Set(raw.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        })
    }()

    static func on(_ name: String) -> Bool { !disabled.contains(name) }

    /// drag the window from the sidebar's top row instead of letting AppKit
    /// derive a titlebar drag region, which it redid on every display cycle by
    /// walking SwiftUI's whole responder tree
    static var dragsWindowDirectly: Bool { on("window-drag") }

    /// build only the filmstrip panels that can be on screen, leaving the rest as
    /// empty slots of the same width — the strip's HStack measured every space's
    /// full tab list on every layout pass
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
