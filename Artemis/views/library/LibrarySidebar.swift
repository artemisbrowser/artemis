// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import AppKit
import SwiftUI
import Synchronization
import UniformTypeIdentifiers

/// a file in the downloads folder, as shown in the library
nonisolated struct DownloadFile: Identifiable {
    let url: URL
    let name: String
    let date: Date
    let kind: String
    let contentType: UTType?
    /// lowercased, without the dot
    let ext: String
    /// bytes
    let size: Int
    fileprivate let group: DownloadKind

    var id: URL { url }

    /// the type's icon, which macOS caches; only apps and untyped files are read one by one
    @MainActor var icon: NSImage {
        guard let contentType, !contentType.conforms(to: .application) else {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSWorkspace.shared.icon(for: contentType)
    }

    /// drags the file itself, so it can be dropped into Finder or another app
    var dragItem: NSItemProvider { NSItemProvider(contentsOf: url) ?? NSItemProvider() }

    private static let rankKeys: Set<URLResourceKey> = [
        .isDirectoryKey, .isHiddenKey, .addedToDirectoryDateKey, .creationDateKey, .contentModificationDateKey,
    ]

    /// the files in `folder` with the date each is ranked by; directories and hidden files are left out
    private static func ranked(in folder: URL, also extra: Set<URLResourceKey> = []) -> [(url: URL, date: Date)] {
        let keys = rankKeys.union(extra)
        // contentsOfDirectory won't enumerate through a symlink (ENOTDIR)
        let urls = try? FileManager.default.contentsOfDirectory(
            at: folder.resolvingSymlinksInPath(), includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
        return (urls ?? []).compactMap { url in
            guard let values = try? url.resourceValues(forKeys: rankKeys), values.isDirectory != true,
                values.isHidden != true
            else { return nil }
            let date = values.addedToDirectoryDate ?? values.creationDate ?? values.contentModificationDate
            return (url, date ?? .distantPast)
        }
    }

    /// newest first; files of one date go by name
    private static func isNewer(_ a: (url: URL, date: Date), _ b: (url: URL, date: Date)) -> Bool {
        a.date != b.date ? a.date > b.date : a.url.lastPathComponent < b.url.lastPathComponent
    }

    private static func described(_ file: (url: URL, date: Date)) -> DownloadFile {
        let values = try? file.url.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey])
        let type = values?.contentType, ext = file.url.pathExtension.lowercased()
        let group = DownloadKind.of(type, ext: ext)
        return DownloadFile(
            url: file.url, name: file.url.lastPathComponent, date: file.date,
            kind: LibrarySidebar.kindLabel(for: type, ext: ext, group: group), contentType: type, ext: ext,
            size: values?.fileSize ?? 0, group: group)
    }

    /// everything in `folder`, newest first, scanned off the main thread
    @concurrent static func loadAllOffMain(in folder: URL) async -> [DownloadFile] {
        ranked(in: folder, also: [.contentTypeKey, .fileSizeKey]).sorted(by: isNewer).map(described)
    }

    /// the last `recent` answer with the folder state it was read from, and how many scans `recent` has made
    private static let lastRecent = Mutex<(key: String, modified: Date, files: [DownloadFile], scans: Int)>(
        ("", .distantPast, [], 0))
    static var recentScans: Int { lastRecent.withLock { $0.scans } }

    /// the newest `count` files in `folder`, in `loadAllOffMain`'s order; an unchanged folder is not scanned again
    @concurrent static func recent(_ count: Int, in folder: URL) async -> [DownloadFile] {
        let resolved = folder.resolvingSymlinksInPath()
        let modified = (try? resolved.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let key = "\(count) \(resolved.path)"
        let last = lastRecent.withLock { $0 }
        if let modified, last.key == key, last.modified == modified { return last.files }
        var newest: [(url: URL, date: Date)] = []
        for file in ranked(in: resolved) {
            guard let slot = newest.firstIndex(where: { isNewer(file, $0) }) ?? (newest.count < count ? newest.count : nil)
            else { continue }
            newest.insert(file, at: slot)
            if newest.count > count { newest.removeLast() }
        }
        let files = newest.map(described)
        lastRecent.withLock {
            $0.scans += 1
            // a folder changed within its timestamp's grain of this scan may change again unseen
            if let modified, modified.timeIntervalSinceNow < -2 { ($0.key, $0.modified, $0.files) = (key, modified, files) }
        }
        return files
    }
}

/// the downloads filter: a glass circle that grows into its kinds, types and orders, over its neighbours, and shrinks back
private struct FilterMenu: View {
    @Binding var filter: DownloadFilter
    @Binding var sort: DownloadSort
    @Binding var ascending: Bool
    let files: [DownloadFile]
    @Environment(\.chromeInk) private var ink
    @Namespace private var glass
    private let metrics = SidebarMetrics.standard
    @State private var isOpen = false
    /// the control under the pointer or the arrow keys
    @State private var lit: Item?
    /// spans the open panel, so a press is known to land on it or elsewhere
    @State private var area = NSView()
    @State private var monitor: Any?

    private enum Item: Hashable {
        case kind(DownloadKind), type(String), sort(DownloadSort)
    }

    private static let width: CGFloat = 264
    private static let inset: CGFloat = 12
    private static let rowHeight: CGFloat = 28
    /// how far a sort row's highlight reaches past the chips' edge
    private static let rowOutset: CGFloat = 5
    private static let mostTypes = 12

    /// the circle's corners, which the panel keeps
    private var radius: CGFloat { metrics.rowHeight / 2 }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        // the hidden label is the circle's place in the row, whose other glass the open panel lies over
        label.hidden()
            .overlay(alignment: .topTrailing) {
                GlassEffectContainer {
                    if isOpen {
                        panel
                            .background { MenuAnchor(view: area).allowsHitTesting(false) }
                            .chromeGlass(in: shape)
                            .glassEffectID("filter", in: glass)
                    } else {
                        Button { set(open: true) } label: { label.contentShape(.capsule) }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Filter downloads")
                            .accessibilityValue(filter.summary ?? "All")
                            .tooltip("Filter downloads")
                            .chromeGlass(in: shape, interactive: true)
                            .glassEffectID("filter", in: glass)
                    }
                }
                .fixedSize()
                .modifier(ChromeGlassScheme())
            }
            .onDisappear { set(open: false) }
    }

    private var label: some View {
        let count = filter.count
        return Image(systemName: "line.3.horizontal.decrease")
            .font(.system(size: 13, weight: .medium))
            .overlay(alignment: .topTrailing) {
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(.black)
                        .blendMode(.destinationOut)
                        .padding(.horizontal, 3)
                        .frame(minWidth: 12, minHeight: 12)
                        .background(ink, in: .capsule)
                        .compositingGroup()
                        .fixedSize()
                        .offset(x: 6, y: -5)
                }
            }
            .foregroundStyle(ink.opacity(count == 0 ? 0.7 : 0.95))
            .frame(width: metrics.rowHeight, height: metrics.rowHeight)
    }

    /// All, the kind in force, and each kind some file is of
    private var kinds: [DownloadKind] {
        let present = Set(files.map(\.group))
        return DownloadKind.allCases.filter { $0 == .all || $0 == filter.kind || present.contains($0) }
    }

    /// the extensions among the kind's files, most common first, then the picked ones past `mostTypes`
    private var types: [(ext: String, count: Int)] {
        let counts = Dictionary(
            files.filter { filter.kind.holds($0) && !$0.ext.isEmpty }.map { ($0.ext, 1) }, uniquingKeysWith: +)
        let common = counts.map { (ext: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.ext < $1.ext }
        return Array(common.prefix(Self.mostTypes)) + common.dropFirst(Self.mostTypes).filter { filter.types.contains($0.ext) }
    }

    /// every control, in the order the arrow keys walk them
    private var items: [Item] {
        kinds.map(Item.kind) + types.map { .type($0.ext) } + DownloadSort.allCases.map(Item.sort)
    }

    private var panel: some View {
        let types = types
        return VStack(alignment: .leading, spacing: 12) {
            section("Kind") {
                FlowLayout(spacing: 5) {
                    ForEach(kinds) { kind in
                        chip(.kind(kind), kind.rawValue, isOn: kind == filter.kind && (kind != .all || filter.types.isEmpty))
                    }
                }
            }
            if !types.isEmpty {
                section("Type") {
                    FlowLayout(spacing: 5) {
                        ForEach(types, id: \.ext) { type in
                            chip(.type(type.ext), ".\(type.ext)", count: type.count, isOn: filter.types.contains(type.ext))
                        }
                    }
                }
            }
            section("Sort") {
                VStack(spacing: 0) { ForEach(DownloadSort.allCases, content: row) }
                    .padding(.horizontal, -Self.rowOutset)
            }
        }
        .padding(Self.inset)
        .frame(width: Self.width)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Download filters")
        .accessibilityAction(.escape) { set(open: false) }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(ink.opacity(0.55))
                .padding(.leading, 4)
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }

    private func chip(_ item: Item, _ title: String, count: Int? = nil, isOn: Bool) -> some View {
        Button { take(item) } label: {
            HStack(spacing: 4) {
                Text(title).font(.system(size: 12, weight: .medium))
                if let count { Text("\(count)").font(.system(size: 10)).opacity(0.55) }
            }
            .foregroundStyle(ink.opacity(isOn ? 1 : 0.85))
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(Capsule().fill(ink.opacity((isOn ? 0.28 : 0.07) + (lit == item ? 0.09 : 0))))
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .onHover { if $0 { lit = item } else if lit == item { lit = nil } }
        .accessibilityLabel(title)
        .accessibilityValue(count.map { "\($0)" } ?? "")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private func row(_ option: DownloadSort) -> some View {
        let isOn = option == sort, item = Item.sort(option)
        return Button { take(item) } label: {
            HStack {
                Text(option.rawValue).font(.system(size: 13, weight: isOn ? .semibold : .regular))
                Spacer(minLength: 0)
                Image(systemName: ascending ? "arrow.up" : "arrow.down")
                    .font(.system(size: 10, weight: .bold))
                    .opacity(isOn ? 1 : 0)
            }
            .foregroundStyle(ink.opacity(0.95))
            .padding(.horizontal, 9)
            .frame(height: Self.rowHeight)
            .background(
                RoundedRectangle(cornerRadius: radius - Self.inset + Self.rowOutset, style: .continuous)
                    .fill(ink.opacity(lit == item ? 0.13 : 0)))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { if $0 { lit = item } else if lit == item { lit = nil } }
        .accessibilityLabel("Sort by \(option.rawValue)")
        .accessibilityValue(isOn ? (ascending ? "Ascending" : "Descending") : "")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    /// a kind or an order is taken and the panel closes; types toggle and it stays, for picking several.
    /// All drops the picked types, and any other kind those none of its files have
    private func take(_ item: Item) {
        switch item {
        case .kind(let kind):
            filter.kind = kind
            filter.types = kind == .all ? [] : filter.types.intersection(files.filter(kind.holds).map(\.ext))
        case .type(let ext): return filter.types.formSymmetricDifference([ext])
        case .sort(let option):
            ascending = option == sort ? !ascending : option.startsAscending
            sort = option
        }
        set(open: false)
    }

    /// while open, a press off the glass or Escape closes it, the arrows move through the controls and Return takes one
    private func set(open: Bool) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard open != isOpen else { return }
        withAnimation(Motion.menu) { isOpen = open }
        lit = open ? .kind(filter.kind) : nil
        guard open else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { event in
            guard event.window === area.window else {
                if event.type != .keyDown { set(open: false) }
                return event
            }
            guard event.type == .keyDown else {
                if area.bounds.contains(area.convert(event.locationInWindow, from: nil)) { return event }
                set(open: false)
                return nil
            }
            switch event.keyCode {
            case 53: set(open: false)
            case 123...126:
                let all = items, step = event.keyCode == 124 || event.keyCode == 125 ? 1 : -1
                let at = lit.flatMap(all.firstIndex(of:)).map { $0 + step } ?? (step > 0 ? 0 : all.count - 1)
                lit = all[min(max(at, 0), all.count - 1)]
            case 36, 49, 76:
                if let lit { take(lit) } else { set(open: false) }
            default: return event
            }
            return nil
        }
    }
}

/// the groups downloads sort into; every file is of exactly one besides `all`
private nonisolated enum DownloadKind: String, CaseIterable, Identifiable {
    case all = "All"
    case images = "Images"
    case movies = "Movies"
    case audio = "Audio"
    case documents = "Documents"
    case archives = "Archives"
    case fonts = "Fonts"
    case other = "Other"

    var id: Self { self }

    func holds(_ file: DownloadFile) -> Bool { self == .all || file.group == self }

    /// never `all`; web fonts and rar have types that conform to nothing, so they go by extension
    static func of(_ type: UTType?, ext: String) -> Self {
        if ["woff", "woff2", "eot"].contains(ext) { return .fonts }
        if ext == "rar" { return .archives }
        guard let type else { return .other }
        // svg is text too, and audio is audiovisual too
        if type.conforms(to: .image) { return .images }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .audiovisualContent) { return .movies }
        if type.conforms(to: .font) { return .fonts }
        if type.conforms(to: .archive) { return .archives }
        if type.conforms(to: .text) || type.conforms(to: .compositeContent) { return .documents }
        return .other
    }
}

/// which downloads the list keeps
private struct DownloadFilter {
    var kind = DownloadKind.all
    /// extensions as `DownloadFile.ext` has them; none keeps every type of the kind
    var types: Set<String> = []

    func keeps(_ file: DownloadFile) -> Bool { kind.holds(file) && (types.isEmpty || types.contains(file.ext)) }

    /// a kind other than All counts one, and so does each picked type
    var count: Int { (kind == .all ? 0 : 1) + types.count }

    /// what is filtered for, in words for accessibility; nil while nothing is
    var summary: String? {
        let parts = (kind == .all ? [] : [kind.rawValue]) + types.sorted().map { ".\($0)" }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

/// the orders the downloads list can take
private enum DownloadSort: String, CaseIterable, Identifiable {
    case date = "Date Added"
    case name = "Name"
    case size = "Size"
    case type = "Type"

    static let storageKey = "libraryDownloadSort"
    static let ascendingKey = "libraryDownloadSortAscending"

    var id: Self { self }

    /// the direction a first press sorts in
    var startsAscending: Bool { self == .name || self == .type }
}

/// the Library's lists; a raw value is both the rail's label and what `storageKey` holds
enum LibraryMode: String, CaseIterable {
    case downloads = "Downloads", archive = "Archive"
    case history = "History"

    /// the list the Library opens on
    static let storageKey = "libraryLastMode"

    var icon: String {
        switch self {
        case .archive: "archivebox"
        case .downloads: "arrow.down.circle"
        case .history: "clock.arrow.circlepath"
        }
    }
}

/// the library: search, filter, and the contents of ~/Downloads
/// grouped by how long ago files arrived
struct LibrarySidebar: View {
    static let railWidth: CGFloat = 72
    /// the whole sidebar's width while the Library is open, whatever width the spaces' sidebar is set to
    static let sidebarWidth: CGFloat = 380

    @Environment(TabManager.self) private var tabManager
    @Environment(\.chromeInk) private var ink
    private let metrics = SidebarMetrics.standard
    @AppStorage(LibraryMode.storageKey) private var mode: LibraryMode = .archive
    @AppStorage(DownloadManager.folderKey) private var downloadsFolder = ""
    @State private var query = ""
    @State private var filter = DownloadFilter()
    @AppStorage(DownloadSort.storageKey) private var sort = DownloadSort.date
    @AppStorage(DownloadSort.ascendingKey) private var ascending = false
    /// nil until ~/Downloads has been read
    @State private var files: [DownloadFile]?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            rail

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    searchField
                    if mode == .downloads {
                        FilterMenu(filter: $filter, sort: $sort, ascending: $ascending, files: files ?? [])
                    }
                }
                // the open filter lies over the list
                .zIndex(1)

                switch mode {
                case .archive: archiveList
                case .downloads: downloadsList
                case .history: historyList
                }
            }
            // only the rail's side follows the sidebar; the lists read as in left mode
            .environment(\.layoutDirection, .leftToRight)
        }
        .task(id: [downloadsFolder] + finishedDownloads.map(\.path)) { files = await DownloadFile.loadAllOffMain(in: DownloadManager.folder) }
    }

    // MARK: - Rail (arc-style left icon column)

    private var rail: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)
            ForEach(LibraryMode.allCases, id: \.self) { item in
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
        }
        .padding(.horizontal, 14)
        .frame(height: metrics.rowHeight)
        .chromeGlass(in: .capsule)
    }

    // MARK: - List

    private var finishedDownloads: [URL] {
        DownloadManager.shared.items.compactMap { $0.state == .finished ? $0.destination : nil }
    }

    /// the files the filter and the search keep, in the chosen order; `files` holds them newest first
    private var visibleFiles: [DownloadFile] {
        let kept = (files ?? []).filter { file in
            filter.keeps(file)
                && (query.isEmpty
                    || [file.name, file.kind, file.group.rawValue].contains { $0.localizedCaseInsensitiveContains(query) })
        }
        func byName(_ a: DownloadFile, _ b: DownloadFile) -> Bool {
            a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        let rising: [DownloadFile] =
            switch sort {
            case .date: kept.reversed()
            case .name: kept.sorted(by: byName)
            case .size: kept.sorted { $0.size != $1.size ? $0.size < $1.size : byName($0, $1) }
            case .type: kept.sorted { $0.ext != $1.ext ? $0.ext < $1.ext : byName($0, $1) }
            }
        return ascending ? rising : rising.reversed()
    }

    /// headed runs of `visible`: by age under the date order, by extension under the type order, else one run with no heading
    private func sections(_ visible: [DownloadFile]) -> [(String, [DownloadFile])] {
        switch sort {
        case .date: Self.grouped(visible, by: \.date)
        case .name, .size: [("", visible)]
        case .type:
            visible.reduce(into: []) { runs, file in
                let label = file.ext.isEmpty ? "No Extension" : ".\(file.ext)"
                if runs.last?.0 == label { runs[runs.count - 1].1.append(file) } else { runs.append((label, [file])) }
            }
        }
    }

    @ViewBuilder
    private var downloadsList: some View {
        let visible = visibleFiles
        if files?.isEmpty == true {
            emptyState(
                "You haven't downloaded anything with Artemis yet!",
                detail: "As soon as you do, it'll be right here.")
        } else if files != nil, visible.isEmpty {
            emptyState(
                "No downloads match",
                detail: "Try a different search or filter.")
        } else {
            filledList(visible)
        }
    }

    // MARK: - History

    /// newest first, matched the way the command bar matches history
    private var visibleHistory: [HistoryEntry] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let entries = tabManager.history.entries(hiding: SpaceLock.shared.lockedIDs)
        guard !q.isEmpty else { return entries }
        let mask = CommandMatcher.mask(q.utf8)
        let needle = Array(q.utf8)
        return entries.filter {
            (mask & ~$0.searchMask) == 0 && CommandMatcher.contains(needle, $0.searchKey)
        }
    }

    @ViewBuilder
    private var historyList: some View {
        let visible = visibleHistory
        if tabManager.history.entries(hiding: SpaceLock.shared.lockedIDs).isEmpty {
            emptyState(
                "No history yet",
                detail: "Pages you visit will show up here.")
        } else if visible.isEmpty {
            emptyState("No history matches", detail: "Try a different search.")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Self.grouped(visible, by: \.lastVisited), id: \.0) { label, entries in
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

    @ViewBuilder
    private var archiveList: some View {
        let visible = tabManager.archive.search(query)
        if tabManager.archive.entries.isEmpty {
            emptyState(
                "Nothing archived yet",
                detail: "Tabs you leave open are tidied away here after a while. Pin the ones you want to keep.")
        } else if visible.isEmpty {
            emptyState("No archived tabs match", detail: "Try a different search.")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Self.grouped(visible, by: \.archivedAt), id: \.0) { label, entries in
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

    private func filledList(_ visible: [DownloadFile]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(sections(visible), id: \.0) { label, sectionFiles in
                    if !label.isEmpty {
                        Text(label)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(ink.opacity(0.55))
                            .padding(.horizontal, 9)
                            .padding(.top, 10)
                            .padding(.bottom, 4)
                    }

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
    private static func grouped<T>(_ items: [T], by date: (T) -> Date) -> [(String, [T])] {
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

    /// what a row calls its file: the type's own name, else one from the group or the extension
    fileprivate nonisolated static func kindLabel(for type: UTType?, ext: String, group: DownloadKind) -> String {
        if let type {
            if type.conforms(to: .image) { return "Image" }
            if type.conforms(to: .audio) { return "Audio" }
            if type.conforms(to: .audiovisualContent) { return "Movie" }
            if type.conforms(to: .pdf) { return "PDF Document" }
            if let name = type.localizedDescription { return name.prefix(1).uppercased() + name.dropFirst() }
        }
        switch group {
        case .fonts: return "Font"
        case .archives: return "Archive"
        default: return ext.isEmpty ? "Download" : "\(ext.uppercased()) file"
        }
    }

    private static func ageLabel(for date: Date) -> String {
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
            VStack(spacing: 4) {
                // fixed icon box so the three glyphs share one centerline
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .frame(width: 28, height: 24)
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .multilineTextAlignment(.center)
            .foregroundStyle(ink.opacity(isActive ? 0.95 : 0.55))
            .frame(maxWidth: .infinity)
            .frame(height: 64)
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

/// a downloaded file: opens on click, drags out as the file
private struct DownloadFileRow: View {
    let file: DownloadFile

    var body: some View {
        let size = ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file)
        LibraryRow(
            title: file.name, detail: "\(size) · \(file.kind)", open: { NSWorkspace.shared.open(file.url) }, iconSide: 30
        ) {
            Image(nsImage: file.icon).resizable().scaledToFit()
        }
        .onDrag { file.dragItem }
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
    /// 30 is the two text lines' height, the most a row holds without growing
    var iconSide: CGFloat = 22
    @ViewBuilder let icon: () -> Icon
    @ViewBuilder var trailing: (Bool) -> Trailing
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            icon().frame(width: iconSide, height: iconSide)
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
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { open() }
        .onTapGesture(perform: open)
        .onHover { isHovering = $0 }
    }
}

extension LibraryRow where Trailing == EmptyView {
    init(
        title: String, detail: String, open: @escaping () -> Void, iconSide: CGFloat = 22,
        @ViewBuilder icon: @escaping () -> Icon
    ) {
        self.init(
            title: title, detail: detail, open: open, iconSide: iconSide, icon: icon, trailing: { _ in EmptyView() })
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
