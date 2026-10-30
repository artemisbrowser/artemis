import Foundation
import WebKit

/// owns the user's Boosts and injects the matching ones into each page as it
/// finishes loading.
///
/// injection is per-page (via the tab's navigation finish), deliberately *not*
/// through the shared `WKUserContentController` — that controller is also where
/// the WebExtensions runtime installs extension content scripts, and its only
/// removal API (`removeAllUserScripts`) would wipe those too. per-page eval
/// keeps Boosts fully isolated from extensions.
@Observable
@MainActor
final class BoostStore {
    static let shared = BoostStore()

    private static let legacyKey = "boostsV1"

    private(set) var boosts: [Boost]

    @ObservationIgnored private let fileURL = AppStorageLocation.file("boosts.json")

    private init() {
        let file = AppStorageLocation.file("boosts.json")
        if let stored = AppStorageLocation.loadDurable([Boost].self, from: file) {
            boosts = stored
        } else if let data = UserDefaults.standard.data(forKey: Self.legacyKey),
            let decoded = try? JSONDecoder().decode([Boost].self, from: data) {
            // lift the old defaults blob into a real file, then stop using it
            boosts = decoded
            if let encoded = try? JSONEncoder().encode(decoded) {
                AppStorageLocation.writeDurable(encoded, to: file)
            }
            UserDefaults.standard.removeObject(forKey: Self.legacyKey)
        } else {
            boosts = []
        }
    }

    func add(host: String, css: String, js: String) {
        let trimmed = host.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return }
        boosts.append(Boost(host: trimmed, css: css, js: js))
        persist()
    }

    func remove(_ boost: Boost) {
        boosts.removeAll { $0.id == boost.id }
        persist()
    }

    func setEnabled(_ boost: Boost, _ enabled: Bool) {
        guard let i = boosts.firstIndex(where: { $0.id == boost.id }) else { return }
        boosts[i].isEnabled = enabled
        persist()
    }

    /// save an edited Boost in place (the editor's Save)
    func update(_ boost: Boost) {
        guard let i = boosts.firstIndex(where: { $0.id == boost.id }) else { return }
        boosts[i] = boost
        boosts[i].host = boost.host.trimmingCharacters(in: .whitespaces).lowercased()
        persist()
    }

    /// the Boost that already covers a host, if there is one — so "Boost this
    /// site" edits the existing tweak instead of stacking a second one
    func boost(forHost host: String?) -> Boost? {
        guard let host = host?.lowercased() else { return nil }
        return boosts.first { host == $0.host || host.hasSuffix("." + $0.host) }
    }

    @discardableResult
    func create(host: String, css: String = "", js: String = "") -> Boost? {
        let trimmed = host.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return nil }
        let boost = Boost(host: trimmed, css: css, js: js)
        boosts.append(boost)
        persist()
        return boost
    }

    /// merge in Boosts from a backup, skipping hosts already covered
    @discardableResult
    func merge(_ incoming: [Boost]) -> Int {
        let hosts = Set(boosts.map(\.host))
        let fresh = incoming.filter { !hosts.contains($0.host) }
        guard !fresh.isEmpty else { return 0 }
        boosts.append(contentsOf: fresh)
        persist()
        return fresh.count
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(boosts) else { return }
        AppStorageLocation.writeDurableNow(data, to: fileURL)
    }

    /// inject every enabled Boost whose host matches the page (exact host or a
    /// subdomain of it). called from the tab's navigation-finish.
    func inject(into webView: WKWebView, url: URL?) {
        guard let host = url?.host()?.lowercased() else { return }
        let matches = boosts.filter {
            $0.isEnabled && (host == $0.host || host.hasSuffix("." + $0.host))
        }
        guard !matches.isEmpty else { return }

        for boost in matches {
            if !boost.css.isEmpty {
                let js = """
                (function(){var s=document.createElement("style");\
                s.textContent=\(Self.jsString(boost.css));\
                document.documentElement.appendChild(s);})();
                """
                webView.evaluateJavaScript(js)
            }
            if !boost.js.isEmpty {
                webView.evaluateJavaScript(boost.js)
            }
        }
    }

    /// JSON-encode a string so it's safe to embed as a JS literal
    private static func jsString(_ value: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [value])) ?? Data("[\"\"]".utf8)
        let array = String(data: data, encoding: .utf8) ?? "[\"\"]"
        return String(array.dropFirst().dropLast())  // strip the [ ] of the 1-element array
    }
}
