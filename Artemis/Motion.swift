import AppKit
import SwiftUI

/// the app's springs. `bounce` is the overshoot: 0 = critically damped, higher = more spring.
/// it belongs on movement (slides, scale); pure fades stay flat so colour and opacity don't wobble
enum Motion {
    /// macOS's Reduce Motion setting, refreshed when the system setting changes
    /// so every preset below honours it without a check at any call site
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

    /// a spatial preset, flattened under Reduce Motion: the move becomes a short
    /// fade-length ease with no overshoot, so nothing travels across the screen
    private static func moving(_ duration: Double, _ bounce: Double) -> Animation {
        reduceMotion ? .easeOut(duration: 0.12) : .spring(duration: duration, bounce: bounce)
    }

    private static func movingSpring(_ duration: Double, _ bounce: Double) -> Spring {
        reduceMotion ? Spring(duration: 0.12, bounce: 0) : Spring(duration: duration, bounce: bounce)
    }

    /// the sidebar pinning in/out and the edge overlay sliding — the headline
    /// gesture. exposed as a `Spring` (not just an `Animation`) so the AppKit
    /// traffic lights can ride the *exact same physics* via a CASpringAnimation
    /// instead of a hand-matched curve that drifts out of sync — see
    /// TrafficLightAligner. tune the feel here and both follow.
    static var sidebarSpring: Spring { movingSpring(0.42, 0.16) }
    static var sidebar: Animation { .spring(sidebarSpring) }

    /// the collapsed sidebar's edge-hover overlay sliding in at the cursor. keeps
    /// the headline bounce (matches `sidebarSpring`) but its duration is
    /// user-tunable (Settings › Sidebar › Reveal speed). the entrance
    /// overshoots a few px past the cursor; the overlay's hover catchment is
    /// widened to cover that gap (see MainView) so the bounce can't read as the
    /// mouse leaving and dismiss the peek mid-reveal.
    static func sidebarReveal(duration: Double) -> Animation {
        .spring(sidebarRevealSpring(duration: duration))
    }

    /// the same reveal as a `Spring`, so the traffic lights can be handed the
    /// *exact* mass/stiffness/damping SwiftUI is using rather than a curve that
    /// merely looks similar — see TrafficLightAligner
    static func sidebarRevealSpring(duration: Double) -> Spring {
        movingSpring(duration, 0.16)
    }

    /// library ⇄ spaces panel slide, rail-width changes — gentle overshoot
    static var panelSpring: Spring { movingSpring(0.40, 0.18) }
    static var panel: Animation { .spring(panelSpring) }

    /// space carousel snapping to rest after a swipe release. exposed as a
    /// `Spring` (like `sidebarSpring`) because `withAnimation` writes the stored
    /// position straight to the destination — only the physics knows where the
    /// strip actually is mid-settle, which is what a chained swipe must anchor to
    static var carouselSpring: Spring { movingSpring(0.45, 0.22) }

    /// the mini-player panel springing in, settling into a corner after a flick,
    /// or reshaping to its video. a `Spring` because AppKit can only ease a
    /// window frame, so `PanelMotion` steps this one on the display clock
    static var pipSpring: Spring { movingSpring(0.42, 0.18) }
    static var carousel: Animation { .spring(carouselSpring) }

    /// the backdrop colour settling after a swipe release — eased, no bounce, so
    /// it can't overshoot the target index and momentarily blend a third space's
    /// colour. paired with `carousel`: the filmstrip springs, the colour glides
    static var spaceColorSettle: Animation { .easeOut(duration: reduceMotion ? 0.2 : 0.42) }

    /// small accents that should pop: selection, chevrons, inline reveals
    static var pop: Animation { moving(0.30, 0.34) }

    /// the drag ghost reshaping between a tab row and a favourite tile — slower
    /// and springier than `pop` so the morph reads as a gradual, bouncy settle
    static var morph: Animation { moving(0.5, 0.36) }

    /// the url pill's glass growing into the address bar and shrinking back
    static var address: Animation { moving(0.25, 0.18) }

    /// hovers and quick toggles — lively but barely overshoots, so the
    /// highlight tracks the cursor without feeling springy
    static var hover: Animation { moving(0.22, 0.10) }

    /// a window leaving: a short accelerating fade with a slight shrink, no
    /// bounce, so a close never lingers
    static var exitDuration: Double { reduceMotion ? 0.1 : 0.15 }

    /// opacity / colour cross-fades — no bounce, a wobble in a gradient reads
    /// as a glitch, not life
    static let fade = Animation.easeInOut(duration: 0.2)

    /// the web card swapping pages on a space switch — quick, so content keeps
    /// up with the slide; both pages are already painted, so it's a clean blend
    static let contentSwap = Animation.easeInOut(duration: 0.08)
}
