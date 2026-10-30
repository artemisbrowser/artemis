import Foundation
import WebKit

/// Per-site "Pretend to be Chrome", opt-in only: an opted-in host gets Chrome's
/// macOS user agent on its main-frame navigations, and the page-world script gives
/// such a page a matching `navigator.userAgentData` and `vendor`.
/// Google's sign-in hosts are never eligible: Google refuses sign-in there from
/// browsers it can tell are disguised.
enum ChromeDisguise {
    private static let hostsKey = "chromeDisguiseHostsV1"
    /// incognito opt-ins, which never reach disk
    private static var ephemeralHosts: Set<String> = []
    /// matched with their subdomains
    private static let signInHosts = ["accounts.google.com", "accounts.youtube.com", "myaccount.google.com"]

    /// Chrome's reduced macOS UA. stable milestones ship every 14 days from
    /// M152 on 2026-08-25
    static let userAgent: String = {
        let anchor = DateComponents(
            calendar: Calendar(identifier: .gregorian), timeZone: .gmt,
            year: 2026, month: 8, day: 25
        ).date ?? .distantPast
        let major = 152 + max(0, Int(Date().timeIntervalSince(anchor) / (14 * 86_400)))
        return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
            + "(KHTML, like Gecko) Chrome/\(major).0.0.0 Safari/537.36"
    }()

    private static var persistedHosts: Set<String> {
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

    /// added once to the shared controller. it acts only where the UA already
    /// claims Chrome, so the opted-in set never has to reach the page
    static func install(into controller: WKUserContentController) {
        controller.addUserScript(
            WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: false))
    }

    private static var script: String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        #if arch(arm64)
            let architecture = "arm"
        #else
            let architecture = "x86"
        #endif
        return #"""
        (() => {
          const match = / Chrome\/(\d+)\./.exec(navigator.userAgent);
          if (!match || "userAgentData" in navigator) return;
          const major = Number(match[1]);
          // Chromium's GREASE brand: its characters, version and slot all follow the major
          const chars = [" ", "(", ":", "-", ".", "/", ")", ";", "=", "?", "_"];
          const orders = [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]];
          const greaseBrand = "Not" + chars[major % 11] + "A" + chars[(major + 1) % 11] + "Brand";
          const listed = (suffix) => {
            const entries = [
              { brand: greaseBrand, version: ["8", "99", "24"][major % 3] + suffix },
              { brand: "Chromium", version: major + suffix },
              { brand: "Google Chrome", version: major + suffix },
            ];
            const out = [];
            orders[major % 6].forEach((slot, index) => { out[slot] = Object.freeze(entries[index]); });
            return Object.freeze(out);
          };
          const brands = listed("");
          const high = {
            architecture: "\#(architecture)", bitness: "64", brands,
            fullVersionList: listed(".0.0.0"), formFactors: Object.freeze(["Desktop"]),
            mobile: false, model: "", platform: "macOS",
            platformVersion: "\#(os.majorVersion).\#(os.minorVersion).\#(os.patchVersion)",
            uaFullVersion: major + ".0.0.0", wow64: false,
          };
          const low = () => ({ brands, mobile: false, platform: "macOS" });
          class NavigatorUAData {
            get brands() { return brands; }
            get mobile() { return false; }
            get platform() { return "macOS"; }
            get [Symbol.toStringTag]() { return "NavigatorUAData"; }
            getHighEntropyValues(hints) {
              const values = low();
              for (const hint of Array.isArray(hints) ? hints : []) {
                if (hint in high) values[hint] = high[hint];
              }
              return Promise.resolve(values);
            }
            toJSON() { return low(); }
          }
          const data = new NavigatorUAData();
          const define = (name, value) => Object.defineProperty(Navigator.prototype, name,
            { get: () => value, configurable: true, enumerable: true });
          define("userAgentData", data);
          define("vendor", "Google Inc.");
        })();
        """#
    }
}
