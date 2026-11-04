// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import AppKit
import SwiftUI
import WebKit

/// private WKWebView SPI. WebKit derives `document.visibilityState` from window
/// occlusion, and an occluded panel's video freezes for good; off while the
/// mini-player owns the view, back on when the browser has it
@objc private protocol WKWebViewOcclusionSPI {
    func _setWindowOcclusionDetectionEnabled(_ enabled: Bool)
}

/// private WKWebView SPI: runs the block once the web view has put its next
/// frame on screen, so a change made in script is visible, not just applied
@objc private protocol WKWebViewPresentationSPI {
    func _doAfterNextPresentationUpdate(_ updateBlock: @escaping () -> Void)
}

/// one caption track the page exposes
struct CaptionTrack: Identifiable, Equatable {
    let id: String
    let label: String
}

/// the floating mini-player: a borderless panel that borrows the tab's live web
/// view and isolates its video, so playback carries over with no reload. the
/// tab's `WebHostView` sits empty until the view is handed back
@Observable
final class MiniPlayer {
    static let cornerRadiusKey = "pipCornerRadius"
    static let defaultCornerRadius = 16.0
    /// the panel's last on-screen frame, restored next open
    static let frameKey = "pipPanelFrame"
    /// the same for call mode, which keeps its own size and spot
    static let callFrameKey = "pipCallFrame"
    /// call mode: the glass frame's inset around the page, and the control row
    static let callInset: CGFloat = 8
    static let callControlsHeight: CGFloat = 52
    /// how much of a call site's own control bar to crop off the page's bottom
    private static let callBarCrop: [String: CGFloat] = ["meet.google.com": 80]
    /// captions drawn in our overlay (true) or by the website (false)
    static let customCaptionsKey = "pipCustomCaptions"
    /// how far the centre ⟲/⟳ buttons jump, in seconds
    static let skipSecondsKey = "pipSkipSeconds"
    static let defaultSkipSeconds = 10.0

    @ObservationIgnored private var panel: PiPPanel?
    @ObservationIgnored private let motion = PanelMotion()
    /// last polled position, to catch a looping short wrapping back to 0
    @ObservationIgnored private var lastTime = 0.0
    @ObservationIgnored private var switchingShort = false
    /// a seek just sent: poll results stay ignored until the video reports
    /// near it, so the thumb doesn't snap back to where it was
    @ObservationIgnored private var seekTarget: (time: Double, until: Date)?
    @ObservationIgnored private var frameObservers: [NSObjectProtocol] = []
    @ObservationIgnored private(set) weak var tab: BrowserTab?
    @ObservationIgnored var onReturnToBrowser: ((BrowserTab) -> Void)?

    @ObservationIgnored private var pollTimer: Timer?
    /// a faster timer for caption text alone
    @ObservationIgnored private var captionTimer: Timer?
    @ObservationIgnored private var aspectApplied = false

    // playback state, observed by `MiniPlayerChrome`
    private(set) var isPlaying = false
    /// current position; settable so the scrubber can bind to it
    var currentTime = 0.0
    private(set) var duration = 0.0
    private(set) var muted = false
    private(set) var volume = 1.0
    /// pauses position updates
    var isScrubbing = false
    /// pauses volume readback
    var isAdjustingVolume = false
    /// the pointer is over the panel; set from a tracking area, so it never blocks clicks
    var chromeHovering = false
    /// an ad is playing, which blocks seeking
    private(set) var adActive = false
    /// the site's ad-skip control is up; it is pinned, invisible, under our Skip
    /// button so the click falls through to it as a trusted event
    private(set) var isSkippable = false
    private(set) var skipLabel = "Skip"

    // captions
    private(set) var captionCount = 0
    private(set) var captionTracks: [CaptionTrack] = []
    /// id of the live track, "" when off
    private(set) var activeCaptionID = ""
    /// the caption text our overlay draws right now
    private(set) var captionText = ""
    var hasCaptions: Bool { captionCount > 0 }
    var captionsOn: Bool { !activeCaptionID.isEmpty }

    /// page buttons (e.g. "Skip Recap") allowed for this site and showing now; the
    /// drag layer eats page clicks, so pills proxy them into the page
    private(set) var pageButtons: [String] = []

    var isActive: Bool { panel != nil }
    /// the tab holds the camera or microphone: the panel shows the whole page above our call controls
    private(set) var isCall = false
    /// a short-form feed (Shorts, Reels, TikTok): the panel gets up / down
    /// controls and can move on by itself when a video comes round
    private(set) var isShortForm = false
    static let autoScrollKey = "pipAutoScroll"
    var autoScroll = UserDefaults.standard.bool(forKey: MiniPlayer.autoScrollKey) {
        didSet { UserDefaults.standard.set(autoScroll, forKey: Self.autoScrollKey) }
    }

    static func isShortForm(_ url: URL?) -> Bool {
        guard let url, let host = url.host else { return false }
        return (host.hasSuffix("youtube.com") && url.path.hasPrefix("/shorts"))
            || (host.hasSuffix("instagram.com") && url.path.contains("/reel"))
            || host.hasSuffix("tiktok.com")
    }

    /// call controls, read from the site's own buttons (or WebKit's capture
    /// state where the site has none); nil until known
    private(set) var micOn: Bool?
    private(set) var cameraOn: Bool?
    private(set) var canLeave = false

    static func isInCall(_ tab: BrowserTab) -> Bool {
        tab.webView.cameraCaptureState != .none || tab.webView.microphoneCaptureState != .none
    }

    // MARK: - Public entry points

    func toggle(_ tab: BrowserTab) {
        if isActive { close(returnToBrowser: false) } else { open(tab) }
    }

    func enterIfPlaying(_ tab: BrowserTab) {
        guard !isActive, tab.isPlayingMedia || Self.isInCall(tab) else { return }
        open(tab)
    }

    func exitIfActive(for tab: BrowserTab) {
        guard isActive, self.tab === tab else { return }
        close(returnToBrowser: false)
    }

    /// the ✕ button: closes and pauses, but leaves a call running
    func dismiss() { close(returnToBrowser: false, pauseVideo: !isCall) }
    /// hands the page back to the browser, still playing
    func returnToBrowser() { close(returnToBrowser: true) }

    // MARK: - Open / close

