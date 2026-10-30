import AppKit
import NaturalLanguage
import SwiftUI
import Translation
import UniformTypeIdentifiers
import WebKit

/// the `accept` attribute of the file input that opened the panel. Public
/// `WKOpenPanelParameters` carries only the multiple/directories flags, so
/// filtering the picker at all needs this. Both are guarded by `responds(to:)`.
@objc private protocol WKOpenPanelParametersSPI {
    var _acceptedMIMETypes: [String] { get }
    var _acceptedFileExtensions: [String] { get }
}

/// private WKWebView SPI for native Picture in Picture. macOS WKWebView ships the
/// full native PiP stack but only exposes it through these underscored methods —
/// the JS `video.webkitSetPresentationMode` path silently no-ops in a non-Safari
/// host. This is the surface Safari and WebKit's MiniBrowser drive. Reached
/// via `unsafeBitCast` (WKWebView responds to these selectors without declaring
/// conformance); every call site guards with `responds(to:)` so a future WebKit
/// that drops them degrades gracefully instead of crashing.
@objc private protocol WKWebViewPiPSPI {
    func _togglePictureInPicture()
    /// lazily creates the AVKit controls manager that backs PiP. macOS only spins
    /// it up through the Touch Bar path (a key-window hook a third-party WKWebView
    /// never trips), so `_canTogglePictureInPicture` stays false until this is
    /// called — even with a playing, tracked video. MiniBrowser calls it right
    /// before reading canToggle; we do the same.
    func _updateMediaPlaybackControlsManager()
    var _canTogglePictureInPicture: Bool { get }
    var _isPictureInPictureActive: Bool { get }
    // macOS 26 "Viewer" — an in-window floating video that auto-falls-back to PiP
    // when occluded/tab-switched. WebKit ENABLES this for WKWebView (it greys out
    // classic PiP), so it's the supported floating-video path on macOS.
    func _toggleInWindow()
    func _enterInWindow()
    func _exitInWindow()
    var _canToggleInWindow: Bool { get }
    var _isInWindowActive: Bool { get }
    /// true while the web view is actively producing audio — a synchronous proxy
    /// for "media is really playing" (false when paused), used to gate auto-PiP
    var _isPlayingAudio: Bool { get }
    /// mute the whole page at the engine level (`_WKMediaMutedState` bitmask —
    /// bit 0 is audio). the public API has no per-web-view mute, and muting each
    /// `<video>` from JS misses Web Audio and any element created later; this is
    /// the switch Safari's own tab-mute flips.
    func _setPageMuted(_ state: UInt)
}

/// private WKPreferences SPI — `allowsPictureInPictureMediaPlayback` is public on
/// iOS but macOS only exposes this underscored setter. Without it WebKit greys out
/// PiP for a WKWebView. Called via a typed `unsafeBitCast` (NOT KVC — the KVC key
/// can't reach an underscored setter and throws).
@objc private protocol WKPreferencesPiPSPI {
    func _setAllowsPictureInPictureMediaPlayback(_ enabled: Bool)
}

/// private WKPreferences SPI gating the MediaStream / MediaDevices web APIs.
/// WKWebView leaves `navigator.mediaDevices` **undefined** unless these are on —
/// Safari turns them on, so a third-party WKWebView host has to as well. Prime
/// Video's player calls `navigator.mediaDevices.enumerateDevices()` during init;
/// against `undefined` it throws (`undefined is not an object … e.groupId`) and
/// the whole content load aborts with "Video Unavailable". Typed `unsafeBitCast`,
/// each call guarded with `responds(to:)`. We only expose the API surface (enable
/// device enumeration); getUserMedia capture still needs the permission delegate
/// + Info.plist usage strings, which a video player never invokes.
@objc private protocol WKPreferencesMediaDevicesSPI {
    func _setMediaDevicesEnabled(_ enabled: Bool)
    func _setMediaStreamEnabled(_ enabled: Bool)
}

/// private WKWebView SPI exposing the live Web Inspector. `isInspectable = true`
/// lets Safari attach remotely, but driving devtools *in-app* needs the
/// underscored `_inspector` accessor — the same `_WKInspector` object Safari and
/// MiniBrowser open. Fetched via a typed `unsafeBitCast` (KVC on an underscored
/// getter throws); the call site guards with `responds(to:)`.
@objc private protocol WKWebViewInspectorSPI {
    var _inspector: AnyObject? { get }
}

/// `_WKInspector` — the inspector controller. `show` docks it to the web view's
/// window (Safari's attached devtools); `close` tears it down. `toggleElementSelection`
/// arms click-to-inspect. `isVisible` getter backs `visible` on the Obj-C side.
@objc private protocol WKInspectorSPI {
    func show()
    func close()
    func detach()
    var isVisible: Bool { get }
}

/// a single browser tab
///
/// owns its `WKWebView` and mirrors the web view's state (title, url,
/// loading progress, history availability) into observable properties
/// so SwiftUI views can react to them
@Observable
final class BrowserTab: NSObject, Identifiable {
    /// stable across relaunches for a restored tab — a `TabRecord` carries it,
    /// and per-tab state on disk (interaction state, and later anything keyed to
    /// a specific tab) is filed under it
    let id: UUID

    // mirrored web view state
    private(set) var title = "New Tab"

    /// what the sidebar actually shows: the name you gave this tab, else the
    /// short name the on-device model suggested for an unwieldy page title, else
    /// the page's own title. See `TabNameStore`.
    @MainActor
    var displayTitle: String {
        TabNameStore.shared.name(for: url ?? pendingURL) ?? title
    }
    private(set) var url: URL?
    private(set) var isLoading = false
    private(set) var progress: Double = 0
    /// true briefly after a load completes so the progress bar can run to 100%
    private(set) var isFinishingLoad = false
    /// a stopped load ends without the run to 100%
    @ObservationIgnored private var stopRequested = false

    /// last url the user asked for (survives failed loads, unlike `webView.url`)
    private(set) var lastAttemptedURL: URL?
    /// human-readable load failure, nil when fine; drives the error page
    private(set) var loadError: String?
    private(set) var canGoBack = false
    private(set) var canGoForward = false

    /// the page's declared theme-color (`<meta name="theme-color">`), if any;
    /// drives chrome that adapts to the site's own colour
    private(set) var themeColor: NSColor?

    /// a colour standing in for the page's content — its theme-color when the
    /// site declares one, else the favicon's dominant accent. nil when neither
    /// is known yet (so chrome can fall back to glass)
    var pageTint: Color? {
        if let themeColor { return Color(nsColor: themeColor) }
        return faviconAccent
    }

    /// the host whose favicon represents this tab
    private var faviconHost: String? { (url ?? lastAttemptedURL ?? pendingURL)?.host() }

    /// resolved through the shared, persistent store keyed by host — so it
    /// survives relaunches, is shared across tabs on the same site, and shows
    /// before a lazily-restored tab ever loads, instead of falling back to a globe
    var favicon: NSImage? { FaviconStore.shared.icon(for: faviconHost) }

    /// a vivid colour sampled from this tab's favicon — used to tint the
    /// favourites selection ring to match the icon. nil until the icon resolves
    var faviconAccent: Color? { FaviconStore.shared.accent(for: faviconHost) }

    /// pinned tabs live in their own sidebar section and persist across launches
    var isPinned = false

    /// favourites ("essentials") live in the global grid at the top of the
    /// sidebar, shared across every space rather than owned by one
    var isEssential = false

    /// the url a pinned tab is anchored to; when the tab navigates away from it
    /// the row reads as "off" its pinned page. nil for unpinned tabs
    var pinnedURL: URL?

    /// the connected coding agent that has driven this tab; nil once it disconnects
    var agentName: String?

    /// a restored pinned tab defers loading until first selected, so launch
    /// with many pins stays fast (lazy hydration)
    private(set) var pendingURL: URL?

    /// when the tab was last viewed or navigated; drives auto-archive of stale
    /// Today tabs. persisted so a tab's age survives relaunches
    var lastAccessed = Date()

    /// live text in the url field; user edits happen here until submit,
    /// and committed navigations write the new url back into it
    var addressText = ""

    /// called when the page requests a new window (`target="_blank"`,
    /// `window.open`); must synchronously return a web view created with
    /// the given configuration, or nil to refuse. The features say whether the
    /// page asked for a sized popup (a sign-in flow) or just another page
    @ObservationIgnored var onRequestNewTab:
        ((WKWebViewConfiguration, WKWindowFeatures) -> WKWebView?)?

    /// the page called `window.close()` on itself
    @ObservationIgnored var onRequestClose: (() -> Void)?

    /// the close the user asked for, run once the page's `beforeunload` lets it go
    @ObservationIgnored var onConfirmedClose: (() -> Void)?

    /// a link clicked with modifiers held (or force clicked), to open elsewhere
    @ObservationIgnored var onOpenLink: ((URL, LinkClick) -> Void)?

    /// called when a page finishes loading — feeds the history store
    @ObservationIgnored var onDidNavigate: ((URL, String) -> Void)?

    /// called whenever the page settles on a real title, which can be well after
    /// it finished loading
    @ObservationIgnored var onDidSettleTitle: ((URL, String) -> Void)?

    /// back-reference to the owning model, set in `TabManager.wire`. lets the
    /// WebExtensions runtime drive selection/close/pin through this tab.
    @ObservationIgnored weak var manager: TabManager?

