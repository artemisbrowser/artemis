// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import AppKit
import Network
import Observation
import SwiftUI

/// persistent favicon cache keyed by host, shared by every tab. a view that
/// reads `icon(for:)` or `accent(for:)` repaints when a fetch lands
@Observable
final class FaviconStore {
    static let shared = FaviconStore()

    /// host → icon
    @ObservationIgnored private var cache: [String: NSImage] = [:]
    /// host → vivid colour sampled from its icon, computed lazily on first ask
    @ObservationIgnored private var accentCache: [String: Color] = [:]
    /// hosts with a fetch in flight
    @ObservationIgnored private var inFlight: Set<String> = []
    /// hosts already missed on disk, so a render never repeats a failing
    /// synchronous file read; cleared when the host's icon lands
    @ObservationIgnored private var knownMissing: Set<String> = []
    /// bumped on every stored icon; the observed stand-in for the caches
    private var generation = 0

    @ObservationIgnored private let dir: URL

    private init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("\(AppStorageLocation.folderName)/Favicons", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        dir = base
    }

    /// strip a leading "www." so "www.site.com" and "site.com" share one icon
    private static func key(for host: String) -> String {
        let h = host.lowercased()
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }

    private func fileURL(for key: String) -> URL {
        // host can't contain '/'; ':' (ports) → '_' keeps it a safe filename
        let safe = key.replacingOccurrences(of: ":", with: "_")
        return dir.appendingPathComponent(safe).appendingPathExtension("png")
    }

    /// delete the icons written since `since`, each named for a site visited; icons
    /// already in memory stay, so open tabs keep theirs
    func removeIcons(since: Date) {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files {
            let written = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            if (written ?? .now) >= since { try? FileManager.default.removeItem(at: file) }
        }
    }

    /// the icon for a host, or nil. reading `generation` here ties every caller
    /// into observation so a later fetch repaints them; a disk hit warms memory.
    func icon(for host: String?) -> NSImage? {
        _ = generation
        guard let host, !host.isEmpty else { return nil }
        let key = Self.key(for: host)
        if let image = cache[key] { return image }
        if knownMissing.contains(key) { return nil }
        if let image = NSImage(contentsOf: fileURL(for: key)) {
            cache[key] = image
            return image
        }
        knownMissing.insert(key)
        return nil
    }

    /// a vivid colour sampled from the host's favicon — for tinting a selection
    /// ring to match the icon rather than the space. nil until the icon resolves.
    /// reads `generation` so a later fetch repaints + recolours callers.
    func accent(for host: String?) -> Color? {
        _ = generation
        guard let host, !host.isEmpty else { return nil }
        let key = Self.key(for: host)
        if let cached = accentCache[key] { return cached }
        guard let image = icon(for: host) else { return nil }
        let color = Self.dominantColor(of: image)
        accentCache[key] = color
        return color
    }

    /// kick off a fetch for a host if we don't already have its icon. cheap to
    /// call repeatedly — it no-ops when cached or already loading.
    func prefetch(host: String?, profile: UUID, isPrivate: Bool) {
        guard let host, !host.isEmpty, icon(for: host) == nil else { return }
        let key = Self.key(for: host)
        if inFlight.contains(key) { return }
        fetch(key: key, declared: nil, profile: profile, isPrivate: isPrivate)
    }

    /// record a page-declared icon URL (from a `<link rel="icon">`) and fetch it.
    /// a private (incognito) icon is memory-only and never asks the remote service
    func update(host: String?, declaredIconURL: URL?, profile: UUID, isPrivate: Bool) {
        guard let host, !host.isEmpty else { return }
        let key = Self.key(for: host)
        if inFlight.contains(key) { return }
        // a declared icon always refetches; a guessed one stands once cached
        if declaredIconURL == nil, cache[key] != nil { return }
        fetch(key: key, declared: declaredIconURL, profile: profile, isPrivate: isPrivate)
    }

    // MARK: - Fetch pipeline

    /// in order: the page-declared icon if it is on the web or inline, the site's
    /// /favicon.ico, then, outside incognito only, Google's favicon service, which learns the host
    static func sources(for key: String, declared: URL?, isPrivate: Bool) -> [URL] {
        [
            declared.flatMap { ["http", "https", "data"].contains($0.scheme?.lowercased()) ? $0 : nil },
            URL(string: "https://\(key)/favicon.ico"),
            isPrivate ? nil : URL(string: "https://www.google.com/s2/favicons?domain=\(key)&sz=64"),
        ].compactMap { $0 }
    }

