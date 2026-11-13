// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import AppKit
import SwiftUI
import WebKit

/// Login forms in every frame, watched from an isolated content world: suggestions on a
/// focused field, fills into the frame that asked, and save offers once a submit has
/// navigated away or taken its form with it.
@MainActor
final class PasswordAutofill: NSObject, WKScriptMessageHandler {
    static let shared = PasswordAutofill()
    /// seconds a submit has to show it signed in
    private static let candidateLifetime: TimeInterval = 45
    /// seconds a username step is remembered for the password step that follows it
    private static let usernameLifetime: TimeInterval = 300

    private struct Shown {
        let panel: NSPanel
        let tab: BrowserTab.ID
        weak var webView: WKWebView?
        let frame: WKFrameInfo?

        var list: NSHostingView<LoginSuggestions>? { panel.contentView as? NSHostingView<LoginSuggestions> }
    }

    private var suggestions: Shown?
    /// bumped by every focus and dismiss, so a list still resolving for an older focus never shows
    private var ticket = 0
    private var commitChecks: [BrowserTab.ID: Task<Void, Never>] = [:]

    static func install(into controller: WKUserContentController) {
        controller.add(shared, contentWorld: PasswordPage.world, name: PasswordPage.messageName)
        controller.addUserScript(
            WKUserScript(source: PasswordPage.source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: PasswordPage.world))
    }

    func userContentController(
        _ controller: WKUserContentController, didReceive message: WKScriptMessage
    ) {
        guard let webView = message.webView, let tab = webView.navigationDelegate as? BrowserTab,
            tab.webView === webView, let body = message.body as? [String: Any],
            let type = body["type"] as? String
        else { return }
        let frame = message.frameInfo
        let origin = SitePermissionStore.originString(frame.securityOrigin)
        switch type {
        case "fields":
            // the first form reported holds, though a main-frame form outranks a subframe's
            let held = tab.loginTarget
            if held == nil || (held?.focused == false && held?.frame?.isMainFrame == false && frame.isMainFrame) {
                tab.loginTarget = LoginTarget(frame: frame, origin: origin, focused: false)
            }
            if body["fresh"] as? Bool == true || !savedKinds(for: origin, in: tab).isEmpty {
                Task { await trackKeys(in: frame, origin: origin, of: tab) }
            }
        case "keys":
            showKeys(body["keys"] as? [[String: Any]], from: frame, origin: origin, in: tab)
        case "moved":
            LoginKeys.on(tab.webView)?.settle()
        case "focus":
            let target = LoginTarget(frame: frame, origin: origin, focused: true)
            tab.loginTarget = target
            suggest(body, into: target, in: tab)
        case "dismiss":
            ticket += 1
            if suggestions?.tab == tab.id { closeSuggestions() }
        case "highlight":
            guard suggestions?.tab == tab.id else { return }
            suggestions?.list?.rootView.highlighted = body["index"] as? Int
        case "pick":
            guard suggestions?.tab == tab.id, let rows = suggestions?.list?.rootView.rows, let index = body["index"] as? Int,
                rows.indices.contains(index)
            else { return }
            rows[index].action()
        case "username":
            guard let name = body["username"] as? String, !name.isEmpty, !tab.isPrivate else { return }
            tab.loginUsernameHint = (origin, name, Date())
        case "submit":
            stage(body, origin: origin, in: tab)
        case "gone":
            guard let candidate = tab.loginCandidate, candidate.origin == origin else { return }
            tab.loginCandidate = nil
            offer(candidate, in: tab)
        default:
            break
        }
    }

    // MARK: - Saving

    private func stage(_ body: [String: Any], origin: String, in tab: BrowserTab) {
        guard let password = body["password"] as? String, !password.isEmpty, !tab.isPrivate else { return }
        var name = body["username"] as? String ?? ""
        if name.isEmpty { name = username(for: origin, in: tab) }
        pend(
            LoginCandidate(
                origin: origin, topOrigin: SitePermissionStore.originString(tab.webView.url) ?? origin,
                username: name, password: password, isNew: body["isNew"] as? Bool ?? false,
                current: body["current"] as? String ?? ""),
            in: tab)
    }

    private func username(for origin: String, in tab: BrowserTab) -> String {
        guard let hint = tab.loginUsernameHint, hint.origin == origin,
            Date().timeIntervalSince(hint.at) < Self.usernameLifetime
        else { return "" }
        return hint.name
    }

