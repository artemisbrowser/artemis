// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import SwiftUI

/// how Artemis looks: the window, the icon, and the sidebar's contents
struct AppearanceSettings: View {
    @AppStorage(WindowChrome.edgeInsetKey) private var edgeInset = WindowChrome.defaultEdgeInset
    @AppStorage(AppIconChoice.storageKey) private var appIconRaw = AppIconChoice.bundled.rawValue
    @AppStorage(NowPlayingCard.enabledKey) private var showsNowPlaying = true
    @AppStorage(FolderPeekDetail.storageKey) private var folderPeekDetailRaw = FolderPeekDetail.none.rawValue
    @AppStorage(FolderTabCount.storageKey) private var folderTabCountRaw = FolderTabCount.count.rawValue

    var body: some View {
        Form {
            Section("Window") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        InfoLabel(
                            "Edge thickness",
                            info: "How much window shows around the page. At zero the page fills the whole window.")
                        Spacer()
                        Text(edgeInset == 0 ? "None" : "\(Int(edgeInset)) pt")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(
                        value: $edgeInset.undoable("Edge Thickness"),
                        in: WindowChrome.range,
                        step: 1)
                    .accessibilityLabel("Edge thickness")
                }
                .settingsAnchor(.edgeThickness)
            }

            Section("Sidebar") {
                Toggle(isOn: $showsNowPlaying.undoable("Now Playing")) {
                    InfoLabel(
                        "Show Now Playing",
                        info: "Shows media controls above the spaces when a background tab plays audio or video.")
                }
                .settingsAnchor(.nowPlaying)
            }

            Section("Folders") {
                Picker(selection: $folderPeekDetailRaw.undoable("Folder Second Line")) {
                    ForEach(FolderPeekDetail.allCases) { detail in
                        Text(detail.label).tag(detail.rawValue)
                    }
                } label: {
                    InfoLabel(
                        "Second line",
                        info: "What each tab shows under its title when you hover a closed folder.")
                }
                .settingsAnchor(.folderSecondLine)

                Picker(selection: $folderTabCountRaw.undoable("Folder Tab Count")) {
                    ForEach(FolderTabCount.allCases) { style in
                        Text(style.label).tag(style.rawValue)
                    }
                } label: {
                    InfoLabel(
                        "Tab count",
                        info: "How a folder shows the number of tabs it holds at the end of its header row.")
                }
                .settingsAnchor(.folderTabCount)
            }

            Section {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 10) {
                    ForEach(AppIconChoice.allCases) { choice in
                        AppIconTile(choice: choice, isSelected: appIconRaw == choice.rawValue) {
                            Binding(get: { appIconRaw }, set: { appIconRaw = $0; AppIconChoice.apply() })
                                .undoable("App Icon").wrappedValue = choice.rawValue
                        }
                    }
                }
                .settingsAnchor(.appIcon)
            } header: {
                InfoLabel("App Icon", info: "Sets the icon shown in the Dock, ⌘Tab and Finder.")
            }
        }
        .formStyle(.grouped)
    }
}

/// what the address bar does beyond its profile's search engine: bangs, and
/// searching the text of pages you've read
struct SearchSettings: View {
    @Environment(TabManager.self) private var tabManager
    @AppStorage(Bangs.enabledKey) private var bangsEnabled = true
    @AppStorage(FullTextIndex.enabledKey) private var indexPageText = false
    @State private var isEditingBangs = false
    @State private var indexStatus: String?

