import Foundation

/// when you separate an off-pinned tab (⌘-click its favicon while it's away from
/// its anchored url), it splits into two tabs — one holding the page you
/// navigated to, one holding the pinned anchor. this picks which of them keeps
/// the pinned slot.
enum PinnedSeparationKeep: String, CaseIterable, Identifiable {
    /// the pinned tab snaps back to its anchor and stays pinned; the page you
    /// navigated to splits off (the original behaviour)
    case pinnedStays
    /// the page you navigated to stays pinned (re-anchored in place); the
    /// original pinned url splits off into its own tab
    case deviationStays

    var id: String { rawValue }
    static let storageKey = "pinnedSeparationKeep"

    static var current: PinnedSeparationKeep {
        UserDefaults.standard.string(forKey: storageKey).flatMap(Self.init) ?? .pinnedStays
    }

    var label: String {
        switch self {
        case .pinnedStays: "Pinned tab stays — page splits off"
        case .deviationStays: "Page stays pinned — original splits off"
        }
    }
}

/// where the tab that splits off lands.
enum PinnedSeparationDestination: String, CaseIterable, Identifiable {
    case pinnedAbove
    case pinnedBelow
    case todayTop
    case todayBottom

    var id: String { rawValue }
    static let storageKey = "pinnedSeparationDestination"

    static var current: PinnedSeparationDestination {
        UserDefaults.standard.string(forKey: storageKey).flatMap(Self.init) ?? .todayBottom
    }

    var label: String {
        switch self {
        case .pinnedAbove: "Pinned — above the original"
        case .pinnedBelow: "Pinned — below the original"
        case .todayTop: "Today — top"
        case .todayBottom: "Today — bottom"
        }
    }
}
