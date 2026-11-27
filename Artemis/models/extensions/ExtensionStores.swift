// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import CryptoKit
import Foundation
import WebKit

/// resolves a Chrome Web Store or Firefox Add-ons page URL to an archive in a temp file for the
/// disk-install path. AMO's JSON API is public; the Chrome update2 endpoint is unofficial and
/// best-effort, with disk sideload as the fallback
enum ExtensionStores {
    private enum StoreError: LocalizedError {
        case unrecognizedURL
        case resolveFailed(String)
        case downloadFailed(String)

        var errorDescription: String? {
            switch self {
            case .unrecognizedURL:
                "That doesn't look like a Chrome Web Store or Firefox Add-ons page."
            case .resolveFailed(let why): "Couldn't find the extension to download: \(why)"
            case .downloadFailed(let why): "Download failed: \(why)"
            }
        }
    }

    /// the Chrome build claimed to the update endpoint, which refuses outdated ones
    private static let chromeProductVersion = "131.0.0.0"

    /// store landing pages the "+" chooser opens for browsing
    static let chromeWebStoreHome = URL(string: "https://chromewebstore.google.com/")!
    static let firefoxAddonsHome = URL(string: "https://addons.mozilla.org/firefox/")!

    /// is this URL an extension's item page, not just the store?
    static func itemPageSource(for url: URL) -> ExtensionSource? {
        if chromeExtensionID(from: url) != nil { return .chrome }
        if firefoxSlug(from: url) != nil { return .firefox }
        return nil
    }

    /// download the archive for a store page and return (tempFileURL, source)
    static func download(from pageURL: URL) async throws -> (URL, ExtensionSource) {
        if let id = chromeExtensionID(from: pageURL) {
            let url = try await resolveChromeCRX(id: id)
            return (try await downloadToTemp(url, ext: "crx"), .chrome)
        }
        if let slug = firefoxSlug(from: pageURL) {
            return (try await download(firefoxRelease(slug: slug)), .firefox)
        }
        throw StoreError.unrecognizedURL
    }

    /// a package a store offers: where to fetch it and the digest it must have
    struct Release {
        let version: String
        let url: URL
        let sha256: String?
    }

    /// the store's release of an installed extension when newer than it, else nil. `feed` stands
    /// in for the Chrome Web Store's update service, which speaks Chrome's update2 protocol
    static func newerRelease(of ext: InstalledExtension, feed: URL? = nil) async throws -> Release? {
        let current = ext.version ?? "0"
        let release: Release?
        if let feed = feed ?? (ext.source == .chrome ? chromeUpdateService : nil) {
            release = try await chromeRelease(id: ext.id, version: current, feed: feed)
        } else if ext.source == .firefox, let addon = geckoID(of: ext.webExtension.manifest) {
            release = try await firefoxRelease(slug: addon)
        } else {
            release = nil
        }
        return release.flatMap { $0.version.compare(current, options: .numeric) == .orderedDescending ? $0 : nil }
    }

    /// the add-on id a Firefox manifest declares
    static func geckoID(of manifest: [String: Any]) -> String? {
        ((manifest["browser_specific_settings"] ?? manifest["applications"]) as? [String: Any])
            .flatMap { $0["gecko"] as? [String: Any] }?["id"] as? String
    }

    /// download a release to a temp file, refused unless it has the digest the store named
    static func download(_ release: Release) async throws -> URL {
        let file = try await downloadToTemp(release.url, ext: release.url.pathExtension == "xpi" ? "xpi" : "crx")
        guard let expected = release.sha256?.lowercased() else { return file }
        let digest = (try? Data(contentsOf: file)).map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
        guard digest == expected else {
            try? FileManager.default.removeItem(at: file)
            throw StoreError.downloadFailed("the package doesn't match the store's digest")
        }
        return file
    }

    // MARK: - Chrome Web Store

    /// pull the 32-char extension id out of a chromewebstore.google.com URL
    private static func chromeExtensionID(from url: URL) -> String? {
        guard let host = url.host(), host.contains("chrome"), host.contains("google.com")
        else { return nil }
        // .../detail/<slug>/<id> or .../detail/<id>
        return url.pathComponents.last { $0.range(of: "^[a-p]{32}$", options: .regularExpression) != nil }
    }

    private static let chromeUpdateService = URL(string: "https://clients2.google.com/service/update2/crx")!