    /// rebuilt (not mutated) when the tab changes profile — WebKit fixes a web
    /// view's data store at creation, so a new jar means a new web view
    @ObservationIgnored private(set) var webView: WKWebView
    /// the cookie jar this tab's web view is bound to. `ProfileStore` caches one
    /// store per profile, so `===` tells a real profile move from a no-op
    @ObservationIgnored private(set) var dataStore: WKWebsiteDataStore
    /// bumps each time `webView` is rebuilt, so the SwiftUI host's `.id` changes
    /// and it re-mounts the fresh view. observed (not @ObservationIgnored) so the
    /// content stack actually re-reads it
    private(set) var webViewGeneration = 0
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    /// the main-window slot currently hosting this tab's web view. the mini-player
    /// borrows the live web view out of here into a floating panel and hands it
    /// back, so the slot is kept weak and re-set whenever it (re)mounts.
    @ObservationIgnored weak var webHost: WebHostView?

    /// the page's last frame, for a second window showing the same tab: only one
    /// window can hold the live web view, and the other stands this in
    var stillFrame: NSImage?
    /// true while this tab's video is popped out into the floating mini-player.
    /// the web-view slot reads it so it leaves itself empty while the panel owns
    /// the view (and re-hosts the view when it flips back to false).
    var isMiniPlayerActive = false

    // MARK: - JavaScript dialogs

    /// the `alert()` / `confirm()` / `prompt()` / leave-page question this page
    /// is currently blocked on. Rendered by whichever surface hosts the tab
    private(set) var pendingDialog: PageDialogRequest?
    /// the user asked this page to stop putting up dialogs; cleared on navigation
    private var suppressesDialogs = false
    /// dialogs since the last commit — the second one earns a suppression offer
    private var dialogsThisPage = 0

    /// this load failed on a certificate the user could choose to accept
    private(set) var canOverrideCertificate = false

    // MARK: - Translation

    /// text the user asked to have translated, or nil when nothing is being
    /// translated. Drives the system's on-device translation popover
    private(set) var pendingTranslation: String?

