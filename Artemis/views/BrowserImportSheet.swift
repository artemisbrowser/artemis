// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import SwiftUI
import UniformTypeIdentifiers

/// import from another browser: pick a profile it has, tick what to bring, and
/// choose which profile here it lands in.
struct BrowserImportSheet: View {
    @Environment(TabManager.self) private var tabManager
    let model: BrowserImportModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch model.phase {
            case .choosing: chooser
            case .working(let step): progress(step)
            case .done(let landed): summary(landed)
            }
        }
        .padding(18)
        .frame(width: 400)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
        .shadow(color: .black.opacity(0.35), radius: 24, y: 8)
    }

    // MARK: - Choosing

    @ViewBuilder
    private var chooser: some View {
        @Bindable var model = model
        Text("Import from Another Browser")
            .font(.system(size: 15, weight: .semibold))

        if model.sources.isEmpty && !model.offersArc {
            note("No other browser's data was found on this Mac.")
        } else {
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(model.sources) { source in
                        sourceRow(source.title, bundleID: source.bundleID, isOn: model.source == source) {
                            model.choose(source)
                        }
                    }
                    if model.offersArc {
                        sourceRow("Arc", bundleID: ArcImport.bundleID, isOn: false) {
                            model.cancel(in: tabManager)
                            ArcMigration.run(into: tabManager)
                        }
                    }
                }
            }
            .frame(maxHeight: 180)
            .fixedSize(horizontal: false, vertical: true)
        }

        if let source = model.source {
            Divider()
            choices(for: source)
        }

        if tabManager.profiles.count > 1 {
            Picker("Into", selection: $model.profileID) {
                ForEach(tabManager.profiles) { profile in
                    Text(profile.name).tag(profile.id)
                }
            }
            .font(.system(size: 12))
            .padding(.horizontal, 8)
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
    private func choices(for source: BrowserImport.Source) -> some View {
        @Bindable var model = model
        if let survey = model.survey {
            VStack(spacing: 2) {
                if let workspaces = survey.workspaces {
                    ImportChoice(
                        "square.stack", "Workspaces",
                        "\(BrowserImportModel.count(workspaces.folders.count, "space")) with their pinned tabs"
                            + (workspaces.favourites.isEmpty
                                ? "" : ", \(BrowserImportModel.count(workspaces.favourites.count, "favourite"))"),
                        isOn: $model.selection.workspaces)
                }
                if let bookmarks = survey.bookmarks {
                    ImportChoice(
                        "bookmark", "Bookmarks",
                        "\(BrowserImportModel.count(bookmarks.linkCount, "link")) pinned in "
                            + BrowserImportModel.count(
                                bookmarks.folders.count + (bookmarks.loose.isEmpty ? 0 : 1), "space"),
                        isOn: $model.selection.bookmarks)
                }
                if !survey.history.isEmpty {
                    ImportChoice(
                        "clock.arrow.circlepath", "History",
                        "\(BrowserImportModel.count(survey.history.count, "page")), with visit counts",
                        isOn: $model.selection.history)
                }
                passwords(for: source)
            }
            if survey.blocked && survey.bookmarks == nil {
                note("Safari's bookmarks and history need Full Disk Access. You can also export bookmarks from Safari's File menu.")
                HStack(spacing: 8) {
                    Button("Open Privacy Settings") {
                        NSWorkspace.shared.open(
                            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                    }
                    Button("Choose Exported File…") { model.chooseExportedBookmarks() }
                }
                .controlSize(.small)
                .padding(.horizontal, 8)
            } else if survey.bookmarks == nil && survey.history.isEmpty && survey.workspaces == nil {
                note("Nothing to import here besides passwords.")
            }
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Reading \(source.browser)…")
                    .font(.system(size: 12))
                    .foregroundStyle(.primary.opacity(0.6))
            }
            .padding(8)
        }
    }

    private func passwords(for source: BrowserImport.Source) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "key")
                .font(.system(size: 11))
                .foregroundStyle(.primary.opacity(0.5))
                .frame(width: 14)
            Text("Passwords").font(.system(size: 13, weight: .medium))
            InfoButton(Self.exportGuide(source) + " Bitwarden and 1Password CSVs work too.")
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

    /// where each browser keeps its export, which is the only way passwords leave it
    private static func exportGuide(_ source: BrowserImport.Source) -> String {
        switch source.engine {
        case .chromium: "In \(source.browser), open Password Manager, then Settings, and export a CSV."
        case .firefox: "In \(source.browser), open about:logins and choose Export from the ⋯ menu."
        case .safari: "In the Passwords app, choose File › Export All Passwords."
        }
    }

    private func sourceRow(_ title: String, bundleID: String, isOn: Bool, action: @escaping () -> Void)
        -> some View
    {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(nsImage: Self.icon(bundleID))
                    .resizable()
                    .frame(width: 20, height: 20)
                Text(title)
                    .font(.system(size: 13, weight: isOn ? .medium : .regular))
                    .lineLimit(1)
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
    }

    /// the browser's own icon, or a plain one when it's no longer installed
    private static func icon(_ bundleID: String) -> NSImage {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return NSWorkspace.shared.icon(for: .applicationBundle)
        }
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
        Text("Importing from \(model.source?.browser ?? "another browser")")
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
