// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import AppKit
import SwiftUI

nonisolated enum SettingsPane: String, CaseIterable, Identifiable {
    var id: Self { self }
    case general = "General"
    case appearance = "Appearance"
    case profiles = "Profiles"
    case privacy = "Privacy & Security"
    case sidebar = "Sidebar"
    case tabs = "Tabs"
    case links = "Links"
    case search = "Search"
    case extensions = "Extensions"
    case intelligence = "Intelligence"
    case agents = "Agents"

    fileprivate static let groups: [[SettingsPane]] = {
        var groups: [[SettingsPane]] = [
            [.general, .appearance, .profiles, .privacy],
            [.sidebar, .tabs, .links, .search],
            [.extensions, .intelligence, .agents],
        ]
        return groups
    }()

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .appearance: "paintbrush.fill"
        case .profiles: "person.2.fill"
        case .privacy: "hand.raised.fill"
        case .sidebar: "sidebar.left"
        case .tabs: "square.on.square.fill"
        case .links: "arrow.triangle.branch"
        case .search: "magnifyingglass"
        case .extensions: "puzzlepiece.extension.fill"
        case .intelligence: "sparkles"
        case .agents: "terminal.fill"
        }
    }
}

struct SettingsView: View {
    static let paneKey = "settingsPane"
    @AppStorage(paneKey) private var selectedPane: SettingsPane = .general
    @State private var back: [SettingsPane] = []
    @State private var forward: [SettingsPane] = []
    /// where Back or Forward is moving to, which records no history of its own
    @State private var stepTarget: SettingsPane?
    @State private var query = ""
    @State private var profiles = ProfilesNavigator.shared
    @State private var spotlight = SettingsSpotlight.shared
    @State private var hits: [SettingID] = []
    /// the on-device model is reading the query
    @State private var asking = false

    /// SwiftUI's own opener, handed over by a browser window; the legacy selector is
    /// the fallback when no window is open, and does nothing from a floating panel
    @MainActor static var openSettingsAction: OpenSettingsAction?

    @MainActor
    static func open(_ pane: SettingsPane? = nil) {
        if let pane { UserDefaults.standard.set(pane.rawValue, forKey: paneKey) }
        NSApp.activate()
        if let openSettingsAction {
            openSettingsAction()
        } else {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
    }

    var body: some View {
        NavigationSplitView {
            SettingsSidebar(
                selection: selectedPane, query: query, hits: hits, asking: asking,
                select: go, open: openProfilePage, reveal: { spotlight.reveal($0) })
                .searchable(text: $query, placement: .sidebar, prompt: "Search settings")
                .onSubmit(of: .search) { if let first = hits.first { spotlight.reveal(first) } }
                .task(id: query) { await find(query) }
                .navigationSplitViewColumnWidth(240)
        } detail: {
            ScrollViewReader { proxy in
                page(selectedPane)
                    .coordinateSpace(.named(SettingsSpotlight.space))
                    .onChange(of: spotlight.pending, initial: true) { _, id in
                        if let id { Task { await reveal(id, proxy) } }
                    }
            }
            .navigationTitle(subpage?.title ?? selectedPane.rawValue)
            // a profile's page says whose it is
            .navigationSubtitle(subpage == nil ? "" : profiles.profile.name)
            .toolbar {
                ToolbarItemGroup(placement: .navigation) {
                    Button(action: goBack) { Image(systemName: "chevron.left") }
                        .disabled(back.isEmpty && subpage == nil)
                        .help(subpage == nil ? "Back" : "Back to \(profiles.profile.name)")
                        .accessibilityLabel("Back")
                    Button(action: goForward) { Image(systemName: "chevron.right") }
                        .disabled(forward.isEmpty)
                        .accessibilityLabel("Forward")
                }
            }
    }
        .frame(width: 900, height: 700)
        .background(UnifiedToolbar())
        // every change of pane is history, a link inside a page or an `open` from outside included
        .onChange(of: selectedPane) { old, new in
            if new == stepTarget {
                stepTarget = nil
                return
            }
            back.append(old)
            forward.removeAll()
        }
    }

    /// the profile page open under Profiles, if one is
    private var subpage: ProfilesNavigator.Page? { selectedPane == .profiles ? profiles.page : nil }

    private func go(_ pane: SettingsPane) {
        // choosing Profiles again from the sidebar comes back up to the list
        if pane == .profiles, subpage != nil { withAnimation(Motion.panel) { profiles.page = nil } }
        selectedPane = pane
    }

    private func openProfilePage(_ page: ProfilesNavigator.Page) {
        profiles.selected = profiles.profile.id
        go(.profiles)
        withAnimation(Motion.panel) { profiles.page = page }
    }

    private func find(_ query: String) async {
        asking = false
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            hits = []
            return
        }
        let found = await SettingsSearch.shared.search(query).filter(\.isAvailable)
        guard !Task.isCancelled else { return }
        hits = found
        // a question, or words nothing matched, goes to the model once typing pauses
        let words = query.split(separator: " ").count
        guard Intelligence.isEnabled, words >= 3 || found.isEmpty else { return }
        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled else { return }
        asking = true
        let ideas = await Intelligence.shared.settingTerms(for: query)
        guard !Task.isCancelled else { return }
        asking = false
        guard let ideas else { return }
        hits = await SettingsSearch.shared.search(query, ideas: ideas).filter(\.isAvailable)
    }

