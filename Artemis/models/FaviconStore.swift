// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import AppKit
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
    func prefetch(host: String?, isPrivate: Bool) {
        guard let host, !host.isEmpty else { return }
        let key = Self.key(for: host)
        if cache[key] != nil || inFlight.contains(key) { return }
        if NSImage(contentsOf: fileURL(for: key)) != nil { return }
        fetch(key: key, declared: nil, isPrivate: isPrivate)
    }

    /// record a page-declared icon URL (from a `<link rel="icon">`) and fetch it.
    /// a private (incognito) icon is memory-only and never asks the remote service
    func update(host: String?, declaredIconURL: URL?, isPrivate: Bool) {
        guard let host, !host.isEmpty else { return }
        let key = Self.key(for: host)
        if inFlight.contains(key) { return }
        // a declared icon always refetches; a guessed one stands once cached
        if declaredIconURL == nil, cache[key] != nil { return }
        fetch(key: key, declared: declaredIconURL, isPrivate: isPrivate)
    }

    // MARK: - Fetch pipeline

    /// in order: the page-declared icon, the site's /favicon.ico, then, outside
    /// incognito only, Google's favicon service, which learns the host
    static func sources(for key: String, declared: URL?, isPrivate: Bool) -> [URL] {
        [
            declared,
            URL(string: "https://\(key)/favicon.ico"),
            isPrivate ? nil : URL(string: "https://www.google.com/s2/favicons?domain=\(key)&sz=64"),
        ].compactMap { $0 }
    }

    /// the first decodable image wins and is cached, and saved unless private
    private func fetch(key: String, declared: URL?, isPrivate: Bool) {
        inFlight.insert(key)
        attempt(
            Self.sources(for: key, declared: declared, isPrivate: isPrivate), index: 0, key: key,
            persist: !isPrivate)
    }

    /// private fetches keep no cookies or cache on disk
    private static let privateSession = URLSession(configuration: .ephemeral)

    private func attempt(_ urls: [URL], index: Int, key: String, persist: Bool) {
        guard index < urls.count else {
            DispatchQueue.main.async { self.inFlight.remove(key) }
            return
        }
        var request = URLRequest(url: urls[index])
        // some servers serve a degraded response (or 403) to an unknown agent
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15",
            forHTTPHeaderField: "User-Agent")
        (persist ? URLSession.shared : Self.privateSession).dataTask(with: request) { [weak self] data, _, _ in
            guard let self else { return }
            if let data, let image = NSImage(data: data), image.size.width > 0 {
                DispatchQueue.main.async {
                    self.store(image, data: data, key: key, persist: persist)
                }
            } else {
                self.attempt(urls, index: index + 1, key: key, persist: persist)
            }
        }.resume()
    }

    /// commit an icon to memory + disk and wake observers. PNG-normalises so the
    /// on-disk form is uniform regardless of the source (.ico, svg, etc).
    private func store(_ image: NSImage, data: Data, key: String, persist: Bool) {
        cache[key] = image
        knownMissing.remove(key)
        accentCache[key] = nil  // recompute the ring colour from the new icon
        generation &+= 1
        if persist {
            let url = fileURL(for: key)
            if let png = Self.png(from: image) {
                try? png.write(to: url)
            } else {
                try? data.write(to: url)
            }
        }
        inFlight.remove(key)
    }

    private static func png(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
            let rep = NSBitmapImageRep(data: tiff)
        else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: - Dominant colour

    /// the icon's strongest hue, weighted by saturation × brightness and clamped to
    /// a legible ring tint; a monochrome icon gets its own average tone instead
    private static func dominantColor(of image: NSImage) -> Color {
        let dim = 24
        guard let rep = bitmap(of: image, dim: dim) else { return Color(white: 0.85) }

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

    /// render an icon into a small RGBA bitmap for sampling
    private static func bitmap(of image: NSImage, dim: Int) -> NSBitmapImageRep? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: dim, pixelsHigh: dim,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        rep.size = NSSize(width: dim, height: dim)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: dim, height: dim))
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }
}
