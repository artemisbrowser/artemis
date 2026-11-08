// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import Foundation
import Security
import UniformTypeIdentifiers

/// a saved login; its password is a Keychain item of its own, read on demand
nonisolated struct SavedLogin: Codable, Identifiable, Hashable {
    let id: UUID
    /// `scheme://host[:port]`, as `SitePermissionStore.originString` writes it
    var origin: String
    var username: String
    var created: Date
    var updated: Date
    var lastUsed: Date?
    var notes: String?
    /// other names the same account signs in with (an email, a phone number); `username` is what autofill fills
    var otherNames: [String]?
    /// a verification-code setup is kept beside the password
    var hasOneTimeCode: Bool?
    /// nil is the default profile, which every login before profiles belongs to
    var profileID: UUID? = nil

    var host: String { URL(string: origin)?.host() ?? origin }
    var profile: UUID { profileID ?? Profile.defaultID }
}

/// a passkey this Mac holds; its private key (or Secure Enclave blob) is a Keychain item of its own
nonisolated struct SavedPasskey: Codable, Identifiable, Hashable {
    /// base64url
    let id: String
    /// lowercase
    let rpID: String
    /// base64url
    let userHandle: String
    var userName: String
    var displayName: String
    let created: Date
    /// the data is a `SecureEnclave.P256` blob rather than a raw software key
    let enclave: Bool
    /// nil is the default profile
    var profileID: UUID? = nil

    var profile: UUID { profileID ?? Profile.defaultID }
}

/// Generic-password items in the login keychain whose attributes say nothing: a UUID or
/// credential ID account and the service as label. Sites and usernames live in each service's
/// `index` item. The data-protection keychain answers -34018 here (no application-identifier).
nonisolated enum Keychain {
    /// the login keychain is shared by every build on the Mac: any bundle ID but the
    /// original keeps its own items, and the original keeps the names its items have
    static let owner: String = {
        if let name = AppStorageLocation.storageName { return name }
        let id = Bundle.main.bundleIdentifier ?? "dev.findles.Artemis"
        return id == "dev.findles.Artemis" ? "Artemis" : id
    }()
    static let passwords = "\(owner) Passwords"
    static let passkeys = "\(owner) Passkeys"
    static let index = "index"
    /// the index's copy while `index` itself is deleted and added again
    static let nextIndex = "index.next"
    /// a profile's suggested-password recipes, roots included, in the passwords service
    static func recipes(_ profile: UUID) -> String { "recipes." + profile.uuidString }

    /// a login's verification-code setup, in the passwords service
    static func code(_ login: UUID) -> String { login.uuidString + ".code" }

    private static func query(_ service: String, _ account: String? = nil) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        if let account { q[kSecAttrAccount as String] = account }
        return q
    }

    /// delete then add, so the item carries Artemis' own access list whatever was there before
    /// the extension lab signs differently, so every login-keychain item would raise a password
    /// prompt on the user's screen; it gets an empty keychain
    private static let isFenced = AppStorageLocation.isExtensionLab

    @discardableResult
    static func put(_ service: String, _ account: String, _ data: Data) -> OSStatus {
        guard !isFenced else { return errSecNotAvailable }
        SecItemDelete(query(service, account) as CFDictionary)
        let item = query(service, account).merging([
            kSecValueData as String: data, kSecAttrLabel as String: service,
        ]) { $1 }
        return SecItemAdd(item as CFDictionary, nil)
    }

    static func secret(_ service: String, _ account: String) -> Data? { read(service, account).data }

    static func read(_ service: String, _ account: String) -> (data: Data?, status: OSStatus) {
        guard !isFenced else { return (nil, errSecItemNotFound) }
        var q = query(service, account)
        q[kSecReturnData as String] = true
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        return (status == errSecSuccess ? out as? Data : nil, status)
    }

    static func delete(_ service: String, _ account: String) {
        guard !isFenced else { return }
        SecItemDelete(query(service, account) as CFDictionary)
    }

    static func accounts(_ service: String) -> [String] {
        guard !isFenced else { return [] }
        var q = query(service)
        q[kSecMatchLimit as String] = kSecMatchLimitAll
        q[kSecReturnAttributes as String] = true
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let items = out as? [[String: Any]]
        else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    /// items still carrying their metadata in `kSecAttrGeneric`, to be migrated
    static func legacy(_ service: String) -> [(account: String, meta: Data)] {
        guard !isFenced else { return [] }
        var q = query(service)
        q[kSecMatchLimit as String] = kSecMatchLimitAll
        q[kSecReturnAttributes as String] = true
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
            let items = out as? [[String: Any]]
        else { return [] }
        return items.compactMap { item in
            guard let account = item[kSecAttrAccount as String] as? String,
                let meta = item[kSecAttrGeneric as String] as? Data
            else { return nil }
            return (account, meta)
        }
    }
}

