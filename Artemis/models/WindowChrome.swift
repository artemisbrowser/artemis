import AppKit
import SwiftUI

/// The rim of window between the edge of Artemis and the page itself.
///
/// The house style floats the page as a card on the space's backdrop, which is
/// what makes a space's colour visible at all. But that rim is taste, not
/// physics: a power user reading code all day wants every pixel, and at 0 the
/// page simply *is* the window. So it's one number, tunable, and everything that
/// touches the rim — the card's padding, its corner rounding, the sidebar/page
/// gap, the peeking overlay's width — derives from it rather than repeating a
/// hard-coded 10.
enum WindowChrome {
    static let edgeInsetKey = "windowEdgeInset"
    static let defaultEdgeInset: Double = 10
    /// 0 = full bleed; past ~16 the card starts looking lost on its backdrop
    static let range: ClosedRange<Double> = 0...16

    /// the narrowest the sidebar/page gap can be and still be grabbable. below
    /// this the resize strip moves onto the page's leading edge instead, so a
    /// thin rim never costs you the ability to resize the sidebar
    static let minGrabWidth: Double = 6

    /// the macOS 26 window corner radius this app's windows get — the VISIBLE
    /// one. a constant on purpose: measuring the theme frame's layer at runtime
    /// proved unreliable twice over — it reports 22 in some states and 0 in
    /// others (tiling, opacity, timing), and the 22 it reports for a normal
    /// window doesn't even match the mask the system actually clips with, which
    /// is Tahoe's default 16 (verified against the rendered corner in a
    /// screenshot). a corner rule fed a wrong or flickering outer pinches the
    /// rim at the corners — "not marrying up". the rim-0 case needs no value at
    /// all (the window's own mask rounds a flush card), so this only shapes
    /// rims 1–16
    static let outerWindowRadius: Double = 16

    /// the rim at which the card would square off. independent of `range` so
    /// narrowing the slider steepens nothing: the widest rim still keeps a
    /// visible corner
    static let squaringInset: Double = 24

    /// rim 0 returns 0, so the window's own mask gives a flush card the system's rounding, tiled
    /// or not; past that the radius falls linearly from the outer radius to square at `squaringInset`
    static func cardRadius(inset: Double) -> Double {
        guard inset > 0 else { return 0 }
        return outerWindowRadius * (1 - min(inset, squaringInset) / squaringInset)
    }

    /// pulls a rim saved while the slider ran wider back inside `range`, so a
    /// stale value can't outlive the slider that could still show it
    static func clampStoredEdgeInset() {
        guard let stored = UserDefaults.standard.object(forKey: edgeInsetKey) as? Double,
            !range.contains(stored)
        else { return }
        UserDefaults.standard.set(
            min(max(stored, range.lowerBound), range.upperBound), forKey: edgeInsetKey)
    }

    /// current value, for code outside a `View` (which uses `@AppStorage`)
    static var edgeInset: Double {
        UserDefaults.standard.object(forKey: edgeInsetKey) as? Double ?? defaultEdgeInset
    }
}
