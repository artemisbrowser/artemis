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

/// converts Adblock Plus filter syntax (EasyList, EasyPrivacy, …) into WebKit content-blocking
/// rules. one malformed rule fails a whole compiled list, so a filter without a clean WebKit
/// mapping is dropped and counted, never approximated
nonisolated enum AdblockConverter {
    /// rules per compiled list, well under WebKit's hard ceiling of 150k
    private static let rulesPerChunk = 30_000

    struct Result {
        /// each element is one list's worth of JSON, ready to compile
        var chunks: [String] = []
        var ruleCount = 0
        var droppedCount = 0
    }

    /// ABP resource types → WebKit `resource-type` values
    private static let typeMap: [String: String] = [
        "script": "script",
        "image": "image",
        "stylesheet": "style-sheet",
        "css": "style-sheet",
        "font": "font",
        "media": "media",
        "popup": "popup",
        "subdocument": "document",
        "frame": "document",
        "document": "document",
        "xmlhttprequest": "raw",
        "xhr": "raw",
        "websocket": "raw",
        "object": "raw",
        "object-subrequest": "raw",
        "ping": "raw",
        "beacon": "raw",
        "other": "raw",
        "image-set": "image",
    ]

    private static let allResourceTypes: Set<String> = [
        "script", "image", "style-sheet", "font", "media", "raw", "document", "svg-document",
    ]

    /// options with no WebKit equivalent; a rule carrying one is dropped, never
    /// reduced to a plain block
    private static let unsupportedOptions: Set<String> = [
        "csp", "redirect", "redirect-rule", "rewrite", "removeparam", "replace", "badfilter",
        "generichide", "elemhide", "specifichide", "ehide", "ghide", "inline-script",
        "inline-font", "empty", "mp4", "webrtc", "popunder", "cname", "header", "urltransform",
        "method", "to", "denyallow", "permissions", "uritransform", "strict1p",
        "strict3p", "ipaddress",
    ]

    /// `!#if` tokens that hold for uBlock running on Safari; every other token is false
    private static let platformTokens: Set<String> = ["env_safari", "cap_user_stylesheet"]

    /// convert whole filter lists into compilable rule chunks, with `extraExceptions`
    /// appended after everything else
    static func convert(_ sources: [String], extraExceptions: [ContentRule] = []) -> Result {
        var blocks: [ContentRule] = []
        var cosmetics = Cosmetics()
        var exceptions: [ContentRule] = []
        var dropped = 0
        var seen = Set<String>()

        let lists = sources.map(preprocessed)
        let cancelled = badfiltered(lists.flatMap { $0 })
        for lines in lists {
            for line in lines {
                guard seen.insert(line).inserted, !cancelled.contains(line) else { continue }

                if isCosmetic(line) {
                    if !addCosmetic(line, to: &cosmetics) { dropped += 1 }
                } else if addCosmeticSwitch(line, to: &cosmetics) {
                    continue
                } else if let (rule, isException) = networkRule(line) {
                    if isException { exceptions.append(rule) } else { blocks.append(rule) }
                } else {
                    dropped += 1
                }
            }
        }

        let (generic, specific) = cosmetics.rules(dropped: &dropped)

        // WebKit applies rules top-down within one compiled list, so every chunk
        // ends with the whole `ignore-previous-rules` tail that overrides it
        let tail = exceptions + extraExceptions
        let groups = [
            (blocks, tail),
            (generic, tail + ignoring(cosmetics.noGeneric.union(cosmetics.noCosmetic))),
            (specific, tail + ignoring(cosmetics.noCosmetic)),
        ]
        var result = Result(
            ruleCount: blocks.count + generic.count + specific.count + tail.count,
            droppedCount: dropped)
        let encoder = JSONEncoder()
        for (rules, groupTail) in groups {
            for start in stride(from: 0, to: rules.count, by: rulesPerChunk) {
                let slice = rules[start..<min(start + rulesPerChunk, rules.count)]
                guard let data = try? encoder.encode(Array(slice) + groupTail),
                    let json = String(data: data, encoding: .utf8)
                else { continue }
                result.chunks.append(json)
            }
        }
        return result
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

    // MARK: - Preprocessing

    /// the list's filter lines, with uBlock's `!#if` blocks resolved and
    /// comments and headers gone
    private static func preprocessed(_ text: String) -> [String] {
        var conditions: [Bool] = []
        var lines: [String] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("!#if ") {
                conditions.append(evaluate(line.dropFirst(5)))
            } else if line.hasPrefix("!#else"), !conditions.isEmpty {
                conditions[conditions.count - 1].toggle()
            } else if line.hasPrefix("!#endif") {
                _ = conditions.popLast()
            } else if !line.isEmpty, !line.hasPrefix("!"), !line.hasPrefix("["),
                !conditions.contains(false)
            {
                lines.append(line)
            }
        }
        return lines
    }

    /// a `!#if` expression: tokens joined by `!`, `&&`, `||` and parentheses
    private static func evaluate(_ expression: Substring) -> Bool {
        var tokens: [Character] = []
        var word = ""
        func flush() {
            guard !word.isEmpty else { return }
            tokens.append(platformTokens.contains(word) ? "t" : "f")
            word = ""
        }
        for character in expression {
            if character.isLetter || character.isNumber || character == "_" {
                word.append(character)
                continue
            }
            flush()
            if "!()".contains(character) || "&|".contains(character) && tokens.last != character {
                tokens.append(character)
            }
        }
        flush()

        var index = 0
        func next() -> Character? { index < tokens.count ? tokens[index] : nil }
        func either() -> Bool {
            var value = both()
            while next() == "|" {
                index += 1
                value = both() || value
            }
            return value
        }
        func both() -> Bool {
            var value = single()
            while next() == "&" {
                index += 1
                value = single() && value
            }
            return value
        }
        func single() -> Bool {
            let token = next()
            index += 1
            switch token {
            case "!": return !single()
            case "(":
                let value = either()
                if next() == ")" { index += 1 }
                return value
            default: return token == "t"
            }
        }
        return either()
    }

    /// filters cancelled by a `$badfilter` twin anywhere in the subscription
    private static func badfiltered(_ lines: [String]) -> Set<String> {
        var cancelled = Set<String>()
        for line in lines where line.contains("badfilter") {
            guard let dollar = line.lastIndex(of: "$") else { continue }
            let options = line[line.index(after: dollar)...].split(separator: ",")
                .filter { $0 != "badfilter" }
            let head = String(line[..<dollar])
            cancelled.insert(options.isEmpty ? head : head + "$" + options.joined(separator: ","))
        }
        return cancelled
    }

    // MARK: - Cosmetic filters

    /// hiding rules gathered across every list, so a `#@#` un-hide or a
    /// `$generichide` exception can reach the hide it cancels wherever that sits
    private struct Cosmetics {
        var hides: [(selector: String, domains: [String], negated: [String])] = []
        /// selector → domains it is un-hidden on; "" means everywhere
        var unhidden: [String: Set<String>] = [:]
        /// domains that opt out of generic hiding, or of all hiding
        var noGeneric: Set<String> = []
        var noCosmetic: Set<String> = []

        /// generic and domain-specific rules, compiled into separate chunks so a
        /// `$generichide` exception can cancel the first without the second
        func rules(dropped: inout Int) -> (generic: [ContentRule], specific: [ContentRule]) {
            var generic: [ContentRule] = []
            var specific: [ContentRule] = []
            for hide in hides {
                let unhide = unhidden[hide.selector] ?? []
                guard !unhide.contains("") else { continue }
                var trigger = ContentRule.Trigger(urlFilter: ".*")
                if hide.domains.isEmpty {
                    let unless = unhide.union(hide.negated)
                    trigger.unlessDomain = unless.isEmpty ? nil : unless.sorted().map { "*" + $0 }
                } else {
                    guard hide.negated.isEmpty else {
                        dropped += 1
                        continue
                    }
                    let domains = hide.domains.filter { !unhide.contains($0) }
                    guard !domains.isEmpty else { continue }
                    trigger.ifDomain = domains.map { "*" + $0 }
                }
                let rule = ContentRule(
                    trigger: trigger, action: .init(type: "css-display-none", selector: hide.selector))
                if hide.domains.isEmpty { generic.append(rule) } else { specific.append(rule) }
            }
            return (generic, specific)
        }
    }

    private static func isCosmetic(_ line: String) -> Bool {
        ["##", "#@#", "#?#", "#@?#", "#$#", "#@$#", "#%#", "#@%#"].contains(where: line.contains)
    }

    /// `example.com##.ad-banner` hides that selector on that domain, `##.ad-banner`
    /// everywhere, and `example.com#@#.ad-banner` cancels either there.
    /// false when the line can't be used
    private static func addCosmetic(_ line: String, to cosmetics: inout Cosmetics) -> Bool {
        // `#?#`/`#$#`/`#%#` (and their `#@` forms) are procedural, CSS-injecting or script rules
        let unhide = line.range(of: "#@#")
        guard let separator = unhide ?? line.range(of: "##"),
            !["#?#", "#$#", "#%#"].contains(where: line.contains)
        else { return false }

        let selector = String(line[separator.upperBound...]).trimmingCharacters(in: .whitespaces)
        // `##^` filters the HTML text itself and `##+js` runs script, neither is CSS
        guard !selector.isEmpty, !selector.hasPrefix("^"), !selector.hasPrefix("+js("),
            isSafeSelector(selector)
        else { return false }

        var domains: [String] = []
        var negated: [String] = []
        for entry in line[line.startIndex..<separator.lowerBound].split(separator: ",") {
            let raw = entry.trimmingCharacters(in: .whitespaces)
            let isNegated = raw.hasPrefix("~")
            guard let name = normalizedDomain(isNegated ? raw.dropFirst() : raw[...]) else {
                // an unmatchable positive entry must not widen the rule to every site
                if isNegated { continue } else { return false }
            }
            if isNegated { negated.append(name) } else { domains.append(name) }
        }

        if unhide != nil {
            guard negated.isEmpty else { return false }
            cosmetics.unhidden[selector, default: []].formUnion(domains.isEmpty ? [""] : domains)
        } else {
            cosmetics.hides.append((selector, domains, negated))
        }
        return true
    }

    /// `@@||site.com^$generichide` (or `$elemhide`) turns hiding off on a site,
    /// which is how lists unbreak pages that test whether bait elements got hidden
    private static func addCosmeticSwitch(_ line: String, to cosmetics: inout Cosmetics) -> Bool {
        guard line.hasPrefix("@@"), let dollar = line.lastIndex(of: "$") else { return false }
        let options = line[line.index(after: dollar)...].split(separator: ",")
        let all = options.contains { $0 == "elemhide" || $0 == "ehide" }
        guard all || options.contains(where: { $0 == "generichide" || $0 == "ghide" })
        else { return false }

        var domains: [String] = []
        for option in options where option.hasPrefix("domain=") || option.hasPrefix("from=") {
            let list = option.drop { $0 != "=" }.dropFirst()
            domains += list.split(separator: "|").filter { !$0.hasPrefix("~") }
                .compactMap(normalizedDomain)
        }
        let pattern = line[line.index(line.startIndex, offsetBy: 2)..<dollar]
        if pattern.hasPrefix("||") {
            let host = pattern.dropFirst(2).prefix { !"^/*|".contains($0) }
            guard let name = normalizedDomain(host) else { return false }
            domains.append(name)
        } else if !(pattern.isEmpty || pattern == "*") {
            return false
        }
        guard !domains.isEmpty else { return false }
        if all { cosmetics.noCosmetic.formUnion(domains) } else { cosmetics.noGeneric.formUnion(domains) }
        return true
    }

    /// cancels every earlier rule in its chunk on these sites
    private static func ignoring(_ domains: Set<String>) -> [ContentRule] {
        guard !domains.isEmpty else { return [] }
        return [
            ContentRule(
                trigger: .init(urlFilter: ".*", ifDomain: domains.sorted().map { "*" + $0 }),
                action: .init(type: "ignore-previous-rules"))
        ]
    }

    /// WebKit's CSS engine handles standard selectors only and skips a rule whose
    /// selector it can't parse. uBlock's procedural extensions (`:has-text`,
    /// `:-abp-has`, `:style`, …) would only be skipped there, so they drop here
    private static func isSafeSelector(_ selector: String) -> Bool {
        let procedural = [
            ":-abp-", ":style(", ":has-text(", ":matches-", ":xpath(", ":upward(", ":remove",
            ":watch-attr(", ":nth-ancestor(", ":min-text-length(", ":others(", ":if(", ":if-not(",
            ":spath(",
        ]
        if procedural.contains(where: selector.contains) { return false }
        // an unbalanced bracket fails the whole compiled list
        return selector.filter { $0 == "(" }.count == selector.filter { $0 == ")" }.count
            && selector.filter { $0 == "[" }.count == selector.filter { $0 == "]" }.count
    }

    // MARK: - Network filters

    /// returns the rule and whether it's an exception (`@@`), or nil to drop
    private static func networkRule(_ line: String) -> (ContentRule, Bool)? {
        var body = line
        var isException = false
        if body.hasPrefix("@@") {
            isException = true
            body.removeFirst(2)
        }

        var optionText = ""
        if let index = optionsSeparator(in: body) {
            optionText = String(body[body.index(after: index)...])
            body = String(body[body.startIndex..<index])
        }

        // regex-literal filters use a syntax WebKit's engine doesn't share
        guard !body.hasPrefix("/") || !body.hasSuffix("/") else { return nil }
        guard !body.isEmpty, let filter = urlFilter(from: body) else { return nil }
        var trigger = ContentRule.Trigger(urlFilter: filter)

        var types: Set<String> = []
        var excludedTypes: Set<String> = []

        for option in optionText.split(separator: ",") where !option.isEmpty {
            var name = option.trimmingCharacters(in: .whitespaces).lowercased()
            let negated = name.hasPrefix("~")
            if negated { name.removeFirst() }

            if name.hasPrefix("domain=") || name.hasPrefix("from=") {
                let list = name.drop { $0 != "=" }.dropFirst()
                var ifDomain: [String] = []
                var unlessDomain: [String] = []
                for entry in list.split(whereSeparator: { $0 == "|" }) {
                    let negated = entry.hasPrefix("~")
                    guard let domain = normalizedDomain(negated ? entry.dropFirst() : entry) else {
                        if negated { continue } else { return nil }
                    }
                    if negated {
                        unlessDomain.append("*" + domain)
                    } else {
                        ifDomain.append("*" + domain)
                    }
                }
                guard ifDomain.isEmpty || unlessDomain.isEmpty else { return nil }
                if !ifDomain.isEmpty { trigger.ifDomain = ifDomain }
                if !unlessDomain.isEmpty { trigger.unlessDomain = unlessDomain }
                continue
            }

            switch name {
            case "third-party", "3p":
                trigger.loadType = negated ? ["first-party"] : ["third-party"]
            case "first-party", "1p":
                trigger.loadType = negated ? ["third-party"] : ["first-party"]
            case "match-case":
                trigger.urlFilterIsCaseSensitive = true
            case "important", "all", "doc":
                break  // no WebKit equivalent, but harmless to keep the rule
            case let name where unsupportedOptions.contains(name)
                || name.contains("=") && !name.hasPrefix("domain="):
                return nil
            default:
                guard let type = typeMap[name] else { return nil }
                if negated { excludedTypes.insert(type) } else { types.insert(type) }
            }
        }

        if !excludedTypes.isEmpty {
            types.formUnion(allResourceTypes.subtracting(excludedTypes))
        }
        if !types.isEmpty { trigger.resourceType = types.sorted() }

        return (
            ContentRule(
                trigger: trigger,
                action: .init(type: isException ? "ignore-previous-rules" : "block", selector: nil)),
            isException
        )
    }

    /// index of the `$` that opens the options, or nil. `$` is legal in a url pattern, so only a
    /// tail whose first token (up to `,` or `=`) looks like an option name splits; the rest of
    /// the tail is unchecked so `$csp=script-src none` still reaches the option parser
    private static func optionsSeparator(in body: String) -> String.Index? {
        guard let index = body.lastIndex(of: "$") else { return nil }
        let tail = body[body.index(after: index)...]
        guard !tail.isEmpty else { return nil }
        var token = tail.prefix { $0 != "," && $0 != "=" }
        if token.hasPrefix("~") { token = token.dropFirst() }
        guard (2...20).contains(token.count),
            token.allSatisfy({ $0.isLowercase && $0.isLetter || $0.isNumber || $0 == "-" })
        else { return nil }
        return index
    }

    /// translate an ABP url pattern into the regex subset WebKit's `url-filter`
    /// accepts
    private static func urlFilter(from pattern: String) -> String? {
        var source = pattern
        var out = ""

        // `||host` — match the host and any subdomain, on any scheme
        if source.hasPrefix("||") {
            source.removeFirst(2)
            out += "^[^:]+://+([^:/?#]+\\.)?"
        } else if source.hasPrefix("|") {
            source.removeFirst()
            out += "^"
        }

        var anchorEnd = false
        if source.hasSuffix("|"), !source.hasSuffix("\\|") {
            source.removeLast()
            anchorEnd = true
        }

        for character in source {
            switch character {
            case "*":
                out += ".*"
            case "^":
                // ABP's "separator": anything that isn't a url-legal name char.
                // WebKit has no `$`-alternation inside a character class, so the
                // end-of-url case is covered by leaving the match unanchored
                out += "[^a-zA-Z0-9_.%-]"
            case ".", "+", "?", "(", ")", "[", "]", "{", "}", "\\", "|", "/", "-", "$":
                out += "\\" + String(character)
            default:
                out.append(character)
            }
        }
        if anchorEnd { out += "$" }

        // WebKit's url-filter is ASCII-only and fails the whole list otherwise
        guard !out.isEmpty, out != ".*", out.count < 1000, out.allSatisfy(\.isASCII) else { return nil }
        // a pattern NSRegularExpression rejects would fail WebKit's whole list
        guard (try? NSRegularExpression(pattern: out)) != nil else { return nil }
        return out
    }
}