/// Artemis' own password and passkey vault: indexes in memory, everything in the Keychain.
/// Keychain writes run in order on `queue` (an add measured ~30 ms); reads wait for them.
@MainActor
@Observable
final class PasswordStore {
    static let offerToSaveKey = "passwordsOfferToSave"
    static let fillFromSuggestionsKey = "passwordsFillFromSuggestions"
    private static let neverSaveKey = "passwordsNeverSave"
    private nonisolated static let queue = DispatchQueue(label: "Artemis.Passwords")

    private(set) var logins: [SavedLogin] = []
    private(set) var passkeys: [SavedPasskey] = []
    private(set) var recipes: [PasswordRecipe] = []
    /// profiles whose recipes item couldn't be read; nothing is written over it
    @ObservationIgnored private var unreadableRecipes: Set<UUID> = []
    /// hosts the person said never to offer saving for
    private(set) var neverSave: [String] =
        UserDefaults.standard.stringArray(forKey: neverSaveKey) ?? []
    /// an index exists but couldn't be read or decoded; nothing is written over it
    private(set) var isUnreadable = false
    /// whether this install still has a profile; a login naming one it doesn't belongs to the default
    @ObservationIgnored private let profileExists: (UUID) -> Bool

    var offersToSave: Bool { UserDefaults.standard.object(forKey: Self.offerToSaveKey) as? Bool ?? true }
    var fillsFromSuggestions: Bool {
        UserDefaults.standard.object(forKey: Self.fillFromSuggestionsKey) as? Bool ?? true
    }

    typealias Loaded = ([SavedLogin]?, [SavedPasskey]?, ([PasswordRecipe], Set<UUID>))

    /// `loaded` from `load()` skips the Keychain reads, so a caller can make them off main
    init(loaded: Loaded? = nil, profileExists: @escaping (UUID) -> Bool) {
        self.profileExists = profileExists
        let loaded = loaded ?? Self.load()
        isUnreadable = loaded.0 == nil || loaded.1 == nil
        (recipes, unreadableRecipes) = loaded.2
        logins = (loaded.0 ?? []).sorted(by: Self.loginOrder)
        passkeys = (loaded.1 ?? []).sorted { ($0.rpID, $0.userName) < ($1.rpID, $1.userName) }
    }

    nonisolated static func load() -> Loaded {
        queue.sync {
            (index(Keychain.passwords, SavedLogin.self), index(Keychain.passkeys, SavedPasskey.self), storedRecipes())
        }
    }

    private nonisolated static func loginOrder(_ a: SavedLogin, _ b: SavedLogin) -> Bool {
        (a.host, a.username) < (b.host, b.username)
    }

