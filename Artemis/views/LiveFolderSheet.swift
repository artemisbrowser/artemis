// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import SwiftUI

/// what New Live Folder is about to make, and where in the sidebar it goes
@Observable
final class LiveFolderDraft {
    enum Kind: CaseIterable { case github, feed }

    struct Found: Identifiable, Equatable {
        let url: URL
        let title: String
        var id: URL { url }
    }

    var kind = Kind.github
    var queries: Set<GitHubQuery> = [.created, .reviewRequested]
    var repo = ""
    /// an edit drops what the last search found
    var address = "" {
        didSet {
            guard address != oldValue else { return }
            found = nil
            chosen = nil
        }
    }
    /// the feeds the last search of `address` confirmed, in page order; nil before one
    var found: [Found]?
    var chosen: URL?
    var isSearching = false
    let container: SidebarContainer
    let index: Int?

    /// `page`, when it's a web page, starts the feed search's address
    init(in container: SidebarContainer = .section(.today), at index: Int? = nil, page: URL? = nil) {
        self.container = container
        self.index = index
        if let page, ["http", "https"].contains(page.scheme?.lowercased()) { address = page.absoluteString }
    }

    /// what was typed, as a web address; a bare host gets https
    var addressURL: URL? {
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let url = URL(string: text.contains("://") ? text : "https://" + text),
            ["http", "https"].contains(url.scheme?.lowercased()), url.host()?.isEmpty == false
        else { return nil }
        return url
    }

    /// `owner/name` from a name or a github.com address; nil when blank, "" when unreadable
    var repoFilter: String? {
        let text = repo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let path = text.contains("github.com") ? text : "https://github.com/" + text
        let url = URL(string: path.contains("://") ? path : "https://" + path)
        return url.flatMap(GitHub.repository).map { "\($0.owner)/\($0.name)" } ?? ""
    }

    var canCreate: Bool {
        switch kind {
        case .github: !queries.isEmpty && repoFilter != ""
        case .feed: chosen != nil && !isSearching
        }
    }

    /// one search at a time; its result is kept only while the address still reads the same
    func find(in space: Space) async {
        guard !isSearching, let url = addressURL else { return }
        isSearching = true
        let feeds = await Feeds.discover(from: url, in: space).map { Found(url: $0.url, title: $0.title) }
        isSearching = false
        guard addressURL == url else { return }
        found = feeds
        chosen = feeds.first?.url
    }

    func create(in manager: TabManager) {
        let space = manager.currentSpace
        var container = container
        if case .folder(let id) = container, space.folder(id) == nil { container = .section(.today) }
        switch kind {
        case .github:
            let chosen = GitHubQuery.allCases.filter(queries.contains)
            let base =
                chosen.count == 1 ? chosen[0].title : chosen.contains(.assignedIssues) ? "GitHub" : "Pull Requests"
            let repo = repoFilter
            let name = repo.flatMap { $0.split(separator: "/").last }.map { "\(base) · \($0)" } ?? base
            manager.newLiveFolder(
                named: name, sources: chosen.map { .github($0, repo: repo) }, in: container, at: index)
        case .feed:
            guard let feed = found?.first(where: { $0.url == chosen }) else { return }
            let name = feed.title.isEmpty ? (feed.url.host() ?? "Feed") : feed.title
            manager.newLiveFolder(named: name, sources: [.feed(feed.url)], in: container, at: index)
        }
        manager.liveFolderDraft = nil
    }
}

/// New Live Folder: GitHub lists signed in through the space's profile, or a feed found from an
/// address. the folder fills itself from then on
struct LiveFolderSheet: View {
    @Environment(TabManager.self) private var tabManager
    @Bindable var draft: LiveFolderDraft
    @FocusState private var addressFocused: Bool

    private static let queryLabels: [(GitHubQuery, String)] = [
        (.created, "Pull requests I opened"),
        (.reviewRequested, "Reviews requested from me"),
        (.teamReviewRequested, "Reviews requested from my team"),
        (.assignedIssues, "Issues assigned to me"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Live Folder")
                .font(.system(size: 15, weight: .semibold))

            HStack(spacing: 4) {
                ForEach(LiveFolderDraft.Kind.allCases, id: \.self) { kind in
                    Button { draft.kind = kind } label: {
                        Text(kind == .github ? "GitHub" : "Feed")
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(.primary.opacity(draft.kind == kind ? 0.14 : 0)))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(draft.kind == kind ? .isSelected : [])
                }
            }
            .animation(Motion.hover, value: draft.kind)

            switch draft.kind {
            case .github: github
            case .feed: feed
            }

            HStack {
                Button("Cancel") { tabManager.liveFolderDraft = nil }
                    .buttonStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary.opacity(0.6))
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button { draft.create(in: tabManager) } label: {
                    Text("Create")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(
                            Capsule().fill(
                                draft.canCreate ? Color.accentColor.opacity(0.9) : Color.primary.opacity(0.12)))
                        .foregroundStyle(draft.canCreate ? .white : .primary.opacity(0.4))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!draft.canCreate)
            }
            .padding(.top, 2)
        }
        .padding(18)
        .frame(width: 400)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
        .shadow(color: .black.opacity(0.35), radius: 24, y: 8)
        .animation(Motion.pop, value: draft.kind)
    }

    @ViewBuilder
    private var github: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Self.queryLabels, id: \.0) { query, label in
                Toggle(
                    label,
                    isOn: Binding(
                        get: { draft.queries.contains(query) },
                        set: { if $0 { draft.queries.insert(query) } else { draft.queries.remove(query) } }))
            }
        }
        .toggleStyle(.checkbox)
        .font(.system(size: 12))

        TextField("Only this repository, as owner/name (optional)", text: $draft.repo)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(well)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(.red.opacity(draft.repoFilter == "" ? 0.6 : 0)))

        note("Uses this space’s GitHub sign-in. Pull requests stay until they merge or close.")
    }

    @ViewBuilder
    private var feed: some View {
        HStack(spacing: 6) {
            TextField("Feed or page address", text: $draft.address)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($addressFocused)
                .onSubmit { find() }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(well)
            Button("Find") { find() }
                .disabled(draft.addressURL == nil || draft.isSearching)
        }
        .onAppear { DispatchQueue.main.async { addressFocused = true } }

        if draft.isSearching {
            note("Looking for a feed…")
        } else if let found = draft.found {
            if found.isEmpty {
                note("No feed found at that address.")
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(found) { feed in
                        let picked = draft.chosen == feed.url
                        Button { draft.chosen = feed.url } label: {
                            HStack(spacing: 8) {
                                Image(systemName: picked ? "largecircle.fill.circle" : "circle")
                                    .foregroundStyle(picked ? Color.accentColor : .primary.opacity(0.4))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(feed.title.isEmpty ? (feed.url.host() ?? "") : feed.title)
                                        .font(.system(size: 13))
                                        .lineLimit(1)
                                    Text(feed.url.absoluteString)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.primary.opacity(0.5))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(picked ? .isSelected : [])
                    }
                }
            }
        } else {
            note("A feed, or any page that links to one.")
        }
    }

    private func find() {
        let space = tabManager.currentSpace
        Task { await draft.find(in: space) }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.primary.opacity(0.55))
            .fixedSize(horizontal: false, vertical: true)
    }

    private var well: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.primary.opacity(0.06))
    }
}
