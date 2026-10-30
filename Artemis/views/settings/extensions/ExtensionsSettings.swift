import SwiftUI
import WebKit

/// the extensions manager: install, toggle, pin to the url bar, inspect permissions, remove.
/// the master switch disables every extension without forgetting each one's own state
struct ExtensionsSettings: View {
    @Environment(ExtensionManager.self) private var extensions
    @State private var addError: String?
    @State private var isAdding = false
    @State private var storeURL = ""
    @State private var pendingRemoval: InstalledExtension?

    var body: some View {
        @Bindable var extensions = extensions
        return Form {
            Section {
                Toggle(isOn: $extensions.isMasterEnabled) {
                    InfoLabel(
                        "Enable extensions",
                        info: "Turning this off disables every extension and remembers which ones were on."
                    )
                }
                // the built-in blocker isn't an extension, but this is where people look for it
                LabeledContent("Ad and tracker blocking") {
                    Button("Privacy & Security…") { SettingsView.open(.privacy) }
                }
            }

            BoostsSection()

            Section("Installed") {
                if extensions.installed.isEmpty {
                    Text("No extensions installed yet.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(extensions.installed) { ext in
                        ExtensionRow(ext: ext) { pendingRemoval = ext }
                    }
                }
            }

            Section {
                HStack {
                    TextField(
                        "Paste a Chrome Web Store or Firefox Add-ons URL", text: $storeURL)
                    Button("Install") { installFromStore() }
                        .disabled(isAdding || storeURL.trimmingCharacters(in: .whitespaces).isEmpty)
                        .tooltip("Install from this URL")
                }
            } header: {
                InfoLabel(
                    "Add from a Store",
                    info: "Paste a Firefox Add-ons or Chrome Web Store link to install. Chrome Web Store installs may not always work."
                )
            }

            Section("Suggested") {
                ForEach(CatalogEntry.curated) { entry in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.name).font(.system(size: 13, weight: .medium))
                            Text(entry.blurb).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Install") { installFromStore(entry.storeURL) }
                            .controlSize(.small)
                            .disabled(isAdding)
                            .tooltip("Install \(entry.name)")
                    }
                }
            }

            Section {
                HStack(spacing: 6) {
                    Button {
                        pickAndInstall()
                    } label: {
                        Label(isAdding ? "Adding…" : "Add from Disk…", systemImage: "plus")
                    }
                    .disabled(isAdding)
                    .tooltip("Sideload an unpacked extension")
                    InfoButton(
                        "Installs an extension folder or a .zip, .xpi or .crx archive. Some extensions may only partly work."
                    )
                }

                if let addError {
                    Text(addError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .alert(
            "Remove \(pendingRemoval?.name ?? "Extension")?",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } })
        ) {
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
            Button("Remove", role: .destructive) {
                if let ext = pendingRemoval { extensions.remove(ext) }
                pendingRemoval = nil
            }
        } message: {
            Text("This deletes the extension and its data from Artemis.")
        }
    }

    private func pickAndInstall() {
        guard let url = ExtensionPicker.run() else { return }
        addError = nil
        isAdding = true
        Task {
            do {
                let ext = try await extensions.installFromDisk(url)
                await ExtensionInstallFlow.finalize(ext, manager: extensions)
            } catch {
                addError = error.localizedDescription
            }
            isAdding = false
        }
    }

    private func installFromStore(_ explicit: String? = nil) {
        let raw = (explicit ?? storeURL).trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: raw), url.scheme?.hasPrefix("http") == true else {
            addError = "Enter a valid https store URL."
            return
        }
        addError = nil
        isAdding = true
        Task {
            do {
                let ext = try await extensions.installFromStore(pageURL: url)
                await ExtensionInstallFlow.finalize(ext, manager: extensions)
                if explicit == nil { storeURL = "" }
            } catch {
                addError = error.localizedDescription
            }
            isAdding = false
        }
    }
}

/// per-site Boosts: the install-nothing cousin of an extension. a real editor —
/// pick a Boost, edit its CSS and JS, save — rather than a write-once add form,
/// because a tweak you can't revise is a tweak you delete and retype.
private struct BoostsSection: View {
    @State private var store = BoostStore.shared
    @State private var editing: Boost?
    @State private var newHost = ""