    /// Only what the index lists is trusted; nil when it is there but unreadable. A missing index is
    /// restored from `nextIndex`; with neither, items still carrying `kSecAttrGeneric` metadata are
    /// migrated into one, and lose that metadata only once the index holds it.
    nonisolated static func index<T: Codable>(_ service: String, _: T.Type) -> [T]? {
        let decoder = JSONDecoder()
        var stored = Keychain.read(service, Keychain.index)
        if stored.status == errSecItemNotFound {
            stored = Keychain.read(service, Keychain.nextIndex)
            if let data = stored.data, Keychain.put(service, Keychain.index, data) == errSecSuccess {
                Keychain.delete(service, Keychain.nextIndex)
            }
        }
        guard stored.status == errSecItemNotFound else {
            return stored.data.flatMap { try? decoder.decode([T].self, from: $0) }
        }
        let legacy = Keychain.legacy(service).compactMap { account, meta -> (String, T, Data)? in
            guard let value = try? decoder.decode(T.self, from: meta), let data = Keychain.secret(service, account)
            else { return nil }
            return (account, value, data)
        }
        let migrated = legacy.map(\.1)
        guard !legacy.isEmpty, let data = try? JSONEncoder().encode(migrated),
            Keychain.put(service, Keychain.index, data) == errSecSuccess
        else { return migrated }
        for (account, _, secret) in legacy { Keychain.put(service, account, secret) }
        return migrated
    }

    /// The index goes after the items it names, so a crash leaves an orphan rather than a hole, and
    /// through `nextIndex`, so a complete index exists at every moment. Nothing is deleted unless
    /// the new index was kept.
    private func persist(_ service: String, writing items: [(String, Data)] = [], deleting gone: [String] = []) {
        guard !isUnreadable else { return }
        let index: Data? =
            service == Keychain.passwords ? try? JSONEncoder().encode(logins) : try? JSONEncoder().encode(passkeys)
        Self.queue.async {
            for (account, data) in items { Keychain.put(service, account, data) }
            guard let index, Keychain.put(service, Keychain.nextIndex, index) == errSecSuccess,
                Keychain.put(service, Keychain.index, index) == errSecSuccess
            else { return }
            Keychain.delete(service, Keychain.nextIndex)
            for account in gone { Keychain.delete(service, account) }
        }
    }

    /// returns once every queued Keychain write has landed, for `applicationWillTerminate`
    nonisolated static func saveNow() { queue.sync {} }

    // MARK: - Logins

    func password(for login: SavedLogin) -> String? {
        Self.queue.sync { Keychain.secret(Keychain.passwords, login.id.uuidString) }
            .flatMap { String(data: $0, encoding: .utf8) }
    }

    /// each login with its password and code setup, read in one job on `queue`; a login whose password
    /// is gone is left out
    func secrets(of logins: [SavedLogin]) async -> [(login: SavedLogin, password: String, code: String?)] {
        await withCheckedContinuation { continuation in
            Self.queue.async {
                func text(_ account: String) -> String? {
                    Keychain.secret(Keychain.passwords, account).flatMap { String(data: $0, encoding: .utf8) }
                }
                continuation.resume(
                    returning: logins.compactMap { login in
                        text(login.id.uuidString).map {
                            (login, $0, login.hasOneTimeCode == true ? text(Keychain.code(login.id)) : nil)
                        }
                    })
            }
        }
    }

    func logins(in profile: UUID) -> [SavedLogin] { logins.filter { owner($0.profile) == profile } }

    func passkeys(in profile: UUID) -> [SavedPasskey] { passkeys.filter { owner($0.profile) == profile } }

    /// a profile this install doesn't have (a restored backup, an older build's
    /// rewrite) hands its logins to the default one rather than hiding them
    private func owner(_ profile: UUID) -> UUID {
        profileExists(profile) ? profile : Profile.defaultID
    }

    /// the profile's logins for exactly this origin, then for its www. twin
    func matches(for origin: String, in profile: UUID) -> [SavedLogin] {
        let recent = { (a: SavedLogin, b: SavedLogin) in (a.lastUsed ?? a.updated) > (b.lastUsed ?? b.updated) }
        let twin = Self.wwwTwin(origin)
        let own = logins(in: profile)
        return own.filter { $0.origin == origin }.sorted(by: recent)
            + own.filter { $0.origin == twin }.sorted(by: recent)
    }