    /// the plain-text password leaves memory once it can no longer be offered
    private func pend(_ candidate: LoginCandidate, in tab: BrowserTab) {
        tab.loginCandidate = candidate
        Task { [weak tab] in
            try? await Task.sleep(for: .seconds(Self.candidateLifetime))
            if tab?.loginCandidate?.at == candidate.at { tab?.loginCandidate = nil }
        }
    }

    /// The main frame committed a new document. A pending login is offered once that page
    /// has had a moment to show a login form again, which would mean the sign-in failed.
    func pageDidCommit(in tab: BrowserTab) {
        if suggestions?.tab == tab.id { closeSuggestions() }
        LoginKeys.on(tab.webView)?.clear()
        tab.loginTarget = nil
        if let offer = tab.loginOffer, Date().timeIntervalSince(offer.at) > 5 { tab.loginOffer = nil }
        guard let candidate = tab.loginCandidate else { return }
        commitChecks[tab.id]?.cancel()
        commitChecks[tab.id] = Task { [weak self, weak tab] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, let tab, !Task.isCancelled, tab.loginCandidate?.at == candidate.at else { return }
            self.commitChecks[tab.id] = nil
            tab.loginCandidate = nil
            if tab.loginTarget == nil { self.offer(candidate, in: tab) }
        }
    }

    private func offer(_ candidate: LoginCandidate, in tab: BrowserTab) {
        let store = PasswordStore.shared
        guard store.offersToSave, !tab.isPrivate, PasswordStore.isSecure(candidate.origin),
            PasswordStore.isSecure(candidate.topOrigin),
            tab.offersCredentials(to: candidate.origin, under: candidate.topOrigin),
            let host = URL(string: candidate.origin)?.host(), !store.neverSave.contains(host)
        else { return }
        // the logins filling offers here, its www. twin's among them
        let saved = store.matches(for: candidate.origin, in: tab.loginProfile)
        var replacing = saved.first { $0.username == candidate.username }
        if replacing == nil, candidate.username.isEmpty {
            let known = [candidate.current, candidate.password].filter { !$0.isEmpty }
            replacing = saved.first { store.password(for: $0).map(known.contains) == true }
        }
        if let replacing, store.password(for: replacing) == candidate.password {
            return store.markUsed(replacing)
        }
        tab.loginOffer = LoginOffer(
            origin: candidate.origin, username: replacing?.username ?? candidate.username,
            password: candidate.password, replacing: replacing)
    }

    func accept(in tab: BrowserTab) {
        guard let offer = tab.loginOffer else { return }
        tab.loginOffer = nil
        // the login as it is now, which may have been renamed or deleted since the offer was made
        if let replacing = offer.replacing, let current = PasswordStore.shared.logins.first(where: { $0.id == replacing.id }) {
            PasswordStore.shared.edit(current, username: current.username, password: offer.password)
        } else {
            PasswordStore.shared.save(
                origin: offer.origin, username: offer.username, password: offer.password, in: tab.loginProfile)
        }
    }

    func decline(in tab: BrowserTab, forever: Bool) {
        guard let offer = tab.loginOffer else { return }
        tab.loginOffer = nil
        if forever { PasswordStore.shared.setNeverSave(offer.host, true) }
    }

    // MARK: - Filling

    /// the frame showing this tab's login form, else the main frame
    func target(in tab: BrowserTab) -> LoginTarget? {
        tab.loginTarget
            ?? SitePermissionStore.originString(tab.url).map { LoginTarget(frame: nil, origin: $0, focused: false) }
    }

    func logins(in tab: BrowserTab) -> [SavedLogin] {
        guard let target = target(in: tab), tab.offersCredentials(to: target.origin) else { return [] }
        return PasswordStore.shared.matches(for: target.origin, in: tab.loginProfile)
    }

    /// refused unless `login` is one this target's origin is offered
    @discardableResult
    func fill(_ login: SavedLogin, into target: LoginTarget, in tab: BrowserTab) async -> Bool {
        let store = PasswordStore.shared
        guard tab.offersCredentials(to: target.origin),
            store.matches(for: target.origin, in: tab.loginProfile).contains(where: { $0.id == login.id }),
            await OwnerUnlock.authenticate(.passwords, "fill your password for \(login.host)"),
            let password = store.password(for: login),
            await fill(username: login.username, password: password, into: target, in: tab)
        else { return false }
        if !tab.isPrivate { store.markUsed(login) }
        return true
    }