    /// Translate what's selected on the page, on this machine.
    ///
    /// Worth stating plainly because it is the differentiator: Apple's own
    /// privacy documentation says Safari sends a page's full text to Apple's
    /// servers to translate it, and every Chromium browser ships it to a server
    /// too. The system translation popover runs against locally-installed
    /// language packs, so the selection never leaves the Mac.
    @MainActor
    func translateSelection() async {
        let selected =
            (try? await webView.evaluateJavaScript("window.getSelection().toString()")) as? String
        let trimmed = (selected ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // the popover is for a passage, not a chapter
        pendingTranslation = String(trimmed.prefix(2000))
    }

    @MainActor
    func clearTranslation() { pendingTranslation = nil }

    // MARK: - Page translation

    private(set) var pageTranslation = PageTranslation.State.idle
    /// non-nil while a page translation runs; the web view's `.translationTask` turns it into a session
    private(set) var pageTranslationRequest: TranslationSession.Configuration?
    /// waiting for a session; a session claims it, and hands it back if it is cancelled
    @ObservationIgnored private var pageCapture: PageCapture?
    /// bumped whenever a page translation ends, so in-flight work for an older one stops
    @ObservationIgnored private var pageTranslationGeneration = 0

    /// a page's captured text nodes, as numbered by the capture script
    private struct PageCapture {
        let id: Int
        let texts: [String]
        let source: Locale.Language
        let target: Locale.Language
    }

    /// ⌥⌘T — translate the whole page on this machine, or put the original back
    func toggleTranslation() async {
        if pageTranslation.isActive {
            showOriginal()
        } else {
            await beginPageTranslation()
        }
    }

    func showOriginal() {
        endPageTranslation()
        webView.callAsyncJavaScript(PageTranslation.restore, in: nil, in: PageTranslation.world)
    }

    /// runs inside the web view's `.translationTask` once `pageTranslationRequest` is set
    func translatePage(with session: TranslationSession) async {
        guard let capture = pageCapture else { return }
        pageCapture = nil
        let generation = pageTranslationGeneration
        do {
            try await session.prepareTranslation()
            // one request per unique string; members[n] are the node indices sharing request n
            var requestFor: [String: Int] = [:]
            var members: [[Int]] = []
            var requests: [TranslationSession.Request] = []
            for (index, text) in capture.texts.enumerated() {
                if let request = requestFor[text] {
                    members[request].append(index)
                    continue
                }
                requestFor[text] = members.count
                requests.append(.init(sourceText: text, clientIdentifier: String(members.count)))
                members.append([index])
            }

            var pending: [[Any]] = []
            var done = 0
            var lastFlush = ContinuousClock.now
            func flush() async throws {
                guard !pending.isEmpty else { return }
                _ = try await webView.callAsyncJavaScript(
                    PageTranslation.apply, arguments: ["id": capture.id, "pairs": pending],
                    contentWorld: PageTranslation.world)
                guard generation == pageTranslationGeneration else { throw CancellationError() }
                pending = []
                lastFlush = .now
                pageTranslation = .translating(progress: Double(done) / Double(requests.count))
            }
            for try await response in session.translate(batch: requests) {
                guard generation == pageTranslationGeneration else { return session.cancel() }
                if let request = response.clientIdentifier.flatMap(Int.init) {
                    pending += members[request].map { [$0, response.targetText] }
                }
                done += 1
                if pending.count >= 8 || ContinuousClock.now - lastFlush > .milliseconds(60) {
                    try await flush()
                }
            }
            try Task.checkCancellation()
            guard generation == pageTranslationGeneration else { return }
            try await flush()
            endPageTranslation(.translated(from: capture.source, to: capture.target))
        } catch {
            guard generation == pageTranslationGeneration else { return }
            if Task.isCancelled {
                pageCapture = capture
                return
            }
            showOriginal()
            pageTranslation = .failed(error.localizedDescription)
        }
    }

    private func beginPageTranslation() async {
        endPageTranslation(.translating(progress: 0))
        let generation = pageTranslationGeneration
        do {
            let result = try await webView.callAsyncJavaScript(
                PageTranslation.capture, contentWorld: PageTranslation.world) as? [String: Any]
            guard generation == pageTranslationGeneration else { return }
            let texts = result?["texts"] as? [String] ?? []
            guard let id = result?["id"] as? Int, !texts.isEmpty else {
                return endPageTranslation(.failed("There's no text on this page to translate."))
            }

            // detection samples at most 400 nodes / 3000 chars; the declared lang is the fallback
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(String(texts.prefix(400).joined(separator: "\n").prefix(3000)))
            let declared = result?["lang"] as? String ?? ""
            let source: Locale.Language
            if let best = recognizer.languageHypotheses(withMaximum: 1).first, best.value >= 0.5 {
                source = Locale.Language(identifier: best.key.rawValue)
            } else if !declared.isEmpty {
                source = Locale.Language(identifier: declared)
            } else {
                return endPageTranslation(.failed("Couldn't tell what language this page is in."))
            }
            let target = Locale.Language(identifier: Locale.preferredLanguages.first ?? "en")
            guard source.languageCode != target.languageCode else {
                return endPageTranslation(
                    .failed("This page is already in \(PageTranslation.name(of: target))."))
            }

            pageCapture = PageCapture(id: id, texts: texts, source: source, target: target)
            pageTranslationRequest = TranslationSession.Configuration(source: source, target: target)
        } catch {
            guard generation == pageTranslationGeneration else { return }
            endPageTranslation(.failed(error.localizedDescription))
        }
    }

    /// the page keeps whatever text it holds; callers restore it when they need to
    private func endPageTranslation(_ state: PageTranslation.State = .idle) {
        pageTranslationGeneration += 1
        pageCapture = nil
        pageTranslationRequest = nil
        pageTranslation = state
    }

    /// read by the suite, which asserts on when the suppression offer appears
    var dialogsRaisedThisPage: Int { dialogsThisPage }

    // MARK: - Media state

    /// frames of this page currently playing media, keyed by frame url (a video
    /// usually lives in an iframe, and several can play at once). fed by
    /// `MediaStateReporter`; the tab counts as playing while it's non-empty
    @ObservationIgnored private var playingFrames: Set<String> = []

    /// true while any frame in this tab is playing audio or video. drives the
    /// sidebar's speaker indicator. unlike the engine's `_isPlayingAudio` this
    /// stays true for a *muted* playing video, so the row keeps its unmute button
    private(set) var isPlayingMediaContent = false

    /// engine-level mute for this tab (⌥ the speaker, or the row's button).
    /// survives navigation within the tab — like Safari, muting a tab mutes the
    /// tab, not just the page that happened to be open
    private(set) var isMuted = false

    /// record a frame's playback state; recomputes the tab-level flag
    func setFramePlaying(_ playing: Bool, frame: String) {
        if playing {
            playingFrames.insert(frame)
        } else {
            playingFrames.remove(frame)
        }
        let now = !playingFrames.isEmpty
        if now != isPlayingMediaContent { isPlayingMediaContent = now }
    }

    /// mute or unmute every media element (and Web Audio) in this tab
    func setMuted(_ muted: Bool) {
        guard isMuted != muted else { return }
        isMuted = muted
        applyMuteState()
    }

    func toggleMuted() { setMuted(!isMuted) }

    /// frames holding controllable media, keyed like `playingFrames`
    @ObservationIgnored private var mediaFrames: [String: (info: WKFrameInfo, media: PageMedia)] = [:]
    /// the frame `media` came from, where `sendMediaCommand` goes
    @ObservationIgnored private var mediaFrame: WKFrameInfo?
    /// the media the sidebar's Now Playing card shows: this tab's top-ranked frame
    private(set) var media: PageMedia?

    /// record a frame's controllable media (nil once it has none); re-elects `media`
    func setFrameMedia(_ media: PageMedia?, frame key: String, info: WKFrameInfo) {
        if var media {
            let old = mediaFrames[key]?.media
            media.startedAt = media.isPlaying && old?.isPlaying != true ? .now : old?.startedAt ?? .now
            mediaFrames[key] = (info, media)
        } else {
            mediaFrames[key] = nil
        }
        let lead = mediaFrames.values.max { $0.media.rank < $1.media.rank }
        mediaFrame = lead?.info
        if self.media != lead?.media { self.media = lead?.media }
    }

    func sendMediaCommand(_ command: MediaCommand) {
        guard let mediaFrame else { return }
        webView.evaluateJavaScript(
            "window.__artemisMedia && window.__artemisMedia('\(command.rawValue)')",
            in: mediaFrame, in: .page)
    }

    /// a fresh document or web view plays nothing
    private func resetMediaState() {
        playingFrames.removeAll()
        isPlayingMediaContent = false
        mediaFrames.removeAll()
        mediaFrame = nil
        media = nil
    }

    /// push `isMuted` down to the engine. re-applied after a web-view rebuild so
    /// a profile move doesn't silently unmute the tab
    private func applyMuteState() {
        guard webView.responds(to: Selector(("_setPageMuted:"))) else { return }
        // _WKMediaMutedState: bit 0 = audio muted
        unsafeBitCast(webView, to: WKWebViewPiPSPI.self)._setPageMuted(isMuted ? 1 : 0)
    }

    // MARK: - Passwords

    var loginOffer: LoginOffer?
    @ObservationIgnored var loginCandidate: LoginCandidate?
    /// where this document's login form is
    @ObservationIgnored var loginTarget: LoginTarget?
    /// the username a two-step sign-in entered on its first page
    @ObservationIgnored var loginUsernameHint: (origin: String, name: String, at: Date)?

    // MARK: - Zoom

    /// this tab's current page-zoom factor. seeded from `ZoomStore` for the site
    /// being shown, so a site you zoomed once opens zoomed everywhere
    private(set) var zoomLevel: Double = ZoomStore.defaultZoom

    /// set the zoom for the site this tab is showing, and remember it for that
    /// site. `remember: false` is for applying a stored value back (no re-save)
    @MainActor
    func setZoom(_ zoom: Double, remember: Bool = true) {
        let clamped = min(max(zoom, ZoomStore.steps.first!), ZoomStore.steps.last!)
        zoomLevel = clamped
        webView.pageZoom = clamped
        LoginKeys.on(webView)?.settle()
        // an incognito tab's zoom works but isn't remembered — the per-site zoom
        // file is on disk, and incognito writes nothing to disk
        if remember, !isPrivate {
            ZoomStore.shared.setZoom(clamped, for: url ?? lastAttemptedURL ?? pendingURL)
        }
    }

    /// an incognito page — its jar is non-persistent, whatever opened it. drives
    /// every no-disk rule: history, zoom, favicons, passwords, the undo stack
    var isPrivate: Bool { !dataStore.isPersistent }

    /// the profile this page browses as; nil for an incognito page
    var profileID: Profile.ID? { ProfileStore.profileID(of: dataStore) }

    /// whose saved logins this page fills from. an incognito page reads its
    /// window's opener's, and never writes back
    var loginProfile: Profile.ID { profileID ?? manager?.currentProfile.id ?? Profile.defaultID }

    @MainActor func zoomIn() { setZoom(ZoomStore.step(from: zoomLevel, by: 1)) }
    @MainActor func zoomOut() { setZoom(ZoomStore.step(from: zoomLevel, by: -1)) }
    @MainActor func resetZoom() { setZoom(ZoomStore.defaultZoom) }

    /// re-read the stored zoom for the page now showing. called on every committed
    /// navigation, so following a link to another site adopts that site's zoom
    @MainActor
    func syncZoomToSite() {
        let stored = ZoomStore.shared.zoom(for: url ?? lastAttemptedURL ?? pendingURL)
        guard abs(stored - zoomLevel) > 0.001 else { return }
        setZoom(stored, remember: false)
    }

    // MARK: - Reader

    /// true while this tab is showing the stripped-down reader instead of the page
    private(set) var isReaderMode = false
    /// the page looks like an article, so the reader button is worth offering.
    /// set by a cheap probe on load — the real extraction only runs on toggle
    private(set) var isReaderAvailable = false
    /// where to go back to when the reader is dismissed
    @ObservationIgnored private var preReaderURL: URL?
    /// set for the one navigation that *is* the reader document. without it the
    /// "navigating away leaves the reader" rule fires on the reader's own load and
    /// switches itself straight back off
    @ObservationIgnored private var isLoadingReaderDocument = false

    /// cheap "is there an article here" probe, run once per load. counting text in
    /// the page beats running the extractor on every navigation
    /// also called when a tab becomes visible, since a background tab skips the
    /// probe on load and would otherwise never offer the reader
    func probeReaderAvailability() {
        // `innerText` forces a layout pass, so this only runs for the page you're
        // actually looking at — a background tab finishing a load shouldn't make
        // the engine reflow it for a button nobody can see
        // a script into a web view with no page launches its web process on main
        guard webView.url != nil, manager == nil || manager?.displayedContentTab === self else {
            isReaderAvailable = false
            return
        }
        let script = """
            (() => {
              const article = document.querySelector('article, main');
              const text = (article || document.body)?.innerText || '';
              return text.trim().length;
            })()
            """
        webView.evaluateJavaScript(script) { [weak self] result, _ in
            guard let self else { return }
            let length = (result as? Int) ?? 0
            self.isReaderAvailable = !self.isReaderMode && length > 1200
        }
    }

    /// ⌘⇧R — swap the page for a clean reading view, or go back to the page
    @MainActor
    func toggleReader() async {
        if isReaderMode {
            isReaderMode = false
            if let preReaderURL { load(preReaderURL) }
            preReaderURL = nil
            return
        }
        guard let current = url else { return }
        let html = (try? await webView.evaluateJavaScript("document.documentElement.outerHTML"))
            as? String
        guard let html,
            let article = ReaderMode.extract(html: html, url: current)
        else {
            // nothing article-shaped here after all; don't leave a dead button
            isReaderAvailable = false
            return
        }
        preReaderURL = current
        isReaderMode = true
        isLoadingReaderDocument = true
        // baseURL is the real page so relative images and links still resolve
        webView.loadHTMLString(ReaderMode.page(for: article), baseURL: current)
    }

    // MARK: - Printing

    /// ⌘P — hand the page to the standard macOS print panel. WebKit paginates the
    /// rendered content itself, so this prints what you see (headers, backgrounds
    /// and all) rather than a re-layout
    @MainActor
    func printPage() {
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        let operation = webView.printOperation(with: info)
        operation.view?.frame = webView.bounds
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        if let window = webView.window {
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            operation.run()
        }
    }

    init(
        id: UUID = UUID(),
        configuration: WKWebViewConfiguration = BrowserTab.defaultConfiguration()
    ) {
        self.id = id
        webView = ArtemisWebView(frame: .zero, configuration: configuration)
        dataStore = configuration.websiteDataStore
        super.init()
        configureWebView()
        observeWebView()
    }

    /// one-time web-view setup, shared by `init` and `rebuildWebView`
    private func configureWebView() {
        // transparent only until the first commit (see `didCommit`), so a fresh view never
        // flashes white; after that the page owns its canvas and the space never tints it
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .clear
        // extension context menus need to know which tab the menu is for
        (webView as? ArtemisWebView)?.owningTab = self

        // swipe-to-navigate hijacks horizontal scrolling on wide pages — off
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsMagnification = true
        webView.isInspectable = true
        webView.uiDelegate = self
        webView.navigationDelegate = self
        // carry per-tab state across a rebuild (profile move) — a muted tab must
        // not come back audible, and a zoomed one must not come back at 100%
        webView.pageZoom = zoomLevel
        applyMuteState()
        resetMediaState()
    }

    /// move this tab into a different profile. because the data store can't be
    /// swapped on a live web view, we build a fresh one bound to `newStore` and
    /// reload where we were. back/forward history and scroll are lost — changing
    /// identity is a deliberate clean break. no-op when the store is unchanged,
    /// so same-profile moves (the common case) never reload
    func rebuildWebView(with newStore: WKWebsiteDataStore) {
        guard newStore !== dataStore else { return }
        // the old web view is about to be dropped; its unanswered question would
        // otherwise hold a handler nothing can ever call
        abandonDialog()
        let wasPending = pendingURL
        let resume = url ?? lastAttemptedURL ?? pendingURL

        observations.forEach { $0.invalidate() }
        observations = []

        webView = ArtemisWebView(
            frame: .zero, configuration: BrowserTab.defaultConfiguration(dataStore: newStore))
        dataStore = newStore
        configureWebView()
        observeWebView()
        webViewGeneration += 1

        // a tab that hadn't loaded yet stays lazy under the new store (pendingURL
        // is untouched); a live one reloads its current page in the new jar
        if wasPending == nil, let resume { load(resume) }
    }

    /// restore a tab without loading it yet; the host name stands in as the
    /// title until the page is hydrated on first selection (lazy)
    convenience init(
        id: UUID = UUID(), restoring url: URL, pinned: Bool, pinnedURL: URL? = nil,
        lastAccessed: Date = Date(), dataStore: WKWebsiteDataStore? = nil
    ) {
        self.init(id: id, configuration: BrowserTab.defaultConfiguration(dataStore: dataStore))
        isPinned = pinned
        self.pinnedURL = pinned ? (pinnedURL ?? url) : nil
        pendingURL = url
        self.lastAccessed = lastAccessed
        if let host = url.host() {
            title = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
        addressText = url.absoluteString
    }

    /// name a restored tab before it loads, when the import knew the title the
    /// page had. the real title replaces it on first navigation
    func adopt(restoredTitle: String) {
        guard !restoredTitle.isEmpty, url == nil else { return }
        title = restoredTitle
    }

    /// a pinned tab that has navigated away from its anchored `pinnedURL`
    var isOffPinnedURL: Bool {
        guard isPinned, let pinnedURL,
            let current = url ?? lastAttemptedURL ?? pendingURL
        else { return false }
        return BrowserTab.normalizedLocation(current) != BrowserTab.normalizedLocation(pinnedURL)
    }

    /// compare urls ignoring a trailing slash and case, so "site.com" and
    /// "site.com/" read as the same place
    static func normalizedLocation(_ url: URL) -> String {
        var s = url.absoluteString
        while s.hasSuffix("/") { s.removeLast() }
        return s.lowercased()
    }

    /// fetch just the site's favicon without loading the page, so a restored
    /// favourite shows its real icon in the grid before it's ever selected
    func prefetchFavicon() {
        FaviconStore.shared.prefetch(host: faviconHost, isPrivate: isPrivate)
    }

    /// mark the tab as just-used, resetting its auto-archive clock
    func touch() { lastAccessed = Date() }

    /// load the page if this tab was restored lazily and hasn't loaded yet, or
    /// was hibernated. a hibernated tab comes back through its saved interaction
    /// state, which restores scroll position, form contents and the back/forward
    /// list — not just the url
    func activateIfNeeded() {
        if needsReloadAfterCrash {
            needsReloadAfterCrash = false
            webView.reload()
        }
        guard let pendingURL else { return }
        self.pendingURL = nil
        isHibernated = false
        if let state = savedInteractionState {
            savedInteractionState = nil
            lastAttemptedURL = pendingURL
            loadError = nil
            lastAccessed = Date()
            // assigning interaction state *is* the navigation — WebKit replays the
            // session entry rather than starting a fresh load
            webView.interactionState = state
            // …unless WebKit declines it (a stale or cross-version blob), in which
            // case fall back to an ordinary load so the tab never comes back blank
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self, self.webView.url == nil, !self.webView.isLoading else { return }
                self.load(pendingURL)
            }
        } else {
            load(pendingURL)
        }
    }

    // MARK: - Hibernation

    /// true while this tab is asleep: its web view (and the web content process
    /// behind it) has been released, and the page is stored as a url plus an
    /// interaction-state blob until the tab is next selected
    private(set) var isHibernated = false

    /// WebKit's opaque session blob — scroll offset, form state, back/forward
    /// list — kept while asleep so waking restores the page rather than reloading
    /// it from scratch
    @ObservationIgnored private var savedInteractionState: Any?

    /// never put to sleep by the idle timer or memory pressure
    var keepsLoaded = false

    /// the web content process died while the tab was off screen; reload on next show
    @ObservationIgnored private var needsReloadAfterCrash = false
    @ObservationIgnored private var lastCrash: Date?

    private(set) var cameraCapture: WKMediaCaptureState = .none
    private(set) var microphoneCapture: WKMediaCaptureState = .none
    var usesCamera: Bool { cameraCapture != .none }
    var isCapturing: Bool { usesCamera || microphoneCapture != .none }

    /// ends the page's camera and microphone capture; it must ask again to resume
    func stopCapture() {
        webView.setCameraCaptureState(.none)
        webView.setMicrophoneCaptureState(.none)
    }

    /// one request this page had blocked, and whether the privacy list is what
    /// recognised it — the ledger a blocker extension's panel reads back
    struct BlockedRequest {
        let url: URL
        let at: Date
        let isTracker: Bool
        /// the rule list that killed it — an extension's own list is named by
        /// its context's `uniqueIdentifier`, ours by `artemis-block-…`
        let list: String
    }

    /// blocked requests for the current document, oldest first
    @ObservationIgnored private(set) var blockedRequests: [BlockedRequest] = []

    /// several lists can report the same request; only the first counts
    private func recordBlockedRequest(_ url: URL, list: String) {
        let now = Date()
        if blockedRequests.contains(where: {
            $0.url == url && now.timeIntervalSince($0.at) < 5
        }) { return }
        if blockedRequests.count >= 2000 { blockedRequests.removeFirst(500) }
        blockedRequests.append(
            BlockedRequest(
                url: url, at: now, isTracker: ContentBlocker.shared.isTracker(url), list: list))
    }

    /// how many requests each rule list blocked on this page, for diagnostics:
    /// this is what separates an extension's own blocking from Artemis's
    var blockedRequestsByList: [String: Int] {
        blockedRequests.reduce(into: [:]) { $0[$1.list, default: 0] += 1 }
    }

    /// the blob worth writing down: the live page's, or the one held while
    /// asleep or not yet restored (an unloaded web view's state is empty)
    var persistableInteractionState: Any? {
        isHibernated || pendingURL != nil ? savedInteractionState : webView.interactionState
    }

    /// set by navigation; a debounced save writes only tabs that have it
    @ObservationIgnored var hasUnsavedState = true

    /// hand a restored tab the state it had last launch. It is replayed by
    /// `activateIfNeeded` on first selection — the same path a waking hibernated
    /// tab takes, including its fallback to a plain load if WebKit declines it
    func adopt(interactionState state: Any?) {
        guard pendingURL != nil else { return }
        savedInteractionState = state
    }

    /// a tab worth putting to sleep: loaded, not already asleep, and not doing
    /// anything you'd notice stopping
    var canHibernate: Bool {
        guard !isHibernated, pendingURL == nil else { return false }
        guard let current = url ?? lastAttemptedURL, current.scheme?.hasPrefix("http") == true
        else { return false }
        return !keepsLoaded && !isCapturing && !isPlayingMediaContent && !isMiniPlayerActive
            && !isLoading && agentName == nil
    }

    /// release this tab's web view and its web content process, remembering
    /// enough to restore the page exactly. this is the difference between 40 open
    /// tabs costing 4GB and costing a few hundred megabytes — WebKit keeps a
    /// process per live view, and a background tab you haven't looked at since
    /// this morning has no business holding one
    func hibernate() {
        guard canHibernate, let current = url ?? lastAttemptedURL else { return }
        savedInteractionState = webView.interactionState
        pendingURL = current
        isHibernated = true

        observations.forEach { $0.invalidate() }
        observations = []
        // a brand-new WKWebView that is never loaded doesn't spawn a web process,
        // so this genuinely gives the memory back
        webView = ArtemisWebView(
            frame: .zero, configuration: BrowserTab.defaultConfiguration(dataStore: dataStore))
        configureWebView()
        observeWebView()
        webViewGeneration += 1
        // the observers just re-read an empty view; restore the display state the
        // sidebar should keep showing while the tab sleeps
        if let host = current.host() {
            title = title.isEmpty || title == "New Tab"
                ? (host.hasPrefix("www.") ? String(host.dropFirst(4)) : host) : title
        }
        url = current
        addressText = current.absoluteString
        canGoBack = false
        canGoForward = false
        debugLog("tab hibernated: \(current.absoluteString)")
    }

    /// Arc's "–" on a pinned tab: close the page but keep the pin. The live web
    /// view (and its web content process) is released and the tab returns to
    /// the dormant state a restored pin starts in — anchored to `pinnedURL`,
    /// loading nothing until next selected. Unlike hibernation, the session is
    /// deliberately dropped: closing means "done here", so the next visit
    /// starts fresh at the pinned page, not wherever you'd wandered off to
    func closeToPinned() {
        guard let anchor = pinnedURL ?? url ?? lastAttemptedURL ?? pendingURL else { return }
        WebNotifications.shared.forgetPage(in: id)
        savedInteractionState = nil
        isHibernated = false
        pendingURL = anchor
        loadError = nil

        observations.forEach { $0.invalidate() }
        observations = []
        webView = ArtemisWebView(
            frame: .zero, configuration: BrowserTab.defaultConfiguration(dataStore: dataStore))
        configureWebView()
        observeWebView()
        webViewGeneration += 1

        url = anchor
        addressText = anchor.absoluteString
        if let host = anchor.host() {
            title = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
        canGoBack = false
        canGoForward = false
    }

    /// the host's installed Safari short version (e.g. "27.0"), read once from
    /// Safari.app so the UA's `Version/` token follows OS updates. falls back to a
    /// recent value when Safari is missing or unreadable.
    private static let currentSafariVersion: String = {
        if let dict = NSDictionary(contentsOfFile: "/Applications/Safari.app/Contents/Info.plist"),
            let v = dict["CFBundleShortVersionString"] as? String, !v.isEmpty {
            return v
        }
        return "26.0"
    }()

    /// shared baseline configuration for new tabs
    ///
    /// the application name keeps sites from serving degraded pages to an
    /// unrecognized WebKit user agent
    ///
    /// the `Version/` token must track the host's real Safari, not a frozen
    /// number: premium streamers (Prime Video, Netflix) gate their DRM player on
    /// the claimed Safari version, and a stale value (e.g. `17.6` on a Safari-26
    /// box) makes Prime serve a player that dies with "Video Unavailable". derived
    /// from CoreServices so it follows OS updates instead of rotting.
    ///
    /// Launch a spare web content process ahead of a new tab, so its first load
    /// doesn't start one (and register every installed font) on the main thread.
    static func prewarmWebProcess() {
        let warm = Selector(("_warmInitialProcess"))
        guard processPool.responds(to: warm) else { return }
        processPool.perform(warm)
    }

    /// every tab's process pool. A configuration left to make its own builds a
    /// new pool per tab: no warm process to reuse, and a fresh main-thread scan
    /// of every installed font for each one
    static let processPool = WKProcessPool()

    /// `dataStore` binds the tab to a profile's jar; nil is WebKit's default store,
    /// which is the default profile's
    static func defaultConfiguration(dataStore: WKWebsiteDataStore? = nil) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.processPool = processPool
        if let dataStore { configuration.websiteDataStore = dataStore }
        configuration.applicationNameForUserAgent = "Version/\(currentSafariVersion) Safari/605.1.15"
        configuration.preferences.isElementFullscreenEnabled = true
        // Writing Tools defaults to `.limited` — a floating panel that hands text
        // back. `.complete` rewrites in place inside the page's own editors, which
        // only a WebKit host can offer: Blink paints its own text controls.
        configuration.writingToolsBehavior = .complete
        // legacy private pref that backs the in-app Web Inspector. the modern
        // `isInspectable` flag (set per-web-view) lets Safari attach remotely, but
        // presenting `_inspector` *in our own window* still needs developer extras
        // turned on at the preferences level. KVC reaches the unexposed setter.
        configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        // let web video into real (detached) Picture in Picture, not just the macOS
        // Viewer. typed SPI call, guarded — KVC can't reach this underscored setter.
        let prefs = configuration.preferences
        if prefs.responds(to: Selector(("_setAllowsPictureInPictureMediaPlayback:"))) {
            unsafeBitCast(prefs, to: WKPreferencesPiPSPI.self)
                ._setAllowsPictureInPictureMediaPlayback(true)
        }
        // expose `navigator.mediaDevices` (it's undefined in a stock WKWebView).
        // streaming players enumerate devices during init; without this they hit
        // `undefined` and abort. Safari has these on by default — see SPI note above.
        let mediaPrefs = unsafeBitCast(prefs, to: WKPreferencesMediaDevicesSPI.self)
        if prefs.responds(to: Selector(("_setMediaStreamEnabled:"))) {
            mediaPrefs._setMediaStreamEnabled(true)
        }
        if prefs.responds(to: Selector(("_setMediaDevicesEnabled:"))) {
            mediaPrefs._setMediaDevicesEnabled(true)
        }
        ExtensionLab.quiet(prefs)
        // incognito pages get the private content controller and no extensions:
        // WebKit injects extension content into every controller it is attached to
        if dataStore?.isPersistent == false {
            configuration.userContentController = SharedWebContent.privateUserContentController
            return configuration
        }
        // the profile's own extension controller and user-content controller: its
        // extensions' content scripts, and Artemis's own scripts and rule lists
        let profile = WebExtensionRuntime.profile(of: dataStore)
        configuration.webExtensionController = WebExtensionRuntime.controller(for: profile)
        configuration.userContentController = SharedWebContent.userContentController(for: profile)
        return configuration
    }

    // MARK: - Navigation

    func load(_ url: URL) {
        debugLog("tab load: \(url.absoluteString)")
        lastAttemptedURL = url
        loadError = nil
        lastAccessed = Date()
        addressText = url.absoluteString
        guard url.isFileURL else {
            webView.load(URLRequest(url: url))
            return
        }
        // read access is granted for the file itself, not its folder: under the
        // App Sandbox the Powerbox grant covers what the user picked, and passing
        // the parent directory asks for something we were never given. A local
        // page's sibling stylesheet therefore won't load unless that folder was
        // picked too — the honest behaviour, rather than a silent half-load
        webView.loadFileURL(url, allowingReadAccessTo: url)
    }

    func retry() {
        if let lastAttemptedURL {
            load(lastAttemptedURL)
        }
    }

    /// resolve url-field input (url or search query) and load it
    func submit(_ input: String) {
        guard let url = URLInput.resolve(input) else { return }
        load(url)
    }

    enum PageExport { case pdf, webArchive, fullPageImage }

    /// writes the page into ~/Downloads (the one folder the sandbox may write
    /// without a panel) under a non-clashing name, then shows it in Finder
    @MainActor
    func export(_ kind: PageExport) async {
        guard url != nil, pendingURL == nil else { return }
        let data: Data?
        let ext: String
        switch kind {
        case .pdf:
            data = try? await webView.pdf(configuration: WKPDFConfiguration())
            ext = "pdf"
        case .webArchive:
            data = await withCheckedContinuation { done in
                webView.createWebArchiveData { done.resume(returning: try? $0.get()) }
            }
            ext = "webarchive"
        case .fullPageImage:
            data = await fullPageSnapshot()?.tiffRepresentation
                .flatMap(NSBitmapImageRep.init(data:))?.representation(using: .png, properties: [:])
            ext = "png"
        }
        guard let data else { return }
        let cleaned = displayTitle.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-").trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        let name = cleaned.isEmpty ? "Page" : String(cleaned.prefix(120))
        let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        var file = folder.appendingPathComponent("\(name).\(ext)")
        var counter = 2
        while FileManager.default.fileExists(atPath: file.path) {
            file = folder.appendingPathComponent("\(name) (\(counter)).\(ext)")
            counter += 1
        }
        guard (try? data.write(to: file)) != nil else { return }
        NSWorkspace.shared.activateFileViewerSelecting([file])
    }

    /// the whole document, not just the viewport, capped at 6000×24000pt and 1600px wide
    @MainActor
    private func fullPageSnapshot() async -> NSImage? {
        let size = try? await webView.evaluateJavaScript("""
            [Math.max(document.documentElement.scrollWidth, document.body?.scrollWidth ?? 0, innerWidth),
             Math.max(document.documentElement.scrollHeight, document.body?.scrollHeight ?? 0, innerHeight)]
            """) as? [Double]
        guard let size, size.count == 2 else { return nil }
        let config = WKSnapshotConfiguration()
        config.rect = CGRect(x: 0, y: 0, width: min(size[0], 6000), height: min(size[1], 24000))
        config.snapshotWidth = NSNumber(value: min(size[0], 1600))
        config.afterScreenUpdates = true
        return try? await webView.takeSnapshot(configuration: config)
    }

    /// the page's address without tracking parameters, optionally as `[title](url)`
    @MainActor
    func copyLink(asMarkdown: Bool = false) {
        guard let url = url ?? pendingURL else { return }
        let clean = URLInput.withoutTrackingParameters(url).absoluteString
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(asMarkdown ? "[\(displayTitle)](\(clean))" : clean, forType: .string)
    }

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
    func reload() { webView.reload() }

    /// asks the page's `beforeunload` first. true: nothing to ask, close now.
    /// false: WebKit shows the leave prompt and calls `webViewDidClose` if confirmed
    func tryClose() -> Bool {
        let selector = Selector(("_tryClose"))
        guard pendingURL == nil, webView.responds(to: selector) else { return true }
        typealias TryClose = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(webView.method(for: selector), to: TryClose.self)(webView, selector)
    }
    /// ⌘⌥R, Safari's spelling of a hard refresh: fetch the page and everything
    /// it pulls in again, ignoring the caches
    func reloadFromOrigin() { webView.reloadFromOrigin() }
    func stopLoading() {
        stopRequested = true
        webView.stopLoading()
    }

    // MARK: - Picture in Picture
    //
    // native macOS PiP via WKWebView SPI (see `WKWebViewPiPSPI`). the JS API
    // (`webkitSetPresentationMode`) is a silent no-op off Safari; `_togglePictureInPicture`
    // is the real trigger. needs the `com.apple.PIPAgent` mach-lookup entitlement to
    // reach the PiP window service under the App Sandbox (see Artemis.entitlements).

    /// the SPI view, or nil if this WebKit build doesn't expose PiP (graceful guard)
    private var pipSPI: WKWebViewPiPSPI? {
        webView.responds(to: Selector(("_togglePictureInPicture")))
            ? unsafeBitCast(webView, to: WKWebViewPiPSPI.self) : nil
    }

    /// whether a video can be popped into PiP right now. refreshes the controls
    /// manager first so the answer is live (it's stale/false until then)
    var canTogglePictureInPicture: Bool {
        guard let pip = pipSPI else { return false }
        pip._updateMediaPlaybackControlsManager()
        return pip._canTogglePictureInPicture
    }

    /// whether this tab currently has a PiP window open
    var isPictureInPictureActive: Bool { pipSPI?._isPictureInPictureActive ?? false }

    /// true while the tab is actively producing audio — a synchronous proxy for
    /// "a video is really playing here". used by the mini-player's auto-pop path;
    /// only reads media state, never enters native PiP.
    var isPlayingMedia: Bool { pipSPI?._isPlayingAudio ?? false }

    /// pop the tab's video into a floating window (⌘⇧P / menu). prefers real
    /// detached PiP; if WebKit won't actually enter it (some WKWebView builds accept
    /// the call but never open the window), falls back to the macOS 26 Viewer (an
    /// in-window floating video that itself becomes PiP when the tab is hidden).
    /// exits whichever is already up.
    func togglePictureInPicture() {
        guard let pip = pipSPI else { return }
        pip._updateMediaPlaybackControlsManager()  // create the AVKit manager (macOS gate)
        if pip._isPictureInPictureActive { pip._togglePictureInPicture(); return }
        if pip._isInWindowActive { pip._toggleInWindow(); return }
        if pip._canTogglePictureInPicture {
            pip._togglePictureInPicture()
            // if real PiP didn't take, use the Viewer instead
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if !pip._isPictureInPictureActive, pip._canToggleInWindow {
                    pip._toggleInWindow()
                }
            }
        } else if pip._canToggleInWindow {
            pip._toggleInWindow()
        }
    }

