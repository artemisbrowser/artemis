// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// a site installed as an app: a window of its own over the jar of the space it came from
struct WebApp: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var url: URL
    var spaceID: UUID
    var profileID: UUID
    var icon = Icon.favicon
    /// how the window's frame is painted; `appearance` holds a solid or gradient's colours
    var look = ScoutBarStyle.glass
    var appearance = SpaceAppearance()
    /// the toolbar hides until the pointer reaches the window's top edge
    var collapsed = false
    /// the page card's rim in points; nil follows the browser window's
    var edgeInset: Double?
    var showsNavigation = true
    /// links to other sites stay in the window
    var keepsLinks = false
    var floats = false
    /// the Dock tile shows the count a page puts in its title, like "Inbox (3)"
    var badges = true

    enum Icon: Codable, Equatable {
        case favicon
        /// an emoji or an SF Symbol name
        case glyph(String)
        /// the image picked from disk, kept at `WebApps.pickedImage(of:)`
        case image
    }

    /// the space it was installed from, else another in the same profile
    func space(in spaces: [Space]) -> Space? {
        spaces.first { $0.id == spaceID } ?? spaces.first { $0.profileID == profileID }
    }

    /// `url` is on this app's site: the same registrable domain, or the same host where there is none
    func covers(_ url: URL) -> Bool {
        guard let site = TabManager.baseDomain(of: url), let home = TabManager.baseDomain(of: self.url) else { return true }
        return site == home
    }

    /// the count in a title like "Inbox (3)" or "(12) Chat"
    static func badge(in title: String) -> String? {
        title.firstMatch(of: /\((\d{1,4}\+?)\)/).map { String($0.1) }
    }
}

extension WebApp {
    /// an app saved before a field existed takes that field's default
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let base = WebApp(
            name: try c.decode(String.self, forKey: .name), url: try c.decode(URL.self, forKey: .url),
            spaceID: try c.decode(UUID.self, forKey: .spaceID), profileID: try c.decode(UUID.self, forKey: .profileID))
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T { (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback }
        self = base
        id = try c.decode(UUID.self, forKey: .id)
        icon = value(.icon, base.icon)
        look = value(.look, base.look)
        appearance = value(.appearance, base.appearance)
        collapsed = value(.collapsed, base.collapsed)
        edgeInset = value(.edgeInset, base.edgeInset)
        showsNavigation = value(.showsNavigation, base.showsNavigation)
        keepsLinks = value(.keepsLinks, base.keepsLinks)
        floats = value(.floats, base.floats)
        badges = value(.badges, base.badges)
    }

    /// everything about the window's look and behaviour back to how an install starts
    mutating func resetLook() {
        let fresh = WebApp(name: name, url: url, spaceID: spaceID, profileID: profileID)
        (look, appearance, collapsed, edgeInset) = (fresh.look, fresh.appearance, fresh.collapsed, fresh.edgeInset)
        (showsNavigation, keepsLinks, floats, badges) = (fresh.showsNavigation, fresh.keepsLinks, fresh.floats, fresh.badges)
    }
}

/// the installed apps, and the launcher each has in Applications
@MainActor
@Observable
final class WebApps {
    static let shared = WebApps()

    private(set) var apps: [WebApp]

    private let fileURL = AppStorageLocation.file("apps.json")
    /// the launcher's Info.plist key naming its app
    private static let idKey = "ArtemisAppID"
    /// raised when the launcher's protocol changes, so older launchers are rewritten at launch
    private static let shimVersion = 1
    private static let host = Bundle.main.bundleIdentifier ?? "dev.findles.Artemis"
    private static let shimBinary = Bundle.main.bundleURL.appending(path: "Contents/Helpers/ArtemisAppShim")

    /// a test run's launchers stay in its own data folder, out of Spotlight and Launchpad
    private static let launchers: URL =
        AppStorageLocation.isTestRun
        ? AppStorageLocation.file("Apps")
        : FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications/Artemis Apps")

    private init() {
        apps = AppStorageLocation.loadDurable([WebApp].self, from: fileURL) ?? []
    }