    /// Fills exactly `target`, in this world, only while it is still on `target.origin` and only
    /// into fields it shows. Values go through the native setter and fire `input` and `change`,
    /// so framework-bound fields see them.
    @discardableResult
    func fill(
        username: String, password: String, generated: Bool = false, into target: LoginTarget, in tab: BrowserTab
    ) async -> Bool {
        guard tab.offersCredentials(to: target.origin) else { return false }
        if let frame = target.frame, !frame.isMainFrame, await !frameIsShown(target.origin, in: tab) {
            return false
        }
        let result = try? await tab.webView.callAsyncJavaScript(
            "return globalThis.__artemisPasswords?.fill(origin, username, password, generated, minimum) ?? false",
            arguments: [
                "origin": target.origin, "username": username, "password": password, "generated": generated,
                "minimum": PasswordPage.minimumShown,
            ],
            in: target.frame, contentWorld: PasswordPage.world)
        return result as? Bool == true
    }

    /// the current code of a login this target's website is offered, into the focused code field
    @discardableResult
    func fillCode(_ login: SavedLogin, into target: LoginTarget, in tab: BrowserTab) async -> Bool {
        let store = PasswordStore.shared
        guard tab.offersCredentials(to: target.origin),
            store.codeMatches(for: target.origin, in: tab.loginProfile).contains(where: { $0.id == login.id }),
            await OwnerUnlock.authenticate(.passwords, "fill your verification code for \(login.host)"),
            let code = store.oneTimeCode(for: login)?.code()
        else { return false }
        if let frame = target.frame, !frame.isMainFrame, await !frameIsShown(target.origin, in: tab) {
            return false
        }
        let result = try? await tab.webView.callAsyncJavaScript(
            "return globalThis.__artemisPasswords?.fillCode(origin, code, minimum) ?? false",
            arguments: ["origin": target.origin, "code": code, "minimum": PasswordPage.minimumShown],
            in: target.frame, contentWorld: PasswordPage.world)
        return result as? Bool == true
    }

    /// whether the field focused in `frame` gets the login list: a username field on a site with logins to offer
    func servesFocusedField(in frame: WKFrameInfo, origin: String, of tab: BrowserTab) async -> Bool {
        let store = PasswordStore.shared
        guard store.fillsFromSuggestions, tab.offersCredentials(to: origin),
            !store.matches(for: origin, in: tab.loginProfile).isEmpty
        else { return false }
        let kind = try? await tab.webView.callAsyncJavaScript(
            "return globalThis.__artemisPasswords?.focusedKind() ?? null", in: frame, contentWorld: PasswordPage.world)
        return kind as? String == "username"
    }

    /// whether an iframe on `origin` shows in the top document; true when none can be found there
    func frameIsShown(_ origin: String, in tab: BrowserTab) async -> Bool {
        let script = """
            const boxes = [...document.querySelectorAll("iframe")].filter(f => {
              try { return new URL(f.src || location.href, location.href).origin === origin; } catch (e) { return false; }
            }).map(f => f.getBoundingClientRect());
            return !boxes.length || boxes.some(b => Math.min(b.right, innerWidth) - Math.max(b.left, 0) >= minimum
              && Math.min(b.bottom, innerHeight) - Math.max(b.top, 0) >= minimum);
            """
        let shown = try? await tab.webView.callAsyncJavaScript(
            script, arguments: ["origin": origin, "minimum": PasswordPage.minimumShown], in: nil, contentWorld: PasswordPage.world)
        return shown as? Bool == true
    }

    /// which of `candidates` the field's `pattern` accepts, tested in the page's process, where the page can time
    /// the test; all of them without a pattern or an answer, and a lone candidate, such as a recipe's, is never tested
    private func fitting(_ candidates: [String], _ rules: PasswordRules, in target: LoginTarget, of tab: BrowserTab)
        async -> [Bool]
    {
        let all = candidates.map { _ in true }
        guard let pattern = rules.pattern, candidates.count > 1 else { return all }
        let fits = try? await tab.webView.callAsyncJavaScript(
            PasswordPage.patternFits, arguments: ["pattern": pattern, "candidates": candidates], in: target.frame, contentWorld: PasswordPage.world)
        return fits as? [Bool] ?? all
    }

    private func generate(_ password: String, into target: LoginTarget, in tab: BrowserTab) async {
        guard await fill(username: "", password: password, generated: true, into: target, in: tab), !tab.isPrivate
        else { return }
        pend(
            LoginCandidate(
                origin: target.origin, topOrigin: SitePermissionStore.originString(tab.webView.url) ?? target.origin,
                username: username(for: target.origin, in: tab), password: password, isNew: true, current: ""),
            in: tab)
    }

