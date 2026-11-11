// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import CryptoKit
import Foundation
import WebKit

/// per-site, opt-in "Pretend to be Chrome": Chrome's user agent, client-hint and Accept headers,
/// plus Chrome's `userAgentData`, `vendor`, `window.chrome`, `deviceMemory` and WebGL strings.
/// Google's sign-in hosts are never eligible: Google refuses a browser it detects disguised
enum ChromeDisguise {
    private static let hostsKey = "chromeDisguiseHostsV1"
    /// incognito opt-ins, which never reach disk
    private static var ephemeralHosts: Set<String> = []
    /// matched with their subdomains
    private static let signInHosts = ["accounts.google.com", "accounts.youtube.com", "myaccount.google.com"]

    /// Chrome's current stable milestone: one ships every 14 days from M152 on 2026-08-25
    static let major: Int = {
        let anchor = DateComponents(
            calendar: Calendar(identifier: .gregorian), timeZone: .gmt,
            year: 2026, month: 8, day: 25
        ).date ?? .distantPast
        return 152 + max(0, Int(Date().timeIntervalSince(anchor) / (14 * 86_400)))
    }()

    /// Chrome's reduced macOS UA
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
        + "(KHTML, like Gecko) Chrome/\(major).0.0.0 Safari/537.36"

