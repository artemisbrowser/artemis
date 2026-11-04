import SwiftUI
import WebKit

/// a stable slot for a tab's `WKWebView` in a browser window; it sits empty while
/// the mini-player borrows the view, so SwiftUI never tears the view down
final class WebHostView: NSView {
    weak var tab: BrowserTab?
    /// the last frame of the page, shown while another window has the real thing
    private let still = NSImageView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        // the page may outgrow this view mid-resize (see `layout()`)
        clipsToBounds = true
        still.imageScaling = .scaleProportionallyUpOrDown
        still.autoresizingMask = [.width, .height]
        still.isHidden = true
        addSubview(still)
        observeKeyWindow()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used from a nib") }

    /// puts the web view in this slot unless the mini-player has it. a web view
    /// lives in one window: the focused one takes it, others show its last frame
    func host(_ webView: WKWebView, borrowed: Bool) {
        guard !borrowed else {
            if webView.superview === self { webView.removeFromSuperview() }
            return
        }
        guard webView.superview !== self else { return }
        guard canTakeLiveView(webView) else { return showStill() }
        // a page renders in its window's colour space. a named one reaches Core
        // Animation as a number; a display's ICC profile is re-parsed per surface
        if window?.colorSpace != .displayP3 { window?.colorSpace = .displayP3 }
        webView.removeFromSuperview()
        webView.frame = bounds
        // the page's frame is managed in `layout()`
        webView.autoresizingMask = []
        addSubview(webView)
        hideStill()
        focusHostedWebView()
    }

    /// free, already ours, or held by an unfocused browser window. the mini-player's
    /// panel isn't a browser window, so its claim is never deferred to
    private func canTakeLiveView(_ webView: WKWebView) -> Bool {
        guard let window else { return false }
        guard let holder = webView.window, holder !== window else { return true }
        guard BrowserWindows.shared.manager(for: holder) != nil else { return true }
        return window.isKeyWindow
    }

    /// the other window took the live view: stand its last frame in its place
    override func willRemoveSubview(_ subview: NSView) {
        super.willRemoveSubview(subview)
        if subview is WKWebView { showStill() }
    }

    /// called on every re-render, so a snapshot that lands late still appears
    func showStill() {
        still.image = tab?.stillFrame
        still.frame = bounds
        still.isHidden = still.image == nil
    }

    private func hideStill() {
        still.isHidden = true
        still.image = nil
    }

