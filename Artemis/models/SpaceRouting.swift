import SwiftUI

/// Which space a site belongs to.
///
/// The rule is a glob over `host/path` — `*.github.com/acme/*` — matched with
/// the host and the path kept apart, so a `*` in the host can never swallow a
/// slash and match the domain out of somebody else's path.
///
/// A space signs in as its profile, so routing a site to spaces in two profiles
/// is what makes the same site two different logins.
struct RoutingRule: Codable, Identifiable, Equatable {
    var id: UUID
    /// glob over `host/path`, e.g. `*.github.com` or `mail.google.com/u/1/*`
    var pattern: String
    /// the space it opens in
    var spaceID: UUID

    init(id: UUID = UUID(), pattern: String, spaceID: UUID) {
        self.id = id
        self.pattern = pattern
        self.spaceID = spaceID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        pattern = try c.decodeIfPresent(String.self, forKey: .pattern) ?? ""
        spaceID = try c.decode(UUID.self, forKey: .spaceID)
    }

    private enum CodingKeys: String, CodingKey { case id, pattern, spaceID }

    /// true when the url is the one this rule is about
    func matches(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased(), !pattern.isEmpty else { return false }
        let trimmed = pattern.trimmingCharacters(in: .whitespaces).lowercased()
        // the pattern's first slash separates the two, so neither glob can reach
        // across into the other
        let cut = trimmed.firstIndex(of: "/")
        let hostPattern = cut.map { String(trimmed[trimmed.startIndex ..< $0]) } ?? trimmed
        let pathPattern = cut.map { String(trimmed[$0...]) }
        // `*.example.com` covers example.com as well: the split between a
        // domain and its subdomains is not one anybody means to draw, and it is
        // the convention every filter list already uses
        let bare = hostPattern.hasPrefix("*.") ? String(hostPattern.dropFirst(2)) : nil
        guard Self.glob(hostPattern, matches: host) || bare == host else { return false }
        guard let pathPattern else { return true }  // no path given → any path
        return Self.glob(pathPattern, matches: url.path().isEmpty ? "/" : url.path().lowercased())
    }

    /// `*` stands for any run of characters, including none. Everything else is
    /// literal, and both ends are anchored
    static func glob(_ pattern: String, matches text: String) -> Bool {
        let parts = pattern.components(separatedBy: "*")
        guard parts.count > 1 else { return pattern == text }
        guard text.hasPrefix(parts[0]) else { return false }
        guard let last = parts.last, text.count >= parts[0].count else { return false }
        var rest = text[text.index(text.startIndex, offsetBy: parts[0].count)...]
        // every middle piece has to appear in order; the last one has to end it
        for piece in parts.dropFirst().dropLast() where !piece.isEmpty {
            guard let found = rest.range(of: piece) else { return false }
            rest = rest[found.upperBound...]
        }
        return last.isEmpty || rest.hasSuffix(last)
    }
}

/// A drafted rule, with the evidence offered for it and the verdict of checking
/// that evidence in code — the one pass that cannot be wrong about itself.
struct RoutingProposal {
    /// who wrote it: the on-device model, or the plain reading of the sentence
    /// that runs when the model is unavailable
    enum Source { case model, sentence }

    var pattern: String
    var spaceName: String
    /// urls the draft says the rule catches, and ones it says it does not
    var examples: [String] = []
    var counterExamples: [String] = []
    /// why it was rejected, or nil if the pattern does what it claims
    var problem: String?
    /// true when a second pass had to correct the first
    var revised = false
    var source: Source = .model
}

/// what a link from another app does when a rule matches it
enum ExternalLinkRouting: String, CaseIterable, Identifiable, Codable {
    /// it still opens in Scout — the rule only decides which space Scout offers
    case scout
    /// it skips Scout and opens in the rule's space
    case direct

    var id: Self { self }

    var title: String {
        switch self {
        case .scout: "Open in Scout, defaulting to the rule's space"
        case .direct: "Open straight in the rule's space"
        }
    }
}