    // MARK: - Suggestions

    private func suggest(_ body: [String: Any], into target: LoginTarget, in tab: BrowserTab) {
        ticket += 1
        let mine = ticket
        guard PasswordStore.shared.fillsFromSuggestions, tab.offersCredentials(to: target.origin),
            let kind = body["kind"] as? String,
            let box = body["rect"] as? [String: Any], tab.webView.window != nil
        else { return }
        let isNew = kind == "new"
        // random passwords only where a save can follow them; a recipe's can be made again
        let offersStrong = isNew && !tab.isPrivate
        let fillsCodes = kind == "code"
        let store = PasswordStore.shared
        let logins =
            fillsCodes
            ? store.codeMatches(for: target.origin, in: tab.loginProfile)
            : isNew ? [] : store.matches(for: target.origin, in: tab.loginProfile)
        let recipes = isNew ? store.recipes(in: tab.loginProfile).filter(\.isUsable) : []
        guard offersStrong || !logins.isEmpty || !recipes.isEmpty else { return closeSuggestions() }
        let host = URL(string: target.origin)?.host() ?? ""
        let rules = PasswordRules(field: body["rules"] as? [String: Any] ?? [:], host: host)
        let number = { (key: String) in (box[key] as? Double) ?? 0 }
        var field = CGRect(x: number("x"), y: number("y"), width: number("width"), height: number("height"))
        Task {
            if box["resolved"] as? Bool == false {
                guard let offset = await frameOffset(of: target.origin, in: tab) else { return }
                field.origin.x += offset.x
                field.origin.y += offset.y
            }
            guard ticket == mine else { return }
            let list = LoginSuggestions(
                logins: logins, origin: target.origin, offersStrongPassword: offersStrong, fillsCodes: fillsCodes,
                recipes: recipes, rules: rules,
                pick: { login in
                    self.closeSuggestions()
                    Task {
                        if fillsCodes {
                            await self.fillCode(login, into: target, in: tab)
                        } else {
                            await self.fill(login, into: target, in: tab)
                        }
                    }
                },
                generate: { candidates in
                    self.closeSuggestions()
                    Task {
                        let fits = await self.fitting(candidates, rules, in: target, of: tab)
                        await self.generate(candidates[fits.firstIndex(of: true) ?? 0], into: target, in: tab)
                    }
                },
                manage: {
                    self.closeSuggestions()
                    ProfilesNavigator.show(.passwords, for: tab.loginProfile)
                })
            present(list, below: field, in: tab, from: target.frame)
        }
    }

    /// Where a cross-origin child frame's content sits in the page: the focused iframe with its origin
    /// when no `points` are given (split card fields put one per field), else the only one shown, if
    /// the page shows it at each of `points`, `[x, y]` in the frame's CSS px.
    func frameOffset(of origin: String, at points: [[Double]] = [], in tab: BrowserTab) async -> CGPoint? {
        let script = """
            const ours = f => { try { return new URL(f.src, location.href).origin === origin; } catch (e) { return false; } };
            const frames = [...document.querySelectorAll("iframe")].filter(f => ours(f) && f.getBoundingClientRect().width > 0);
            let active = document.activeElement;
            while (active?.shadowRoot?.activeElement) active = active.shadowRoot.activeElement;
            const focused = !points.length && active instanceof HTMLIFrameElement && ours(active)
              && active.getBoundingClientRect().width > 0 ? active : null;
            if (!focused && frames.length !== 1) return null;
            const f = focused ?? frames[0], b = f.getBoundingClientRect(), x = b.left + f.clientLeft, y = b.top + f.clientTop;
            return points.every(([px, py]) => document.elementFromPoint(x + px, y + py) === f) ? [x, y] : null;
            """
        guard
            let point = try? await tab.webView.callAsyncJavaScript(
                script, arguments: ["origin": origin, "points": points], in: nil, contentWorld: PasswordPage.world)
                as? [Double],
            point.count == 2
        else { return nil }
        return CGPoint(x: point[0], y: point[1])
    }

    /// ↑ and ↓ in the field walk the rows from here on
    private func present(_ list: LoginSuggestions, below css: CGRect, in tab: BrowserTab, from frame: WKFrameInfo?) {
        closeSuggestions(tellingPage: false)
        guard let panel = suggestionPanel(list, below: css, in: tab.webView) else { return }
        suggestions = Shown(panel: panel, tab: tab.id, webView: tab.webView, frame: frame)
        tab.webView.evaluateJavaScript(
            "globalThis.__artemisPasswords?.listing(\(list.rows.count))", in: frame, in: PasswordPage.world)
    }