    /// the update service's answer for one extension: `<updatecheck status="ok" codebase=… version=…>`,
    /// or `status="noupdate"`
    private static func chromeRelease(id: String, version: String, feed: URL) async throws -> Release? {
        var components = URLComponents(url: feed, resolvingAgainstBaseURL: false)!
        components.queryItems = (components.queryItems ?? []) + [
            .init(name: "response", value: "updatecheck"),
            .init(name: "acceptformat", value: "crx3"),
            .init(name: "prodversion", value: chromeProductVersion),
            .init(name: "x", value: "id=\(id)&v=\(version)&uc"),
        ]
        var request = URLRequest(url: components.url!)
        request.networkServiceType = .background
        let (data, _) = try await URLSession.shared.data(for: request)
        let answer = String(decoding: data, as: UTF8.self)
        guard let check = answer.firstMatch(of: /<updatecheck\b[^>]*>/).map({ String($0.output) }) else { return nil }
        func attribute(_ name: String) -> String? {
            (try? Regex("\\s\(name)=\"([^\"]*)\"", as: (Substring, Substring).self))
                .flatMap { check.firstMatch(of: $0) }.map { String($0.output.1) }
        }
        guard attribute("status") == "ok", let version = attribute("version"),
            let url = attribute("codebase").flatMap({ URL(string: $0.replacingOccurrences(of: "&amp;", with: "&")) })
        else { return nil }
        return Release(version: version, url: url, sha256: attribute("hash_sha256"))
    }

    private static func resolveChromeCRX(id: String) async throws -> URL {
        var components = URLComponents(url: chromeUpdateService, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "response", value: "redirect"),
            .init(name: "acceptformat", value: "crx2,crx3"),
            .init(name: "prodversion", value: chromeProductVersion),
            .init(name: "x", value: "id=\(id)&installsource=ondemand&uc"),
        ]
        guard let url = components.url else {
            throw StoreError.resolveFailed("couldn't build the update URL")
        }
        return url  // the endpoint 302-redirects to the real CRX; URLSession follows it
    }

    // MARK: - Firefox Add-ons (AMO)

    /// pull the add-on slug out of an addons.mozilla.org URL
    private static func firefoxSlug(from url: URL) -> String? {
        guard let host = url.host(), host.contains("addons.mozilla.org") else { return nil }
        // .../addon/<slug>/...
        guard let i = url.pathComponents.firstIndex(of: "addon"),
            url.pathComponents.indices.contains(i + 1)
        else { return nil }
        return url.pathComponents[i + 1]
    }

    /// AMO's current version of an add-on, named by slug or add-on id
    private static func firefoxRelease(slug: String) async throws -> Release {
        let name = slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["/"])) ?? slug
        var request = URLRequest(url: URL(string: "https://addons.mozilla.org/api/v5/addons/addon/\(name)/")!)
        request.networkServiceType = .background
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw StoreError.resolveFailed("the add-on wasn't found on AMO")
        }
        // current_version.file.url
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let current = json["current_version"] as? [String: Any],
            let file = current["file"] as? [String: Any],
            let urlString = file["url"] as? String,
            let url = URL(string: urlString)
        else {
            throw StoreError.resolveFailed("AMO didn't return a download link")
        }
        let hash = (file["hash"] as? String).flatMap { $0.hasPrefix("sha256:") ? String($0.dropFirst(7)) : nil }
        return Release(version: current["version"] as? String ?? "0", url: url, sha256: hash)
    }

    // MARK: - Download

    private static func downloadToTemp(_ url: URL, ext: String) async throws -> URL {
        do {
            let (location, response) = try await URLSession.shared.download(from: url)
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("artemis-ext-\(UUID().uuidString).\(ext)")
            try FileManager.default.moveItem(at: location, to: dest)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                try? FileManager.default.removeItem(at: dest)
                throw StoreError.downloadFailed("server returned \(http.statusCode)")
            }
            return dest
        } catch let err as StoreError {
            throw err
        } catch {
            throw StoreError.downloadFailed(error.localizedDescription)
        }
    }
}

/// a hand-picked extension the catalog screen offers for one-click install, verified to run on
/// WebKit's WebExtensions runtime
struct CatalogEntry: Identifiable {
    var id: String { storeURL }
    let name: String
    let blurb: String
    let source: ExtensionSource
    let storeURL: String

    static let curated: [CatalogEntry] = [
        CatalogEntry(
            name: "Dark Reader",
            blurb: "Dark mode for every website.",
            source: .firefox,
            storeURL: "https://addons.mozilla.org/firefox/addon/darkreader/"),
        CatalogEntry(
            name: "Bitwarden",
            blurb: "Open-source password manager.",
            source: .firefox,
            storeURL: "https://addons.mozilla.org/firefox/addon/bitwarden-password-manager/"),
    ]
}
