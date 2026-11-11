// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import AppKit
import SecurityInterface
import SwiftUI
import WebKit

/// url pill — a clean domain at rest; a click grows it into the command bar,
/// editing the full url. persists when a space has no tabs: what you type there
/// opens the space's first tab
struct UrlField: View {
    @Environment(TabManager.self) private var tabManager
    @Environment(\.chromeInk) private var ink
    @Environment(ExtensionManager.self) private var extensions
    @AppStorage(BrowserToolbar.shownKey) private var showsToolbar = false
    @AppStorage(BrowserToolbar.fullURLKey) private var showsFullURL = false
    var inToolbar = false

    var body: some View {
        let locked = SpaceLock.shared.isLocked(tabManager.currentSpace)
        let tab = tabManager.unlockedContentTab
        HStack(spacing: 6) {
            if inToolbar, let tab { CopyURLButton(tab: tab, standalone: true) }
            pill(tab)
            if inToolbar { PageActions(tab: tab) }
        }
        .disabled(tab == nil && locked)
    }

    /// in the toolbar the pill hugs its url and keeps only the pinned extensions;
    /// the page's buttons sit either side of it
    private func pill(_ tab: BrowserTab?) -> some View {
        let pinned = extensions.enabledExtensions(in: tabManager).contains(where: \.isPinned)
        return HStack(spacing: 6) {
            Text(Self.displayText(for: tab, full: inToolbar && showsFullURL))
                .font(.system(size: 13))
                .foregroundStyle(ink.opacity(tab?.url == nil ? 0.45 : 0.9))
                .lineLimit(1)
                .contentTransition(.opacity)
                .frame(maxWidth: inToolbar ? nil : .infinity, alignment: .leading)
                .accessibilityLabel("Address")
                .accessibilityValue(tab?.url?.absoluteString ?? "")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { tabManager.editAddress() }
            if !inToolbar, let tab {
                ReaderButton(tab: tab)
                PageTranslationButton(tab: tab)
                PasswordKeyButton(tab: tab, isOnScreen: tabManager.isSidebarSettled)
                AutofillOfferButton(tab: tab, isOnScreen: tabManager.isSidebarSettled)
            }
            PinnedExtensionsBar()
            if !inToolbar {
                if let tab { CopyURLButton(tab: tab) }
                SiteSettingsButton(tab: tab)
            }
        }
        .modifier(PillChrome(hugs: inToolbar, endsInButton: !inToolbar || pinned))
        // the whole pill is tappable, not just the text
        .contentShape(Rectangle())
        .onTapGesture { tabManager.editAddress() }
        .contextMenu {
            Button(showsToolbar ? "Hide Toolbar" : "Show Toolbar") { showsToolbar.toggle() }
            if inToolbar {
                Button(showsFullURL ? "Hide Full URL" : "Show Full URL") { showsFullURL.toggle() }
            }
        }
        .animation(Motion.address, value: Self.displayText(for: tab, full: inToolbar && showsFullURL))
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { frame in
            tabManager.urlPillFrame = frame
            // the address bar grown from this pill follows it, as when the sidebar pins
            if tabManager.isCommandBarVisible, let origin = tabManager.addressBarOrigin, !origin.isEmpty,
                tabManager.isInWindow(frame), frame != origin
            {
                withAnimation(Motion.address) { tabManager.addressBarOrigin = frame }
            }
        }
        // moving between sidebar and toolbar, the outgoing pill may leave after the new one lands
        .onDisappear { if inToolbar == showsToolbar { tabManager.urlPillFrame = nil } }
        // the address bar draws this pill's stand-in while it grows and shrinks
        .opacity(tabManager.addressBarOrigin == nil ? 1 : 0)
        .animation(Motion.fade, value: tabManager.addressBarOrigin == nil)
    }

    /// the committed page's address, or one the user asked for that hasn't answered yet; never a
    /// load the page started that hasn't committed
    static func displayText(for tab: BrowserTab?, full: Bool = false) -> String {
        // attempted url keeps the pill honest when a load fails
        let url = tab?.requestedURL ?? tab?.url ?? tab?.lastAttemptedURL
        guard let url, let host = url.host() else {
            return "Search or enter URL"
        }
        if full { return url.absoluteString }
        let shown = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        guard let port = url.port, port != (url.scheme == "https" ? 443 : 80) else { return shown }
        return "\(shown):\(port)"
    }
}

