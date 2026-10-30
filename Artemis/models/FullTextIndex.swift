import Foundation
import SQLite3

/// One page's worth of indexed text, as a search result.
struct PageTextHit: Identifiable, Sendable {
    var url: URL
    var title: String
    var visited: Date
    /// the matching sentence or two, with an ellipsis where it was cut
    var snippet: String

    var id: String { url.absoluteString }
}

/// A local full-text index of the pages you've read.
///
/// Browser history answers "what was that page called". This answers "I read
/// something last week that said…", which is the question people actually have
/// and which no mainstream browser will answer, because doing it their way means
/// shipping your reading to a server. Doing it here means a SQLite FTS5 table in
/// Artemis' own container that never leaves the machine — the one shape of this
/// feature a privacy-first browser can offer and a cloud-first one can't.
///
/// Off by default. Indexing what you read is a real escalation over recording
/// where you went, so it's a decision the user makes rather than a default they
/// discover.
///
/// An actor because every operation touches SQLite and none of it belongs on the
/// main thread — extraction runs on page load, which is exactly when the main
/// thread is busiest.
actor FullTextIndex {
    /// AppStorage key for the opt-in
    static let enabledKey = "indexPageText"
    /// how many pages the index keeps before the oldest are dropped. 20k pages
    /// of text is a few hundred megabytes at the very worst and a year of
    /// ordinary browsing
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
        // WAL so a search never waits behind an insert, and a page of text
        // written while you're reading can't stall the UI
        exec("PRAGMA journal_mode = WAL;")
        exec("PRAGMA synchronous = NORMAL;")
        // `url` and `visited` are carried but not indexed — they're how a hit
        // gets turned back into something you can open, not something to match
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

    /// index (or re-index) one page. Re-visiting a page replaces its row rather
    /// than adding a second one, so the index is "pages you've read", not "times
    /// you've loaded something"
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

    /// keep the newest `pageLimit` pages. cheap to check, rare to act on
    private func pruneIfNeeded() {
        guard let db, count() > Self.pageLimit else { return }
        _ = db
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
        // bm25 ranks title matches above body matches; the weights are the
        // column order (url, title, body, visited)
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

    /// bytes on disk, for the settings pane — "it's all local" deserves a number
    func sizeOnDisk() -> Int {
        let files = [fileURL, fileURL.appendingPathExtension("wal")]
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

    /// drop everything indexed since `date` — the ranged half of Clear Browsing
    /// Data, so clearing the last hour of history clears the last hour of text
    func clear(since date: Date) {
        guard open() != nil else { return }
        exec("DELETE FROM pages WHERE CAST(visited AS REAL) >= \(date.timeIntervalSince1970);")
    }

    // MARK: - Helpers

    private func bind(_ statement: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(statement, index, value, -1, Self.transient)
    }

    /// Turn what the user typed into an FTS5 query.
    ///
    /// User input can't go in raw: FTS5 has its own syntax and a stray quote or
    /// `NEAR` is a syntax error, not a search. Each word becomes a quoted term
    /// (so punctuation is harmless), and the last one gets a prefix `*` so
    /// results appear while you're still typing it.
    nonisolated static func ftsQuery(for input: String) -> String? {
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
