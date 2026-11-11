// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import ContentBlockerConverter
import Foundation

/// one WebKit content-blocking rule, in the JSON shape `WKContentRuleListStore` compiles
nonisolated struct ContentRule: Encodable {
    struct Trigger: Encodable {
        var urlFilter: String
        var urlFilterIsCaseSensitive: Bool?
        /// WebKit rejects the whole list when a trigger has both of these
        var ifDomain: [String]?
        var unlessDomain: [String]?
        var resourceType: [String]?
        var loadType: [String]?

        enum CodingKeys: String, CodingKey {
            case urlFilter = "url-filter"
            case urlFilterIsCaseSensitive = "url-filter-is-case-sensitive"
            case ifDomain = "if-domain"
            case unlessDomain = "unless-domain"
            case resourceType = "resource-type"
            case loadType = "load-type"
        }
    }

    struct Action: Encodable {
        var type: String
        var selector: String?
    }

    var trigger: Trigger
    var action: Action
}

/// EasyList-format lists into one WebKit rule list, through AdGuard's converter. a filter WebKit
/// can't express is skipped and counted. WebKit rejects a list over 150k rules, so the converter
/// trims its own output to leave room for `extraExceptions`
nonisolated enum FilterConverter {
    struct Result {
        var json = "[]"
        var ruleCount = 0
        /// filters WebKit can't express
        var droppedCount = 0
        /// blocking rules left out to stay under the ceiling
        var overCeilingCount = 0
    }

    private static let ruleCeiling = 150_000

    /// `extraExceptions` go after every converted rule, so they override all of them
    static func convert(_ sources: [String], extraExceptions: [ContentRule] = [], ceiling: Int = ruleCeiling) -> Result {
        var lines: [String] = []
        for var source in sources {
            source.makeContiguousUTF8()
            lines += source.split(whereSeparator: \.isNewline).filter { !$0.hasPrefix("[Adblock") }.map(String.init)
        }
        let converted = ContentBlockerConverter().convertArray(
            rules: lines, safariVersion: .autodetect(), advancedBlocking: false, maxJsonSizeBytes: nil,
            progress: nil, maxRules: max(0, ceiling - extraExceptions.count))
        if converted.discardedSafariRules > 0 {
            Diagnostics.record(
                area: "blocker", message: "over WebKit's rule ceiling: \(converted.discardedSafariRules) rules dropped")
        }
        var json = converted.safariRulesJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        if !extraExceptions.isEmpty, let data = try? encoder.encode(extraExceptions),
            let tail = String(data: data, encoding: .utf8), json.hasSuffix("]")
        {
            json = converted.safariRulesCount == 0 ? tail : String(json.dropLast()) + "," + String(tail.dropFirst())
        }
        return Result(
            json: json,
            ruleCount: converted.safariRulesCount + extraExceptions.count,
            droppedCount: converted.sourceRulesCount - converted.sourceSafariCompatibleRulesCount
                + converted.errorsCount,
            overCeilingCount: converted.discardedSafariRules)
    }

    /// the hosts a list blocks outright (`||host^`, no path, no `domain=`), for attributing
    /// a blocked request to the list that recognised it
    static func blockedHosts(in source: String) -> Set<String> {
        var hosts: Set<String> = []
        for rawLine in source.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("||") else { continue }
            let body = line.dropFirst(2)
            let end = body.firstIndex(where: { "^/$*|?".contains($0) }) ?? body.endIndex
            let host = String(body[body.startIndex..<end])
            let rest = body[end...].drop { $0 == "^" }
            guard rest.isEmpty || rest.first == "$" && !rest.contains("domain=") else { continue }
            guard host.contains("."), !host.contains(" "), let name = normalizedDomain(host)
            else { continue }
            hosts.insert(name)
        }
        return hosts
    }

    /// WebKit refuses to compile a list holding an upper-case or non-ASCII
    /// domain, so an IDN entry is punycoded. entities (`google.*`) and regex
    /// domains have no WebKit form and come back nil
    private static func normalizedDomain(_ domain: some StringProtocol) -> String? {
        let lower = domain.lowercased()
        let host = lower.allSatisfy(\.isASCII) ? lower : URL(string: "http://\(lower)")?.host
        guard let host, !host.isEmpty,
            host.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || ".-_".contains($0)) })
        else { return nil }
        return host
    }
}
