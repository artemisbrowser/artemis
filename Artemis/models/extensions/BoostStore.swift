import Foundation
import WebKit

/// owns the user's Boosts and injects the matching ones into each page as it finishes loading.
/// never through the shared `WKUserContentController`: its only removal API,
/// `removeAllUserScripts`, also wipes extension content scripts
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
            boosts = decoded
            if let encoded = try? JSONEncoder().encode(decoded) {
                AppStorageLocation.writeDurable(encoded, to: file)
            }
            UserDefaults.standard.removeObject(forKey: Self.legacyKey)
        } else {
            boosts = []
        }
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

    @discardableResult
    func create(host: String) -> Boost? {
        let trimmed = host.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return nil }
        let boost = Boost(host: trimmed)
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

    /// inject every enabled Boost whose host is the page's host or a parent of it
    func inject(into webView: WKWebView, url: URL?) {
        guard let host = url?.host()?.lowercased() else { return }
        for boost in boosts where boost.isEnabled && (host == boost.host || host.hasSuffix("." + boost.host)) {
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
