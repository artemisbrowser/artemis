// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import AppKit
import WebKit

/// Native keys over the login fields a page reports, mounted above the tab's web view in the page slot
/// holding it. The page never sees them: its script only measures.
final class LoginKeys: NSView {
    private struct Spot: Equatable {
        let id: Int
        let frame: CGRect
        let dark: Bool
    }

    private struct Reporter {
        var frame: WKFrameInfo
        var origin: String
        var spots: [Spot] = []
        var keys: [NSButton] = []
    }

    /// WebKit leaves the cursor alone inside a cursor rect; scrolls, zooms and right clicks go on to the page
    private final class Key: NSButton {
        weak var webView: ArtemisWebView?
        override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
        override func scrollWheel(with event: NSEvent) { webView?.scrollWheel(with: event) }
        override func magnify(with event: NSEvent) { webView?.magnify(with: event) }
        override func smartMagnify(with event: NSEvent) { webView?.smartMagnify(with: event) }
        override func rightMouseDown(with event: NSEvent) { webView?.rightMouseDown(with: event) }
        override func rightMouseUp(with event: NSEvent) { webView?.rightMouseUp(with: event) }
    }

    /// a key's side, in points
    static let side: CGFloat = 22
    private static let glyph = NSImage(systemSymbolName: "key.fill", accessibilityDescription: "Passwords")?
        .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))

    private weak var webView: ArtemisWebView?
    private var reporters: [AnyHashable: Reporter] = [:]
    /// a report still resolving its frame's offset yields to any newer one from that frame
    private var tickets: [AnyHashable: Int] = [:]
    private var lastTicket = 0
    private var settling: Task<Void, Never>?
    private var defaultsObserver: NSObjectProtocol?

    override var isFlipped: Bool { true }

    var tracksMainFrame: Bool { reporters.values.contains { $0.frame.isMainFrame } }

    /// `webView`'s keys, made for the first report that has any; they go, and every frame reporting them
    /// stops measuring, when suggestions are turned off
    static func on(_ webView: WKWebView, making: Bool = false) -> LoginKeys? {
        guard let webView = webView as? ArtemisWebView else { return nil }
        if let keys = webView.loginKeys { return keys }
        guard making else { return nil }
        let keys = LoginKeys()
        keys.webView = webView
        keys.autoresizingMask = [.width, .height]
        webView.loginKeys = keys
        keys.mount()
        keys.watchLogins()
        keys.defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak keys] _ in
            MainActor.assumeIsolated {
                guard let keys, !PasswordStore.shared.fillsFromSuggestions else { return }
                for reporter in keys.reporters.values {
                    keys.webView?.evaluateJavaScript(
                        "globalThis.__artemisPasswords?.stop()", in: reporter.frame, in: PasswordPage.world)
                }
                keys.clear()
            }
        }
        return keys
    }

    deinit {
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
    }

    /// WebKit's frame handle (SPI), else where the frame is
    static func key(_ frame: WKFrameInfo) -> AnyHashable {
        let handle = Selector(("_handle"))
        if frame.responds(to: handle), let id = frame.perform(handle)?.takeUnretainedValue() as? NSObject { return id }
        return "\(frame.isMainFrame) \(frame.request.url?.absoluteString ?? "")"
    }

    /// a change to the saved logins measures every frame again, under what its origin now has
    private func watchLogins() {
        withObservationTracking { _ = PasswordStore.shared.logins } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.settle()
                self?.watchLogins()
            }
        }
    }

    /// above the web view while a page slot holds it, so never in the mini-player
    func mount() {
        guard let webView, let host = webView.superview as? WebHostView else { return removeFromSuperview() }
        frame = host.bounds
        host.addSubview(self, positioned: .above, relativeTo: webView)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        settle()
    }

    func ticket(for frame: WKFrameInfo) -> Int {
        lastTicket += 1
        tickets[Self.key(frame)] = lastTicket
        return lastTicket
    }

    /// `list` is the frame's whole report, centres in top-document CSS px as far as the frame could
    /// resolve them; `offset` adds the rest, nil when its frame can't be placed in the page
    func place(_ list: [[String: Any]], from frame: WKFrameInfo, origin: String, offset: CGPoint?, ticket: Int) {
        let key = Self.key(frame)
        guard tickets[key] == ticket else { return }
        var spots: [Spot] = []
        if settling == nil, let offset, let webView {
            let scale = webView.pageZoom * webView.magnification
            for item in list {
                guard let id = item["id"] as? Int, let x = item["x"] as? Double, let y = item["y"] as? Double,
                    let size = item["size"] as? Double
                else { continue }
                let side = size * scale
                var spot = CGRect(
                    x: (x + offset.x) * scale - side / 2, y: (y + offset.y) * scale - side / 2, width: side, height: side)
                if !webView.isFlipped { spot.origin.y = webView.bounds.height - spot.maxY }
                spot = convert(spot, from: webView)
                if bounds.contains(spot) { spots.append(Spot(id: id, frame: spot, dark: item["dark"] as? Bool == true)) }
            }
        }
        var reporter = reporters[key] ?? Reporter(frame: frame, origin: origin)
        (reporter.frame, reporter.origin) = (frame, origin)
        if reporter.spots != spots {
            reporter.keys.forEach { $0.removeFromSuperview() }
            reporter.keys = spots.map { spot in
                let button = Key(image: Self.glyph ?? NSImage(), target: self, action: #selector(press))
                button.webView = webView
                button.frame = spot.frame
                button.isBordered = false
                button.refusesFirstResponder = true
                button.tag = spot.id
                button.appearance = NSAppearance(named: spot.dark ? .darkAqua : .aqua)
                button.contentTintColor = .secondaryLabelColor
                button.setAccessibilityLabel("Passwords")
                addSubview(button)
                return button
            }
            reporter.spots = spots
        }
        reporters[key] = reporter
    }

    func forget(_ frame: WKFrameInfo) { drop(Self.key(frame)) }

    private func drop(_ key: AnyHashable) {
        reporters.removeValue(forKey: key)?.keys.forEach { $0.removeFromSuperview() }
        tickets[key] = nil
    }

    /// the main frame committed a new document
    func clear() {
        reporters.keys.forEach(drop)
        tickets = [:]
        settling?.cancel()
        settling = nil
    }

    /// hides every key until the page has held still for 150 ms, then asks each frame where they go
    func settle() {
        guard !reporters.isEmpty else { return }
        for key in reporters.keys {
            reporters[key]?.keys.forEach { $0.removeFromSuperview() }
            reporters[key]?.keys = []
            reporters[key]?.spots = []
        }
        settling?.cancel()
        settling = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, !Task.isCancelled else { return }
            settling = nil
            guard window != nil, let tab = webView?.owningTab else { return }
            for (key, reporter) in reporters where !Task.isCancelled {
                if await !PasswordAutofill.shared.trackKeys(in: reporter.frame, origin: reporter.origin, of: tab) {
                    drop(key)
                }
            }
        }
    }

    @objc private func press(_ sender: NSButton) {
        guard let reporter = reporters.values.first(where: { $0.keys.contains(sender) }), let tab = webView?.owningTab
        else { return }
        PasswordAutofill.shared.openKey(sender.tag, in: reporter.frame, of: tab)
    }
}
