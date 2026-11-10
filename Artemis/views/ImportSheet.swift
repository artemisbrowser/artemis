// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import SwiftUI
import UniformTypeIdentifiers

/// import from another browser: pick it, choose where each of its profiles lands, tick what to bring
struct ImportSheet: View {
    @Environment(TabManager.self) private var tabManager
    let model: ImportModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch model.phase {
            case .choosing: chooser
            case .working(let step): progress(step)
            case .done(let landed): summary(landed)
            case .failed(let reason): failure(reason)
            }
        }
        .padding(18)
        .frame(width: 420)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
        .shadow(color: .black.opacity(0.35), radius: 24, y: 8)
    }

    // MARK: - Choosing

    @ViewBuilder
    private var chooser: some View {
        Text("Import from Another Browser")
            .font(.system(size: 15, weight: .semibold))

        if model.browsers.isEmpty {
            note("No other browser's data was found on this Mac.")
        } else {
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(model.browsers) { browser in
                        browserRow(browser)
                    }
                }
            }
            .frame(maxHeight: 160)
            .fixedSize(horizontal: false, vertical: true)
        }

        if let browser = model.browser {
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    chosen(browser)
                }
            }
            .frame(maxHeight: 420)
            .fixedSize(horizontal: false, vertical: true)
        }

        HStack {
            Button("Not Now") { model.cancel(in: tabManager) }
                .buttonStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(.primary.opacity(0.6))
                .keyboardShortcut(.cancelAction)
            Spacer()
            capsule("Import", enabled: model.canImport) { model.run(into: tabManager) }
        }
        .padding(.top, 2)
    }

    @ViewBuilder
    private func chosen(_ browser: ImportedBrowser) -> some View {
        if let wall = browser.wall { self.wall(wall, of: browser) }
        if model.reading {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Reading \(browser.name)…")
                    .font(.system(size: 12))
                    .foregroundStyle(.primary.opacity(0.6))
            }
            .padding(8)
        } else {
            note(
                "Nothing in \(browser.name) changes."
                    + (model.available.contains(.passwords)
                        ? " A password saved here for the same site and username takes \(browser.name)'s." : ""))
            VStack(spacing: 2) {
                ForEach(browser.profiles, id: \.id) { profile in
                    profileRow(profile, alone: browser.profiles.count == 1)
                }
            }
            categories(browser)
            if model.needsKey {
                note(
                    "macOS will ask for \(browser.name)'s key to read what it keeps sealed."
                        + (model.loginsFile ? " The password file is plain text, so delete it once it's imported." : ""))
            }
        }
    }

    // MARK: - Browsers and profiles

    private func browserRow(_ browser: ImportedBrowser) -> some View {
        let isOn = model.browser?.id == browser.id
        return Button { model.choose(browser) } label: {
            HStack(spacing: 10) {
                Image(nsImage: Self.icon([browser.bundleID] + browser.aliases))
                    .resizable()
                    .frame(width: 20, height: 20)
                Text(browser.name)
                    .font(.system(size: 13, weight: isOn ? .medium : .regular))
                    .lineLimit(1)
                if browser.profiles.count > 1 {
                    Text(ImportModel.count(browser.profiles.count, "profile"))
                        .font(.system(size: 11))
                        .foregroundStyle(.primary.opacity(0.5))
                }
                Spacer(minLength: 0)
                if isOn {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.primary.opacity(isOn ? 0.08 : 0)))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(model.reading)
    }

    /// one source profile: whether it comes, what it holds, and which profile here takes it
    private func profileRow(_ profile: ImportedProfile, alone: Bool) -> some View {
        let isOn = model.included.contains(profile.id)
        return HStack(spacing: 8) {
            if !alone {
                Button {
                    if isOn { model.included.remove(profile.id) } else { model.included.insert(profile.id) }
                } label: {
                    Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 14))
                        .foregroundStyle(isOn ? Color.accentColor : .primary.opacity(0.3))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Include \(profile.name)")
                .accessibilityValue(isOn ? "on" : "off")
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(profile.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(Self.contents(profile))
                    .font(.system(size: 11))
                    .foregroundStyle(.primary.opacity(0.5))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Picker("Into", selection: destination(profile)) {
                if !tabManager.profiles.contains(where: { $0.id == profile.id }) {
                    Text("New profile").tag(profile.id)
                }
                ForEach(tabManager.profiles) { here in
                    Text(here.name).tag(here.id)
                }
            }
            .labelsHidden()
            .fixedSize()
            .controlSize(.small)
            .disabled(!isOn)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .opacity(isOn ? 1 : 0.55)
    }

    private func destination(_ profile: ImportedProfile) -> Binding<UUID> {
        Binding(
            get: { model.destinations[profile.id] ?? profile.id },
            set: { model.destinations[profile.id] = $0 })
    }

    /// "3 spaces · 41 tabs · 6 folders", or what else the profile has
    private static func contents(_ profile: ImportedProfile) -> String {
        let (tabs, folders) = tally(profile.spaces.flatMap { $0.pinned + $0.today })
        var parts: [String] = []
        if !profile.spaces.isEmpty { parts.append(ImportModel.count(profile.spaces.count, "space")) }
        if tabs > 0 { parts.append(ImportModel.count(tabs, "tab")) }
        if folders > 0 { parts.append(ImportModel.count(folders, "folder")) }
        if parts.isEmpty, profile.historyCount > 0 { parts.append(ImportModel.count(profile.historyCount, "page")) }
        if !profile.locked.isEmpty { parts.append("sealed") }
        return parts.isEmpty ? "Nothing to import" : parts.joined(separator: " · ")
    }

    private static func tally(_ items: [ImportedItem]) -> (tabs: Int, folders: Int) {
        var out = (tabs: 0, folders: 0)
        for item in items {
            switch item {
            case .tab: out.tabs += 1
            case .split(let panes, _): out.tabs += panes.count
            case .folder(_, _, let children):
                let inner = tally(children)
                out.tabs += inner.tabs
                out.folders += inner.folders + 1
            }
        }
        return out
    }

    // MARK: - Categories

    @ViewBuilder
    private func categories(_ browser: ImportedBrowser) -> some View {
        let available = model.available
        if available.isEmpty, browser.wall == nil {
            note("Nothing to import from the profiles chosen.")
        }
        VStack(spacing: 2) {
            ForEach(available, id: \.self) { category in
                if category == .passwords, model.passwordsNeedFile {
                    passwordFile
                } else {
                    ImportChoice(
                        Self.symbol(category), Self.title(category), detail(category, of: browser),
                        isOn: selected(category))
                }
            }
            if model.selection.contains(.passwords), model.chosen.contains(where: {
                if case .chromium = $0.logins { true } else { false }
            }) {
                ImportChoice(
                    "doc.text", "Also save a plain-text file", "A CSV in Downloads for another password manager",
                    isOn: Bindable(model).loginsFile)
            }
        }
    }

    private func selected(_ category: ImportCategory) -> Binding<Bool> {
        Binding(
            get: { model.selection.contains(category) },
            set: { if $0 { model.selection.insert(category) } else { model.selection.remove(category) } })
    }

    private func detail(_ category: ImportCategory, of browser: ImportedBrowser) -> String {
        let profiles = model.chosen
        let sealed = "Needs \(browser.name)'s key"
        func sum(_ value: (ImportedProfile) -> Int) -> Int { profiles.reduce(0) { $0 + value($1) } }
        switch category {
        case .spaces:
            let spaces = sum { $0.spaces.count }
            guard spaces > 0 else { return sealed }
            let (tabs, folders) = Self.tally(profiles.flatMap { $0.spaces.flatMap { $0.pinned + $0.today } })
            return "\(ImportModel.count(spaces, "space")) · \(ImportModel.count(tabs, "tab")) · "
                + ImportModel.count(folders, "folder")
        case .favourites:
            let favourites = sum { $0.favourites.count }
            return favourites > 0 ? "\(ImportModel.count(favourites, "tab")) pinned to the top" : sealed
        case .bookmarks:
            let links = sum { Self.tally($0.bookmarks).tabs }
            return links > 0 ? "\(ImportModel.count(links, "link")) as pinned folders" : sealed
        case .archive:
            let archived = sum { $0.archive.count }
            return archived > 0 ? "\(ImportModel.count(archived, "tab")) \(browser.name) archived" : sealed
        case .history:
            let pages = sum(\.historyCount)
            let line = ImportModel.count(pages, "page")
            return pages > Importers.historyLimit
                ? "\(line). The newest \(Importers.historyLimit.formatted()) per profile come across." : line
        case .cookies:
            return "\(ImportModel.count(sum(\.cookieCount), "cookie")), so you stay signed in"
        case .passwords:
            let logins = sum(\.loginCount)
            return logins > 0 ? "\(ImportModel.count(logins, "login")), into Artemis Passwords" : "Into Artemis Passwords"
        }
    }

    private static func title(_ category: ImportCategory) -> String {
        switch category {
        case .spaces: "Spaces & tabs"
        case .favourites: "Favourites"
        case .bookmarks: "Bookmarks"
        case .archive: "Archive"
        case .history: "History"
        case .cookies: "Cookies"
        case .passwords: "Passwords"
        }
    }

    private static func symbol(_ category: ImportCategory) -> String {
        switch category {
        case .spaces: "square.stack"
        case .favourites: "star"
        case .bookmarks: "bookmark"
        case .archive: "archivebox"
        case .history: "clock.arrow.circlepath"
        case .cookies: "person.badge.key"
        case .passwords: "key"
        }
    }

    /// a browser whose passwords leave only as an exported CSV
    private var passwordFile: some View {
        let hint = model.chosen.lazy.compactMap { if case .csvOnly(let hint) = $0.logins { hint } else { nil } }.first
        return HStack(spacing: 6) {
            Image(systemName: "key")
                .font(.system(size: 11))
                .foregroundStyle(.primary.opacity(0.5))
                .frame(width: 14)
            Text("Passwords").font(.system(size: 13, weight: .medium))
            InfoButton((hint.map { $0 + " " } ?? "") + "Bitwarden and 1Password CSVs work too.")
                .font(.system(size: 11))
            Spacer()
            if let file = model.passwordFile {
                Text(file.lastPathComponent)
                    .font(.system(size: 11))
                    .foregroundStyle(.primary.opacity(0.5))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Button(model.passwordFile == nil ? "Choose CSV…" : "Change…") { model.choosePasswordFile() }
                .controlSize(.small)
        }
        .padding(.vertical, 6)
        .padding(.leading, 32)
        .padding(.trailing, 8)
    }

    // MARK: - Walls

    @ViewBuilder
    private func wall(_ wall: Wall, of browser: ImportedBrowser) -> some View {
        switch wall {
        case .fullDiskAccess:
            note("\(browser.name)'s data needs Full Disk Access. You can also choose the file its File menu exports.")
            HStack(spacing: 8) {
                Button("Open Privacy Settings") { Self.openPrivacy("Privacy_AllFiles") }
                Button("Choose Exported File…") { model.chooseExport() }
            }
            .controlSize(.small)
            .padding(.horizontal, 8)
        case .notRunning:
            note("Open \(browser.name) to import its spaces. Cookies stay importable.")
            Button("Try Again") { model.readLive() }
                .controlSize(.small)
                .padding(.horizontal, 8)
        case .noWindow:
            note("Open a \(browser.name) window to import its spaces.")
            Button("Try Again") { model.readLive() }
                .controlSize(.small)
                .padding(.horizontal, 8)
        case .noReply:
            note("\(browser.name) didn't answer. Try again in a moment.")
            Button("Try Again") { model.readLive() }
                .controlSize(.small)
                .padding(.horizontal, 8)
        case .automationDenied:
            note("Allow Artemis to control \(browser.name) in Privacy & Security, Automation.")
            HStack(spacing: 8) {
                Button("Open Privacy Settings") { Self.openPrivacy("Privacy_Automation") }
                Button("Try Again") { model.readLive() }
            }
            .controlSize(.small)
            .padding(.horizontal, 8)
        }
    }

    private static func openPrivacy(_ pane: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
    }

    /// the browser's own icon, or a plain one when it's no longer installed
    private static func icon(_ bundleIDs: [String]) -> NSImage {
        guard let app = bundleIDs.lazy.compactMap(NSWorkspace.shared.urlForApplication(withBundleIdentifier:)).first
        else { return NSWorkspace.shared.icon(for: .applicationBundle) }
        return NSWorkspace.shared.icon(forFile: app.path)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.primary.opacity(0.5))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8)
    }

    // MARK: - Running, and after

    @ViewBuilder
    private func progress(_ step: String) -> some View {
        Text("Importing from \(model.browser?.name ?? "another browser")")
            .font(.system(size: 15, weight: .semibold))
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(step)
                .font(.system(size: 12))
                .foregroundStyle(.primary.opacity(0.6))
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func summary(_ landed: [String]) -> some View {
        Text("Imported")
            .font(.system(size: 15, weight: .semibold))
        VStack(alignment: .leading, spacing: 4) {
            ForEach(landed, id: \.self) { line in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.top, 3)
                    Text(line)
                        .font(.system(size: 12))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        HStack {
            Spacer()
            capsule("Done", enabled: true) { model.cancel(in: tabManager) }
        }
        .padding(.top, 2)
    }

    @ViewBuilder
    private func failure(_ reason: String) -> some View {
        Text("Import stopped")
            .font(.system(size: 15, weight: .semibold))
        Text(reason)
            .font(.system(size: 12))
            .foregroundStyle(.primary.opacity(0.6))
            .fixedSize(horizontal: false, vertical: true)
        HStack {
            Spacer()
            capsule("Close", enabled: true) { model.cancel(in: tabManager) }
        }
        .padding(.top, 2)
    }

    private func capsule(_ title: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(
                    Capsule().fill(enabled ? Color.accentColor.opacity(0.9) : Color.primary.opacity(0.12)))
                .foregroundStyle(enabled ? .white : .primary.opacity(0.4))
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.defaultAction)
        .disabled(!enabled)
    }
}

/// a checkable line in an import sheet: what it is, and how much of it there is
struct ImportChoice: View {
    let symbol: String
    let title: String
    let detail: String
    @Binding var isOn: Bool

    init(_ symbol: String, _ title: String, _ detail: String, isOn: Binding<Bool>) {
        self.symbol = symbol
        self.title = title
        self.detail = detail
        _isOn = isOn
    }

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(isOn ? Color.accentColor : .primary.opacity(0.3))
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Image(systemName: symbol)
                            .font(.system(size: 11))
                            .foregroundStyle(.primary.opacity(0.5))
                            .frame(width: 14)
                        Text(title).font(.system(size: 13, weight: .medium))
                    }
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.primary.opacity(0.5))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 20)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.primary.opacity(isOn ? 0.06 : 0)))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityHint(detail)
        .accessibilityValue(isOn ? "on" : "off")
        .accessibilityAddTraits(.isToggle)
    }
}
