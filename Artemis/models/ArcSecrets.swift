// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import CommonCrypto
import CryptoKit
import Foundation

/// Reading what Arc encrypted.
///
/// Chromium keeps one random passphrase in the login keychain and derives an
/// AES key from it; every cookie value and saved password is sealed with that
/// key. Reading them needs the user's consent at the keychain prompt — that
/// prompt *is* the permission model here, and nothing is decrypted without it.
nonisolated enum ArcSecrets {
    /// the keychain item Arc writes — service "Arc Safe Storage", account "Arc" —
    /// and the looser matches to fall back on
    private static let candidates: [(service: String, account: String?)] = [
        ("Arc Safe Storage", "Arc"), ("Arc Safe Storage", nil), ("Arc", "Arc"),
    ]

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

    /// The AES key, straight from the keychain.
    ///
    /// `SecItemCopyMatching` is what raises the system prompt, so this is the
    /// call the user is consenting to. Fetch it once and pass it down: asking
    /// per cookie would raise the prompt thousands of times.
    static func key() throws -> Data {
        guard !ExtensionLab.isRequested else { throw Failure.noKey }
        for candidate in candidates {
            var query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: candidate.service,
                kSecReturnData as String: true,
            ]
            if let account = candidate.account { query[kSecAttrAccount as String] = account }
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            // a refusal at the prompt ends it: the looser candidates match the same item
            guard status != errSecItemNotFound else { continue }
            guard status == errSecSuccess, let passphrase = item as? Data else { throw Failure.noKey }
            return try derive(from: passphrase)
        }
        throw Failure.noKey
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

    /// Unseal one value. `host` is only used for cookies: current Chromium
    /// prepends a SHA-256 of the cookie's domain to the plaintext, and that
    /// prefix is not part of the value.
    static func decrypt(_ sealed: Data, key: Data, host: String? = nil) throws -> String {
        guard sealed.count > version.count, sealed.prefix(version.count) == version else {
            // an unsealed value (Chromium writes plaintext when it has no
            // keychain) is already the answer
            if let text = String(data: sealed, encoding: .utf8) { return text }
            throw Failure.badCiphertext
        }
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
        guard status == kCCSuccess else { throw Failure.badCiphertext }
        var plain = Data(out.prefix(written))
        if let host, plain.count >= 32,
            plain.prefix(32) == Data(SHA256.hash(data: Data(host.utf8)))
        {
            plain = plain.dropFirst(32)
        }
        guard let text = String(data: plain, encoding: .utf8) else { throw Failure.badCiphertext }
        return text
    }
}
