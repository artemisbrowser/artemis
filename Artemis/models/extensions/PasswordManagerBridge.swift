import AppKit
import Foundation

/// Services the native-messaging endpoint Bitwarden's extension expects from
/// its Safari app extension (`sendNativeMessage("com.bitwarden.desktop", …)`).
///
/// Why this exists: Bitwarden detects its host browser from the user agent, and
/// a WebKit UA reads as Safari — so clipboard copy/read, vault-export download
/// and "open the popup" are all routed to this app id instead of the web APIs
/// the Chrome/Firefox paths use. Safari answers from
/// `SafariWebExtensionHandler.swift` in the Bitwarden desktop app; Artemis
/// answers here with the same message shapes (verified against their handler
/// source, bitwarden/clients `apps/browser/src/safari`).
///
/// Biometric unlock is deliberately reported as unavailable: the real flow
/// hands out a vault key stored in the *Bitwarden desktop app's* keychain
/// access group, which no other app can (or should) read. Password unlock is
/// fully self-contained in the extension and unaffected.
@MainActor
enum PasswordManagerBridge {
    /// the app id Bitwarden's Safari code path messages
    static let bitwardenAppID = "com.bitwarden.desktop"

    /// BiometricsStatus.PlatformUnsupported in bitwarden/clients — hides the
    /// biometrics option in the UI rather than offering a button that fails
    private static let biometricsPlatformUnsupported = 5

    static func handle(_ message: [String: Any]) -> Any? {
        guard let command = message["command"] as? String else { return [:] }
        switch command {
        case "readFromClipboard":
            // reply is the raw string (Safari's handler returns the pasteboard
            // string as the whole message payload)
            return NSPasteboard.general.string(forType: .string) ?? ""

        case "copyToClipboard":
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(message["data"] as? String ?? "", forType: .string)
            return [:]

        case "showPopover":
            // "open my popup": same signal chrome.action.openPopup lands on —
            // the url bar's settings button observes the pending id and presents
            if let ext = ExtensionManager.shared.installed.first(where: {
                $0.name.localizedCaseInsensitiveContains("bitwarden")
            }) {
                ExtensionManager.shared.pendingPopupExtensionID = ext.id
            }
            return [:]

        case "downloadFile":
            // vault export: {fileName, blobData, blobOptions:{type}} as JSON in
            // "data". Safari runs a save panel; so do we
            guard let json = message["data"] as? String,
                let parsed = try? JSONSerialization.jsonObject(with: Data(json.utf8))
                    as? [String: Any],
                let fileName = parsed["fileName"] as? String
            else { return [:] }
            let blob = parsed["blobData"] as? String ?? ""
            let type = (parsed["blobOptions"] as? [String: Any])?["type"] as? String
            let data = type == "text/plain"
                ? Data(blob.utf8) : (Data(base64Encoded: blob) ?? Data(blob.utf8))
            guard !ExtensionLab.isRequested else { return [:] }
            let panel = NSSavePanel()
            panel.canCreateDirectories = true
            panel.nameFieldStringValue = fileName
            if panel.runModal() == .OK, let url = panel.url {
                try? data.write(to: url)
            }
            return [:]

        case "getBiometricsStatus", "getBiometricsStatusForUser":
            return biometricsReply(
                command: command, message: message, response: biometricsPlatformUnsupported)

        case "authenticateWithBiometrics", "unlockWithBiometricsForUser",
            "biometricUnlock", "biometricUnlockAvailable":
            return biometricsReply(command: command, message: message, response: false)

        case "sleep":
            return [:]

        default:
            debugLog("bitwarden bridge: unhandled command \(command)")
            return [:]
        }
    }

    /// their biometrics replies all share one envelope: the inner "message"
    /// carries the command back with a response and the caller's messageId
    private static func biometricsReply(
        command: String, message: [String: Any], response: Any
    ) -> [String: Any] {
        [
            "message": [
                "command": command,
                "response": response,
                "timestamp": Int64(Date().timeIntervalSince1970 * 1000),
                "messageId": message["messageId"] as? Int ?? 0,
            ]
        ]
    }
}
