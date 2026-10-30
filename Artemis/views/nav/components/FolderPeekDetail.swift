/// what the second line of a row in a folder's hover panel says, if anything
enum FolderPeekDetail: String, CaseIterable, Identifiable {
    case none
    case lastVisited
    case domain

    static let storageKey = "folderPeekDetail"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: "Nothing"
        case .lastVisited: "Last visited"
        case .domain: "Site"
        }
    }
}
