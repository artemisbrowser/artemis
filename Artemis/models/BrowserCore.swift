// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import AppKit
import WebKit

/// what every browser window shares: the profiles, the spaces and their tabs, the
/// closed tabs ⇧⌘T reopens. a `TabManager` is per window and holds its selection and ⌘Z
@Observable
@MainActor
final class BrowserCore {
    static let shared = BrowserCore()

    /// the default profile is always first
    var profiles: [Profile] = []
    var spaces: [Space] = []
    /// tabs you closed, newest first — the undo stack behind ⇧⌘T
    var closedTabs: [ClosedTab] = []
    /// folder shapes removed by "Close Folder", newest first
    var closedFolders: [ClosedFolder] = []
    /// sites waiting on an answer about the camera, microphone or location
    var permissionQueue: [PermissionRequest] = []

    let continuity = Continuity()
    /// the floating mini-player
    let miniPlayer = MiniPlayer()

    /// pages owned by a window rather than a space (Scout, Peek), held weakly
    /// here so any window can enumerate them, even before one registers
    let windowLocal = NSHashTable<BrowserTab>.weakObjects()

    /// the space to reopen on next launch — whichever window last chose one
    var persistedSpaceID: Space.ID?

    @ObservationIgnored var saveTask: Task<Void, Never>?
    @ObservationIgnored var archiveTimer: Timer?
    @ObservationIgnored var memoryPressureSource: DispatchSourceMemoryPressure?
    @ObservationIgnored var linkHoverReporter: LinkHoverReporter?
    @ObservationIgnored var mediaStateReporter: MediaStateReporter?
    /// true once a manager has loaded the session and installed the app-wide
    /// hooks, so later windows attach to what is already running
    @ObservationIgnored var isLoaded = false
}

extension BrowserCore {
    var defaultProfile: Profile { profiles.first { $0.isDefault } ?? profiles[0] }

    func profile(_ id: Profile.ID?) -> Profile? {
        profiles.first { $0.id == id }
    }

    /// the profile `space` browses as
    func profile(of space: Space) -> Profile {
        profile(space.profileID) ?? defaultProfile
    }

    /// every profile's favourites
    var allEssentials: [BrowserTab] { profiles.flatMap(\.essentials) }
}

/// which chrome a window wears — the full browser, the compact Scout bar, or an
/// incognito window
enum WindowKind {
    case main
    /// a link glanced at in its own window, in a space private to it
    case scout
    /// a full browser window over one throwaway space and jar, never saved
    case incognito
}