    var body: some View {
        Form {
            Section {
                HStack {
                    Toggle(isOn: $bangsEnabled.undoable("Bangs")) {
                        InfoLabel(
                            "Bangs",
                            info: "Typing “!yt cats” searches YouTube directly. \(Bangs.builtin.count) bangs are built in and DuckDuckGo handles the rest.")
                    }
                    Spacer()
                    Button("Custom…") { isEditingBangs = true }
                        .disabled(!bangsEnabled)
                }
                .settingsAnchor(.bangs)
            } header: {
                InfoLabel("Shortcuts", info: "Each profile picks its own search engine, in Profiles.")
            }

            Section("Search Page Contents") {
                Toggle(isOn: $indexPageText.undoable("Page Index")) {
                    InfoLabel(
                        "Index the text of pages I visit",
                        info: "Lets the command bar search the text of pages you've read. Each profile has its own index on this Mac, and incognito pages are skipped.")
                }
                .settingsAnchor(.indexPageText)
                HStack {
                    if let indexStatus {
                        Text(indexStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Spacer()
                    Button("Erase Index", role: .destructive) {
                        Task {
                            for profile in tabManager.profiles { await profile.pageIndex.clear() }
                            await refreshIndexStatus()
                        }
                    }
                    .disabled(indexStatus == nil)
                }
                .settingsAnchor(.eraseIndex)
            }
        }
        .formStyle(.grouped)
        .task { await refreshIndexStatus() }
        .sheet(isPresented: $isEditingBangs) { CustomBangsEditor() }
    }

    private func refreshIndexStatus() async {
        var pages = 0
        var bytes = 0
        for profile in tabManager.profiles {
            pages += await profile.pageIndex.count()
            bytes += await profile.pageIndex.sizeOnDisk()
        }
        indexStatus =
            pages == 0
            ? "Nothing indexed yet."
            : "\(pages.formatted()) pages indexed, "
                + ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

/// how the sidebar behaves: revealing it from the window edge, and sliding between spaces
struct SidebarSettings: View {
    @AppStorage("sidebarRevealDelay") private var sidebarRevealDelay = 100.0
    @AppStorage("sidebarHoverAreaWidth") private var sidebarHoverAreaWidth = 8.0
    @AppStorage("sidebarRevealDuration") private var sidebarRevealDuration = 0.2
    @AppStorage("spaceTransitionDuration") private var spaceTransitionDuration = 0.2

    var body: some View {
        Form {
            Section("Reveal") {
                Slider(value: $sidebarRevealDelay.undoable("Reveal Delay"), in: 0...600, step: 25) {
                    InfoLabel(
                        "Reveal delay",
                        info: "A hidden sidebar peeks after you hover the window edge for \(Int(sidebarRevealDelay)) ms.")
                } minimumValueLabel: {
                    Text("Fast")
                } maximumValueLabel: {
                    Text("Slow")
                }
                .settingsAnchor(.revealDelay)

                Slider(value: $sidebarHoverAreaWidth.undoable("Hover Area"), in: 2...40, step: 1) {
                    InfoLabel(
                        "Hover area",
                        info: "Hovering a \(Int(sidebarHoverAreaWidth)) pt strip along the window edge reveals the sidebar.")
                } minimumValueLabel: {
                    Text("Narrow")
                } maximumValueLabel: {
                    Text("Wide")
                }
                .settingsAnchor(.hoverArea)

                // bind in whole milliseconds: a fractional-second step (0.05)
                // doesn't divide the range evenly in floating point, so the
                // thumb can't reach the far end. integers land cleanly
                Slider(
                    value: Binding(
                        get: { sidebarRevealDuration * 1000 },
                        set: { sidebarRevealDuration = $0 / 1000 }
                    ).undoable("Reveal Speed"),
                    in: 100...600, step: 50
                ) {
                    InfoLabel(
                        "Reveal speed",
                        info: "The sidebar slides in over \(Int(sidebarRevealDuration * 1000)) ms.")
                } minimumValueLabel: {
                    Text("Fast")
                } maximumValueLabel: {
                    Text("Slow")
                }
                .settingsAnchor(.revealSpeed)
            }

            Section("Spaces") {
                Slider(
                    value: Binding(
                        get: { spaceTransitionDuration * 1000 },
                        set: { spaceTransitionDuration = $0 / 1000 }
                    ).undoable("Switching Speed"),
                    in: 0...800, step: 50
                ) {
                    InfoLabel(
                        "Switching speed",
                        info: "Switching spaces slides the tab list over \(String(format: "%.2f", spaceTransitionDuration)) s.")
                } minimumValueLabel: {
                    Text("Fast")
                } maximumValueLabel: {
                    Text("Slow")
                }
                .settingsAnchor(.spaceSwitchSpeed)
            }
        }
        .formStyle(.grouped)
    }
}

/// pinned tabs, their hover cards, and split view
struct TabsSettings: View {
    @AppStorage(PinnedSeparationKeep.storageKey) private var pinnedSeparationKeepRaw = PinnedSeparationKeep.pinnedStays.rawValue
    @AppStorage(PinnedSeparationDestination.storageKey) private var pinnedSeparationDestinationRaw = PinnedSeparationDestination.todayBottom.rawValue
    @AppStorage(SplitOrientation.defaultKey) private var defaultSplitOrientationRaw = SplitOrientation.columns.rawValue
    @AppStorage("dimInactivePanes") private var dimInactivePanes = false
    @AppStorage("autoResizeSplitOnDrag") private var autoResizeSplitOnDrag = true
    @AppStorage("defaultSplitLinked") private var defaultSplitLinked = false
    @AppStorage("showSplitDropGuides") private var showSplitDropGuides = true
    @AppStorage(TabPreviewCard.enabledKey) private var showsPreviews = true

    var body: some View {
        Form {
            Section {
                Picker(selection: $pinnedSeparationKeepRaw.undoable("Pinned Separation")) {
                    ForEach(PinnedSeparationKeep.allCases) { keep in
                        Text(keep.label).tag(keep.rawValue)
                    }
                } label: {
                    InfoLabel(
                        "When separating",
                        info: "⌘-click an off-anchor pinned tab's favicon to split it in two. This picks which one keeps the pinned slot.")
                }
                .settingsAnchor(.pinnedSeparation)

                Picker(selection: $pinnedSeparationDestinationRaw.undoable("Split-Off Tab Destination")) {
                    ForEach(PinnedSeparationDestination.allCases) { dest in
                        Text(dest.label).tag(dest.rawValue)
                    }
                } label: {
                    InfoLabel("Split-off tab goes to", info: "Where the tab that splits off lands.")
                }
                .settingsAnchor(.splitOffDestination)
            } header: {
                InfoLabel("Pinned Tabs", info: "How long unpinned tabs stay before archiving is set per profile.")
            }

            Section {
                Toggle(isOn: $showsPreviews.undoable("Previews")) {
                    InfoLabel(
                        "Show previews",
                        info: "Rest the pointer on a pinned tab or favourite to see what's new there. Nothing is fetched in incognito or locked spaces.")
                }
                .settingsAnchor(.tabPreviews)
                ForEach(TabPreviewCard.Kind.allCases) { kind in
                    PreviewKindToggle(kind: kind)
                        .disabled(!showsPreviews)
                        .settingsAnchor(kind == TabPreviewCard.Kind.allCases.first ? .previewSites : nil)
                }
            } header: {
                Text("Previews")
            }

            Section("Split View") {
                Picker(selection: $defaultSplitOrientationRaw.undoable("Split Direction")) {
                    ForEach(SplitOrientation.allCases) { orientation in
                        Text(orientation.label).tag(orientation.rawValue)
                    }
                } label: {
                    InfoLabel(
                        "New splits open",
                        info: "The direction a new split opens in. Drag the handle at a pane's top right to rearrange it later.")
                }
                .settingsAnchor(.splitDirection)

                Toggle(isOn: $autoResizeSplitOnDrag.undoable("Auto-Resize Panes")) {
                    InfoLabel(
                        "Auto-resize panes on drag",
                        info: "Rearranging panes evens out their sizes. Turn it off to keep the sizes you set by hand.")
                }
                .settingsAnchor(.autoResizePanes)

                Toggle(isOn: $dimInactivePanes.undoable("Dim Inactive Panes")) {
                    InfoLabel("Dim inactive panes", info: "Fades the panes you're not using so the focused one stands out.")
                }
                .settingsAnchor(.dimInactivePanes)

                Toggle(isOn: $defaultSplitLinked.undoable("Linked Splits")) {
                    InfoLabel(
                        "Open links in the next pane",
                        info: "New splits start linked, so a link clicked in one pane opens in the next. Change it per pane with the link button.")
                }
                .settingsAnchor(.linkedSplits)

                Toggle(isOn: $showSplitDropGuides.undoable("Drop Guides")) {
                    InfoLabel(
                        "Show drop guides while dragging",
                        info: "Shows where to drop a pane for each split direction while you drag it.")
                }
                .settingsAnchor(.dropGuides)
            }
        }
        .formStyle(.grouped)
    }
}

/// one site's switch under Previews, on until turned off
private struct PreviewKindToggle: View {
    let kind: TabPreviewCard.Kind
    @AppStorage private var isOn: Bool

    init(kind: TabPreviewCard.Kind) {
        self.kind = kind
        _isOn = AppStorage(wrappedValue: true, kind.storageKey)
    }

    var body: some View {
        Toggle(isOn: $isOn.undoable("\(kind.label) Previews")) {
            InfoLabel(kind.label, info: info)
        }
    }

    private var info: String {
        switch kind {
        case .gmail: "Your newest unread emails, read with this profile's Gmail sign-in."
        case .icloudMail: "Your newest unread emails, read with this profile's iCloud sign-in."
        case .webmail: "Yahoo, AOL, Proton, HEY and Fastmail read with this profile's sign-in. Zoho shows its count while its tab is open."
        case .outlook: "Your newest unread emails, read from your Outlook tab's own page. Works where a school or work account blocks mail apps."
        case .github: "A repository's latest open issues and pull requests."
        case .recentPages: "Pages you visited lately on Notion, Linear, Figma and Confluence."
        case .notifications: "The last notifications a pinned site sent you."
        }
    }
}

private struct AppIconTile: View {
    let choice: AppIconChoice
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(spacing: 4) {
                if let image = choice.image(dark: AppIconChoice.iconsAreDark) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 64, height: 64)
                }
                Text(choice.label)
                    .font(.caption)
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(1)
            }
            .padding(6)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? Color.accentColor.opacity(0.18) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// bangs of your own, which win over the built-in table when the trigger clashes
private struct CustomBangsEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var bangs: [Bang] = Bangs.custom
    @State private var trigger = ""
    @State private var name = ""
    @State private var template = ""

    /// the trigger as stored: lowercased, without its `!`
    private var key: String {
        trigger.lowercased().trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "!"))
    }

