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

    /// the selected row's glass is an AppKit view faded by Core Animation, so a
    /// selection change re-renders its rows once instead of every frame of the fade
    static var animatesLitPaneInLayer: Bool { on("lit-pane") }

    /// a hidden page's timers are throttled harder the longer it stays hidden, as in Safari
    static var backsOffHiddenTimers: Bool { on("timer-backoff") }

    /// a restored tab makes its web view on first use, not at launch
    static var makesWebViewsLazily: Bool { on("lazy-webview") }

    /// launch builds one session manager, not a second that warms the restored page early
    static var buildsOneSeed: Bool { on("one-seed") }

    /// launch makes the restored page's web view once the window is visible, while its rule lists load
    static var startsLaunchPageEarly: Bool { on("early-page") }

    /// a memory warning sleeps the background tabs past the newest few, not only a critical one
    static var sleepsOnWarning: Bool { on("sleep-warning") }

    /// the newest few background tabs keep the full idle wait; the rest sleep after a third of it
    static var keepsNewestAwake: Bool { on("sleep-newest") }

    /// pins and favourites sleep when no window shows their space, and a space's own page only
    /// stays awake beside a window's space
    static var sleepsFarKeepers: Bool { on("sleep-keepset") }

    /// unsent form text, a download, an app badge, a site allowed to notify or requests in flight
    /// two checks running keep a tab awake
    static var sleepExemptions: Bool { on("sleep-exempt") }

    /// closing the last browser window puts every tab to sleep
    static var sleepsWithNoWindow: Bool { on("sleep-close") }

    /// Low Power Mode halves the idle wait and keeps fewer tabs awake
    static var sleepsHarderOnLowPower: Bool { on("sleep-lowpower") }

    /// a still of the page, kept while it sleeps, to stand in while it wakes
    static var keepsSleepFrame: Bool { on("sleep-frame") }

    /// the command bar answers ↵ itself, so its field never ends editing in the key's turn
    static var takesReturnBeforeField: Bool { on("bar-return") }

    /// a closing command bar fades as it stood, re-rendered only once it unmounts
    static var leavesClosingBarAlone: Bool { on("bar-quiet") }

    /// ⇧⌘[ ⇧⌘] switch tabs from the key monitor, before AppKit's menu search and the page
    static var reservesTabKeys: Bool { on("tab-keys") }

    /// the space pager slides as one Core Animation layer outside the sidebar's graph
    static var slidesPagerInLayer: Bool { on("pager-layer") }
}
