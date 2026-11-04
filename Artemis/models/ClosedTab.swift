import Foundation

/// a tab you closed, kept in memory for ⇧⌘T. never persisted: its
/// `interactionState` is only meaningful to the WebKit that produced it
struct ClosedTab: Identifiable {
    let id = UUID()
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
    /// `WKWebView.interactionState`, or nil for a tab that was asleep when it
    /// was closed (a hibernated tab has no live session to capture)
    let interactionState: Any?
    let closedAt: Date
    /// shared by every tab closed in the same act, so one ⇧⌘T brings a bulk
    /// close back as the one thing it was. nil for an ordinary single close
    let undoGroup: UUID?
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
    }

    let id = UUID()
    /// the undo group its tabs were closed under, so the two restore as one act
    let undoGroup: UUID
    let spaceID: Space.ID
    /// where the closed folder itself sat
    let container: SidebarContainer
    let index: Int
    let nodes: [Node]
    let closedAt: Date
}
