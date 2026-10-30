import Foundation

/// resolves a Chrome Web Store or Firefox Add-ons page URL to an archive in a temp file for the
/// disk-install path. AMO's JSON API is public; the Chrome update2 endpoint is unofficial and
/// best-effort, with disk sideload as the fallback
enum ExtensionStores {
    enum StoreError: LocalizedError {
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

    /// a Chrome build to claim when asking the update endpoint for a CRX. kept
    /// reasonably current so the store doesn't refuse the request.
    private static let chromeProductVersion = "131.0.0.0"

    /// store landing pages the "+" chooser opens for browsing
    static let chromeWebStoreHome = URL(string: "https://chromewebstore.google.com/")!
    static let firefoxAddonsHome = URL(string: "https://addons.mozilla.org/firefox/")!

    /// is this URL a recognisable extension *item* page (not just the store)?
    /// gates the store page's "Add to Artemis" button.
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
            let url = try await resolveFirefoxXPI(slug: slug)
            return (try await downloadToTemp(url, ext: "xpi"), .firefox)
        }
        throw StoreError.unrecognizedURL
    }

    // MARK: - Chrome Web Store

    /// pull the 32-char extension id out of a chromewebstore.google.com URL
    static func chromeExtensionID(from url: URL) -> String? {
        guard let host = url.host(), host.contains("chrome"), host.contains("google.com")
        else { return nil }
        // .../detail/<slug>/<id> or .../detail/<id>
        let id = url.pathComponents.last { $0.range(of: "^[a-p]{32}$", options: .regularExpression) != nil }
        return id
    }

    private static func resolveChromeCRX(id: String) async throws -> URL {
        var components = URLComponents(string: "https://clients2.google.com/service/update2/crx")!
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
    static func firefoxSlug(from url: URL) -> String? {
        guard let host = url.host(), host.contains("addons.mozilla.org") else { return nil }
        // .../addon/<slug>/...
        guard let i = url.pathComponents.firstIndex(of: "addon"),
            url.pathComponents.indices.contains(i + 1)
        else { return nil }
        return url.pathComponents[i + 1]
    }

    private static func resolveFirefoxXPI(slug: String) async throws -> URL {
        let api = URL(string: "https://addons.mozilla.org/api/v5/addons/addon/\(slug)/")!
        let (data, response) = try await URLSession.shared.data(from: api)
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
        return url
    }

    // MARK: - Download

    private static func downloadToTemp(_ url: URL, ext: String) async throws -> URL {
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw StoreError.downloadFailed("server returned \(http.statusCode)")
            }
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("artemis-ext-\(UUID().uuidString).\(ext)")
            try data.write(to: dest)
            return dest
        } catch let err as StoreError {
            throw err
        } catch {
            throw StoreError.downloadFailed(error.localizedDescription)
        }
    }
}

/// a hand-picked extension the catalog screen offers for one-click install. kept
/// to well-known, open-source add-ons verified to run on our WebExtensions
/// runtime, so first-run UX isn't "go find a folder".
struct CatalogEntry: Identifiable {
    var id: String { storeURL }
    let name: String
    let blurb: String
    let source: ExtensionSource
    let storeURL: String

    /// starter set — Firefox AMO entries first since that path is the most stable
    static let curated: [CatalogEntry] = [
        CatalogEntry(
            name: "uBlock Origin",
            blurb: "Efficient, wide-spectrum content blocker.",
            source: .firefox,
            storeURL: "https://addons.mozilla.org/firefox/addon/ublock-origin/"),
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
