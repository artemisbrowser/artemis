import SwiftUI
import WebKit

/// a stable slot that owns where a tab's `WKWebView` lives in the main window.
/// handing SwiftUI this container (rather than the raw web view) lets the
/// mini-player borrow the live web view into a floating panel and hand it back
/// without SwiftUI tearing the web view down — the slot just sits empty while
/// the panel owns the view.
final class WebHostView: NSView {
    /// the page this slot shows, for the still that stands in when another
    /// window is holding the live web view
    weak var tab: BrowserTab?
    /// the last frame of the page, shown while another window has the real thing
    private let still = NSImageView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        // the hosted page is deliberately allowed to be larger than this view
        // while a resize is in flight (see `layout()`), so the overflow has to
        // be clipped rather than drawn over the rest of the window
        clipsToBounds = true
        still.imageScaling = .scaleProportionallyUpOrDown
        still.autoresizingMask = [.width, .height]
        still.isHidden = true
        addSubview(still)
        observeKeyWindow()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used from a nib") }

    /// put the web view back in this slot, unless the mini-player currently owns
    /// it (`borrowed`), in which case the slot is left empty.
    ///
    /// A `WKWebView` is one view and can live in one window, so two windows on
    /// the same page can't both show it live. The focused window takes it; the
    /// other shows the last frame it had.
    func host(_ webView: WKWebView, borrowed: Bool) {
        guard !borrowed else {
            if webView.superview === self { webView.removeFromSuperview() }
            return
        }
        guard webView.superview !== self else { return }
        guard canTakeLiveView(webView) else { return showStill() }
        webView.removeFromSuperview()
        webView.frame = bounds
        // the page's frame is managed in `layout()`, not by springs — see there
        webView.autoresizingMask = []
        addSubview(webView)
        hideStill()
        focusHostedWebView()
    }

    /// free, already ours, or held by a browser window that isn't the focused
    /// one. The mini-player's panel is not a browser window — it lends the view
    /// out and hands it straight back, so its claim is never deferred to
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

    /// the still is only what this slot shows while another window has the page;
    /// it is refreshed on re-render so a snapshot that lands late still appears
    func showStill() {
        still.image = tab?.stillFrame
        still.frame = bounds
        still.isHidden = still.image == nil
    }

    private func hideStill() {
        still.isHidden = true
        still.image = nil
    }

    /// take the page back when this window comes forward, and keep a fresh still
    /// for the window that is about to lose it
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

    /// only pages on screen in more than one window need a still — everywhere
    /// else the slot either has the live view or nothing to stand in for
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

    /// Give the page a frame that *covers* the host while the host is being
    /// animated, and the exact frame once it stops.
    ///
    /// Resizing a `WKWebView` is not a cheap operation dressed up as a frame
    /// change: the page relayouts, repaints, and hands Core Animation a brand
    /// new IOSurface — and attaching one costs a colour-space construction from
    /// ICC data (ColorSync, an MD5 and a gamma curve check) every single time.
    /// In a profile of the sidebar animation that chain was the heaviest thing
    /// in the app, because a spring-driven sidebar changes the card's width
    /// something like fifty times per toggle and every one of those frames paid
    /// for it.
    ///
    /// A page that is *larger* than its host looks identical — the excess is
    /// clipped — so during a run of size changes the page is left at whichever
    /// size covers both where it was and where it's going, and reflows once, at
    /// the end. The page slides with the card instead of reflowing under it,
    /// which is also the nicer of the two.
    override func layout() {
        super.layout()
        guard let webView = subviews.first(where: { $0 is WKWebView }) as? WKWebView else { return }
        guard PerfFlags.settlesPageResize else {
            if webView.frame != bounds { webView.frame = bounds }
            return
        }

        // A *shrinking* host was covered by this — the page stays at its old,
        // larger size and nothing reflows. A growing one was not: the host
        // overtook the page on every frame, so every frame set a new frame and
        // paid the full relayout/IOSurface cost this exists to avoid. Grow in a
        // couple of big steps instead — the page only has to cover the host, and
        // the excess is clipped, so overshooting lets the next dozen frames land
        // inside the page that is already there.
        let page = webView.frame.size
        let covering =
            isResizing
            ? CGSize(
                width: page.width >= bounds.width ? page.width : bounds.width * Self.growthStep,
                height: page.height >= bounds.height
                    ? page.height : bounds.height * Self.growthStep)
            : bounds.size
        // AppKit's origin is bottom-left; anchor the page to the *top* left so a
        // taller-than-host page hangs off the bottom rather than hiding its head
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

    /// A slot with no window yet can't claim the page (it has no window to
    /// compare against), so it claims here instead — the first moment it can.
    /// Re-checking beats trusting the mount: the slot the page is coming *from*
    /// is torn down in the same update pass
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, let tab { host(tab.webView, borrowed: tab.isMiniPlayerActive) }
        focusHostedWebView()
    }

    /// true while this slot holds the real page rather than a still
    var hostsLiveView: Bool { subviews.contains { $0 is WKWebView } }
}

/// hosts a tab's `WKWebView` in SwiftUI
///
/// the web view is owned by the tab (so it survives view rebuilds);
/// callers must apply `.id(tab.id)` so SwiftUI swaps the hosted view
/// when the selected tab changes
struct WebViewContainer: NSViewRepresentable {
    /// fills what it's offered, sparing SwiftUI an Auto Layout measurement of its subtree
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSViewType, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    let tab: BrowserTab
    /// false for a page that is mounted but not being looked at (the pages held
    /// behind the current one, and the neighbouring spaces' pages). `.opacity(0)`
    /// is not enough: an invisible-but-unhidden `WKWebView` is still *visible* as
    /// far as WebKit is concerned, so it keeps running `requestAnimationFrame`,
    /// keeps painting, and keeps its full render pipeline warm — measurably, a
    /// second page held that way cost more web-process CPU than re-attaching it
    /// from scratch would have. Hiding the host makes AppKit send `viewDidHide`
    /// down the subtree, which is what actually tells WebKit the page is not on
    /// screen (the same signal a background Safari tab gets).
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
        // the mini-player hands the view back to whichever slot last asked for
        // it; a slot showing a still isn't that slot
        if nsView.hostsLiveView { tab.webHost = nsView } else { nsView.showStill() }
        // reading `isMiniPlayerActive` here ties the slot to the flag: when the
        // mini-player hands the view back, this re-runs and re-hosts the view.
        nsView.host(tab.webView, borrowed: tab.isMiniPlayerActive)
        let hidden = !isVisible && PerfFlags.hidesOffscreenPages
        if nsView.isHidden != hidden {
            nsView.isHidden = hidden
            // coming back on screen is the same moment as being mounted, as far
            // as focus goes: a page that isn't first responder reads
            // `document.hasFocus()` as false, which is enough to make
            // focus-gated video players refuse to start
            if !hidden { nsView.focusHostedWebView() }
        }
    }
}
