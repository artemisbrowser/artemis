// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import AppKit
import WebKit

/// an empty animation controller: claiming a force click without WebKit's
/// preview. WebKit only accepts one that conforms to AppKit's (unexported)
/// NSImmediateActionAnimationController, so the conformance is added at runtime
private final class PeekActionController: NSObject {
    private static let conforms: Void = {
        if let p = objc_getProtocol("NSImmediateActionAnimationController") {
            class_addProtocol(PeekActionController.self, p)
        }
    }()

    override init() {
        _ = Self.conforms
        super.init()
    }
}

/// the web view behind every tab: a force click on a link opens Peek, and the
/// context menu gains extension items, which WebKit builds but an embedder must
/// splice in itself from `willOpenMenu`
final class ArtemisWebView: WKWebView {
    /// set by `BrowserTab.configureWebView`; weak, since the tab owns the view
    weak var owningTab: BrowserTab?
    /// the link a force click is pressing on, claimed from WebKit's own
    /// force-click gesture so WebKit also drops the click that ends it
    private var forcedLink: URL?

    /// WebKit SPI: a force click is starting over `hitTestResult`. a link claims
    /// it (opening Peek, not Quick Look); anything else gets the system's (nil)
    @objc(_immediateActionAnimationControllerForHitTestResult:withType:userData:)
    func immediateActionController(_ hitTestResult: NSObject, type: Int, userData: AnyObject?) -> AnyObject? {
        let url = hitTestResult.value(forKey: "absoluteLinkURL") as? URL
        guard let url, url.scheme == "http" || url.scheme == "https" else {
            forcedLink = nil
            return nil
        }
        forcedLink = url
        // WebKit has just drawn its yellow link highlight; clear it before it grows
        dismissLinkHighlight()
        return PeekActionController()
    }

    /// WebKit SPI: the force click went all the way down. Peek opens after the
    /// press's mouse-up has reached this page, or the page is left thinking the
    /// button is still held
    @objc(_completeImmediateActionAnimation)
    func completeImmediateAction() {
        dismissLinkHighlight()
        guard let url = forcedLink else { return }
        forcedLink = nil
        guard NSEvent.pressedMouseButtons & 1 != 0 else {
            DispatchQueue.main.async { [weak self] in self?.owningTab?.onOpenLink?(url, .peek) }
            return
        }
        var monitor: Any?
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            if let monitor { NSEvent.removeMonitor(monitor) }
            DispatchQueue.main.async { self?.owningTab?.onOpenLink?(url, .peek) }
            return event
        }
    }

    private func dismissLinkHighlight() {
        let dismiss = Selector(("_dismissContentRelativeChildWindows"))
        if responds(to: dismiss) { perform(dismiss) }
    }

    @objc(_cancelImmediateActionAnimation)
    func cancelImmediateAction() { forcedLink = nil }

    /// the login keys over this page, which go wherever a page slot holds it
    var loginKeys: LoginKeys?

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        loginKeys?.mount()
    }

    /// where and when the page was last pressed, in window points: a download flies from the click that started it
    private(set) var lastPress: (point: NSPoint, at: Date)?

    override func mouseDown(with event: NSEvent) {
        lastPress = (event.locationInWindow, .now)
        super.mouseDown(with: event)
    }

    /// login keys stand aside while the page moves under them, before WebKit scrolls or zooms it
    override func scrollWheel(with event: NSEvent) {
        loginKeys?.settle()
        super.scrollWheel(with: event)
    }

    override func magnify(with event: NSEvent) {
        loginKeys?.settle()
        super.magnify(with: event)
    }

    override func smartMagnify(with event: NSEvent) {
        loginKeys?.settle()
        super.smartMagnify(with: event)
    }

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        guard let tab = owningTab else { return }

        // WebKit only offers Copy when there is a selection, so its presence is
        // the signal — the selection itself can only be read asynchronously, and
        // a menu is built synchronously
        if menu.items.contains(where: { $0.identifier?.rawValue.hasSuffix("Copy") == true }) {
            let translate = NSMenuItem(
                title: "Translate Selection…", action: #selector(translateSelection), keyEquivalent: "")
            translate.target = self
            menu.addItem(.separator())
            menu.addItem(translate)
        }

        let extensionItems = (tab.manager.map(ExtensionManager.shared.enabledExtensions(in:)) ?? [])
            .filter { $0.context.isLoaded }
            .flatMap { $0.context.menuItems(for: tab) }
        guard !extensionItems.isEmpty else { return }
        menu.addItem(.separator())
        extensionItems.forEach { menu.addItem($0) }
    }

    @objc private func translateSelection() {
        guard let tab = owningTab else { return }
        Task { @MainActor in await tab.translateSelection() }
    }
}
