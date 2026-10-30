import AppKit
import CryptoKit
import LocalAuthentication
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

    /// the last click or key press Artemis itself received, and its window
    private var gesture: (at: Date, window: NSWindow?) = (.distantPast, nil)
    /// when each tab's last ceremony ended; the next needs a gesture made after it
    private var finished: [BrowserTab.ID: Date] = [:]
    private var busy: Set<BrowserTab.ID> = []
    private var monitor: Any?

    static func install(into controller: WKUserContentController) {
        controller.addScriptMessageHandler(shared, contentWorld: .page, name: PasskeyPage.messageName)
        controller.addUserScript(
            WKUserScript(source: PasskeyPage.source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        guard shared.monitor == nil else { return }
        shared.monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .keyDown]) { event in
            MainActor.assumeIsolated { shared.gesture = (Date(), event.window) }
            return event
        }
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
            let body = message.body as? [String: Any], let type = body["type"] as? String,
            let challenge = (body["challenge"] as? String).flatMap(Data.init(base64URL:)), !challenge.isEmpty
        else { return .refused(prompted: false) }
        let origin = SitePermissionStore.originString(frame.securityOrigin)
        let host = frame.securityOrigin.host.lowercased()
        let rpID = ((body["rpId"] as? String) ?? host).lowercased()
        let now = Date()
        let last = finished[tab.id] ?? .distantPast
        guard PasswordStore.isSecure(origin), Passkeys.isValid(rpID: rpID, for: host),
            gesture.window != nil, gesture.window === webView.window, gesture.at > last,
            now.timeIntervalSince(gesture.at) < Self.gestureWindow, now.timeIntervalSince(last) > Self.spacing,
            busy.insert(tab.id).inserted
        else { return .refused(prompted: false) }
        defer {
            busy.remove(tab.id)
            finished[tab.id] = Date()
        }
        let clientData = { (kind: String) in
            Passkeys.clientDataJSON(type: kind, challenge: challenge.base64URL, origin: origin)
        }
        switch type {
        case "create": return await create(body, rpID: rpID, tab: tab, clientData: clientData("webauthn.create"))
        case "get": return await get(body, rpID: rpID, tab: tab, clientData: clientData("webauthn.get"))
        default: return .refused(prompted: false)
        }
    }

    private func create(_ body: [String: Any], rpID: String, tab: BrowserTab, clientData: Data) async -> Outcome {
        let algorithms = body["algorithms"] as? [Int] ?? []
        let user = body["user"] as? [String: Any] ?? [:]
        guard !tab.isPrivate, algorithms.isEmpty || algorithms.contains(-7),
            let handle = (user["id"] as? String).flatMap(Data.init(base64URL:)), (1...64).contains(handle.count)
        else { return .refused(prompted: false) }
        let name = PasskeyPage.clean(user["name"] as? String ?? "")
        guard await Self.verify("create a passkey for \(rpID) as \u{201C}\(name)\u{201D}") else {
            return .refused(prompted: true)
        }
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
        let authData = Passkeys.authenticatorData(rpID: rpID, credential: (id, key.publicKey.rawRepresentation))
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
        guard let passkey = candidates.count == 1 ? candidates[0] : await Self.choose(candidates, rpID, tab),
            await Self.verify("sign in to \(rpID) as \u{201C}\(PasskeyPage.clean(passkey.userName))\u{201D}")
        else { return .refused(prompted: true) }
        let authData = Passkeys.authenticatorData(rpID: rpID)
        guard let blob = store.passkeyKey(passkey),
            let signature = try? Passkeys.sign(
                authData: authData, clientData: clientData, blob: blob, enclave: passkey.enclave)
        else { return .refused(prompted: true) }
        return .done([
            "id": passkey.id, "clientDataJSON": clientData.base64URL,
            "authenticatorData": authData.base64URL, "signature": signature.base64URL,
            "userHandle": passkey.userHandle,
        ])
    }

    /// Touch ID or the account password, every ceremony
    private static func verify(_ reason: String) async -> Bool {
        (try? await LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) == true
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
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        guard await alert.beginSheetModal(for: window) == .alertFirstButtonReturn else { return nil }
        return passkeys[picker.indexOfSelectedItem]
    }
}