    /// pop the tab's playing video out, but only if it isn't already out — the
    /// auto-on-switch-away path (tab switch or leaving the app). only fires for
    /// genuinely playing media: a paused video is left alone (a muted-but-playing
    /// video produces no audio, so it's also skipped — auto-PiP is for things you're
    /// actually listening to; ⌘⇧P still works on anything).
    func enterPictureInPictureIfPlaying() {
        guard let pip = pipSPI, pip._isPlayingAudio else { return }
        pip._updateMediaPlaybackControlsManager()
        guard pip._canTogglePictureInPicture, !pip._isPictureInPictureActive else { return }
        pip._togglePictureInPicture()
    }

    /// close this tab's PiP if it has one — when you switch back, the floating
    /// window follows the *other* tab (Arc's Mini Player feel)
    func exitPictureInPictureIfActive() {
        guard let pip = pipSPI, pip._isPictureInPictureActive else { return }
        pip._togglePictureInPicture()
    }

    // MARK: - Web Inspector
    //
    // in-app devtools via the `_inspector` SPI (see `WKInspectorSPI`). the public
    // `isInspectable` flag (set in `configureWebView`) only opens the door for
    // Safari to attach remotely; this is what shows the inspector docked in our
    // own window. graceful guard — a WebKit build without it just no-ops.