    static var persistedHosts: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: hostsKey) ?? [])
    }

    static func isEligible(_ host: String) -> Bool {
        let host = host.lowercased()
        return !signInHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// `ephemeral` tabs also see this session's incognito opt-ins
    static func isOn(for host: String?, ephemeral: Bool) -> Bool {
        guard let host = host?.lowercased(), isEligible(host) else { return false }
        return persistedHosts.contains(host) || (ephemeral && ephemeralHosts.contains(host))
    }

    /// turning a host on from an incognito tab stays in memory; turning it off
    /// clears it everywhere
    static func set(_ on: Bool, for host: String, ephemeral: Bool) {
        let host = host.lowercased()
        if on, ephemeral {
            ephemeralHosts.insert(host)
            return
        }
        var hosts = persistedHosts
        if on { hosts.insert(host) } else { hosts.remove(host) }
        ephemeralHosts.remove(host)
        UserDefaults.standard.set(hosts.sorted(), forKey: hostsKey)
    }

    /// the last incognito window closed: its opt-ins go with it
    static func forgetEphemeral() {
        ephemeralHosts = []
    }

    /// on the Mac, one script in every shared controller. it acts only where the UA already claims Chrome,
    /// and the header rules only on navigations `gate` opens, so the opted-in set never reaches the page
    static func install(into controller: WKUserContentController) {
        controller.addUserScript(
            WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        Task { await attach(to: controller) }
    }
}

extension ChromeDisguise {
/// a plausible build for `major`: Chromium's branch number advances about 59 per milestone
private static let fullVersion = "\(major).0.\(7204 + (major - 138) * 59).110"

/// Chromium's brand list for `major`: the GREASE brand's characters, version and slot all follow it
private static func brands(full: Bool) -> [(brand: String, version: String)] {
    let chars = Array(" (:-./);=?_")
    let grease = "Not\(chars[major % 11])A\(chars[(major + 1) % 11])Brand"
    let version = full ? fullVersion : "\(major)"
    let entries = [
        (grease, ["8", "99", "24"][major % 3] + (full ? ".0.0.0" : "")),
        ("Chromium", version),
        ("Google Chrome", version),
    ]
    let slots = [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]][major % 6]
    var out = entries
    for (index, slot) in slots.enumerated() { out[slot] = entries[index] }
    return out.map { (brand: $0.0, version: $0.1) }
}

/// the `Sec-CH-UA` header value
static var clientHintBrands: String {
    brands(full: false).map { "\"\($0.brand)\";v=\"\($0.version)\"" }.joined(separator: ", ")
}

/// a disguised navigation awaits this before it starts, so its first request has the headers
static func attach(to controller: WKUserContentController) async {
    if let attachHold { await attachHold() }
    guard !attached.contains(controller), let list = await headerRules.value,
        !attached.contains(controller)
    else { return }
    controller.add(list)
    attached.add(controller)
}

private static let attached = NSHashTable<WKUserContentController>.weakObjects()
/// self-test only: every `attach` awaits this first, as it would a cold rule compile
static var attachHold: (() async -> Void)?

/// lets the header rules act on this navigation and every request its page makes
static func gate(_ preferences: WKWebpagePreferences, on: Bool) {
    let getter = NSSelectorFromString("_activeContentRuleListActionPatterns")
    let setter = NSSelectorFromString("_setActiveContentRuleListActionPatterns:")
    guard preferences.responds(to: getter), preferences.responds(to: setter) else { return }
    let current = preferences.perform(getter)?.takeUnretainedValue() as? [String: Set<String>] ?? [:]
    guard (current[headerRulesID] != nil) != on else { return }
    var patterns = current
    patterns[headerRulesID] = on ? ["*://*/*"] : nil
    _ = preferences.perform(setter, with: patterns as NSDictionary)
}

private static let encodedRules: String = {
    func rule(_ filter: String, _ headers: [String: String], types: [String]? = nil) -> [String: Any] {
        var trigger: [String: Any] = ["url-filter": filter]
        if let types { trigger["resource-type"] = types }
        let set = headers.sorted { $0.key < $1.key }.map { ["operation": "set", "header": $0.key, "value": $0.value] }
        return ["trigger": trigger, "action": ["type": "modify-headers", "priority": 1, "request-headers": set]]
    }
    // client hints go only to secure contexts, as Chrome sends them
    let hints = ["Sec-CH-UA": clientHintBrands, "Sec-CH-UA-Mobile": "?0", "Sec-CH-UA-Platform": "\"macOS\""]
    let rules = [
        rule("^https://", hints),
        rule("^http://([^/?#@]*\\.)?localhost(:[0-9]+)?/", hints),
        rule("^http://127\\.0\\.0\\.1(:[0-9]+)?/", hints),
        rule("^http://\\[::1\\](:[0-9]+)?/", hints),
        rule(".*", ["Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,"
            + "image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7"], types: ["document"]),
        rule(".*", ["Accept": "image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8"], types: ["image"]),
        rule(".*", ["Accept": "text/css,*/*;q=0.1"], types: ["style-sheet"]),
    ]
    let json = (try? JSONSerialization.data(withJSONObject: rules, options: .sortedKeys)) ?? Data()
    return String(decoding: json, as: UTF8.self)
}()

private static let headerRulesID = "artemis.chrome-disguise."
    + SHA256.hash(data: Data(encodedRules.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()

/// `modify-headers` rules act only where `_activeContentRuleListActionPatterns` names this list
static let headerRules = Task<WKContentRuleList?, Never> { @MainActor in
    guard let store = WKContentRuleListStore.default() else { return nil }
    for id in (try? await store.availableIdentifiers()) ?? [] where id.hasPrefix("artemis.chrome-disguise.") && id != headerRulesID {
        try? await store.removeContentRuleList(forIdentifier: id)
    }
    if let list = try? await store.contentRuleList(forIdentifier: headerRulesID) { return list }
    do {
        return try await store.compileContentRuleList(forIdentifier: headerRulesID, encodedContentRuleList: encodedRules)
    } catch {
        Diagnostics.record(area: "chrome disguise", message: "header rules failed to compile: \(error)")
        return nil
    }
}

private static var script: String {
    let os = ProcessInfo.processInfo.operatingSystemVersion
    #if arch(arm64)
        let architecture = "arm"
        let gpu = (vendor: "Google Inc. (Apple)", renderer: "ANGLE (Apple, ANGLE Metal Renderer: Apple M1, Unspecified Version)")
    #else
        let architecture = "x86"
        let gpu = (vendor: "Google Inc. (Intel)",
            renderer: "ANGLE (Intel, ANGLE Metal Renderer: Intel(R) Iris(TM) Plus Graphics, Unspecified Version)")
    #endif
    func list(_ full: Bool) -> String {
        brands(full: full).map { "{ brand: \"\($0.brand)\", version: \"\($0.version)\" }" }.joined(separator: ", ")
    }
    return #"""
    (() => {
      if (!/ Chrome\/\#(major)\./.test(navigator.userAgent) || "userAgentData" in navigator) return;
      const frozen = (entries) => Object.freeze(entries.map(Object.freeze));
      const brands = frozen([\#(list(false))]);
      const high = {
        architecture: "\#(architecture)", bitness: "64", brands,
        fullVersionList: frozen([\#(list(true))]), formFactors: Object.freeze(["Desktop"]),
        mobile: false, model: "", platform: "macOS",
        platformVersion: "\#(os.majorVersion).\#(os.minorVersion).\#(os.patchVersion)",
        uaFullVersion: "\#(fullVersion)", wow64: false,
      };
      const low = () => ({ brands, mobile: false, platform: "macOS" });

      // a replacement stringifies as JavaScriptCore prints a native function
      const natives = new WeakMap();
      const previous = Function.prototype.toString;
      const toString = { toString() {
        const name = natives.get(this);
        return name === undefined ? previous.call(this) : "function " + name + "() {\n    [native code]\n}";
      } }.toString;
      natives.set(toString, "toString");
      Function.prototype.toString = toString;
      const native = (fn, name) => {
        Object.defineProperty(fn, "name", { value: name });
        natives.set(fn, name);
        return fn;
      };
      // arrows, like native functions, have no prototype and refuse `new`
      const define = (proto, name, value) => Object.defineProperty(proto, name,
        { get: native(() => value, "get " + name), configurable: true, enumerable: true });

      let creating = true;
      class NavigatorUAData {
        constructor() { if (!creating) throw new TypeError("Illegal constructor"); }
        get brands() { return brands; }
        get mobile() { return false; }
        get platform() { return "macOS"; }
        getHighEntropyValues(hints) {
          const values = low();
          for (const hint of Array.isArray(hints) ? hints : []) {
            if (hint in high) values[hint] = high[hint];
          }
          return Promise.resolve(values);
        }
        toJSON() { return low(); }
      }
      natives.set(NavigatorUAData, "NavigatorUAData");
      for (const key of Object.getOwnPropertyNames(NavigatorUAData.prototype)) {
        const { get, value } = Object.getOwnPropertyDescriptor(NavigatorUAData.prototype, key);
        if (get) natives.set(get, "get " + key);
        else if (key !== "constructor") natives.set(value, key);
      }
      Object.defineProperty(NavigatorUAData.prototype, Symbol.toStringTag, { value: "NavigatorUAData", configurable: true });
      define(Navigator.prototype, "userAgentData", new NavigatorUAData());
      creating = false;
      define(Navigator.prototype, "vendor", "Google Inc.");
      define(Navigator.prototype, "deviceMemory", 8);

      if (!window.chrome) {
        const app = {
          isInstalled: false,
          InstallState: { DISABLED: "disabled", INSTALLED: "installed", NOT_INSTALLED: "not_installed" },
          RunningState: { CANNOT_RUN: "cannot_run", READY_TO_RUN: "ready_to_run", RUNNING: "running" },
          getDetails: native(() => null, "getDetails"),
          getIsInstalled: native(() => false, "getIsInstalled"),
          installState: native((callback) => { callback && callback("not_installed"); }, "installState"),
          runningState: native(() => "cannot_run", "runningState"),
        };
        const csi = native(() => ({ startE: performance.timeOrigin,
          onloadT: performance.timeOrigin + performance.now(), pageT: performance.now(), tran: 15 }), "csi");
        const loadTimes = native(() => {
          const start = performance.timeOrigin / 1000;
          const entry = performance.getEntriesByType("navigation")[0];
          const protocol = (entry && entry.nextHopProtocol) || "http/1.1";
          const negotiated = protocol !== "http/1.1" && protocol !== "http/1.0";
          return { requestTime: start, startLoadTime: start, commitLoadTime: start, finishDocumentLoadTime: 0,
            finishLoadTime: 0, firstPaintTime: 0, firstPaintAfterLoadTime: 0, navigationType: "Other",
            wasFetchedViaSpdy: negotiated, wasNpnNegotiated: negotiated,
            npnNegotiatedProtocol: negotiated ? protocol : "unknown",
            wasAlternateProtocolAvailable: false, connectionInfo: protocol };
        }, "loadTimes");
        Object.defineProperty(window, "chrome", { value: { app, csi, loadTimes }, writable: true, configurable: true });
      }

      // ANGLE's strings as Chrome reports them on this Mac's GPU family
      const angle = {
        37445: "\#(gpu.vendor)",
        37446: "\#(gpu.renderer)",
      };
      const versions = {
        WebGLRenderingContext: { 7938: "WebGL 1.0 (OpenGL ES 2.0 Chromium)",
          35724: "WebGL GLSL ES 1.0 (OpenGL ES GLSL ES 1.0 Chromium)" },
        WebGL2RenderingContext: { 7938: "WebGL 2.0 (OpenGL ES 3.0 Chromium)",
          35724: "WebGL GLSL ES 3.00 (OpenGL ES GLSL ES 3.0 Chromium)" },
      };
      for (const name in versions) {
        const proto = window[name] && window[name].prototype;
        const original = proto && proto.getParameter;
        if (typeof original !== "function") continue;
        const strings = { ...angle, ...versions[name] };
        proto.getParameter = native({ getParameter(parameter) {
          return parameter in strings ? strings[parameter] : original.call(this, parameter);
        } }.getParameter, "getParameter");
      }
    })();
    """#
}
}
