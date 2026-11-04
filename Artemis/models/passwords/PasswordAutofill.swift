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

    private var suggestions: (panel: NSPanel, tab: BrowserTab.ID)?
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
            if suggestions?.tab == tab.id { closeSuggestions() }
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
            let host = URL(string: candidate.origin)?.host(), !store.neverSave.contains(host)
        else { return }
        let saved = store.logins(in: tab.loginProfile).filter { $0.origin == candidate.origin }
        var replacing = saved.first { $0.username == candidate.username }
        if replacing == nil, candidate.username.isEmpty, !candidate.current.isEmpty {
            replacing = saved.first { store.password(for: $0) == candidate.current }
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
        if let replacing = offer.replacing {
            PasswordStore.shared.edit(replacing, username: replacing.username, password: offer.password)
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
        target(in: tab).map { PasswordStore.shared.matches(for: $0.origin, in: tab.loginProfile) } ?? []
    }

    /// refused unless `login` is one this target's origin is offered
    @discardableResult
    func fill(_ login: SavedLogin, into target: LoginTarget, in tab: BrowserTab) async -> Bool {
        let store = PasswordStore.shared
        guard store.matches(for: target.origin, in: tab.loginProfile).contains(where: { $0.id == login.id }),
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
        guard store.codeMatches(for: target.origin, in: tab.loginProfile).contains(where: { $0.id == login.id }),
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

    /// which of `candidates` the field's `pattern` accepts, tested in one round trip in the page's
    /// process, where WebKit can stop a runaway pattern; all of them without a pattern or an answer
    private func fitting(_ candidates: [String], _ rules: PasswordRules, in target: LoginTarget, of tab: BrowserTab)
        async -> [Bool]
    {
        let all = candidates.map { _ in true }
        guard let pattern = rules.pattern, !candidates.isEmpty else { return all }
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
        guard PasswordStore.shared.fillsFromSuggestions, let kind = body["kind"] as? String,
            let box = body["rect"] as? [String: Any], tab.webView.window != nil
        else { return }
        let offersStrong = kind == "new"
        let fillsCodes = kind == "code"
        let store = PasswordStore.shared
        let logins =
            fillsCodes
            ? store.codeMatches(for: target.origin, in: tab.loginProfile)
            : offersStrong ? [] : store.matches(for: target.origin, in: tab.loginProfile)
        guard offersStrong || !logins.isEmpty else { return closeSuggestions() }
        let recipes = offersStrong ? store.recipes(in: tab.loginProfile).filter(\.isUsable) : []
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
            let made = recipes.compactMap { recipe in recipe.password(for: host).map { (recipe.id, $0) } }
            let fits = await fitting(made.map(\.1), rules, in: target, of: tab)
            let list = LoginSuggestions(
                logins: logins, origin: target.origin, offersStrongPassword: offersStrong, fillsCodes: fillsCodes,
                recipes: recipes, rules: rules, misfits: Set(zip(made, fits).filter { !$1 }.map(\.0.0)),
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
            present(list, below: field, in: tab)
        }
    }

    /// where a cross-origin child frame's content sits in the page, when exactly one iframe has its
    /// origin and the page shows that iframe at each of `points`, `[x, y]` in the frame's CSS px
    func frameOffset(of origin: String, at points: [[Double]] = [], in tab: BrowserTab) async -> CGPoint? {
        let script = """
            const frames = [...document.querySelectorAll("iframe")].filter(f => {
              try { return new URL(f.src, location.href).origin === origin; } catch (e) { return false; }
            }).filter(f => f.getBoundingClientRect().width > 0);
            if (frames.length !== 1) return null;
            const f = frames[0], b = f.getBoundingClientRect(), x = b.left + f.clientLeft, y = b.top + f.clientTop;
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

    private func present(_ list: LoginSuggestions, below css: CGRect, in tab: BrowserTab) {
        closeSuggestions()
        if let panel = suggestionPanel(list, below: css, in: tab.webView) { suggestions = (panel, tab.id) }
    }

    private func closeSuggestions() {
        guard let panel = suggestions?.panel else { return }
        suggestions = nil
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    // MARK: - Keys

    /// the field kinds a key serves from what `origin` has saved; new-password fields always have one
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
        guard PasswordStore.shared.fillsFromSuggestions else { return false }
        let tracked = try? await tab.webView.callAsyncJavaScript(
            "return globalThis.__artemisPasswords?.track(kinds, size, optional) ?? false",
            arguments: [
                "kinds": savedKinds(for: origin, in: tab), "optional": optional,
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
    let logins: [SavedLogin]
    let origin: String
    let offersStrongPassword: Bool
    let fillsCodes: Bool
    let recipes: [PasswordRecipe]
    let rules: PasswordRules
    /// recipes whose password the field's `pattern` turned away
    let misfits: Set<PasswordRecipe.ID>
    let pick: (SavedLogin) -> Void
    /// fills the first candidate the field's `pattern` accepts, else the first
    let generate: ([String]) -> Void
    let manage: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(logins) { login in
                let name = login.username.isEmpty ? "No username" : login.username
                if fillsCodes {
                    SuggestionRow(icon: "lock.badge.clock", title: "Verification Code", detail: name) { pick(login) }
                } else {
                    SuggestionRow(
                        icon: "key.fill", title: name, detail: login.origin == origin ? nil : login.host
                    ) { pick(login) }
                }
            }
            let host = URL(string: origin)?.host() ?? origin
            ForEach(recipes) { recipe in
                if let password = recipe.password(for: host) {
                    SuggestionRow(
                        icon: "key.horizontal.fill", title: recipe.name,
                        detail: rules.problem(with: password)
                            ?? (misfits.contains(recipe.id) ? "Not in the form this site asks for" : recipe.masked(for: host))
                    ) { generate([password]) }
                }
            }
            if offersStrongPassword {
                // symbol-free candidates trail, for a pattern that turns symbols away
                SuggestionRow(icon: "wand.and.sparkles", title: "Use Strong Password", detail: nil) {
                    generate(
                        (0..<8).map { _ in PasswordPage.strongPassword(rules) }
                            + (0..<8).map { _ in PasswordPage.strongPassword(rules, symbols: false) })
                }
                if !rules.namesCharacters {
                    SuggestionRow(icon: "textformat.abc", title: "Strong Password Without Symbols", detail: nil) {
                        generate((0..<8).map { _ in PasswordPage.strongPassword(rules, symbols: false) })
                    }
                }
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