    /// the `_WKInspector` controller for this tab, or nil if the SPI is absent
    private var inspectorSPI: WKInspectorSPI? {
        guard webView.responds(to: Selector(("_inspector"))) else { return nil }
        guard let inspector = unsafeBitCast(webView, to: WKWebViewInspectorSPI.self)._inspector
        else { return nil }
        return unsafeBitCast(inspector, to: WKInspectorSPI.self)
    }

    /// whether this tab's Web Inspector is currently open. note: `show` connects the
    /// frontend asynchronously, so this only flips true a beat after `toggleInspector`
    var isInspectorVisible: Bool { inspectorSPI?.isVisible ?? false }

    /// ⌥⌘I / menu: open this tab's Web Inspector, or close it if already up
    func toggleInspector() {
        guard let inspector = inspectorSPI else { return }
        if inspector.isVisible {
            inspector.close()
        } else {
            inspector.show()
            // present in a dedicated window WebKit owns end-to-end. the *attached*
            // (docked) inspector never paints here — the inspected view sits inside
            // our custom rounded card, which WebKit can't carve a dock out of. detach
            // is a no-op once it's already in its own window.
            inspector.detach()
        }
    }

    // MARK: - State mirroring

    private func observeWebView() {
        observations = [
            webView.observe(\.title, options: [.initial, .new]) { [weak self] webView, _ in
                guard let self else { return }
                if let title = webView.title, !title.isEmpty {
                    self.title = title
                    // the page's real title, which is *not* reliably available at
                    // `didFinish` — a single-page app typically sets it from
                    // script afterwards. Anything that wants to react to what a
                    // page is called has to listen here, not there.
                    if let url = webView.url { self.onDidSettleTitle?(url, title) }
                } else {
                    self.title = webView.url?.host() ?? "New Tab"
                }
                ExtensionManager.shared.tabDidChange(.title, for: self)
            },
            webView.observe(\.url, options: [.initial, .new]) { [weak self] webView, _ in
                guard let self else { return }
                self.url = webView.url
                if let url = webView.url {
                    self.addressText = url.absoluteString
                }
                self.hasUnsavedState = true
                ExtensionManager.shared.tabDidChange(.URL, for: self)
            },
            webView.observe(\.isLoading, options: [.initial, .new]) { [weak self] webView, _ in
                guard let self else { return }
                let loading = webView.isLoading
                if self.isLoading && !loading && !self.stopRequested {
                    // finished: let the bar animate to the end before hiding
                    self.isFinishingLoad = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                        guard let self, !self.webView.isLoading else { return }
                        self.isFinishingLoad = false
                    }
                } else if loading {
                    self.isFinishingLoad = false
                }
                if loading != self.isLoading { self.stopRequested = false }
                if loading { self.progress = webView.estimatedProgress }
                self.isLoading = loading
                self.hasUnsavedState = true
                ExtensionManager.shared.tabDidChange(.loading, for: self)
            },
            webView.observe(\.estimatedProgress, options: [.initial, .new]) { [weak self] webView, _ in
                // a stop reports 1.0 before it reports the load over
                guard let self, !self.stopRequested else { return }
                self.progress = webView.estimatedProgress
            },
            webView.observe(\.canGoBack, options: [.initial, .new]) { [weak self] webView, _ in
                self?.canGoBack = webView.canGoBack
            },
            webView.observe(\.canGoForward, options: [.initial, .new]) { [weak self] webView, _ in
                self?.canGoForward = webView.canGoForward
            },
            webView.observe(\.themeColor, options: [.initial, .new]) { [weak self] webView, _ in
                self?.themeColor = webView.themeColor
            },
            webView.observe(\.cameraCaptureState, options: [.initial, .new]) { [weak self] webView, _ in
                self?.cameraCapture = webView.cameraCaptureState
            },
            webView.observe(\.microphoneCaptureState, options: [.initial, .new]) { [weak self] webView, _ in
                self?.microphoneCapture = webView.microphoneCaptureState
            },
        ]
    }
}

