// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import SwiftUI

/// the panel that hangs beside a folded folder while the cursor rests on it:
/// every tab filed under it, nested folders flattened in, over a search field
struct FolderPeek: View {
    @Environment(TabManager.self) private var tabManager
    @Environment(\.chromeInk) private var ink
    @AppStorage(FolderPeekDetail.storageKey) private var detailRaw = FolderPeekDetail.none.rawValue
    let folder: TabFolder
    var dismiss: () -> Void = {}
    @State private var query = ""
    /// height before any search; a search never shrinks the panel out from under the
    /// cursor, which would end the hover and close it
    @State private var restingHeight: CGFloat?
    @FocusState private var isSearchFocused: Bool

    static let width: CGFloat = 268
    /// tall enough for eight rows before the list scrolls, plus the field
    static let maxHeight: CGFloat = 348
    private static let listHeight: CGFloat = 300

    private var detail: FolderPeekDetail { FolderPeekDetail(rawValue: detailRaw) ?? .none }

    /// the folder's rows in draw order, nested folders flattened in and each
    /// split's panes as one row, kept whole when any pane matches the query
    private var rows: [[BrowserTab]] {
        let space = tabManager.currentSpace
        let byID = Dictionary(space.tabs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var rows: [[BrowserTab]] = []
        var lastGroup: SplitGroup.ID?
        for tab in space.tabIDs(under: .folder(folder.id)).compactMap({ byID[$0] }) {
            let group = space.splitGroup(containing: tab.id)?.id
            if let group, group == lastGroup {
                rows[rows.count - 1].append(tab)
            } else {
                rows.append([tab])
            }
            lastGroup = group
        }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return rows }
        return rows.filter { panes in
            panes.contains { tab in
                tab.displayTitle.localizedCaseInsensitiveContains(trimmed)
                    || (tab.url?.absoluteString.localizedCaseInsensitiveContains(trimmed) ?? false)
            }
        }
    }

    var body: some View {
        VStack(spacing: 6) {
            searchField
            if rows.isEmpty {
                Text(query.isEmpty ? "Empty folder" : "No tabs match that search")
                    .font(.system(size: 12))
                    .foregroundStyle(ink.opacity(0.45))
                    .padding(.vertical, 10)
                    // a search holds the panel at its resting height; the message centres in that room
                    .frame(maxWidth: .infinity, maxHeight: query.isEmpty ? nil : .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(rows, id: \.first?.id) { panes in
                            FolderPeekRow(panes: panes, detail: detail) { tab in
                                tabManager.clearSelection()
                                tabManager.selectedTabID = tab.id
                                tabManager.isCommandBarVisible = false
                                dismiss()
                            }
                        }
                    }
                }
                .frame(maxHeight: Self.listHeight)
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .padding(6)
        .frame(width: Self.width)
        .frame(height: query.isEmpty ? nil : restingHeight, alignment: .top)
        .onGeometryChange(for: CGFloat.self, of: \.size.height) { height in
            if query.isEmpty { restingHeight = height }
        }
        .chromeGlass(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
        // the panel comes up ready to type; focus has to wait a runloop turn for
        // the field to exist
        .onAppear { DispatchQueue.main.async { isSearchFocused = true } }
        .onKeyPress(.escape) {
            dismiss()
            return .handled
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(ink.opacity(0.5))
            TextField(
                "Search", text: $query,
                prompt: Text("Search \(folder.name)…").foregroundStyle(ink.opacity(0.45))
            )
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .foregroundStyle(ink)
            .focused($isSearchFocused)
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        // flat: the panel is already glass
        .background(Capsule().fill(ink.opacity(0.09)))
        .contentShape(.rect)
        .onTapGesture { isSearchFocused = true }
    }
}

/// one row in the folder's panel: a tab, or a split's panes side by side with
/// hairlines between, each with favicon, title, and the setting's second line
private struct FolderPeekRow: View {
    @Environment(\.chromeInk) private var ink
    let panes: [BrowserTab]
    let detail: FolderPeekDetail
    let pick: (BrowserTab) -> Void
    @State private var isHovering = false

    private func subtitle(_ tab: BrowserTab) -> String? {
        switch detail {
        case .none: nil
        case .lastVisited: tab.lastAccessed.formatted(.relative(presentation: .named))
        case .domain: tab.url?.host()
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(panes.enumerated()), id: \.element.id) { i, tab in
                if i > 0 {
                    Rectangle().fill(ink.opacity(0.18)).frame(width: 1, height: 16)
                }
                pane(tab)
            }
        }
        .background(RowHighlight(opacity: isHovering ? 0.09 : 0))
        .onHover { isHovering = $0 }
        .animation(Motion.hover, value: isHovering)
    }

    private func pane(_ tab: BrowserTab) -> some View {
        let subtitle = subtitle(tab)
        return HStack(spacing: 8) {
            if let favicon = tab.favicon {
                Image(nsImage: favicon)
                    .resizable().scaledToFit()
                    .frame(width: 16, height: 16)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                Image(systemName: "globe")
                    .font(.system(size: 12))
                    .foregroundStyle(ink.opacity(0.6))
                    .frame(width: 16, height: 16)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(tab.displayTitle)
                    .font(.system(size: 13))
                    .foregroundStyle(ink.opacity(0.9))
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(ink.opacity(0.45))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, subtitle == nil ? 6 : 5)
        .frame(maxWidth: .infinity)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { pick(tab) }
        .onTapGesture { pick(tab) }
    }
}