extension RoutingRule {
    /// Read a rule out of a sentence without a model: find a space by name, find
    /// a site by looking for something domain-shaped, and build the glob. It is
    /// what runs when Apple's on-device model is unavailable, which — being an
    /// OS-managed asset — is not something the app can fix or wait out.
    static func suggest(from sentence: String, spaces: [String]) -> RoutingProposal? {
        let text = sentence.lowercased()
        guard !text.isEmpty else { return nil }

        // the longest space name mentioned wins, so "Work" inside "Work Admin"
        // doesn't steal the match
        let named = spaces
            .filter { !$0.isEmpty && text.contains($0.lowercased()) }
            .max { $0.count < $1.count }
        guard let named else {
            return RoutingProposal(
                pattern: "", spaceName: "", problem: "no space in that sentence is one you have",
                source: .sentence)
        }

        // whatever is left once the space's own name is out of the way
        let rest = text.replacingOccurrences(of: named.lowercased(), with: " ")
        let words = rest.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "." && $0 != "-" })
            .map(String.init)
            .filter { !Self.filler.contains($0) && $0.count > 1 }

        // something already domain-shaped is taken at its word; otherwise the
        // longest remaining word is the site's name and .com is the guess
        let host = words.first { $0.contains(".") && !$0.hasSuffix(".") }
            ?? words.max { $0.count < $1.count }.map { "\($0).com" }
        guard let host else {
            return RoutingProposal(
                pattern: "", spaceName: named,
                problem: "no site in that sentence to make a rule from", source: .sentence)
        }
        let pattern = host.hasPrefix("*.") ? host : "*.\(host)"
        return RoutingProposal(
            pattern: pattern, spaceName: named,
            examples: ["https://\(host)/", "https://www.\(host)/"], source: .sentence)
    }

    /// words that are never the site being talked about
    private static let filler: Set<String> = [
        "all", "always", "and", "any", "everything", "for", "from", "goes", "go", "in", "into",
        "keep", "link", "links", "me", "my", "open", "opens", "page", "pages", "put", "send",
        "site", "sites", "space", "the", "to", "url", "urls", "want", "with",
    ]
}

extension UserDefaults {
    /// what a routed link from another app does. Scout keeps it by default —
    /// a link from elsewhere is a glance, and the rule only says where it would land
    var externalLinkRouting: ExternalLinkRouting {
        ExternalLinkRouting(rawValue: string(forKey: "externalLinkRouting") ?? "") ?? .scout
    }
}

/// the rules, in the order they are tried — the first match wins
@MainActor
@Observable
final class RoutingStore {
    static let shared = RoutingStore()

    private(set) var rules: [RoutingRule] = []

    /// injectable so the suite can drill recovery without touching the real file
    private let fileURL: URL
    private var saveTask: Task<Void, Never>?

    init(fileURL: URL = AppStorageLocation.file("routing.json")) {
        self.fileURL = fileURL
        rules = AppStorageLocation.loadDurable([RoutingRule].self, from: fileURL) ?? []
    }

    /// the rule that claims this url, or nil
    func rule(for url: URL) -> RoutingRule? {
        rules.first { $0.matches(url) }
    }

    func add(pattern: String, spaceID: UUID) {
        let trimmed = pattern.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        rules.append(RoutingRule(pattern: trimmed, spaceID: spaceID))
        scheduleSave()
    }

    func update(_ rule: RoutingRule) {
        guard let index = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        rules[index] = rule
        scheduleSave()
    }

    func remove(_ rule: RoutingRule) {
        rules.removeAll { $0.id == rule.id }
        scheduleSave()
    }

    func move(fromOffsets: IndexSet, toOffset: Int) {
        rules.move(fromOffsets: fromOffsets, toOffset: toOffset)
        scheduleSave()
    }

    /// a deleted space takes its rules with it. Called before the container is
    /// destroyed, so a rule can't fire into a jar that is being torn down
    func forget(spaceID: UUID) {
        guard rules.contains(where: { $0.spaceID == spaceID }) else { return }
        rules.removeAll { $0.spaceID == spaceID }
        saveNow()
    }

    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            let snapshot = rules
            let url = fileURL
            await Task.detached(priority: .utility) {
                guard let data = try? JSONEncoder().encode(snapshot) else { return }
                AppStorageLocation.writeDurable(data, to: url)
            }.value
        }
    }

    func saveNow() {
        guard let data = try? JSONEncoder().encode(rules) else { return }
        AppStorageLocation.writeDurableNow(data, to: fileURL)
    }
}
