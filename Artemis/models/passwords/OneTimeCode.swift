import CryptoKit
import Foundation

/// RFC 6238 verification codes from an `otpauth://totp/` link or a bare base32 setup key
nonisolated struct OneTimeCode: Hashable {
    enum Algorithm: String { case sha1 = "SHA1", sha256 = "SHA256", sha512 = "SHA512" }

    /// the link or key as given; what the Keychain holds and an export writes
    let setup: String
    let secret: Data
    let digits: Int
    /// seconds each code lasts
    let period: Int
    let algorithm: Algorithm

    init?(_ text: String) {
        setup = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var key = setup
        var items: [String: String] = [:]
        if setup.lowercased().hasPrefix("otpauth://") {
            guard let parts = URLComponents(string: setup), parts.host?.lowercased() == "totp" else { return nil }
            items = Dictionary(
                (parts.queryItems ?? []).map { ($0.name.lowercased(), $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
            key = items["secret"] ?? ""
        }
        digits = items["digits"].flatMap { Int($0) } ?? 6
        period = items["period"].flatMap { Int($0) } ?? 30
        algorithm = items["algorithm"].flatMap { Algorithm(rawValue: $0.uppercased()) } ?? .sha1
        guard (6...8).contains(digits), (1...300).contains(period), let secret = Self.base32(key), secret.count >= 10
        else { return nil }
        self.secret = secret
    }

    /// RFC 4648, any case, ignoring spaces, hyphens and padding
    static func base32(_ text: String) -> Data? {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var out = Data()
        var buffer = 0
        var bits = 0
        for c in text.uppercased() where !" -=".contains(c) {
            guard let value = alphabet.firstIndex(of: c) else { return nil }
            buffer = buffer << 5 | value
            bits += 5
            if bits >= 8 {
                bits -= 8
                out.append(UInt8(truncatingIfNeeded: buffer >> bits))
                buffer &= (1 << bits) - 1
            }
        }
        return out
    }

    func code(at date: Date = Date()) -> String {
        let counter = UInt64(date.timeIntervalSince1970) / UInt64(period)
        let message = withUnsafeBytes(of: counter.bigEndian) { Data($0) }
        let key = SymmetricKey(data: secret)
        let mac =
            switch algorithm {
            case .sha1: Data(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: key))
            case .sha256: Data(HMAC<SHA256>.authenticationCode(for: message, using: key))
            case .sha512: Data(HMAC<SHA512>.authenticationCode(for: message, using: key))
            }
        let offset = Int(mac[mac.count - 1] & 0x0f)
        let number = mac[offset..<offset + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) } & 0x7fff_ffff
        let modulus = (0..<digits).reduce(UInt32(1)) { a, _ in a * 10 }
        let digitsText = String(number % modulus)
        return String(repeating: "0", count: digits - digitsText.count) + digitsText
    }

    func secondsLeft(at date: Date = Date()) -> Int {
        period - Int(date.timeIntervalSince1970) % period
    }
}
