// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import Foundation
import SQLite3

/// A Chromium profile's history, cookies and saved logins. Arc, Dia and every
/// Chromium browser keep them in the same tables.
nonisolated enum ChromiumData {
    /// the live jar: the newer of `Cookies` and `Network/Cookies`
    static func cookieFile(in profile: URL) -> URL? {
        [profile.appending(path: "Cookies"), profile.appending(path: "Network/Cookies")]
            .compactMap { file in modified(file).map { (file, $0) } }
            .max { $0.1 < $1.1 }?.0
    }

    static func loginFiles(in profile: URL) -> [URL] {
        ["Login Data", "Login Data For Account"].map { profile.appending(path: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func modified(_ file: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
    }

    // MARK: - Counts, without the key

    static func historyCount(_ file: URL) -> Int {
        SQLiteCopy.count(file, "SELECT count(*) FROM urls WHERE hidden = 0 AND last_visit_time > 0;")
    }

    static func cookieCount(_ file: URL) -> Int {
        SQLiteCopy.count(file, "SELECT count(*) FROM cookies;")
    }

    static func loginCount(_ files: [URL]) -> Int {
        files.reduce(0) { $0 + SQLiteCopy.count($1, "SELECT count(*) FROM logins WHERE blacklisted_by_user = 0;") }
    }

    // MARK: - History

    /// a profile's `History`, newest first
    static func history(_ file: URL) -> [ImportedVisit] {
        SQLiteCopy.withDatabase(at: file) { db in
            var out: [ImportedVisit] = []
            SQLiteCopy.rows(
                db,
                """
                SELECT url, title, last_visit_time, visit_count, typed_count FROM urls
                WHERE hidden = 0 AND last_visit_time > 0 ORDER BY last_visit_time DESC
                LIMIT \(Importers.historyLimit);
                """
            ) { row in
                guard let url = SQLiteCopy.text(row, 0) else { return }
                out.append(
                    ImportedVisit(
                        url: url, title: SQLiteCopy.text(row, 1) ?? "",
                        lastVisited: date(sqlite3_column_int64(row, 2)),
                        visitCount: Int(sqlite3_column_int(row, 3)), typedCount: Int(sqlite3_column_int(row, 4))))
            }
            return out
        } ?? []
    }

    // MARK: - Cookies

    /// One jar's cookies, shaped for a `WKHTTPCookieStore`. Without `key` only
    /// plaintext values come back; a value that won't unseal is dropped.
    static func cookies(_ file: URL, key: Data?, now: Date = Date()) -> ImportedCookies {
        SQLiteCopy.withDatabase(at: file) { db in
            var read = ImportedCookies()
            var seen: Set<String> = []
            // unpartitioned rows first, then https: a site's cookie can exist several
            // times over, split by partition, scheme and port, and Artemis stores one
            let columns = SQLiteCopy.columns(db, "cookies")
            let sql = """
                SELECT host_key, name, encrypted_value, value, path, expires_utc, is_secure,
                       is_httponly, has_expires, \(SQLiteCopy.column("samesite", columns))
                FROM cookies
                ORDER BY (\(SQLiteCopy.column("top_frame_site_key", columns)) = '') DESC,
                         \(SQLiteCopy.column("source_scheme", columns)) DESC;
                """
            SQLiteCopy.rows(db, sql) { row in
                read.rows += 1
                guard let host = SQLiteCopy.text(row, 0), !host.isEmpty, let name = SQLiteCopy.text(row, 1),
                    seen.insert("\(host)\u{1}\(name)\u{1}\(SQLiteCopy.text(row, 4) ?? "")").inserted
                else { return }
                let sealed = SQLiteCopy.blob(row, 2)
                let value: String
                if sealed.isEmpty {
                    value = SQLiteCopy.text(row, 3) ?? ""
                } else if let key, let unsealed = try? BrowserKeychain.decrypt(sealed, key: key, host: host) {
                    value = unsealed
                    read.unsealed += 1
                } else {
                    return
                }

                var properties: [HTTPCookiePropertyKey: Any] = [
                    .name: name, .value: value, .domain: host, .path: SQLiteCopy.text(row, 4) ?? "/",
                ]
                if sqlite3_column_int(row, 6) != 0 { properties[.secure] = "TRUE" }
                if sqlite3_column_int(row, 7) != 0 { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
                if sqlite3_column_int(row, 8) != 0 {
                    let expiry = date(sqlite3_column_int64(row, 5))
                    guard expiry > now else { return }
                    properties[.expires] = expiry
                }
                switch sqlite3_column_int(row, 9) {
                case 1: properties[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteLax.rawValue
                case 2: properties[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteStrict.rawValue
                default: break
                }
                if let cookie = HTTPCookie(properties: properties) { read.cookies.append(cookie) }
            }
            return read
        } ?? ImportedCookies()
    }

    // MARK: - Saved passwords

    /// every file's logins, deduped on realm, user and password
    static func logins(_ files: [URL], key: Data) -> [ImportedLogin] {
        var seen: Set<String> = []
        var out: [ImportedLogin] = []
        for file in files {
            SQLiteCopy.withDatabase(at: file) { db in
                SQLiteCopy.rows(
                    db,
                    """
                    SELECT origin_url, username_value, password_value, signon_realm FROM logins
                    WHERE blacklisted_by_user = 0;
                    """
                ) { row in
                    let sealed = SQLiteCopy.blob(row, 2)
                    guard !sealed.isEmpty, let password = try? BrowserKeychain.decrypt(sealed, key: key),
                        !password.isEmpty
                    else { return }
                    let origin = SQLiteCopy.text(row, 0) ?? ""
                    let realm = SQLiteCopy.text(row, 3) ?? ""
                    let username = SQLiteCopy.text(row, 1) ?? ""
                    guard seen.insert("\(realm)\u{1}\(username)\u{1}\(password)").inserted else { return }
                    let address = origin.isEmpty ? realm : origin
                    out.append(
                        ImportedLogin(
                            title: URL(string: address)?.host() ?? address, url: address, username: username,
                            password: password))
                }
            }
        }
        return out
    }

    /// Chromium counts microseconds from 1601-01-01
    static func date(_ raw: Int64) -> Date {
        Date(timeIntervalSince1970: Double(raw) / 1_000_000 - 11_644_473_600)
    }
}