    /// `tellingPage` ends ↑ and ↓ in the field it was under
    private func closeSuggestions(tellingPage: Bool = true) {
        guard let shown = suggestions else { return }
        suggestions = nil
        shown.panel.parent?.removeChildWindow(shown.panel)
        shown.panel.orderOut(nil)
        if tellingPage {
            shown.webView?.evaluateJavaScript("globalThis.__artemisPasswords?.listing(0)", in: shown.frame, in: PasswordPage.world)
        }
    }

    // MARK: - Keys

    /// the field kinds a key serves from what `origin` has saved
    private func savedKinds(for origin: String, in tab: BrowserTab) -> [String] {
        let store = PasswordStore.shared
        return (store.matches(for: origin, in: tab.loginProfile).isEmpty ? [] : ["username", "password"])
            + (store.codeMatches(for: origin, in: tab.loginProfile).isEmpty ? [] : ["code"])
    }

    /// a site with saved logins or codes gets keys before its page shows a password field, if the page
    /// has a field they serve by the time it has loaded
    func pageDidFinish(in tab: BrowserTab) {
        guard let origin = SitePermissionStore.originString(tab.webView.url), !savedKinds(for: origin, in: tab).isEmpty
        else { return }
        Task { await trackKeys(in: nil, origin: origin, of: tab, optional: true) }
    }

    /// turns key reports on in `frame` (nil: the main frame), or asks it for a fresh one; false once it is
    /// gone, or when `optional` and it has no field a key serves
    @discardableResult
    func trackKeys(in frame: WKFrameInfo?, origin: String, of tab: BrowserTab, optional: Bool = false) async -> Bool {
        guard PasswordStore.shared.fillsFromSuggestions, tab.offersCredentials(to: origin) else { return false }
        // a new-password field has random passwords to offer outside incognito, else only a recipe's
        let offersNew = !tab.isPrivate || PasswordStore.shared.recipes(in: tab.loginProfile).contains(where: \.isUsable)
        let tracked = try? await tab.webView.callAsyncJavaScript(
            "return globalThis.__artemisPasswords?.track(kinds, size, optional) ?? false",
            arguments: [
                "kinds": (offersNew ? ["new"] : []) + savedKinds(for: origin, in: tab), "optional": optional,
                "size": LoginKeys.side / (tab.webView.pageZoom * tab.webView.magnification),
            ],
            in: frame, contentWorld: PasswordPage.world)
        return tracked as? Bool == true
    }

    /// a frame's report replaces its keys; nil when its document has gone. A frame reporting while
    /// suggestions are off stops measuring. A subframe's keys move with the page around it, which only
    /// the main frame hears, so that is tracked too.
    private func showKeys(_ list: [[String: Any]]?, from frame: WKFrameInfo, origin: String, in tab: BrowserTab) {
        guard let list, PasswordStore.shared.fillsFromSuggestions else {
            if list != nil {
                tab.webView.evaluateJavaScript("globalThis.__artemisPasswords?.stop()", in: frame, in: PasswordPage.world)
            }
            LoginKeys.on(tab.webView)?.forget(frame)
            return
        }
        guard let keys = LoginKeys.on(tab.webView, making: !list.isEmpty) else { return }
        let ticket = keys.ticket(for: frame)
        if !frame.isMainFrame, !list.isEmpty, !keys.tracksMainFrame,
            let main = SitePermissionStore.originString(tab.webView.url)
        {
            Task { await trackKeys(in: nil, origin: main, of: tab) }
        }
        let resolved = list.allSatisfy { $0["resolved"] as? Bool != false }
        let centres = list.map { [$0["x"] as? Double ?? 0, $0["y"] as? Double ?? 0] }
        Task {
            let offset: CGPoint? = resolved ? .zero : await frameOffset(of: origin, at: centres, in: tab)
            keys.place(list, from: frame, origin: origin, offset: offset, ticket: ticket)
        }
    }

    /// a key's click focuses its field and opens the list under it, or closes the list it opened
    func openKey(_ id: Int, in frame: WKFrameInfo, of tab: BrowserTab) {
        tab.webView.window?.makeFirstResponder(tab.webView)
        Task {
            _ = try? await tab.webView.callAsyncJavaScript(
                "globalThis.__artemisPasswords?.open(id, shown)", arguments: ["id": id, "shown": suggestions?.tab == tab.id],
                in: frame, contentWorld: PasswordPage.world)
        }
    }
}

