import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// a file in ~/Downloads, as shown in the library
nonisolated struct DownloadFile: Identifiable {
    let id: URL
    let url: URL
    let name: String
    let date: Date
    let kind: String
    let contentType: UTType?

    var icon: NSImage {
        NSWorkspace.shared.icon(forFile: url.path)
    }

    /// everything in ~/Downloads, newest first, scanned off the main thread
    @concurrent static func loadAllOffMain() async -> [DownloadFile] {
        // in the sandbox, `.downloadsDirectory` is a *symlink* into the real
        // ~/Downloads; contentsOfDirectory won't enumerate through it (ENOTDIR),
        // so resolve it to the real path first (writes follow the link fine, but
        // listing does not)
        let downloads = FileManager.default
            .urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            .resolvingSymlinksInPath()
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isHiddenKey, .contentTypeKey,
            .addedToDirectoryDateKey, .creationDateKey, .contentModificationDateKey,
        ]
        guard
            let urls = try? FileManager.default.contentsOfDirectory(
                at: downloads, includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles])
        else { return [] }

        return
            urls.compactMap { url -> DownloadFile? in
                guard let values = try? url.resourceValues(forKeys: keys),
                    values.isDirectory != true, values.isHidden != true
                else { return nil }
                let date =
                    values.addedToDirectoryDate ?? values.creationDate
                    ?? values.contentModificationDate ?? .distantPast
                return DownloadFile(
                    id: url,
                    url: url,
                    name: url.lastPathComponent,
                    date: date,
                    kind: LibrarySidebar.kindLabel(for: values.contentType),
                    contentType: values.contentType)
            }
            .sorted { $0.date > $1.date }
    }
}

/// filter categories for the downloads library
enum DownloadFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case images = "Images"
    case movies = "Movies"
    case archives = "Archives"
    case other = "Other"

    var id: Self { self }

    func matches(_ file: DownloadFile) -> Bool {
        guard let type = file.contentType else { return self == .other || self == .all }
        switch self {
        case .all: return true
        case .images: return type.conforms(to: .image)
        case .movies: return type.conforms(to: .audiovisualContent)
        case .archives: return type.conforms(to: .archive)
        case .other:
            return !type.conforms(to: .image) && !type.conforms(to: .audiovisualContent)
                && !type.conforms(to: .archive)
        }
    }
}

/// the library: search, filter, and the contents of ~/Downloads
/// grouped by how long ago files arrived
struct LibrarySidebar: View {
    /// width of the left icon rail — added *on top* of the sidebar width so the
    /// archive/history list keeps the full sidebar width (the rail is "extra")
    static let railWidth: CGFloat = 56

    enum Mode: String, CaseIterable {
        case downloads = "Downloads", archive = "Archive"
        case history = "History"

        var icon: String {
            switch self {
            case .archive: "archivebox"
            case .downloads: "arrow.down.circle"
            case .history: "clock.arrow.circlepath"
            }
        }
    }

    /// current sidebar width — drives the filter's icon-only collapse
    var width: Double = 250

    @Environment(TabManager.self) private var tabManager
    @Environment(\.chromeInk) private var ink
    @Environment(\.sidebarMetrics) private var metrics
    // remember the section you last opened, rather than always landing on Archive
    @AppStorage("libraryLastMode") private var mode: Mode = .archive
    @State private var query = ""
    @State private var filter: DownloadFilter = .all
    @State private var files: [DownloadFile] = []
    @FocusState private var isSearchFocused: Bool

