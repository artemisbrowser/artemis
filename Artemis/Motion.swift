// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import AppKit
import SwiftUI

/// the app's springs. `bounce` is the overshoot: 0 = critically damped, higher = more spring.
/// it belongs on movement (slides, scale); pure fades stay flat so colour and opacity don't wobble
enum Motion {
    /// macOS's Reduce Motion setting, kept current; every preset below honours it
    private(set) static var reduceMotion: Bool = {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            }
        }
        return NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }()

    /// a spatial preset; under Reduce Motion a short ease with no overshoot
    private static func moving(_ duration: Double, _ bounce: Double) -> Animation {
        reduceMotion ? .easeOut(duration: 0.12) : .spring(duration: duration, bounce: bounce)
    }

    private static func movingSpring(_ duration: Double, _ bounce: Double) -> Spring {
        reduceMotion ? Spring(duration: 0.12, bounce: 0) : Spring(duration: duration, bounce: bounce)
    }

    /// the sidebar pinning in/out. a `Spring` so `BrowserShell` can drive the
    /// AppKit shell with the same physics SwiftUI uses
    static var sidebarSpring: Spring { movingSpring(0.42, 0.16) }
    static var sidebar: Animation { .spring(sidebarSpring) }

    /// the collapsed sidebar's edge-hover overlay sliding in: `sidebarSpring`'s
    /// bounce over the user's Reveal speed
    static func sidebarRevealSpring(duration: Double) -> Spring {
        movingSpring(duration, 0.16)
    }

    /// library ⇄ spaces panel slide, rail-width changes — gentle overshoot
    static var panelSpring: Spring { movingSpring(0.40, 0.18) }
    static var panel: Animation { .spring(panelSpring) }

    /// space carousel snapping to rest after a swipe release. a `Spring` so a
    /// chained swipe can ask where the strip is mid-settle
    static var carouselSpring: Spring { movingSpring(0.45, 0.22) }

    /// the mini-player panel springing in, settling into a corner, or reshaping
    /// to its video; `PanelMotion` steps it on the display clock
    static var pipSpring: Spring { movingSpring(0.42, 0.18) }
    static var carousel: Animation { .spring(carouselSpring) }

    /// the backdrop colour settling after a swipe release. no bounce: an
    /// overshoot would blend in a third space's colour
    static var spaceColorSettle: Animation { .easeOut(duration: reduceMotion ? 0.2 : 0.42) }

    /// small accents that should pop: selection, chevrons, inline reveals
    static var pop: Animation { moving(0.30, 0.34) }

    /// the drag ghost reshaping between a tab row and a favourite tile
    static var morph: Animation { moving(0.5, 0.36) }

    /// the url pill's glass growing into the address bar and shrinking back
    static var address: Animation { moving(0.25, 0.18) }

    /// hovers and quick toggles
    static var hover: Animation { moving(0.22, 0.10) }

    /// a window leaving: a short accelerating fade with a slight shrink
    static var exitDuration: Double { reduceMotion ? 0.1 : 0.15 }

    /// a view sliding in from `edge`; a plain fade under Reduce Motion
    static func slide(_ edge: Edge) -> AnyTransition {
        reduceMotion ? .opacity : .move(edge: edge).combined(with: .opacity)
    }

    /// a view growing in from `scale`; a plain fade under Reduce Motion
    static func grow(from scale: CGFloat, anchor: UnitPoint = .center) -> AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: scale, anchor: anchor))
    }

    /// opacity and colour cross-fades, with no bounce
    static let fade = Animation.easeInOut(duration: 0.2)

    /// the web card swapping pages, eased in and out by `PageStackView`
    static let contentSwapDuration: TimeInterval = 0.08
}