    /// shows the setting's page, scrolls its row to the middle and lights it for a moment
    private func reveal(_ id: SettingID, _ proxy: ScrollViewProxy) async {
        spotlight.pending = nil
        let entry = id.entry
        if let page = entry.page {
            openProfilePage(page)
        } else {
            go(entry.pane)
            if entry.pane == .profiles { profiles.page = nil }
        }
        // the new page's rows exist only after its first layout
        try? await Task.sleep(for: .milliseconds(120))
        withAnimation(Motion.panel) { proxy.scrollTo(id, anchor: .center) }
        spotlight.lit = id
        try? await Task.sleep(for: .seconds(1.8))
        if spotlight.lit == id { spotlight.lit = nil }
    }

    private func goBack() {
        // a profile's page steps back out to the profile before leaving the pane
        if subpage != nil {
            withAnimation(Motion.panel) { profiles.page = nil }
            return
        }
        guard let pane = back.popLast() else { return }
        forward.append(selectedPane)
        stepTarget = pane
        selectedPane = pane
    }

    private func goForward() {
        guard let pane = forward.popLast() else { return }
        back.append(selectedPane)
        stepTarget = pane
        selectedPane = pane
    }

    @ViewBuilder
    private func page(_ pane: SettingsPane) -> some View {
        switch pane {
        case .general: GeneralSettings()
        case .appearance: AppearanceSettings()
        case .profiles: ProfilesSettings()
        case .privacy: PrivacySettings()
        case .extensions: ExtensionsSettings()
        case .search: SearchSettings()
        case .sidebar: SidebarSettings()
        case .tabs: TabsSettings()
        case .links: LinksSettings()
        case .intelligence: IntelligenceSettings()
        case .agents: AgentSettings()
        }
    }
}

/// the Settings scene forces the preferences toolbar (centred title over centred
/// buttons) and ignores `.windowToolbarStyle`; unified puts them in one row
private struct UnifiedToolbar: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.toolbarStyle = .unified
        }
    }
}

private struct SettingsSidebar: View {
    let selection: SettingsPane
    let query: String
    let hits: [SettingID]
    let asking: Bool
    let select: (SettingsPane) -> Void
    let open: (ProfilesNavigator.Page) -> Void
    let reveal: (SettingID) -> Void
    @AppStorage(AppIconChoice.storageKey) private var iconRaw = AppIconChoice.bundled.rawValue

