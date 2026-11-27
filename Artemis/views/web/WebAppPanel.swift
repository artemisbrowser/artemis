// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// an installed app's settings, opened from the pill in its window; each change applies at once
struct WebAppPanel: View {
    @Environment(TabManager.self) private var tabManager
    let id: UUID
    let tab: BrowserTab
    @State private var name = ""
    @State private var website = ""
    @State private var showingIcons = false

    private var apps: WebApps { WebApps.shared }

    var body: some View {
        if let app = apps.app(id) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        dockIcon(app).frame(width: 36, height: 36)
                        TextField("Name", text: $name)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                            .modifier(EditorField())
                            .onSubmit(commitName)
                    }
                    group("WEBSITE") {
                        HStack(spacing: 6) {
                            TextField("https://", text: $website)
                                .textFieldStyle(.plain)
                                .font(.system(size: 13))
                                .modifier(EditorField())
                                .onSubmit(commitWebsite)
                            Button {
                                website = tab.url?.absoluteString ?? website
                                commitWebsite()
                            } label: {
                                Image(systemName: "arrow.down.doc").font(.system(size: 13))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .disabled(tab.url == nil)
                            .tooltip("Start on the page that's open")
                        }
                    }
                    group("ICON") { iconChoices(app) }
                    group("FRAME") {
                        FrameEditor(
                            style: binding(\.look), appearance: binding(\.appearance),
                            spaceInfo: "The frame wears the colours of the space it signs in as.")
                    }
                    group("EDGE") {
                        HStack(spacing: 10) {
                            Slider(
                                value: Binding(
                                    get: { apps.app(id)?.edgeInset ?? WindowChrome.edgeInset },
                                    set: { value in edit { $0.edgeInset = value.rounded() } }),
                                in: WindowChrome.range)
                            Text("\(Int(app.edgeInset ?? WindowChrome.edgeInset)) pt")
                                .font(.system(size: 12).monospacedDigit())
                                .foregroundStyle(.primary.opacity(0.5))
                                .frame(width: 34, alignment: .trailing)
                        }
                    }
                    group("WINDOW") {
                        toggle("Hide toolbar", \.collapsed, info: "Point at the window's top edge to show it.")
                        toggle("Back, forward and reload", \.showsNavigation)
                        toggle("Keep other sites in the app", \.keepsLinks, info: "When off, links to other sites open in Artemis.")
                        toggle("Float above other windows", \.floats)
                        toggle("Dock badge", \.badges, info: "Shows the unread count the page puts in its title.")
                    }
                    group("SIGNED IN AS") {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(tabManager.spaces) { space in
                                SpaceMenuRow(space: space, isTarget: space.id == app.space(in: tabManager.spaces)?.id) {
                                    edit {
                                        $0.spaceID = space.id
                                        $0.profileID = space.profileID
                                    }
                                }
                            }
                        }
                    }
                    Divider()
                    HStack {
                        Button("Reset Look") { edit { $0.resetLook() } }
                        Spacer()
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([apps.launcher(of: app)])
                        }
                    }
                    .font(.system(size: 12))
                }
                .padding(16)
            }
            .frame(width: 340)
            .frame(maxHeight: 560)
            .onAppear {
                name = app.name
                website = app.url.absoluteString
            }
            .onDisappear(perform: commitName)
        }
    }

    // MARK: - Icon

    private func iconChoices(_ app: WebApp) -> some View {
        let glyph: String? = if case .glyph(let g) = app.icon { g } else { nil }
        return HStack(spacing: 10) {
            choice("Site", selected: app.icon == .favicon) {
                if let icon = tab.favicon ?? FaviconStore.shared.icon(for: app.url.host()) {
                    Image(nsImage: icon).resizable().scaledToFit().frame(width: 20, height: 20)
                } else {
                    Image(systemName: "globe")
                }
            } action: {
                edit { $0.icon = .favicon }
            }
            choice("Symbol", selected: glyph != nil) {
                SpaceGlyph(icon: glyph ?? "face.smiling", size: 18)
            } action: {
                showingIcons = true
            }
            .popover(isPresented: $showingIcons, arrowEdge: .trailing) {
                IconPicker(
                    icon: Binding(get: { glyph ?? "" }, set: { new in edit { $0.icon = .glyph(new) } }),
                    name: app.name)
            }
            choice("Image", selected: app.icon == .image) {
                if app.icon == .image, let image = NSImage(contentsOf: WebApps.pickedImage(of: app)) {
                    Image(nsImage: image).resizable().scaledToFill().frame(width: 40, height: 40).clipped()
                } else {
                    Image(systemName: "photo")
                }
            } action: {
                pickImage(for: app)
            }
            Spacer()
        }
    }

    private func choice<Face: View>(
        _ label: String, selected: Bool, @ViewBuilder face: () -> Face, action: @escaping () -> Void
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return Button(action: action) {
            VStack(spacing: 4) {
                face()
                    .font(.system(size: 17))
                    .foregroundStyle(.primary.opacity(0.8))
                    .frame(width: 40, height: 40)
                    .background(shape.fill(.primary.opacity(0.06)))
                    .clipShape(shape)
                    .overlay(shape.strokeBorder(.primary.opacity(selected ? 0.55 : 0), lineWidth: 2))
                Text(label).font(.system(size: 11)).foregroundStyle(.primary.opacity(0.6))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(Motion.hover, value: selected)
    }

    private func dockIcon(_ app: WebApp) -> some View {
        Group {
            if let icon = apps.dockIcon(of: app, favicon: tab.favicon)
                ?? NSImage(contentsOf: apps.launcher(of: app).appending(path: "Contents/Resources/icon.png"))
            {
                Image(nsImage: icon).resizable().scaledToFit()
            } else {
                Image(systemName: "app.dashed").font(.system(size: 26)).foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel("Dock icon")
    }

    private func pickImage(for app: WebApp) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.message = "Choose an icon for \(app.name)"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            WebApps.shared.setImage(at: url, for: app)
        }
    }

    // MARK: - Editing

    private func edit(_ change: (inout WebApp) -> Void) {
        guard var app = apps.app(id) else { return }
        change(&app)
        apps.update(app)
    }

    private func binding<T>(_ key: WritableKeyPath<WebApp, T>) -> Binding<T> {
        let fallback = apps.app(id)
        return Binding(
            get: { (apps.app(id) ?? fallback)![keyPath: key] },
            set: { value in edit { $0[keyPath: key] = value } })
    }

    private func toggle(_ title: String, _ key: WritableKeyPath<WebApp, Bool>, info: String? = nil) -> some View {
        Toggle(isOn: binding(key)) {
            if let info { InfoLabel(title, info: info) } else { Text(title) }
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .font(.system(size: 12))
    }

    private func commitName() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != apps.app(id)?.name else { return }
        edit { $0.name = trimmed }
        name = apps.app(id)?.name ?? trimmed
    }

    /// a typed address without a scheme is taken as https
    private func commitWebsite() {
        let typed = website.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: typed.contains("://") ? typed : "https://" + typed), url.host() != nil,
            ["https", "http"].contains(url.scheme), url != apps.app(id)?.url
        else { return }
        edit { $0.url = url }
        tab.load(url)
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.45))
            content()
        }
    }
}
