// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import AppKit
import CryptoKit

/// a suggested password the person's own way: a root they remember plus part of each site's name
nonisolated struct PasswordRecipe: Codable, Identifiable, Hashable {
    enum SitePart: String, Codable, CaseIterable { case name, firstLetters, initial, scrambled }
    enum LetterCase: String, Codable, CaseIterable { case lower, capitalized, upper }

    var id = UUID()
    var name = "My Password"
    var root = ""
    var sitePart = SitePart.name
    /// how many characters `.firstLetters` and `.scrambled` keep
    var letters = 5
    var letterCase = LetterCase.lower
    var siteFirst = false
    /// nil is the default profile
    var profileID: UUID? = nil
    /// what `.scrambled` signs each site's name with; a scrambled recipe without it makes nothing
    var key: Data? = Self.newKey()

    static func newKey() -> Data { SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) } }

    var profile: UUID { profileID ?? Profile.defaultID }

    var isUsable: Bool { sitePart != .scrambled || key != nil }

    /// the registrable domain's first label: `accounts.google.co.uk` is `google`
    static func siteName(_ host: String) -> String {
        let domain = PasswordStore.registrableDomain(host) ?? host
        return String(domain.prefix { $0 != "." }.filter { $0.isLetter || $0.isNumber })
    }

    func site(for host: String) -> String? {
        let name = Self.siteName(host)
        let part: String
        switch sitePart {
        case .name: part = name
        case .firstLetters: part = String(name.prefix(letters))
        case .initial: part = String(name.prefix(1))
        case .scrambled: return key.map { Self.scramble(name.lowercased(), key: $0, count: letters) }
        }
        return switch letterCase {
        case .lower: part.lowercased()
        case .capitalized: part.prefix(1).uppercased() + part.dropFirst().lowercased()
        case .upper: part.uppercased()
        }
    }

    func password(for host: String) -> String? { site(for: host).map { join(root, $0) } }

    /// the password with dots for its root, safe to show on screen
    func masked(for host: String) -> String? { site(for: host).map { join("••••", $0) } }

    private func join(_ root: String, _ site: String) -> String { siteFirst ? site + root : root + site }

    private static let scrambleClasses = ["abcdefghijkmnopqrstuvwxyz", "ABCDEFGHJKLMNPQRSTUVWXYZ", "23456789"].map(Array.init)

    /// at least three characters of the name's HMAC-SHA256, opening with a lowercase letter, a capital and a digit
    static func scramble(_ name: String, key: Data, count: Int) -> String {
        let mac = Array(HMAC<SHA256>.authenticationCode(for: Data(name.utf8), using: SymmetricKey(data: key)))
        let all = scrambleClasses.flatMap { $0 }
        return String(
            (0..<min(max(count, 3), mac.count)).map { i in
                let set = i < scrambleClasses.count ? scrambleClasses[i] : all
                return set[Int(mac[i]) % set.count]
            })
    }
}

nonisolated extension PasswordRecipe {
    /// a field this build doesn't know, or one an older build never wrote, falls back to its default;
    /// a missing key stays missing, since a new one would change every scrambled password
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func field<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? c.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        let base = PasswordRecipe()
        self.init(
            id: field(.id, base.id), name: field(.name, base.name), root: field(.root, base.root),
            sitePart: field(.sitePart, base.sitePart), letters: field(.letters, base.letters),
            letterCase: field(.letterCase, base.letterCase), siteFirst: field(.siteFirst, base.siteFirst),
            profileID: field(.profileID, base.profileID), key: field(.key, Data?.none))
    }
}

