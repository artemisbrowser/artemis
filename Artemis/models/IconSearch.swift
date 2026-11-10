// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import Foundation

/// ranks the picker's icons (curated SF Symbols, every emoji) against free text
/// by meaning: name words, Apple/CLDR keywords, lemmas and on-device word
/// embeddings, so "home" finds the house and "gym" the dumbbell
actor IconSearch {
    static let shared = IconSearch()

    private struct Icon {
        let id: String
        let isEmoji: Bool
        let name: [Int]  // indices into `meaning.vocab`
        let parts: [Int]  // halves of run-together symbol words
        let tags: [Int]
        let rawName: String
        /// matches only a typed substring of its name, never by meaning (flags: "cooking" isn't the Cook Islands)
        var literal = false
    }

    private let meaning = WordMeaning()
    private var icons: [Icon] = []

    private static let modifiers: Set<String> = [
        "fill", "circle", "square", "rectangle", "and", "the", "of", "with", "on", "in", "for",
        "to", "left", "right", "up", "down", "badge", "slash", "plus", "minus", "inverse",
        "button", "symbol", "sign", "mark", "dot", "dots", "line", "lines", "horizontal",
        "vertical", "my", "stuff", "things", "im", "is", "am", "are", "be", "it", "its", "at",
        "an", "this", "that", "so", "very", "just", "from", "by", "as", "or", "but", "about",
        "we", "you", "your", "our", "me", "going", "get", "got",
    ]

    /// shorthand the embedding doesn't know, and common space names it reads too literally
    private static let concepts: [String: String] = [
        "work": "job office briefcase", "personal": "person heart", "projects": "hammer lightbulb",
        "finance": "money bank chart", "coding": "code computer keyboard", "travel": "airplane suitcase globe",
        "fitness": "dumbbell running", "shopping": "cart bag", "recipes": "cooking chef",
        "taxes": "money receipt calculator", "photography": "camera", "reading": "book",
        "health": "heart medical", "school": "book backpack", "research": "magnifying microscope",
        "uni": "university", "dev": "developer code", "docs": "documents", "doc": "document",
        "ai": "robot brain", "ml": "robot brain", "dnd": "dice dragon", "admin": "settings",
        "misc": "miscellaneous", "tv": "television", "pc": "computer", "biz": "business",
        "sci": "science", "bio": "biology", "chem": "chemistry", "maths": "math", "rpg": "dice sword",
        "irl": "people", "wfh": "home work", "diy": "tools hammer", "fyp": "university project",
    ]

    private static func words(_ text: String) -> [String] {
        WordMeaning.words(text.lowercased().replacingOccurrences(of: "d&d", with: "dnd"), dropping: modifiers)
    }

    private func buildIfNeeded() {
        guard icons.isEmpty else { return }
        var keywords: [String: [String]] = [:]
        for line in IconKeywords.table.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1)
            keywords[String(parts[0])] = parts[1].split(separator: " ").map(String.init)
        }
        var seen = Set<String>()
        let symbols = SFSymbols.categories.flatMap(\.symbols).filter { seen.insert($0).inserted }
        icons = symbols.map { id in
            let name = Self.words(id)
            return Icon(
                id: id, isEmoji: false, name: name.map(meaning.intern), parts: name.flatMap(halves).map(meaning.intern),
                tags: (keywords[id] ?? []).map(meaning.intern), rawName: id)
        }
        for category in Emojis.categories {
            icons += category.emoji.map {
                Icon(
                    id: $0.glyph, isEmoji: true, name: Self.words($0.name).map(meaning.intern), parts: [],
                    tags: (keywords[$0.glyph] ?? []).map(meaning.intern), rawName: $0.name,
                    literal: category.name == "Flags")
            }
        }
    }

    /// symbol names run words together ("graduationcap"); split one the
    /// embedding doesn't know into two halves it does
    private func halves(_ word: String) -> [String] {
        guard word.count >= 6, !WordMeaning.knows(word) else { return [] }
        for cut in 3...(word.count - 3) {
            let head = String(word.prefix(cut)), tail = String(word.dropFirst(cut))
            if WordMeaning.knows(head), WordMeaning.knows(tail) { return [head, tail] }
        }
        return []
    }

    /// icons for `query` as typed in the picker, best first: the model's `ideas`
    /// lead when given, then matches by meaning, then bare substrings of a name
    func search(_ query: String, emoji: Bool, ideas: [String] = []) -> [String] {
        buildIfNeeded()
        var seen = Set<String>()
        return (roundRobin(ideas) + ranked(query, partial: true))
            .filter { $0.isEmoji == emoji && seen.insert($0.id).inserted }.map(\.id)
    }

    /// icons for a space called `name`: its strongest matches, then turns through
    /// the model's `ideas`; one per base shape, symbols and emoji alternating
    func suggestions(for name: String, ideas: [String] = []) -> [String] {
        buildIfNeeded()
        let direct = ranked(name, floor: 0.55)
        var bases = Set<String>()
        let unique = (direct.prefix(4) + roundRobin(ideas) + direct.dropFirst(4))
            .filter { bases.insert(Self.base(of: $0)).inserted }
        let symbols = unique.filter { !$0.isEmoji }, emoji = unique.filter(\.isEmoji)
        let mixed = (0..<max(symbols.count, emoji.count)).flatMap { i in
            [i < symbols.count ? symbols[i].id : nil, i < emoji.count ? emoji[i].id : nil].compactMap { $0 }
        }
        return Array(mixed.prefix(24))
    }

    /// the first few hits for each idea in turn; an idea that is itself an emoji is its own hit
    private func roundRobin(_ ideas: [String]) -> [Icon] {
        let lists = ideas.map { idea in
            let glyph = idea.replacingOccurrences(of: "\u{FE0F}", with: "")
            return icons.filter { $0.id.replacingOccurrences(of: "\u{FE0F}", with: "") == glyph }
                + ranked(idea, floor: 0.6).prefix(3)
        }
        return (0..<4).flatMap { depth in lists.compactMap { depth < $0.count ? $0[depth] : nil } }
    }

    /// symbol variants share their first name word; gendered emoji their neutral form
    private static func base(of icon: Icon) -> String {
        guard icon.isEmoji else { return String(icon.id.prefix { $0 != "." }) }
        let neutral = icon.id.replacingOccurrences(of: "\u{200D}\u{2642}\u{FE0F}", with: "")
            .replacingOccurrences(of: "\u{200D}\u{2640}\u{FE0F}", with: "")
        var scalars = Array(neutral.unicodeScalars)
        if scalars.count > 2, ["\u{1F468}", "\u{1F469}"].contains(scalars[0]), scalars[1] == "\u{200D}" {
            scalars[0] = "\u{1F9D1}"
        }
        return String(String.UnicodeScalarView(scalars))
    }

    private func ranked(_ query: String, partial: Bool = false, floor: Float = 0.5) -> [Icon] {
        let typed = Self.words(query)
        guard !typed.isEmpty else { return [] }
        let perWord = typed.map {
            meaning.scores($0, synonyms: Self.concepts[$0]?.split(separator: " ").map(String.init) ?? [], partial: partial)
        }
        let raw = query.lowercased().trimmingCharacters(in: .whitespaces)
        func best(_ ids: [Int], _ scores: [Float]) -> Float { ids.map { scores[$0] }.max() ?? 0 }
        var scored: [(Icon, Float)] = []
        for icon in icons {
            let each = perWord.map {
                let name = best(icon.name, $0)
                // a name close in meaning breaks ties between icons that share a keyword
                let score = max(name, best(icon.parts, $0) * 0.85, best(icon.tags, $0) * 0.92) + name * 0.03
                return icon.literal ? 0 : score
            }
            // the strongest word carries half, so a phrase needn't match word for word
            var score = (each.max()! + each.reduce(0, +) / Float(each.count)) / 2
            score -= Float(icon.name.count) * 0.005
            if partial, raw.count >= 2, icon.rawName.contains(raw) { score = max(score, floor) }
            if score >= floor { scored.append((icon, score)) }
        }
        return scored.sorted { $0.1 > $1.1 }.map(\.0)
    }
}