    /// `https://www.example.com` ↔ `https://example.com`
    nonisolated static func wwwTwin(_ origin: String) -> String {
        origin.contains("://www.")
            ? origin.replacingOccurrences(of: "://www.", with: "://")
            : origin.replacingOccurrences(of: "://", with: "://www.")
    }

    /// adds, or replaces the password of the login with the same origin and username
    @discardableResult
    func save(origin: String, username: String, password: String, in profile: UUID) -> SavedLogin {
        let now = Date()
        var login =
            logins(in: profile).first { $0.origin == origin && $0.username == username }
            ?? SavedLogin(
                id: UUID(), origin: origin, username: username, created: now, updated: now,
                profileID: Self.stored(profile))
        login.updated = now
        login.lastUsed = now
        replace(login, password: password)
        return login
    }

    /// `login` is found again by id, so a caller's older copy reverts nothing; a deleted one stays deleted
    func edit(
        _ login: SavedLogin, username: String, password: String?, notes: String? = nil,
        otherNames: [String]? = nil
    ) {
        guard var changed = logins.first(where: { $0.id == login.id }) else { return }
        changed.username = username
        if let notes { changed.notes = notes.isEmpty ? nil : notes }
        if let otherNames { changed.otherNames = otherNames.isEmpty ? nil : otherNames }
        changed.updated = Date()
        replace(changed, password: password)
    }

    func markUsed(_ login: SavedLogin) {
        guard var used = logins.first(where: { $0.id == login.id }) else { return }
        used.lastUsed = Date()
        replace(used, password: nil)
    }

    private func replace(_ login: SavedLogin, password: String?) {
        logins.removeAll { $0.id == login.id }
        logins.append(login)
        logins.sort(by: Self.loginOrder)
        persist(Keychain.passwords, writing: password.map { [(login.id.uuidString, Data($0.utf8))] } ?? [])
    }

    func delete(_ login: SavedLogin) {
        logins.removeAll { $0.id == login.id }
        persist(Keychain.passwords, deleting: [login.id.uuidString, Keychain.code(login.id)])
    }

    // MARK: - Verification codes

    func oneTimeCode(for login: SavedLogin) -> OneTimeCode? {
        guard logins.first(where: { $0.id == login.id })?.hasOneTimeCode == true else { return nil }
        return Self.queue.sync { Keychain.secret(Keychain.passwords, Keychain.code(login.id)) }
            .flatMap { String(data: $0, encoding: .utf8) }.flatMap(OneTimeCode.init)
    }

    /// nil removes it
    func setOneTimeCode(_ code: OneTimeCode?, for login: SavedLogin) {
        guard let stored = logins.first(where: { $0.id == login.id }) else { return }
        let account = Keychain.code(login.id)
        logins.removeAll { $0.id == login.id }
        var changed = stored
        changed.hasOneTimeCode = code == nil ? nil : true
        changed.updated = Date()
        logins.append(changed)
        logins.sort(by: Self.loginOrder)
        if let code {
            persist(Keychain.passwords, writing: [(account, Data(code.setup.utf8))])
        } else {
            persist(Keychain.passwords, deleting: [account])
        }
    }

    /// the profile's logins with codes on any subdomain of `origin`'s registrable domain,
    /// most recently used first
    func codeMatches(for origin: String, in profile: UUID) -> [SavedLogin] {
        guard Self.isSecure(origin), let host = URL(string: origin)?.host() else { return [] }
        let site = Self.registrableDomain(host) ?? host
        return logins(in: profile).filter {
            $0.hasOneTimeCode == true && Self.isSecure($0.origin) && (Self.registrableDomain($0.host) ?? $0.host) == site
        }
        .sorted { ($0.lastUsed ?? $0.updated) > ($1.lastUsed ?? $1.updated) }
    }

    func setNeverSave(_ host: String, _ never: Bool) {
        neverSave.removeAll { $0 == host }
        if never { neverSave.append(host) }
        UserDefaults.standard.set(neverSave, forKey: Self.neverSaveKey)
    }