    /// a trigger is one word, since the bar splits what you type on spaces, and the
    /// destination is a web address
    private var canAdd: Bool {
        let scheme = URL(string: template.replacingOccurrences(of: "{q}", with: "x"))?.scheme?.lowercased()
        return !key.isEmpty && !key.contains(where: \.isWhitespace) && !name.isEmpty
            && template.contains("{q}") && (scheme == "http" || scheme == "https")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Custom Bangs")
                .font(.headline)

            Table(bangs) {
                TableColumn("Bang") { Text("!" + $0.trigger).monospaced() }
                    .width(90)
                TableColumn("Name", value: \.name)
                TableColumn("Destination", value: \.template)
                TableColumn("") { bang in
                    Button("Remove") { remove(bang) }
                        .buttonStyle(.link)
                }
                .width(70)
            }
            .frame(minHeight: 200)

            HStack {
                TextField("trigger", text: $trigger).frame(width: 80)
                TextField("Name", text: $name).frame(width: 140)
                TextField("https://example.com/search?q={q}", text: $template)
                Button("Add", action: add).disabled(!canAdd)
            }

            Text("{q} is where the rest of what you type goes.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 620)
    }

    private func add() {
        guard canAdd else { return }
        bangs.removeAll { $0.trigger == key }
        bangs.append(Bang(trigger: key, name: name, template: template))
        Bangs.setCustom(bangs)
        trigger = ""
        name = ""
        template = ""
    }

    private func remove(_ bang: Bang) {
        bangs.removeAll { $0.trigger == bang.trigger }
        Bangs.setCustom(bangs)
    }
}