/// a borderless child panel holding `content` just under `css`, a field's box in the top document's CSS pixels;
/// one CSS pixel is `pageZoom × magnification` points
func suggestionPanel(_ content: some View, below css: CGRect, in webView: WKWebView) -> NSPanel? {
    guard let window = webView.window else { return nil }
    let scale = webView.pageZoom * webView.magnification
    var field = CGRect(x: css.minX * scale, y: css.minY * scale, width: css.width * scale, height: css.height * scale)
    if !webView.isFlipped { field.origin.y = webView.bounds.height - field.maxY }
    let screen = window.convertToScreen(webView.convert(field, to: nil))
    let host = NSHostingView(rootView: content)
    let size = host.fittingSize
    let panel = NSPanel(
        contentRect: NSRect(x: screen.minX, y: screen.minY - size.height - 4, width: size.width, height: size.height),
        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.becomesKeyOnlyIfNeeded = true
    panel.animationBehavior = .none
    panel.contentView = host
    window.addChildWindow(panel, ordered: .above)
    return panel
}

/// the list under a focused login field
struct LoginSuggestions: View {
    struct Row {
        let icon: String
        let title: String
        let detail: String?
        let action: () -> Void
    }

    let logins: [SavedLogin]
    let origin: String
    let offersStrongPassword: Bool
    let fillsCodes: Bool
    let recipes: [PasswordRecipe]
    let rules: PasswordRules
    let pick: (SavedLogin) -> Void
    /// fills the first candidate the field's `pattern` accepts, else the first
    let generate: ([String]) -> Void
    let manage: () -> Void
    /// the row ↑ and ↓ in the page have reached, an index into `rows`
    var highlighted: Int?

    /// every row but Manage Passwords…, in order: the random passwords lead where they are offered
    var rows: [Row] {
        let host = URL(string: origin)?.host() ?? origin
        let saved = logins.map { login in
            let name = login.username.isEmpty ? "No username" : login.username
            let elsewhere = login.origin == origin ? nil : login.host
            return fillsCodes
                ? Row(icon: "lock.badge.clock", title: "Verification Code", detail: elsewhere.map { "\(name) · \($0)" } ?? name) {
                    pick(login)
                }
                : Row(icon: "key.fill", title: name, detail: elsewhere) { pick(login) }
        }
        let suggested = recipes.compactMap { recipe in
            recipe.password(for: host).map { password in
                Row(
                    icon: "key.horizontal.fill", title: recipe.name,
                    detail: rules.problem(with: password) ?? recipe.masked(for: host)
                ) { generate([password]) }
            }
        }
        guard offersStrongPassword else { return saved + suggested }
        // symbol-free candidates trail, for a pattern that turns symbols away
        let strong = Row(icon: "wand.and.sparkles", title: "Use Strong Password", detail: nil) {
            generate(
                (0..<8).map { _ in PasswordPage.strongPassword(rules) }
                    + (0..<8).map { _ in PasswordPage.strongPassword(rules, symbols: false) })
        }
        let plain = Row(icon: "textformat.abc", title: "Strong Password Without Symbols", detail: nil) {
            generate((0..<8).map { _ in PasswordPage.strongPassword(rules, symbols: false) })
        }
        return (rules.namesCharacters ? [strong] : [strong, plain]) + saved + suggested
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                SuggestionRow(
                    icon: row.icon, title: row.title, detail: row.detail, isHighlighted: highlighted == index,
                    action: row.action)
            }
            Divider().padding(.vertical, 2)
            SuggestionRow(icon: "gearshape", title: "Manage Passwords…", detail: nil, action: manage)
        }
        .padding(6)
        .frame(width: 260)
        .background(VisualEffectView(material: .menu, blending: .behindWindow))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// a row of the suggestion list or the url pill key's popover; without an action it is not a button
struct SuggestionRow: View {
    let icon: String
    let title: String
    let detail: String?
    /// chosen from the keyboard
    var isHighlighted = false
    let action: (() -> Void)?
    @State private var isHovering = false

    var body: some View {
        if let action {
            Button(action: action) { label }
                .buttonStyle(.plain)
                .onHover { isHovering = $0 }
        } else {
            label
        }
    }

    private var label: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.system(size: 13)).lineLimit(1)
                if let detail {
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.primary.opacity(isHovering || isHighlighted ? 0.1 : 0)))
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .animation(Motion.hover, value: isHovering)
    }
}
