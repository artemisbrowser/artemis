// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import Foundation

/// one saved agent conversation, as Artemis keeps it
struct AgentChat: Codable, Identifiable {
    let id: UUID
    var name: String
    let space: UUID
    var updated: Date
    var entries: [AgentTask.Entry]
}

/// each profile's saved agent chats, one file per chat in the profile's own folder. never
/// synced and never in a backup; writes go through the durable-write queue
@Observable
final class AgentChats {
    static let shared = AgentChats()

    /// read lazily, in a view's body too, so its filling in notifies nothing; `revision` does
    @ObservationIgnored private var loaded: [UUID: [UUID: AgentChat]] = [:]
    private var revision = 0

    static func folder(_ profile: Profile) -> URL {
        let folder = profile.file("AgentChats")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return folder
    }

    private static func file(_ id: UUID, in profile: Profile) -> URL {
        folder(profile).appending(path: "\(id.uuidString).json")
    }

    private func all(_ profile: Profile) -> [UUID: AgentChat] {
        if let chats = loaded[profile.id] { return chats }
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.folder(profile), includingPropertiesForKeys: nil)) ?? []
        let chats = files.filter { $0.pathExtension == "json" }.compactMap { AppStorageLocation.loadDurable(AgentChat.self, from: $0) }
        let byID = Dictionary(chats.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        loaded[profile.id] = byID
        return byID
    }

    /// newest first, without those of a locked space
    func chats(in profile: Profile) -> [AgentChat] {
        _ = revision
        let locked = SpaceLock.shared.lockedIDs
        return all(profile).values.filter { !locked.contains($0.space) }.sorted { $0.updated > $1.updated }
    }

    func chat(_ id: UUID, in profile: Profile) -> AgentChat? {
        all(profile)[id].flatMap { SpaceLock.shared.lockedIDs.contains($0.space) ? nil : $0 }
    }

    func save(_ chat: AgentChat, in profile: Profile) {
        _ = all(profile)
        loaded[profile.id]?[chat.id] = chat
        revision += 1
        guard let data = try? JSONEncoder().encode(chat) else { return }
        AppStorageLocation.writeDurable(data, to: Self.file(chat.id, in: profile), takenAt: AppStorageLocation.snapshotTime())
    }

    func rename(_ id: UUID, to name: String, in profile: Profile) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, var chat = all(profile)[id] else { return }
        chat.name = name
        save(chat, in: profile)
        for manager in BrowserWindows.shared.mainManagers where manager.agentTask?.chatID == id { manager.agentTask?.name = name }
    }

    /// removes the matching chats' files, and ends any of them open in a window
    func delete(where matches: (AgentChat) -> Bool, in profile: Profile) {
        let gone = all(profile).values.filter(matches).map(\.id)
        for manager in BrowserWindows.shared.mainManagers {
            if let open = manager.agentTask?.chatID, gone.contains(open) { manager.closeAgentChat() }
        }
        for id in gone { loaded[profile.id]?[id] = nil }
        revision += 1
        let files = gone.map { Self.file($0, in: profile) }
        AppStorageLocation.enqueueDurable {
            for file in files {
                try? FileManager.default.removeItem(at: file)
                try? FileManager.default.removeItem(at: file.appendingPathExtension("bak"))
            }
        }
    }

    func delete(_ id: UUID, in profile: Profile) { delete(where: { $0.id == id }, in: profile) }

    func delete(since: Date, in profile: Profile) { delete(where: { $0.updated >= since }, in: profile) }
}