    /// takes the page back when this window comes forward, and stills it when it goes back
    private func observeKeyWindow() {
        let center = NotificationCenter.default
        center.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let tab = self.tab,
                    note.object as? NSWindow === self.window
                else { return }
                self.host(tab.webView, borrowed: tab.isMiniPlayerActive)
            }
        }
        center.addObserver(
            forName: NSWindow.didResignKeyNotification, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let tab = self.tab,
                    note.object as? NSWindow === self.window,
                    tab.webView.superview === self
                else { return }
                self.captureStill(of: tab)
            }
        }
    }

    /// only pages on screen in more than one window need a still
    private func captureStill(of tab: BrowserTab) {
        let showing = BrowserWindows.shared.allManagers.filter { $0.isShowing(tab) }
        guard showing.count > 1 else { return }
        let configuration = WKSnapshotConfiguration()
        configuration.rect = tab.webView.bounds
        tab.webView.takeSnapshot(with: configuration) { image, _ in
            MainActor.assumeIsolated { tab.stillFrame = image }
        }
    }

    // MARK: - Resize settling

    /// how far past the host a growing page is sized, so a run of growth frames
    /// costs two relayouts rather than one per frame
    private static let growthStep: CGFloat = 1.15

    /// fires once the host has stopped changing size
    private var settleTask: Task<Void, Never>?
    /// true between the first layout of a run and the settle
    private var isResizing = false

    /// gives the page a frame that covers the host while the host animates, and
    /// the exact frame once it stops: each `WKWebView` resize is a full relayout
    /// and a new IOSurface, and the clipped excess looks identical
    override func layout() {
        super.layout()
        guard let webView = subviews.first(where: { $0 is WKWebView }) as? WKWebView else { return }
        guard PerfFlags.settlesPageResize else {
            if webView.frame != bounds { webView.frame = bounds }
            return
        }

        // a shrinking host keeps the larger page; a growing one is covered in steps
        let page = webView.frame.size
        let covering =
            isResizing
            ? CGSize(
                width: page.width >= bounds.width ? page.width : bounds.width * Self.growthStep,
                height: page.height >= bounds.height
                    ? page.height : bounds.height * Self.growthStep)
            : bounds.size
        setPageFrame(webView, size: covering)

        isResizing = true
        settleTask?.cancel()
        settleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, let self else { return }
            isResizing = false
            if let webView = subviews.first(where: { $0 is WKWebView }) as? WKWebView {
                setPageFrame(webView, size: bounds.size)
            }
        }
    }

    /// anchored top-left in AppKit's bottom-left space, so a tall page overhangs the bottom
    private func setPageFrame(_ webView: WKWebView, size: CGSize) {
        let frame = CGRect(
            x: bounds.minX, y: bounds.maxY - size.height,
            width: size.width, height: size.height)
        guard webView.frame != frame else { return }
        webView.frame = frame
    }

    /// an http(s) page shown in the key window becomes first responder, so
    /// `document.hasFocus()` holds; on mount and tab switch only, and never over
    /// the field of a command bar that stays open
    func focusHostedWebView() {
        guard let window, window.isKeyWindow,
            !(window.firstResponder is NSText && tab?.manager?.isCommandBarVisible == true),
            let webView = subviews.first(where: { $0 is WKWebView }) as? WKWebView,
            let scheme = webView.url?.scheme, scheme == "http" || scheme == "https"
        else { return }
        window.makeFirstResponder(webView)
    }

    /// a slot can't claim the page until it has a window to compare against
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, let tab { host(tab.webView, borrowed: tab.isMiniPlayerActive) }
        focusHostedWebView()
    }

    /// true while this slot holds the real page rather than a still
    var hostsLiveView: Bool { subviews.contains { $0 is WKWebView } }
}

/// hosts a tab's `WKWebView` in SwiftUI. the tab owns the web view; callers key
/// this with `.id` on the tab and its `webViewGeneration`
struct WebViewContainer: NSViewRepresentable {
    /// fills what it's offered, sparing SwiftUI an Auto Layout measurement of its subtree
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSViewType, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    let tab: BrowserTab
    /// false for a page mounted but not looked at. only hiding the host tells
    /// WebKit the page is off screen; at `.opacity(0)` it keeps rendering
    var isVisible = true

    func makeNSView(context: Context) -> WebHostView {
        let container = WebHostView()
        container.tab = tab
        tab.webHost = container
        container.host(tab.webView, borrowed: tab.isMiniPlayerActive)
        container.isHidden = !isVisible && PerfFlags.hidesOffscreenPages
        return container
    }

    func updateNSView(_ nsView: WebHostView, context: Context) {
        nsView.tab = tab
        // the mini-player hands the view back to whichever slot last asked for it
        if nsView.hostsLiveView { tab.webHost = nsView } else { nsView.showStill() }
        // reading `isMiniPlayerActive` re-runs this when the mini-player hands the view back
        nsView.host(tab.webView, borrowed: tab.isMiniPlayerActive)
        let hidden = !isVisible && PerfFlags.hidesOffscreenPages
        if nsView.isHidden != hidden {
            nsView.isHidden = hidden
            // a page that isn't first responder reads `document.hasFocus()` as
            // false, which focus-gated video players refuse to start on
            if !hidden { nsView.focusHostedWebView() }
        }
    }
}

