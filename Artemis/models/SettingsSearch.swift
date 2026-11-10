// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import Foundation

/// ranks every `SettingID` against what was typed in the Settings search, by its
/// title, section, pane and keywords, matched by meaning as well as by letters
actor SettingsSearch {
    static let shared = SettingsSearch()

    private struct Doc {
        let id: SettingID
        let title: [Int], section: [Int], pane: [Int], keywords: [Int]  // indices into `meaning.vocab`
        /// " title ", " section pane keywords ", lowercased, for letters typed so far
        let titleText: String, otherText: String
    }

    private let meaning = WordMeaning()
    private var docs: [Doc] = []

    private static let filler: Set<String> = [
        "how", "do", "does", "can", "where", "what", "which", "why", "is", "are", "the", "to", "of",
        "my", "me", "it", "its", "an", "and", "or", "for", "with", "in", "on", "off", "turn", "make",
        "set", "change", "want", "get", "enable", "disable", "setting", "settings", "option", "options",
        "there", "way", "that", "this", "be", "when", "from", "at", "so", "too", "dont", "doesnt",
    ]

    private func buildIfNeeded() {
        guard docs.isEmpty else { return }
        func ids(_ text: String) -> [Int] { WordMeaning.words(text, dropping: Self.filler).map { meaning.intern($0) } }
        docs = SettingID.allCases.map { id in
            let e = id.entry
            let place = [e.page?.title, e.section].compactMap { $0 }.joined(separator: " ")
            return Doc(
                id: id, title: ids(e.title), section: ids(place), pane: ids(e.pane.rawValue),
                keywords: e.keywords.flatMap(ids),
                titleText: " " + e.title.lowercased() + " ",
                otherText: " " + ([place, e.pane.rawValue] + e.keywords).joined(separator: " ").lowercased() + " ")
        }
    }

    /// best first: the strongest hits of each of the model's `ideas` in turn, then
    /// a title holding the typed letters at a word start, then the rest by meaning
    func search(_ query: String, ideas: [String] = []) -> [SettingID] {
        let lists = ideas.map { ranked($0).prefix(2) }
        let led = (0..<2).flatMap { depth in lists.compactMap { depth < $0.count ? $0[$0.startIndex + depth] : nil } }
        var seen = Set<SettingID>()
        return (led + ranked(query)).filter { seen.insert($0).inserted }
    }

    private func ranked(_ query: String) -> [SettingID] {
        buildIfNeeded()
        let raw = query.lowercased().trimmingCharacters(in: .whitespaces)
        let typed = WordMeaning.words(raw, dropping: Self.filler)
        let perWord = typed.enumerated().map { meaning.scores($1, partial: $0 == typed.count - 1) }
        func best(_ ids: [Int], _ scores: [Float]) -> Float { ids.map { scores[$0] }.max() ?? 0 }
        var scored: [(SettingID, Float)] = []  // `docs` order breaks ties
        for doc in docs {
            let each = perWord.map {
                max(best(doc.title, $0), best(doc.section, $0) * 0.8, best(doc.pane, $0) * 0.7, best(doc.keywords, $0) * 0.92)
            }
            var score = each.isEmpty ? 0 : (each.max()! + each.reduce(0, +) / Float(each.count)) / 2
            if raw.count >= 2 {
                if doc.titleText.contains(" " + raw) { score = max(score, 1.1) }
                else if doc.otherText.contains(" " + raw) { score = max(score, 0.9) }
            }
            if score >= 0.6 { scored.append((doc.id, score)) }
        }
        return scored.enumerated().sorted { ($0.1.1, $1.0) > ($1.1.1, $0.0) }.map(\.1.0)
    }
}

nonisolated extension SettingID {
    /// where the row lives: "Privacy & Security › Content Blocking"
    var place: String {
        let e = entry
        return ([e.pane.rawValue, e.page?.title, e.section == e.title ? nil : e.section].compactMap { $0 })
            .joined(separator: " › ")
    }
}
