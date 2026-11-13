// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import WebKit

/// WebKit gives every web page a `browser.runtime`. Chrome shows one only where an extension is
/// externally connectable and Firefox never does, and pages pick their messaging path by it
/// (Proton's sign-in hand-off), so elsewhere `browser` is emptied before the page's scripts run
@MainActor
enum PageNamespaceGate {
    private static let scripts = NSMapTable<WKUserContentController, WKUserScript>.weakToStrongObjects()
    private static let remove = NSSelectorFromString("_removeUserScript:")

    /// `patterns`: the `externally_connectable.matches` of the extensions running behind `controller`
    static func apply(_ patterns: [String], to controller: WKUserContentController) {
        guard controller.responds(to: remove) else { return }
        if let old = scripts.object(forKey: controller) { controller.perform(remove, with: old) }
        let sources = patterns.compactMap(regexSource)
        guard let list = try? JSONSerialization.data(withJSONObject: sources),
            let json = String(data: list, encoding: .utf8)
        else { return }
        // an empty object, not a delete: WebKit puts its namespace back wherever `browser` isn't an object
        let script = WKUserScript(
            source: "if (!\(json).some((p) => new RegExp(p).test(location.href))) globalThis.browser = {};",
            injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)
        controller.addUserScript(script)
        scripts.setObject(script, forKey: controller)
    }

    /// a match pattern as an anchored regular expression; nil for one that isn't `scheme://host/path`
    static func regexSource(of pattern: String) -> String? {
        if pattern == "<all_urls>" { return "^(https?|file|ftp)://" }
        let halves = pattern.components(separatedBy: "://")
        guard halves.count == 2, let slash = halves[1].firstIndex(of: "/") else { return nil }
        let escape = NSRegularExpression.escapedPattern(for:)
        let host = String(halves[1][..<slash])
        let hostSource =
            host == "*" ? "[^/]*" : host.hasPrefix("*.") ? "([^/]+\\.)?" + escape(String(host.dropFirst(2))) : escape(host)
        let path = escape(String(halves[1][slash...])).replacingOccurrences(of: "\\*", with: ".*")
        return "^" + (halves[0] == "*" ? "https?" : escape(halves[0])) + "://" + hostSource + "(:\\d+)?" + path + "$"
    }
}
