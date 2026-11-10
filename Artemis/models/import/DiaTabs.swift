// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import CommonCrypto
import CryptoKit
import Foundation
import SQLite3

/// Dia's spaces and favourites, from the encrypted `tabs.db` or the older
/// `StorableProfileContainers.json`. Nil when `tabs.db` exists and `key` is nil or doesn't open it.
nonisolated enum DiaTabs {
    /// `namespace` is "<bundleID>/<profile folder>"; space ids hang off it
    static func read(profile: URL, key: Data?, namespace: String) -> (spaces: [ImportedSpace], favourites: [ImportedTab])? {
        let folder = profile.lastPathComponent
        let database = profile.appending(path: "tabs.db")
        guard FileManager.default.fileExists(atPath: database.path) else {
            let dia = profile.deletingLastPathComponent().deletingLastPathComponent()
            return legacy(dia.appending(path: "StorableProfileContainers.json"), folder: folder, namespace: namespace)
        }
        guard let key else { return nil }

        let plain: Data
        do {
            plain = try decrypt(database, key: databaseKey(key, label: "profile/\(folder)/tabs"))
        } catch {
            debugLog("dia import: \(folder)/tabs.db skipped, \(error.reason)")
            return nil
        }
        let temp = FileManager.default.temporaryDirectory.appending(path: "dia-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: temp) }
        guard FileManager.default.createFile(atPath: temp.path, contents: plain, attributes: [.posixPermissions: 0o600])
        else {
            debugLog("dia import: \(folder)/tabs.db skipped, the decrypted copy could not be written")
            return nil
        }
        return SQLiteCopy.withDatabase(at: temp) { tree($0, namespace: namespace) }
    }

    // MARK: - Decrypting tabs.db

    private struct Unreadable: Error { var reason: String }

    private static let pageSize = 4096
    /// each page ends in a 16-byte IV then a 64-byte HMAC, which is not checked
    private static let reserved = 80
    private static let saltKey = Data(base64Encoded: "iOe1Ue/XtonbieE/5m1nAgewvWQlePHRcKnoU10EyOM=")!

    /// `key` is the 16-byte PBKDF2 key of "Dia Safe Storage"
    private static func databaseKey(_ key: Data, label: String) -> SymmetricKey {
        let info = Data(label.utf8)
        let salt = HMAC<SHA256>.authenticationCode(for: info, using: SymmetricKey(data: saltKey))
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: key), salt: Data(salt), info: info, outputByteCount: 32)
    }

    /// The database as plain SQLite, with the log's committed frames folded in.
    private static func decrypt(_ file: URL, key: SymmetricKey) throws(Unreadable) -> Data {
        guard let main = try? Data(contentsOf: file), !main.isEmpty, main.count % pageSize == 0 else {
            throw Unreadable(reason: "it is not a whole number of 4096-byte pages")
        }
        var count = main.count / pageSize
        var pages: [Int: Data] = [:]
        for n in 1...count { pages[n] = main.subdata(in: (n - 1) * pageSize..<n * pageSize) }

        // frames from an older log generation carry another salt; frames after the last commit are unfinished
        if let wal = try? Data(contentsOf: URL(fileURLWithPath: file.path + "-wal")), wal.count >= 32,
            bigEndian(wal, 8) == pageSize
        {
            let salt = wal.subdata(in: 16..<24)
            var pending: [Int: Data] = [:]
            var at = 32
            while at + 24 + pageSize <= wal.count, wal.subdata(in: at + 8..<at + 16) == salt {
                pending[bigEndian(wal, at)] = wal.subdata(in: at + 24..<at + 24 + pageSize)
                let commit = bigEndian(wal, at + 4)
                if commit > 0 {
                    pages.merge(pending) { $1 }
                    pending = [:]
                    count = commit
                }
                at += 24 + pageSize
            }
        }
        guard (1...count).allSatisfy({ pages[$0] != nil }) else {
            throw Unreadable(reason: "the log claims \(count) pages and \(pages.count) are held")
        }

        var out = Data(capacity: count * pageSize)
        for n in 1...count {
            guard let page = pages[n], let plain = decryptPage(page, first: n == 1, key: key) else {
                throw Unreadable(reason: "page \(n) did not decrypt")
            }
            out.append(plain)
            // a right key gives page size 4096 and payload fractions 64/32/32
            if n == 1, out[16] != 0x10 || out[17] != 0 || out[21] != 64 || out[22] != 32 || out[23] != 32 {
                throw Unreadable(reason: "the header did not validate, so the key is wrong")
            }
        }
        // the log is already folded in, so the copy opens as a rollback-journal database
        out[18] = 1
        out[19] = 1
        return out
    }

    /// page 1 begins with a 16-byte cipher salt where SQLite's header string goes
    private static func decryptPage(_ page: Data, first: Bool, key: SymmetricKey) -> Data? {
        let body = page.subdata(in: (first ? 16 : 0)..<pageSize - reserved)
        let iv = page.subdata(in: pageSize - reserved..<pageSize - reserved + 16)
        var plain = Data(count: body.count)
        var moved = 0
        let status = plain.withUnsafeMutableBytes { output in
            body.withUnsafeBytes { input in
                iv.withUnsafeBytes { vector in
                    key.withUnsafeBytes { keyBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), 0,
                            keyBytes.baseAddress, keyBytes.count, vector.baseAddress,
                            input.baseAddress, body.count, output.baseAddress, body.count, &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess, moved == body.count else { return nil }
        return (first ? Data("SQLite format 3\0".utf8) : Data()) + plain + Data(count: reserved)
    }

    private static func bigEndian(_ data: Data, _ offset: Int) -> Int {
        data[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) }
    }

    // MARK: - The tree

    private struct Node {
        var id: String
        var kind: String
        var entity: String
    }

    /// `nodes` is the tree: per space a `favorites` node, a `pinned_container` node and one
    /// `window` node per open window; a `tab` holds its `content_pane`s and a `group` is a folder
    private static func tree(_ db: OpaquePointer, namespace: String) -> (spaces: [ImportedSpace], favourites: [ImportedTab]) {
        let nodeColumns = SQLiteCopy.columns(db, "nodes")
        var children: [String: [Node]] = [:]
        var containers: [String: [Node]] = [:]
        SQLiteCopy.rows(
            db,
            """
            SELECT id, kind, \(SQLiteCopy.column("entity_id", nodeColumns)), parent_id, \(SQLiteCopy.column("space_id", nodeColumns))
            FROM nodes \(nodeColumns.contains("deleted_at") ? "WHERE deleted_at IS NULL" : "")
            ORDER BY \(nodeColumns.contains("order") ? "\"order\"" : "rowid");
            """
        ) { row in
            guard let id = anyText(row, 0), let kind = SQLiteCopy.text(row, 1) else { return }
            let node = Node(id: id, kind: kind, entity: anyText(row, 2) ?? "")
            if ["favorites", "pinned_container", "window"].contains(kind) {
                if let space = anyText(row, 4) { containers[space, default: []].append(node) }
            } else if let parent = anyText(row, 3) {
                children[parent, default: []].append(node)
            }
        }

        var folders: [String: String] = [:]
        SQLiteCopy.rows(db, "SELECT id, \(SQLiteCopy.column("title", SQLiteCopy.columns(db, "tab_groups"))) FROM tab_groups;") {
            row in
            if let id = anyText(row, 0) { folders[id] = SQLiteCopy.text(row, 1) }
        }
        var panes: [String: ImportedTab] = [:]
        SQLiteCopy.rows(
            db,
            """
            SELECT p.id, \(SQLiteCopy.column("p.custom_title", SQLiteCopy.columns(db, "content_panes"))), w.url,
                   \(SQLiteCopy.column("w.title", SQLiteCopy.columns(db, "web_contents")))
            FROM content_panes p JOIN web_contents w ON w.content_pane_id = p.id;
            """
        ) { row in
            guard let id = anyText(row, 0), panes[id] == nil, let url = SQLiteCopy.text(row, 2), !url.isEmpty else { return }
            panes[id] = ImportedTab(
                url: url, title: SQLiteCopy.text(row, 3), name: SQLiteCopy.text(row, 1).flatMap { $0.isEmpty ? nil : $0 })
        }

        func items(_ node: Node) -> [ImportedItem] {
            let kids = children[node.id] ?? []
            switch node.kind {
            case "tab":
                let tabs = kids.filter { $0.kind == "content_pane" }.compactMap { panes[$0.entity] }
                guard let first = tabs.first else { return [] }
                return [tabs.count == 1 ? .tab(first) : .split(tabs, .columns)]
            case "group":
                let name = folders[node.entity].flatMap { $0.isEmpty ? nil : $0 } ?? "Folder"
                return [.folder(name: name, expanded: true, kids.flatMap(items))]
            default:
                return []
            }
        }
        func contents(_ kind: String, of space: String) -> [ImportedItem] {
            (containers[space] ?? []).filter { $0.kind == kind }.flatMap { (children[$0.id] ?? []).flatMap(items) }
        }
        var spaces: [ImportedSpace] = []
        var favourites: [ImportedTab] = []
        var seen: Set<String> = []
        let spaceColumns = SQLiteCopy.columns(db, "spaces")
        SQLiteCopy.rows(
            db,
            """
            SELECT id, \(SQLiteCopy.column("title", spaceColumns)), \(SQLiteCopy.column("theme", spaceColumns)) FROM spaces
            \(spaceColumns.contains("deleted_at") ? "WHERE deleted_at IS NULL" : "")
            ORDER BY \(SQLiteCopy.column("creation_date", spaceColumns));
            """
        ) { row in
            guard let id = anyText(row, 0) else { return }
            spaces.append(
                ImportedSpace(
                    id: Importers.stableID("\(namespace)/space/\(id)"),
                    name: SQLiteCopy.text(row, 1).flatMap { $0.isEmpty ? nil : $0 } ?? "Space",
                    colors: themes[SQLiteCopy.text(row, 2) ?? ""] ?? [],
                    pinned: contents("pinned_container", of: id), today: contents("window", of: id)))
            favourites += flatten(contents("favorites", of: id)).filter { seen.insert($0.url).inserted }
        }
        return (spaces, favourites)
    }

    private static func flatten(_ items: [ImportedItem]) -> [ImportedTab] {
        items.flatMap { item -> [ImportedTab] in
            switch item {
            case .tab(let tab): [tab]
            case .split(let panes, _): panes
            case .folder(_, _, let inner): flatten(inner)
            }
        }
    }

    /// an id of any storage class as text; blobs as hex
    private static func anyText(_ row: OpaquePointer, _ column: Int32) -> String? {
        switch sqlite3_column_type(row, column) {
        case SQLITE_NULL: nil
        case SQLITE_BLOB: SQLiteCopy.blob(row, column).map { String(format: "%02x", $0) }.joined()
        default: SQLiteCopy.text(row, column)
        }
    }

    /// stand-in colour pairs for Dia's theme names; `neutral` is absent so it takes a preset
    private static let themes: [String: [RGBA]] = [
        "red": [0xF25C54, 0xF7A399], "orange": [0xF5913E, 0xF9C48F], "yellow": [0xF8D558, 0xFBE79E],
        "green": [0x5DBB63, 0xA8DCA0], "blue": [0x4A90E2, 0x9CC3F0], "pink": [0xF27BAA, 0xF8B8D0],
        "purple": [0x9B6FE0, 0xC9B0F0],
    ].mapValues { pair in
        pair.map { RGBA(Double($0 >> 16 & 0xFF) / 255, Double($0 >> 8 & 0xFF) / 255, Double($0 & 0xFF) / 255) }
    }

    // MARK: - Legacy JSON

    /// Dia 1.54 and earlier: one file for every profile, holding `window` and `favorites`
    /// containers whose `tabs[].contents[].variant` is `webContent{_0:{title,url}}` or `newTabPage`.
    private static func legacy(_ file: URL, folder: String, namespace: String) -> (spaces: [ImportedSpace], favourites: [ImportedTab]) {
        guard let data = try? Data(contentsOf: file),
            let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
            let scope = scope(json, folder: folder)
        else { return ([], []) }

        var containers: [(kind: String, tabs: [Any])] = []
        collect(scope, label: nil, into: &containers)
        var pinned: [ImportedItem] = []
        var today: [ImportedItem] = []
        var favourites: [ImportedTab] = []
        for container in containers {
            let items = container.tabs.compactMap { tab -> ImportedItem? in
                let panes = ((tab as? [String: Any])?["contents"] as? [Any] ?? []).compactMap(webContent)
                guard let first = panes.first else { return nil }
                return panes.count == 1 ? .tab(first) : .split(panes, .columns)
            }
            let kind = container.kind.lowercased()
            if kind.contains("favorite") {
                favourites += flatten(items)
            } else if kind.contains("pinned") {
                pinned += items
            } else {
                today += items
            }
        }
        var seen: Set<String> = []
        favourites = favourites.filter { seen.insert($0.url).inserted }
        guard !pinned.isEmpty || !today.isEmpty else { return ([], favourites) }
        let space = ImportedSpace(
            id: Importers.stableID("\(namespace)/space/legacy"), name: "Dia", pinned: pinned, today: today)
        return ([space], favourites)
    }

    /// the value under the first key or flat-list label naming `folder`, or the object that names it
    private static func scope(_ json: Any, folder: String) -> Any? {
        if let object = json as? [String: Any] {
            if let value = object[folder] { return value }
            if object.values.contains(where: { $0 as? String == folder }) { return object }
            return object.keys.sorted().lazy.compactMap { scope(object[$0]!, folder: folder) }.first
        }
        guard let list = json as? [Any] else { return nil }
        for (index, element) in list.enumerated() {
            if element as? String == folder, index + 1 < list.count { return list[index + 1] }
            if let found = scope(element, folder: folder) { return found }
        }
        return nil
    }

    /// every object with a `tabs` list, kinded by its `kind`/`type` or the label above it
    private static func collect(_ json: Any, label: String?, into out: inout [(kind: String, tabs: [Any])]) {
        if let object = json as? [String: Any] {
            if let tabs = object["tabs"] as? [Any] {
                let kind = object["kind"] ?? object["type"]
                out.append((kind as? String ?? (kind as? [String: Any])?.keys.first ?? label ?? "window", tabs))
                return
            }
            for name in object.keys.sorted() { collect(object[name]!, label: name, into: &out) }
        } else if let list = json as? [Any] {
            var label = label
            for element in list {
                if let name = element as? String { label = name } else { collect(element, label: label, into: &out) }
            }
        }
    }

    private static func webContent(_ content: Any) -> ImportedTab? {
        let object = content as? [String: Any]
        let variant = object?["variant"] as? [String: Any] ?? object
        let web = variant?["webContent"] as? [String: Any]
        guard let page = web?["_0"] as? [String: Any] ?? web, let url = page["url"] as? String, !url.isEmpty
        else { return nil }
        return ImportedTab(url: url, title: page["title"] as? String)
    }
}