    /// the first decodable image wins and is cached, and saved unless private. each fetch has a
    /// session of its own through the profile's extension proxy: no connection, cookie or cache
    /// shared with another, and no request alive past 15 seconds
    private func fetch(key: String, declared: URL?, profile: UUID, isPrivate: Bool) {
        inFlight.insert(key)
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForResource = 15
        if let proxy = ExtensionProxyBridge.shared.activeProxy(in: profile) {
            config.proxyConfigurations = [proxy.config]
        }
        let session = URLSession(configuration: config)
        let urls = Self.sources(for: key, declared: declared, isPrivate: isPrivate)
        Task {
            defer {
                inFlight.remove(key)
                session.finishTasksAndInvalidate()
            }
            for url in urls {
                guard let png = await Self.download(url, via: session), let image = NSImage(data: png)
                else { continue }
                cache[key] = image
                knownMissing.remove(key)
                accentCache[key] = nil  // recompute the ring colour from the new icon
                generation &+= 1
                if !isPrivate { try? png.write(to: fileURL(for: key)) }
                return
            }
        }
    }

    nonisolated private static let maxBytes = 1 << 20
    /// the long side an icon is kept at, in pixels; the 64pt passwords tile draws it at about 82
    nonisolated private static let maxPixels = 128
    /// the longest side an icon may declare, in pixels: drawing it down decodes it whole first
    nonisolated private static let maxSourcePixels = 4096

    /// the icon at `url` as a PNG of at most `maxPixels` a side; nil when it isn't an image,
    /// declares more than `maxSourcePixels` a side, or passes `maxBytes` or the session's deadline
    @concurrent
    private nonisolated static func download(_ url: URL, via session: URLSession) async -> Data? {
        var request = URLRequest(url: url)
        // some servers serve a degraded response (or 403) to an unknown agent
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15",
            forHTTPHeaderField: "User-Agent")
        guard let (bytes, response) = try? await session.bytes(for: request) else { return nil }
        defer { bytes.task.cancel() }
        guard response.expectedContentLength <= maxBytes else { return nil }
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                guard data.count <= maxBytes else { return nil }
            }
        } catch { return nil }
        guard let image = NSImage(data: data), image.size.width > 0, image.size.height > 0 else { return nil }
        // a vector rep reports no pixels and renders at the cap
        let pixels = image.representations.map { max($0.pixelsWide, $0.pixelsHigh) }.max() ?? 0
        guard pixels <= maxSourcePixels else { return nil }
        let scale = CGFloat(pixels > 0 ? min(pixels, maxPixels) : maxPixels)
            / max(image.size.width, image.size.height)
        let rep = bitmap(
            of: image, width: max(1, Int(image.size.width * scale)), height: max(1, Int(image.size.height * scale)))
        return rep?.representation(using: .png, properties: [:])
    }

    // MARK: - Dominant colour

    /// the icon's strongest hue, weighted by saturation × brightness and clamped to
    /// a legible ring tint; a monochrome icon gets its own average tone instead
    private static func dominantColor(of image: NSImage) -> Color {
        let dim = 24
        guard let rep = bitmap(of: image, width: dim, height: dim) else { return Color(white: 0.85) }

        let bins = 12
        var weight = [Double](repeating: 0, count: bins)
        var rSum = [Double](repeating: 0, count: bins)
        var gSum = [Double](repeating: 0, count: bins)
        var bSum = [Double](repeating: 0, count: bins)
        // average of every opaque pixel, grey and black included
        var allW = 0.0, allR = 0.0, allG = 0.0, allB = 0.0

        for y in 0..<dim {
            for x in 0..<dim {
                guard let raw = rep.colorAt(x: x, y: y), raw.alphaComponent > 0.5,
                    let c = raw.usingColorSpace(.sRGB)
                else { continue }
                allW += 1
                allR += Double(c.redComponent)
                allG += Double(c.greenComponent)
                allB += Double(c.blueComponent)
                var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
                guard s > 0.18, b > 0.12 else { continue }  // skip grey/near-black
                let w = Double(s * b)  // favour vivid, bright pixels
                let i = min(bins - 1, Int(h * CGFloat(bins)))
                weight[i] += w
                rSum[i] += Double(c.redComponent) * w
                gSum[i] += Double(c.greenComponent) * w
                bSum[i] += Double(c.blueComponent) * w
            }
        }

        guard let i = weight.indices.max(by: { weight[$0] < weight[$1] }), weight[i] > 0 else {
            // monochrome: its own tone, floored to stay visible
            guard allW > 0 else { return Color(white: 0.85) }  // fully transparent
            let mono = NSColor(srgbRed: allR / allW, green: allG / allW, blue: allB / allW, alpha: 1)
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            mono.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
            return Color(hue: Double(h), saturation: Double(s), brightness: Double(max(b, 0.35)))
        }
        let w = weight[i]
        let base = NSColor(srgbRed: rSum[i] / w, green: gSum[i] / w, blue: bSum[i] / w, alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        base.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return Color(
            hue: Double(h),
            saturation: Double(min(max(s, 0.55), 0.9)),
            brightness: Double(max(b, 0.85)))
    }

    /// render an icon into an RGBA bitmap of the given pixel size
    private nonisolated static func bitmap(of image: NSImage, width: Int, height: Int) -> NSBitmapImageRep? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        rep.size = NSSize(width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }
}
