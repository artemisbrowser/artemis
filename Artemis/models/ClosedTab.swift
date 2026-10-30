import Foundation

/// A tab you closed, kept just long enough to change your mind.
///
/// It stores the page's whole WebKit session — the back/forward list and where
/// you were scrolled to — rather than only its url, because reopening a tab and
/// landing at the top of the page with no history is not the same as getting it
/// back. That blob is opaque and only meaningful to the WebKit that produced it,
/// which is the reason this stack lives in memory for the length of the session
/// rather than on disk: a stale blob from a previous WebKit is worth nothing,
/// and the archive already covers "what was I looking at yesterday".
struct ClosedTab: Identifiable {
    let id = UUID()
    let url: URL
    let title: String
    /// the space it was closed from, so it comes back where it lived
    let spaceID: Space.ID
    /// the folder it was filed in, so it comes back inside it rather than at
    /// the foot of the space. nil when it sat loose in a section; the name comes
    /// too, so undoing "close this folder" rebuilds the folder as well
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

/// the folder shape "Close Folder" removed, kept so one ⇧⌘T rebuilds it whole.
///
/// The per-tab record names only the folder a tab sat in directly, which is
/// enough to put tabs back but loses everything with nothing in it — the empty
/// folders, and the nested ones whose only contents were more folders.
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