    // MARK: - Recipes

    func recipes(in profile: UUID) -> [PasswordRecipe] { recipes.filter { owner($0.profile) == profile } }

    /// adds, or replaces the recipe with the same id
    func save(_ recipe: PasswordRecipe) {
        if let i = recipes.firstIndex(where: { $0.id == recipe.id }) {
            recipes[i] = recipe
        } else {
            recipes.append(recipe)
        }
        persistRecipes(of: recipe.profile)
    }

    func delete(_ recipe: PasswordRecipe) {
        recipes.removeAll { $0.id == recipe.id }
        persistRecipes(of: recipe.profile)
    }

    /// every profile's recipes, and the profiles whose item is there but unreadable
    private nonisolated static func storedRecipes() -> ([PasswordRecipe], Set<UUID>) {
        var all: [PasswordRecipe] = []
        var unreadable: Set<UUID> = []
        for account in Keychain.accounts(Keychain.passwords) where account.hasPrefix("recipes.") {
            guard let profile = UUID(uuidString: String(account.dropFirst("recipes.".count))) else { continue }
            guard let data = Keychain.secret(Keychain.passwords, account),
                let recipes = try? JSONDecoder().decode([PasswordRecipe].self, from: data)
            else {
                unreadable.insert(profile)
                continue
            }
            all += recipes
        }
        return (all, unreadable)
    }

    /// rewrites one profile's item, or deletes it once the profile has none
    private func persistRecipes(of profile: UUID) {
        guard !isUnreadable, !unreadableRecipes.contains(profile) else { return }
        let account = Keychain.recipes(profile)
        let own = recipes.filter { $0.profile == profile }
        let data = own.isEmpty ? nil : try? JSONEncoder().encode(own)
        Self.queue.async {
            if let data { Keychain.put(Keychain.passwords, account, data) } else { Keychain.delete(Keychain.passwords, account) }
        }
    }

    // MARK: - Passkeys

    func passkeyKey(_ passkey: SavedPasskey) -> Data? {
        Self.queue.sync { Keychain.secret(Keychain.passkeys, passkey.id) }
    }

    /// The new key is written and read back before the credential it replaces (same relying
    /// party and user handle) is removed; false when the Keychain didn't keep it.
    func add(_ passkey: SavedPasskey, key: Data) -> Bool {
        guard !isUnreadable else { return false }
        let kept = Self.queue.sync {
            Keychain.put(Keychain.passkeys, passkey.id, key) == errSecSuccess
                && Keychain.secret(Keychain.passkeys, passkey.id) == key
        }
        guard kept else { return false }
        let replaced = passkeys.filter {
            $0.rpID == passkey.rpID && $0.userHandle == passkey.userHandle && $0.profile == passkey.profile
        }
        passkeys.removeAll { old in replaced.contains { $0.id == old.id } }
        passkeys.append(passkey)
        passkeys.sort { ($0.rpID, $0.userName) < ($1.rpID, $1.userName) }
        persist(Keychain.passkeys, deleting: replaced.map(\.id))
        return true
    }

    func delete(_ passkey: SavedPasskey) {
        passkeys.removeAll { $0.id == passkey.id }
        persist(Keychain.passkeys, deleting: [passkey.id])
    }

    /// a deleted profile takes its logins, codes, passkeys and recipes with it
    func deleteAll(in profile: UUID) {
        let doomed = logins.filter { $0.profile == profile }
        if !doomed.isEmpty {
            logins.removeAll { $0.profile == profile }
            persist(Keychain.passwords, deleting: doomed.flatMap { [$0.id.uuidString, Keychain.code($0.id)] })
        }
        let keys = passkeys.filter { $0.profile == profile }
        if !keys.isEmpty {
            passkeys.removeAll { $0.profile == profile }
            persist(Keychain.passkeys, deleting: keys.map(\.id))
        }
        recipes.removeAll { $0.profile == profile }
        persistRecipes(of: profile)
    }

