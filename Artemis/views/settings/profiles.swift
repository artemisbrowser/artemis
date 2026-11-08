// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import AppKit
import SwiftUI

/// which profile the Profiles pane shows, and which of its pages. Shared so the
/// password key, the command bar and the profile button can open straight to one
@MainActor
@Observable
final class ProfilesNavigator {
    static let shared = ProfilesNavigator()

    enum Page { case passwords, autofill, clearData }

    var selected: Profile.ID?
    var page: Page?
    /// a profile just added, whose name field takes the keyboard when it shows
    var naming: Profile.ID?

    /// open Settings on `profile`, at `page` or its overview
    static func show(_ page: Page? = nil, for profile: Profile.ID) {
        shared.selected = profile
        shared.page = page
        SettingsView.open(.profiles)
    }

    /// the profile on show, falling back to the one the browser is in
    var profile: Profile {
        let core = BrowserCore.shared
        return core.profile(selected)
            ?? BrowserWindows.shared.browserScope?.currentProfile ?? core.defaultProfile
    }
}

extension ProfilesNavigator.Page {
    var title: String {
        switch self {
        case .passwords: "Passwords"
        case .autofill: "Autofill"
        case .clearData: "Clear Browsing Data"
        }
    }
}

/// Profiles: the identities spaces browse as. A list on the left, the chosen
/// profile on the right, and its passwords and data one level down.
struct ProfilesSettings: View {
    @State private var navigator = ProfilesNavigator.shared

    var body: some View {
        let profile = navigator.profile
        switch navigator.page {
        case .passwords:
            PasswordsSettings(profileID: profile.id)
                .id(profile.id)
                .transition(Motion.slide(.trailing))
        case .autofill:
            AutofillSettings(profileID: profile.id)
                .id(profile.id)
                .transition(Motion.slide(.trailing))
        case .clearData:
            ClearBrowsingDataSettings(profile: profile)
                .id(profile.id)
                .transition(Motion.slide(.trailing))
        case nil:
            overview(profile).transition(Motion.slide(.leading))
        }
    }

    /// the list sits in the same 20pt margins the grouped form beside it draws.
    /// The reader pins the pane to the window, so the two columns share its height
    private func overview(_ profile: Profile) -> some View {
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: 0) {
                Text("Profiles keep your data separate across spaces: logins, cookies, history, favourites and passwords. Any profile can be used by one or more spaces.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding([.horizontal, .top], 20)
                HStack(alignment: .top, spacing: 0) {
                    ProfileList(selection: Binding(get: { profile.id }, set: { navigator.selected = $0 }))
                        .frame(width: 220)
                        .frame(maxHeight: .infinity)
                        .padding([.leading, .vertical], 20)
                    // one view per profile, so a pending rename commits to the profile it began on
                    ProfileDetail(profile: profile)
                        .id(profile.id)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
    }
}

// MARK: - List

private struct ProfileList: View {
    @Environment(TabManager.self) private var tabManager
    @Binding var selection: Profile.ID

    var body: some View {
        VStack(spacing: 0) {
            Text("Your Profiles")
                .font(.headline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            Divider()
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(tabManager.profiles) { profile in
                        ProfileListRow(
                            profile: profile, spaces: spaceCount(profile),
                            isSelected: profile.id == selection
                        ) { selection = profile.id }
                    }
                }
                .padding(8)
            }
            Divider()
            HStack(spacing: 0) {
                footerButton("plus", label: "New Profile", action: add)
                Divider().frame(height: 16)
                footerButton("minus", label: "Delete Profile…", action: delete)
                    .disabled(selectedProfile?.isDefault != false)
                Spacer()
            }
            .padding(.horizontal, 4)
            .frame(height: 30)
        }
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.background.secondary))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator))
    }

    private var selectedProfile: Profile? { tabManager.core.profile(selection) }

    private func spaceCount(_ profile: Profile) -> Int {
        tabManager.spaces.filter { $0.profileID == profile.id }.count
    }

    private func footerButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 28, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(label)
        .accessibilityLabel(label)
    }

    private func add() {
        let profile = tabManager.createProfile(name: uniqueName(), icon: "person.crop.circle")
        ProfilesNavigator.shared.naming = profile.id
        selection = profile.id
    }

    /// "New Profile", then "New Profile 2", so a second press never makes a twin
    private func uniqueName() -> String {
        let names = Set(tabManager.profiles.map(\.name))
        var name = "New Profile"
        var n = 2
        while names.contains(name) {
            name = "New Profile \(n)"
            n += 1
        }
        return name
    }

    private func delete() {
        guard let profile = selectedProfile, ProfileDeletion.confirm(profile, in: tabManager) else { return }
        selection = Profile.defaultID
        tabManager.deleteProfile(profile)
    }
}