// MARK: - WKNavigationDelegate

extension BrowserTab: WKNavigationDelegate {
    /// answer proxy authentication natively when a VPN extension's compat
    /// bridge holds credentials — otherwise WebKit surfaces macOS's own
    /// "Proxy Authentication Required" dialog for every 407. non-proxy
    /// challenges keep their default handling untouched
    func webView(
        _ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let space = challenge.protectionSpace
        if space.isProxy() || space.authenticationMethod == "NSURLAuthenticationMethodHTTPProxy" {
            if let credential = ExtensionProxyBridge.shared.proxyURLCredential(in: ProfileStore.proxyProfile(of: dataStore)) {
                completionHandler(.useCredential, credential)
                return
            }
            // a proxy WE set, whose credentials haven't arrived yet: fail the
            // request rather than handing the user a system password dialog
            // for a server they never chose. The extension's credentials land
            // moments later and the tabs reload.
            if ExtensionProxyBridge.shared.activeProxy(in: ProfileStore.proxyProfile(of: dataStore)) != nil {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
        }
        // keep the certificate this host presented: the load may be about to fail,
        // and the failure carries no trust with it, so this is the only chance to
        // capture what the user will be asked about
        if space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
            let trust = space.serverTrust
        {
            let host = space.host
            CertificateTrust.remember(trust, for: host)
            if CertificateTrust.applyException(to: trust, host: host) {
                completionHandler(.useCredential, URLCredential(trust: trust))
                return
            }
        }
        // a server asking who you are. Without this the challenge falls through
        // to default handling, which answers it with nothing — so every router
        // page, staging box and internal tool behind basic auth is a dead end
        switch space.authenticationMethod {
        case NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest,
            NSURLAuthenticationMethodNTLM:
            askForCredentials(space, completionHandler)
        default:
            completionHandler(.performDefaultHandling, nil)
        }
    }

    /// Put the server's login to the user. Credentials live for this session only.
    @MainActor
    private func askForCredentials(
        _ space: URLProtectionSpace,
        _ completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard pendingDialog == nil else {
            return completionHandler(.cancelAuthenticationChallenge, nil)
        }
        pendingDialog = PageDialogRequest(
            kind: .httpAuth(realm: space.realm?.isEmpty == false ? space.realm : nil),
            message: "", host: space.host
        ) { [weak self] answer in
            self?.pendingDialog = nil
            guard answer.confirmed, !answer.text.isEmpty else {
                return completionHandler(.cancelAuthenticationChallenge, nil)
            }
            completionHandler(
                .useCredential,
                URLCredential(
                    user: answer.text, password: answer.secondary, persistence: .forSession))
        }
    }

    /// every content-rule-list result WebKit produces, per subresource: the only
    /// place a block becomes visible to the app. the action object is WebKit SPI,
    /// so its flags are read by key rather than by type
    @objc(_webView:contentRuleListWithIdentifier:performedAction:forURL:)
    func webView(
        _ webView: WKWebView, contentRuleListWithIdentifier identifier: String,
        performedAction action: NSObject, for url: URL
    ) {
        guard (action.value(forKey: "blockedLoad") as? Bool) == true else { return }
        recordBlockedRequest(url, list: identifier)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        debugLog("didStartProvisionalNavigation url=\(webView.url?.absoluteString ?? "nil")")
        blockedRequests.removeAll()
        // the old page's frames are gone; anything they were playing has stopped
        resetMediaState()
        // a new document gets a fresh dialog budget — silencing is per page, not
        // per tab, or one bad page would mute the site you navigate to next. It
        // resets here rather than at `didCommit` because a commit is delivered on
        // its own IPC and can arrive *after* the new document's first `alert()`,
        // which would zero the count between two dialogs of the same page
        suppressesDialogs = false
        dialogsThisPage = 0
        canOverrideCertificate = false
        WebNotifications.shared.forgetPage(in: id)
        // navigating anywhere leaves the reader — including clicking a link inside
        // it, which should land on the real page. the reader's own load is exempt
        // (it shares the page's url, so only this flag can tell them apart)
        if isLoadingReaderDocument {
            isLoadingReaderDocument = false
        } else if isReaderMode {
            isReaderMode = false
            preReaderURL = nil
        }
    }

    /// the new page's document has started rendering — adopt that site's stored
    /// zoom now, before it paints, so following a link never flashes at 100% first
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        webView.setValue(true, forKey: "drawsBackground")
        webView.underPageBackgroundColor = nil
        syncZoomToSite()
        endPageTranslation()
        PasswordAutofill.shared.pageDidCommit(in: self)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        debugLog("didFinish url=\(webView.url?.absoluteString ?? "nil")")
        loadError = nil
        fetchFavicon()
        probeReaderAvailability()
        PasswordAutofill.shared.pageDidFinish(in: self)
        // apply any per-site Boosts (custom CSS/JS) for this page
        BoostStore.shared.inject(into: webView, url: webView.url)
        if let url = webView.url, url.scheme == "http" || url.scheme == "https" {
            onDidNavigate?(url, webView.title?.isEmpty == false ? webView.title! : (url.host() ?? url.absoluteString))
            // match Safari: once a page loads, move keyboard focus into the
            // content so it reports `document.hasFocus() == true`. focus-gated web
            // players (Prime Video) otherwise abort their content load. only for
            // the visible tab, and never while the user is typing in the URL bar
            // (a field editor holds first responder then).
            if manager?.selectedTab === self, let window = webView.window,
                window.isKeyWindow, !(window.firstResponder is NSText) {
                window.makeFirstResponder(webView)
            }
        }
    }

