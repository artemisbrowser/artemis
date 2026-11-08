// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import Foundation
import WebKit

/// a capability a site must ask for, answered once per site and remembered
nonisolated enum SitePermission: String, Codable, CaseIterable, Identifiable, Sendable {
    case camera
    case microphone
    case location
    case notifications
    case downloads

    var id: String { rawValue }

    var label: String {
        switch self {
        case .camera: "Camera"
        case .microphone: "Microphone"
        case .location: "Location"
        case .notifications: "Notifications"
        case .downloads: "Downloads"
        }
    }

    var icon: String {
        switch self {
        case .camera: "video"
        case .microphone: "mic"
        case .location: "location"
        case .notifications: "bell"
        case .downloads: "arrow.down.circle"
        }
    }

    /// `icon` for a site that was refused
    var blockedIcon: String {
        self == .downloads ? "xmark.circle" : "\(icon).slash"
    }

    /// what the prompt says the site is asking for
    var request: String {
        switch self {
        case .camera: "use your camera"
        case .microphone: "use your microphone"
        case .location: "know your location"
        case .notifications: "send you notifications"
        case .downloads: "download files"
        }
    }
}

nonisolated enum PermissionDecision: String, Codable, Sendable {
    case allow
    case deny
}

/// one site's remembered answers
nonisolated struct SitePermissionRecord: Codable, Identifiable, Sendable {
    /// scheme + host + non-default port, e.g. `https://meet.google.com`
    var origin: String
    var decisions: [SitePermission: PermissionDecision]
    var updated: Date

    var id: String { origin }
}

/// the remembered answers behind `PermissionPrompt`; `TabManager` queues the
/// live requests. incognito answers stay in memory
@MainActor
@Observable
final class SitePermissionStore {
    static let shared = SitePermissionStore()

    private(set) var records: [String: SitePermissionRecord] = [:]
    /// answers given in incognito, never written
    private var ephemeral: [String: SitePermissionRecord] = [:]

    private static let fileName = "permissions.json"

    private init() {
        records =
            AppStorageLocation.loadDurable(
                [String: SitePermissionRecord].self, from: AppStorageLocation.file(Self.fileName)) ?? [:]
    }

    /// the remembered answer, or nil if the site has never been asked. incognito
    /// answers take precedence over, then fall back to, the saved ones
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
        AppStorageLocation.discardUnreadable(of: AppStorageLocation.file(Self.fileName))
        saveNow(keepsBackup: false)
    }

    /// every site with a remembered answer, most recently decided first
    var sorted: [SitePermissionRecord] {
        records.values.sorted { $0.updated > $1.updated }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        AppStorageLocation.writeDurable(data, to: AppStorageLocation.file(Self.fileName))
    }

    /// write synchronously, for app termination, where a queued write dies
    /// with the process
    func saveNow(keepsBackup: Bool = true) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        AppStorageLocation.writeDurableNow(data, to: AppStorageLocation.file(Self.fileName), keepsBackup: keepsBackup)
    }

    /// `scheme://host[:port]`, the key a decision is stored under; a default port
    /// (or WebKit's 0 for none) is left off
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
