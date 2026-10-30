import Foundation
import WebKit

/// What a site can ask Artemis for.
///
/// Deliberately small. These are the capabilities where the answer has to be a
/// per-site decision the user makes once and Artemis remembers — not a global
/// setting, and not something a page gets to have silently.
nonisolated enum SitePermission: String, Codable, CaseIterable, Identifiable, Sendable {
    case camera
    case microphone
    case location
    case notifications

    var id: String { rawValue }

    var label: String {
        switch self {
        case .camera: "Camera"
        case .microphone: "Microphone"
        case .location: "Location"
        case .notifications: "Notifications"
        }
    }

    var icon: String {
        switch self {
        case .camera: "video"
        case .microphone: "mic"
        case .location: "location"
        case .notifications: "bell"
        }
    }

    /// what the prompt says the site is asking for
    var request: String {
        switch self {
        case .camera: "use your camera"
        case .microphone: "use your microphone"
        case .location: "know your location"
        case .notifications: "send you notifications"
        }
    }
}

nonisolated enum PermissionDecision: String, Codable, Sendable {
    case allow
    case deny
}

/// One site's remembered answers.
nonisolated struct SitePermissionRecord: Codable, Identifiable, Sendable {
    /// scheme + host + port, e.g. `https://meet.google.com` — the same unit of
    /// trust the web platform uses, so `https://evil.example` can't inherit an
    /// answer given to `https://good.example`
    var origin: String
    var decisions: [SitePermission: PermissionDecision]
    var updated: Date

    var id: String { origin }
}

/// Remembers which sites may use the camera, the microphone and your location.
///
/// Before this existed Artemis had no `WKUIDelegate` capture handler at all,
/// which WebKit reads as "deny" — so `getUserMedia` failed on every site,
/// silently, and video calls simply did not work in the browser. The store is
/// the memory behind the prompt; `TabManager` owns the queue of live requests
/// and `PermissionPrompt` is the face of it.
///
/// Incognito never touches disk, like every other store in the app.
@MainActor
@Observable
final class SitePermissionStore {
    static let shared = SitePermissionStore()

    private(set) var records: [String: SitePermissionRecord] = [:]
    /// answers given inside the burner space: kept only in memory, forgotten on
    /// quit along with everything else about it
    private var ephemeral: [String: SitePermissionRecord] = [:]

    nonisolated private static let fileName = "permissions.json"

    /// `records` from `read()` skips the load, so a caller can decode off main
    init(records: [String: SitePermissionRecord]? = nil) {
        if let stored = records ?? Self.read() { self.records = stored }
    }

    nonisolated static func read() -> [String: SitePermissionRecord]? {
        AppStorageLocation.loadDurable([String: SitePermissionRecord].self, from: AppStorageLocation.file(fileName))
    }

    /// the remembered answer, or nil if the site has never been asked
    func decision(for origin: String, _ permission: SitePermission, ephemeral isEphemeral: Bool)
        -> PermissionDecision?
    {
        if isEphemeral, let record = ephemeral[origin], let decision = record.decisions[permission] {
            return decision
        }
        return records[origin]?.decisions[permission]
    }

    func set(
        _ decision: PermissionDecision, for origin: String, _ permission: SitePermission,
        ephemeral isEphemeral: Bool
    ) {
        if isEphemeral {
            var record = ephemeral[origin] ?? SitePermissionRecord(
                origin: origin, decisions: [:], updated: Date())
            record.decisions[permission] = decision
            record.updated = Date()
            ephemeral[origin] = record
            return
        }
        var record = records[origin] ?? SitePermissionRecord(
            origin: origin, decisions: [:], updated: Date())
        record.decisions[permission] = decision
        record.updated = Date()
        records[origin] = record
        save()
    }

    func forget(_ origin: String) {
        records[origin] = nil
        ephemeral[origin] = nil
        save()
    }

    func forget(_ origin: String, _ permission: SitePermission, ephemeral isEphemeral: Bool = false) {
        if isEphemeral {
            ephemeral[origin]?.decisions[permission] = nil
            return
        }
        records[origin]?.decisions[permission] = nil
        if records[origin]?.decisions.isEmpty == true { records[origin] = nil }
        save()
    }

    /// the last incognito window closed: its answers go with it
    func forgetEphemeral() {
        ephemeral = [:]
    }

    func forgetAll() {
        records = [:]
        ephemeral = [:]
        save()
    }

    /// every site with a remembered answer, most recently decided first
    var sorted: [SitePermissionRecord] {
        records.values.sorted { $0.updated > $1.updated }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        let url = AppStorageLocation.file(Self.fileName)
        Task.detached(priority: .utility) {
            AppStorageLocation.writeDurable(data, to: url)
        }
    }

    /// write synchronously, for app termination — a detached write is killed
    /// with the process, so an answer given moments before quitting is lost
    func saveNow() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        AppStorageLocation.writeDurableNow(data, to: AppStorageLocation.file(Self.fileName))
    }

    /// `https://host:port` for a security origin, which is what a decision is
    /// keyed by. WebKit hands us the parts; the default port is left off so
    /// `https://example.com` and `https://example.com:443` are one site
    nonisolated static func originString(_ origin: WKSecurityOrigin) -> String {
        var text = "\(origin.protocol)://\(origin.host)"
        let isDefaultPort =
            origin.port == 0 || (origin.protocol == "https" && origin.port == 443)
            || (origin.protocol == "http" && origin.port == 80)
        if !isDefaultPort { text += ":\(origin.port)" }
        return text
    }

    nonisolated static func originString(_ url: URL?) -> String? {
        guard let url, let scheme = url.scheme, let host = url.host() else { return nil }
        var text = "\(scheme)://\(host)"
        if let port = url.port,
            !(scheme == "https" && port == 443), !(scheme == "http" && port == 80)
        {
            text += ":\(port)"
        }
        return text
    }
}
