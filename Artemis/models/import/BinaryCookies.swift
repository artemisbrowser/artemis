// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import Foundation

/// WebKit's cookie jars: `.binarycookies` files and session-cookie plists.
nonisolated enum BinaryCookies {
    /// A `.binarycookies` jar read byte by byte. The page table is big-endian,
    /// records little-endian, dates seconds since 2001. Expired and nameless
    /// records are dropped; an unpartitioned record wins a (domain, name, path) clash.
    static func read(_ file: URL, now: Date = Date()) -> [HTTPCookie] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        let bytes = [UInt8](data)
        var unpartitioned: [HTTPCookie] = []
        var partitioned: [HTTPCookie] = []
        for record in records(bytes) {
            let at = record.lowerBound
            guard let flags = word(bytes, at + 8) else { continue }
            let name = string(bytes, record, 20)
            let domain = string(bytes, record, 16)
            let path = string(bytes, record, 24)
            let expiry = Date(timeIntervalSinceReferenceDate: seconds(bytes, at + 40))
            guard !name.isEmpty, !domain.isEmpty, expiry > now else { continue }

            // a leading dot makes a domain cookie; a host-only one (0x20) is stored without it
            var properties: [HTTPCookiePropertyKey: Any] = [
                .name: name, .value: string(bytes, record, 28), .domain: domain, .path: path.isEmpty ? "/" : path,
                .expires: expiry,
            ]
            if flags & 0x1 != 0 { properties[.secure] = "TRUE" }
            if flags & 0x4 != 0 { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
            switch flags & 0x18 {
            case 0x08: properties[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteLax.rawValue
            case 0x18: properties[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteStrict.rawValue
            default: break
            }
            guard let cookie = HTTPCookie(properties: properties) else { continue }
            if flags >> 8 == 0x42 { unpartitioned.append(cookie) } else { partitioned.append(cookie) }
        }
        var seen: Set<String> = []
        return (unpartitioned + partitioned).filter { seen.insert("\($0.domain)\u{1}\($0.name)\u{1}\($0.path)").inserted }
    }

    /// a plist of `HTTPCookie.properties` dictionaries; unexpired ones come back
    static func readPlist(_ file: URL, now: Date = Date()) -> [HTTPCookie] {
        guard let data = try? Data(contentsOf: file),
            let list = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [[String: Any]]
        else { return [] }
        return list.compactMap { entry in
            let properties = Dictionary(entry.map { (HTTPCookiePropertyKey($0.key), $0.value) }) { first, _ in first }
            guard let cookie = HTTPCookie(properties: properties), !cookie.name.isEmpty, !cookie.domain.isEmpty,
                cookie.expiresDate.map({ $0 > now }) ?? true
            else { return nil }
            return cookie
        }
    }

    /// records in a jar or a session-cookie plist, expired or not
    static func count(_ file: URL) -> Int {
        guard let data = try? Data(contentsOf: file, options: .alwaysMapped) else { return 0 }
        if data.starts(with: Array("cook".utf8)) { return records([UInt8](data)).count }
        return ((try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [Any])?.count ?? 0
    }

    /// Each record's byte range in file order. A page is `00 00 01 00`, a cookie
    /// count, then offsets from the page start; a truncated page ends the walk.
    private static func records(_ bytes: [UInt8]) -> [Range<Int>] {
        guard bytes.starts(with: Array("cook".utf8)), let pages = word(bytes, 4, bigEndian: true) else { return [] }
        var out: [Range<Int>] = []
        var page = 8 + pages * 4
        for index in 0..<pages {
            guard let size = word(bytes, 8 + index * 4, bigEndian: true), page + size <= bytes.count,
                let count = word(bytes, page + 4), 8 + count * 4 <= size
            else { break }
            for slot in 0..<count {
                // a record is at least its 56-byte header: offsets, then expiry and creation
                guard let offset = word(bytes, page + 8 + slot * 4), let length = word(bytes, page + offset),
                    length >= 56, offset + length <= size
                else { continue }
                out.append(page + offset..<page + offset + length)
            }
            page += size
        }
        return out
    }

    private static func word(_ bytes: [UInt8], _ at: Int, bigEndian: Bool = false) -> Int? {
        guard at >= 0, at + 4 <= bytes.count else { return nil }
        let word = bytes[at..<at + 4]
        return (bigEndian ? Array(word) : word.reversed()).reduce(0) { $0 << 8 | Int($1) }
    }

    private static func seconds(_ bytes: [UInt8], _ at: Int) -> Double {
        Double(bitPattern: bytes[at..<at + 8].reversed().reduce(0) { $0 << 8 | UInt64($1) })
    }

    /// the NUL-terminated string whose record-relative offset sits at `field`
    private static func string(_ bytes: [UInt8], _ record: Range<Int>, _ field: Int) -> String {
        guard let offset = word(bytes, record.lowerBound + field), offset > 0, offset < record.count else { return "" }
        let start = record.lowerBound + offset
        let end = bytes[start..<record.upperBound].firstIndex(of: 0) ?? record.upperBound
        return String(decoding: bytes[start..<end], as: UTF8.self)
    }
}
