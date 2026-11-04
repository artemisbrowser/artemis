import SwiftUI

/// a context menu as data, so the menu and VoiceOver's actions come from one list
struct MenuEntry {
    enum Kind {
        case button(() -> Void)
        case divider
        /// a line of text heading the menu
        case header
        /// spoken as "<spokenPrefix> <child title>", one action per child
        case submenu([MenuEntry], spokenPrefix: String)
    }

    var title = ""
    var systemImage: String?
    var role: ButtonRole?
    let kind: Kind

    static let divider = MenuEntry(kind: .divider)

    static func button(
        _ title: String, _ systemImage: String? = nil, role: ButtonRole? = nil, action: @escaping () -> Void
    ) -> MenuEntry {
        MenuEntry(title: title, systemImage: systemImage, role: role, kind: .button(action))
    }
}

/// the entries as a menu's items, in order
struct MenuEntriesView: View {
    let entries: [MenuEntry]

    var body: some View {
        ForEach(entries.indices, id: \.self) { index in
            let entry = entries[index]
            switch entry.kind {
            case .button(let action):
                Button(role: entry.role, action: action) { label(entry) }
            case .divider:
                Divider()
            case .header:
                Text(entry.title)
            case .submenu(let children, _):
                Menu { MenuEntriesView(entries: children) } label: { label(entry) }
            }
        }
    }

    @ViewBuilder private func label(_ entry: MenuEntry) -> some View {
        if let systemImage = entry.systemImage {
            Label(entry.title, systemImage: systemImage).labelStyle(.titleAndIcon)
        } else {
            Text(entry.title)
        }
    }
}

/// the same entries as accessibility actions, which only take title-string buttons
struct MenuEntryActions: View {
    let entries: [MenuEntry]

    var body: some View {
        ForEach(Array(Self.actions(entries).enumerated()), id: \.offset) { _, action in
            Button(action.title, action: action.perform)
        }
    }

    static func actions(_ entries: [MenuEntry], prefix: String? = nil) -> [(title: String, perform: () -> Void)] {
        entries.flatMap { entry -> [(title: String, perform: () -> Void)] in
            switch entry.kind {
            case .button(let perform): [(prefix.map { "\($0) \(entry.title)" } ?? entry.title, perform)]
            case .divider, .header: []
            case .submenu(let children, let spokenPrefix): actions(children, prefix: spokenPrefix)
            }
        }
    }
}
