// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import Foundation
import os

/// Errors worth reporting, kept on this Mac: a ring of recent events in memory and
/// an append-only JSONL log beside the other stores. Messages are redacted before
/// either holds them, and a private window leaves only the bare fact.
nonisolated enum Diagnostics {
    struct Event: Codable, Sendable {
        enum Level: String, Codable, Sendable { case error, warning }
        let t: Date
        let level: Level
        let area: String
        let message: String
        let sig: String
    }

    static let capacity = 300
    /// past this the log rotates once, so at most twice this stays on disk
    private static let fileCap = 512 * 1024
    private static let file = AppStorageLocation.file("diagnostics.jsonl")
    private static let older = AppStorageLocation.file("diagnostics.1.jsonl")
    private static let ring = OSAllocatedUnfairLock(initialState: [Event]())
    private static let disk = DispatchQueue(label: "com.artemis.diagnostics", qos: .utility)

    /// a self-test run records into the ring alone
    static func record(
        area: String, message: String, level: Event.Level = .error, inPrivate: Bool = false
    ) {
        let entry = event(area: area, message: message, level: level, inPrivate: inPrivate)
        ring.withLock { append(entry, to: &$0) }
        if !SelfTest.isRequested { disk.async { write(entry) } }
    }

    static func event(
        area: String, message: String, level: Event.Level = .error, inPrivate: Bool = false
    ) -> Event {
        let text = inPrivate ? "in a private window" : String(redact(message).prefix(500))
        return Event(
            t: .now, level: level, area: area, message: text,
            sig: signature(area: area, message: text))
    }

    static func append(_ event: Event, to ring: inout [Event], capacity: Int = capacity) {
        ring.append(event)
        if ring.count > capacity { ring.removeFirst(ring.count - capacity) }
    }

    /// this launch's events, oldest first
    static var recent: [Event] { ring.withLock { $0 } }

    /// the log on disk after `date`, oldest first. Waits on the log's queue, so
    /// never from the main thread
    static func events(after date: Date) -> [Event] {
        disk.sync {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return [older, file].flatMap { url in
                ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n")
                    .compactMap { try? decoder.decode(Event.self, from: Data($0.utf8)) }
            }
            .filter { $0.t > date }
        }
    }

    private static func write(_ event: Event) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard var line = try? encoder.encode(event) else { return }
        line.append(0x0A)
        let fm = FileManager.default
        let size = (try? fm.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        if size + line.count > fileCap {
            try? fm.removeItem(at: older)
            try? fm.moveItem(at: file, to: older)
        }
        guard let handle = try? FileHandle(forWritingTo: file) else {
            try? line.write(to: file)
            return
        }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line)
    }

    /// a match stops at a backslash so a redacted JSON string keeps its escapes
    private static let redactions: [(NSRegularExpression, String)] = [
        (#"\b[a-z][a-z0-9+.-]*://[^\s"'<>\\]*"#, "<url>"),
        (#"\b(?:about|blob|data|javascript|mailto):[^\s"'<>\\]+"#, "<url>"),
        (#"[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}"#, "<email>"),
    ].map { (try! NSRegularExpression(pattern: $0, options: .caseInsensitive), $1) }

    static func redact(_ text: String) -> String {
        var out = text.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        for (pattern, token) in redactions {
            out = pattern.stringByReplacingMatches(
                in: out, range: NSRange(out.startIndex..., in: out), withTemplate: token)
        }
        return out
    }

    /// counts and ids vary between occurrences of one error, so digits don't count
    static func signature(area: String, message: String) -> String {
        hash(area + ":" + message.filter { !$0.isNumber })
    }

    /// FNV-1a: the same text hashes the same in every process
    static func hash(_ text: String) -> String {
        var value: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 { value = (value ^ UInt64(byte)) &* 0x100_0000_01b3 }
        return String(format: "%016llx", value)
    }
}