    var body: some View {
        Section {
            if store.boosts.isEmpty {
                Text("No Boosts yet. Add a site below to restyle it with your own CSS or JS.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(store.boosts) { boost in
                HStack(spacing: 8) {
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { boost.isEnabled }, set: { store.setEnabled(boost, $0) })
                    )
                    .labelsHidden()
                    VStack(alignment: .leading, spacing: 1) {
                        Text(boost.host).font(.system(size: 13, weight: .medium))
                        Text(summary(for: boost))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Edit") { editing = boost }
                        .controlSize(.small)
                    Button("Remove", role: .destructive) { store.remove(boost) }
                        .controlSize(.small)
                }
            }

            HStack {
                TextField("Add a site (e.g. example.com)", text: $newHost)
                    .onSubmit(createBoost)
                Button("Add Boost", action: createBoost)
                    .disabled(newHost.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            InfoLabel(
                "Boosts",
                info: "Applies your own CSS and JavaScript to a site and its subdomains every time it loads."
            )
        }
        .sheet(item: $editing) { boost in
            BoostEditor(boost: boost) { edited in
                store.update(edited)
                editing = nil
            } onCancel: {
                editing = nil
            }
        }
    }

    private func summary(for boost: Boost) -> String {
        var parts: [String] = []
        if !boost.css.isEmpty { parts.append("\(boost.css.count) chars of CSS") }
        if !boost.js.isEmpty { parts.append("\(boost.js.count) chars of JS") }
        return parts.isEmpty ? "empty" : parts.joined(separator: " · ")
    }

    private func createBoost() {
        guard let created = store.create(host: newHost) else { return }
        newHost = ""
        editing = created
    }
}

/// the CSS/JS editor sheet for one Boost
private struct BoostEditor: View {
    @State var boost: Boost
    let onSave: (Boost) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Boost")
                .font(.headline)
            TextField("Host", text: $boost.host)
                .textFieldStyle(.roundedBorder)

            Text("CSS").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $boost.css)
                .font(.system(.caption, design: .monospaced))
                .frame(height: 140)
                .overlay(
                    RoundedRectangle(cornerRadius: 6).stroke(.separator))

            InfoLabel("JavaScript", info: "Runs in the page itself once it finishes loading.")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $boost.js)
                .font(.system(.caption, design: .monospaced))
                .frame(height: 100)
                .overlay(
                    RoundedRectangle(cornerRadius: 6).stroke(.separator))

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save") { onSave(boost) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(boost.host.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}

/// one row in the installed list: icon + identity, enable/pin controls, and a
/// disclosure of the permissions the extension was granted
private struct ExtensionRow: View {
    @Environment(ExtensionManager.self) private var extensions
    let ext: InstalledExtension
    let onRemove: () -> Void
    /// read once — it comes off the manifest file on disk
    @State private var coverage: (bridged: [String], missing: [String]) = ([], [])

    private var otherProfiles: [Profile] {
        (extensions.tabManager?.profiles ?? []).filter { $0.id != extensions.currentProfile }
    }

    private func enabled(in profile: UUID) -> Binding<Bool> {
        Binding(
            get: { ext.profiles.contains(profile) },
            set: { extensions.setEnabled(ext, $0, in: profile) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                icon
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(ext.name).font(.system(size: 13, weight: .semibold))
                        if let version = ext.version {
                            Text("v\(version)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text(ext.source.label).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                if !otherProfiles.isEmpty {
                    Menu("Also in") {
                        ForEach(otherProfiles) { profile in
                            Toggle(profile.name, isOn: enabled(in: profile.id))
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .tooltip("Turn it on in other profiles too")
                }
                Toggle("", isOn: enabled(in: extensions.currentProfile))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tooltip("On in this profile")
            }

            if let summary = ext.summary, !summary.isEmpty {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            if let errorText = ext.loadErrorText {
                Label(errorText, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if !coverage.missing.isEmpty {
                Label(
                    "Needs \(coverage.missing.joined(separator: ", ")) — an API WebKit doesn't "
                        + "provide to extensions. Parts of this extension can't work in Artemis.",
                    systemImage: "bolt.horizontal.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if !coverage.bridged.isEmpty {
                Label(
                    "Bridged by Artemis: \(coverage.bridged.joined(separator: ", ")) — "
                        + "APIs WebKit lacks, filled in natively.",
                    systemImage: "arrow.triangle.branch")
                    .font(.caption)
                    .foregroundStyle(.teal)
            }

            if !ext.requestedPermissionLabels.isEmpty || !ext.requestedHostLabels.isEmpty {
                DisclosureGroup("Permissions") {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(ext.requestedPermissionLabels, id: \.self) { p in
                            Label(p, systemImage: "key.fill").font(.caption)
                        }
                        ForEach(ext.requestedHostLabels, id: \.self) { h in
                            Label(h, systemImage: "globe").font(.caption)
                        }
                    }
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                }
                .font(.caption)
            }

            DisclosureGroup("Diagnostics") {
                VStack(alignment: .leading, spacing: 3) {
                    diag("Manifest", "v\(Int(ext.webExtension.manifestVersion))")
                    diag("Background", ext.webExtension.hasBackgroundContent
                        ? (ext.webExtension.hasPersistentBackgroundContent ? "persistent" : "event page")
                        : "none")
                    diag("Content scripts", ext.webExtension.hasInjectedContent ? "yes" : "no")
                    diag("Options page", ext.webExtension.hasOptionsPage ? "yes" : "no")
                    diag("Commands", ext.webExtension.hasCommands ? "yes" : "no")
                    diag("Loaded", ext.context.isLoaded ? "running" : "stopped")
                    Text("Coverage is Safari-class via WebKit's runtime — some Chrome-only APIs may no-op.")
                        .font(.caption2).foregroundStyle(.secondary).padding(.top, 2)
                }
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            }
            .font(.caption)

            HStack(spacing: 12) {
                Button(ext.isPinned ? "Unpin from URL Bar" : "Pin to URL Bar") {
                    extensions.togglePin(ext)
                }
                .controlSize(.small)
                .disabled(!ext.isEnabled)

                if ext.webExtension.hasOptionsPage {
                    Button("Options") {
                        Task { try? await extensions.openOptionsPage(for: ext) }
                    }
                    .controlSize(.small)
                    .disabled(!ext.isEnabled)
                }

                Spacer()

                Button("Remove", role: .destructive, action: onRemove)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
        .onAppear { coverage = extensions.permissionCoverage(for: ext) }
    }

    private func diag(_ label: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.caption)
            Spacer()
            Text(value).font(.caption.monospaced())
        }
    }

    @ViewBuilder private var icon: some View {
        if let image = ext.icon(size: 32) {
            Image(nsImage: image).resizable().interpolation(.high)
                .frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(.quaternary)
                .frame(width: 32, height: 32)
                .overlay(Image(systemName: "puzzlepiece.extension.fill").foregroundStyle(.secondary))
        }
    }
}
