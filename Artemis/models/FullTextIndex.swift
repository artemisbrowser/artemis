// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import Foundation
import SQLite3

/// one indexed page, as a search result
struct PageTextHit: Identifiable, Sendable {
    var url: URL
    var title: String
    var visited: Date
    /// the matching sentence or two, with an ellipsis where it was cut
    var snippet: String

    var id: String { url.absoluteString }
}

/// an on-device SQLite FTS5 index of the text of pages read, one row per url.
/// opt-in, off by default; the database opens lazily on first use
actor FullTextIndex {
    static let enabledKey = "indexPageText"
    /// the oldest pages beyond this are dropped
    private static let pageLimit = 20_000

    private var db: OpaquePointer?
    private var isOpen = false

    private static let transient = unsafeBitCast(
        -1, to: (@convention(c) (UnsafeMutableRawPointer?) -> Void).self)

    private let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    // MARK: - Lifecycle

    private func open() -> OpaquePointer? {
        if isOpen { return db }
        isOpen = true
        var handle: OpaquePointer?
        guard sqlite3_open_v2(
            fileURL.path, &handle,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK
        else {
            debugLog("fulltext: could not open the index")
            db = nil
            return nil
        }
        db = handle
        exec("PRAGMA journal_mode = WAL;")
        exec("PRAGMA synchronous = NORMAL;")
        // `visited` is seconds since 1970, stored as text
        exec(
            """
            CREATE VIRTUAL TABLE IF NOT EXISTS pages USING fts5(
                url UNINDEXED, title, body, visited UNINDEXED,
                tokenize = 'unicode61 remove_diacritics 2'
            );
            """)
        return db
    }

    private func exec(_ sql: String) {
        guard let db else { return }
        var error: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &error) != SQLITE_OK, let error {
            debugLog("fulltext: \(String(cString: error))")
            sqlite3_free(error)
        }
    }

    // MARK: - Writing

    /// replaces any earlier row for the same url
    func record(url: URL, title: String, body: String) {
        guard let db = open() else { return }
        let trimmed = String(body.prefix(200_000))
        guard !trimmed.isEmpty else { return }

        var delete: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM pages WHERE url = ?;", -1, &delete, nil) == SQLITE_OK {
            bind(delete, 1, url.absoluteString)
            sqlite3_step(delete)
        }
        sqlite3_finalize(delete)

        var insert: OpaquePointer?
        guard sqlite3_prepare_v2(
            db, "INSERT INTO pages(url, title, body, visited) VALUES(?, ?, ?, ?);", -1, &insert,
            nil) == SQLITE_OK
        else { return }
        bind(insert, 1, url.absoluteString)
        bind(insert, 2, title)
        bind(insert, 3, trimmed)
        bind(insert, 4, String(Date().timeIntervalSince1970))
        sqlite3_step(insert)
        sqlite3_finalize(insert)

        pruneIfNeeded()
    }

    private func pruneIfNeeded() {
        guard count() > Self.pageLimit else { return }
        exec(
            """
            DELETE FROM pages WHERE rowid NOT IN (
                SELECT rowid FROM pages ORDER BY CAST(visited AS REAL) DESC LIMIT \(Self.pageLimit)
            );
            """)
    }

    // MARK: - Reading

    func search(_ query: String, limit: Int = 5) -> [PageTextHit] {
        guard let db = open(), let match = Self.ftsQuery(for: query) else { return [] }
        var statement: OpaquePointer?
        // bm25 weights follow column order (url, title, body, visited)
        let sql = """
            SELECT url, title, visited, snippet(pages, 2, '', '', '…', 14)
            FROM pages WHERE pages MATCH ?
            ORDER BY bm25(pages, 0.0, 8.0, 1.0, 0.0)
            LIMIT ?;
            """
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, match)
        sqlite3_bind_int(statement, 2, Int32(limit))

        var hits: [PageTextHit] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let raw = sqlite3_column_text(statement, 0),
                let url = URL(string: String(cString: raw))
            else { continue }
            let title = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
            let visited = sqlite3_column_text(statement, 2).map { String(cString: $0) } ?? "0"
            let snippet = sqlite3_column_text(statement, 3).map { String(cString: $0) } ?? ""
            hits.append(
                PageTextHit(
                    url: url, title: title.isEmpty ? (url.host() ?? url.absoluteString) : title,
                    visited: Date(timeIntervalSince1970: Double(visited) ?? 0),
                    snippet: snippet.replacingOccurrences(of: "\n", with: " ")))
        }
        return hits
    }

    func count() -> Int {
        guard let db = open() else { return 0 }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT count(*) FROM pages;", -1, &statement, nil)
            == SQLITE_OK
        else { return 0 }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int(statement, 0)) : 0
    }

    /// bytes on disk, database plus write-ahead log
    func sizeOnDisk() -> Int {
        let files = [fileURL, URL(fileURLWithPath: fileURL.path + "-wal")]
        return files.reduce(0) { total, url in
            total + ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    // MARK: - Clearing

    /// let go of the database, before its profile's files are deleted
    func close() {
        if let db { sqlite3_close_v2(db) }
        db = nil
        isOpen = false
    }

    func clear() {
        guard open() != nil else { return }
        exec("DELETE FROM pages;")
        exec("VACUUM;")
    }

    /// drops everything indexed since `date`
    func clear(since date: Date) {
        guard open() != nil else { return }
        exec("DELETE FROM pages WHERE CAST(visited AS REAL) >= \(date.timeIntervalSince1970);")
    }

    // MARK: - Helpers

    private func bind(_ statement: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(statement, index, value, -1, Self.transient)
    }

    /// each word of two or more alphanumerics quoted, the last as a prefix; raw input
    /// would be FTS5 syntax, where a stray quote or `NEAR` is an error
    private nonisolated static func ftsQuery(for input: String) -> String? {
        let words = input
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 1 }
        guard !words.isEmpty else { return nil }
        return words.enumerated()
            .map { index, word in
                let quoted = "\"\(word)\""
                return index == words.count - 1 ? quoted + " *" : quoted
            }
            .joined(separator: " ")
    }
}
