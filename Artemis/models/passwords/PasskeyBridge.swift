// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import AppKit
import CryptoKit
import WebKit

/// WebAuthn `publicKey` requests from top-level documents, answered by `Passkeys` in place of
/// WebKit's own ceremony, which needs an entitlement this build can't carry. The page supplies
/// only the request: origin, rpId, client data, the user's gesture and verification are native.
final class PasskeyBridge: NSObject, WKScriptMessageHandlerWithReply {
    static let shared = PasskeyBridge()
    /// seconds a click or key press stays good for starting a ceremony
    private static let gestureWindow: TimeInterval = 5
    /// seconds between one ceremony's end and the next one's start, per tab
    private static let spacing: TimeInterval = 3
    /// seconds a refusal that showed nothing waits before the page hears it
    private static let refusalDelay: Duration = .seconds(2)

    private enum Outcome {
        case done([String: Any])
        /// the person verified, and the site already holds one of this Mac's passkeys
        case excluded
        case refused(prompted: Bool)
    }

    /// when each tab's last ceremony ended; the next needs a gesture made after it
    private var finished: [BrowserTab.ID: Date] = [:]
    private var busy: Set<BrowserTab.ID> = []
    /// a conditional request, held until the login suggestions pick a passkey or its page goes
    private struct Waiting {
        let origin: String
        let rpID: String
        let allowed: Set<String>
        let pick: CheckedContinuation<SavedPasskey?, Never>
    }
    private var waiting: [BrowserTab.ID: Waiting] = [:]
    /// UV is claimed only while the passwords policy asks the owner at all; the gesture is always UP
    private static var verifies: Bool { OwnerUnlock.Kind.passwords.policy != .never }

