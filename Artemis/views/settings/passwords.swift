// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import AppKit
import SwiftUI
import UniformTypeIdentifiers
import Vision
import WebKit

/// one profile's passwords: the logins and passkeys Artemis keeps in the Keychain,
/// and how it offers them
struct PasswordsSettings: View {
    let profileID: Profile.ID
    @AppStorage(PasswordStore.offerToSaveKey) private var offerToSave = true
    @AppStorage(PasswordStore.fillFromSuggestionsKey) private var fillFromSuggestions = true
    @AppStorage(PwnedPasswords.enabledKey) private var checksLeaks = false
    @State private var query = ""
    @State private var openSite: String?
    @State private var status: String?
    @State private var editingRecipe: PasswordRecipe?
    private var store: PasswordStore { .shared }
    private var logins: [SavedLogin] { store.logins(in: profileID) }
    private var passkeys: [SavedPasskey] { store.passkeys(in: profileID) }

    private var sites: [PasswordSite] {
        let all = PasswordSite.group(logins: logins, passkeys: passkeys)
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return all }
        return all.filter { site in
            site.domain.localizedCaseInsensitiveContains(q)
                || site.accounts.contains { $0.name.localizedCaseInsensitiveContains(q) }
        }
    }

    var body: some View {
        if let domain = openSite, let site = PasswordSite.group(logins: logins, passkeys: passkeys)
            .first(where: { $0.domain == domain })
        {
            PasswordSiteDetail(site: site, back: { withAnimation(Motion.panel) { openSite = nil } })
                .transition(Motion.slide(.trailing))
        } else {
            // a site that empties drops its unlock, so new logins there ask again
            list.transition(Motion.slide(.leading)).onAppear { openSite = nil }
        }
    }

    private var list: some View {
        Form {
            if store.isUnreadable {
                Section {
                    Label(
                        "Artemis couldn't open its keychain items, so nothing new will be saved. Quit and reopen Artemis, and allow access if macOS asks.",
                        systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search", text: $query, prompt: Text("Search websites and accounts"))
                        .textFieldStyle(.plain)
                }
                if sites.isEmpty {
                    Text(logins.isEmpty && passkeys.isEmpty
                        ? "No saved passwords yet. Artemis offers to save one after you sign in."
                        : "Nothing matches that search.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                ForEach(sites) { site in
                    PasswordSiteRow(site: site) {
                        Task {
                            guard await OwnerUnlock.authenticate(.passwords, "view your saved logins for \(site.domain)") else { return }
                            withAnimation(Motion.panel) { openSite = site.domain }
                        }
                    }
                }
            } header: {
                HStack {
                    InfoLabel(
                        "Passwords",
                        info: "Only this profile's. Passkeys made in Artemis stay on this Mac and don't sync to other devices or browsers.")
                    Spacer()
                    if !sites.isEmpty {
                        Text(sites.count == 1 ? "1 website" : "\(sites.count) websites").foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                ForEach(store.recipes(in: profileID)) { recipe in
                    LabeledContent {
                        Button("Edit") {
                            Task {
                                guard await OwnerUnlock.authenticate(.passwords, "edit your suggested password") else { return }
                                editingRecipe = recipe
                            }
                        }
                        .controlSize(.small)
                    } label: {
                        Text(recipe.name)
                        Text(recipe.masked(for: "instagram.com").map { "instagram.com: " + $0 } ?? "Its scramble key is missing")
                    }
                }
                Button("Add Suggested Password…") {
                    editingRecipe = PasswordRecipe(profileID: PasswordStore.stored(profileID))
                }
                Toggle(isOn: $checksLeaks) {
                    InfoLabel(
                        "Check roots against known leaks",
                        info: "Asks Have I Been Pwned whether a root has leaked. Only the first 5 characters of its hash leave this Mac.")
                }
            } header: {
                InfoLabel(
                    "Suggested Passwords",
                    info: "A root you remember plus part of each site's name, offered when you sign up. Unless that part is scrambled, one leaked password makes the others easier to guess.")
            }

            Section {
                Toggle(isOn: $offerToSave) {
                    InfoLabel(
                        "Offer to save passwords",
                        info: "Asks to save a login to your keychain after you sign in. Incognito windows never save.")
                }
                Toggle(isOn: $fillFromSuggestions) {
                    InfoLabel("Fill from suggestions", info: "Suggests saved logins when you click into a login field.")
                }
            } header: {
                InfoLabel("Options", info: "These apply to every profile.")
            }

            Section {
                UnlockPicker(
                    .passwords, info: "Covers filling, viewing and copying passwords and codes, and signing in with passkeys.")
            } header: {
                UnlockHeader()
            }

            if !store.neverSave.isEmpty {
                Section {
                    ForEach(store.neverSave, id: \.self) { host in
                        HStack {
                            Text(host)
                            Spacer()
                            Button("Remove") { store.setNeverSave(host, false) }.buttonStyle(.link)
                        }
                    }
                } header: {
                    InfoLabel("Never Saved", info: "Sites Artemis won't offer to save a password for, in any profile.")
                }
            }

            Section {
                HStack {
                    Button("Import CSV…") { importCSV() }
                    Button("Export CSV…") { Task { await exportCSV() } }
                        .disabled(logins.isEmpty)
                }
                if let status {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                InfoLabel(
                    "Import & Export",
                    info: "Put a CSV from another browser or password manager in Downloads, then import it into this profile. Verification codes come too, and exports save there as plain text.")
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editingRecipe) { PasswordRecipeEditor(recipe: $0) }
    }

    private func importCSV() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        panel.message = "Choose a password export (.csv)."
        // a picked file in iCloud-synced Documents can be refused (EPERM); Downloads is reliably readable
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].resolvingSymlinksInPath()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text: String
        do {
            text = try Self.readText(url)
        } catch {
            let posix = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError
            if posix?.domain == NSPOSIXErrorDomain, posix?.code == Int(EPERM) {
                return status = "macOS won't let Artemis read files in that folder. Move the export into Downloads and import it from there."
            }
            return status = "That file couldn't be read: \(error.localizedDescription)"
        }
        Task {
            guard let summary = await store.importCSV(text, into: profileID) else {
                return status = "That file has no url and password columns, so nothing was imported."
            }
            status = "Imported: \(summary.added) added, \(summary.updated) updated, \(summary.skipped) skipped."
        }
    }

    /// coordinated, so a file iCloud has offloaded is downloaded first; UTF-8, UTF-16 (BOM) or Windows-1252
    private static func readText(_ url: URL) throws -> String {
        var coordinationError: NSError?
        var result: Result<Data, Error> = .failure(CocoaError(.fileReadUnknown))
        NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { readable in
            result = Result { try Data(contentsOf: readable) }
        }
        if let coordinationError { throw coordinationError }
        let data = try result.get()
        // without a byte-order mark almost any even-length bytes decode as UTF-16
        let unicode = data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF])
        for encoding: String.Encoding in unicode ? [.utf16] : [.utf8, .windowsCP1252] {
            if let text = String(data: data, encoding: encoding) { return text }
        }
        throw CocoaError(.fileReadInapplicableStringEncoding)
    }

    private func exportCSV() async {
        let alert = NSAlert()
        alert.messageText = "Export passwords as plain text?"
        alert.informativeText = "Anyone who can open the file can read every password in it. Delete it once you've imported it elsewhere."
        alert.addButton(withTitle: "Export…")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn,
            await OwnerUnlock.authenticate(.passwords, "export your saved passwords")
        else { return }
        let rows = await store.secrets(of: logins).map {
            (name: $0.login.host, url: $0.login.origin, username: $0.login.username, password: $0.password, code: $0.code ?? "")
        }
        status = store.writePlaintext(PasswordStore.csv(rows), suggesting: "artemis-passwords.csv", count: rows.count)
    }
}

@MainActor
func confirmDelete(_ title: String, _ detail: String) -> Bool {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = detail
    alert.addButton(withTitle: "Delete").hasDestructiveAction = true
    alert.addButton(withTitle: "Cancel")
    return alert.runModal() == .alertFirstButtonReturn
}

/// everything saved for one website (a registrable domain), one row in the list
private struct PasswordSite: Identifiable {
    /// one sign-in on the site: its logins (one per website it was saved on) and passkeys
    struct Account: Identifiable {
        let name: String
        var logins: [SavedLogin] = []
        var passkeys: [SavedPasskey] = []
        var id: String { name }
        /// the login whose password the card shows, edits and copies
        var primary: SavedLogin? { logins.max { $0.updated < $1.updated } }
        var modified: Date? { (logins.map(\.updated) + passkeys.map(\.created)).max() }
    }

    let domain: String
    var accounts: [Account]
    var id: String { domain }
    var hasPasskey: Bool { accounts.contains { !$0.passkeys.isEmpty } }
    /// the host whose favicon stands for the site
    var iconHost: String { accounts.first?.logins.first?.host ?? domain }

    static func group(logins: [SavedLogin], passkeys: [SavedPasskey]) -> [PasswordSite] {
        var sites: [String: [String: Account]] = [:]
        for login in logins {
            let domain = PasswordStore.registrableDomain(login.host) ?? login.host
            sites[domain, default: [:]][login.username, default: Account(name: login.username)].logins.append(login)
        }
        for passkey in passkeys {
            let domain = PasswordStore.registrableDomain(passkey.rpID) ?? passkey.rpID
            sites[domain, default: [:]][passkey.userName, default: Account(name: passkey.userName)].passkeys.append(passkey)
        }
        return sites.map { domain, accounts in
            PasswordSite(domain: domain, accounts: accounts.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
        }
        .sorted { $0.domain.localizedStandardCompare($1.domain) == .orderedAscending }
    }
}

/// the site's favicon on a soft tile, or a monogram in a colour of its own when it has none
private struct SiteIcon: View {
    let host: String
    let size: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
        ZStack {
            if let icon = FaviconStore.shared.icon(for: host) {
                shape.fill(.background.secondary)
                Image(nsImage: icon).resizable().interpolation(.high).scaledToFit().padding(size * 0.18)
            } else {
                shape.fill(Self.tint(for: host).gradient)
                Text(String(host.replacingOccurrences(of: "www.", with: "").prefix(1)).uppercased())
                    .font(.system(size: size * 0.46, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .overlay(shape.strokeBorder(.primary.opacity(0.08)))
    }

    /// stable per host, so a site keeps its colour between launches
    private static func tint(for host: String) -> Color {
        let hue = Double(host.unicodeScalars.reduce(UInt32(7)) { ($0 &* 31) &+ $1.value } % 360) / 360
        return Color(hue: hue, saturation: 0.5, brightness: 0.72)
    }
}

private struct PasswordSiteRow: View {
    let site: PasswordSite
    let open: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                SiteIcon(host: site.iconHost, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(site.domain).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                if site.hasPasskey {
                    Image(systemName: "person.badge.key.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .tooltip("Has a passkey")
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 3)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.primary.opacity(isHovering ? 0.06 : 0))
                .padding(-4))
        .onHover { isHovering = $0 }
        .animation(Motion.hover, value: isHovering)
    }

    private var subtitle: String {
        guard site.accounts.count == 1, let account = site.accounts.first else { return "\(site.accounts.count) accounts" }
        return account.name.isEmpty ? "No username" : account.name
    }
}

/// one website's accounts as cards; reached only after a device-owner check
private struct PasswordSiteDetail: View {
    let site: PasswordSite
    let back: () -> Void

    var body: some View {
        Form {
            Section {
                VStack(spacing: 10) {
                    SiteIcon(host: site.iconHost, size: 64)
                    Text(site.domain).font(.system(size: 22, weight: .bold))
                    if site.accounts.count > 1 {
                        Text("\(site.accounts.count) accounts").font(.callout).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            } header: {
                Button(action: back) {
                    Label("All Passwords", systemImage: "chevron.left").font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
            }

            ForEach(site.accounts) { account in
                AccountCard(account: account)
            }
        }
        .formStyle(.grouped)
        .background(CaptureShield())
    }
}

/// keeps the hosting window out of screenshots and screen recordings while it is on screen
struct CaptureShield: NSViewRepresentable {
    final class Shield: NSView {
        private weak var shielded: NSWindow?

        override func viewDidMoveToWindow() {
            shielded?.sharingType = .readOnly
            shielded = window
            window?.sharingType = .none
        }

        override func removeFromSuperview() {
            shielded?.sharingType = .readOnly
            super.removeFromSuperview()
        }
    }

    func makeNSView(context: Context) -> Shield { Shield() }
    func updateNSView(_ nsView: Shield, context: Context) {}

    static func dismantleNSView(_ nsView: Shield, coordinator: ()) {
        nsView.window?.sharingType = .readOnly
    }
}

/// the faint rounded highlight under a hovered value, the same inset on every side
private struct HoverPill: ViewModifier {
    let isLit: Bool

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(.primary.opacity(isLit ? 0.08 : 0)))
            .contentShape(.rect)
    }
}

/// a value that copies itself when clicked, under a faint pill while hovered
private struct CopyValue: View {
    let value: String
    var shown: String?
    var monospaced = false
    var hovering: Binding<Bool>?
    /// asks the device owner first, as the passwords unlock policy says, and copies concealed
    var secret = false
    /// a code: copied concealed, with no owner check
    var concealed = false
    /// dots in place of the value while true; nil for a value that is never masked
    var masked: Bool?
    @State private var isHovering = false
    @State private var copied = false

    var body: some View {
        Button {
            Task {
                if secret, !(await OwnerUnlock.authenticate(.passwords, "copy this password")) { return }
                if secret || concealed {
                    NSPasteboard.general.copySecret(value)
                } else {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                }
                withAnimation(Motion.fade) { copied = true }
                try? await Task.sleep(for: .seconds(1.2))
                withAnimation(Motion.fade) { copied = false }
            }
        } label: {
            // every state stays laid out, so the pill never changes size under the cursor
            ZStack {
                if let masked {
                    Text(String(repeating: "●", count: 12))
                        .font(.system(size: 8))
                        .tracking(2)
                        .opacity(masked && !copied ? 1 : 0)
                }
                Text(shown ?? value)
                    .font(monospaced ? .system(.body, design: .monospaced) : .body)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .opacity(masked == true || copied ? 0 : 1)
                Label("Copied", systemImage: "doc.on.doc.fill")
                    .opacity(copied ? 1 : 0)
            }
            .frame(height: 17)
            .foregroundStyle(.secondary)
            .modifier(HoverPill(isLit: isHovering || copied))
        }
        .buttonStyle(.plain)
        .onHover { over in
            isHovering = over
            hovering?.wrappedValue = over
        }
        .animation(Motion.hover, value: isHovering)
        .tooltip(copied ? "Copied" : "Click to copy")
    }
}

/// the current code, grouped for reading, beside the seconds it has left
private struct CodeValue: View {
    let code: OneTimeCode

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let current = code.code(at: context.date)
            let half = current.count / 2
            HStack(spacing: 4) {
                Text("\(code.secondsLeft(at: context.date))s")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                CopyValue(
                    value: current, shown: "\(current.prefix(half)) \(current.dropFirst(half))", monospaced: true,
                    concealed: true)
            }
        }
    }
}

/// a website pill whose click opens the native menu: open, copy, edit
private struct WebsitePill: View {
    let login: SavedLogin
    let edit: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button {
            let url = URL(string: login.origin)
            NativeMenu.popUp([
                ("Open Website", { if let url { PasswordSiteDetail.open(url) } }),
                ("Copy Website", {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(login.host, forType: .string)
                }),
                nil,
                ("Edit Websites", edit),
            ])
        } label: {
            Text(login.host)
                .foregroundStyle(.secondary)
                .modifier(HoverPill(isLit: isHovering))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(Motion.hover, value: isHovering)
    }
}

extension PasswordSiteDetail {
    /// in a new tab of the frontmost browser window, brought forward
    @MainActor
    static func open(_ url: URL) {
        guard let browser = BrowserWindows.shared.browserScope else { return }
        browser.revealTab(browser.newTab(url: url))
    }
}

/// an NSMenu at the pointer, so its items look and behave like the system's
@MainActor
enum NativeMenu {
    private final class Item: NSObject {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
        @objc func fire() { run() }
    }

    /// nil entries are separators, and an entry without an action shows disabled
    static func popUp(_ entries: [(String, (() -> Void)?)?]) {
        let menu = NSMenu()
        var targets: [Item] = []
        for entry in entries {
            guard let (title, run) = entry else {
                menu.addItem(.separator())
                continue
            }
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            if let run {
                let target = Item(run)
                targets.append(target)
                item.target = target
                item.action = #selector(Item.fire)
            }
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        withExtendedLifetime(targets) {}
    }
}

/// nspasteboard.org markers that clipboard managers read
extension NSPasteboard.PasteboardType {
    static let concealed = Self("org.nspasteboard.ConcealedType")
    static let transient = Self("org.nspasteboard.TransientType")
}

extension NSPasteboard {
    /// a password or code for this Mac only, marked so clipboard histories skip it, and cleared after
    /// 90 seconds unless something else was copied since
    func copySecret(_ text: String) {
        prepareForNewContents(with: .currentHostOnly)
        setString(text, forType: .string)
        setString("", forType: .concealed)
        setString("", forType: .transient)
        let copied = changeCount
        Task {
            try? await Task.sleep(for: .seconds(90))
            if changeCount == copied { clearContents() }
        }
    }
}

private struct DraftName: Identifiable {
    let id = UUID()
    var text: String
}

/// one account, Passwords-style: values copy on click; Edit turns the card into fields
private struct AccountCard: View {
    let account: PasswordSite.Account
    @State private var password: String?
    @State private var oneTimeCode: OneTimeCode?
    @State private var passwordHovered = false
    @State private var isEditing = false
    @State private var draftNames: [DraftName] = []
    @State private var newName = ""
    @State private var draftPassword = ""
    @State private var draftCode = ""
    @State private var scanNote: String?
    @State private var draftNotes = ""
    @State private var draftSites: [String] = []
    @State private var newSite = ""
    private var store: PasswordStore { .shared }

    var body: some View {
        Group {
            if isEditing { editor } else { viewer }
        }
        .onAppear {
            password = account.primary.flatMap(store.password(for:))
            oneTimeCode = account.logins.lazy.compactMap(store.oneTimeCode(for:)).first
        }
    }

    private var title: String { account.name.isEmpty ? "No username" : account.name }

    /// the username autofill uses, then the account's other sign-in names
    private var names: [String] {
        ([account.name] + (account.primary?.otherNames ?? [])).filter { !$0.isEmpty }
    }

    /// what a sign-in name is, by its shape
    private static func kind(of name: String) -> String {
        if name.contains("@") { return "Email" }
        if name.wholeMatch(of: /\+?[\d\s().-]{6,}/) != nil { return "Phone" }
        return "Username"
    }

    // MARK: Viewing

    private var viewer: some View {
        Section {
            ForEach(Array(names.enumerated()), id: \.offset) { _, name in
                LabeledContent(Self.kind(of: name)) { CopyValue(value: name) }
            }
            if names.isEmpty {
                LabeledContent("Username") { Text("No username").foregroundStyle(.secondary) }
            }
            if let password {
                // this page opened through a check, so it shows passwords until the Mac locks or sleeps
                LabeledContent("Password") {
                    CopyValue(
                        value: password, monospaced: true, hovering: $passwordHovered, secret: true,
                        masked: !(passwordHovered && (OwnerUnlock.unlockedAt != nil || OwnerUnlock.isUnlocked(.passwords))))
                }
            }
            if let oneTimeCode {
                LabeledContent("Verification Code") { CodeValue(code: oneTimeCode) }
            }
            if !account.logins.isEmpty {
                LabeledContent(account.logins.count == 1 ? "Website" : "Websites") {
                    VStack(alignment: .trailing, spacing: 2) {
                        ForEach(account.logins) { login in WebsitePill(login: login, edit: beginEditing) }
                    }
                }
            }
            ForEach(account.passkeys) { _ in
                LabeledContent("Passkey") {
                    Label("On this Mac", systemImage: "person.badge.key.fill").foregroundStyle(.secondary)
                }
            }
            if let modified = account.modified {
                LabeledContent("Modified") {
                    Text(modified.formatted(.relative(presentation: .named))).foregroundStyle(.secondary)
                }
            }
            if let notes = account.primary?.notes {
                Text(notes).foregroundStyle(.secondary).textSelection(.enabled)
            }
        } header: {
            HStack {
                Text(account.logins.isEmpty ? "Passkey" : title)
                Spacer()
                if account.primary != nil {
                    Button("Edit", action: beginEditing).controlSize(.small)
                }
            }
        }
    }

    // MARK: Editing

    private func beginEditing() {
        draftNames = (names.isEmpty ? [""] : names).map { DraftName(text: $0) }
        newName = ""
        draftPassword = password ?? ""
        draftCode = oneTimeCode?.setup ?? ""
        scanNote = nil
        draftNotes = account.primary?.notes ?? ""
        draftSites = account.logins.map(\.host)
        newSite = ""
        withAnimation(Motion.panel) { isEditing = true }
    }

    @ViewBuilder
    private var editor: some View {
        Section {
            ForEach($draftNames) { $name in
                let isFirst = name.id == draftNames.first?.id
                LabeledContent(isFirst ? "Username" : Self.kind(of: name.text)) {
                    HStack(spacing: 8) {
                        TextField("Username", text: $name.text)
                            .multilineTextAlignment(.trailing)
                            .labelsHidden()
                        if !isFirst {
                            Button("Remove", systemImage: "minus.circle.fill") {
                                draftNames.removeAll { $0.id == name.id }
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .foregroundStyle(.red)
                        }
                    }
                }
            }
            HStack {
                TextField("Add", text: $newName, prompt: Text("Add another username, email or phone"))
                    .onSubmit(addName)
                Button("Add", systemImage: "plus.circle.fill", action: addName)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            HStack {
                Text("Editing")
                Spacer()
                Button("Cancel") { withAnimation(Motion.panel) { isEditing = false } }.controlSize(.small)
                Button("Save", action: save)
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
                    .disabled(draftSites.isEmpty || draftPassword.isEmpty || codeIsInvalid)
            }
        }

        Section {
            LabeledContent("Password") {
                TextField("Password", text: $draftPassword)
                    .font(.system(.body, design: .monospaced))
                    .multilineTextAlignment(.trailing)
                    .labelsHidden()
            }
            if let host = draftSites.first, let url = URL(string: "https://\(host)/.well-known/change-password") {
                HStack {
                    Spacer()
                    Button("Change Password on Website…") { PasswordSiteDetail.open(url) }
                }
            }
        }

        Section {
            LabeledContent("Setup Key") {
                TextField("Setup Key", text: $draftCode, prompt: Text("Key or otpauth:// link"))
                    .font(.system(.body, design: .monospaced))
                    .multilineTextAlignment(.trailing)
                    .labelsHidden()
            }
            HStack {
                if let scanNote { Text(scanNote).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("Scan QR Code in Current Tab", systemImage: "qrcode.viewfinder") { Task { await scanCode() } }
            }
        } header: {
            Text("Verification Code")
        } footer: {
            if codeIsInvalid {
                Text("That isn't a setup key or otpauth:// link.").font(.caption).foregroundStyle(.red)
            }
        }

        Section(draftSites.count == 1 ? "Website" : "Websites") {
            ForEach(draftSites, id: \.self) { host in
                HStack {
                    Text(host)
                    Spacer()
                    Button("Remove \(host)", systemImage: "minus.circle.fill") {
                        draftSites.removeAll { $0 == host }
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
                }
            }
            HStack {
                TextField("Add Website", text: $newSite, prompt: Text("Add website"))
                    .onSubmit(addSite)
                Button("Add", systemImage: "plus.circle.fill", action: addSite)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .disabled(Self.host(newSite) == nil)
            }
        }

        Section("Notes") {
            TextField("Notes", text: $draftNotes, prompt: Text("Add notes"), axis: .vertical)
                .labelsHidden()
                .lineLimit(3...8)
        }

        Section {
            Button(role: .destructive) {
                let sites = account.logins.map(\.host).joined(separator: ", ")
                if confirmDelete("Delete this password?", "\(title) on \(sites)") {
                    account.logins.forEach(store.delete)
                }
            } label: {
                Text("Delete Password").frame(maxWidth: .infinity)
            }
        }
    }

    /// the host a typed website names, or nil if it doesn't name one
    private static func host(_ typed: String) -> String? {
        let trimmed = typed.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return nil }
        let url = URL(string: trimmed.contains("://") ? trimmed : "https://\(trimmed)")
        return url?.host().flatMap { $0.contains(".") ? $0 : nil }
    }

    private var codeIsInvalid: Bool {
        !draftCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && OneTimeCode(draftCode) == nil
    }

    /// the first verification-code QR code showing in the frontmost browser tab
    private func scanCode() async {
        guard let webView = BrowserWindows.shared.browserScope?.selectedTab?.webView,
            let image = try? await webView.takeSnapshot(configuration: nil),
            let picture = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return scanNote = "No page is open to scan." }
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try? VNImageRequestHandler(cgImage: picture).perform([request])
        guard let found = request.results?.lazy.compactMap(\.payloadStringValue).first(where: { OneTimeCode($0) != nil })
        else { return scanNote = "No verification-code QR code is showing in the current tab." }
        draftCode = found
        scanNote = "Scanned from the current tab."
    }

    private func addName() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !draftNames.contains(where: { $0.text == name }) else { return }
        draftNames.append(DraftName(text: name))
        newName = ""
    }

    private func addSite() {
        guard let host = Self.host(newSite), !draftSites.contains(host) else { return }
        draftSites.append(host)
        newSite = ""
    }

    private func save() {
        let changedPassword = draftPassword == password ? nil : draftPassword
        let cleaned = draftNames.map { $0.text.trimmingCharacters(in: .whitespaces) }
        let draftUser = cleaned.first ?? ""
        let others = Array(cleaned.dropFirst().filter { !$0.isEmpty })
        var saved: [SavedLogin] = []
        for login in account.logins {
            if draftSites.contains(login.host) {
                store.edit(login, username: draftUser, password: changedPassword, notes: draftNotes, otherNames: others)
                saved.append(login)
            } else {
                store.delete(login)
            }
        }
        let kept = Set(account.logins.map(\.host))
        for host in draftSites where !kept.contains(host) {
            let added = store.save(
                origin: "https://\(host)", username: draftUser, password: draftPassword,
                in: account.logins.first?.profile ?? Profile.defaultID)
            store.edit(added, username: draftUser, password: nil, notes: draftNotes, otherNames: others)
            saved.append(added)
        }
        // every website the account signs in on offers its code
        let code = OneTimeCode(draftCode)
        for login in saved where store.oneTimeCode(for: login)?.setup != code?.setup {
            store.setOneTimeCode(code, for: login)
        }
        password = draftPassword
        oneTimeCode = code
        withAnimation(Motion.panel) { isEditing = false }
    }
}

/// one suggested password: its root, how each site's name joins it, and what that makes
private struct PasswordRecipeEditor: View {
    @State var recipe: PasswordRecipe
    @State private var showsRoot = false
    @State private var sample = "instagram.com"
    @State private var leakNote: (text: String, color: Color)?
    @AppStorage(PwnedPasswords.enabledKey) private var checksLeaks = false
    @Environment(\.dismiss) private var dismiss
    private var store: PasswordStore { .shared }
    private var isNew: Bool { !store.recipes.contains { $0.id == recipe.id } }
    private var sampleHost: String { URL(string: sample)?.host() ?? sample }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $recipe.name)
                    LabeledContent("Root") {
                        HStack {
                            if showsRoot {
                                TextField("Root", text: $recipe.root)
                            } else {
                                SecureField("Root", text: $recipe.root)
                            }
                            Button {
                                showsRoot.toggle()
                            } label: {
                                Image(systemName: showsRoot ? "eye.slash" : "eye")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(showsRoot ? "Hide root" : "Show root")
                        }
                        .labelsHidden()
                        .font(.system(.body, design: .monospaced))
                    }
                    if !recipe.root.isEmpty { StrengthMeter(password: recipe.root) }
                    if let leakNote { Text(leakNote.text).font(.caption).foregroundStyle(leakNote.color) }
                }
                Section {
                    Picker("Part of its name", selection: $recipe.sitePart) {
                        Text("Whole name").tag(PasswordRecipe.SitePart.name)
                        Text("First letters").tag(PasswordRecipe.SitePart.firstLetters)
                        Text("First letter").tag(PasswordRecipe.SitePart.initial)
                        Text("Scrambled").tag(PasswordRecipe.SitePart.scrambled)
                    }
                    if recipe.sitePart == .firstLetters {
                        Stepper("\(recipe.letters) letters", value: $recipe.letters, in: 2...12)
                    }
                    if recipe.sitePart == .scrambled {
                        Stepper("\(recipe.letters) characters", value: $recipe.letters, in: 3...12)
                        if !recipe.isUsable {
                            Text("Its scramble key is missing, so it can't make passwords. Switch to another part and back to start a new key.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    } else {
                        Picker("Letters", selection: $recipe.letterCase) {
                            Text("lowercase").tag(PasswordRecipe.LetterCase.lower)
                            Text("Capitalised").tag(PasswordRecipe.LetterCase.capitalized)
                            Text("UPPERCASE").tag(PasswordRecipe.LetterCase.upper)
                        }
                    }
                    Picker("Goes", selection: $recipe.siteFirst) {
                        Text("After the root").tag(false)
                        Text("Before the root").tag(true)
                    }
                } header: {
                    InfoLabel(
                        "Each Site Adds",
                        info: "Taken from the site's name: instagram.com gives instagram. Scrambled uses characters only Artemis can work out, so it remembers them for you.")
                }
                Section("Preview") {
                    TextField("Website", text: $sample)
                    LabeledContent("Suggests") {
                        Text((showsRoot ? recipe.password(for: sampleHost) : recipe.masked(for: sampleHost)) ?? "Nothing")
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                if !isNew {
                    Button("Delete", role: .destructive) {
                        store.delete(recipe)
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    store.save(recipe)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(
                    recipe.root.isEmpty || !recipe.isUsable || recipe.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding()
        }
        .frame(width: 440, height: 560)
        .onChange(of: recipe.sitePart) {
            if recipe.sitePart == .scrambled, recipe.key == nil { recipe.key = PasswordRecipe.newKey() }
        }
        .task(id: checksLeaks ? recipe.root : "") {
            leakNote = nil
            guard checksLeaks, !recipe.root.isEmpty else { return }
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            let count = await PwnedPasswords.count(for: recipe.root)
            guard !Task.isCancelled else { return }
            leakNote =
                switch count {
                case nil: ("Couldn't check for leaks right now.", .secondary)
                case 0?: ("Not in any known leak.", .secondary)
                case let count?: ("Seen in \(count.formatted()) leaks. Pick another root.", .red)
                }
        }
        .background(CaptureShield())
    }
}

extension PasswordStore {
    static let shared = PasswordStore { BrowserCore.shared.profile($0) != nil }

    /// writes plain-text passwords to a file the person picks inside Downloads, readable
    /// by its owner only; anywhere outside Downloads is refused
    func writePlaintext(_ csv: String, suggesting name: String, count: Int) -> String {
        guard
            let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?
                .resolvingSymlinksInPath()
        else { return "Downloads isn't reachable." }
        let panel = NSSavePanel()
        panel.title = "Export Passwords"
        panel.message = "This file holds \(count) passwords as plain text. Import it, then delete it."
        panel.directoryURL = downloads
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let picked = panel.url else { return "Export cancelled." }
        let url = picked.resolvingSymlinksInPath()
        let folder = url.deletingLastPathComponent().path
        guard folder == downloads.path || folder.hasPrefix(downloads.path + "/") else {
            return "Artemis can only save into Downloads."
        }
        // owner-only from the moment the file exists, and before a byte lands in it
        let fd = open(url.path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return "Couldn't save (\(String(cString: strerror(errno))))." }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            guard fchmod(fd, 0o600) == 0 else { throw POSIXError(.EPERM) }
            try handle.write(contentsOf: Data(csv.utf8))
            try handle.close()
        } catch {
            return "Couldn't save (\(error.localizedDescription))."
        }
        return "\(count) passwords saved to Downloads/\(url.lastPathComponent)."
    }
}