private struct ProfileListRow: View {
    let profile: Profile
    let spaces: Int
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 8) {
                SpaceGlyph(icon: profile.icon, size: 13)
                    .frame(width: 18)
                Text(profile.name)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(spaces == 0 ? "Not used" : spaces == 1 ? "1 space" : "\(spaces) spaces")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 8)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.22) : .clear))
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Detail

private struct ProfileDetail: View {
    @Environment(TabManager.self) private var tabManager
    @Environment(ExtensionManager.self) private var extensions
    let profile: Profile
    @State private var name = ""
    @State private var showingIconPicker = false
    @State private var siteCount: Int?
    @State private var isRenaming = false
    @FocusState private var nameFocused: Bool

    private var spaces: [Space] { tabManager.spaces.filter { $0.profileID == profile.id } }

    private var extensionSummary: String {
        let count = extensions.installed.filter { $0.profiles.contains(profile.id) }.count
        return count == 0 ? "None enabled" : count == 1 ? "1 enabled" : "\(count) enabled"
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    Button {
                        showingIconPicker.toggle()
                    } label: {
                        SpaceGlyph(icon: profile.icon, size: 20)
                            .frame(width: 40, height: 40)
                            .background(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(.primary.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                    .help("Change Icon")
                    .accessibilityLabel("Change Icon")
                    .popover(isPresented: $showingIconPicker, arrowEdge: .bottom) {
                        IconPicker(
                            icon: Binding(
                                get: { profile.icon }, set: { tabManager.updateProfile(profile, icon: $0) }
                            ).undoable("Profile Icon"))
                    }
                    if isRenaming {
                        TextField("Name", text: $name, prompt: Text("Profile name"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .font(.title3)
                            .focused($nameFocused)
                            .onSubmit(commitName)
                            .onExitCommand {
                                name = profile.name
                                isRenaming = false
                            }
                            .onChange(of: nameFocused) { _, focused in if !focused { commitName() } }
                    } else {
                        Text(profile.name)
                            .font(.title3.weight(.semibold))
                            .lineLimit(1)
                        Spacer()
                        Button("Rename") { beginRename() }
                    }
                }
            }

            Section {
                if spaces.isEmpty {
                    Text("No space uses this profile yet. Choose one from the profile button at the bottom right of the sidebar, or in a space's settings.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    FlowLayout(spacing: 6) {
                        ForEach(spaces) { space in SpaceChip(space: space) }
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text(spaces.count == 1 ? "Used by 1 Space" : "Used by \(spaces.count) Spaces")
            }

            Section("Search") {
                Picker("Search engine", selection: bind(\.searchEngine, "Search Engine")) {
                    ForEach(SearchEngine.allCases) { engine in
                        Text(engine.label).tag(engine)
                    }
                }
                // the ⓘ stays outside the disabled toggle: it's what says why it's off
                LabeledContent {
                    Toggle("Search engine suggestions", isOn: bind(\.suggestsSearches, "Search Suggestions"))
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .disabled(!SearchSuggest.supports(profile.searchEngine))
                } label: {
                    InfoLabel(
                        "Search engine suggestions",
                        info: SearchSuggest.supports(profile.searchEngine)
                            ? "Shows \(profile.searchEngine.label) completions in the command bar by sending them what you type. Never used in incognito windows."
                            : "Artemis can't get completions from \(profile.searchEngine.label), so this is unavailable.")
                }
                LabeledContent("Bangs and shortcuts") {
                    Button("Search Settings…") { SettingsView.open(.search) }
                }
            }

            Section("Tabs") {
                Picker(selection: bind(\.archiveAfterHours, "Archive Timing")) {
                    ForEach([0.0, 6, 12, 24, 48, 168], id: \.self) { hours in
                        Text(Self.archiveLabel(hours)).tag(hours)
                    }
                } label: {
                    InfoLabel(
                        "Archive tabs after",
                        info: "Today tabs in this profile's spaces that you leave untouched move to the Library. Pinned tabs and favourites are never archived.")
                }
            }

            TranslationSection(rules: profile.translationRules)

            Section("Your Data") {
                DataRow(
                    title: "Passwords", detail: passwordSummary, symbol: "key.fill", tint: .green
                ) { open(.passwords) }
                DataRow(title: "Autofill", detail: autofillSummary, symbol: "creditcard.fill", tint: .blue) {
                    open(.autofill)
                }
                DataRow(
                    title: "Clear Browsing Data",
                    detail: siteCount.map { $0 == 1 ? "1 site storing data" : "\($0) sites storing data" },
                    symbol: "trash.fill", tint: .red
                ) { open(.clearData) }
                LabeledContent("Extensions", value: extensionSummary)
            }

            if !profile.isDefault {
                Section {
                    Button("Delete Profile…", role: .destructive) {
                        guard ProfileDeletion.confirm(profile, in: tabManager) else { return }
                        ProfilesNavigator.shared.selected = Profile.defaultID
                        tabManager.deleteProfile(profile)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: takeNaming)
        .onDisappear { if isRenaming { commitName() } }
        .task { siteCount = await PrivacyCleaner.siteRecordCount(in: profile) }
    }

    /// a profile setting that saves with the session when it changes
    private func bind<Value: Equatable>(_ key: ReferenceWritableKeyPath<Profile, Value>, _ setting: String) -> Binding<Value> {
        Binding(
            get: { profile[keyPath: key] },
            set: {
                profile[keyPath: key] = $0
                tabManager.scheduleSave()
            }
        ).undoable(setting)
    }

    private static func archiveLabel(_ hours: Double) -> String {
        switch hours {
        case 0: "Never"
        case ..<24: "\(Int(hours)) hours"
        case 24: "1 day"
        case 168: "1 week"
        default: "\(Int(hours / 24)) days"
        }
    }

    private var passwordSummary: String {
        let store = PasswordStore.shared
        let sites = Set(store.logins(in: profile.id).map(\.host)).count
        let keys = store.passkeys(in: profile.id).count
        switch (sites, keys) {
        case (0, 0): return "None saved"
        case (_, 0): return sites == 1 ? "1 website" : "\(sites) websites"
        case (0, _): return keys == 1 ? "1 passkey" : "\(keys) passkeys"
        default: return "\(sites == 1 ? "1 website" : "\(sites) websites"), \(keys == 1 ? "1 passkey" : "\(keys) passkeys")"
        }
    }

    private var autofillSummary: String {
        let store = AutofillStore.shared
        let places = store.addresses(in: profile.id).count, cards = store.cards(in: profile.id).count
        let parts = [
            places == 0 ? nil : places == 1 ? "1 address" : "\(places) addresses",
            cards == 0 ? nil : cards == 1 ? "1 card" : "\(cards) cards",
        ].compactMap { $0 }
        return parts.isEmpty ? "None saved" : parts.joined(separator: ", ")
    }

    private func open(_ page: ProfilesNavigator.Page) {
        if isRenaming { commitName() }
        withAnimation(Motion.panel) { ProfilesNavigator.shared.page = page }
    }

    /// a profile just added opens straight into naming it
    private func takeNaming() {
        guard ProfilesNavigator.shared.naming == profile.id else { return }
        ProfilesNavigator.shared.naming = nil
        beginRename()
    }

    private func beginRename() {
        name = profile.name
        isRenaming = true
        DispatchQueue.main.async { nameFocused = true }
    }

    private func commitName() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != profile.name {
            Binding(get: { profile.name }, set: { tabManager.updateProfile(profile, name: $0) })
                .undoable("Profile Name").wrappedValue = trimmed
        }
        isRenaming = false
    }
}

/// the language pages translate into, and the rules made from the translate button
private struct TranslationSection: View {
    let rules: TranslationRules
    @State private var targets: [Locale.Language] = []

    var body: some View {
        Section("Translation") {
            Picker(
                selection: Binding(
                    get: { targets.first { PageTranslation.sameTarget($0, rules.target) } ?? rules.target },
                    set: { rules.setTarget($0) }
                ).undoable("Translation Language")
            ) {
                ForEach(targets, id: \.self) { Text(PageTranslation.name(of: $0)).tag($0) }
            } label: {
                InfoLabel(
                    "Translate pages to",
                    info: "Pages are translated on this Mac. Rules are made from the translate button while a page is translated.")
            }
            ForEach(rules.languages, id: \.self) { code in
                rule("Always translate \(PageTranslation.name(of: Locale.Language(identifier: code)))") {
                    rules.setAlways(code, false)
                }
            }
            ForEach(rules.sites, id: \.self) { site in
                rule("Never translate \(site)") { rules.setNever(site, false) }
            }
        }
        .task { targets = await PageTranslation.targetLanguages() }
    }

    private func rule(_ title: String, remove: @escaping () -> Void) -> some View {
        LabeledContent(title) { Button("Remove", action: remove) }
    }
}

/// a space using the profile, in its own icon and accent
private struct SpaceChip: View {
    let space: Space

    var body: some View {
        HStack(spacing: 5) {
            SpaceGlyph(icon: space.icon, size: 11)
                .foregroundStyle(space.appearance.accent)
            Text(space.name)
                .lineLimit(1)
        }
        .font(.callout)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(.primary.opacity(0.07)))
    }
}

/// rows of chips that wrap at the edge
private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: rows.width, height: rows.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (index, origin) in arrange(subviews, width: bounds.width).origins.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> (origins: [CGPoint], width: CGFloat, height: CGFloat) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (origins, widest, y + rowHeight)
    }
}

/// one way into a profile's data, Arc-style: a tinted badge, a title, what's
/// there, and an arrow that says it opens a page
private struct DataRow: View {
    let title: String
    let detail: String?
    let symbol: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(tint.gradient))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                    if let detail {
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// the one confirmation every delete goes through, saying what goes with it
@MainActor
private enum ProfileDeletion {
    static func confirm(_ profile: Profile, in tabManager: TabManager) -> Bool {
        let store = PasswordStore.shared
        let passwords = store.logins(in: profile.id).count + store.passkeys(in: profile.id).count
        let spaces = tabManager.spaces.filter { $0.profileID == profile.id }.count
        let home = tabManager.core.defaultProfile.name
        var detail = "Its history, favourites, cookies and site data are deleted."
        if passwords > 0 {
            detail += passwords == 1 ? " So is 1 saved password." : " So are \(passwords) saved passwords and passkeys."
        }
        let autofill = AutofillStore.shared
        if !autofill.addresses(in: profile.id).isEmpty || !autofill.cards(in: profile.id).isEmpty {
            detail += " So are its saved addresses and cards."
        }
        if spaces > 0 {
            detail += spaces == 1 ? " Its space moves to \(home)." : " Its \(spaces) spaces move to \(home)."
        }
        let alert = NSAlert()
        alert.messageText = "Delete \(profile.name)?"
        alert.informativeText = detail
        alert.addButton(withTitle: "Delete").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

// MARK: - Clear Browsing Data

/// one profile's clear: its own history, cookies, caches, archive and page text,
/// plus the few things every profile shares
struct ClearBrowsingDataSettings: View {
    @Environment(TabManager.self) private var tabManager
    let profile: Profile

    @State private var range: ClearRange = .all
    @State private var targets: ClearTargets = [.history, .cache]
    @State private var confirming = false
    @State private var working = false
    @State private var siteCount: Int?
    @State private var clearedAt: Date?

    var body: some View {
        Form {
            Section {
                Picker("Time range", selection: $range) {
                    ForEach(ClearRange.allCases) { option in
                        Text(option.label.capitalizedFirst).tag(option)
                    }
                }
            }

            Section {
                toggle("Browsing history", .history)
                toggle("Cookies and site data", .siteData)
                toggle("Cached files and images", .cache)
                toggle("Archived tabs", .archive)
                toggle("Indexed page text", .pageText)
                toggle("Saved addresses and cards", .autofill)
                if targets.contains(.siteData) {
                    Label("Signs \(profile.name) out of sites.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text(profile.name)
            } footer: {
                if let siteCount {
                    Text(siteCount == 1 ? "1 site storing data" : "\(siteCount) sites storing data")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            Section {
                toggle("Downloads list", .downloads)
                toggle("Per-site zoom levels", .zoom)
                toggle("Site permissions", .permissions)
            } header: {
                InfoLabel(
                    "Every Profile",
                    info: "These aren't kept per profile, so clearing them clears them everywhere. The time range doesn't apply to them.")
            }

            Section {
                HStack {
                    if let clearedAt {
                        Text("Cleared \(clearedAt.formatted(date: .omitted, time: .shortened)).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if working { ProgressView().controlSize(.small) }
                    Button("Clear…", role: .destructive) { confirming = true }
                        .disabled(targets.isEmpty || working)
                }
            }
        }
        .formStyle(.grouped)
        .task { siteCount = await PrivacyCleaner.siteRecordCount(in: profile) }
        .confirmationDialog(
            "Clear \(summary) from \(range.label)?", isPresented: $confirming, titleVisibility: .visible
        ) {
            Button("Clear", role: .destructive) { performClear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text((untimed.map { "The time range doesn't apply to \($0). " } ?? "") + "This can't be undone.")
        }
    }

    private func toggle(_ label: String, _ target: ClearTargets) -> some View {
        Toggle(
            label,
            isOn: Binding(
                get: { targets.contains(target) },
                set: { on in
                    if on { targets.insert(target) } else { targets.remove(target) }
                }))
    }

    /// the picked items with no timestamps, which a shorter range still clears in full
    private var untimed: String? {
        guard range != .all else { return nil }
        let names: [(ClearTargets, String)] = [
            (.downloads, "the downloads list"), (.zoom, "zoom levels"), (.permissions, "site permissions"),
        ]
        let picked = names.filter { targets.contains($0.0) }.map(\.1)
        guard let last = picked.last else { return nil }
        return picked.count == 1 ? last : picked.dropLast().joined(separator: ", ") + " or " + last
    }

    /// plain-language list of what's about to go, for the confirmation title
    private var summary: String {
        let names: [(ClearTargets, String)] = [
            (.history, "history"), (.siteData, "cookies"), (.cache, "caches"), (.archive, "archived tabs"),
            (.pageText, "page text"), (.autofill, "addresses and cards"), (.downloads, "the downloads list"), (.zoom, "zoom levels"),
            (.permissions, "site permissions"),
        ]
        let picked = names.filter { targets.contains($0.0) }.map(\.1)
        let list: String
        switch picked.count {
        case 0: list = "nothing"
        case 1: list = picked[0]
        default: list = picked.dropLast().joined(separator: ", ") + " and " + picked[picked.count - 1]
        }
        return targets.subtracting(.shared).isEmpty ? list : "\(profile.name)'s \(list)"
    }

    private func performClear() {
        working = true
        Task {
            await PrivacyCleaner.clear(targets, range: range, in: profile, manager: tabManager)
            siteCount = await PrivacyCleaner.siteRecordCount(in: profile)
            clearedAt = Date()
            working = false
        }
    }
}

private extension String {
    /// "the last hour" → "The last hour", without touching the rest
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
