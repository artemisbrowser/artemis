// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import CommonCrypto
import CryptoKit
import Foundation

/// Reading what a Chromium-family browser sealed: one keychain passphrase derives
/// the AES key for every cookie value and saved password. The keychain prompt is
/// the user's consent, and nothing is decrypted without it.
nonisolated enum BrowserKeychain {
    /// Chromium's fixed derivation parameters on macOS
    private static let salt = "saltysalt"
    private static let rounds: UInt32 = 1003
    private static let keyLength = kCCKeySizeAES128
    /// sixteen spaces — Chromium's constant IV
    private static let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
    /// marks a value sealed with the keychain key
    private static let version = Data("v10".utf8)

    enum Failure: Error {
        /// no keychain item, or the user said no at the prompt
        case noKey
        case badCiphertext
    }

    /// The AES key; this call raises the prompt, so fetch it once per run. A refusal
    /// ends the lookup. Only when every candidate is missing are item attributes
    /// (no prompt) searched for a `… Safe Storage`/`… Storage Key` naming `browser`.
    static func key(for candidates: [KeychainItem], browser: String) throws -> Data {
        guard !ExtensionLab.isRequested else { throw Failure.noKey }
        for candidate in candidates {
            switch passphrase(candidate) {
            case .success(let secret): return try derive(from: secret)
            case .failure(.missing): continue
            case .failure(.refused): throw Failure.noKey
            }
        }
        guard let found = search(browser), case .success(let secret) = passphrase(found) else {
            throw Failure.noKey
        }
        return try derive(from: secret)
    }

    private enum Lookup: Error { case missing, refused }

    private static func passphrase(_ item: KeychainItem) -> Result<Data, Lookup> {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: item.service,
            kSecReturnData as String: true,
        ]
        if let account = item.account { query[kSecAttrAccount as String] = account }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status != errSecItemNotFound else { return .failure(.missing) }
        guard status == errSecSuccess, let secret = result as? Data else { return .failure(.refused) }
        return .success(secret)
    }

    /// attributes only, so no prompt
    private static func search(_ browser: String) -> KeychainItem? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
            let items = result as? [[String: Any]]
        else { return nil }
        let name = browser.lowercased()
        for item in items {
            guard let service = item[kSecAttrService as String] as? String,
                service.hasSuffix(" Safe Storage") || service.hasSuffix(" Storage Key")
            else { continue }
            let account = item[kSecAttrAccount as String] as? String
            guard service.lowercased().contains(name) || account?.lowercased().contains(name) == true
            else { continue }
            return KeychainItem(service: service, account: account)
        }
        return nil
    }

    /// PBKDF2-SHA1 over the keychain passphrase
    private static func derive(from passphrase: Data) throws -> Data {
        var key = [UInt8](repeating: 0, count: keyLength)
        let saltBytes = [UInt8](salt.utf8)
        let status = passphrase.withUnsafeBytes { raw in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2),
                raw.baseAddress?.assumingMemoryBound(to: CChar.self), passphrase.count,
                saltBytes, saltBytes.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), rounds,
                &key, keyLength)
        }
        // a failed derivation leaves the buffer zeroed, which would look like a
        // perfectly good key and unseal nothing
        guard status == kCCSuccess else { throw Failure.noKey }
        return Data(key)
    }

    /// The plaintext bytes of one `v10` blob, or nil when it isn't one or won't open.
    static func open(_ sealed: Data, key: Data) -> Data? {
        guard sealed.count > version.count, sealed.starts(with: version) else { return nil }
        let body = sealed.dropFirst(version.count)
        var out = [UInt8](repeating: 0, count: body.count + kCCBlockSizeAES128)
        var written = 0
        let status = body.withUnsafeBytes { input in
            key.withUnsafeBytes { keyBytes in
                CCCrypt(
                    CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES128),
                    CCOptions(kCCOptionPKCS7Padding),
                    keyBytes.baseAddress, keyLength,
                    iv,
                    input.baseAddress, body.count,
                    &out, out.count, &written)
            }
        }
        guard status == kCCSuccess else { return nil }
        return Data(out.prefix(written))
    }

    /// Unseal one value. `host` is only used for cookies: current Chromium
    /// prepends a SHA-256 of the cookie's domain to the plaintext, and that
    /// prefix is not part of the value.
    static func decrypt(_ sealed: Data, key: Data, host: String? = nil) throws -> String {
        guard sealed.count > version.count, sealed.starts(with: version) else {
            // an unsealed value (Chromium writes plaintext when it has no
            // keychain) is already the answer
            if let text = String(data: sealed, encoding: .utf8) { return text }
            throw Failure.badCiphertext
        }
        guard var plain = open(sealed, key: key) else { throw Failure.badCiphertext }
        if let host, plain.count >= 32,
            plain.prefix(32) == Data(SHA256.hash(data: Data(host.utf8)))
        {
            plain = plain.dropFirst(32)
        }
        guard let text = String(data: plain, encoding: .utf8) else { throw Failure.badCiphertext }
        return text
    }
}