/// the shared glass pill around the url text
private struct PillChrome: ViewModifier {
    private let metrics = SidebarMetrics.standard
    /// as wide as its contents, rather than the width it's offered
    var hugs = false
    var endsInButton = true

    func body(content: Content) -> some View {
        let leading: CGFloat = 14
        content
            // tighter on the trailing side so a trailing button tucks to the
            // pill edge; the text keeps its breathing room on the left. the
            // capsule insets the button by its own vertical gap, so it nests
            .padding(.leading, leading)
            .padding(.trailing, endsInButton ? (metrics.rowHeight - 22) / 2 : leading)
            // pin the pill to a row's height — the 22pt settings button would
            // otherwise inflate it past rowHeight via the vertical padding
            .frame(
                maxWidth: hugs ? nil : .infinity, minHeight: metrics.rowHeight, maxHeight: metrics.rowHeight,
                alignment: .leading)
            .chromeGlass(in: .capsule)
    }
}

/// the page's buttons right of the toolbar's pill, gathered in one glass capsule
struct PageActions: View {
    let tab: BrowserTab?

    var body: some View {
        // 22pt buttons whose highlight is a bar-tall circle: spaced and inset
        // so one button alone makes a circle matching the nav buttons
        HStack(spacing: 14) {
            if let tab {
                ReaderButton(tab: tab)
                PageTranslationButton(tab: tab)
                PasswordKeyButton(tab: tab)
                AutofillOfferButton(tab: tab)
            }
            SiteSettingsButton(tab: tab)
        }
        .padding(.horizontal, (SidebarMetrics.glassSide - 22) / 2)
        .frame(height: SidebarMetrics.glassSide)
        .chromeGlass(in: .capsule, interactive: true)
    }
}

/// shown only while the reader is on: an exit, never an invitation. entering
/// is deliberate, via ⌘⇧R, the menu or the command bar
private struct ReaderButton: View {
    @Environment(\.chromeInk) private var ink
    let tab: BrowserTab

