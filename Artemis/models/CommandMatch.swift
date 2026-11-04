// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import Foundation

/// how well a query matched one candidate, and where it landed
nonisolated struct CommandMatch {
    let score: Int
    /// byte offsets into the candidate; empty when the candidate holds
    /// non-ascii, where a byte offset is not a character offset
    let ranges: [Range<Int>]
}

/// one scoring scale for every result kind, so tabs, history, actions and spaces
/// rank against each other in a single list
nonisolated enum CommandMatcher {
    /// quality floors, before length and position penalties
    enum Tier {
        static let exact = 1000
        static let prefix = 880
        static let wordPrefix = 760
        static let acronym = 660
        static let substring = 560
        static let subsequence = 380
    }

    /// bytes a candidate is matched against; lowercasing is ascii-only, which is
    /// what the scorer compares
    static func needle(_ query: String) -> [UInt8] {
        Array(query.lowercased().utf8)
    }

    /// bits for the a–z and 0–9 in a string. a query needing a byte the
    /// candidate lacks can't match, and that test is one AND
    static func mask<S: Sequence<UInt8>>(_ bytes: S) -> UInt64 {
        var mask: UInt64 = 0
        for byte in bytes {
            if byte >= 97, byte <= 122 {
                mask |= 1 << UInt64(byte - 97)
            } else if byte >= 48, byte <= 57 {
                mask |= 1 << UInt64(byte - 48 + 26)
            }
        }
        return mask
    }

    /// `candidate` must already be lowercased
    static func match(_ query: [UInt8], _ candidate: String) -> CommandMatch? {
        guard !query.isEmpty else { return nil }
        var candidate = candidate
        return candidate.withUTF8 { text in query.withUnsafeBufferPointer { score($0, text) } }
    }

    /// byte-wise substring test; `String.contains` goes through ICU, never use it here
    static func contains(_ needle: [UInt8], _ candidate: String) -> Bool {
        guard !needle.isEmpty else { return true }
        var candidate = candidate
        return candidate.withUTF8 { text in
            needle.withUnsafeBufferPointer { offset(of: $0, in: text, from: 0) != nil }
        }
    }

    /// where `needle` next occurs in `text`, at or after `start`
    private static func offset(
        of needle: UnsafeBufferPointer<UInt8>, in text: UnsafeBufferPointer<UInt8>, from start: Int
    ) -> Int? {
        let n = text.count, m = needle.count
        guard n - start >= m, let base = text.baseAddress else { return nil }
        let raw = UnsafeRawPointer(base)
        let ones: UInt64 = 0x0101_0101_0101_0101
        let first = ones &* UInt64(needle[0]), last = ones &* UInt64(needle[m - 1])
        var i = start
        // eight starts per load, lane k at byte k (little-endian): a lane is zero where the
        // needle's first and last bytes both line up, and each flagged lane is confirmed in full
        while i + m + 7 <= n {
            let lanes = (raw.loadUnaligned(fromByteOffset: i, as: UInt64.self) ^ first)
                | (raw.loadUnaligned(fromByteOffset: i + m - 1, as: UInt64.self) ^ last)
            var zeros = (lanes &- ones) & ~lanes & (ones << 7)
            while zeros != 0 {
                let at = i + zeros.trailingZeroBitCount / 8
                if memcmp(base + at, needle.baseAddress, m) == 0 { return at }
                zeros &= zeros &- 1
            }
            i += 8
        }
        while i <= n - m {
            if memcmp(base + i, needle.baseAddress, m) == 0 { return i }
            i += 1
        }
        return nil
    }

    /// bytes that end a word, so the next byte starts one
    private static func isSeparator(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x20, 0x2D, 0x2E, 0x2F, 0x5F, 0x3A, 0x3F, 0x26, 0x3D, 0x2C, 0x23, 0x40, 0x7C, 0x2B:
            true
        default: false
        }
    }

    private static func score(
        _ query: UnsafeBufferPointer<UInt8>, _ text: UnsafeBufferPointer<UInt8>
    ) -> CommandMatch? {
        let n = text.count, m = query.count
        guard m <= n else { return nil }
        let lengthPenalty = min(40, n / 4)

        // contiguous run: the best hit is the earliest one, and one starting a
        // word beats one buried mid-word
        var hit = -1
        var hitAtBoundary = false
        var from = 0
        while let i = offset(of: query, in: text, from: from) {
            let boundary = i == 0 || isSeparator(text[i - 1])
            if hit < 0 || (boundary && !hitAtBoundary) {
                hit = i
                hitAtBoundary = boundary
            }
            if boundary { break }
            from = i + 1
        }
        // fuzzy tiers apply to name-length candidates only, never a long title+url key
        guard hit >= 0 || n <= 96 else { return nil }

        let ascii = text.reduce(0, |) < 0x80

        if hit >= 0 {
            let ranges = ascii ? [hit..<(hit + m)] : []
            if hit == 0 {
                let tier = n == m ? Tier.exact : Tier.prefix - lengthPenalty
                return CommandMatch(score: tier, ranges: ranges)
            }
            let base = hitAtBoundary ? Tier.wordPrefix : Tier.substring
            return CommandMatch(score: base - min(60, hit) - lengthPenalty, ranges: ranges)
        }

        // initials: "so" finds "Stack Overflow", "pl" finds "Pricing – Linear"
        if let acronym = acronymMatch(query, text, ascii: ascii) {
            return CommandMatch(score: Tier.acronym - lengthPenalty, ranges: acronym)
        }

        // in-order scatter, for queries of three bytes or more
        guard m >= 3 else { return nil }
        var ranges: [Range<Int>] = []
        var qi = 0, last = -1, gaps = 0
        for index in 0..<n where qi < m && text[index] == query[qi] {
            gaps += last >= 0 ? (index - last - 1) : min(index, 24)
            last = index
            if ascii { append(index, to: &ranges) }
            qi += 1
        }
        guard qi == m else { return nil }
        return CommandMatch(
            score: Tier.subsequence - min(220, gaps * 3) - lengthPenalty,
            ranges: ascii ? ranges : [])
    }

    private static func acronymMatch(
        _ query: UnsafeBufferPointer<UInt8>, _ text: UnsafeBufferPointer<UInt8>, ascii: Bool
    ) -> [Range<Int>]? {
        var ranges: [Range<Int>] = []
        var qi = 0
        var atBoundary = true
        for index in 0..<text.count where qi < query.count {
            let byte = text[index]
            if isSeparator(byte) {
                atBoundary = true
                continue
            }
            if atBoundary {
                // punctuation and non-ascii bytes (`(`, `–`, `·`) start no word: the next letter does
                guard (byte >= 97 && byte <= 122) || (byte >= 48 && byte <= 57) else { continue }
                guard byte == query[qi] else { return nil }
                if ascii { append(index, to: &ranges) }
                qi += 1
            }
            atBoundary = false
        }
        guard qi == query.count else { return nil }
        return ranges
    }

    private static func append(_ index: Int, to ranges: inout [Range<Int>]) {
        if let last = ranges.last, last.upperBound == index {
            ranges[ranges.count - 1] = last.lowerBound..<(index + 1)
        } else {
            ranges.append(index..<(index + 1))
        }
    }
}
