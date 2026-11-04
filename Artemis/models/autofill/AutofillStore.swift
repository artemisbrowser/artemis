import Foundation
import Security

/// a postal address with the contact details checkouts ask beside it
nonisolated struct SavedAddress: Codable, Identifiable, Hashable {
    var id = UUID()
    var givenName = ""
    var familyName = ""
    var organization = ""
    /// one street line per line
    var street = ""
    var city = ""
    /// a state, province or county, as the person writes it
    var region = ""
    var postalCode = ""
    /// ISO 3166-1 alpha-2, uppercase
    var country = ""
    var phone = ""
    var email = ""
    var created = Date()
    var updated = Date()
    var lastUsed: Date?
    /// nil is the default profile
    var profileID: UUID?

    var profile: UUID { profileID ?? Profile.defaultID }
    var name: String { [givenName, familyName].filter { !$0.isEmpty }.joined(separator: " ") }
    var streetLines: [String] {
        street.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
    /// the first street line and the town, for a one-line list row
    var summary: String {
        [streetLines.first ?? "", city.isEmpty ? postalCode : city].filter { !$0.isEmpty }.joined(separator: ", ")
    }

    /// `other` names the same place: its first street line and postal code, ignoring case and spacing
    func isSamePlace(as other: SavedAddress) -> Bool {
        let key = { (a: SavedAddress) in
            ((a.streetLines.first ?? "") + "|" + a.postalCode).lowercased().filter { !$0.isWhitespace && $0 != "," && $0 != "." }
        }
        return key(self) == key(other)
    }

    /// `other`'s filled fields over this one's
    func merging(_ other: SavedAddress) -> SavedAddress {
        var merged = self
        let fields: [WritableKeyPath<SavedAddress, String>] = [
            \.givenName, \.familyName, \.organization, \.street, \.city, \.region, \.postalCode, \.country, \.phone, \.email,
        ]
        for field in fields where !other[keyPath: field].isEmpty { merged[keyPath: field] = other[keyPath: field] }
        return merged
    }
}

nonisolated enum CardBrand: String, Codable, CaseIterable {
    case visa, mastercard, amex, discover, diners, jcb, unionpay, maestro, other

    init(number: String) {
        let d = number.filter(\.isNumber)
        let two = Int(d.prefix(2)) ?? 0, four = Int(d.prefix(4)) ?? 0
        self =
            switch true {
            case d.hasPrefix("4"): .visa
            case (51...55).contains(two) || (2221...2720).contains(four): .mastercard
            case two == 34 || two == 37: .amex
            case d.hasPrefix("6011") || d.hasPrefix("65") || (644...649).contains(Int(d.prefix(3)) ?? 0): .discover
            case two == 36 || two == 38 || (300...305).contains(Int(d.prefix(3)) ?? 0): .diners
            case two == 35: .jcb
            case two == 62: .unionpay
            case two == 50 || (56...58).contains(two) || d.hasPrefix("6"): .maestro
            default: .other
            }
    }

    var name: String {
        switch self {
        case .visa: "Visa"
        case .mastercard: "Mastercard"
        case .amex: "American Express"
        case .discover: "Discover"
        case .diners: "Diners Club"
        case .jcb: "JCB"
        case .unionpay: "UnionPay"
        case .maestro: "Maestro"
        case .other: "Card"
        }
    }

    /// the digit counts this network issues
    var lengths: [Int] {
        switch self {
        case .visa: [13, 16, 19]
        case .mastercard: [16]
        case .amex: [15]
        case .diners: Array(14...19)
        case .discover, .jcb, .unionpay: Array(16...19)
        case .maestro, .other: Array(12...19)
        }
    }

    /// the digits spaced as printed on the card (Amex 4-6-5, 14-digit Diners 4-6-4, else fours);
    /// digits past what the card can hold are dropped
    static func grouped(_ number: String) -> String {
        var rest = Substring(number.filter(\.isNumber))
        let brand = CardBrand(number: String(rest))
        let sizes = brand == .amex || (brand == .diners && rest.count <= 14) ? [4, 6, 5] : [4, 4, 4, 4, 3]
        var groups: [Substring] = []
        for size in sizes where !rest.isEmpty {
            groups.append(rest.prefix(size))
            rest = rest.dropFirst(size)
        }
        return groups.joined(separator: " ")
    }

    /// a length its network issues, passing the Luhn check
    static func isValid(_ number: String) -> Bool {
        let digits = number.compactMap(\.wholeNumberValue)
        guard CardBrand(number: number).lengths.contains(digits.count),
            digits.count == number.filter({ !$0.isWhitespace && $0 != "-" }).count
        else { return false }
        let sum = digits.reversed().enumerated().reduce(0) { sum, item in
            let doubled = item.offset % 2 == 1 ? item.element * 2 : item.element
            return sum + (doubled > 9 ? doubled - 9 : doubled)
        }
        return sum % 10 == 0
    }
}

/// a payment card's display details; its number is a Keychain item of its own and no security code is ever kept
nonisolated struct SavedCard: Codable, Identifiable, Hashable {
    var id = UUID()
    var holder = ""
    /// 1–12
    var expiryMonth: Int
    /// four digits
    var expiryYear: Int
    var brand: CardBrand
    var last4: String
    var created = Date()
    var updated = Date()
    var lastUsed: Date?
    /// nil is the default profile
    var profileID: UUID?

    var profile: UUID { profileID ?? Profile.defaultID }
    var label: String { "\(brand.name) •••• \(last4)" }
    var expiry: String { String(format: "%02d/%02d", expiryMonth, expiryYear % 100) }
    var isExpired: Bool {
        let now = Calendar.current.dateComponents([.year, .month], from: Date())
        return (expiryYear, expiryMonth) < (now.year ?? 0, now.month ?? 0)
    }
}

/// where card numbers live, keyed by card UUID; the self-test keeps its own in memory
nonisolated struct CardVault: Sendable {
    var put: @Sendable (String, Data) -> Bool
    var read: @Sendable (String) -> Data?
    var delete: @Sendable (String) -> Void

    static func keychain(_ service: String) -> CardVault {
        CardVault(
            put: { Keychain.put(service, $0, $1) == errSecSuccess }, read: { Keychain.secret(service, $0) },
            delete: { Keychain.delete(service, $0) })
    }
}

/// One profile's addresses and cards. Addresses and card details sit in `autofill.json`; each card number is a
/// login-keychain item named by the card's UUID. The data-protection keychain (which could demand user presence
/// itself) answers -34018 here, so every use of a number goes through `OwnerUnlock` first.
@MainActor
@Observable
final class AutofillStore {
    static let fillAddressesKey = "autofillAddresses"
    static let fillCardsKey = "autofillCards"
    static let offerToSaveKey = "autofillOfferToSave"

    /// the self-test swaps in its own
    static var shared = AutofillStore(
        file: AppStorageLocation.file("autofill.json"), vault: .keychain("\(Keychain.owner) Cards"))

    private nonisolated static let queue = DispatchQueue(label: "Artemis.Cards")

    private struct Saved: Codable {
        var addresses: [SavedAddress]
        var cards: [SavedCard]
    }

    private(set) var addresses: [SavedAddress] = []
    private(set) var cards: [SavedCard] = []
    /// the file is there but neither it nor its backup decodes; nothing is written over it
    private(set) var isUnreadable = false
    @ObservationIgnored private let file: URL
    @ObservationIgnored private let vault: CardVault

    var fillsAddresses: Bool { Self.flag(Self.fillAddressesKey) }
    var fillsCards: Bool { Self.flag(Self.fillCardsKey) }
    var offersToSave: Bool { Self.flag(Self.offerToSaveKey) }

    private static func flag(_ key: String) -> Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }

    init(file: URL, vault: CardVault) {
        self.file = file
        self.vault = vault
        if let saved = AppStorageLocation.loadDurable(Saved.self, from: file) {
            addresses = saved.addresses
            cards = saved.cards
        } else {
            isUnreadable = FileManager.default.fileExists(atPath: file.path)
        }
    }

    private var encoded: Data? {
        isUnreadable ? nil : try? JSONEncoder().encode(Saved(addresses: addresses, cards: cards))
    }

    private func persist() {
        if let encoded { AppStorageLocation.writeDurable(encoded, to: file) }
    }

    /// the write finished before it returns, for `applicationWillTerminate`, where a queued one dies with the process
    func saveNow() {
        if let encoded { AppStorageLocation.writeDurableNow(encoded, to: file) }
    }

    private static func recent(_ a: Date?, _ b: Date?) -> Bool { (a ?? .distantPast) > (b ?? .distantPast) }

    /// most recently used first
    func addresses(in profile: UUID) -> [SavedAddress] {
        addresses.filter { $0.profile == profile }.sorted { Self.recent($0.lastUsed ?? $0.updated, $1.lastUsed ?? $1.updated) }
    }

    func cards(in profile: UUID) -> [SavedCard] {
        cards.filter { $0.profile == profile }.sorted { Self.recent($0.lastUsed ?? $0.updated, $1.lastUsed ?? $1.updated) }
    }

    /// adds, or replaces the address with the same id
    func save(_ address: SavedAddress) {
        var address = address
        address.updated = Date()
        addresses.removeAll { $0.id == address.id }
        addresses.append(address)
        persist()
    }

    func delete(_ address: SavedAddress) {
        addresses.removeAll { $0.id == address.id }
        persist()
    }

    /// adds, or replaces the card with the same id; a nil `number` keeps the stored one. False when the
    /// Keychain refused the number.
    @discardableResult
    func save(_ card: SavedCard, number: String?) -> Bool {
        guard !isUnreadable else { return false }
        var card = card
        if let number {
            let digits = number.filter(\.isNumber)
            let kept = Self.queue.sync { vault.put(card.id.uuidString, Data(digits.utf8)) }
            guard kept else { return false }
            card.brand = CardBrand(number: digits)
            card.last4 = String(digits.suffix(4))
        }
        card.updated = Date()
        cards.removeAll { $0.id == card.id }
        cards.append(card)
        persist()
        return true
    }

    func delete(_ card: SavedCard) {
        cards.removeAll { $0.id == card.id }
        persist()
        let vault = vault
        Self.queue.async { vault.delete(card.id.uuidString) }
    }

    /// the card's digits; callers check the device owner first
    func number(for card: SavedCard) -> String? {
        Self.queue.sync { vault.read(card.id.uuidString) }.flatMap { String(data: $0, encoding: .utf8) }
    }

    /// the profile's card with these digits
    func card(numbered number: String, in profile: UUID) -> SavedCard? {
        let digits = number.filter(\.isNumber)
        return cards(in: profile).first { $0.last4 == String(digits.suffix(4)) && self.number(for: $0) == digits }
    }

    func markUsed(_ address: SavedAddress) {
        guard let i = addresses.firstIndex(where: { $0.id == address.id }) else { return }
        addresses[i].lastUsed = Date()
        persist()
    }

    func markUsed(_ card: SavedCard) {
        guard let i = cards.firstIndex(where: { $0.id == card.id }) else { return }
        cards[i].lastUsed = Date()
        persist()
    }

    /// the profile's addresses and cards, and their numbers, last changed or used since `since`
    func deleteAll(in profile: UUID, since: Date = .distantPast) {
        let touched = { (changed: Date, used: Date?) in max(changed, used ?? changed) >= since }
        for card in cards where card.profile == profile && touched(card.updated, card.lastUsed) { delete(card) }
        addresses.removeAll { $0.profile == profile && touched($0.updated, $0.lastUsed) }
        persist()
    }

    /// ISO code for what a country field holds: a code, or a name in English or this Mac's language
    nonisolated static func countryCode(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let regions = Locale.Region.isoRegions.map(\.identifier).filter { $0.count == 2 && $0.allSatisfy(\.isLetter) }
        if trimmed.count == 2, regions.contains(trimmed.uppercased()) { return trimmed.uppercased() }
        let folded = { (s: String) in s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
        let wanted = folded(trimmed)
        for locale in [Locale.current, Locale(identifier: "en")] {
            if let code = regions.first(where: { locale.localizedString(forRegionCode: $0).map(folded) == wanted }) {
                return code
            }
        }
        return ["uk": "GB", "usa": "US", "united states of america": "US"][wanted]
    }
}
