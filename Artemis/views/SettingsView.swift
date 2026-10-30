import AppKit
import SwiftUI

enum Tab: String, CaseIterable, Identifiable {
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

    static let groups: [[Tab]] = [
        [.general, .appearance, .profiles, .privacy],
        [.sidebar, .tabs, .links, .search],
        [.extensions, .intelligence, .agents],
    ]

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

    /// what the sidebar search matches besides the title: the page's section names
    var keywords: [String] {
        switch self {
        case .general: ["Default Browser", "Memory", "Sleep", "Picture in Picture", "Mini-Player"]
        case .appearance: [
            "Window", "Edge thickness", "Now Playing", "Folders", "App Icon",
        ]
        case .profiles: [
            "Passwords", "Passkeys", "Logins", "Cookies", "History", "Favourites", "Clear Browsing Data", "Sign out",
            "Search engine", "Suggestions", "Archive", "Auto-Archive",
        ]
        case .privacy: [
            "Content Blocking", "Ads", "Trackers", "Incognito", "Touch ID", "Fingerprint", "Site Permissions",
            "Camera", "Microphone", "Location", "On-Device Data",
        ]
        case .sidebar: ["Reveal", "Hover", "Spaces", "Switching speed"]
        case .tabs: ["Pinned Tabs", "Split View", "Panes", "Drop guides", "Linked"]
        case .links: ["Routing", "Rules", "Links from other apps", "Peek", "Scout"]
        case .search: ["Bangs", "Page Contents", "Index", "Full text"]
        case .extensions: ["Installed", "Store", "Suggested", "Boosts"]
        case .intelligence: ["Features", "On-device", "AI"]
        case .agents: ["Setup", "Approved Agents", "Connected"]
        }
    }

    func matches(_ query: String) -> Bool {
        ([rawValue] + keywords).contains { $0.localizedCaseInsensitiveContains(query) }
    }
}

struct SettingsView: View {
    private static let paneKey = "settingsPane"
    @AppStorage(paneKey) private var selectedTab: Tab = .general
    @State private var back: [Tab] = []
    @State private var forward: [Tab] = []
    @State private var query = ""
    @State private var profiles = ProfilesNavigator.shared

    /// SwiftUI's own opener, handed over by a browser window; the legacy selector is
    /// the fallback when no window is open, and does nothing from a floating panel
    @MainActor static var openSettingsAction: OpenSettingsAction?

    @MainActor
    static func open(_ pane: Tab? = nil) {
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
            SettingsSidebar(selection: selectedTab, query: query, select: go, open: openProfilePage)
                .searchable(text: $query, placement: .sidebar, prompt: "Search settings")
                .navigationSplitViewColumnWidth(240)
        } detail: {
            page(selectedTab)
                .navigationTitle(subpage?.title ?? selectedTab.rawValue)
                // a profile's page says whose it is
                .navigationSubtitle(subpage == nil ? "" : profiles.profile.name)
                .toolbar {
                    ToolbarItemGroup(placement: .navigation) {
                        Button(action: goBack) { Image(systemName: "chevron.left") }
                            .disabled(back.isEmpty && subpage == nil)
                            .help(subpage == nil ? "Back" : "Back to \(profiles.profile.name)")
                        Button(action: goForward) { Image(systemName: "chevron.right") }
                            .disabled(forward.isEmpty)
                    }
                }
        }
        .frame(width: 900, height: 700)
        .background(UnifiedToolbar())
    }

    /// the profile page open under Profiles, if one is
    private var subpage: ProfilesNavigator.Page? { selectedTab == .profiles ? profiles.page : nil }

    private func go(_ tab: Tab) {
        // choosing Profiles again from the sidebar comes back up to the list
        if tab == .profiles, subpage != nil { withAnimation(Motion.panel) { profiles.page = nil } }
        guard tab != selectedTab else { return }
        back.append(selectedTab)
        forward.removeAll()
        selectedTab = tab
    }

    private func openProfilePage(_ page: ProfilesNavigator.Page) {
        profiles.selected = profiles.profile.id
        go(.profiles)
        withAnimation(Motion.panel) { profiles.page = page }
    }

    private func goBack() {
        // a profile's page steps back out to the profile before leaving the pane
        if subpage != nil {
            withAnimation(Motion.panel) { profiles.page = nil }
            return
        }
        guard let tab = back.popLast() else { return }
        forward.append(selectedTab)
        selectedTab = tab
    }

    private func goForward() {
        guard let tab = forward.popLast() else { return }
        back.append(selectedTab)
        selectedTab = tab
    }

    @ViewBuilder
    private func page(_ tab: Tab) -> some View {
        switch tab {
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
    let selection: Tab
    let query: String
    let select: (Tab) -> Void
    let open: (ProfilesNavigator.Page) -> Void
    @AppStorage(AppIconChoice.storageKey) private var iconRaw = AppIconChoice.bundled.rawValue

    private var icon: AppIconChoice { AppIconChoice(rawValue: iconRaw) ?? .bundled }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if query.isEmpty {
                    AppCard(icon: icon)
                    ForEach(Tab.groups, id: \.self) { group in
                        rows(group)
                    }
                } else {
                    let found = Tab.allCases.filter { $0.matches(query) }
                    let pages = [ProfilesNavigator.Page.passwords, .clearData].filter {
                        $0.title.localizedCaseInsensitiveContains(query)
                    }
                    if found.isEmpty && pages.isEmpty {
                        Text("Nothing matches “\(query)”")
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
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

    private func rows(_ tabs: [Tab]) -> some View {
        VStack(spacing: 2) {
            ForEach(tabs) { tab in
                SettingsRow(tab: tab, icon: icon, isSelected: tab == selection) { select(tab) }
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
                SettingsBadge(tab: .profiles, icon: icon)
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

/// the app's icon, name and version, where an account card would sit
private struct AppCard: View {
    let icon: AppIconChoice

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "Version \(short) (\(build))"
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
    let tab: Tab
    let icon: AppIconChoice
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 10) {
                SettingsBadge(tab: tab, icon: icon)
                Text(tab.rawValue)
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
    }
}

/// a page's symbol drawn like the app icon: its glyph colour on the icon's black
/// (or, with light icons, white) glass
private struct SettingsBadge: View {
    let tab: Tab
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
                Image(systemName: tab.symbol)
                    .font(.system(size: size * 0.52, weight: .semibold))
                    .foregroundStyle(LinearGradient(
                        colors: [icon.glyph.light, icon.glyph.base], startPoint: .top, endPoint: .bottom))
                    .shadow(color: icon.glyph.base.opacity(0.6), radius: 2)
            }
    }
}