    func app(_ id: UUID?) -> WebApp? { apps.first { $0.id == id } }

    static func canInstall(_ tab: BrowserTab) -> Bool {
        !tab.isPrivate && tab.manager?.webAppID == nil && ["https", "http"].contains(tab.url?.scheme)
    }

    func launcher(of app: WebApp) -> URL {
        Self.launchers.appending(path: app.name.replacingOccurrences(of: "/", with: "-") + ".app")
    }

    static func pickedImage(of app: WebApp) -> URL { AppStorageLocation.file("App Icons/\(app.id.uuidString).png") }

    /// asks for a name, then installs the page `tab` shows and opens its window
    func askToInstall(_ tab: BrowserTab) {
        guard Self.canInstall(tab), let url = tab.url, let manager = tab.manager else { return }
        // a Scout page's space is its window's own, so it installs from one in the same profile
        let own = manager.space(of: tab) ?? manager.currentSpace
        guard let space = manager.spaces.first(where: { $0 === own }) ?? manager.spaces.first(where: { $0.profileID == own.profileID })
        else { return }
        let alert = NSAlert()
        alert.messageText = "Install as App"
        alert.informativeText =
            "It opens in a window of its own, signed in as \(space.name). Keep it in the Dock from Applications › Artemis Apps."
        let suggested = tab.displayTitle.isEmpty ? url.host() ?? "" : tab.displayTitle
        let field = NSTextField(string: suggested)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let typed = field.stringValue.trimmingCharacters(in: .whitespaces)
        open(install(url, name: typed.isEmpty ? suggested : typed, from: space, icon: tab.favicon))
    }

    /// a name another app holds gets a number
    func install(_ url: URL, name: String, from space: Space, icon: NSImage?) -> WebApp {
        let app = WebApp(name: uniqueName(name), url: url, spaceID: space.id, profileID: space.profileID)
        apps.append(app)
        save()
        writeLauncher(for: app, favicon: icon)
        return app
    }

    private func uniqueName(_ name: String, except id: UUID? = nil) -> String {
        var unique = name, n = 1
        // launchers are named after apps on a case-insensitive volume
        while apps.contains(where: { $0.name.caseInsensitiveCompare(unique) == .orderedSame && $0.id != id }) {
            n += 1
            unique = "\(name) \(n)"
        }
        return unique
    }

    /// saves an edit and carries it to the launcher and the open window
    func update(_ edited: WebApp) {
        guard let index = apps.firstIndex(where: { $0.id == edited.id }) else { return }
        var app = edited
        app.name = uniqueName(app.name.trimmingCharacters(in: .whitespaces), except: app.id)
        if app.name.isEmpty { app.name = apps[index].name }
        let old = apps[index]
        guard app != old else { return }
        apps[index] = app
        scheduleSave()
        var recolours = false
        if case .glyph = app.icon { recolours = app.look != old.look || app.appearance != old.appearance }
        if app.name != old.name || app.icon != old.icon || recolours { refreshLauncher(from: old, to: app) }
        if app.badges != old.badges, !app.badges { post("badge", for: app, ["badge": ""]) }
        guard let window = window(of: app) else { return }
        window.level = app.floats ? .floating : .normal
        window.title = app.name
        if app.spaceID != old.spaceID {
            // a page can't move jars, so the window opens again over the new one
            window.close()
            DispatchQueue.main.async { self.open(app) }
        }
    }