    private var icon: AppIconChoice { AppIconChoice(rawValue: iconRaw) ?? .bundled }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if query.isEmpty {
                    AppCard(icon: icon)
                    ForEach(SettingsPane.groups, id: \.self) { group in
                        rows(group)
                    }
                } else {
                    let found = SettingsPane.allCases.filter { $0.rawValue.localizedCaseInsensitiveContains(query) }
                    let pages = [ProfilesNavigator.Page.passwords, .autofill, .clearData].filter {
                        $0.title.localizedCaseInsensitiveContains(query)
                    }
                    if asking {
                        ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                    } else if hits.isEmpty && found.isEmpty && pages.isEmpty {
                        Text("Nothing matches “\(query)”")
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                    }
                    if !hits.isEmpty {
                        VStack(spacing: 2) {
                            ForEach(hits, id: \.self) { id in
                                SettingHitRow(id: id, icon: icon) { reveal(id) }
                            }
                        }
                    }
                    // a profile's own pages, reached in one click rather than via Profiles
                    if !pages.isEmpty {
                        VStack(spacing: 2) {
                            ForEach(pages, id: \.self) { page in
                                ProfilePageRow(page: page, icon: icon) { open(page) }
                            }
                        }
                    }
                    rows(found)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private func rows(_ panes: [SettingsPane]) -> some View {
        VStack(spacing: 2) {
            ForEach(panes) { pane in
                SettingsRow(pane: pane, icon: icon, isSelected: pane == selection) { select(pane) }
            }
        }
    }
}

/// a search hit that is a page inside Profiles: opens it for the profile in use
private struct ProfilePageRow: View {
    let page: ProfilesNavigator.Page
    let icon: AppIconChoice
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                SettingsBadge(pane: .profiles, icon: icon)
                VStack(alignment: .leading, spacing: 0) {
                    Text(page.title)
                    Text("Profiles › \(ProfilesNavigator.shared.profile.name)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}

/// a search hit that is one setting: its page's badge, its name, and where it lives
private struct SettingHitRow: View {
    let id: SettingID
    let icon: AppIconChoice
    let action: () -> Void

    var body: some View {
        let entry = id.entry
        Button(action: action) {
            HStack(spacing: 10) {
                SettingsBadge(pane: entry.pane, icon: icon)
                VStack(alignment: .leading, spacing: 0) {
                    Text(entry.title).lineLimit(2)
                    Text(id.place)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}

/// the app's icon, name and version, where an account card would sit
private struct AppCard: View {
    let icon: AppIconChoice

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        let channel = Updates.buildChannel.flatMap { $0 == "release" ? nil : " \($0.capitalized)" } ?? ""
        return "Version \(short)\(channel) (\(build))"
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: icon.image(dark: AppIconChoice.iconsAreDark) ?? NSApp.applicationIconImage)
                .resizable()
                .frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text("Artemis").font(.title3.weight(.semibold))
                Text(version).font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 4)
    }
}

private struct SettingsRow: View {
    let pane: SettingsPane
    let icon: AppIconChoice
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 10) {
                SettingsBadge(pane: pane, icon: icon)
                Text(pane.rawValue)
                    .foregroundStyle(isSelected ? .white : .primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? Color.accentColor : .clear))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// a page's symbol drawn like the app icon: its glyph colour on the icon's black
/// (or, with light icons, white) glass
private struct SettingsBadge: View {
    let pane: SettingsPane
    let icon: AppIconChoice
    private let size: CGFloat = 24

    var body: some View {
        let dark = AppIconChoice.iconsAreDark
        let shape = RoundedRectangle(cornerRadius: size * 0.28)
        shape
            .fill(LinearGradient(
                colors: dark ? [Color(white: 0.2), Color(white: 0.06)] : [.white, Color(white: 0.9)],
                startPoint: .top, endPoint: .bottom))
            .overlay(shape.strokeBorder(dark ? .white.opacity(0.14) : .black.opacity(0.1), lineWidth: 0.5))
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: pane.symbol)
                    .font(.system(size: size * 0.52, weight: .semibold))
                    .foregroundStyle(LinearGradient(
                        colors: [icon.glyph.light, icon.glyph.base], startPoint: .top, endPoint: .bottom))
                    .shadow(color: icon.glyph.base.opacity(0.6), radius: 2)
            }
    }
}
