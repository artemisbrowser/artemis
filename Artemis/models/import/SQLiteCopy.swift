// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import Foundation
import SQLite3

/// Reading another browser's databases and compressed session files.
nonisolated enum SQLiteCopy {
    /// Run `body` against a copy of a database: the live file is locked while
    /// its browser runs, and its write-ahead log holds the newest rows, so both
    /// come across before it is opened.
    static func withDatabase<T>(at link: URL, _ body: (OpaquePointer) -> T) -> T? {
        let files = FileManager.default
        // copyItem copies a symlink as a link, which would open the live file
        let url = link.resolvingSymlinksInPath()
        guard files.isReadableFile(atPath: url.path) else { return nil }
        let scratch = files.temporaryDirectory.appending(path: "import-\(UUID().uuidString)")
        guard (try? files.createDirectory(at: scratch, withIntermediateDirectories: true)) != nil
        else { return nil }
        defer { try? files.removeItem(at: scratch) }

        let copy = scratch.appending(path: url.lastPathComponent)
        guard (try? files.copyItem(at: url, to: copy)) != nil else { return nil }
        for suffix in ["-wal", "-shm"] {
            let side = URL(fileURLWithPath: url.path + suffix)
            guard files.fileExists(atPath: side.path) else { continue }
            try? files.copyItem(at: side, to: URL(fileURLWithPath: copy.path + suffix))
        }

        var handle: OpaquePointer?
        // read-write: a write-ahead database with no -shm beside it won't open read-only
        guard sqlite3_open_v2(copy.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
            let db = handle
        else {
            sqlite3_close(handle)
            return nil
        }
        defer { sqlite3_close(db) }
        return body(db)
    }

    /// One integer from the live file, opened immutable: no copy, no lock, and the write-ahead
    /// log ignored, unless that reads 0 beside a non-empty log. For survey counts only.
    static func count(_ url: URL, _ sql: String) -> Int {
        let live = immutableCount(url, sql)
        let log = (try? FileManager.default.attributesOfItem(atPath: url.path + "-wal")[.size] as? Int) ?? 0
        guard live == 0, log > 0 else { return live }
        return withDatabase(at: url) { scalar($0, sql) } ?? 0
    }

    private static func immutableCount(_ url: URL, _ sql: String) -> Int {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return 0 }
        parts.query = "immutable=1"
        guard let uri = parts.url?.absoluteString else { return 0 }
        var handle: OpaquePointer?
        defer { sqlite3_close(handle) }
        guard sqlite3_open_v2(uri, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK,
            let db = handle
        else { return 0 }
        return scalar(db, sql)
    }

    /// each row of `sql`; nothing when it doesn't prepare, as on a database that isn't one
    static func rows(_ db: OpaquePointer, _ sql: String, _ each: (OpaquePointer) -> Void) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW { each(statement) }
    }

    static func scalar(_ db: OpaquePointer, _ sql: String) -> Int {
        var out = 0
        rows(db, sql) { out = Int(sqlite3_column_int64($0, 0)) }
        return out
    }

    /// a table's column names, for schemas that drift between versions
    static func columns(_ db: OpaquePointer, _ table: String) -> Set<String> {
        var out: Set<String> = []
        rows(db, "PRAGMA table_info(\"\(table)\");") { if let name = text($0, 1) { out.insert(name) } }
        return out
    }

    /// `name` when the table has it, else NULL, so a column a version lacks reads as missing;
    /// `name` may be qualified (`t.col`)
    static func column(_ name: String, _ columns: Set<String>) -> String {
        let bare = name.split(separator: ".").last.map(String.init) ?? name
        return columns.contains(bare) ? name : "NULL"
    }

    static func text(_ statement: OpaquePointer?, _ column: Int32) -> String? {
        sqlite3_column_text(statement, column).map { String(cString: $0) }
    }

    static func blob(_ statement: OpaquePointer?, _ column: Int32) -> Data {
        guard let bytes = sqlite3_column_blob(statement, column) else { return Data() }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
    }

    /// Opening the file is the honest test. Full Disk Access refuses with EPERM
    /// and never prompts, where a check of permissions alone says yes.
    static func isReadable(_ file: URL) -> Bool {
        let fd = open(file.path, O_RDONLY)
        guard fd >= 0 else { return false }
        close(fd)
        return true
    }

    /// Mozilla's `mozLz40\0` header, the decoded size as a little-endian
    /// UInt32, then one LZ4 block. Nil for anything that isn't exactly that.
    static func mozLz4(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count >= 12, bytes.starts(with: Array("mozLz40\0".utf8)) else { return nil }
        let size = bytes[8..<12].reversed().reduce(0) { $0 << 8 | Int($1) }
        guard size <= 256 << 20 else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(size)
        var i = 12
        /// a 4-bit length of 15 continues in bytes until one isn't 255
        func length(_ nibble: UInt8) -> Int? {
            var n = Int(nibble)
            guard n == 15 else { return n }
            while i < bytes.count {
                let more = bytes[i]
                i += 1
                n += Int(more)
                if more != 255 { return n }
            }
            return nil
        }
        while i < bytes.count {
            let token = bytes[i]
            i += 1
            guard let literals = length(token >> 4), i + literals <= bytes.count, out.count + literals <= size
            else { return nil }
            out += bytes[i..<i + literals]
            i += literals
            // the last sequence is literals alone
            if i == bytes.count { break }
            guard i + 2 <= bytes.count else { return nil }
            let offset = Int(bytes[i]) | Int(bytes[i + 1]) << 8
            i += 2
            guard offset > 0, offset <= out.count, let match = length(token & 15).map({ $0 + 4 }),
                out.count + match <= size
            else { return nil }
            // byte by byte: a match may overlap the bytes it is writing
            for _ in 0..<match { out.append(out[out.count - offset]) }
        }
        return out.count == size ? Data(out) : nil
    }
}
