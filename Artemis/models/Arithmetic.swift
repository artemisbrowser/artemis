import Foundation

/// `+ - * / ^ %` and parentheses over decimals; `×` and `÷` read as `*` and `/`.
/// nil unless the whole input (≤200 chars, bounding recursion) parses and has an operator
nonisolated struct Arithmetic {
    private let chars: [Character]
    private var at = 0

    static func evaluate(_ input: String) -> Double? {
        let text = input.filter { $0 != " " }
            .replacingOccurrences(of: "×", with: "*").replacingOccurrences(of: "÷", with: "/")
        guard text.count <= 200, Double(text) == nil, text.contains(where: \.isNumber),
            text.allSatisfy({ "0123456789.+-*/^%()".contains($0) })
        else { return nil }
        var parser = Arithmetic(chars: Array(text))
        guard let value = parser.sum(), parser.at == parser.chars.count, value.isFinite else { return nil }
        return value
    }

    private init(chars: [Character]) { self.chars = chars }

    private func peek(_ c: Character) -> Bool { at < chars.count && chars[at] == c }

    private mutating func sum() -> Double? {
        guard var value = product() else { return nil }
        while peek("+") || peek("-") {
            let plus = peek("+")
            at += 1
            guard let rhs = product() else { return nil }
            value = plus ? value + rhs : value - rhs
        }
        return value
    }

    private mutating func product() -> Double? {
        guard var value = power() else { return nil }
        while peek("*") || peek("/") {
            let times = peek("*")
            at += 1
            guard let rhs = power() else { return nil }
            value = times ? value * rhs : value / rhs
        }
        return value
    }

    /// right-associative: 2^3^2 is 2^9
    private mutating func power() -> Double? {
        guard let base = unary() else { return nil }
        guard peek("^") else { return base }
        at += 1
        return power().map { pow(base, $0) }
    }

    private mutating func unary() -> Double? {
        if peek("-") {
            at += 1
            return unary().map { -$0 }
        }
        guard var value = atom() else { return nil }
        while peek("%") {
            value /= 100
            at += 1
        }
        return value
    }

    private mutating func atom() -> Double? {
        if peek("(") {
            at += 1
            guard let value = sum(), peek(")") else { return nil }
            at += 1
            return value
        }
        let start = at
        while at < chars.count, chars[at].isNumber || chars[at] == "." { at += 1 }
        return Double(String(chars[start..<at]))
    }
}
