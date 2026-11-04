// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import CryptoKit
import Foundation

/// patches a stored package so the `__artemis/compat.js` shim runs before the extension's own
/// code in its background, pages and content scripts, filling the namespaces WebKit lacks and
/// bridging to native over `runtime.sendNativeMessage`
nonisolated enum ExtensionCompat {
    /// manifest permissions whose namespaces are `undefined` in WebKit and
    /// which the shim fills, bridging to native code where the page can't
    static let shimmedPermissions: Set<String> = [
        "proxy", "privacy", "idle", "notifications", "offscreen", "identity", "sidePanel",
        "tabGroups", "management", "downloads", "search",
    ]

    /// service-worker globals that keep a background in a real worker; any other background
    /// becomes a scripts array, which WebKit runs as a document
    private static let serviceWorkerOnlyAPIs = [
        "skipWaiting", "clients.claim", "clients.matchAll", "self.registration",
        "importScripts", "addEventListener(\"fetch\"", "addEventListener('fetch'",
    ]

    /// the application id the shim passes to `runtime.sendNativeMessage`, so
    /// the delegate can tell compat traffic from real native-messaging hosts
    static let nativeAppID = "app.artemis.compat"

    /// marker key written into patched manifests (WebKit ignores unknown keys)
    static let markerKey = "artemis_compat"
    /// manifest key holding the host `identity.getRedirectURL` answers with;
    /// `runtime.getManifest()` exposes it to the shim synchronously
    static let redirectHostKey = "artemis_redirect_host"
    /// manifest key mapping the worker's literal importScripts targets that run no code
    /// to whether they exist (an empty file) or not (a failed fetch)
    private static let inertImportsKey = "artemis_inert_imports"
    /// bumped whenever the shim or the patch changes, so stored packages re-patch
    private static let shimVersion = 45

    // MARK: - Entry point

    /// unpack and patch a stored extension in place, returning the URL for
    /// `WKWebExtension(resourceBaseURL:)`. idempotent per shim version
    @concurrent static func prepare(storedID id: String) async -> URL? {
        guard var root = await migrateZipIfNeeded(id: id) else { return nil }
        if let dir = ExtensionInstaller.manifestRoot(under: root) { root = dir }
        patchIfNeeded(packageRoot: root, storedID: id)
        return root
    }

    // MARK: - Zip migration

    /// a stored `extension.zip` unpacked into the package directory, which can be patched as
    /// files; the zip itself when unpacking fails
    private static func migrateZipIfNeeded(id: String) async -> URL? {
        let dir = ExtensionInstaller.storageRoot.appendingPathComponent(id, isDirectory: true)
        let zip = dir.appendingPathComponent("extension.zip")
        let fm = FileManager.default
        guard fm.fileExists(atPath: zip.path) else {
            return fm.fileExists(atPath: dir.path) ? dir : nil
        }
        let unpacked = dir.appendingPathComponent("unpacked", isDirectory: true)
        try? fm.removeItem(at: unpacked)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zip.path, unpacked.path]
        let launched = await withCheckedContinuation { finished in
            ditto.terminationHandler = { _ in finished.resume(returning: true) }
            do { try ditto.run() } catch { finished.resume(returning: false) }
        }
        let extracted = launched && ditto.terminationStatus == 0
        guard extracted, ExtensionInstaller.manifestRoot(under: unpacked) != nil else {
            debugLog("compat: unzip failed for \(id)")
            try? fm.removeItem(at: unpacked)
            return zip  // fall back to the zip; WebKit still loads it unpatched
        }
        try? fm.removeItem(at: zip)
        debugLog("compat: unpacked \(id) for patching")
        return dir
    }

    // MARK: - Patching

    /// the origin its own store gives it (`chrome-extension://<store id>`, `moz-extension:`),
    /// which extension code checks for. set explicitly: WebKit fixes a context's base
    /// URL when it is built, before the stored id is assigned
    @MainActor static func baseURL(storedID id: String) -> URL? {
        guard PerfFlags.on("ext-scheme") else { return nil }
        let origin = try? String(
            contentsOf: ExtensionInstaller.storageRoot.appendingPathComponent(id, isDirectory: true)
                .appendingPathComponent(ExtensionInstaller.packageOriginFile),
            encoding: .utf8)
        let scheme = switch origin {
        case "xpi": "moz-extension"
        case .some: "chrome-extension"
        case nil: "webkit-extension"
        }
        return URL(string: "\(scheme)://\(id.lowercased())/")!
    }

    /// every extension gets the shim: WebKit's namespace methods return undefined when called
    /// detached from their namespace, as `webextension-polyfill` calls them (`bindNamespaces`)
    static func needsShim(manifest: [String: Any]) -> Bool {
        (manifest["manifest_version"] as? NSNumber) != nil || manifest["background"] != nil
    }

    /// does this manifest want the natively-bridged namespaces too?
    static func needsProxyBridge(manifest: [String: Any]) -> Bool {
        let declared = (["permissions", "optional_permissions"].flatMap {
            (manifest[$0] as? [Any]) ?? []
        }).compactMap { $0 as? String }
        return !shimmedPermissions.isDisjoint(with: declared)
    }

    @discardableResult
    static func patchIfNeeded(packageRoot: URL, storedID: String? = nil) -> Bool {
        let manifestURL = packageRoot.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
            var manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            needsShim(manifest: manifest),
            (manifest[markerKey] as? Int) != shimVersion
        else { return false }

        // 1. the shim itself, inside the package so `script-src 'self'` allows it
        let shimDir = packageRoot.appendingPathComponent("__artemis", isDirectory: true)
        try? FileManager.default.createDirectory(at: shimDir, withIntermediateDirectories: true)
        for (name, source) in [("compat.js", pageJS(reaching: manifest)), ("compat-content.js", contentJS)] {
            guard (try? source.write(
                to: shimDir.appendingPathComponent(name), atomically: true, encoding: .utf8))
                != nil
            else { return false }
        }

        // 2. a worker that must stay one keeps its URL, which its relative imports resolve
        // against, and imports the shim first; any other becomes a scripts array, which WebKit
        // runs as a document (scripts > service_worker)
        if var background = manifest["background"] as? [String: Any] {
            // unwrap the scripts pair older shim versions built around such a worker
            if background["preferred_environment"] as? String == "service_worker",
                let scripts = background["scripts"] as? [String],
                scripts.count == 2, scripts[0] == "__artemis/compat.js"
            {
                background = background.filter { $0.key == "type" }
                background["service_worker"] = scripts[1]
            }
            // a manifest naming both (Chrome reads the worker, Firefox the scripts):
            // WebKit runs the scripts as a document, which has no importScripts
            let scriptsWin = !((background["scripts"] as? [String]) ?? []).isEmpty
            if scriptsWin, let worker = background["service_worker"] as? String {
                let file = packageRoot.appendingPathComponent(worker)
                if let data = try? Data(contentsOf: file) {
                    let stripped = withoutShimImport(data)
                    if stripped != data { try? stripped.write(to: file) }
                }
            }
            if !scriptsWin, let worker = background["service_worker"] as? String {
                let isModule = (background["type"] as? String) == "module"
                if needsServiceWorkerEnvironment(packageRoot: packageRoot, entry: worker, isModule: isModule) {
                    importShim(into: packageRoot.appendingPathComponent(worker), isModule: isModule)
                    manifest[inertImportsKey] = inertImports(packageRoot: packageRoot, worker: worker)
                } else {
                    background["scripts"] = ["__artemis/compat.js", worker]
                    background.removeValue(forKey: "service_worker")
                }
            } else if var scripts = background["scripts"] as? [String],
                !scripts.contains("__artemis/compat.js")
            {
                scripts.insert("__artemis/compat.js", at: 0)
                background["scripts"] = scripts
            }
            // background.page is covered by the HTML pass below
            manifest["background"] = background
        }

        // 3. content scripts get the content variant first: the same
        // detached-call bug, none of the bridged namespaces
        if var scripts = manifest["content_scripts"] as? [[String: Any]] {
            for index in scripts.indices {
                var js = ((scripts[index]["js"] as? [String]) ?? []).filter { !$0.hasPrefix("__artemis/") }
                js.insert("__artemis/compat-content.js", at: 0)
                scripts[index]["js"] = js
            }
            manifest["content_scripts"] = withoutRepeats(scripts)
        }

        // 4. the bridge channel: sendNativeMessage is permission-gated. userScripts
        // runs on scripting's registry, which WebKit only exposes when declared
        var permissions = (manifest["permissions"] as? [Any])?.compactMap { $0 as? String } ?? []
        let optional = (manifest["optional_permissions"] as? [Any])?.compactMap { $0 as? String } ?? []
        var needed = ["nativeMessaging"]
        if (permissions + optional).contains("userScripts") { needed.append("scripting") }
        for permission in needed where !permissions.contains(permission) {
            permissions.append(permission)
        }
        manifest["permissions"] = permissions

        // 5. declarativeNetRequest rulesets trimmed to what WebKit will compile:
        // every enabled ruleset becomes ONE content-rule-list, capped at 150,000
        // rules, and the translator emits one rule per `requestDomains` entry
        budgetRulesets(packageRoot: packageRoot, manifest: &manifest)

        if let storedID {
            manifest[redirectHostKey] = redirectHost(storedID: storedID, manifest: manifest)
        }
        manifest[markerKey] = shimVersion
        guard let out = try? JSONSerialization.data(
            withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        else { return false }
        try? out.write(to: manifestURL)

        // 6. every packaged HTML page loads the shim first
        patchHTMLFiles(under: packageRoot)
        markScriptsUTF8(under: packageRoot)
        uncommentLocales(under: packageRoot)

        debugLog("compat: patched \(packageRoot.lastPathComponent) (shim v\(shimVersion))")
        return true
    }

    /// the OAuth redirect host the store registered: `<id>.chromiumapp.org` for
    /// a Web Store id, `<sha1 hex of the add-on id>.extensions.allizom.org` for an
    /// xpi, else the stored id, which no provider has registered
    private static func redirectHost(storedID: String, manifest: [String: Any]) -> String {
        let sidecar = ExtensionInstaller.storageRoot
            .appendingPathComponent(storedID, isDirectory: true)
            .appendingPathComponent(ExtensionInstaller.packageOriginFile)
        let origin = try? String(contentsOf: sidecar, encoding: .utf8)
        let gecko = (manifest["browser_specific_settings"] ?? manifest["applications"])
            .flatMap { ($0 as? [String: Any])?["gecko"] as? [String: Any] }
        if origin == "xpi", let addonID = gecko?["id"] as? String {
            let digest = Insecure.SHA1.hash(data: Data(addonID.utf8))
            return digest.map { String(format: "%02x", $0) }.joined() + ".extensions.allizom.org"
        }
        let id = origin.flatMap { $0 == "xpi" ? nil : $0 } ?? storedID.lowercased()
        return id + ".chromiumapp.org"
    }

    // MARK: - declarativeNetRequest budget

    /// WebKit's ceiling on one compiled content-rule-list (`maxRuleCount`,
    /// ContentExtensionParser). every enabled ruleset lands in that one list
    private static let translatedRuleCap = 150_000
    /// a ruleset that is off by default may cost this much when switched on
    private static let optionalRulesetBudget = 20_000
    /// what the default-enabled rulesets may spend together; the rest of the cap
    /// covers a later-enabled ruleset and the estimate's own error
    private static let enabledRulesetBudget = translatedRuleCap - 2 * optionalRulesetBudget
    /// maps a trimmed ruleset back to the file it came from, so a later re-patch
    /// budgets the original rules rather than the trimmed ones
    private static let rulesetSourceKey = "artemis_dnr_sources"

    /// trim rulesets into `__artemis/dnr/` copies that fit the cap. one oversized
    /// ruleset fails the whole compile, and WebKit then rolls the enabled state
    /// back, so the extension blocks nothing while its UI reports blocking on
    private static func budgetRulesets(packageRoot: URL, manifest: inout [String: Any]) {
        guard var dnr = manifest["declarative_net_request"] as? [String: Any],
            var resources = dnr["rule_resources"] as? [[String: Any]]
        else { return }

        var sources = (manifest[rulesetSourceKey] as? [String: String]) ?? [:]
        let outDir = packageRoot.appendingPathComponent("__artemis/dnr", isDirectory: true)
        let sourcePath = { (entry: [String: Any]) -> String? in
            guard let id = entry["id"] as? String else { return nil }
            return sources[id] ?? (entry["path"] as? String)
        }
        let readRules = { (path: String) -> [[String: Any]]? in
            guard let data = try? Data(contentsOf: packageRoot.appendingPathComponent(path))
            else { return nil }
            return (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
        }

        // cheapest first, so small rulesets survive whole; costed in a pass of its own so
        // only one parsed ruleset is alive at a time
        let order = resources.indices.compactMap { index -> (index: Int, cost: Int)? in
            autoreleasepool {
                guard let path = sourcePath(resources[index]), let rules = readRules(path)
                else { return nil }
                return (index, rules.reduce(0) { $0 + translatedCost(of: $1) })
            }
        }.sorted { $0.cost < $1.cost }

        var spent = 0
        var trimmed = false
        for (index, _) in order {
            autoreleasepool {
                guard let id = resources[index]["id"] as? String,
                    let path = sourcePath(resources[index]), let rules = readRules(path)
                else { return }

                let isEnabled = (resources[index]["enabled"] as? Bool) ?? false
                let allowance =
                    isEnabled ? max(0, enabledRulesetBudget - spent) : optionalRulesetBudget
                let (kept, cost) = fit(rules: rules, within: allowance)
                if isEnabled { spent += cost }
                guard kept.count < rules.count else { return }

                try? FileManager.default.createDirectory(
                    at: outDir, withIntermediateDirectories: true)
                guard let out = try? JSONSerialization.data(withJSONObject: kept),
                    (try? out.write(to: outDir.appendingPathComponent("\(id).json"))) != nil
                else { return }

                sources[id] = path
                resources[index]["path"] = "__artemis/dnr/\(id).json"
                trimmed = true
                debugLog(
                    "compat: dnr ruleset \(id) trimmed \(rules.count) → \(kept.count) rules"
                        + " (\(cost) of \(allowance) translated)")
            }
        }

        guard trimmed else { return }
        dnr["rule_resources"] = resources
        manifest["declarative_net_request"] = dnr
        manifest[rulesetSourceKey] = sources
    }

    /// keep as many rules as the allowance buys, non-block rules first: dropping
    /// an `allow` while its `block` survives blocks more than the author meant
    private static func fit(rules: [[String: Any]], within allowance: Int)
        -> (kept: [[String: Any]], cost: Int)
    {
        let isBlock = { (rule: [String: Any]) in
            (rule["action"] as? [String: Any])?["type"] as? String == "block"
        }
        var spent = 0
        var kept = Set<Int>()
        for blocking in [false, true] {
            for (index, rule) in rules.enumerated() where isBlock(rule) == blocking {
                let cost = translatedCost(of: rule)
                guard spent + cost <= allowance else { continue }
                spent += cost
                kept.insert(index)
            }
        }
        return (rules.indices.filter(kept.contains).map { rules[$0] }, spent)
    }

    /// how many content-rule-list rules WebKit's translator emits for one DNR
    /// rule: one per request domain × method, one per excluded domain × method,
    /// doubled when the rule carries both initiator and excluded-initiator lists
    private static func translatedCost(of rule: [String: Any]) -> Int {
        let condition = (rule["condition"] as? [String: Any]) ?? [:]
        let action = (rule["action"] as? [String: Any])?["type"] as? String
        let count = { (key: String) in (condition[key] as? [Any])?.count ?? 0 }
        let isAllowAll = action == "allowAllRequests"
        let methods = isAllowAll ? 0 : count("requestMethods")
        let excludedMethods = isAllowAll ? 0 : count("excludedRequestMethods")
        let domains = condition["regexFilter"] == nil ? count("requestDomains") : 0

        var units = domains > 0 ? domains * max(1, methods) : max(1, methods)
        let excluded = count("excludedRequestDomains")
        units += excluded > 0 ? excluded * max(1, excludedMethods) : excludedMethods

        var perUnit = 1
        if condition["initiatorDomains"] != nil, condition["excludedInitiatorDomains"] != nil,
            !isAllowAll
        {
            perUnit += 1
        }
        if action == "upgradeScheme" { perUnit += 1 }
        return units * perUnit
    }

    /// Chrome injects a file into a frame once however many entries list it; WebKit runs it again
    /// and the second copy dies redeclaring its globals. a file a match-everything entry already
    /// injects the same way goes
    private static func withoutRepeats(_ scripts: [[String: Any]]) -> [[String: Any]] {
        let timing = { (entry: [String: Any]) in
            "\(entry["run_at"] as? String ?? "document_idle")|\(entry["world"] as? String ?? "ISOLATED")"
        }
        let allFrames = { (entry: [String: Any]) in entry["all_frames"] as? Bool ?? false }
        let files = { (entry: [String: Any], key: String) in (entry[key] as? [String]) ?? [] }
        let everywhere = { (entry: [String: Any]) -> Bool in
            let matches = Set(files(entry, "matches"))
            let narrowed = ["exclude_matches", "include_globs", "exclude_globs"].contains {
                !files(entry, $0).isEmpty
            }
            return !narrowed && (matches.contains("<all_urls>") || matches.contains("*://*/*")
                || matches.isSuperset(of: ["http://*/*", "https://*/*"]))
        }
        let broad = scripts.filter(everywhere)
        return scripts.compactMap { entry in
            guard !everywhere(entry) else { return entry }
            let covered = Set(broad.filter { timing($0) == timing(entry) && (allFrames($0) || !allFrames(entry)) }
                .flatMap { files($0, "js") + files($0, "css") })
            var entry = entry
            for key in ["js", "css"] where entry[key] != nil {
                entry[key] = files(entry, key).filter { $0.hasPrefix("__artemis/") || !covered.contains($0) }
            }
            let own = (files(entry, "js") + files(entry, "css")).filter { !$0.hasPrefix("__artemis/") }
            return own.isEmpty ? nil : entry
        }
    }

    /// the worker's first line loads the shim, from the package root
    /// guarded: an extension page may load the same file as a plain script
    private static let classicImport =
        "if (typeof importScripts === \"function\") importScripts(\"/__artemis/compat.js\");\n"
    private static let moduleImport = "import \"/__artemis/compat.js\";\n"

    private static func importShim(into worker: URL, isModule: Bool) {
        guard let original = try? Data(contentsOf: worker) else { return }
        var data = withoutShimImport(original)
        let bom = Data([0xEF, 0xBB, 0xBF])
        let at = data.starts(with: bom) ? bom.count : 0
        data.insert(contentsOf: Data((isModule ? moduleImport : classicImport).utf8), at: at)
        if data != original { try? data.write(to: worker) }
    }

    /// the shim's import is always the file's first line, in any form a shim version has written
    private static func withoutShimImport(_ data: Data) -> Data {
        let bom = Data([0xEF, 0xBB, 0xBF])
        let start = data.starts(with: bom) ? bom.count : 0
        for line in [classicImport, moduleImport, "importScripts(\"/__artemis/compat.js\");\n"] {
            let bytes = Data(line.utf8)
            if data[start...].starts(with: bytes) {
                var trimmed = data
                trimmed.removeSubrange(start..<(start + bytes.count))
                return trimmed
            }
        }
        return data
    }

    /// does this background use APIs only a real service worker has? a textual check, whose
    /// false positive keeps the environment the extension asked for
    private static func needsServiceWorkerEnvironment(
        packageRoot: URL, entry: String, isModule: Bool
    ) -> Bool {
        if isModule { return true }  // module backgrounds are worker-shaped anyway
        guard let source = try? String(
            contentsOf: packageRoot.appendingPathComponent(entry), encoding: .utf8)
        else { return true }  // unreadable → assume it needs what it asked for
        return serviceWorkerOnlyAPIs.contains { source.contains($0) }
    }

    /// WebKit's importScripts drains microtasks even for an empty or missing file,
    /// which closes any startup window the worker keeps; the shim answers these itself
    private static func inertImports(packageRoot: URL, worker: String) -> [String: Bool] {
        guard let source = try? String(
            contentsOf: packageRoot.appendingPathComponent(worker), encoding: .utf8)
        else { return [:] }
        let base = URL(fileURLWithPath: "/" + worker)
        let paths = source.matches(of: /importScripts\(\s*["']([^"'?#:]+)["']/).compactMap { match in
            URL(string: String(match.1), relativeTo: base)?.standardized.path
        }
        var inert: [String: Bool] = [:]
        for path in paths {
            guard let data = try? Data(contentsOf: packageRoot.appendingPathComponent(path)) else {
                inert[path] = false
                continue
            }
            let code = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines.union(["\u{FEFF}"]))
            if code.isEmpty { inert[path] = true }
        }
        return inert
    }

    /// WebKit's generated background page has no charset, so its scripts decode
    /// as Windows-1252; Chrome and Firefox read every extension script as UTF-8.
    /// a byte-order mark overrides the page's encoding for that one script
    private static func markScriptsUTF8(under root: URL) {
        let bom = Data([0xEF, 0xBB, 0xBF])
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        else { return }
        for case let url as URL in walker where ["js", "mjs"].contains(url.pathExtension.lowercased()) {
            guard let data = try? Data(contentsOf: url), !data.starts(with: bom),
                data.contains(where: { $0 >= 0x80 })
            else { continue }
            try? (bom + data).write(to: url)
        }
    }

    /// Firefox accepts whole-line `//` comments in messages.json; WebKit rejects the file
    private static func uncommentLocales(under root: URL) {
        let locales = root.appendingPathComponent("_locales")
        for locale in (try? FileManager.default.contentsOfDirectory(at: locales, includingPropertiesForKeys: nil)) ?? [] {
            let file = locale.appendingPathComponent("messages.json")
            guard let json = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let clean = json.replacing(#/(?m)^[ \t]*//.*$/#, with: "")
            if clean != json { try? clean.write(to: file, atomically: true, encoding: .utf8) }
        }
    }

    private static func patchHTMLFiles(under root: URL) {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { return }
        let tag = "<script src=\"/__artemis/compat.js\"></script>"
        for case let url as URL in walker where ["html", "htm"].contains(url.pathExtension.lowercased()) {
            guard var html = try? String(contentsOf: url, encoding: .utf8),
                !html.contains("/__artemis/compat.js")
            else { continue }
            if let range = html.range(of: "<head>") {
                html.insert(contentsOf: tag, at: range.upperBound)
            } else if let range = html.range(of: "<script") {
                html.insert(contentsOf: tag, at: range.lowerBound)
            } else {
                continue
            }
            try? html.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - The shim

    /// `compat.js`, injected first into the background and every extension page:
    /// fills the namespaces WebKit lacks and bridges them over sendNativeMessage
    static let compatJS = pageJS(reaching: nil)

    private static let shimSource: String = {
        guard let url = Bundle.main.url(forResource: "compat", withExtension: "js"),
            let source = try? String(contentsOf: url, encoding: .utf8)
        else { preconditionFailure("compat.js missing from the app bundle") }
        return source
    }()

    /// Chrome's enums, constants and events by namespace (tools/compat-gaps.py)
    private static let gaps: [String: Any] = {
        guard let url = Bundle.main.url(forResource: "compat-gaps", withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let table = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { preconditionFailure("compat-gaps.json missing from the app bundle") }
        return table
    }()

    /// namespaces Chrome exposes without a permission
    private static let openNamespaces: Set<String> = [
        "action", "browserAction", "commands", "extension", "i18n", "omnibox", "pageAction",
        "permissions", "runtime", "tabs", "windows",
    ]

    /// the page shim with only the gap entries this manifest can reach inlined;
    /// nil manifest inlines them all
    private static func pageJS(reaching manifest: [String: Any]?) -> String {
        let declared = Set(["permissions", "optional_permissions"].flatMap {
            ((manifest?[$0] as? [Any]) ?? []).compactMap { $0 as? String }
        })
        let reachable = gaps.filter { name, _ in
            let root = String(name.split(separator: ".")[0])
            // declarativeNetRequestWithHostAccess and kin open declarativeNetRequest
            return manifest == nil || openNamespaces.contains(root) || declared.contains { $0.hasPrefix(root) }
                || (root == "contextMenus" && declared.contains("menus"))
        }
        let json = (try? JSONSerialization.data(withJSONObject: reachable, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return shimSource.replacingOccurrences(of: "/*@gaps*/{}", with: json)
    }

    /// the content-script variant: the generic fixes only, cut at the markers.
    /// content scripts run in every frame and have no native bridge to use the rest
    static let contentJS: String = {
        let cut = shimSource.range(of: "  // @content-cut")!
        let resume = shimSource.range(of: "  // @content-resume")!
        return String(shimSource[..<cut.lowerBound] + shimSource[resume.lowerBound...])
    }()
}