    /// the launcher as it stands before edits still on their way to it
    @ObservationIgnored private var launcherBefore: [UUID: WebApp] = [:]
    @ObservationIgnored private var launcherTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    /// once edits settle, so a drag signs one bundle rather than one per frame
    private func refreshLauncher(from old: WebApp, to app: WebApp) {
        let before = launcherBefore[app.id] ?? old
        launcherBefore[app.id] = before
        launcherTasks[app.id]?.cancel()
        launcherTasks[app.id] = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            launcherBefore[app.id] = nil
            guard let app = self.app(app.id) else { return }
            rewriteLauncher(from: before, to: app)
        }
    }

    private func rewriteLauncher(from old: WebApp, to app: WebApp) {
        let running = shimIsRunning(old)
        let previous = Self.existingIcon(of: launcher(of: old))
        guard app.name != old.name else {
            writeLauncher(for: app, fallback: previous)
            return post("icon", for: app)
        }
        quitShim(old)
        try? FileManager.default.removeItem(at: launcher(of: old))
        writeLauncher(for: app, fallback: previous)
        guard running else { return }
        // Launch Services hands an open to a launcher still quitting rather than starting the renamed one
        Task {
            for _ in 0..<50 where shimIsRunning(app) { try? await Task.sleep(for: .milliseconds(40)) }
            if window(of: app) != nil { launchShim(app) }
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            if !Task.isCancelled { save() }
        }
    }

    /// copies a picked image in as the app's icon
    func setImage(at file: URL, for app: WebApp) {
        guard let tiff = NSImage(contentsOf: file)?.tiffRepresentation,
            let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { return }
        let target = Self.pickedImage(of: app)
        try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard (try? png.write(to: target)) != nil else { return }
        var edited = self.app(app.id) ?? app
        if edited.icon == .image { return refreshLauncher(from: edited, to: edited) }
        edited.icon = .image
        update(edited)
    }

    /// takes its launcher and its window with it
    func remove(_ app: WebApp) {
        let app = self.app(app.id) ?? app
        apps.removeAll { $0.id == app.id }
        save()
        quitShim(app)
        try? FileManager.default.removeItem(at: launcher(of: app))
        try? FileManager.default.removeItem(at: Self.pickedImage(of: app))
        window(of: app)?.performClose(nil)
    }

    func window(of app: WebApp) -> NSWindow? { ScoutWindow.window(showing: app.id) }

    /// fronts its window, else opens one; the launcher, once running, holds the Dock tile
    func open(_ app: WebApp) {
        if let window = window(of: app) {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        } else {
            ScoutWindow.open(app)
            window(of: app)?.level = app.floats ? .floating : .normal
            if !shimIsRunning(app) { launchShim(app) }
        }
    }

    /// opens the app `url` launches; false when it is no installed app's launcher
    func open(launcher url: URL) -> Bool {
        guard url.pathExtension == "app",
            let id = (NSDictionary(contentsOf: url.appending(path: "Contents/Info.plist"))?[Self.idKey] as? String)
                .flatMap(UUID.init),
            let app = apps.first(where: { $0.id == id })
        else { return false }
        open(app)
        return true
    }

    private func save() {
        saveTask?.cancel()
        saveTask = nil
        guard let data = try? JSONEncoder().encode(apps) else { return }
        AppStorageLocation.writeDurable(data, to: fileURL)
    }

    // MARK: - Launcher

    /// once at launch: listens for launchers quitting, and rewrites any an older Artemis wrote
    func start() {
        DistributedNotificationCenter.default().addObserver(
            forName: Self.event("quit"), object: nil, queue: .main
        ) { note in
            let id = (note.object as? String).flatMap(UUID.init)
            MainActor.assumeIsolated {
                if let app = self.app(id) { self.window(of: app)?.performClose(nil) }
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                if self.saveTask != nil { self.save() }
            }
        }
        for app in apps {
            let info = NSDictionary(contentsOf: launcher(of: app).appending(path: "Contents/Info.plist"))
            if (info?["ArtemisShim"] as? Int ?? 0) < Self.shimVersion, FileManager.default.fileExists(atPath: Self.shimBinary.path) {
                writeLauncher(for: app, fallback: Self.existingIcon(of: launcher(of: app)))
            }
        }
    }

    /// the app's window closed: its launcher quits and gives up the Dock tile
    func windowClosed(_ id: UUID) {
        if let app = app(id) { quitShim(app) }
    }

    /// the page's title changed: the Dock tile shows the count it carries
    func titleChanged(_ title: String, for app: WebApp) {
        guard app.badges else { return }
        let badge = WebApp.badge(in: title) ?? ""
        guard lastBadge[app.id] != badge else { return }
        lastBadge[app.id] = badge
        post("badge", for: app, ["badge": badge])
    }

    @ObservationIgnored private var lastBadge: [UUID: String] = [:]

    func shimID(_ app: WebApp) -> String { "\(Self.host).app.\(app.id.uuidString)" }

    func shimIsRunning(_ app: WebApp) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: shimID(app)).isEmpty
    }

    /// a launcher has nothing to save, and a signal needs no Apple Events consent
    private func quitShim(_ app: WebApp) {
        NSRunningApplication.runningApplications(withBundleIdentifier: shimID(app)).forEach { $0.forceTerminate() }
    }

    private func launchShim(_ app: WebApp) {
        let bundle = launcher(of: app)
        guard (NSDictionary(contentsOf: bundle.appending(path: "Contents/Info.plist"))?["ArtemisShim"]) != nil else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: bundle, configuration: configuration)
    }

    /// must match the names ArtemisAppShim listens for
    private static func event(_ name: String) -> Notification.Name { Notification.Name("\(host).webapp.\(name)") }

    private func post(_ name: String, for app: WebApp, _ info: [String: String]? = nil) {
        DistributedNotificationCenter.default().postNotificationName(
            Self.event(name), object: app.id.uuidString, userInfo: info, deliverImmediately: true)
    }

    /// a small native app that holds the Dock tile and hands itself to this Artemis; a script
    /// bundle doing only the handing over when the helper is missing
    private func writeLauncher(for app: WebApp, favicon: NSImage? = nil, fallback: NSImage? = nil) {
        let bundle = launcher(of: app)
        let contents = bundle.appending(path: "Contents")
        let fm = FileManager.default
        guard (try? fm.createDirectory(at: contents.appending(path: "MacOS"), withIntermediateDirectories: true)) != nil,
            (try? fm.createDirectory(at: contents.appending(path: "Resources"), withIntermediateDirectories: true)) != nil
        else { return }
        let native = fm.fileExists(atPath: Self.shimBinary.path)
        let executable = contents.appending(path: "MacOS/launch")
        // rewritten in place: a running launcher's open of its own bundle must never find it missing
        try? fm.removeItem(at: executable)
        var info: [String: Any] = [
            "CFBundleExecutable": "launch",
            "CFBundleIdentifier": shimID(app),
            "CFBundleName": app.name,
            "CFBundleIconFile": "AppIcon",
            "CFBundlePackageType": "APPL",
            "NSHighResolutionCapable": true,
            Self.idKey: app.id.uuidString,
            "ArtemisHost": Self.host,
        ]
        if native {
            info["ArtemisShim"] = Self.shimVersion
            try? fm.copyItem(at: Self.shimBinary, to: executable)
        } else {
            info["LSUIElement"] = true
            try? "#!/bin/sh\nexec /usr/bin/open -b '\(Self.host)' \"${0%/Contents/MacOS/*}\"\n"
                .write(to: executable, atomically: true, encoding: .utf8)
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        }
        (info as NSDictionary).write(to: contents.appending(path: "Info.plist"), atomically: true)
        let icon = dockIcon(of: app, favicon: favicon) ?? fallback ?? glyphPlate(String(app.name.prefix(1)).uppercased(), of: app)
        try? icon.png()?.write(to: contents.appending(path: "Resources/icon.png"))
        Self.writeICNS(icon, to: contents.appending(path: "Resources/AppIcon.icns"))
        if native {
            let sign = Process()
            sign.executableURL = URL(filePath: "/usr/bin/codesign")
            sign.arguments = ["--force", "--sign", "-", bundle.path]
            sign.standardError = FileHandle.nullDevice
            try? sign.run()
            sign.waitUntilExit()
        }
        NSWorkspace.shared.noteFileSystemChanged(bundle.path)
    }

    // MARK: - Icon

    /// what the Dock shows for `app`: its favicon, glyph or picked image on a plate of the macOS icon grid
    func dockIcon(of app: WebApp, favicon: NSImage? = nil) -> NSImage? {
        switch app.icon {
        case .favicon:
            guard let image = favicon ?? FaviconStore.shared.icon(for: app.url.host()) else { return nil }
            let light = FaviconStore.isLight(image)
            return Self.plate(light ? NSColor(white: 0.12, alpha: 1) : .white) { image.draw(in: $0.insetBy(dx: 192, dy: 192)) }
        case .image:
            guard let image = NSImage(contentsOf: Self.pickedImage(of: app)) else { return nil }
            return Self.plate(.white) { plate in
                let scale = max(plate.width / image.size.width, plate.height / image.size.height)
                let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
                image.draw(in: NSRect(x: plate.midX - size.width / 2, y: plate.midY - size.height / 2, width: size.width, height: size.height))
            }
        case .glyph(let glyph):
            return glyphPlate(glyph, of: app)
        }
    }

    /// an emoji, SF Symbol or letter on the plate colour
    private func glyphPlate(_ glyph: String, of app: WebApp) -> NSImage {
        let fill = NSColor(plateColour(of: app))
        let ink: NSColor = fill.isLight ? NSColor(white: 0.1, alpha: 1) : .white
        return Self.plate(fill) { plate in
            if let symbol = NSImage(systemSymbolName: glyph, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 400, weight: .medium).applying(.init(paletteColors: [ink])))
            {
                let size = symbol.size
                symbol.draw(in: NSRect(x: plate.midX - size.width / 2, y: plate.midY - size.height / 2, width: size.width, height: size.height))
            } else {
                let font = glyph.isEmojiIcon ? NSFont.systemFont(ofSize: 440) : NSFont.systemFont(ofSize: 480, weight: .semibold)
                let text = NSAttributedString(string: glyph, attributes: [.font: font, .foregroundColor: ink])
                let size = text.size()
                text.draw(at: NSPoint(x: plate.midX - size.width / 2, y: plate.midY - size.height / 2))
            }
        }
    }

    /// the icon a launcher already wears: its own PNG, else the Finder icon an older Artemis set
    private static func existingIcon(of bundle: URL) -> NSImage? {
        if let png = NSImage(contentsOf: bundle.appending(path: "Contents/Resources/icon.png")) { return png }
        guard FileManager.default.fileExists(atPath: bundle.appending(path: "Icon\r").path) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: bundle.path)
        icon.size = NSSize(width: 1024, height: 1024)
        return icon
    }

    /// a glyph sits on the window's colour, or the space's accent under glass
    private func plateColour(of app: WebApp) -> Color {
        switch app.look {
        case .solid, .gradient: return app.appearance.colors.first?.color ?? .accentColor
        default:
            let spaces = BrowserWindows.shared.browserScope?.spaces ?? []
            return app.space(in: spaces)?.appearance.accent ?? .accentColor
        }
    }

    /// 824 of 1024 points, corner radius 185, clipped to the plate
    private static func plate(_ fill: NSColor, _ draw: @escaping (NSRect) -> Void) -> NSImage {
        NSImage(size: NSSize(width: 1024, height: 1024), flipped: false) { _ in
            let plate = NSRect(x: 100, y: 100, width: 824, height: 824)
            let shape = NSBezierPath(roundedRect: plate, xRadius: 185, yRadius: 185)
            fill.setFill()
            shape.fill()
            shape.addClip()
            draw(plate)
            return true
        }
    }

    /// each icns slot wants a rep drawn at its own size
    private static func writeICNS(_ icon: NSImage, to url: URL) {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.icns.identifier as CFString, 4, nil)
        else { return }
        for (pixels, dpi) in [(256, 72), (512, 72), (512, 144), (1024, 144)] {
            guard let image = icon.rendered(pixels: pixels) else { continue }
            CGImageDestinationAddImage(
                destination, image, [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary)
        }
        CGImageDestinationFinalize(destination)
    }
}

private extension NSImage {
    func rendered(pixels: Int) -> CGImage? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }

    func png() -> Data? {
        rendered(pixels: 1024).map { NSBitmapImageRep(cgImage: $0) }?.representation(using: .png, properties: [:])
    }
}

private extension NSColor {
    var isLight: Bool {
        let c = usingColorSpace(.sRGB) ?? .gray
        return 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent > 0.6
    }
}
