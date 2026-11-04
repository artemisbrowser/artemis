import AppKit
import Foundation

/// the native-messaging endpoint a WebKit user agent sends Bitwarden's clipboard, export and popup
/// calls to, answered in the shapes of its `SafariWebExtensionHandler`. biometric unlock needs a key
/// in the Bitwarden desktop app's keychain access group, so it reports unsupported
@MainActor
enum PasswordManagerBridge {
    /// the app id Bitwarden's Safari code path messages
    static let bitwardenAppID = "com.bitwarden.desktop"

    /// `BiometricsStatus.PlatformUnsupported` in bitwarden/clients, which hides the biometrics option
    private static let biometricsPlatformUnsupported = 5

    static func handle(_ message: [String: Any]) -> Any? {
        guard let command = message["command"] as? String else { return [:] }
        switch command {
        case "readFromClipboard":
            // the reply is the bare pasteboard string, as Safari's handler sends it
            return NSPasteboard.general.string(forType: .string) ?? ""

        case "copyToClipboard":
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(message["data"] as? String ?? "", forType: .string)
            return [:]

        case "showPopover":
            // the same signal `action.openPopup` raises: the url bar presents the pending id
            if let ext = ExtensionManager.shared.installed.first(where: {
                $0.name.localizedCaseInsensitiveContains("bitwarden")
            }) {
                ExtensionManager.shared.pendingPopupExtensionID = ext.id
            }
            return [:]

        case "downloadFile":
            // vault export: {fileName, blobData, blobOptions:{type}} as JSON in "data"
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