    private func open(_ tab: BrowserTab) {
        guard panel == nil else { return }
        let webView = tab.webView
        self.tab = tab
        tab.isMiniPlayerActive = true
        resetState()
        isCall = Self.isInCall(tab)
        isShortForm = !isCall && Self.isShortForm(tab.webView.url)
        let size = isCall ? NSSize(width: 400, height: 340) : NSSize(width: 480, height: 270)

        webView.removeFromSuperview()

        let content = PiPContentView(frame: NSRect(origin: .zero, size: size))
        content.onHover = { [weak self] in self?.chromeHovering = $0 }
        let root: NSView
        let page: NSView
        if isCall {
            let glass = NSGlassEffectView(frame: content.frame)
            glass.appearance = NSAppearance(named: .darkAqua)
            glass.cornerRadius = 22
            glass.tintColor = NSColor(white: 0, alpha: 0.3)
            glass.contentView = content
            root = glass
            let inset = Self.callInset
            let clip = NSView(frame: NSRect(
                x: inset, y: Self.callControlsHeight,
                width: size.width - 2 * inset, height: size.height - Self.callControlsHeight - inset))
            clip.wantsLayer = true
            clip.layer?.cornerRadius = 14
            clip.layer?.cornerCurve = .continuous
            clip.layer?.masksToBounds = true
            clip.autoresizingMask = [.width, .height]
            content.addSubview(clip)
            let crop = webView.url?.host.flatMap { Self.callBarCrop[$0] } ?? 0
            webView.frame = NSRect(
                x: 0, y: -crop, width: clip.bounds.width, height: clip.bounds.height + crop)
            clip.addSubview(webView)
            page = clip
        } else {
            content.wantsLayer = true
            content.layer?.backgroundColor = NSColor.black.cgColor
            let radius = UserDefaults.standard.object(forKey: Self.cornerRadiusKey) as? Double
                ?? Self.defaultCornerRadius
            content.layer?.cornerRadius = radius
            content.layer?.cornerCurve = .continuous
            content.layer?.masksToBounds = true
            webView.frame = content.bounds
            content.addSubview(webView)
            root = content
            page = webView
        }
        webView.autoresizingMask = [.width, .height]
        setOcclusionDetection(false, on: webView)

        let chrome = NSHostingView(rootView: MiniPlayerChrome(player: self))
        chrome.frame = content.bounds
        chrome.autoresizingMask = [.width, .height]
        content.addSubview(chrome)

        let screen = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = NSPoint(x: screen.maxX - size.width - 24, y: screen.minY + 24)
        let panel = PiPPanel(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered, defer: false)
        root.wantsLayer = true
        panel.contentView = root
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // a named colour space, as in `WebHostView.host`, is cheap per surface
        panel.colorSpace = .displayP3
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentMinSize = isCall ? NSSize(width: 280, height: 220) : NSSize(width: 260, height: 150)
        if isCall {
            // the whole glass frame (everything but the page) drags
            panel.isDragHandle = { [weak page] p in !(page?.frame.contains(p) ?? false) }
            panel.locksAspect = false
        } else {
            panel.contentAspectRatio = NSSize(width: 16, height: 9)
        }
        panel.onGestureBegan = { [weak self] in self?.motion.stop() }
        panel.onFling = { [weak self, weak panel] target, velocity in
            guard let self, let panel else { return }
            self.motion.animate(panel, to: target, velocity: velocity)
        }
        let frameKey = isCall ? Self.callFrameKey : Self.frameKey
        var target = panel.frame
        if let saved = UserDefaults.standard.string(forKey: frameKey) {
            let r = NSRectFromString(saved)
            if r.width > 100, r.height > 60,
                NSScreen.screens.contains(where: { $0.frame.intersects(r) }) {
                target = r
            }
        }
        // a video panel stays invisible until isolation, or the whole page flashes in it
        panel.alphaValue = 0
        panel.setFrame(target, display: false)
        panel.orderFrontRegardless()
        self.panel = panel
        if isCall { PanelMotion.appear(panel) }
        let save: (Notification) -> Void = { [weak self, weak panel] _ in
            guard let self, let panel, !self.motion.isRunning else { return }
            UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: frameKey)
        }
        let nc = NotificationCenter.default
        frameObservers = [
            nc.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main, using: save),
            nc.addObserver(forName: NSWindow.didResizeNotification, object: panel, queue: .main, using: save),
        ]

        if isCall { startCallPolling() } else { isolateVideo() }
    }

    func setCornerRadius(_ radius: Double) {
        guard !isCall, let content = panel?.contentView else { return }
        content.layer?.cornerRadius = radius
        content.layer?.cornerCurve = .continuous
        content.layer?.masksToBounds = true
    }

    private func close(returnToBrowser: Bool, pauseVideo: Bool = false) {
        pollTimer?.invalidate()
        pollTimer = nil
        captionTimer?.invalidate()
        captionTimer = nil
        motion.stop()
        guard let tab else { panel?.close(); panel = nil; return }
        let webView = tab.webView

        setOcclusionDetection(true, on: webView)

        // pause while the video is still live
        if pauseVideo {
            webView.evaluateJavaScript("window.__artemisPip && window.__artemisPip.pause()",
                completionHandler: nil)
        }
        webView.evaluateJavaScript("window.__artemisPip && window.__artemisPip.remove()",
            completionHandler: nil)

        frameObservers.forEach(NotificationCenter.default.removeObserver)
        frameObservers = []
        webView.removeFromSuperview()
        panel?.close()
        panel = nil
        tab.isMiniPlayerActive = false

        tab.webHost?.host(webView, borrowed: false)
        self.tab = nil

        if returnToBrowser { onReturnToBrowser?(tab) }
    }

    /// see `WKWebViewOcclusionSPI`
    private func setOcclusionDetection(_ enabled: Bool, on webView: WKWebView) {
        guard webView.responds(to: Selector(("_setWindowOcclusionDetectionEnabled:")))
        else { return }
        unsafeBitCast(webView, to: WKWebViewOcclusionSPI.self)
            ._setWindowOcclusionDetectionEnabled(enabled)
    }

    private func resetState() {
        isPlaying = false
        currentTime = 0
        duration = 0
        muted = false
        volume = 1
        isScrubbing = false
        isAdjustingVolume = false
        chromeHovering = false
        adActive = false
        isSkippable = false
        aspectApplied = false
        captionCount = 0
        captionTracks = []
        activeCaptionID = ""
        captionText = ""
        pageButtons = []
    }

    // MARK: - Chrome actions

    func playPause() { eval("window.__artemisPip && window.__artemisPip.toggle()") }
    func seek(to time: Double) {
        currentTime = time
        seekTarget = (time, Date().addingTimeInterval(1.5))
        eval("window.__artemisPip && window.__artemisPip.seek(\(time))")
    }

    /// jump by the configured interval; `direction` is -1 (back) or +1 (forward)
    func skip(_ direction: Double) {
        let s = max(1, UserDefaults.standard.object(forKey: Self.skipSecondsKey) as? Double
            ?? Self.defaultSkipSeconds)
        var t = currentTime + direction * s
        if duration > 0 { t = min(t, duration) }
        seek(to: max(0, t))
    }

    func toggleMute() {
        tab?.webView.evaluateJavaScript("window.__artemisPip && window.__artemisPip.mute()") {
            [weak self] result, _ in
            self?.muted = (result as? Bool) ?? self?.muted ?? false
        }
    }

    func setVolume(_ value: Double) {
        volume = value
        muted = value <= 0.0001
        eval("window.__artemisPip && window.__artemisPip.setVolume(\(value))")
    }

    /// retries while the list is empty: some players fill it only a beat after
    /// their captions module loads
    func refreshCaptionTracks(retries: Int = 6) {
        tab?.webView.evaluateJavaScript("window.__artemisPip && window.__artemisPip.ccList()") {
            [weak self] result, _ in
            guard let self else { return }
            let rows = (result as? [[String: Any]]) ?? []
            let tracks = rows.compactMap { row -> CaptionTrack? in
                guard let id = row["id"] as? String, let label = row["label"] as? String
                else { return nil }
                return CaptionTrack(id: id, label: label)
            }
            if !tracks.isEmpty || retries <= 0 {
                self.captionTracks = tracks
                self.captionCount = tracks.count
            }
            if tracks.isEmpty, retries > 0, self.isActive {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.refreshCaptionTracks(retries: retries - 1)
                }
            }
        }
    }

    /// "" turns captions off
    func selectCaption(_ id: String) {
        activeCaptionID = id
        let arg = id.isEmpty ? "''" : "'\(id.jsEscaped)'"
        eval("window.__artemisPip && window.__artemisPip.ccSelect(\(arg))")
    }

    /// clicks the visible page button an allowed pill stands for; a click that must
    /// be trusted goes through `setSkipTarget` instead
    func clickPageButton(_ label: String) {
        eval("window.__artemisPip && window.__artemisPip.clickAllowed('\(label.jsEscaped)')")
    }

    /// pins the site's invisible skip button under ours (CSS px == panel points), so
    /// the physical click falls through to it as a trusted event
    func setSkipTarget(_ rect: CGRect) {
        eval("window.__artemisPip && window.__artemisPip.setSkipTarget("
            + "\(Int(rect.minX)), \(Int(rect.minY)), \(Int(rect.width)), \(Int(rect.height)))")
    }

    /// the catalog key for the current site: its host without "www."
    private var siteHost: String? {
        guard var h = tab?.webView.url?.host else { return nil }
        if h.hasPrefix("www.") { h.removeFirst(4) }
        return h
    }

    private func eval(_ js: String) {
        tab?.webView.evaluateJavaScript(js, completionHandler: nil)
    }

    // MARK: - Short-form feeds

    /// the next (1) or previous (-1) video in the feed. the page is let go while
    /// it moves (isolation pins the old video's ancestors), then isolated again
    /// around whichever video is playing, hidden throughout
    func stepShort(_ direction: Int) {
        guard isShortForm, !switchingShort, let webView = tab?.webView, let host = webView.superview
        else { return }
        switchingShort = true
        webView.takeSnapshot(with: nil) { [weak self] image, _ in
            guard let self else { return }
            // the old video holds still on top while the feed moves underneath
            let still = NSImageView(frame: webView.frame)
            still.image = image
            still.imageScaling = .scaleAxesIndependently
            host.addSubview(still, positioned: .above, relativeTo: webView)
            webView.alphaValue = 0
            self.eval("window.__artemisPip && window.__artemisPip.remove()")
            self.eval(Self.stepJS(direction))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                guard let self else { return }
                self.aspectApplied = false
                webView.evaluateJavaScript(Self.applyJS) { [weak self] _, _ in
                    self?.shapeToVideo { self?.slide(from: still, to: webView, direction: direction) }
                }
            }
        }
    }

    /// the old video leaves past one edge as the new one arrives from the other
    private func slide(from still: NSView, to webView: NSView, direction: Int) {
        let rest = webView.frame.origin
        let travel = webView.frame.height * CGFloat(direction)
        webView.setFrameOrigin(NSPoint(x: rest.x, y: rest.y - travel))
        webView.alphaValue = 1
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.38
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
            webView.animator().setFrameOrigin(rest)
            still.animator().setFrameOrigin(NSPoint(x: still.frame.minX, y: still.frame.minY + travel))
        } completionHandler: { [weak self] in
            still.removeFromSuperview()
            self?.switchingShort = false
            self?.lastTime = 0
        }
    }

    /// moves a short-form feed: the site's own next / previous button where it
    /// has one, else the next visible video scrolled into view
    private static func stepJS(_ direction: Int) -> String {
        """
        (function(dir){
          var h = location.hostname;
          var btn = h.indexOf('youtube.com') >= 0
            ? document.querySelector('#navigation-button-' + (dir > 0 ? 'down' : 'up') + ' button')
            : h.indexOf('tiktok.com') >= 0
              ? document.querySelector(dir > 0 ? "[data-e2e='arrow-right']" : "[data-e2e='arrow-left']")
              : null;
          if (btn) { btn.click(); return; }
          var vids = Array.prototype.filter.call(document.querySelectorAll('video'),
            function (v) { return v.getClientRects().length; });
          var mid = innerHeight / 2, cur = -1, best = Infinity;
          vids.forEach(function (v, i) {
            var r = v.getBoundingClientRect(), d = Math.abs((r.top + r.bottom) / 2 - mid);
            if (d < best) { best = d; cur = i; }
          });
          var next = vids[cur + dir];
          if (next) next.scrollIntoView({ block: 'center' }); else scrollBy(0, dir * innerHeight);
        })(\(direction));
        """
    }

    // MARK: - Call controls

    private func startCallPolling() {
        eval(Self.callJS)
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.pollCall() }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        pollCall()
    }

    private func pollCall() {
        guard let webView = tab?.webView else { return }
        webView.evaluateJavaScript("window.__artemisCall && window.__artemisCall.state()") {
            [weak self, weak webView] result, _ in
            guard let self, let webView else { return }
            let d = result as? [String: Any] ?? [:]
            self.micOn = d["mic"] as? Bool ?? (webView.microphoneCaptureState == .none
                ? nil : webView.microphoneCaptureState == .active)
            self.cameraOn = d["cam"] as? Bool ?? (webView.cameraCaptureState == .none
                ? nil : webView.cameraCaptureState == .active)
            self.canLeave = d["leave"] as? Bool ?? false
        }
    }

    /// the site's own button where it has one, else WebKit's capture mute
    func toggleCall(_ kind: String) {
        guard let webView = tab?.webView else { return }
        webView.evaluateJavaScript("window.__artemisCall && window.__artemisCall.toggle('\(kind)')") {
            [weak self, weak webView] result, _ in
            guard let self, let webView else { return }
            if (result as? Bool) != true {
                if kind == "mic" {
                    webView.setMicrophoneCaptureState(
                        webView.microphoneCaptureState == .active ? .muted : .active)
                } else {
                    webView.setCameraCaptureState(webView.cameraCaptureState == .active ? .muted : .active)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.pollCall() }
        }
    }

    func leaveCall() {
        eval("window.__artemisCall && window.__artemisCall.leave()")
    }

    /// finds a call site's mic / camera / leave buttons by their accessible
    /// labels (Meet, Teams and Zoom all label them), skipping settings menus
    private static let callJS = #"""
    window.__artemisCall = window.__artemisCall || (() => {
      const label = b => (b.getAttribute('aria-label') || b.getAttribute('data-tooltip')
        || b.title || b.textContent || '').trim();
      const find = re => [...document.querySelectorAll('button,[role="button"]')]
        .find(b => b.getClientRects().length && re.test(label(b)) && !/settings|options/i.test(label(b)));
      const MIC = /microphone|\bmic\b|^(un)?mute\b/i, CAM = /camera|\bvideo\b/i;
      const LEAVE = /leave call|hang ?up|end call|leave meeting|^leave$/i;
      const on = b => b && !/turn on|unmute|start|camera on|microphone on/i.test(label(b));
      return {
        state() {
          const m = find(MIC), c = find(CAM);
          return { mic: m ? on(m) : null, cam: c ? on(c) : null, leave: !!find(LEAVE) };
        },
        toggle(kind) { const b = find(kind === 'mic' ? MIC : CAM); if (b) b.click(); return !!b; },
        leave() { const b = find(LEAVE); if (b) b.click(); return !!b; },
      };
    })();
    """#

    // MARK: - Video isolation + polling

    private func isolateVideo() {
        guard let webView = tab?.webView else { return }
        webView.evaluateJavaScript(Self.applyJS) { [weak self] result, _ in
            guard let self else { return }
            if (result as? Bool) != true { self.close(returnToBrowser: false); return }
            self.shapeToVideo { [weak self] in
                guard let panel = self?.panel else { return }
                PanelMotion.appear(panel)
            }
            self.startPolling()
            self.refreshCaptionTracks()
            self.applyCaptionRender()
        }
    }

    /// fits the still-invisible panel to the video's shape in one resize
    private func shapeToVideo(then done: @escaping () -> Void) {
        tab?.webView.evaluateJavaScript("window.__artemisPip && window.__artemisPip.state()") {
            [weak self] result, _ in
            guard let self, let panel = self.panel else { return done() }
            if let d = result as? [String: Any], let w = d["w"] as? Double, let h = d["h"] as? Double,
                w > 0, h > 0 {
                self.aspectApplied = true
                panel.contentAspectRatio = NSSize(width: w, height: h)
                panel.setFrame(panel.reshaped(panel.frame, aspect: w / h), display: true)
            }
            self.afterPresentation(done)
        }
    }

    /// `done` once the page's latest change is on screen, so the panel never
    /// shows a frame from before the isolation
    private func afterPresentation(_ done: @escaping () -> Void) {
        guard let webView = tab?.webView,
            webView.responds(to: Selector(("_doAfterNextPresentationUpdate:")))
        else { return done() }
        unsafeBitCast(webView, to: WKWebViewPresentationSPI.self)._doAfterNextPresentationUpdate(done)
    }

    func applyCaptionRender() {
        let custom = UserDefaults.standard.object(forKey: Self.customCaptionsKey) as? Bool ?? true
        eval("window.__artemisPip && window.__artemisPip.setCaptionRender(\(custom))")
    }

    private func startPolling() {
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.pollState()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer

        captionTimer?.invalidate()
        let cap = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.pollCaption()
        }
        RunLoop.main.add(cap, forMode: .common)
        captionTimer = cap
    }

    private func pollCaption() {
        tab?.webView.evaluateJavaScript("window.__artemisPip && window.__artemisPip.caption()") {
            [weak self] result, _ in
            self?.captionText = (result as? String) ?? ""
        }
    }

    /// catalogs every labelled page button per site; the allowed ones showing now
    /// become pills, read each tick so a Settings toggle applies live
    private func pollButtons() {
        guard let webView = tab?.webView, let host = siteHost else { return }
        webView.evaluateJavaScript("window.__artemisPip && window.__artemisPip.buttons()") {
            [weak self] result, _ in
            guard let self, let labels = result as? [String] else { return }
            PiPSiteButtons.merge(host: host, labels: labels)
            let allowed = PiPSiteButtons.allowed(host: host)
            let shown = labels.filter { allowed.contains($0) }
            if shown != self.pageButtons { self.pageButtons = shown }
        }
    }

    private func pollState() {
        guard let webView = tab?.webView, let panel else { return }
        pollButtons()
        webView.evaluateJavaScript("window.__artemisPip && window.__artemisPip.state()") {
            [weak self] result, _ in
            guard let self, let d = result as? [String: Any] else { return }
            self.isPlaying = (d["playing"] as? Bool) ?? false
            self.duration = (d["duration"] as? Double) ?? 0
            self.muted = (d["muted"] as? Bool) ?? false
            if !self.isAdjustingVolume { self.volume = (d["volume"] as? Double) ?? self.volume }
            self.activeCaptionID = (d["ccActive"] as? String) ?? ""
            self.adActive = (d["ad"] as? Bool) ?? false
            self.isSkippable = (d["skippable"] as? Bool) ?? false
            if let label = d["skipLabel"] as? String, !label.isEmpty { self.skipLabel = label }
            let current = (d["current"] as? Double) ?? 0
            // a short loops rather than ending: coming round is the cue to move on
            if self.isShortForm, self.autoScroll, !self.switchingShort, self.duration > 1,
                self.lastTime >= self.duration - 0.8, current < 1 {
                self.stepShort(1)
            }
            self.lastTime = current
            if let target = self.seekTarget, abs(current - target.time) > 1.5, Date() < target.until {
                // still the pre-seek position
            } else if !self.isScrubbing {
                self.seekTarget = nil
                self.currentTime = current
            }

            if !self.aspectApplied,
                let w = d["w"] as? Double, let h = d["h"] as? Double, w > 0, h > 0 {
                self.aspectApplied = true
                panel.contentAspectRatio = NSSize(width: w, height: h)
                panel.setFrame(panel.reshaped(panel.frame, aspect: w / h), display: true)
            }
        }
    }
}

private extension String {
    /// minimal escape for embedding in a single-quoted JS string
    var jsEscaped: String {
        replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
    }
}

// MARK: - Chrome overlay

/// the panel's controls over a full-window drag layer; while hidden they stop
/// hit-testing so the whole window drags
private struct MiniPlayerChrome: View {
    @Bindable var player: MiniPlayer
    @AppStorage(MiniPlayer.cornerRadiusKey) private var cornerRadius = MiniPlayer.defaultCornerRadius
    @AppStorage(MiniPlayer.customCaptionsKey) private var customCaptions = true
    @AppStorage(MiniPlayer.skipSecondsKey) private var skipSeconds = MiniPlayer.defaultSkipSeconds
    @AppStorage("pipShowRemaining") private var showRemaining = false
    @State private var showCaptions = false

    private var visible: Bool { player.chromeHovering || showCaptions }

    var body: some View {
        if player.isCall {
            CallControls(player: player)
        } else {
            videoChrome
        }
    }

    private var videoChrome: some View {
        ZStack(alignment: .bottomTrailing) {
            LinearGradient(
                colors: [.black.opacity(0.45), .black.opacity(0.2), .black.opacity(0.5)],
                startPoint: .top, endPoint: .bottom)
                .opacity(visible ? 1 : 0)
                .allowsHitTesting(false)

            if customCaptions, !player.captionText.isEmpty {
                GeometryReader { geo in
                    VStack {
                        Spacer(minLength: 0)
                        captionBubble(maxWidth: geo.size.width * 0.86)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, visible ? 52 : 22)
                }
                .allowsHitTesting(false)
            }

            VStack(spacing: 10) {
                if player.isShortForm {
                    CenterButton(symbol: "chevron.up", label: "Previous video", size: 16) { player.stepShort(-1) }
                }
                HStack(spacing: 34) {
                    // ads block seeking
                    CenterButton(
                        symbol: Self.skipSymbol(forward: false, seconds: skipSeconds),
                        label: "Back \(skipSeconds) seconds", size: 20
                    ) { player.skip(-1) }
                    .opacity(player.adActive ? 0.25 : 1)
                    .disabled(player.adActive)
                    CenterButton(
                        symbol: player.isPlaying ? "pause.fill" : "play.fill",
                        label: player.isPlaying ? "Pause" : "Play", size: 34
                    ) { player.playPause() }
                    CenterButton(
                        symbol: Self.skipSymbol(forward: true, seconds: skipSeconds),
                        label: "Forward \(skipSeconds) seconds", size: 20
                    ) { player.skip(1) }
                    .opacity(player.adActive ? 0.25 : 1)
                    .disabled(player.adActive)
                }
                if player.isShortForm {
                    CenterButton(symbol: "chevron.down", label: "Next video", size: 16) { player.stepShort(1) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .opacity(visible ? 1 : 0)
            .allowsHitTesting(visible)

            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
                bottomBar
            }
            .padding(12)
            .opacity(visible ? 1 : 0)
            .allowsHitTesting(visible)

            if showCaptions {
                captionMenu
                    .padding(.trailing, 16).padding(.bottom, 48)
                    .opacity(visible ? 1 : 0)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: visible)
        .animation(.easeInOut(duration: 0.1), value: player.captionText)
        .animation(.easeInOut(duration: 0.18), value: player.pageButtons)
        .onChange(of: player.chromeHovering) { _, hovering in
            if !hovering { showCaptions = false }
        }
        .onChange(of: cornerRadius) { _, r in player.setCornerRadius(r) }
    }

    private func captionBubble(maxWidth: CGFloat) -> some View {
        Text(Self.clampLines(player.captionText, 2))
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .shadow(color: .black.opacity(0.55), radius: 2, y: 1)
            .frame(maxWidth: max(maxWidth, 80))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .glassEffect(.regular, in: .rect(cornerRadius: 9))
    }

    /// the last `n` lines, since captions read bottom-up
    static func clampLines(_ s: String, _ n: Int) -> String {
        let lines = s.split(whereSeparator: \.isNewline)
        if lines.count <= n { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
        return lines.suffix(n).joined(separator: "\n")
    }

    private var topBar: some View {
        HStack {
            ChromeButton(symbol: "arrow.up.left", label: "Back to the tab", glass: true) {
                player.returnToBrowser()
            }
            Spacer()
            ChromeButton(symbol: "xmark", label: "Close mini player", glass: true) { player.dismiss() }
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                timeLabel(showRemaining
                    ? "-" + Self.clock(max(player.duration - player.currentTime, 0))
                    : Self.clock(player.currentTime), opacity: 0.85)

                TimeSlider(player: player)
                    .opacity(player.adActive ? 0.35 : 1)
                    .disabled(player.adActive)

                timeLabel(Self.clock(player.duration), opacity: 0.6)
            }

            // the site's skip button is pinned under ours, so the click lands on it trusted
            if player.isSkippable {
                OverlayButton(label: player.skipLabel, systemImage: "forward.end.fill") { rect in
                    player.setSkipTarget(rect)
                }
            } else if player.pageButtons.isEmpty {
                VolumeControl(player: player)

                if player.isShortForm {
                    ChromeButton(
                        symbol: player.autoScroll ? "play.square.stack.fill" : "play.square.stack",
                        label: player.autoScroll ? "Stop auto-scroll" : "Auto-scroll"
                    ) { player.autoScroll.toggle() }
                } else {
                    ChromeButton(
                        symbol: player.captionsOn ? "captions.bubble.fill" : "captions.bubble",
                        label: "Captions"
                    ) {
                        player.refreshCaptionTracks()
                        showCaptions.toggle()
                    }
                }
            } else {
                ForEach(player.pageButtons, id: \.self) { label in
                    PageButtonPill(label: label) { player.clickPageButton(label) }
                }
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 4)
        .padding(.vertical, 2)
        .glassEffect(.regular, in: .capsule)
    }

    /// a time readout; tapping either flips the leading one between elapsed
    /// and remaining
    private func timeLabel(_ text: String, opacity: Double) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundStyle(.white.opacity(opacity))
            .shadow(color: .black.opacity(0.5), radius: 1.5, y: 0.5)
            .contentShape(Rectangle())
            .onTapGesture { showRemaining.toggle() }
    }

    /// numbered SF skip symbol when one exists for the interval, plain arrows
    /// otherwise (the interval is user-configurable to anything)
    static func skipSymbol(forward: Bool, seconds: Double) -> String {
        let base = forward ? "goforward" : "gobackward"
        let n = Int(seconds)
        return (Double(n) == seconds && [5, 10, 15, 30, 45, 60, 75, 90].contains(n))
            ? "\(base).\(n)" : base
    }

    /// our own caption picker — a Custom/Website style switch on top, then the
    /// track list. selecting a row drives the site's native track API.
    private var captionMenu: some View {
        VStack(alignment: .leading, spacing: 1) {
            stylePicker
            Divider().overlay(.white.opacity(0.18)).padding(.vertical, 4)
            CaptionRow(label: "Off", active: !player.captionsOn) {
                player.selectCaption("")
                showCaptions = false
            }
            if player.captionTracks.isEmpty {
                Text("No captions detected")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.horizontal, 8)
                    .frame(height: 26, alignment: .leading)
            }
            ForEach(player.captionTracks) { track in
                CaptionRow(label: track.label, active: track.id == player.activeCaptionID) {
                    player.selectCaption(track.id)
                    showCaptions = false
                }
            }
        }
        .padding(6)
        .frame(width: 210, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
    }

    private var stylePicker: some View {
        HStack(spacing: 4) {
            styleChip("Custom", custom: true)
            styleChip("Website", custom: false)
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.white.opacity(0.08)))
        .padding(.horizontal, 2)
        .padding(.top, 2)
    }

    private func styleChip(_ label: String, custom: Bool) -> some View {
        Button {
            customCaptions = custom
            player.applyCaptionRender()
        } label: {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(.white.opacity(customCaptions == custom ? 0.22 : 0)))
                .foregroundStyle(.white.opacity(customCaptions == custom ? 1 : 0.55))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// seconds → m:ss (or h:mm:ss past an hour)
    static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let s = total % 60, m = (total / 60) % 60, h = total / 3600
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}

/// the time scrubber: while held it shows its own value, so polls can't move it
private struct TimeSlider: View {
    @Bindable var player: MiniPlayer
    @State private var scrubTime = 0.0

    var body: some View {
        Slider(
            value: Binding(
                get: { min(max(player.isScrubbing ? scrubTime : player.currentTime, 0), max(player.duration, 1)) },
                set: { scrubTime = $0; player.currentTime = $0 }),
            in: 0...max(player.duration, 1),
            onEditingChanged: { editing in
                if editing {
                    scrubTime = player.currentTime
                    player.isScrubbing = true
                } else {
                    player.seek(to: scrubTime)
                    player.isScrubbing = false
                }
            })
            .controlSize(.mini)
            .tint(.white)
            .frame(minWidth: 80)
            .accessibilityLabel("Playback position")
            .accessibilityValue("\(MiniPlayerChrome.clock(player.currentTime)) of \(MiniPlayerChrome.clock(player.duration))")
    }
}

/// a speaker button that grows a glass capsule with a slider on hover
private struct VolumeControl: View {
    @Bindable var player: MiniPlayer
    @State private var hovering = false
    @State private var hideTask: Task<Void, Never>?

    private var icon: String {
        (player.muted || player.volume <= 0.001) ? "speaker.slash.fill"
            : player.volume < 0.5 ? "speaker.wave.1.fill" : "speaker.wave.2.fill"
    }

    private var level: Binding<Double> {
        Binding(
            get: { player.muted ? 0 : player.volume },
            set: { player.setVolume($0) })
    }

    var body: some View {
        // the slider only appears on hover, so the button adjusts the level too
        ChromeButton(symbol: icon, label: player.muted ? "Unmute" : "Mute") { player.toggleMute() }
            .accessibilityValue("Volume \(Int((level.wrappedValue * 100).rounded())) percent")
            .accessibilityAdjustableAction { direction in
                let step = direction == .increment ? 0.1 : -0.1
                player.setVolume(min(max(level.wrappedValue + step, 0), 1))
            }
            .onHover { setHover($0) }
            .overlay(alignment: .trailing) {
                if hovering {
                    HStack(spacing: 10) {
                        Slider(value: level, in: 0...1, onEditingChanged: { editing in
                            player.isAdjustingVolume = editing
                        })
                        .frame(width: 84)
                        .controlSize(.mini)
                        .tint(.white)
                        .accessibilityLabel("Volume")
                        ChromeButton(symbol: icon, label: player.muted ? "Unmute" : "Mute") { player.toggleMute() }
                    }
                    // no trailing padding, so the capsule's speaker sits exactly over the base one
                    .padding(.leading, 14)
                    .padding(.vertical, 4)
                    .glassEffect(.regular, in: .capsule)
                    .fixedSize()
                    .onHover { setHover($0) }
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.16), value: hovering)
    }

    /// hides a beat after exit, so the capsule survives the button→slider gap
    private func setHover(_ inside: Bool) {
        hideTask?.cancel()
        if inside {
            hovering = true
        } else {
            hideTask = Task {
                try? await Task.sleep(for: .milliseconds(140))
                if !Task.isCancelled { hovering = false }
            }
        }
    }
}

/// call mode's bottom row: back to the tab, the call's own mic / camera /
/// leave as glass, and ✕ (which leaves the call running)
private struct CallControls: View {
    @Bindable var player: MiniPlayer

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                CallButton(symbol: "arrow.up.left", label: "Back to the tab") { player.returnToBrowser() }
                Spacer(minLength: 0)
                if let mic = player.micOn {
                    CallButton(symbol: mic ? "mic.fill" : "mic.slash.fill",
                               label: mic ? "Mute" : "Unmute", lit: !mic) { player.toggleCall("mic") }
                }
                if let camera = player.cameraOn {
                    CallButton(symbol: camera ? "video.fill" : "video.slash.fill",
                               label: camera ? "Turn camera off" : "Turn camera on",
                               lit: !camera) { player.toggleCall("cam") }
                }
                if player.canLeave {
                    CallButton(symbol: "phone.down.fill", label: "Leave call", tint: .red) { player.leaveCall() }
                }
                Spacer(minLength: 0)
                CallButton(symbol: "xmark", label: "Close mini player") { player.dismiss() }
            }
            .padding(.horizontal, MiniPlayer.callInset)
            .frame(height: MiniPlayer.callControlsHeight)
        }
        .animation(.easeInOut(duration: 0.18), value: player.micOn)
        .animation(.easeInOut(duration: 0.18), value: player.cameraOn)
    }
}

/// one glass call control. `lit` marks a muted mic / camera (a light pane, the
/// way Meet shows it); `tint` colours the glass (leave is red)
private struct CallButton: View {
    let symbol: String
    let label: String
    var lit = false
    var tint: Color?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(lit ? Color.black.opacity(0.85) : .white.opacity(hovering ? 1 : 0.9))
                .frame(width: 36, height: 36)
                .glassEffect(
                    .regular.tint(tint ?? (lit ? .white.opacity(0.85) : nil)).interactive(),
                    in: .circle)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .tooltip(label)
        .onHover { hovering = $0 }
    }
}

/// a transport glyph for the centre cluster, on a glass circle
private struct CenterButton: View {
    let symbol: String
    /// the spoken name: the panel has no tooltip layer to supply one
    var label: String
    var size: CGFloat
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white.opacity(hovering ? 1 : 0.92))
                .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
                .frame(width: size + 22, height: size + 22)
                .glassEffect(.regular, in: .circle)
                .frame(width: size + 30, height: size + 30)
                .contentShape(Circle())
                .accessibilityLabel(label)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// a labelled glass capsule for an allowed site button ("Skip Recap" etc.) —
/// clicking it proxies a real click to the page element via `clickAllowed`
private struct PageButtonPill: View {
    let label: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(hovering ? 1 : 0.85))
                .lineLimit(1)
                .frame(maxWidth: 140)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .glassEffect(.regular, in: .capsule)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// visuals only: a click passes through to the site's invisible button pinned under
/// it, since sites ignore an untrusted `.click()`. reports its rect to keep that aligned
private struct OverlayButton: View {
    let label: String
    let systemImage: String
    let onFrame: (CGRect) -> Void

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage).font(.system(size: 10, weight: .bold))
            Text(label).font(.system(size: 12, weight: .semibold)).lineLimit(1)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: .capsule)
        .allowsHitTesting(false)
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { onFrame($0) }
    }
}

private struct CaptionRow: View {
    let label: String
    let active: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .opacity(active ? 1 : 0)
                    .frame(width: 12)
                Text(label)
                    .font(.system(size: 12))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.white.opacity(hovering ? 1 : 0.85))
            .padding(.horizontal, 8)
            .frame(height: 28)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(.white.opacity(hovering ? 0.16 : 0)))
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// a glyph control for the mini-player chrome; `glass` gives it its own glass circle
private struct ChromeButton: View {
    let symbol: String
    /// the spoken name: the panel has no tooltip layer to supply one
    var label: String
    var size: CGFloat = 13
    var glass: Bool = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .bold))
                .foregroundStyle(.white.opacity(hovering ? 1 : 0.85))
                .frame(width: 28, height: 28)
                .modifier(GlassCircle(enabled: glass))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .tooltip(label)
        .onHover { hovering = $0 }
    }
}

private struct GlassCircle: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled { content.glassEffect(.regular, in: .circle) } else { content }
    }
}

/// the mini-player's panel. drag and resize are resolved by geometry in `sendEvent`,
/// so clicks still reach the web view as trusted events; it must be able to become
/// key, or web-content clicks are silently dropped
final class PiPPanel: NSPanel {
    /// where a click-drag moves the panel (window coords); clicks there still
    /// reach the controls on release. default: the top band
    var isDragHandle: ((NSPoint) -> Bool)?
    /// a drag, swipe or pinch started: stop any spring in flight
    var onGestureBegan: (() -> Void)?
    private var swipeTravel = NSPoint.zero
    private var swipeCursorStart = NSPoint.zero
    private var swipeRecent: [(point: NSPoint, time: TimeInterval)] = []
    /// false in call mode, where the page reflows to any shape
    var locksAspect = true
    /// a flicked release: where to settle (a screen corner) and the release
    /// speed as a fraction of that distance per second
    var onFling: ((NSRect, Double) -> Void)?
    /// how far from an edge still grabs the resize
    private let resizeMargin: CGFloat = 14

    private var pendingDown: NSEvent?
    private var dragStart: NSPoint?
    private var dragging = false

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            let p = event.locationInWindow
            if event.modifierFlags.contains(.command) { drag(); return }
            if let edge = resizeEdge(at: p) { startResize(edge, from: event); return }
            // withheld, and forwarded on release, so a button on the handle still clicks
            if isDragHandle?(p) ?? (p.y > (contentView?.bounds.height ?? 0) - 46) {
                pendingDown = event; dragStart = p; dragging = false
                return
            }
            super.sendEvent(event)
        case .leftMouseDragged:
            if let start = dragStart, pendingDown != nil, !dragging {
                let p = event.locationInWindow
                if hypot(p.x - start.x, p.y - start.y) > 4 {
                    dragging = true; pendingDown = nil; dragStart = nil
                    drag()
                }
                return
            }
            super.sendEvent(event)
        case .leftMouseUp:
            if let down = pendingDown {  // top-strip click, no drag → forward it
                pendingDown = nil; dragStart = nil
                super.sendEvent(down); super.sendEvent(event)
                return
            }
            super.sendEvent(event)
        case .scrollWheel where event.hasPreciseScrollingDeltas:
            swipe(event)
        case .magnify:
            pinch(event)
        default:
            super.sendEvent(event)
        }
    }

    /// two fingers move the panel with the cursor riding along; a flick settles it
    /// in a corner instead of the system's momentum
    private func swipe(_ e: NSEvent) {
        guard e.momentumPhase.isEmpty else { return }
        if e.phase.contains(.began) {
            onGestureBegan?()
            swipeTravel = .zero
            swipeRecent = []
            swipeCursorStart = NSEvent.mouseLocation
        }
        // fingers' direction, whatever the scroll-direction setting
        let flip: CGFloat = e.isDirectionInvertedFromDevice ? 1 : -1
        let dx = e.scrollingDeltaX * flip, dy = -e.scrollingDeltaY * flip
        setFrameOrigin(NSPoint(x: frame.minX + dx, y: frame.minY + dy))
        swipeTravel = NSPoint(x: swipeTravel.x + dx, y: swipeTravel.y + dy)
        // Quartz's global space is top-left origin, measured off the primary display
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        CGWarpMouseCursorPosition(CGPoint(
            x: swipeCursorStart.x + swipeTravel.x, y: top - (swipeCursorStart.y + swipeTravel.y)))
        CGAssociateMouseAndMouseCursorPosition(1)
        swipeRecent.append((swipeTravel, e.timestamp))
        swipeRecent.removeAll { e.timestamp - $0.time > 0.08 }
        if e.phase.contains(.ended) { fling(swipeRecent) }
    }

    /// pinch grows or shrinks the panel about its centre, keeping its shape
    private func pinch(_ e: NSEvent) {
        if e.phase.contains(.began) { onGestureBegan?() }
        defer { if e.phase.contains(.ended) { keepOnScreen() } }
        let aspect = frame.width / max(frame.height, 1)
        let minW = max(contentMinSize.width, contentMinSize.height * aspect, 200)
        let w = min(max(frame.width * (1 + e.magnification), minW), screen?.visibleFrame.width ?? 2000)
        let h = w / aspect
        setFrame(NSRect(x: frame.midX - w / 2, y: frame.midY - h / 2, width: w, height: h), display: true)
    }

    private func drag() {
        onGestureBegan?()
        let startFrame = frame
        let startMouse = NSEvent.mouseLocation
        var recent: [(point: NSPoint, time: TimeInterval)] = []
        while let e = NSApp.nextEvent(
            matching: [.leftMouseDragged, .leftMouseUp],
            until: .distantFuture, inMode: .eventTracking, dequeue: true) {
            let m = NSEvent.mouseLocation
            recent.append((m, e.timestamp))
            recent.removeAll { e.timestamp - $0.time > 0.08 }
            if e.type == .leftMouseUp { break }
            setFrameOrigin(NSPoint(
                x: startFrame.minX + m.x - startMouse.x, y: startFrame.minY + m.y - startMouse.y))
        }
        fling(recent)
    }

    /// a fast release glides on into the screen corner nearest where momentum
    /// would carry it; a slow one stays put
    private func fling(_ recent: [(point: NSPoint, time: TimeInterval)]) {
        guard let first = recent.first, let last = recent.last, last.time > first.time,
            let area = screen?.visibleFrame.insetBy(dx: 16, dy: 16)
        else { return }
        let dt = last.time - first.time
        let v = CGVector(dx: (last.point.x - first.point.x) / dt, dy: (last.point.y - first.point.y) / dt)
        let speed = hypot(v.dx, v.dy)
        guard speed > 700 else { return keepOnScreen() }
        // where momentum would carry it, then the corner nearest that
        let flung = NSPoint(x: frame.midX + v.dx * 0.25, y: frame.midY + v.dy * 0.25)
        let x = flung.x < area.midX ? area.minX : area.maxX - frame.width
        let y = flung.y < area.midY ? area.minY : area.maxY - frame.height
        let target = NSRect(origin: NSPoint(x: x, y: y), size: frame.size)
        let distance = hypot(target.minX - frame.minX, target.minY - frame.minY)
        onFling?(target, distance > 1 ? speed / distance : 0)
    }

    /// dragged, swiped or pinched partly off screen: spring back fully onto it
    private func keepOnScreen() {
        let r = onScreen(frame)
        if r != frame { onFling?(r, 0) }
    }

    private func onScreen(_ r: NSRect) -> NSRect {
        guard let area = (screen ?? NSScreen.main)?.visibleFrame.insetBy(dx: 16, dy: 16) else { return r }
        var o = r.origin
        o.x = min(max(o.x, area.minX), area.maxX - r.width)
        o.y = min(max(o.y, area.minY), area.maxY - r.height)
        return NSRect(origin: o, size: r.size)
    }

    /// `r` at the video's `aspect`, keeping its area and the corner nearest the
    /// screen's, then kept on screen
    func reshaped(_ r: NSRect, aspect: CGFloat) -> NSRect {
        let w = (r.width * r.height * aspect).squareRoot().rounded()
        let h = (w / aspect).rounded()
        let area = (screen ?? NSScreen.main)?.visibleFrame ?? r
        let x = r.midX > area.midX ? r.maxX - w : r.minX
        let y = r.midY > area.midY ? r.maxY - h : r.minY
        return onScreen(NSRect(x: x, y: y, width: w, height: h))
    }

    private struct Edge: OptionSet { let rawValue: Int
        static let left = Edge(rawValue: 1), right = Edge(rawValue: 2)
        static let bottom = Edge(rawValue: 4), top = Edge(rawValue: 8)
    }

    /// which edges the point (window coords, bottom-left) is within grabbing
    /// distance of — nil if it's in the interior
    private func resizeEdge(at p: NSPoint) -> Edge? {
        guard let b = contentView?.bounds else { return nil }
        var e: Edge = []
        if p.x <= resizeMargin { e.insert(.left) }
        if p.x >= b.width - resizeMargin { e.insert(.right) }
        if p.y <= resizeMargin { e.insert(.bottom) }
        if p.y >= b.height - resizeMargin { e.insert(.top) }
        return e.isEmpty ? nil : e
    }

    /// the grabbed corner moves; the opposite one stays put
    private func startResize(_ edge: Edge, from down: NSEvent) {
        let start = frame
        let startMouse = NSEvent.mouseLocation
        let ar = contentAspectRatio
        let aspect = ar.height > 0 ? ar.width / ar.height : start.width / max(start.height, 1)
        let minW = max(contentMinSize.width, 200)
        let maxW = (screen?.visibleFrame.width ?? 2000)
        while let e = NSApp.nextEvent(
            matching: [.leftMouseDragged, .leftMouseUp],
            until: .distantFuture, inMode: .eventTracking, dequeue: true) {
            if e.type == .leftMouseUp { break }
            let m = NSEvent.mouseLocation
            let dx = m.x - startMouse.x, dy = m.y - startMouse.y
            var w = start.width
            if edge.contains(.right) { w = start.width + dx }
            else if edge.contains(.left) { w = start.width - dx }
            else if edge.contains(.top) { w = (start.height + dy) * aspect }
            else if edge.contains(.bottom) { w = (start.height - dy) * aspect }
            w = min(max(w, minW), maxW)
            var h = w / aspect
            if !locksAspect {
                h = start.height
                if edge.contains(.top) { h = start.height + dy } else if edge.contains(.bottom) { h = start.height - dy }
                h = max(h, contentMinSize.height)
                if !edge.contains(.left), !edge.contains(.right) { w = start.width }
            }
            var origin = start.origin
            origin.x = edge.contains(.left) ? start.maxX - w : start.origin.x
            origin.y = edge.contains(.top) ? start.origin.y : start.maxY - h
            setFrame(NSRect(origin: origin, size: NSSize(width: w, height: h)), display: true)
        }
        keepOnScreen()
    }
}

/// springs a panel's position on the display clock, since AppKit can only ease
/// a window frame; retargeting mid-flight starts from where it is. size never
/// animates here: every size change makes the borrowed page re-lay itself out
final class PanelMotion: NSObject {
    private weak var panel: NSWindow?
    private var from = NSPoint.zero
    private var to = NSPoint.zero
    private var velocity = 0.0
    private var start: CFTimeInterval = 0
    private var link: CADisplayLink?
    var isRunning: Bool { link != nil }

    func animate(_ panel: NSWindow, to frame: NSRect, velocity: Double = 0) {
        stop()
        self.panel = panel
        from = panel.frame.origin
        to = frame.origin
        self.velocity = velocity
        start = CACurrentMediaTime()
        let link = panel.contentView?.displayLink(target: self, selector: #selector(step))
        link?.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func step() {
        guard let panel else { return stop() }
        let spring = Motion.pipSpring
        let t = CACurrentMediaTime() - start
        guard t < spring.settlingDuration else {
            panel.setFrameOrigin(to)
            return stop()
        }
        let p = CGFloat(spring.value(fromValue: 0.0, toValue: 1.0, initialVelocity: velocity, time: t))
        panel.setFrameOrigin(NSPoint(x: from.x + (to.x - from.x) * p, y: from.y + (to.y - from.y) * p))
    }

    /// the panel's entrance: fades up while its content springs from 94% scale,
    /// on the render server, at its final size
    static func appear(_ panel: NSWindow) {
        guard let layer = panel.contentView?.layer else { panel.alphaValue = 1; return }
        let b = layer.bounds
        var from = CATransform3DMakeTranslation(b.midX, b.midY, 0)
        from = CATransform3DScale(from, 0.94, 0.94, 1)
        from = CATransform3DTranslate(from, -b.midX, -b.midY, 0)
        let spring = Motion.pipSpring
        let grow = CASpringAnimation(keyPath: "transform")
        grow.fromValue = NSValue(caTransform3D: from)
        grow.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        grow.mass = spring.mass
        grow.stiffness = spring.stiffness
        grow.damping = spring.damping
        grow.duration = grow.settlingDuration
        layer.add(grow, forKey: "appear")
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            panel.animator().alphaValue = 1
        }
    }
}

/// reports hover from a tracking area, which never takes a click from the web view
final class PiPContentView: NSView {
    var onHover: ((Bool) -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
            owner: self))
    }
    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}

// MARK: - Per-site button allowlist store

/// page buttons seen per site in the mini-player, each with an allowed flag:
/// [host: [label: allowed]] in UserDefaults
enum PiPSiteButtons {
    static let key = "pipSiteButtons"

    static func all() -> [String: [String: Bool]] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: [String: Bool]] ?? [:]
    }

    /// new labels arrive unallowed
    static func merge(host: String, labels: [String]) {
        guard !labels.isEmpty else { return }
        var catalog = all()
        var site = catalog[host] ?? [:]
        var changed = false
        for label in labels where site[label] == nil {
            site[label] = false
            changed = true
        }
        if changed {
            catalog[host] = site
            UserDefaults.standard.set(catalog, forKey: key)
        }
    }

    static func allowed(host: String) -> Set<String> {
        Set((all()[host] ?? [:]).filter(\.value).keys)
    }

    static func setAllowed(_ allow: Bool, host: String, label: String) {
        var catalog = all()
        var site = catalog[host] ?? [:]
        site[label] = allow
        catalog[host] = site
        UserDefaults.standard.set(catalog, forKey: key)
    }

    static func forget(host: String) {
        var catalog = all()
        catalog.removeValue(forKey: host)
        UserDefaults.standard.set(catalog, forKey: key)
    }
}

// MARK: - Injected JavaScript engine

extension MiniPlayer {
    /// installs `window.__artemisPip` once and runs `apply()`. the literal isn't raw:
    /// a backslash in the script must be escaped
    fileprivate static let applyJS = """
    (function () {
      if (window.__artemisPip) return window.__artemisPip.apply();

      var H = location.hostname;
      function q(s) { try { return document.querySelector(s); } catch (e) { return null; } }
      function qa(s) { try { return Array.prototype.slice.call(document.querySelectorAll(s)); } catch (e) { return []; } }
      function has(s) { return H.indexOf(s) !== -1; }

      \(PlayerSites.script)

      var YT = {
        video: 'video.html5-main-video, #movie_player video, video',
        root: ['#movie_player', '.html5-video-player'],
        cap: ['.ytp-caption-window-container', '.caption-window'],
        // the player's only children left showing
        keep: ['.html5-video-container', '.ytp-caption-window-container', '.video-ads', '.ytp-ad-module'],
        // never swept: a display:none'd button can't take the real click a skip needs
        alive: ['.ytp-skip-ad', '.ytp-skip-ad-button', '.ytp-ad-skip-button', '.ytp-ad-skip-button-modern'],
        // role=button content, not controls: kept out of the button catalog
        noScan: ['.ytp-chapter-title', '.ytp-chapters-container', '.ytp-progress-bar-container',
                 '.ytp-progress-bar', '[class*="chapter" i]', '.ytp-time-display'],
        hide: ['.ytp-chrome-bottom', '.ytp-chrome-top', '.ytp-gradient-bottom', '.ytp-gradient-top',
               '.ytp-ce-element', '.ytp-ce-covering-overlay', '.ytp-pause-overlay', '.ytp-pause-overlay-container',
               '.ytp-cued-thumbnail-overlay', '.ytp-tooltip', '.ytp-chrome-controls',
               '.ytp-large-play-button', '.ytp-large-play-button-bg', '.ytp-bezel', '.ytp-bezel-text-wrapper',
               '.ytp-spinner', '.ytp-watermark', '.ytp-title-channel', '.ytp-title-channel-logo',
               '.iv-branding', '.annotation', '.ytp-videowall-still', '.ytp-endscreen-content',
               '.html5-endscreen', '.ytp-suggested-action', '.ytp-ce-video', '.ytp-ce-channel',
               '#masthead-container', 'ytd-masthead', '#guide', 'tp-yt-app-drawer', 'ytd-mini-guide-renderer'],
        cc: youTubeCaptions
      };

      var NF = {
        video: '.watch-video video, video',
        root: ['.watch-video', '.watch-video--player-view'],
        cap: ['.player-timedtext'],
        hide: ['.watch-video--bottom-controls-container', '.PlayerControlsNeo__bottom-controls',
               '.PlayerControlsNeo__all-controls', '.PlayerControlsNeo__layout', '[data-uia="timeline-bar"]',
               '.watch-video--back-container', '.watch-video--flag-container', '.advisory-background',
               '[data-uia="player-skip-intro"]', '[data-uia^="next-episode-seamless"]'],
        cc: netflixCaptions
      };

      var PV = {
        video: '.atvwebplayersdk-root video, .dv-player-fullscreen video, video',
        root: ['.atvwebplayersdk-player-container', '.atvwebplayersdk-root', '.dv-player-fullscreen'],
        cap: ['.atvwebplayersdk-captions-overlay', '.atvwebplayersdk-captions-text'],
        hide: ['.atvwebplayersdk-bottompanel-container', '.atvwebplayersdk-hideabletopbuttons-container',
               '.atvwebplayersdk-infobar-container', '.atvwebplayersdk-nextupcard-wrapper',
               '.atvwebplayersdk-nextupcard-button', '.atvwebplayersdk-timeindicator-text',
               '.atvwebplayersdk-subtitle-text', '.atvwebplayersdk-title-text',
               '.atvwebplayersdk-skipelement-button',
               // every overlay child but the captions: its hashed classes evade the list above
               '.atvwebplayersdk-overlays-container > *:not([class*="captions" i]):not([class*="subtitle" i])'],
        // X-Ray's role=button rows are content, not controls
        noScan: ['[class*="xray" i]', '[id*="xray" i]', '.atvwebplayersdk-infobar-container'],
        cc: null
      };

      var DP = {
        video: '.btm-media-client-element video, video',
        root: ['.btm-media-player', '.btm-media-overlays-container'],
        cap: ['.dss-hls-subtitle-overlay', '.dss-subtitle-renderer-wrapper'],
        hide: ['.overlay__controls', '.controls__header', '.controls__footer', '.overlay__ratings',
               'div[class*="bottom-gradient"]'],
        cc: null
      };

      var HU = {
        video: '#web-player-app video, video',
        root: ['#web-player-app'],
        cap: ['[class*="caption" i]', '[class*="Subtitle" i]'],
        hide: ['[class*="ControlsContainer"]'],
        cc: null
      };

      // null: isolate the bare video, losing any captions drawn outside it
      function profile() {
        if (has('youtube.com') || has('youtu.be')) return YT;
        if (has('netflix.com')) return NF;
        if (has('primevideo.com') || has('amazon.')) return PV;
        if (has('disneyplus.com')) return DP;
        if (has('hulu.com')) return HU;
        return null;
      }

      var FILL = 'position:fixed !important;inset:0 !important;width:100vw !important;'
        + 'height:100vh !important;max-width:none !important;max-height:none !important;'
        + 'margin:0 !important;z-index:2147483647 !important;background:#000 !important;';

      var st = { video: null, root: null, saved: [], prevV: '', prevR: '', mode: '', prof: null, ttModes: null, capCustom: true, btnCache: null, btnAt: 0, swept: [], lifted: []  };

      function findVideo(p) {
        var vids = qa(p ? p.video : 'video');
        if (!vids.length) vids = qa('video');
        var playing = vids.filter(function (v) { return !v.paused && v.readyState > 1; });
        var pool = playing.length ? playing : vids;
        pool.sort(function (a, b) { return (b.clientWidth * b.clientHeight) - (a.clientWidth * a.clientHeight); });
        return pool[0] || null;
      }

      function neutralize(el) {
        var saved = [], node = el.parentElement;
        while (node && node !== document.documentElement) {
          saved.push({ el: node, style: node.getAttribute('style') || '' });
          var s = node.style;
          s.transform = 'none'; s.filter = 'none'; s.perspective = 'none'; s.willChange = 'auto';
          s.contain = 'none'; s.opacity = '1'; s.zIndex = 'auto'; s.mixBlendMode = 'normal';
          s.isolation = 'auto'; s.clipPath = 'none'; s.webkitClipPath = 'none';
          s.mask = 'none'; s.webkitMaskImage = 'none'; s.overflow = 'visible';
          node = node.parentElement;
        }
        return saved;
      }

      function styleEl(id) {
        var s = document.getElementById(id);
        if (!s) { s = document.createElement('style'); s.id = id; document.head.appendChild(s); }
        return s;
      }

      function backdrop() {
        var bg = document.getElementById('__artemis_pip_bg');
        if (!bg) { bg = document.createElement('div'); bg.id = '__artemis_pip_bg'; document.documentElement.appendChild(bg); }
        bg.style.cssText = 'position:fixed;inset:0;background:#000;z-index:2147483645;pointer-events:none;';
      }

      function apply() {
        var p = profile(); st.prof = p;
        var v = findVideo(p); if (!v) return false;
        st.video = v; v.controls = false;
        backdrop();

        // stash native text-track modes; `setCaptionRender` decides whether to
        // draw them (website style) or hide+scrape them (our custom style)
        st.ttModes = [];
        if (v.textTracks) for (var ti = 0; ti < v.textTracks.length; ti++) st.ttModes.push(v.textTracks[ti].mode);

        var rootEl = null;
        // the player that holds this video (a Shorts page carries several)
        if (p && p.root) for (var i = 0; i < p.root.length; i++) { var r = v.closest(p.root[i]); if (r) { rootEl = r; break; } }

        if (rootEl) {
          st.mode = 'root'; st.root = rootEl;
          st.saved = neutralize(rootEl);
          st.prevR = rootEl.getAttribute('style') || '';
          rootEl.style.cssText = st.prevR + ';' + FILL;
          st.prevV = v.getAttribute('style') || '';
          v.style.cssText = st.prevV + ';width:100% !important;height:100% !important;'
            + 'left:0 !important;top:0 !important;object-fit:contain !important;'
            + 'max-width:none !important;max-height:none !important;object-fit:contain !important;';
          var css = '';
          if (p.hide) css += p.hide.join(',') + '{display:none !important;}';
          // anything else the player draws over the video
          if (p.keep) css += p.root.map(function (r) {
            return r + ' > :not(' + p.keep.join('):not(') + ')';
          }).join(',') + '{opacity:0 !important;pointer-events:none !important;}';
          // `alive` elements stay clickable under our pills: opacity, never display:none
          if (p.alive && p.alive.length) css += p.alive.join(',') + '{opacity:0 !important;pointer-events:auto !important;}';
          styleEl('__artemis_pip_hide').textContent = css;
        } else {
          st.mode = 'bare';
          st.saved = neutralize(v);
          st.prevV = v.getAttribute('style') || '';
          v.style.cssText = st.prevV + ';' + FILL + 'object-fit:contain !important;';
        }

        document.documentElement.style.overflow = 'hidden';
        styleEl('__artemis_pip_native').textContent = 'video::-webkit-media-controls{display:none !important;}';
        setCaptionRender(true);
        try { sweep(); } catch (e) {}
        return true;
      }

      // custom: the site's captions keep flowing, invisible, for us to redraw
      function setCaptionRender(custom) {
        st.capCustom = !!custom;
        var v = st.video;
        if (v && v.textTracks) for (var i = 0; i < v.textTracks.length; i++) {
          var m = v.textTracks[i].mode;
          if (custom) { if (m === 'showing') v.textTracks[i].mode = 'hidden'; }
          else { if (m === 'hidden') v.textTracks[i].mode = 'showing'; }
        }
        var sels = (st.prof && st.prof.cap) || [];
        // class-level, so it covers nodes created later
        styleEl('__artemis_pip_cap').textContent =
          (custom && sels.length) ? (sels.join(',') + '{opacity:0 !important;}') : '';
        // drop the inline hide capText forces on live caption nodes
        if (!custom) for (var k = 0; k < sels.length; k++) {
          var els = qa(sels[k]); for (var j = 0; j < els.length; j++) els[j].style.removeProperty('opacity');
        }
      }

      function remove() {
        // un-hide everything the sweep touched
        for (var sw = 0; sw < st.swept.length; sw++) {
          var w = st.swept[sw];
          try {
            w.el.removeAttribute('data-artemis-swept');
            if (w.prev) w.el.style.setProperty('display', w.prev, w.prio || '');
            else w.el.style.removeProperty('display');
          } catch (e) {}
        }
        if (st.lifted) for (var lf = 0; lf < st.lifted.length; lf++) {
          try {
            st.lifted[lf].setAttribute('style', st.lifted[lf].__artemisLift || '');
            st.lifted[lf].__artemisLift = null;
          } catch (e) {}
        }
        if (st.video && st.video.textTracks && st.ttModes)
          for (var ti = 0; ti < st.ttModes.length; ti++)
            if (st.video.textTracks[ti]) st.video.textTracks[ti].mode = st.ttModes[ti];
        if (st.mode === 'root' && st.root) { st.root.setAttribute('style', st.prevR); if (st.video) st.video.setAttribute('style', st.prevV); }
        else if (st.video) st.video.setAttribute('style', st.prevV);
        for (var i = 0; i < st.saved.length; i++) st.saved[i].el.setAttribute('style', st.saved[i].style);
        ['__artemis_pip_bg', '__artemis_pip_hide', '__artemis_pip_native', '__artemis_pip_cap'].forEach(function (id) {
          var e = document.getElementById(id); if (e) e.remove();
        });
        document.documentElement.style.overflow = '';
        st = { video: null, root: null, saved: [], prevV: '', prevR: '', mode: '', prof: null, ttModes: null, capCustom: true, btnCache: null, btnAt: 0, swept: [], lifted: [] };
        return true;
      }

      function stripTags(s) { return (s || '').replace(/<[^>]+>/g, '').trim(); }

      // the caption text to draw now. in custom style both of the site's layers,
      // native cues and its DOM overlay, are suppressed every tick before reading
      function capText() {
        var v = st.video;
        var sels = (st.prof && st.prof.cap) || [];

        if (st.capCustom) {
          if (v && v.textTracks) for (var n = 0; n < v.textTracks.length; n++)
            if (v.textTracks[n].mode === 'showing') v.textTracks[n].mode = 'hidden';
          for (var h = 0; h < sels.length; h++) {
            var els = qa(sels[h]);
            for (var e = 0; e < els.length; e++) els[e].style.setProperty('opacity', '0', 'important');
          }
        }

        // the site's rendered overlay first, then native cues
        for (var k = 0; k < sels.length; k++) {
          var el = q(sels[k]);
          if (el) {
            var t = (el.innerText || el.textContent || '').replace(/\\s*\\n\\s*/g, '\\n').replace(/[ \\t]+/g, ' ').trim();
            if (t) return t;
          }
        }
        if (v && v.textTracks) for (var i = 0; i < v.textTracks.length; i++) {
          var tt = v.textTracks[i];
          if ((tt.mode === 'showing' || tt.mode === 'hidden') && tt.activeCues && tt.activeCues.length) {
            var s = '';
            for (var j = 0; j < tt.activeCues.length; j++) s += (s ? '\\n' : '') + (tt.activeCues[j].text || '');
            s = stripTags(s); if (s) return s;
          }
        }
        return '';
      }

      function ccImpl() {
        if (st.prof && st.prof.cc) return st.prof.cc;
        return nativeCC(function () { return st.video; });
      }

      // ---- overlay sweep: in root mode, hides every player-root child off the
      // video's ancestor chain that holds no captions or `alive` element. re-run
      // each buttons() tick for late mounts; remove() restores everything
      function capLike(el) {
        var c = String((el.getAttribute && el.getAttribute('class')) || '').toLowerCase();
        if (c.indexOf('caption') !== -1 || c.indexOf('subtitle') !== -1 || c.indexOf('timedtext') !== -1) return true;
        var sels = (st.prof && st.prof.cap) || [];
        for (var i = 0; i < sels.length; i++) { try { if (el.matches && el.matches(sels[i])) return true; } catch (e) {} }
        return false;
      }
      function hasCapInside(el) {
        if (!el.querySelector) return false;
        try { if (el.querySelector('[class*="caption" i], [class*="subtitle" i], [class*="timedtext" i]')) return true; } catch (e) {}
        var sels = (st.prof && st.prof.cap) || [];
        for (var i = 0; i < sels.length; i++) { try { if (el.querySelector(sels[i])) return true; } catch (e) {} }
        return false;
      }
      // profile `alive`: elements the sweep must never hide
      function aliveLike(el) {
        var sels = (st.prof && st.prof.alive) || [];
        for (var i = 0; i < sels.length; i++) { try { if (el.matches && el.matches(sels[i])) return true; } catch (e) {} }
        return false;
      }
      function hasAliveInside(el) {
        if (!el.querySelector) return false;
        var sels = (st.prof && st.prof.alive) || [];
        for (var i = 0; i < sels.length; i++) { try { if (el.querySelector(sels[i])) return true; } catch (e) {} }
        return false;
      }
      function sweep() {
        if (st.mode !== 'root' || !st.root || !st.video) return;
        var chain = [], n = st.video.parentElement;
        while (n && n !== st.root) { chain.push(n); n = n.parentElement; }
        if (n !== st.root) return;
        // un-hide swept containers that have since gained an `alive` element
        for (var s = st.swept.length - 1; s >= 0; s--) {
          var w = st.swept[s];
          if (!aliveLike(w.el) && !hasAliveInside(w.el)) continue;
          if (w.prev) w.el.style.setProperty('display', w.prev, w.prio || '');
          else w.el.style.removeProperty('display');
          w.el.removeAttribute('data-artemis-swept');
          st.swept.splice(s, 1);
        }
        function walk(parent) {
          var kids = parent.children;
          for (var i = 0; i < kids.length; i++) {
            var k = kids[i];
            if (k === st.video || k.tagName === 'STYLE' || k.tagName === 'SCRIPT' || k.tagName === 'LINK') continue;
            if (chain.indexOf(k) !== -1) { walk(k); continue; }
            if (capLike(k)) continue;
            if (aliveLike(k)) continue;
            if (hasCapInside(k) || hasAliveInside(k)) { walk(k); continue; }
            if (k.getAttribute('data-artemis-swept')) continue;
            k.setAttribute('data-artemis-swept', '1');
            st.swept.push({ el: k, prev: k.style.getPropertyValue('display'), prio: k.style.getPropertyPriority('display') });
            k.style.setProperty('display', 'none', 'important');
          }
        }
        walk(st.root);
      }

      // ---- site-button allowlist, matched by label since some sites randomise
      // class names. display:none'd buttons are still found, with innerText
      // falling back to textContent
      function btnLabel(el) {
        var s = el.getAttribute('aria-label') || el.innerText || el.textContent || '';
        return s.replace(/\\s+/g, ' ').trim();
      }
      function btnCandidates() {
        var scope = st.root || document;
        var els; try { els = Array.prototype.slice.call(scope.querySelectorAll('button, [role="button"], input[type="button"], input[type="submit"]')); } catch (e) { els = []; }
        var ex = (st.prof && st.prof.noScan) ? st.prof.noScan.join(',') : '';
        if (ex) els = els.filter(function (el) {
          try { return !el.closest(ex); } catch (e) { return true; }
        });
        return els;
      }
      function stash(el) {
        if (el.__artemisLift == null) { el.__artemisLift = el.getAttribute('style') || ''; st.lifted.push(el); }
      }
      // pins the site button fixed at our pill's rect. its ancestors drop transforms,
      // so `fixed` is viewport-relative, and rise above the video; remove() restores them
      function pinUnder(el, t) {
        st.lifted = st.lifted || [];
        if (!el || !t) return;
        var n = el.parentElement;
        while (n && n !== st.root && n !== document.documentElement) {
          stash(n);
          n.style.setProperty('pointer-events', 'auto', 'important');
          n.style.setProperty('z-index', '2147483646', 'important');
          n.style.setProperty('transform', 'none', 'important');
          n.style.setProperty('filter', 'none', 'important');
          n.style.setProperty('perspective', 'none', 'important');
          n.style.setProperty('will-change', 'auto', 'important');
          n.style.setProperty('contain', 'none', 'important');
          n = n.parentElement;
        }
        stash(el);
        el.style.cssText = el.__artemisLift
          + ';position:fixed !important;left:' + t.x + 'px !important;top:' + t.y + 'px !important;'
          + 'width:' + t.w + 'px !important;height:' + t.h + 'px !important;margin:0 !important;'
          + 'min-width:0 !important;max-width:none !important;opacity:0 !important;'
          + 'pointer-events:auto !important;z-index:2147483647 !important;';
      }
      function moveSkip() { var sk = findSkip(); if (sk) pinUnder(sk.el, window.__artemisSkipTarget); }

      // the laid-out control matching `sels`, or null until it has a real size.
      // not offsetParent, which goes null once pinUnder sets position:fixed
      function findControl(sels, fallback) {
        if (!st.prof || !st.prof.alive) return null;
        for (var i = 0; i < sels.length; i++) {
          var e = q(sels[i]);
          if (!e || e.disabled) continue;
          var cs = getComputedStyle(e);
          if (cs.display === 'none' || cs.visibility === 'hidden') continue;
          var r = e.getBoundingClientRect();
          if (r.width < 12 || r.height < 12) continue;
          var label = (e.getAttribute('aria-label') || e.innerText || e.textContent || fallback)
            .replace(/\\s+/g, ' ').trim();
          if (!label || label.length > 20) label = fallback;
          return { el: e, label: label };
        }
        return null;
      }
      function findSkip() {
        return findControl(skipAdSelectors, 'Skip');
      }

      function scanButtons() {
        var out = [], seen = Object.create(null), els = btnCandidates();
        for (var i = 0; i < els.length && out.length < 40; i++) {
          var l = btnLabel(els[i]);
          if (!l || l.length > 40) continue;
          var k = l.toLowerCase();
          // ad-skip has its own bottom-bar button (moveSkip)
          if (st.prof && st.prof.alive && k.indexOf('skip') !== -1) continue;
          if (seen[k]) continue;
          seen[k] = 1; out.push(l);
        }
        return out;
      }

      window.__artemisPip = {
        apply: apply,
        remove: remove,
        state: function () {
          var v = st.video; if (!v) return null;
          var active = ''; try { active = ccImpl().active() || ''; } catch (e) {}
          var ad = false;
          try { ad = !!(st.root && st.root.classList &&
            (st.root.classList.contains('ad-showing') || st.root.classList.contains('ad-interrupting'))); } catch (e) {}
          var sk = null; try { sk = findSkip(); } catch (e) {}
          try { moveSkip(); } catch (e) {}
          return { ad: ad,
            skippable: !!sk, skipLabel: sk ? sk.label : '',
            playing: !v.paused, current: v.currentTime || 0,
            duration: isFinite(v.duration) ? v.duration : 0, muted: !!v.muted,
            volume: (v.muted ? 0 : (v.volume == null ? 1 : v.volume)),
            w: v.videoWidth || 0, h: v.videoHeight || 0, ccActive: active };
        },
        // our skip button's rect in CSS px; moveSkip re-pins the real one under it each tick
        setSkipTarget: function (x, y, w, h) {
          window.__artemisSkipTarget = (w > 0 && h > 0) ? { x: x, y: y, w: w, h: h } : null;
        },
        caption: function () { try { return capText(); } catch (e) { return ''; } },
        setCaptionRender: function (custom) { try { setCaptionRender(!!custom); } catch (e) {} },
        toggle: function () { var v = st.video; if (!v) return; if (v.paused) v.play(); else v.pause(); },
        pause: function () { var v = st.video; if (v) v.pause(); },
        seek: function (t) { var v = st.video; if (v && isFinite(t)) v.currentTime = t; },
        mute: function () { var v = st.video; if (!v) return false; v.muted = !v.muted; return v.muted; },
        setVolume: function (x) {
          var v = st.video; if (!v) return;
          x = Math.max(0, Math.min(1, x)); v.volume = x; v.muted = (x <= 0);
        },
        ccList: function () { try { return ccImpl().list() || []; } catch (e) { return []; } },
        ccActive: function () { try { return ccImpl().active() || ''; } catch (e) { return ''; } },
        ccSelect: function (id) {
          try { var c = ccImpl(); if (!id) { if (c.off) c.off(); } else c.select(id); } catch (e) {}
        },
        // the labels of buttons up right now; Swift polls at 4Hz, the scan runs ~1Hz
        buttons: function () {
          if (!st.video) return [];
          var now = Date.now();
          if (st.btnCache && now - st.btnAt < 900) return st.btnCache;
          st.btnAt = now;
          try { sweep(); } catch (e) {}
          try { st.btnCache = scanButtons(); } catch (e) { st.btnCache = []; }
          return st.btnCache;
        },
        clickAllowed: function (label) {
          try {
            var k = String(label).replace(/\\s+/g, ' ').trim().toLowerCase();
            var els = btnCandidates(), match = null, ghost = null;
            for (var i = 0; i < els.length; i++) {
              if (btnLabel(els[i]).toLowerCase() !== k) continue;
              var el = els[i], r = el.getBoundingClientRect();
              // the visible one: hidden 0×0 copies swallow a click and do nothing
              if (r.width > 1 && r.height > 1 && el.offsetParent !== null) {
                match = el;
                if (el.tagName === 'BUTTON') break;
              } else if (!ghost) { ghost = el; }
            }
            var target = match || ghost;
            if (!target) { return false; }
            var r = target.getBoundingClientRect();
            var cx = r.left + r.width / 2, cy = r.top + r.height / 2;
            var o = { bubbles: true, cancelable: true, composed: true, view: window, clientX: cx, clientY: cy, button: 0, buttons: 1 };
            try { target.dispatchEvent(new PointerEvent('pointerdown', o)); } catch (e) {}
            try { target.dispatchEvent(new MouseEvent('mousedown', o)); } catch (e) {}
            try { target.dispatchEvent(new PointerEvent('pointerup', o)); } catch (e) {}
            try { target.dispatchEvent(new MouseEvent('mouseup', o)); } catch (e) {}
            try { target.dispatchEvent(new MouseEvent('click', o)); } catch (e) {}
            try { target.click(); } catch (e) {}
            return true;
          } catch (e) { return false; }
        }
      };
      return apply();
    })();
    """
}
