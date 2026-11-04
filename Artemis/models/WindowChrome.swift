import AppKit
import SwiftUI

/// the rim of backdrop between the window's edge and the page card, in points.
/// the card's padding, corner radius, sidebar gap and peek overlay all derive
/// from this one setting; at 0 the page fills the window
enum WindowChrome {
    static let edgeInsetKey = "windowEdgeInset"
    static let defaultEdgeInset: Double = 10
    /// 0 = full bleed; past ~16 the card starts looking lost on its backdrop
    static let range: ClosedRange<Double> = 0...16

    /// the narrowest grabbable sidebar/page gap; below it the resize strip
    /// moves onto the page's leading edge
    static let minGrabWidth: Double = 6

    /// the corner radius macOS 26 visibly clips a window to. never read it from
    /// the theme frame's layer: that reports 22 or 0 depending on state, not
    /// the 16 the mask uses
    static let outerWindowRadius: Double = 16

    /// the rim at which the card would square off; deliberately past `range`, so
    /// the widest rim still keeps a visible corner
    static let squaringInset: Double = 24

    /// rim 0 returns 0, so the window's own mask gives a flush card the system's rounding, tiled
    /// or not; past that the radius falls linearly from the outer radius to square at `squaringInset`
    static func cardRadius(inset: Double) -> Double {
        guard inset > 0 else { return 0 }
        return outerWindowRadius * (1 - min(inset, squaringInset) / squaringInset)
    }

    /// pulls a stored rim back inside `range`
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
