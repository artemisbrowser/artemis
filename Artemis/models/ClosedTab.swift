// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import Foundation

/// a tab you closed, kept in memory for ⇧⌘T. never persisted: its
/// `interactionState` is only meaningful to the WebKit that produced it
struct ClosedTab: Identifiable {
    /// the closed tab's own id, which a reopened tab takes back
    let id: BrowserTab.ID
    let url: URL
    let title: String
    /// the space it was closed from, so it comes back where it lived
    let spaceID: Space.ID
    /// the folder it was filed in, nil when it sat loose in a section; the name
    /// lets an undo rebuild a folder that has since gone
    let folderID: TabFolder.ID?
    let folderName: String?
    /// its slot among that container's own children
    let index: Int
    let isPinned: Bool
    let pinnedURL: URL?
    let customName: String?
    /// the tab's session blob: its live page's, or the one held while asleep or unrestored
    let interactionState: Any?
    let closedAt: Date
    /// shared by every tab closed in the same act, so one ⇧⌘T or ⌘Z brings a
    /// bulk close back as the one thing it was
    let act: ClosedAct
    /// set for a removed favourite: it goes back into this profile's grid at `index`
    var profileID: Profile.ID? = nil
}

/// one close as the user did it, however many tabs it took. ⌘Z and ⇧⌘T both
/// reopen it whole, and whichever runs first uses it up
final class ClosedAct {
    /// what the Edit menu calls it: "Undo \(name)"
    let name: String
    /// its tabs were filed in the archive, and a redo files them there again
    let archives: Bool
    var isRegistered = false
    /// the splits its tabs were panes of, as they stood when the first one closed
    var splits: [Split] = []

    struct Split {
        let id: UUID
        let root: SplitNode
        let linkSourceID: UUID?
        let linkTargetID: UUID?
    }

    init(name: String, archives: Bool = false) {
        self.name = name
        self.archives = archives
    }
}

/// the folder shape "Close Folder" removed, so one ⇧⌘T rebuilds it whole,
/// including folders that held no tabs
struct ClosedFolder: Identifiable {
    /// one folder in the removed shape. parents precede their children, so
    /// rebuilding in order always finds the parent already there
    struct Node {
        let id: TabFolder.ID
        let name: String
        let isExpanded: Bool
        /// nil for the folder that was closed — it goes back to `container`
        let parent: TabFolder.ID?
        /// its items name the closed tabs, so the next refresh counts them dismissed
        let live: LiveFolder?
    }

    let id = UUID()
    /// the act its tabs were closed under, so the two restore as one
    let act: ClosedAct
    let spaceID: Space.ID
    /// where the closed folder itself sat
    let container: SidebarContainer
    let index: Int
    let nodes: [Node]
    let closedAt: Date
}
