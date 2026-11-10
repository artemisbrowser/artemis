// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import Foundation

/// a profile's standing translation choices: the languages it always translates, the
/// sites it never translates by itself, and the language pages go into.
/// only ever written from a person's explicit choice, never from an incognito page
@Observable
final class TranslationRules {
    private struct Saved: Codable {
        /// `Locale.Language.LanguageCode` identifiers
        var languages: [String] = []
        /// hosts without `www.`, as `ZoomStore.key(for:)` makes them
        var sites: [String] = []
        var target: String?
    }

    private var saved: Saved
    @ObservationIgnored private let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
        saved = AppStorageLocation.loadDurable(Saved.self, from: fileURL) ?? Saved()
    }

    var languages: [String] { saved.languages }
    /// the chosen language's identifier; nil follows the system
    var chosenTarget: String? {
        get { saved.target }
        set {
            saved.target = newValue
            save()
        }
    }
    var sites: [String] { saved.sites }

    /// the chosen language, else the first preferred system language
    var target: Locale.Language { saved.target.map(Locale.Language.init(identifier:)) ?? PageTranslation.systemTarget }

    func alwaysTranslates(_ language: Locale.Language) -> Bool {
        language.languageCode.map { saved.languages.contains($0.identifier) } ?? false
    }

    func neverTranslates(_ url: URL?) -> Bool {
        ZoomStore.key(for: url).map(saved.sites.contains) ?? false
    }

    /// what a page load may do without being asked
    func translatesAutomatically(_ language: Locale.Language, on url: URL?) -> Bool {
        alwaysTranslates(language) && !neverTranslates(url)
    }

    func setAlways(_ code: String, _ on: Bool) {
        saved.languages.removeAll { $0 == code }
        if on { saved.languages.append(code) }
        save()
    }

    func setNever(_ site: String, _ on: Bool) {
        saved.sites.removeAll { $0 == site }
        if on { saved.sites.append(site) }
        save()
    }

    /// the system language is stored as no choice, so it follows the system
    func setTarget(_ language: Locale.Language) {
        let system = PageTranslation.sameTarget(language, PageTranslation.systemTarget)
        saved.target = system ? nil : language.minimalIdentifier
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(saved) else { return }
        AppStorageLocation.writeDurable(data, to: fileURL)
    }
}