    var body: some View {
        if tab.isReaderMode {
            Button {
                Task { await tab.toggleReader() }
            } label: {
                Image(systemName: "doc.plaintext.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(ink.opacity(0.95))
                    .frame(width: 22, height: 22)
                    .background(UrlBarHighlight(fill: ink.opacity(0.16)))
                    .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .tooltip("Hide Reader", keys: ["⌘", "⇧", "R"])
            .transition(Motion.grow(from: 0.8))
        }
    }
}

/// present only while a page translation is running, shown or failed. it offers the way
/// back to the original, the language to translate into and the rules, and carries any error
private struct PageTranslationButton: View {
    @Environment(\.chromeInk) private var ink
    let tab: BrowserTab
    @State private var isHovering = false
    @State private var isShowingPanel = false
    @State private var targets: [Locale.Language] = []

    private var status: String {
        switch tab.pageTranslation {
        case .idle: ""
        case .detecting: "Translating on device…"
        case .translating(_, _, let progress): "Translating on device… \(Int(progress * 100))%"
        case .translated(let from, let to):
            "Translated on device from \(PageTranslation.name(of: from)) to \(PageTranslation.name(of: to))"
        case .failed(let message): message
        }
    }

    private var progress: Double? {
        switch tab.pageTranslation {
        case .detecting: 0
        case .translating(_, _, let progress): progress
        default: nil
        }
    }

    var body: some View {
        if tab.pageTranslation != .idle {
            Button {
                isShowingPanel.toggle()
            } label: {
                Group {
                    if let progress {
                        ProgressView(value: progress)
                            .progressViewStyle(.circular)
                            .controlSize(.mini)
                            .tint(ink)
                    } else {
                        Image(systemName: tab.pageTranslation.isActive ? "translate" : "exclamationmark.triangle")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(ink.opacity(isHovering ? 0.9 : 0.7))
                    }
                }
                .frame(width: 22, height: 22)
                .background(UrlBarHighlight(fill: ink.opacity(isHovering ? 0.13 : 0)))
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .animation(Motion.hover, value: isHovering)
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
            .tooltip(status, keys: tab.pageTranslation.isActive ? ["⌥", "⌘", "T"] : [])
            .holdsSidebar(while: isShowingPanel)
            .popover(isPresented: $isShowingPanel, arrowEdge: .bottom) { panel }
            .transition(Motion.grow(from: 0.8))
        }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(status)
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
            if let languages = tab.pageTranslation.languages {
                Picker("Translate to", selection: target(languages.to)) {
                    ForEach(targets, id: \.self) { Text(PageTranslation.name(of: $0)).tag($0) }
                }
                .pickerStyle(.menu)
                .disabled(targets.isEmpty)
                // incognito obeys the rules but never makes them
                if !tab.isPrivate, let rules = tab.translationRules {
                    Toggle(
                        "Always translate \(PageTranslation.name(of: languages.from))",
                        isOn: Binding(
                            get: { rules.alwaysTranslates(languages.from) },
                            set: { tab.setAlwaysTranslates(languages.from, $0) }))
                    Toggle(
                        "Never translate this site",
                        isOn: Binding(get: { rules.neverTranslates(tab.url) }, set: { tab.setNeverTranslatesSite($0) }))
                }
            }
            Button(tab.pageTranslation.isActive ? "Show Original" : "Dismiss") {
                isShowingPanel = false
                tab.showOriginal()
            }
        }
        .padding(12)
        .frame(width: 260, alignment: .leading)
        .task { targets = await PageTranslation.targetLanguages() }
    }

    private func target(_ current: Locale.Language) -> Binding<Locale.Language> {
        Binding(
            get: { targets.first { PageTranslation.sameTarget($0, current) } ?? current },
            set: { language in Task { await tab.translatePage(to: language) } })
    }
}

/// present while this site has saved logins, or a save the person hasn't answered;
/// a fresh save offer opens its popover once, as the direct answer to a sign-in
private struct PasswordKeyButton: View {
    let tab: BrowserTab
    /// false while a collapsed sidebar holds the button off the window; an offer waits for it
    var isOnScreen = true
    @State private var isHovering = false
    @State private var isShowingPanel = false
    @State private var target: LoginTarget?

    var body: some View {
        if tab.loginOffer != nil || !PasswordAutofill.shared.logins(in: tab).isEmpty {
            Button {
                target = PasswordAutofill.shared.target(in: tab)
                isShowingPanel.toggle()
            } label: {
                Image(systemName: tab.loginOffer == nil ? "key" : "key.fill")
                    .font(.system(size: 13, weight: .bold))
                    // a waiting save offer stays lit
                    .modifier(ChromeButtonFace(isHovering: isHovering || tab.loginOffer != nil, boxSize: 22, inUrlBar: true))
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
            .tooltip(tab.loginOffer == nil ? "Passwords for this site" : "Save password")
            .task(id: isOnScreen ? tab.loginOffer?.id : nil) {
                guard isOnScreen, tab.loginOffer?.shown == false else { return }
                tab.loginOffer?.shown = true
                target = PasswordAutofill.shared.target(in: tab)
                isShowingPanel = true
            }
            .holdsSidebar(while: isShowingPanel)
            .popover(isPresented: $isShowingPanel, arrowEdge: .bottom) {
                PasswordPanel(tab: tab, target: target) { isShowingPanel = false }
            }
            .transition(Motion.grow(from: 0.8))
        }
    }
}

/// present only while a submitted address or card waits on an answer; its popover opens once, as the
/// direct answer to the submit
private struct AutofillOfferButton: View {
    let tab: BrowserTab
    /// false while a collapsed sidebar holds the button off the window; an offer waits for it
    var isOnScreen = true
    @State private var isShowingPanel = false

    var body: some View {
        if let offer = tab.autofillOffer {
            Button {
                isShowingPanel.toggle()
            } label: {
                Image(systemName: offer.card == nil ? "house.fill" : "creditcard.fill")
                    .font(.system(size: 12, weight: .bold))
                    // a waiting offer stays lit
                    .modifier(ChromeButtonFace(isHovering: true, boxSize: 22, inUrlBar: true))
            }
            .buttonStyle(.plain)
            .tooltip(offer.card == nil ? "Save address" : "Save card")
            .task(id: isOnScreen ? offer.id : nil) {
                guard isOnScreen, tab.autofillOffer?.shown == false else { return }
                tab.autofillOffer?.shown = true
                isShowingPanel = true
            }
            .holdsSidebar(while: isShowingPanel)
            .popover(isPresented: $isShowingPanel, arrowEdge: .bottom) {
                AutofillOfferPanel(tab: tab, offer: offer) { isShowingPanel = false }
            }
            .transition(Motion.grow(from: 0.8))
        }
    }
}

private struct AutofillOfferPanel: View {
    let tab: BrowserTab
    let offer: AutofillOffer
    let close: () -> Void

    private var title: String {
        let verb = offer.updatesAddress || offer.updatesCard ? "Update" : "Save"
        return switch (offer.address, offer.card) {
        case (.some, .some): "\(verb) this address and card?"
        case (.some, nil): "\(verb) this address?"
        default: "\(verb) this card?"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 13, weight: .semibold))
            if let address = offer.address {
                Text([address.name, address.summary].filter { !$0.isEmpty }.joined(separator: "\n"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            if let card = offer.card {
                Text("\(card.label), expires \(card.expiry)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Not Now") {
                    tab.autofillOffer = nil
                    close()
                }
                Button(offer.updatesAddress || offer.updatesCard ? "Update" : "Save") {
                    Autofill.shared.accept(in: tab)
                    close()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
        .frame(width: 280, alignment: .leading)
    }
}

/// the key's popover: the pending save, else this site's logins
private struct PasswordPanel: View {
    let tab: BrowserTab
    let target: LoginTarget?
    let close: () -> Void
    /// what a row's menu last copied, said on that row for a moment
    @State private var copied: Copy?
    @State private var isHoveringNever = false
    @State private var hoveringMore: SavedLogin.ID?

    private struct Copy: Equatable {
        let login: SavedLogin.ID
        let note: String
        let at = Date()
    }

    private var logins: [SavedLogin] {
        guard let target, tab.offersCredentials(to: target.origin) else { return [] }
        return PasswordStore.shared.matches(for: target.origin, in: tab.loginProfile)
    }

    var body: some View {
        if let offer = tab.loginOffer {
            VStack(alignment: .leading, spacing: 10) {
                Text(offer.replacing == nil ? "Save password for \(offer.host)?" : "Update password for \(offer.host)?")
                    .font(.system(size: 13, weight: .semibold))
                Text(offer.username.isEmpty ? "No username" : offer.username)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Never for This Site") {
                        PasswordAutofill.shared.decline(in: tab, forever: true)
                        close()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(isHoveringNever ? .primary : .secondary)
                    .onHover { isHoveringNever = $0 }
                    .animation(Motion.hover, value: isHoveringNever)
                    Spacer()
                    Button("Not Now") {
                        PasswordAutofill.shared.decline(in: tab, forever: false)
                        close()
                    }
                    Button(offer.replacing == nil ? "Save" : "Update") {
                        PasswordAutofill.shared.accept(in: tab)
                        close()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(12)
            .frame(width: 280, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(logins) { login in
                    HStack(spacing: 2) {
                        SuggestionRow(
                            icon: "key.fill", title: login.username.isEmpty ? "No username" : login.username,
                            detail: copied?.login == login.id ? copied?.note : login.host, action: fill(login))
                        Button {
                            NativeMenu.popUp([
                                ("Copy Username", login.username.isEmpty
                                    ? nil : { copy(login.username, "Username copied", from: login) }),
                                ("Copy Password", {
                                    Task {
                                        guard await OwnerUnlock.authenticate(.passwords, "copy the password for \(login.host)"),
                                            let password = PasswordStore.shared.password(for: login)
                                        else { return }
                                        copy(password, "Password copied", from: login, concealed: true)
                                    }
                                }),
                            ])
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 12, weight: .semibold))
                                .frame(width: 24, height: 24)
                                .background(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(.primary.opacity(hoveringMore == login.id ? 0.1 : 0)))
                                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("More")
                        .onHover { hoveringMore = $0 ? login.id : nil }
                        .animation(Motion.hover, value: hoveringMore)
                        .padding(.trailing, 2)
                        .tooltip("More")
                    }
                }
                Divider().padding(.vertical, 2)
                SuggestionRow(icon: "gearshape", title: "Manage Passwords…", detail: nil) {
                    close()
                    ProfilesNavigator.show(.passwords, for: tab.loginProfile)
                }
            }
            .padding(6)
            .frame(width: 280)
            .task(id: copied) {
                try? await Task.sleep(for: .seconds(1.5))
                if !Task.isCancelled { copied = nil }
            }
        }
    }

    /// a row fills only into a login form the page reported; only a report gives a target its frame
    private func fill(_ login: SavedLogin) -> (() -> Void)? {
        guard tab.loginTarget != nil, let target, target.frame != nil else { return nil }
        return {
            close()
            Task { await PasswordAutofill.shared.fill(login, into: target, in: tab) }
        }
    }

    private func copy(_ text: String, _ note: String, from login: SavedLogin, concealed: Bool = false) {
        if concealed {
            NSPasteboard.general.copySecret(text)
        } else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        copied = Copy(login: login.id, note: note)
    }
}

struct CopyURLButton: View {
    let tab: BrowserTab?
    var standalone = false
    @State private var isHovering = false
    @State private var copied = false

    private var url: URL? { tab?.url }

    var body: some View {
        Button {
            guard let url else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
            copied = true
        } label: {
            Image(systemName: copied ? "checkmark" : "link")
                .font(.system(size: 13, weight: .bold))
                .modifier(ChromeButtonFace(
                    isHovering: isHovering, standalone: standalone, boxSize: standalone ? 28 : 22,
                    inUrlBar: !standalone))
                .animation(Motion.pop, value: copied)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .disabled(url == nil)
        .opacity(url == nil ? 0.4 : 1)
        .tooltip(copied ? "Copied!" : "Copy URL")
        .accessibilityLabel("Copy URL")
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(1.2))
            copied = false
        }
    }
}

private struct SiteSettingsButton: View {
    @Environment(ExtensionManager.self) private var extensions
    @Environment(TabManager.self) private var tabManager
    let tab: BrowserTab?
    @State private var isHovering = false
    @State private var isShowingPanel = false
    /// the popup an extension opened itself (`chrome.action.openPopup`), anchored here
    @State private var programmaticPopup: WKWebExtension.Action?
    @State private var showProgrammaticPopup = false

    var body: some View {
        Button {
            isShowingPanel.toggle()
        } label: {
            TwoKnobs()
                .stroke(style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
                .frame(width: 16, height: 12)
                .modifier(ChromeButtonFace(isHovering: isHovering, boxSize: 22, inUrlBar: true))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .tooltip("Site settings")
        .accessibilityLabel("Site settings")
        .holdsSidebar(while: isShowingPanel)
        .popover(isPresented: $isShowingPanel, arrowEdge: .bottom) {
            // popovers don't always inherit @Observable environment on macOS;
            // re-inject so the Extensions section finds the managers
            SiteSettingsPanel(tab: tab)
                .environment(ExtensionManager.shared)
                .environment(tabManager)
        }
        .popover(isPresented: $showProgrammaticPopup, arrowEdge: .bottom) {
            if let programmaticPopup {
                ExtensionPopupContainer(action: programmaticPopup)
            }
        }
        // every window has one of these buttons; the focused window's presents
        .onChange(of: extensions.pendingPopup) { _, request in
            guard let request, tabManager === BrowserWindows.shared.current else { return }
            extensions.pendingPopup = nil
            guard let ext = extensions.enabledExtensions(in: tabManager).first(where: { $0.id == request.extensionID })
            else { return }
            programmaticPopup = extensions.action(for: ext)
            showProgrammaticPopup = programmaticPopup?.presentsPopup == true
        }
        .onChange(of: showProgrammaticPopup) { _, shown in
            if !shown { programmaticPopup?.closePopup() }
        }
    }
}

/// the site-settings glyph: two slider knobs, unboxed (SF only ships them in a square)
private struct TwoKnobs: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let d: CGFloat = 5.2
        for (y, x) in [(r.minY + d / 2, r.minX + r.width * 0.66), (r.maxY - d / 2, r.minX + r.width * 0.34)] {
            p.move(to: CGPoint(x: r.minX, y: y))
            p.addLine(to: CGPoint(x: x - d / 2, y: y))
            p.addEllipse(in: CGRect(x: x - d / 2, y: y - d / 2, width: d, height: d))
            p.move(to: CGPoint(x: x + d / 2, y: y))
            p.addLine(to: CGPoint(x: r.maxX, y: y))
        }
        return p
    }
}

/// the site-settings popover: extensions, connection security and data clearing,
/// site permissions and the Chrome disguise
private struct SiteSettingsPanel: View {
    @Environment(\.dismiss) private var dismiss
    let tab: BrowserTab?
    @State private var secureHover = false
    @State private var menuHover = false
    @State private var showActions = false

    private var isTrustedManually: Bool {
        guard let tab, let host = tab.url?.host() else { return false }
        return CertificateTrust.hasException(for: host, ephemeral: tab.isPrivate)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ExtensionsDropdownSection()

            Divider().overlay(.primary.opacity(0.08))

            connectionRow

            if let tab, let origin = SitePermissionStore.originString(tab.url) {
                SitePermissionRows(origin: origin, ephemeral: tab.isPrivate)
            }

            if let tab, let url = tab.url, url.scheme == "https" || url.scheme == "http",
                let host = url.host()
            {
                ChromeDisguiseRow(tab: tab, host: host)
            }
        }
        .padding(12)
        .frame(width: 260)
    }

    private var connectionRow: some View {
        let isSecure = tab?.isSecure == true
        return HStack(spacing: 10) {
            // opens the native certificate-trust panel for the page's server trust
            Button {
                let trust = tab?.webView.serverTrust
                dismiss()
                // let the popover close before the sheet attaches to the window
                DispatchQueue.main.async {
                    CertificateTrust.showViewer(trust: trust)
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isSecure ? "lock.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .semibold))
                    Text(isSecure ? "Secure" : "Not Secure")
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundStyle(.primary.opacity(0.9))
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(.primary.opacity(secureHover ? 0.14 : 0.08))
                )
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .animation(Motion.hover, value: secureHover)
            }
            .buttonStyle(.plain)
            .onHover { secureHover = $0 }
            .disabled(tab?.webView.serverTrust == nil)
            // the row reads as a status, so say that it is also a button
            .tooltip(isSecure ? "View certificate" : "Check this certificate")

            Spacer(minLength: 0)

            // a Button and popover, not a Menu: Menu swallows pointer tracking,
            // so .onHover never reaches its label
            Button {
                showActions = true
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary.opacity(menuHover ? 0.9 : 0.55))
                    .frame(width: 30, height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(.primary.opacity(menuHover ? 0.18 : 0))
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .animation(Motion.hover, value: menuHover)
            }
            .buttonStyle(.plain)
            .onHover { menuHover = $0 }
            .tooltip("More actions")
            .popover(isPresented: $showActions, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    if let tab, let host = tab.url?.host(), isTrustedManually {
                        PopoverActionRow(title: "Stop Trusting This Certificate", icon: "xmark.shield") {
                            showActions = false
                            CertificateTrust.forget(host)
                            tab.reload()
                        }
                    }
                    PopoverActionRow(title: "Clear Cookies for This Site", icon: "trash") {
                        showActions = false
                        if let tab { Task { await SiteSettingsPanel.clear([WKWebsiteDataTypeCookies], of: tab) } }
                    }
                    PopoverActionRow(title: "Clear All Data for This Site", icon: "trash") {
                        showActions = false
                        if let tab {
                            Task { await SiteSettingsPanel.clear(WKWebsiteDataStore.allWebsiteDataTypes(), of: tab) }
                        }
                    }
                }
                .padding(6)
            }
            .disabled(tab?.url?.host() == nil)
        }
    }

    /// clears `types` for the tab's site (its host and parent domains) in the tab's own
    /// data store only, then reloads the page so it stops using what was cleared
    @MainActor
    static func clear(_ types: Set<String>, of tab: BrowserTab) async {
        guard let host = tab.url?.host()?.lowercased() else { return }
        let store = tab.dataStore
        let records = await store.dataRecords(ofTypes: types).filter {
            host == $0.displayName || host.hasSuffix("." + $0.displayName)
        }
        await store.removeData(ofTypes: types, for: records)
        tab.reload()
    }
}

/// Ask / Allow / Block for each permission this site can request, against the
/// same store the page's prompts and Settings › Privacy & Security read
private struct SitePermissionRows: View {
    let origin: String
    let ephemeral: Bool
    private var store: SitePermissionStore { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(SitePermission.allCases) { permission in
                HStack {
                    Label(permission.label, systemImage: permission.icon)
                        .font(.system(size: 12))
                    Spacer()
                    Picker(permission.label, selection: binding(permission)) {
                        Text("Ask").tag(PermissionDecision?.none)
                        Text("Allow").tag(PermissionDecision?.some(.allow))
                        Text("Block").tag(PermissionDecision?.some(.deny))
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
            }
        }
    }

    private func binding(_ permission: SitePermission) -> Binding<PermissionDecision?> {
        Binding {
            store.decision(for: origin, permission, ephemeral: ephemeral)
        } set: { decision in
            if let decision {
                store.set(decision, for: origin, permission, ephemeral: ephemeral)
            } else {
                store.forget(origin, permission, ephemeral: ephemeral)
            }
        }
    }
}

/// per-site "Pretend to be Chrome"; a change reloads the page, since the UA is
/// chosen when a navigation starts
private struct ChromeDisguiseRow: View {
    let tab: BrowserTab
    let host: String
    @State private var isOn = false

    private var isEligible: Bool { ChromeDisguise.isEligible(host) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label("Pretend to be Chrome", systemImage: "theatermasks")
                    .font(.system(size: 12))
                Spacer()
                Toggle("Pretend to be Chrome", isOn: Binding {
                    isOn
                } set: { on in
                    isOn = on
                    ChromeDisguise.set(on, for: host, ephemeral: tab.isPrivate)
                    tab.reload()
                })
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .disabled(!isEligible)
            }
            Text(
                isEligible
                    ? "For sites that only work in Chrome. Never used on Google sign-in pages, "
                        + "which block browsers that do this."
                    : "Unavailable on Google sign-in pages: Google blocks browsers that "
                        + "pretend to be Chrome there."
            )
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        // the popover outlives a redirect to another host
        .onChange(of: host, initial: true) { isOn = ChromeDisguise.isOn(for: host, ephemeral: tab.isPrivate) }
    }
}

/// one action row in a small sidebar popover
struct PopoverActionRow: View {
    let title: String
    let icon: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 13))
                Spacer(minLength: 0)
            }
            .foregroundStyle(.primary.opacity(isHovering ? 0.95 : 0.8))
            .padding(.horizontal, 8)
            .frame(height: 28)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.primary.opacity(isHovering ? 0.13 : 0))
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .animation(Motion.hover, value: isHovering)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

extension View {
    /// keeps a peeked overlay sidebar out while `open`. a view removed in the same
    /// pass that closes it (Dismiss, Never, the last tab closing) still lets go
    func holdsSidebar(while open: Bool) -> some View {
        modifier(SidebarHold(open: open))
    }
}

private struct SidebarHold: ViewModifier {
    @Environment(TabManager.self) private var tabManager
    let open: Bool
    @State private var holding = false

    func body(content: Content) -> some View {
        content
            .onChange(of: open) { _, open in
                tabManager.isSidebarPopoverOpen = open
                holding = open
            }
            .onDisappear {
                if holding { tabManager.isSidebarPopoverOpen = false }
            }
    }
}