    /// below this the search box would start clipping its placeholder,
    /// so the filter drops its label and becomes a square icon button
    private var isFilterCompact: Bool { width < 230 }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            rail

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    searchField
                    if mode == .downloads {
                        filterButton
                    }
                }

                switch mode {
                case .archive: archiveList
                case .downloads: downloadsList
                case .history: historyList
                }
            }
        }
        // the file list is read when the Library is actually opened, not at
        // launch: this panel is mounted for the whole session (it slides rather
        // than unmounts), and enumerating ~/Downloads with per-file attribute
        // fetches is not something to do while the window is still coming up
        // re-read on every open, not just the first — and on appear, so the
        // panel is current without scanning during launch
        .task(id: tabManager.isLibraryOpen) {
            if tabManager.isLibraryOpen { files = await DownloadFile.loadAllOffMain() }
        }
    }

    // MARK: - Rail (arc-style left icon column)

    private var rail: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)
            ForEach(Mode.allCases, id: \.self) { item in
                RailButton(icon: item.icon, label: item.rawValue, isActive: mode == item) {
                    if mode != item { query = "" }
                    mode = item
                }
            }
            Spacer(minLength: 0)
        }
        .frame(width: Self.railWidth)
        .frame(maxHeight: .infinity)
    }

    // MARK: - Search + filter

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(ink.opacity(0.5))
            TextField(
                "Search",
                text: $query,
                prompt: Text("Search \(mode.rawValue)...")
                    .foregroundStyle(ink.opacity(0.45))
            )
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .foregroundStyle(ink)
            .focused($isSearchFocused)
        }
        .padding(.horizontal, 14)
        .frame(height: metrics.rowHeight)
        .chromeGlass(in: .capsule)
    }

    private var filterButton: some View {
        Menu {
            Picker("Filter", selection: $filter) {
                ForEach(DownloadFilter.allCases) { option in
                    Text(option.rawValue).tag(option)
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.system(size: 12))
                if !isFilterCompact {
                    Text(filter == .all ? "Filter" : filter.rawValue)
                        .font(.system(size: 12))
                }
            }
            .foregroundStyle(ink.opacity(filter == .all ? 0.7 : 0.95))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        // the label collapses to a bare glyph at narrow widths, taking the name
        // with it
        .accessibilityLabel("Filter downloads")
        .accessibilityValue(filter.rawValue)
        // hug the content, then pad inside the pill and force the height to
        // match the search box (padding the label directly gets eaten by the menu)
        .fixedSize()
        .padding(.horizontal, isFilterCompact ? 0 : 12)
        .frame(width: isFilterCompact ? metrics.rowHeight : nil, height: metrics.rowHeight)
        .chromeGlass(in: .capsule)
    }

    // MARK: - List

    private var visibleFiles: [DownloadFile] {
        files.filter { file in
            filter.matches(file)
                && (query.isEmpty || file.name.localizedCaseInsensitiveContains(query))
        }
    }

    @ViewBuilder
    private var downloadsList: some View {
        if files.isEmpty {
            emptyState(
                "You haven't downloaded anything with Artemis yet!",
                detail: "As soon as you do, it'll be right here.")
        } else if visibleFiles.isEmpty {
            emptyState(
                "No downloads match",
                detail: "Try a different search or filter.")
        } else {
            filledList
        }
    }

    // MARK: - History

    private var visibleHistory: [HistoryEntry] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return tabManager.history.entries }
        return tabManager.history.entries.filter {
            $0.title.localizedCaseInsensitiveContains(q)
                || $0.url.absoluteString.localizedCaseInsensitiveContains(q)
        }
    }

    @ViewBuilder
    private var historyList: some View {
        if tabManager.history.entries.isEmpty {
            emptyState(
                "No history yet",
                detail: "Pages you visit will show up here.")
        } else if visibleHistory.isEmpty {
            emptyState("No history matches", detail: "Try a different search.")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Self.grouped(visibleHistory, by: \.lastVisited), id: \.0) { label, entries in
                        Text(label)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(ink.opacity(0.55))
                            .padding(.horizontal, 9)
                            .padding(.top, 10)
                            .padding(.bottom, 4)

                        ForEach(entries) { entry in
                            HistoryRow(entry: entry) {
                                tabManager.newTab(url: entry.url)
                            }
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    // MARK: - Archive

    private var visibleArchive: [ArchiveEntry] {
        tabManager.archive.search(query)
    }

    @ViewBuilder
    private var archiveList: some View {
        if tabManager.archive.entries.isEmpty {
            emptyState(
                "Nothing archived yet",
                detail: "Tabs you leave open are tidied away here after a while — pin the ones you want to keep.")
        } else if visibleArchive.isEmpty {
            emptyState("No archived tabs match", detail: "Try a different search.")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Self.grouped(visibleArchive, by: \.archivedAt), id: \.0) { label, entries in
                        Text(label)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(ink.opacity(0.55))
                            .padding(.horizontal, 9)
                            .padding(.top, 10)
                            .padding(.bottom, 4)

                        ForEach(entries) { entry in
                            ArchiveRow(
                                entry: entry,
                                restore: { tabManager.restoreFromArchive(entry) },
                                delete: { tabManager.archive.remove(entry) })
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    private func emptyState(_ title: String, detail: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "shippingbox")
                .font(.system(size: 28))
                .foregroundStyle(ink.opacity(0.35))
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(ink.opacity(0.8))
                .multilineTextAlignment(.center)
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(ink.opacity(0.5))
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var filledList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(Self.grouped(visibleFiles, by: \.date), id: \.0) { label, sectionFiles in
                    Text(label)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(ink.opacity(0.55))
                        .padding(.horizontal, 9)
                        .padding(.top, 10)
                        .padding(.bottom, 4)

                    ForEach(sectionFiles) { file in
                        DownloadFileRow(file: file)
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    // MARK: - Data

    /// (label, items) runs in the items' order, with one calendar lookup per
    /// distinct day rather than per item
    static func grouped<T>(_ items: [T], by date: (T) -> Date) -> [(String, [T])] {
        let calendar = Calendar.current
        var day = Date.distantFuture ..< Date.distantFuture
        var ordered: [(String, [T])] = []
        for item in items {
            let at = date(item)
            if !day.contains(at) {
                let start = calendar.startOfDay(for: at)
                day = start ..< (calendar.date(byAdding: .day, value: 1, to: start) ?? .distantFuture)
                let label = ageLabel(for: at)
                if ordered.last?.0 != label { ordered.append((label, [])) }
            }
            ordered[ordered.count - 1].1.append(item)
        }
        return ordered
    }

    nonisolated static func kindLabel(for type: UTType?) -> String {
        guard let type else { return "Download" }
        if type.conforms(to: .image) { return "Image" }
        if type.conforms(to: .audiovisualContent) { return "Movie" }
        if type.conforms(to: .archive) { return "Zip Archive" }
        if type.conforms(to: .pdf) { return "PDF Document" }
        return type.localizedDescription?.capitalized ?? "Download"
    }

    static func ageLabel(for date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        let days =
            calendar.dateComponents(
                [.day],
                from: calendar.startOfDay(for: date),
                to: calendar.startOfDay(for: Date())
            ).day ?? 0
        if days < 7 { return "\(days) days ago" }
        if days < 35 {
            let weeks = max(days / 7, 1)
            return weeks == 1 ? "1 week ago" : "\(weeks) weeks ago"
        }
        let months = max(days / 30, 1)
        return months == 1 ? "1 month ago" : "\(months) months ago"
    }
}

/// one item in the library's left rail: icon over a tiny label, highlighted
/// pill when it's the active section
private struct RailButton: View {
    @Environment(\.chromeInk) private var ink
    let icon: String
    let label: String
    let isActive: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                // fixed icon box so the three glyphs share one centerline
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .frame(width: 22, height: 20)
                Text(label)
                    .font(.system(size: 9, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .multilineTextAlignment(.center)
            .foregroundStyle(ink.opacity(isActive ? 0.95 : 0.55))
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(RowHighlight(opacity: isActive ? 0.22 : (isHovering ? 0.09 : 0), isSelected: isActive))
            .animation(Motion.hover, value: isHovering)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(label)
            .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        // no tooltip: the label is already shown under the icon
    }
}

/// an archived tab: opens on click, with delete and restore on hover
private struct ArchiveRow: View {
    let entry: ArchiveEntry
    let restore: () -> Void
    let delete: () -> Void

    var body: some View {
        LibraryRow(title: entry.title, detail: entry.url.host() ?? entry.url.absoluteString, open: restore) {
            SiteFavicon(host: entry.url.host())
        } trailing: { hovering in
            if hovering {
                HStack(spacing: 2) {
                    HoverIconButton("trash", boxSize: 24, action: delete).tooltip("Delete")
                    HoverIconButton("arrow.uturn.backward", boxSize: 24, action: restore).tooltip("Restore Tab")
                }
                .transition(.opacity)
            }
        }
        .contextMenu {
            Group {
                Button("Restore Tab", systemImage: "arrow.uturn.backward", action: restore)
                CopyLinkButton(url: entry.url)
                Divider()
                Button("Delete", systemImage: "trash", role: .destructive, action: delete)
            }
            .labelStyle(.titleAndIcon)
        }
    }
}

/// a visited page: opens in a new tab on click
private struct HistoryRow: View {
    let entry: HistoryEntry
    let open: () -> Void

    var body: some View {
        LibraryRow(title: entry.title, detail: entry.url.host() ?? entry.url.absoluteString, open: open) {
            SiteFavicon(host: entry.url.host())
        }
        .contextMenu { CopyLinkButton(url: entry.url).labelStyle(.titleAndIcon) }
    }
}

/// a file in Downloads: opens on click
private struct DownloadFileRow: View {
    let file: DownloadFile
    /// NSWorkspace's icon is a synchronous fetch, so it is read once per row
    @State private var icon: NSImage?

    var body: some View {
        LibraryRow(title: file.name, detail: file.kind, open: { NSWorkspace.shared.open(file.url) }) {
            Group {
                if let icon { Image(nsImage: icon).resizable().scaledToFit() } else { Color.clear }
            }
            .onAppear { if icon == nil { icon = file.icon } }
        }
        .contextMenu {
            Button("Show in Finder", systemImage: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([file.url])
            }
            .labelStyle(.titleAndIcon)
        }
    }
}

/// the shape every Library list shares: icon, title over detail, a hover
/// highlight like a tab row's, and optional controls shown while hovered
private struct LibraryRow<Icon: View, Trailing: View>: View {
    @Environment(\.chromeInk) private var ink
    let title: String
    let detail: String
    let open: () -> Void
    @ViewBuilder let icon: () -> Icon
    @ViewBuilder var trailing: (Bool) -> Trailing
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            icon().frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(title.replacingOccurrences(of: " ", with: "\u{00A0}"))
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(ink)
                Text(detail)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(ink.opacity(0.5))
            }
            Spacer(minLength: 0)
            trailing(isHovering)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(RowHighlight(opacity: isHovering ? 0.09 : 0))
        .animation(Motion.hover, value: isHovering)
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture(perform: open)
        .onHover { isHovering = $0 }
    }
}

extension LibraryRow where Trailing == EmptyView {
    init(title: String, detail: String, open: @escaping () -> Void, @ViewBuilder icon: @escaping () -> Icon) {
        self.init(title: title, detail: detail, open: open, icon: icon, trailing: { _ in EmptyView() })
    }
}

/// a site's favicon at tab-row size, or a globe until one is known
private struct SiteFavicon: View {
    @Environment(\.chromeInk) private var ink
    let host: String?

    var body: some View {
        if let icon = FaviconStore.shared.icon(for: host) {
            Image(nsImage: icon)
                .resizable()
                .scaledToFit()
                .frame(width: 16, height: 16)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        } else {
            Image(systemName: "globe")
                .font(.system(size: 12))
                .foregroundStyle(ink.opacity(0.6))
        }
    }
}

private struct CopyLinkButton: View {
    let url: URL

    var body: some View {
        Button("Copy Link", systemImage: "link") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
        }
    }
}