/// the card's mounted pages, one `WebHostView` each, in a single AppKit view.
/// only the shown page and the one it fades in over are unhidden
struct PageStack: NSViewRepresentable {
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSViewType, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    let tabs: [BrowserTab]
    let shownID: BrowserTab.ID?

    func makeNSView(context: Context) -> PageStackView {
        let view = PageStackView()
        view.update(tabs: tabs, shownID: shownID)
        return view
    }

    func updateNSView(_ view: PageStackView, context: Context) {
        view.update(tabs: tabs, shownID: shownID)
    }
}

final class PageStackView: NSView {
    private var hosts: [BrowserTab.ID: (host: WebHostView, generation: Int)] = [:]
    private var shownID: BrowserTab.ID?
    /// held opaque under the incoming page until its fade lands
    private var fadingID: BrowserTab.ID?
    private var fadeToken = 0

    init() {
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func update(tabs: [BrowserTab], shownID new: BrowserTab.ID?) {
        let mounted = Set(tabs.map(\.id))
        for (id, entry) in hosts where !mounted.contains(id) {
            entry.host.removeFromSuperview()
            hosts[id] = nil
        }
        let switched = new != shownID
        if switched {
            fadingID = shownID.flatMap { mounted.contains($0) ? $0 : nil }
            shownID = new
        }
        for tab in tabs {
            if let entry = hosts[tab.id], entry.generation == tab.webViewGeneration {
                // the mini-player hands the view back to whichever slot last asked for it
                if entry.host.hostsLiveView { tab.webHost = entry.host } else { entry.host.showStill() }
                entry.host.host(tab.webView, borrowed: tab.isMiniPlayerActive)
                continue
            }
            hosts[tab.id]?.host.removeFromSuperview()
            let host = WebHostView(frame: bounds)
            host.wantsLayer = true
            host.tab = tab
            tab.webHost = host
            // hidden before it joins the window, so a warm page never starts out visible
            host.isHidden = isHidden(tab.id)
            addSubview(host)
            host.host(tab.webView, borrowed: tab.isMiniPlayerActive)
            hosts[tab.id] = (host, tab.webViewGeneration)
        }
        applyVisibility()
        if switched { fade() }
    }

    private func isHidden(_ id: BrowserTab.ID) -> Bool {
        id != shownID && id != fadingID && PerfFlags.hidesOffscreenPages
    }

    private func applyVisibility() {
        for (id, entry) in hosts {
            let host = entry.host
            host.layer?.zPosition = id == shownID ? 2 : (id == fadingID ? 1 : 0)
            host.alphaValue = id == shownID || id == fadingID ? 1 : 0
            let hidden = isHidden(id)
            guard host.isHidden != hidden else { continue }
            host.isHidden = hidden
            // a page that isn't first responder reads `document.hasFocus()` as
            // false, which focus-gated video players refuse to start on
            if !hidden { host.focusHostedWebView() }
        }
    }

    /// the incoming page fades in over the outgoing one; with no incoming page
    /// the outgoing one fades out instead
    private func fade() {
        fadeToken += 1
        let token = fadeToken
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.duration = Motion.contentSwapDuration
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, token == fadeToken else { return }
            fadingID = nil
            applyVisibility()
        }
        if let id = shownID, let layer = hosts[id]?.host.layer {
            animation.fromValue = 0
            animation.toValue = 1
            layer.add(animation, forKey: "fade")
        } else if let id = fadingID, let host = hosts[id]?.host {
            animation.fromValue = 1
            animation.toValue = 0
            host.alphaValue = 0
            host.layer?.add(animation, forKey: "fade")
        }
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        for (host, _) in hosts.values where host.frame != bounds {
            host.frame = bounds
            host.needsLayout = true
        }
    }

    /// only the shown page takes the pointer; the one fading out under it never does
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let id = shownID, let host = hosts[id]?.host, !host.isHidden else { return nil }
        return host.hitTest(convert(point, from: superview))
    }
}