    /// what a record stores for `profile`: the default profile is nil, as before profiles
    nonisolated static func stored(_ profile: UUID) -> UUID? {
        profile == Profile.defaultID ? nil : profile
    }

    // MARK: - Sites

    typealias SuffixCheck = @convention(c) (CFString) -> DarwinBoolean
    /// CFNetwork's copy of the Public Suffix List, ICANN and private sections with their wildcards
    /// and exceptions: the one WebKit reads. Looked up in every loaded image (RTLD_DEFAULT).
    nonisolated static let isPublicSuffix = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_CFHostIsDomainTopLevel")
        .map { unsafeBitCast($0, to: SuffixCheck.self) }

    /// The site boundary for passkey rpIds, verification codes, recipes and Settings' grouping: one
    /// label more than the longest public suffix, or than the last label when none is listed. Nil for
    /// a public suffix, a bare label, or an IP address.
    nonisolated static func registrableDomain(_ host: String) -> String? {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !isIPAddress(host) else { return nil }
        let labels = host.split(separator: ".")
        let suffix =
            labels.indices.first { isPublicSuffix?(labels[$0...].joined(separator: ".") as CFString).boolValue == true }
            ?? labels.count - 1
        guard suffix > 0 else { return nil }
        return labels[(suffix - 1)...].joined(separator: ".")
    }

    nonisolated static func isIPAddress(_ host: String) -> Bool {
        host.contains(":") || (!host.isEmpty && host.allSatisfy { $0.isNumber || $0 == "." })
    }

    /// https anywhere, http only on the loopback host
    nonisolated static func isSecure(_ origin: String) -> Bool {
        guard let url = URL(string: origin), let host = url.host() else { return false }
        return url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1"].contains(host))
    }

    // MARK: - CSV

    nonisolated struct ImportSummary: Sendable {
        var added = 0
        var updated = 0
        var skipped = 0
    }

    /// one CSV row worth importing
    private nonisolated struct ImportRow: Sendable {
        let origin: String
        let username: String
        let password: String
        let code: Data?
    }

    /// Chromium-family, Firefox, Safari, Bitwarden and 1Password exports, told apart by header
    /// names; nil when the header has no url or password column, or the store is unreadable. Each
    /// row is its own job on `queue`, so a read made meanwhile waits for one row, not the file.
    func importCSV(_ text: String, into profile: UUID) async -> ImportSummary? {
        guard !isUnreadable, let rows = Self.importRows(Self.parseCSV(text)) else { return nil }
        var summary = ImportSummary()
        for row in rows {
            guard let row else {
                summary.skipped += 1
                continue
            }
            let existing = logins(in: profile).first { $0.origin == row.origin && $0.username == row.username }
            let written = await withCheckedContinuation { continuation in
                Self.queue.async { continuation.resume(returning: Self.write(row, over: existing, in: profile)) }
            }
            if let written, existing == nil {
                logins.append(written)
                summary.added += 1
            } else if let written, let i = logins.firstIndex(where: { $0.id == written.id }) {
                // only what the import changed, over whatever was edited while it ran
                logins[i].updated = written.updated
                if written.hasOneTimeCode == true { logins[i].hasOneTimeCode = true }
                summary.updated += 1
            } else {
                summary.skipped += 1
            }
        }
        logins.sort(by: Self.loginOrder)
        persist(Keychain.passwords)
        return summary
    }

