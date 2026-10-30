import SwiftUI

/// a browsing context — its own tabs (pinned + today), icon, and appearance.
/// switching spaces swaps the whole tab set
@Observable
final class Space: Identifiable {
    let id: UUID
    var name: String
    var icon: String  // SF Symbol name or emoji glyph
    var appearance: SpaceAppearance
    var tabs: [BrowserTab]
    var selectedTabID: BrowserTab.ID?
    /// when true the pinned section is folded away under the space header
    var pinnedCollapsed = false
    /// Touch ID or the account password opens it; see `SpaceLock`
    var requiresUnlock = false

    /// the sidebar tree: `tabs` says which tabs the space has, these say where
    /// they sit and which folders hold them. `normalizeTree()` keeps them in step
    var folders: [TabFolder] = []
    var pinnedEntries: [SidebarEntry] = []
    var todayEntries: [SidebarEntry] = []

    /// the split views in this space — each tiles 2–4 of its tabs together and
    /// shows as one grouped block in the sidebar. a tab belongs to at most one
    /// group; the group's members are kept contiguous in `tabs` so the block
    /// renders as a single run
    var splitGroups: [SplitGroup] = []

    /// the identity this space browses as — its cookies, favourites, history and
    /// passwords. `TabManager.setProfile` rebuilds the tabs' web views when it changes
    var profileID: Profile.ID

    init(
        id: UUID = UUID(),
        name: String,
        icon: String,
        appearance: SpaceAppearance = SpaceAppearance(),
        tabs: [BrowserTab] = [],
        profileID: Profile.ID = Profile.defaultID
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.appearance = appearance
        self.tabs = tabs
        self.profileID = profileID
        normalizeTree()
    }

    var pinnedTabs: [BrowserTab] { tabs.filter(\.isPinned) }
    var todayTabs: [BrowserTab] { tabs.filter { !$0.isPinned } }

    var selectedTab: BrowserTab? {
        tabs.first { $0.id == selectedTabID }
    }

    /// the split group a tab belongs to, if any (a tab is in at most one)
    func splitGroup(containing id: BrowserTab.ID) -> SplitGroup? {
        splitGroups.first { $0.contains(id) }
    }

    /// resolve a group's pane ids to their live tabs, in pane order, skipping any
    /// that no longer exist in the space
    func tabs(in group: SplitGroup) -> [BrowserTab] {
        group.tabIDs.compactMap { id in tabs.first { $0.id == id } }
    }
}