/// what a site asks of a password, in Apple's `passwordrules` language
nonisolated struct PasswordRules {
    var minLength = 0
    var maxLength = Int.max
    var maxConsecutive = Int.max
    /// each entry is met by one character from any of its classes
    var required: [[String]] = []
    var allowed: [String] = []
    /// the field's own `pattern`, which only the page tests, so a runaway one stalls that tab rather than Artemis
    var pattern: String?

    /// whether the site says which characters it takes
    var namesCharacters: Bool { !required.isEmpty || !allowed.isEmpty || pattern != nil }

    /// text over a kilobyte is ignored, as if the site named no rules
    init(_ text: String = "") {
        guard text.utf8.count <= 1024 else { return }
        for property in Self.split(text, on: ";") {
            let parts = property.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            let classes = Self.split(parts[1], on: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            switch parts[0].lowercased() {
            case "minlength": minLength = max(minLength, Int(parts[1]) ?? 0)
            case "maxlength": maxLength = min(maxLength, Int(parts[1]) ?? .max)
            case "max-consecutive": maxConsecutive = min(maxConsecutive, Int(parts[1]) ?? .max)
            case "required": required.append(classes)
            case "allowed": allowed += classes
            default: continue
            }
        }
    }

    /// the page's own `passwordrules`, else Apple's for `host`, narrowed by the field's
    /// `min` and `max` lengths (-1 when unset) and its `pattern`
    init(field: [String: Any], host: String) {
        let own = field["rules"] as? String ?? ""
        self.init(own.isEmpty ? Self.known(for: host) ?? "" : own)
        if let low = field["min"] as? Int, low > 0 { minLength = max(minLength, low) }
        if let high = field["max"] as? Int, high > 0 { maxLength = min(maxLength, high) }
        pattern = (field["pattern"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// `text` cut at each `separator` outside a `[…]` class, where `]]` is a literal `]` then the close
    private static func split(_ text: String, on separator: Character) -> [String] {
        var pieces = [""]
        var inClass = false
        var chars = Array(text)[...]
        while let c = chars.popFirst() {
            if inClass, c == "]", chars.first != "]" {
                inClass = false
            } else if !inClass, c == "[" {
                inClass = true
            } else if !inClass, c == separator {
                pieces.append("")
                continue
            }
            pieces[pieces.count - 1].append(c)
        }
        return pieces
    }

    private struct Quirk: Decodable {
        let rules: String
        let exactOnly: Bool?

        enum CodingKeys: String, CodingKey {
            case rules = "password-rules"
            case exactOnly = "exact-domain-match-only"
        }
    }

    /// apple/password-manager-resources quirks/password-rules.json (MIT, notice beside it)
    private static let quirks: [String: Quirk] = {
        guard let url = Bundle.main.url(forResource: "password-rules", withExtension: "json"),
            let data = try? Data(contentsOf: url)
        else { return [:] }
        return (try? JSONDecoder().decode([String: Quirk].self, from: data)) ?? [:]
    }()

    /// Apple's rules for `host`, or for the nearest parent domain they cover
    static func known(for host: String) -> String? {
        let host = host.lowercased()
        var labels = host.split(separator: ".")
        while labels.count >= 2 {
            let domain = labels.joined(separator: ".")
            if let quirk = quirks[domain], quirk.exactOnly != true || domain == host { return quirk.rules }
            labels.removeFirst()
        }
        return nil
    }

    /// what `password` lacks for this site, in words; nil when it fits
    func problem(with password: String) -> String? {
        if password.count < minLength { return "Too short for this site" }
        if password.count > maxLength { return "Too long for this site" }
        if !password.allSatisfy(isAllowed) { return "Has characters this site doesn't allow" }
        if longestRun(password) > maxConsecutive { return "Repeats a character too often for this site" }
        let missing = required.first { classes in
            !password.contains { c in classes.contains { Self.matches(c, $0) } }
        }
        guard let missing else { return nil }
        let names = ["upper": "a capital letter", "lower": "a lowercase letter", "digit": "a number"]
        return "This site needs " + (missing.lazy.compactMap { names[$0.lowercased()] }.first ?? "a symbol")
    }

    /// a site that names no classes allows anything
    func isAllowed(_ c: Character) -> Bool {
        let classes = allowed + required.flatMap { $0 }
        return classes.isEmpty || classes.contains { Self.matches(c, $0) }
    }

    private func longestRun(_ password: String) -> Int {
        var longest = 0
        var run = 0
        var last: Character?
        for c in password {
            run = c == last ? run + 1 : 1
            last = c
            longest = max(longest, run)
        }
        return longest
    }

    static func matches(_ c: Character, _ name: String) -> Bool {
        switch name.lowercased() {
        case "upper": c.isASCII && c.isUppercase
        case "lower": c.isASCII && c.isLowercase
        case "digit": c.isASCII && c.isNumber
        case "special": c.isASCII && (c.isPunctuation || c.isSymbol || c == " ")
        case "ascii-printable": c.isASCII && !c.isNewline
        case "unicode": true
        default: name.hasPrefix("[") && name.dropFirst().dropLast().contains(c)
        }
    }
}

/// how many leaks Have I Been Pwned has seen a password in; only five hex characters
/// of its SHA-1 leave the Mac
enum PwnedPasswords {
    static let enabledKey = "passwordsCheckLeaks"
    private static let session = URLSession(configuration: .ephemeral)

    /// nil when the service can't be reached
    static func count(for password: String) async -> Int? {
        let hash = Insecure.SHA1.hash(data: Data(password.utf8)).map { String(format: "%02X", $0) }.joined()
        var request = URLRequest(url: URL(string: "https://api.pwnedpasswords.com/range/" + hash.prefix(5))!)
        request.setValue("true", forHTTPHeaderField: "Add-Padding")
        guard let (data, response) = try? await session.data(for: request),
            (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return count(of: String(hash.dropFirst(5)), in: String(decoding: data, as: UTF8.self))
    }

    /// the count beside `suffix` in a range response's `SUFFIX:COUNT` lines; padding lines say 0
    static func count(of suffix: String, in body: String) -> Int {
        for line in body.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":")
            if parts.count == 2, parts[0] == suffix { return Int(parts[1]) ?? 0 }
        }
        return 0
    }
}

/// a guess at how hard a password is to crack: the fewest bits that build it
/// from dictionary words, keyboard or alphabet runs, repeats and single characters
enum PasswordStrength: Int, Comparable {
    case weak, fair, good, strong

    /// what the dictionary said of each piece, kept by whoever rates one password while it is typed,
    /// so each keystroke asks only about the pieces it made
    final class Words {
        fileprivate var known: [String: Bool] = [:]
    }

    init(_ password: String, words: Words = Words()) {
        let bits = Self.bits(password, words: words)
        self = bits < 40 ? .weak : bits < 55 ? .fair : bits < 70 ? .good : .strong
    }

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    private static let runs = ["abcdefghijklmnopqrstuvwxyz", "0123456789", "qwertyuiop", "asdfghjkl", "zxcvbnm"]
    private static let leet: [Character: Character] = ["0": "o", "1": "i", "3": "e", "4": "a", "5": "s", "7": "t", "@": "a", "$": "s"]

    static func bits(_ password: String, words: Words = Words()) -> Double {
        let chars = Array(password)
        var cost = [0.0] + Array(repeating: Double.infinity, count: chars.count)
        for end in stride(from: 1, through: chars.count, by: 1) {
            cost[end] = cost[end - 1] + log2(pool(chars[end - 1]))
            for start in max(0, end - 24)..<max(0, end - 2) {
                if let bits = pattern(chars[start..<end], words) { cost[end] = min(cost[end], cost[start] + bits) }
            }
        }
        return cost[chars.count]
    }

    private static func pool(_ c: Character) -> Double {
        c.isLowercase ? 26 : c.isUppercase ? 26 : c.isNumber ? 10 : 33
    }

    /// the system dictionary knows it
    private static func isWord(_ word: String, _ words: Words) -> Bool {
        if let known = words.known[word] { return known }
        let known = NSSpellChecker.shared.checkSpelling(of: word, startingAt: 0).location == NSNotFound
        words.known[word] = known
        return known
    }

    /// bits for a piece of three or more characters that one pattern covers, nil when none does
    private static func pattern(_ piece: ArraySlice<Character>, _ words: Words) -> Double? {
        let first = log2(pool(piece.first!))
        let length = log2(Double(piece.count))
        if Set(piece).count == 1 { return first + length }
        if piece.count == 4, let year = Int(String(piece)), (1900...2099).contains(year) { return log2(200) }
        let lower = String(piece).lowercased()
        if runs.contains(where: { $0.contains(lower) || String($0.reversed()).contains(lower) }) {
            return first + length + 1
        }
        let word = String(lower.map { leet[$0] ?? $0 })
        guard word.allSatisfy(\.isLetter), isWord(word, words) else { return nil }
        return log2(20_000) + (piece.contains(where: \.isUppercase) ? 1 : 0) + (word == lower ? 0 : 1)
    }
}