    /// the data rows of an export, nil for each one without a password or a web address; nil when the
    /// header names no url or password column
    nonisolated private static func importRows(_ table: [[String]]) -> [ImportRow?]? {
        guard let first = table.first else { return nil }
        let header = first.map {
            $0.replacingOccurrences(of: "\u{FEFF}", with: "").trimmingCharacters(in: .whitespaces).lowercased()
        }
        func column(_ names: [String]) -> Int? { names.lazy.compactMap { header.firstIndex(of: $0) }.first }
        guard
            let urlColumn = column([
                "url", "login_uri", "website", "web site", "login url", "uri", "origin", "hostname",
            ]),
            let passwordColumn = column(["password", "login_password"])
        else { return nil }
        let userColumn = column([
            "username", "login_username", "user name", "login name", "login", "email", "e-mail",
        ])
        let codeColumn = column(["otpauth", "login_totp", "totp", "otp", "one-time password"])
        return table.dropFirst().filter { $0.contains { !$0.isEmpty } }.map { row in
            func cell(_ index: Int?) -> String {
                guard let index, index < row.count else { return "" }
                return row[index].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            // Bitwarden can list several URIs in one cell
            var address = cell(urlColumn).split(whereSeparator: { $0 == "," || $0 == "\n" }).first
                .map(String.init) ?? ""
            if !address.contains("://") { address = "https://" + address }
            let password = row.indices.contains(passwordColumn) ? row[passwordColumn] : ""
            guard !password.isEmpty, let origin = SitePermissionStore.originString(URL(string: address)),
                origin.hasPrefix("http")
            else { return nil }
            return ImportRow(
                origin: origin, username: cell(userColumn), password: password,
                code: OneTimeCode(cell(codeColumn)).map { Data($0.setup.utf8) })
        }
    }

    /// one row's Keychain writes, on `queue`: the login to index, flagged for a code only when this row
    /// wrote one; nil when the row changes nothing or the Keychain refused it
    nonisolated private static func write(_ row: ImportRow, over existing: SavedLogin?, in profile: UUID) -> SavedLogin? {
        let now = Date()
        let password = Data(row.password.utf8)
        guard var login = existing else {
            var login = SavedLogin(
                id: UUID(), origin: row.origin, username: row.username, created: now, updated: now,
                profileID: stored(profile))
            guard Keychain.put(Keychain.passwords, login.id.uuidString, password) == errSecSuccess else { return nil }
            if let code = row.code, Keychain.put(Keychain.passwords, Keychain.code(login.id), code) == errSecSuccess {
                login.hasOneTimeCode = true
            }
            return login
        }
        let samePassword = Keychain.secret(Keychain.passwords, login.id.uuidString) == password
        let sameCode = row.code == nil || Keychain.secret(Keychain.passwords, Keychain.code(login.id)) == row.code
        guard !samePassword || !sameCode else { return nil }
        login.updated = now
        login.hasOneTimeCode = nil
        if !samePassword { Keychain.put(Keychain.passwords, login.id.uuidString, password) }
        if let code = row.code, !sameCode, Keychain.put(Keychain.passwords, Keychain.code(login.id), code) == errSecSuccess {
            login.hasOneTimeCode = true
        }
        return login
    }

    /// RFC 4180: quoted fields may hold commas, doubled quotes and line breaks
    nonisolated static func parseCSV(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var pendingQuote = false
        for c in text {
            if quoted {
                if pendingQuote {
                    pendingQuote = false
                    if c == "\"" {
                        field.append(c)
                        continue
                    }
                    quoted = false
                } else if c == "\"" {
                    pendingQuote = true
                    continue
                } else {
                    field.append(c)
                    continue
                }
            }
            switch c {
            case "\"" where field.isEmpty: quoted = true
            case ",":
                row.append(field)
                field = ""
            case "\n", "\r\n", "\r":
                row.append(field)
                field = ""
                rows.append(row)
                row = []
            default: field.append(c)
            }
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }

    /// Chrome's export shape, which every password manager reads, with an `otpauth` column
    /// when any row has a code
    nonisolated static func csv(
        _ rows: [(name: String, url: String, username: String, password: String, code: String)]
    ) -> String {
        func field(_ text: String) -> String { "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        let codes = rows.contains { !$0.code.isEmpty }
        let lines = rows.map {
            ([$0.name, $0.url, $0.username, $0.password] + (codes ? [$0.code] : [])).map(field).joined(separator: ",")
        }
        return ([codes ? "name,url,username,password,otpauth" : "name,url,username,password"] + lines)
            .joined(separator: "\n") + "\n"
    }
}
