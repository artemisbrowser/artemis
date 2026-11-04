// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import CryptoKit
import Foundation

/// The CBOR WebAuthn needs: maps, integers, byte and text strings.
/// Maps encode in the order given, so callers list keys in CTAP2 canonical order.
nonisolated indirect enum CBOR {
    case int(Int)
    case bytes(Data)
    case text(String)
    case map([(CBOR, CBOR)])

    var encoded: Data {
        switch self {
        case .int(let n): n >= 0 ? Self.head(0, UInt64(n)) : Self.head(1, UInt64(-1 - n))
        case .bytes(let data): Self.head(2, UInt64(data.count)) + data
        case .text(let text): Self.head(3, UInt64(text.utf8.count)) + Data(text.utf8)
        case .map(let pairs):
            pairs.reduce(Self.head(5, UInt64(pairs.count))) { $0 + $1.0.encoded + $1.1.encoded }
        }
    }

    private static func head(_ major: UInt8, _ value: UInt64) -> Data {
        let type = major << 5
        switch value {
        case ..<24: return Data([type | UInt8(value)])
        case ..<0x100: return Data([type | 24, UInt8(value)])
        case ..<0x10000: return Data([type | 25]) + bigEndian(value, 2)
        case ..<0x1_0000_0000: return Data([type | 26]) + bigEndian(value, 4)
        default: return Data([type | 27]) + bigEndian(value, 8)
        }
    }

    static func bigEndian(_ value: UInt64, _ bytes: Int) -> Data {
        Data((0..<bytes).reversed().map { UInt8(truncatingIfNeeded: value >> (8 * UInt64($0))) })
    }
}

/// A software platform authenticator: ES256 keys, "none" attestation, sign count held at 0.
nonisolated enum Passkeys {
    /// identifies Artemis to relying parties that map authenticator models
    static let aaguid = Data([
        0x7a, 0x1d, 0x3e, 0x52, 0x9b, 0x04, 0x4c, 0x61, 0xa8, 0x2f, 0x5e, 0x13, 0xc6, 0x90, 0x47, 0xd8,
    ])
    static let userPresent: UInt8 = 0x01
    static let userVerified: UInt8 = 0x04
    static let attestedData: UInt8 = 0x40

    /// An rpId (lowercase) is the caller's host or a registrable suffix of it: never a public
    /// suffix, never an IP address.
    static func isValid(rpID: String, for host: String) -> Bool {
        let host = host.lowercased()
        guard !PasswordStore.isIPAddress(rpID), !PasswordStore.isIPAddress(host) else { return false }
        return rpID == host || (host.hasSuffix("." + rpID) && PasswordStore.registrableDomain(rpID) != nil)
    }

    /// serialised in the spec's field order, which relying parties may match byte for byte;
    /// only top-level documents run ceremonies, so `crossOrigin` is always false
    static func clientDataJSON(type: String, challenge: String, origin: String) -> Data {
        func quoted(_ text: String) -> String {
            let data = try? JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed, .withoutEscapingSlashes])
            return data.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
        }
        return Data(
            "{\"type\":\(quoted(type)),\"challenge\":\(quoted(challenge)),\"origin\":\(quoted(origin)),\"crossOrigin\":false}"
                .utf8)
    }

    /// `x || y`, 32 bytes each, as `P256...PublicKey.rawRepresentation` gives them
    static func coseKey(_ raw: Data) -> Data {
        CBOR.map([
            (.int(1), .int(2)), (.int(3), .int(-7)), (.int(-1), .int(1)),
            (.int(-2), .bytes(raw.prefix(32))), (.int(-3), .bytes(raw.suffix(32))),
        ]).encoded
    }

    /// `SHA256(rpId) || flags || signCount(4) [|| AAGUID || credIdLen(2) || credId || COSE key]`
    static func authenticatorData(rpID: String, verified: Bool, credential: (id: Data, publicKey: Data)? = nil) -> Data {
        var flags = userPresent | (verified ? userVerified : 0)
        if credential != nil { flags |= attestedData }
        var data = Data(SHA256.hash(data: Data(rpID.utf8))) + [flags] + CBOR.bigEndian(0, 4)
        if let credential {
            data += aaguid + CBOR.bigEndian(UInt64(credential.id.count), 2) + credential.id
                + coseKey(credential.publicKey)
        }
        return data
    }

    static func attestationObject(_ authData: Data) -> Data {
        CBOR.map([
            (.text("fmt"), .text("none")), (.text("attStmt"), .map([])), (.text("authData"), .bytes(authData)),
        ]).encoded
    }

    /// a new key: the Secure Enclave's when it will make one, else software
    static func makeKey() -> (blob: Data, enclave: Bool, publicKey: P256.Signing.PublicKey) {
        if SecureEnclave.isAvailable, let key = try? SecureEnclave.P256.Signing.PrivateKey() {
            return (key.dataRepresentation, true, key.publicKey)
        }
        let key = P256.Signing.PrivateKey()
        return (key.rawRepresentation, false, key.publicKey)
    }

    static func publicKey(blob: Data, enclave: Bool) throws -> P256.Signing.PublicKey {
        enclave
            ? try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: blob).publicKey
            : try P256.Signing.PrivateKey(rawRepresentation: blob).publicKey
    }

    /// DER ECDSA over `authData || SHA256(clientDataJSON)`
    static func sign(authData: Data, clientData: Data, blob: Data, enclave: Bool) throws -> Data {
        let message = authData + Data(SHA256.hash(data: clientData))
        return enclave
            ? try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: blob).signature(for: message)
                .derRepresentation
            : try P256.Signing.PrivateKey(rawRepresentation: blob).signature(for: message).derRepresentation
    }
}

extension Data {
    nonisolated var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    nonisolated init?(base64URL text: String) {
        var base = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base += String(repeating: "=", count: (4 - base.count % 4) % 4)
        self.init(base64Encoded: base)
    }
}