    // MARK: Failures

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        handleLoadError(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleLoadError(error)
    }

    /// a page on screen reloads at once; one off screen reloads when next shown.
    /// a second crash within 10s stops the loop at the error page
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        debugLog("web content process terminated: \(url?.absoluteString ?? "-")")
        Diagnostics.record(area: "webcontent", message: "web content process ended", inPrivate: isPrivate)
        abandonDialog()
        resetMediaState()
        let now = Date()
        defer { lastCrash = now }
        if let lastCrash, now.timeIntervalSince(lastCrash) < 10 {
            lastAttemptedURL = url ?? lastAttemptedURL
            loadError = "This page stopped responding and was closed to protect your Mac."
            return
        }
        if BrowserWindows.shared.allManagers.contains(where: { $0.onScreenTabIDs.contains(id) }) {
            webView.reload()
        } else {
            needsReloadAfterCrash = true
        }
    }

    private func handleLoadError(_ error: Error) {
        let nsError = error as NSError
        debugLog("navigation error: \(nsError.domain) \(nsError.code) \(nsError.localizedDescription)")
        // cancellation isn't failure (user navigated away, or a download took over)
        guard nsError.code != NSURLErrorCancelled else { return }
        // "frame load interrupted": normal when a navigation becomes a download
        guard !(nsError.domain == "WebKitErrorDomain" && nsError.code == 102) else { return }
        // "plug-in handled load" (204): a raw media file (e.g. a direct .mp4) the
        // engine renders in its built-in media viewer — the page DID load, not failed
        guard !(nsError.domain == "WebKitErrorDomain" && nsError.code == 204) else { return }
        loadError = nsError.localizedDescription
        // a certificate the system refuses is the one failure the user can
        // knowingly overrule, and the error page needs to know to offer it
        canOverrideCertificate = CertificateTrust.isOverridable(nsError)
        if let host = lastAttemptedURL?.host() {
            title = host
        }
    }

    /// Accept the certificate this host most recently presented, then reload.
    /// Scoped to that one certificate by `SecTrustCopyExceptions`, so the host
    /// presenting a different one later asks again.
    @MainActor
    func acceptCertificateAndRetry() {
        guard let host = lastAttemptedURL?.host(),
            CertificateTrust.addException(for: host)
        else { return }
        canOverrideCertificate = false
        retry()
    }

    // MARK: Downloads

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        preferences: WKWebpagePreferences
    ) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        // a link that asks to be downloaded is, whatever is held
        if navigationAction.shouldPerformDownload {
            return (.download, preferences)
        }
        if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
            // WebKit reports the button as a mask bit: 1 << 2 is the middle one
            let middle = navigationAction.buttonNumber == 1 << 2
            if let click = LinkClick.route(navigationAction.modifierFlags, middle: middle) {
                onOpenLink?(url, click)
                return (.cancel, preferences)
            }
            // linked split pane: a plain link click loads in the paired pane instead
            // of navigating this one
            if manager?.routeLinkedNavigation(from: self, to: url) == true {
                return (.cancel, preferences)
            }
        }
        // a scheme WebKit doesn't render belongs to another app. Cancelling
        // without offering it is how `mailto:` and every `zoommtg:` link on the
        // web silently did nothing
        if let url = navigationAction.request.url, !ExternalSchemes.isInternal(url.scheme) {
            // only the page you are looking at gets to ask. An existing subframe
            // navigating itself to an app scheme is the drive-by case and is
            // cancelled without a word; a nil target frame is a new window, which
            // is what `target=_blank` on a mailto: link is
            let fromMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
            if fromMainFrame, ExternalSchemes.canOffer(url) { offerExternal(url) }
            return (.cancel, preferences)
        }
        // set here, the UA already reaches this navigation's own request
        if navigationAction.targetFrame?.isMainFrame == true, let url = navigationAction.request.url,
            url.scheme == "https" || url.scheme == "http"
        {
            let wanted =
                ChromeDisguise.isOn(for: url.host(), ephemeral: isPrivate) ? ChromeDisguise.userAgent : ""
            if (webView.customUserAgent ?? "") != wanted { webView.customUserAgent = wanted }
        }
        return (.allow, preferences)
    }

    /// anything the engine can't render inline becomes a download
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse
    ) async -> WKNavigationResponsePolicy {
        debugLog(
            "navigationResponse url=\(navigationResponse.response.url?.absoluteString ?? "nil") "
                + "mime=\(navigationResponse.response.mimeType ?? "nil") "
                + "canShow=\(navigationResponse.canShowMIMEType)")

        // servers marking a response as an attachment want a download,
        // even when the mime type is displayable (images, pdfs, …)
        if let http = navigationResponse.response as? HTTPURLResponse,
            let disposition = http.value(forHTTPHeaderField: "Content-Disposition"),
            disposition.lowercased().contains("attachment")
        {
            return .download
        }

        return navigationResponse.canShowMIMEType ? .allow : .download
    }

    func webView(
        _ webView: WKWebView,
        navigationAction: WKNavigationAction,
        didBecome download: WKDownload
    ) {
        debugLog("navigationAction didBecome download")
        DownloadManager.shared.register(
            download, sourceTitle: title, sourceHost: url?.host() ?? "")
    }

    func webView(
        _ webView: WKWebView,
        navigationResponse: WKNavigationResponse,
        didBecome download: WKDownload
    ) {
        debugLog("navigationResponse didBecome download")
        DownloadManager.shared.register(
            download, sourceTitle: title, sourceHost: url?.host() ?? "")
    }

    /// hand the page's declared icon to the shared store, which fetches and caches it by host
    private func fetchFavicon() {
        let script = #"document.querySelector('link[rel~="icon"]')?.href || ''"#
        webView.evaluateJavaScript(script) { [weak self] result, _ in
            guard let self else { return }
            let host = self.webView.url?.host() ?? self.faviconHost
            var declared: URL?
            if let href = result as? String, !href.isEmpty {
                declared = URL(string: href, relativeTo: self.webView.url)
            }
            FaviconStore.shared.update(
                host: host, declaredIconURL: declared, isPrivate: self.isPrivate)
        }
    }
}

// MARK: - WKUIDelegate