    static func install(into controller: WKUserContentController) {
        controller.addScriptMessageHandler(shared, contentWorld: .page, name: PasskeyPage.messageName)
        controller.addUserScript(
            WKUserScript(source: PasskeyPage.source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        UserGesture.watch()
    }

    func userContentController(
        _ controller: WKUserContentController, didReceive message: WKScriptMessage
    ) async -> (Any?, String?) {
        switch await run(message) {
        case .done(let reply):
            return (reply, nil)
        case .excluded:
            return (["error": "InvalidStateError", "message": "This account already has a passkey here."], nil)
        case .refused(let prompted):
            if !prompted { try? await Task.sleep(for: Self.refusalDelay) }
            return (["error": "NotAllowedError", "message": "The operation either timed out or was not allowed."], nil)
        }
    }

    private func run(_ message: WKScriptMessage) async -> Outcome {
        let frame = message.frameInfo
        guard frame.isMainFrame, let webView = message.webView,
            let tab = webView.navigationDelegate as? BrowserTab, tab.webView === webView,
            let body = message.body as? [String: Any], let type = body["type"] as? String
        else { return .refused(prompted: false) }
        if type == "cancel" {
            answer(nil, for: tab.id)
            return .refused(prompted: true)
        }
        let origin = SitePermissionStore.originString(frame.securityOrigin)
        let host = frame.securityOrigin.host.lowercased()
        let rpID = ((body["rpId"] as? String) ?? host).lowercased()
        guard let challenge = (body["challenge"] as? String).flatMap(Data.init(base64URL:)), !challenge.isEmpty,
            PasswordStore.isSecure(origin), tab.offersCredentials(to: origin), Passkeys.isValid(rpID: rpID, for: host)
        else { return .refused(prompted: false) }
        let clientData = { (kind: String) in
            Passkeys.clientDataJSON(type: kind, challenge: challenge.base64URL, origin: origin)
        }
        // the pick in Artemis's own list is this ceremony's gesture
        if type == "get", body["conditional"] as? Bool == true {
            let id = tab.id
            answer(nil, for: id)
            let picked = await withCheckedContinuation {
                waiting[id] = Waiting(origin: origin, rpID: rpID, allowed: Set(body["allow"] as? [String] ?? []), pick: $0)
            }
            guard let picked else { return .refused(prompted: true) }
            return await sign(with: picked, rpID: rpID, clientData: clientData("webauthn.get"))
        }
        let now = Date()
        let last = finished[tab.id] ?? .distantPast
        guard let pressed = UserGesture.recent(in: webView, within: Self.gestureWindow), pressed > last,
            now.timeIntervalSince(last) > Self.spacing,
            busy.insert(tab.id).inserted
        else { return .refused(prompted: false) }
        defer {
            busy.remove(tab.id)
            finished[tab.id] = Date()
        }
        switch type {
        case "create": return await create(body, rpID: rpID, tab: tab, clientData: clientData("webauthn.create"))
        case "get": return await get(body, rpID: rpID, tab: tab, clientData: clientData("webauthn.get"))
        default: return .refused(prompted: false)
        }
    }

    /// the passkeys the conditional request waiting in `tab` would take from `origin`'s page
    func offered(to origin: String, in tab: BrowserTab) -> [SavedPasskey] {
        guard let request = waiting[tab.id], request.origin == origin else { return [] }
        return PasswordStore.shared.passkeys(in: tab.loginProfile).filter {
            $0.rpID == request.rpID && (request.allowed.isEmpty || request.allowed.contains($0.id))
        }
    }

    /// ends the tab's waiting conditional request: signed with `passkey`, or refused
    func answer(_ passkey: SavedPasskey?, for tab: BrowserTab.ID) {
        waiting.removeValue(forKey: tab)?.pick.resume(returning: passkey)
    }

    private func create(_ body: [String: Any], rpID: String, tab: BrowserTab, clientData: Data) async -> Outcome {
        let algorithms = body["algorithms"] as? [Int] ?? []
        let user = body["user"] as? [String: Any] ?? [:]
        guard !tab.isPrivate, algorithms.isEmpty || algorithms.contains(-7),
            let handle = (user["id"] as? String).flatMap(Data.init(base64URL:)), (1...64).contains(handle.count)
        else { return .refused(prompted: false) }
        let name = PasskeyPage.clean(user["name"] as? String ?? "")
        // every ceremony asks on screen, so an unlock still in its window never acts for a page unseen
        guard let window = tab.webView.window else { return .refused(prompted: false) }
        let confirm = NSAlert()
        confirm.messageText = "Create a passkey for \(rpID)" + (name.isEmpty ? "?" : " as \u{201C}\(name)\u{201D}?")
        confirm.informativeText = "Passkeys made in Artemis are kept on this Mac only."
        // click-only: a Return typed for the page must not answer for the person
        confirm.addButton(withTitle: "Continue").keyEquivalent = ""
        confirm.addButton(withTitle: "Cancel")
        guard await confirm.beginSheetModal(for: window) == .alertFirstButtonReturn,
            await OwnerUnlock.authenticate(.passwords, "create a passkey for \(rpID) as \u{201C}\(name)\u{201D}")
        else { return .refused(prompted: true) }
        let store = PasswordStore.shared
        let excluded = Set(body["exclude"] as? [String] ?? [])
        if store.passkeys(in: tab.loginProfile).contains(where: { $0.rpID == rpID && excluded.contains($0.id) }) {
            await Self.inform(tab, "You already have a passkey for \(rpID) in Artemis.")
            return .excluded
        }

        let key = Passkeys.makeKey()
        var id = Data(count: 16)
        guard id.withUnsafeMutableBytes({ SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }) == errSecSuccess,
            store.add(
                SavedPasskey(
                    id: id.base64URL, rpID: rpID, userHandle: handle.base64URL, userName: name,
                    displayName: PasskeyPage.clean(user["displayName"] as? String ?? ""), created: Date(),
                    enclave: key.enclave, profileID: PasswordStore.stored(tab.loginProfile)),
                key: key.blob)
        else { return .refused(prompted: true) }
        let authData = Passkeys.authenticatorData(
            rpID: rpID, verified: Self.verifies, credential: (id, key.publicKey.rawRepresentation))
        return .done([
            "id": id.base64URL, "clientDataJSON": clientData.base64URL,
            "attestationObject": Passkeys.attestationObject(authData).base64URL,
            "authenticatorData": authData.base64URL, "publicKey": key.publicKey.derRepresentation.base64URL,
        ])
    }

    private func get(_ body: [String: Any], rpID: String, tab: BrowserTab, clientData: Data) async -> Outcome {
        let store = PasswordStore.shared
        let allowed = Set(body["allow"] as? [String] ?? [])
        let candidates = store.passkeys(in: tab.loginProfile).filter {
            $0.rpID == rpID && (allowed.isEmpty || allowed.contains($0.id))
        }
        guard !candidates.isEmpty else {
            await Self.inform(tab, "Artemis has no passkey for \(rpID).")
            return .refused(prompted: true)
        }
        guard let passkey = await Self.choose(candidates, rpID, tab) else { return .refused(prompted: true) }
        return await sign(with: passkey, rpID: rpID, clientData: clientData)
    }

    private func sign(with passkey: SavedPasskey, rpID: String, clientData: Data) async -> Outcome {
        let authData = Passkeys.authenticatorData(rpID: rpID, verified: Self.verifies)
        guard
            await OwnerUnlock.authenticate(
                .passwords, "sign in to \(rpID) as \u{201C}\(PasskeyPage.clean(passkey.userName))\u{201D}"),
            let blob = PasswordStore.shared.passkeyKey(passkey),
            let signature = try? Passkeys.sign(
                authData: authData, clientData: clientData, blob: blob, enclave: passkey.enclave)
        else { return .refused(prompted: true) }
        return .done([
            "id": passkey.id, "clientDataJSON": clientData.base64URL,
            "authenticatorData": authData.base64URL, "signature": signature.base64URL,
            "userHandle": passkey.userHandle,
        ])
    }

    private static func inform(_ tab: BrowserTab, _ text: String) async {
        guard let window = tab.webView.window else { return }
        let alert = NSAlert()
        alert.messageText = text
        alert.informativeText = "Passkeys made in Artemis are kept on this Mac only."
        _ = await alert.beginSheetModal(for: window)
    }

    private static func choose(_ passkeys: [SavedPasskey], _ rpID: String, _ tab: BrowserTab) async
        -> SavedPasskey?
    {
        guard let window = tab.webView.window else { return nil }
        let alert = NSAlert()
        alert.messageText = "Sign in to \(rpID)"
        alert.informativeText = "Choose the account to use."
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 26))
        for passkey in passkeys {
            let name = PasskeyPage.clean(passkey.userName), display = PasskeyPage.clean(passkey.displayName)
            picker.menu?.addItem(withTitle: display.isEmpty ? name : "\(name) — \(display)", action: nil, keyEquivalent: "")
        }
        alert.accessoryView = picker
        alert.addButton(withTitle: "Continue").keyEquivalent = ""
        alert.addButton(withTitle: "Cancel")
        guard await alert.beginSheetModal(for: window) == .alertFirstButtonReturn else { return nil }
        return passkeys[picker.indexOfSelectedItem]
    }
}