extension BrowserTab: WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        onRequestNewTab?(configuration, windowFeatures)
    }

    /// `window.close()`. Without this a sign-in popup that closes itself when it
    /// is done just sits there, and the flow looks stuck
    func webViewDidClose(_ webView: WKWebView) {
        if let confirmed = onConfirmedClose {
            onConfirmedClose = nil
            confirmed()
        } else {
            onRequestClose?()
        }
    }

    /// `<input type=file>` was clicked.
    ///
    /// Without this method WebKit's `runOpenPanel` returns false and the click
    /// does nothing at all — no panel, no error, no console message. The picker
    /// itself grants the sandbox access: WebKit issues the read-only sandbox
    /// extensions for whatever comes back, so no extra entitlement is involved.
    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping ([URL]?) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        panel.canCreateDirectories = false
        panel.message = frame.request.url?.host().map { "Choose a file to upload to \($0)." }
        let types = Self.acceptedTypes(parameters)
        if !types.isEmpty {
            panel.allowedContentTypes = types
            // `accept` is a hint, not a rule — a site that asks for images still
            // has to cope with whatever the user actually picks
            panel.allowsOtherFileTypes = true
        }
        // exactly once, on every path: WebKit traps on a second call and leaks
        // the input's pending state on none
        var answered = false
        let answer = { (urls: [URL]?) in
            guard !answered else { return }
            answered = true
            completionHandler(urls)
        }
        let finish = { (response: NSApplication.ModalResponse) in
            answer(response == .OK ? panel.urls : nil)
        }
        if let window = webView.window {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(panel.runModal())
        }
    }

    /// map the input's `accept` list onto `UTType`s for the picker
    private static func acceptedTypes(_ parameters: WKOpenPanelParameters) -> [UTType] {
        let spi = unsafeBitCast(parameters, to: WKOpenPanelParametersSPI.self)
        var types: [UTType] = []
        if parameters.responds(to: Selector(("_acceptedMIMETypes"))) {
            types += spi._acceptedMIMETypes.compactMap { UTType(mimeType: $0) }
        }
        if parameters.responds(to: Selector(("_acceptedFileExtensions"))) {
            types += spi._acceptedFileExtensions.compactMap {
                UTType(filenameExtension: $0.hasPrefix(".") ? String($0.dropFirst()) : $0)
            }
        }
        return types
    }

    func webView(
        _ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void
    ) {
        askPage(.alert, message: message, frame: frame) { _ in completionHandler() }
    }

    func webView(
        _ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void
    ) {
        askPage(.confirm, message: message, frame: frame) { completionHandler($0.confirmed) }
    }

    func webView(
        _ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?, initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (String?) -> Void
    ) {
        askPage(.prompt(defaultText: defaultText ?? ""), message: prompt, frame: frame) { answer in
            completionHandler(answer.confirmed ? answer.text : nil)
        }
    }

    /// "Leave site? Changes you made may not be saved."
    ///
    /// SPI — there is no public delegate for `beforeunload`, and WebKit reads a
    /// delegate that doesn't answer this selector as "nobody is listening" and
    /// unloads without asking, which is how an unsaved draft disappears.
    @objc(_webView:runBeforeUnloadConfirmPanelWithMessage:initiatedByFrame:completionHandler:)
    func _webView(
        _ webView: WKWebView, runBeforeUnloadConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void
    ) {
        if onConfirmedClose != nil { manager?.focus(self) }
        askPage(.leaveConfirm, message: message, frame: frame) { [weak self] answer in
            if !answer.confirmed { self?.onConfirmedClose = nil }
            completionHandler(answer.confirmed)
        }
    }

    /// Put a page's question on screen, or refuse it on the page's behalf.
    ///
    /// Refused when the page has been silenced, and when one of its dialogs is
    /// already up: JS blocks inside `alert()`, so a second question can only come
    /// from another frame, and letting frames queue is how a page holds a browser.
    @MainActor
    private func askPage(
        _ kind: PageDialogRequest.Kind, message: String, frame: WKFrameInfo,
        respond: @escaping (PageDialogRequest.Answer) -> Void
    ) {
        guard !suppressesDialogs, pendingDialog == nil else {
            // a refused `beforeunload` means the navigation goes ahead
            return respond(.init(confirmed: kind == .leaveConfirm))
        }
        dialogsThisPage += 1
        pendingDialog = PageDialogRequest(
            kind: kind, message: message,
            host: frame.securityOrigin.host,
            // a page that keeps asking earns a way to be silenced; leaving a page
            // is a one-off the user asked for, so it never offers one
            checkbox: dialogsThisPage > 1 && kind != .leaveConfirm ? .silencePage : nil
        ) { [weak self] answer in
            self?.pendingDialog = nil
            respond(answer)
        }
    }

    /// A link in a scheme WebKit can't render — hand it to the app that claims
    /// it, once the user has said so for this site.
    @MainActor
    private func offerExternal(_ url: URL) {
        let scheme = url.scheme?.lowercased() ?? ""
        let site = (self.url ?? lastAttemptedURL)?.host() ?? ""
        guard !ExternalSchemes.isAllowed(site: site, scheme: scheme) else {
            ExternalSchemes.open(url)
            return
        }
        guard pendingDialog == nil else { return }
        let appName = ExternalSchemes.handlerName(for: url)
        pendingDialog = PageDialogRequest(
            kind: .openExternal(scheme: scheme, appName: appName), message: "",
            host: site,
            // nothing is offered to remember when nothing would open
            checkbox: appName == nil ? nil : .rememberChoice
        ) { [weak self] answer in
            self?.pendingDialog = nil
            guard answer.confirmed else { return }
            ExternalSchemes.open(url)
        }
    }

    /// answer from the panel. `silence` is the "stop showing these" checkbox
    @MainActor
    func answerDialog(
        _ confirmed: Bool, text: String = "", secondary: String = "", checked: Bool = false
    ) {
        guard let dialog = pendingDialog else { return }
        switch (dialog.checkbox, checked) {
        case (.silencePage, true): suppressesDialogs = true
        case (.rememberChoice, true):
            if case .openExternal(let scheme, _) = dialog.kind, confirmed {
                ExternalSchemes.allow(site: dialog.host, scheme: scheme)
            }
        default: break
        }
        pendingDialog = nil
        dialog.answer(confirmed, text: text, secondary: secondary)
    }

    /// the tab or its page is going away with a question still up
    @MainActor
    func abandonDialog() {
        pendingDialog?.abandon()
        pendingDialog = nil
    }

    /// A page wants the camera or the microphone.
    ///
    /// Not implementing this method is not neutral: WebKit reads a missing
    /// handler as a refusal, which is why `getUserMedia` used to fail on every
    /// site in Artemis and video calls simply didn't work. The answer is a
    /// per-site decision the user makes and the app remembers.
    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        let wanted: [SitePermission] =
            switch type {
            case .camera: [.camera]
            case .microphone: [.microphone]
            case .cameraAndMicrophone: [.camera, .microphone]
            @unknown default: [.camera, .microphone]
            }
        decide(wanted, origin: origin, decisionHandler: decisionHandler)
    }

    /// A page wants to know where you are. Same story as capture: no handler
    /// means WebKit refuses, so "find me" on a map never worked.
    func webView(
        _ webView: WKWebView,
        requestGeolocationPermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        decide([.location], origin: origin, decisionHandler: decisionHandler)
    }

    private func decide(
        _ permissions: [SitePermission], origin: WKSecurityOrigin,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        guard let manager else { return decisionHandler(.deny) }
        manager.requestPermission(
            permissions, origin: SitePermissionStore.originString(origin), tab: self
        ) { decision in
            decisionHandler(decision == .allow ? .grant : .deny)
        }
    }
}

// MARK: - WKWebExtensionTab

/// presents the tab to the WebExtensions runtime so `chrome.tabs` and content
/// scripts work. all protocol methods are optional; we implement the ones that
/// map cleanly onto existing tab plumbing and let WebKit fall back for the rest.
extension BrowserTab: WKWebExtensionTab {
    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        ExtensionManager.shared.browserWindow
    }

    func indexInWindow(for context: WKWebExtensionContext) -> Int {
        guard let manager else { return 0 }
        return (manager.tabs + manager.essentials).firstIndex { $0.id == id } ?? 0
    }

    func webView(for context: WKWebExtensionContext) -> WKWebView? { webView }

    func url(for context: WKWebExtensionContext) -> URL? { url ?? lastAttemptedURL }

    func pendingURL(for context: WKWebExtensionContext) -> URL? { pendingURL }

    func title(for context: WKWebExtensionContext) -> String? { title }

    func isPinned(for context: WKWebExtensionContext) -> Bool { isPinned }

    func isSelected(for context: WKWebExtensionContext) -> Bool {
        manager?.selectedTab?.id == id
    }

    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { !isLoading }

    @MainActor
    func activate(for context: WKWebExtensionContext) async throws {
        manager?.selectedTabID = id
    }

    @MainActor
    func setSelected(_ selected: Bool, for context: WKWebExtensionContext) async throws {
        if selected { manager?.selectedTabID = id }
    }

    @MainActor
    func setPinned(_ pinned: Bool, for context: WKWebExtensionContext) async throws {
        guard isPinned != pinned, let manager else { return }
        manager.togglePin(self)
    }

    @MainActor
    func loadURL(_ url: URL, for context: WKWebExtensionContext) async throws {
        load(url)
    }

    @MainActor
    func reload(fromOrigin: Bool, for context: WKWebExtensionContext) async throws {
        fromOrigin ? webView.reloadFromOrigin() : webView.reload()
    }

    @MainActor
    func goBack(for context: WKWebExtensionContext) async throws { webView.goBack() }

    @MainActor
    func goForward(for context: WKWebExtensionContext) async throws { webView.goForward() }

    @MainActor
    func close(for context: WKWebExtensionContext) async throws {
        manager?.close(self)
    }
}
