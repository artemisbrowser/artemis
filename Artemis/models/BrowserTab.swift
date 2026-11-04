import AppKit
import SwiftUI
import Translation
import UniformTypeIdentifiers
import WebKit

/// the `accept` attribute of the file input that opened the panel, which public
/// `WKOpenPanelParameters` lacks; guarded by `responds(to:)`
@objc private protocol WKOpenPanelParametersSPI {
    var _acceptedMIMETypes: [String] { get }
    var _acceptedFileExtensions: [String] { get }
}

/// private WKWebView media SPI, reached via `unsafeBitCast` and guarded by `responds(to:)`
@objc private protocol WKWebViewMediaSPI {
    var _isPlayingAudio: Bool { get }
    /// mute the whole page, Web Audio included (`_WKMediaMutedState`: bit 0 is audio)
    func _setPageMuted(_ state: UInt)
}

/// private WKPreferences SPI: off keeps WebKit's own PiP out of pages, so only the mini-player floats video.
/// called via `unsafeBitCast`; KVC can't reach an underscored setter
@objc private protocol WKPreferencesPiPSPI {
    func _setAllowsPictureInPictureMediaPlayback(_ enabled: Bool)
}

/// private WKPreferences SPI: `navigator.mediaDevices` is undefined unless these
/// are on. capture still goes through the permission delegate
@objc private protocol WKPreferencesMediaDevicesSPI {
    func _setMediaDevicesEnabled(_ enabled: Bool)
    func _setMediaStreamEnabled(_ enabled: Bool)
}

/// private WKWebView SPI for the in-app Web Inspector, via `unsafeBitCast` and
/// guarded by `responds(to:)`
@objc private protocol WKWebViewInspectorSPI {
    var _inspector: AnyObject? { get }
}

/// `_WKInspector`, the inspector controller
@objc private protocol WKInspectorSPI {
    func show()
    func close()
    func detach()
    var isVisible: Bool { get }
}

/// a browser tab: owns its `WKWebView` and mirrors the page's state into
/// observable properties
@Observable
final class BrowserTab: NSObject, Identifiable {
    /// stable across relaunches via `TabRecord`; per-tab state on disk is keyed by it
    let id: UUID

    private(set) var title = "New Tab"

    /// the sidebar's title: the user's name for the tab, else the model's short
    /// name for the page title, else the page title. see `TabNameStore`
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
    static let crashLoopError = "Artemis stopped reloading it after it crashed twice in a minute."
    private(set) var canGoBack = false
    private(set) var canGoForward = false

    /// the page's `<meta name="theme-color">`, if any
    private(set) var themeColor: NSColor?

    /// the page's theme-color, else the favicon's accent; nil when neither is known
    var pageTint: Color? {
        if let themeColor { return Color(nsColor: themeColor) }
        return faviconAccent
    }

    /// the host whose favicon represents this tab
    private var faviconHost: String? { (url ?? lastAttemptedURL ?? pendingURL)?.host() }

    /// from the persistent per-host store, so it shows before a restored tab loads
    var favicon: NSImage? { FaviconStore.shared.icon(for: faviconHost) }

    /// a vivid colour sampled from the favicon; nil until the icon resolves
    var faviconAccent: Color? { FaviconStore.shared.accent(for: faviconHost) }

    /// pinned tabs live in their own sidebar section and persist across launches
    var isPinned = false

    /// a favourite: shown in the grid shared by every space
    var isEssential = false

    /// the url a pinned tab is anchored to; when the tab navigates away from it
    /// the row reads as "off" its pinned page. nil for unpinned tabs
    var pinnedURL: URL?

    /// the connected coding agent that has driven this tab; nil once it disconnects
    var agentName: String?

    /// set through `navigator.setAppBadge`, and dropped once the tab leaves `appBadgeOrigin`
    private(set) var appBadge: AppBadge?
    @ObservationIgnored private var appBadgeOrigin: String?

    func setAppBadge(_ badge: AppBadge?, origin: String) {
        appBadge = badge
        appBadgeOrigin = origin
    }

    /// the sidebar's unread mark: the page's app badge, else a leading "(n)" in its title
    var unread: AppBadge? {
        appBadge ?? TabManager.unreadCount(in: title).map(AppBadge.count)
    }

    /// `displayTitle` beside an unread badge, without the "(n)" the badge already shows
    var badgedTitle: String {
        unread == nil ? displayTitle : TabManager.normalisedTitle(displayTitle)
    }

    /// the url an unloaded tab (restored, asleep, or closed to its pin) loads when next selected
    private(set) var pendingURL: URL?

    /// when the tab was last viewed or navigated; persisted, and drives auto-archive
    var lastAccessed = Date()

    /// live text in the url field; user edits happen here until submit,
    /// and committed navigations write the new url back into it
    var addressText = ""

    /// the page asked for a new window; must synchronously return a web view built
    /// from the given configuration, or nil to refuse
    @ObservationIgnored var onRequestNewTab:
        ((WKWebViewConfiguration, WKWindowFeatures) -> WKWebView?)?

    /// the page called `window.close()` on itself
    @ObservationIgnored var onRequestClose: (() -> Void)?

    /// the close the user asked for, run once the page's `beforeunload` lets it go
    @ObservationIgnored var onConfirmedClose: (() -> Void)?

    /// a link clicked with modifiers held (or force clicked), to open elsewhere
    @ObservationIgnored var onOpenLink: ((URL, LinkClick) -> Void)?

    /// a page finished loading
    @ObservationIgnored var onDidNavigate: ((URL, String) -> Void)?

    /// the page settled on a real title, possibly well after it finished loading
    @ObservationIgnored var onDidSettleTitle: ((URL, String) -> Void)?

    /// the owning model, set in `TabManager.wire`
    @ObservationIgnored weak var manager: TabManager?

    /// rebuilt (not mutated) when the tab changes profile — WebKit fixes a web
    /// view's data store at creation, so a new jar means a new web view
    @ObservationIgnored private(set) var webView: WKWebView
    /// the cookie jar this tab's web view is bound to. `ProfileStore` caches one
    /// store per profile, so `===` tells a real profile move from a no-op
    @ObservationIgnored private(set) var dataStore: WKWebsiteDataStore
    /// bumps each time `webView` is rebuilt; the SwiftUI host's `.id`, so must stay observed
    private(set) var webViewGeneration = 0
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    /// the main-window slot hosting this tab's web view; re-set on every mount
    @ObservationIgnored weak var webHost: WebHostView?

    /// the page's last frame, for a second window showing the same tab: only one
    /// window can hold the live web view, and the other stands this in
    var stillFrame: NSImage?
    /// the mini-player owns the web view; the slot stays empty while this holds
    var isMiniPlayerActive = false

    // MARK: - JavaScript dialogs

    /// the `alert()` / `confirm()` / `prompt()` / leave-page question this page
    /// is blocked on
    private(set) var pendingDialog: PageDialogRequest?
    /// the user asked this page to stop putting up dialogs; cleared on navigation
    private var suppressesDialogs = false
    /// dialogs since the last commit — the second one earns a suppression offer
    private var dialogsThisPage = 0

    /// this load failed on a certificate the user could choose to accept
    private(set) var canOverrideCertificate = false

    // MARK: - Translation

    /// the selection in the system's on-device translation popover, or nil
    private(set) var pendingTranslation: String?

    /// translate the page's selection on this Mac
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
    /// set while a language pair has to be downloaded first; the web view's `.translationTask` offers it
    private(set) var pageTranslationRequest: TranslationSession.Configuration?
    @ObservationIgnored private var pageTranslator: PageTranslator?
    /// bumped whenever a page translation ends, so in-flight work for an older one stops
    @ObservationIgnored private var pageTranslationGeneration = 0

    /// the profile's rules; an incognito page obeys its window's and never writes them
    var translationRules: TranslationRules? { BrowserCore.shared.profile(loginProfile)?.translationRules }

    /// ⌥⌘T — translate the whole page on this machine, or put the original back
    func toggleTranslation() async {
        if pageTranslation.isActive {
            showOriginal()
        } else {
            await beginPageTranslation()
        }
    }

    func showOriginal() {
        pageTranslator?.stop(restoring: true)
        endPageTranslation()
    }

    /// translate again into `language`, which becomes the profile's choice unless this page is incognito
    func translatePage(to language: Locale.Language) async {
        if !isPrivate { translationRules?.setTarget(language) }
        showOriginal()
        await beginPageTranslation(to: language)
    }

    func setAlwaysTranslates(_ language: Locale.Language, _ on: Bool) {
        guard !isPrivate, let code = language.languageCode?.identifier else { return }
        translationRules?.setAlways(code, on)
    }

    func setNeverTranslatesSite(_ on: Bool) {
        guard !isPrivate, let site = ZoomStore.key(for: url) else { return }
        translationRules?.setNever(site, on)
    }

    /// runs inside the web view's `.translationTask` once `pageTranslationRequest` is set,
    /// and may show the system's download sheet
    func downloadLanguages(with session: TranslationSession) async {
        guard let request = pageTranslationRequest, let source = request.source, let target = request.target
        else { return }
        let generation = pageTranslationGeneration
        do {
            try await session.prepareTranslation()
        } catch {
            guard generation == pageTranslationGeneration, !Task.isCancelled else { return }
            return endPageTranslation(.failed(error.localizedDescription))
        }
        guard generation == pageTranslationGeneration else { return }
        pageTranslationRequest = nil
        startTranslator(from: source, to: target)
    }

    /// a page load translates itself only under an always-rule the person made
    private func translateIfRuled() async {
        guard !pageTranslation.isActive, let rules = translationRules, !rules.languages.isEmpty,
            !rules.neverTranslates(url)
        else { return }
        await beginPageTranslation(automatic: true)
    }

    /// `automatic` translates only what a rule covers, and says nothing when it doesn't
    private func beginPageTranslation(to chosen: Locale.Language? = nil, automatic: Bool = false) async {
        endPageTranslation(automatic ? .idle : .detecting)
        let generation = pageTranslationGeneration
        func fail(_ message: String) {
            if !automatic { endPageTranslation(.failed(message)) }
        }
        let sample = try? await webView.callAsyncJavaScript(
            PageTranslation.sample, contentWorld: PageTranslation.world) as? [String: Any]
        guard generation == pageTranslationGeneration else { return }
        let texts = sample?["texts"] as? [String] ?? []
        guard !texts.isEmpty else { return fail("There's no text on this page to translate.") }
        guard let source = PageTranslation.language(of: texts, declared: sample?["lang"] as? String) else {
            return fail("Couldn't tell what language this page is in.")
        }
        let rules = translationRules
        if automatic, rules?.translatesAutomatically(source, on: url) != true { return }
        let target = chosen ?? rules?.target ?? PageTranslation.systemTarget
        guard source.languageCode != target.languageCode else {
            return fail("This page is already in \(PageTranslation.name(of: target)).")
        }

        let status = await LanguageAvailability().status(from: source, to: target)
        guard generation == pageTranslationGeneration else { return }
        switch status {
        case .installed:
            startTranslator(from: source, to: target)
        case .supported where !automatic:
            pageTranslationRequest = TranslationSession.Configuration(source: source, target: target)
        default:
            fail("This Mac can't translate \(PageTranslation.name(of: source)) to \(PageTranslation.name(of: target)).")
        }
    }

    private func startTranslator(from source: Locale.Language, to target: Locale.Language) {
        let translator = PageTranslator(webView: webView, from: source, to: target)
        translator.report = { [weak self, weak translator] state in
            guard let self, let translator, pageTranslator === translator else { return }
            if case .failed = state { showOriginal() }
            pageTranslation = state
        }
        pageTranslator = translator
        pageTranslation = .translating(from: source, to: target, progress: 0)
        translator.start()
    }

    /// stops any translation; the page keeps whatever text it holds
    private func endPageTranslation(_ state: PageTranslation.State = .idle) {
        pageTranslationGeneration += 1
        pageTranslator?.stop(restoring: false)
        pageTranslator = nil
        pageTranslationRequest = nil
        pageTranslation = state
    }

    /// read by the suite, which asserts on when the suppression offer appears
    var dialogsRaisedThisPage: Int { dialogsThisPage }

    // MARK: - Media state

    /// frames playing media, keyed by frame url; fed by `MediaStateReporter`
    @ObservationIgnored private var playingFrames: Set<String> = []

    /// any frame is playing audio or video; unlike `_isPlayingAudio`, true while muted
    private(set) var isPlayingMediaContent = false

    /// engine-level mute for the tab; survives navigation
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

    /// push `isMuted` down to the engine
    private func applyMuteState() {
        guard webView.responds(to: Selector(("_setPageMuted:"))) else { return }
        unsafeBitCast(webView, to: WKWebViewMediaSPI.self)._setPageMuted(isMuted ? 1 : 0)
    }

    /// true while the tab is producing audio
    var isPlayingMedia: Bool {
        guard webView.responds(to: Selector(("_isPlayingAudio"))) else { return false }
        return unsafeBitCast(webView, to: WKWebViewMediaSPI.self)._isPlayingAudio
    }

    // MARK: - Passwords

    var loginOffer: LoginOffer?
    @ObservationIgnored var loginCandidate: LoginCandidate?
    /// where this document's login form is
    @ObservationIgnored var loginTarget: LoginTarget?
    /// the username a two-step sign-in entered on its first page
    @ObservationIgnored var loginUsernameHint: (origin: String, name: String, at: Date)?

    // MARK: - Autofill

    var autofillOffer: AutofillOffer?
    /// each frame's address and card fields, by `LoginKeys.key`
    @ObservationIgnored var autofillFrames: [AnyHashable: AutofillFrame] = [:]

    // MARK: - Zoom

    /// the page-zoom factor, seeded from `ZoomStore` for the site shown
    private(set) var zoomLevel: Double = ZoomStore.defaultZoom

    /// set the zoom for the site shown; `remember: false` applies a stored value
    @MainActor
    func setZoom(_ zoom: Double, remember: Bool = true) {
        let clamped = min(max(zoom, ZoomStore.steps.first!), ZoomStore.steps.last!)
        zoomLevel = clamped
        webView.pageZoom = clamped
        LoginKeys.on(webView)?.settle()
        // incognito writes nothing to disk
        if remember, !isPrivate {
            ZoomStore.shared.setZoom(clamped, for: url ?? lastAttemptedURL ?? pendingURL)
        }
    }

    /// an incognito page: its jar is non-persistent. every no-disk rule keys off this
    var isPrivate: Bool { !dataStore.isPersistent }

    /// the profile this page browses as; nil for an incognito page
    var profileID: Profile.ID? { ProfileStore.profileID(of: dataStore) }

    /// whose saved logins this page fills from. an incognito page reads its
    /// window's opener's, and never writes back
    var loginProfile: Profile.ID { profileID ?? manager?.currentProfile.id ?? Profile.defaultID }

    @MainActor func zoomIn() { setZoom(ZoomStore.step(from: zoomLevel, by: 1)) }
    @MainActor func zoomOut() { setZoom(ZoomStore.step(from: zoomLevel, by: -1)) }
    @MainActor func resetZoom() { setZoom(ZoomStore.defaultZoom) }

    /// adopt the stored zoom for the page now showing; runs on every commit
    @MainActor
    func syncZoomToSite() {
        let stored = ZoomStore.shared.zoom(for: url ?? lastAttemptedURL ?? pendingURL)
        guard abs(stored - zoomLevel) > 0.001 else { return }
        setZoom(stored, remember: false)
    }

    // MARK: - Reader

    /// true while this tab is showing the stripped-down reader instead of the page
    private(set) var isReaderMode = false
    /// the page looks like an article, by `probeReaderAvailability`
    private(set) var isReaderAvailable = false
    /// where to go back to when the reader is dismissed
    @ObservationIgnored private var preReaderURL: URL?
    /// set for the one navigation that loads the reader document, which shares
    /// the page's url and must not leave the reader
    @ObservationIgnored private var isLoadingReaderDocument = false

    /// a cheap "is there an article here" probe, on load and when a tab becomes
    /// visible, since a background tab skips it on load
    func probeReaderAvailability() {
        // `innerText` forces layout: only the displayed page. a script into a web
        // view with no page launches its web process on main
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

    /// ⌘P: the standard print panel over the page as rendered
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

        // swipe-to-navigate would take horizontal scrolling on wide pages
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsMagnification = true
        webView.isInspectable = true
        webView.uiDelegate = self
        webView.navigationDelegate = self
        // carries zoom and mute across a rebuild
        webView.pageZoom = zoomLevel
        applyMuteState()
        resetMediaState()
    }

    /// move the tab to another profile's jar: a fresh web view reloads the page,
    /// losing back/forward history and scroll. a no-op for the same store
    func rebuildWebView(with newStore: WKWebsiteDataStore) {
        guard newStore !== dataStore else { return }
        // the old view's unanswered question holds a handler nothing could call
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

        // a tab that hadn't loaded stays lazy
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

    /// a restored tab's title until its first navigation
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

    /// fetch the site's favicon without loading the page
    func prefetchFavicon() {
        FaviconStore.shared.prefetch(host: faviconHost, isPrivate: isPrivate)
    }

    /// mark the tab as just-used, resetting its auto-archive clock
    func touch() { lastAccessed = Date() }

    /// load a lazily restored or hibernated tab, through its saved interaction
    /// state when it has one
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
            // assigning interaction state is the navigation
            webView.interactionState = state
            // WebKit can decline a stale blob; then load the url
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self, self.webView.url == nil, !self.webView.isLoading else { return }
                self.load(pendingURL)
            }
        } else {
            load(pendingURL)
        }
    }

    // MARK: - Hibernation

    /// asleep: the web view and its process are released until next selected
    private(set) var isHibernated = false

    /// WebKit's opaque session blob (scroll, forms, back/forward list), kept while asleep
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

    /// one request this page had blocked, as a blocker extension's panel reads it back
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

    /// requests blocked on this page per rule list, for diagnostics
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

    /// a restored tab's state from last launch, replayed by `activateIfNeeded`
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

    /// release the web view and its web content process, keeping enough to
    /// restore the page exactly
    func hibernate() {
        guard canHibernate, let current = url ?? lastAttemptedURL else { return }
        savedInteractionState = webView.interactionState
        pendingURL = current
        isHibernated = true

        observations.forEach { $0.invalidate() }
        observations = []
        // a WKWebView that never loads spawns no web process
        webView = ArtemisWebView(
            frame: .zero, configuration: BrowserTab.defaultConfiguration(dataStore: dataStore))
        configureWebView()
        observeWebView()
        webViewGeneration += 1
        // the observers just re-read an empty view
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

    /// close a pinned tab's page but keep the pin: it returns to the unloaded state
    /// of a restored pin at `pinnedURL`, with its session dropped
    func closeToPinned() {
        guard let anchor = pinnedURL ?? url ?? lastAttemptedURL ?? pendingURL else { return }
        WebNotifications.shared.forgetPage(in: id)
        appBadge = nil
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

    /// the installed Safari's short version, for the UA's `Version/` token: streaming
    /// players gate DRM on it
    private static let currentSafariVersion: String = {
        if let dict = NSDictionary(contentsOfFile: "/Applications/Safari.app/Contents/Info.plist"),
            let v = dict["CFBundleShortVersionString"] as? String, !v.isEmpty {
            return v
        }
        return "26.0"
    }()

    /// launch a spare web content process, so a new tab's first load doesn't
    /// start one on the main thread
    static func prewarmWebProcess() {
        let warm = Selector(("_warmInitialProcess"))
        guard processPool.responds(to: warm) else { return }
        processPool.perform(warm)
    }

    /// every tab's process pool; a pool per tab would scan every font on main per tab
    static let processPool = WKProcessPool()

    /// `dataStore` binds the tab to a profile's jar; nil is WebKit's default store,
    /// which is the default profile's
    static func defaultConfiguration(dataStore: WKWebsiteDataStore? = nil) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.processPool = processPool
        if let dataStore { configuration.websiteDataStore = dataStore }
        configuration.applicationNameForUserAgent = "Version/\(currentSafariVersion) Safari/605.1.15"
        configuration.preferences.isElementFullscreenEnabled = true
        // Writing Tools rewrites in place inside the page's editors
        configuration.writingToolsBehavior = .complete
        // the in-app Web Inspector needs this as well as `isInspectable`
        configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        let prefs = configuration.preferences
        if prefs.responds(to: Selector(("_setAllowsPictureInPictureMediaPlayback:"))) {
            unsafeBitCast(prefs, to: WKPreferencesPiPSPI.self)
                ._setAllowsPictureInPictureMediaPlayback(false)
        }
        let mediaPrefs = unsafeBitCast(prefs, to: WKPreferencesMediaDevicesSPI.self)
        if prefs.responds(to: Selector(("_setMediaStreamEnabled:"))) {
            mediaPrefs._setMediaStreamEnabled(true)
        }
        if prefs.responds(to: Selector(("_setMediaDevicesEnabled:"))) {
            mediaPrefs._setMediaDevicesEnabled(true)
        }
        ExtensionLab.quiet(prefs)
        // an incognito page takes its parent profile's controllers; WebKit lets in
        // only the extensions with private access
        let isPrivate = dataStore?.isPersistent == false
        let profile = dataStore.map(ProfileStore.proxyProfile(of:)) ?? Profile.defaultID
        configuration.webExtensionController = WebExtensionRuntime.controller(for: profile)
        configuration.userContentController = SharedWebContent.userContentController(for: profile, isPrivate: isPrivate)
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
        // read access to the file alone: a sibling stylesheet won't load
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

    /// writes the page into ~/Downloads under a non-clashing name, then shows it in Finder
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

    // MARK: - Web Inspector

    /// the `_WKInspector` controller for this tab, or nil if the SPI is absent
    private var inspectorSPI: WKInspectorSPI? {
        guard webView.responds(to: Selector(("_inspector"))) else { return nil }
        guard let inspector = unsafeBitCast(webView, to: WKWebViewInspectorSPI.self)._inspector
        else { return nil }
        return unsafeBitCast(inspector, to: WKInspectorSPI.self)
    }

    /// whether the Web Inspector is open; turns true a beat after `toggleInspector`
    var isInspectorVisible: Bool { inspectorSPI?.isVisible ?? false }

    /// ⌥⌘I / menu: open this tab's Web Inspector, or close it if already up
    func toggleInspector() {
        guard let inspector = inspectorSPI else { return }
        if inspector.isVisible {
            inspector.close()
        } else {
            inspector.show()
            // a docked inspector never paints inside the rounded card
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
                    // a page's real title can arrive after `didFinish`
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
    /// proxy auth from a VPN extension's bridge, server trust, and HTTP auth
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
            // our proxy, credentials not yet in: fail rather than raise a system
            // dialog; the tabs reload once they land
            if ExtensionProxyBridge.shared.activeProxy(in: ProfileStore.proxyProfile(of: dataStore)) != nil {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
        }
        // the only chance to keep the certificate: a load failure carries no trust
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
        switch space.authenticationMethod {
        case NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest,
            NSURLAuthenticationMethodNTLM:
            askForCredentials(space, completionHandler)
        default:
            completionHandler(.performDefaultHandling, nil)
        }
    }

    /// put the server's login to the user; credentials live for this session only
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
        // dialog silencing is per page; reset here because `didCommit` can arrive
        // after the new document's first `alert()`
        suppressesDialogs = false
        dialogsThisPage = 0
        canOverrideCertificate = false
        WebNotifications.shared.forgetPage(in: id)
        // navigating anywhere leaves the reader, except the reader's own load
        if isLoadingReaderDocument {
            isLoadingReaderDocument = false
        } else if isReaderMode {
            isReaderMode = false
            preReaderURL = nil
        }
    }

    /// adopt the new site's zoom here, before the page paints
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        webView.setValue(true, forKey: "drawsBackground")
        webView.underPageBackgroundColor = nil
        if appBadge != nil, SitePermissionStore.originString(webView.url) != appBadgeOrigin { appBadge = nil }
        syncZoomToSite()
        endPageTranslation()
        PasswordAutofill.shared.pageDidCommit(in: self)
        Autofill.shared.pageDidCommit(in: self)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        debugLog("didFinish url=\(webView.url?.absoluteString ?? "nil")")
        loadError = nil
        fetchFavicon()
        probeReaderAvailability()
        PasswordAutofill.shared.pageDidFinish(in: self)
        BoostStore.shared.inject(into: webView, url: webView.url)
        Task { await translateIfRuled() }
        if let url = webView.url, url.scheme == "http" || url.scheme == "https" {
            onDidNavigate?(url, webView.title?.isEmpty == false ? webView.title! : (url.host() ?? url.absoluteString))
            // focus the loaded page, as Safari does, so `document.hasFocus()` holds;
            // never the hidden tab, or while a field editor holds first responder
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
    /// a second crash within a minute stops the loop at the error page
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        debugLog("web content process terminated: \(url?.absoluteString ?? "-")")
        Diagnostics.record(area: "webcontent", message: "web content process ended", inPrivate: isPrivate)
        abandonDialog()
        resetMediaState()
        let now = Date()
        defer { lastCrash = now }
        if let lastCrash, now.timeIntervalSince(lastCrash) < 60 {
            lastAttemptedURL = url ?? lastAttemptedURL
            loadError = Self.crashLoopError
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
        // a cancellation isn't a failure
        guard nsError.code != NSURLErrorCancelled else { return }
        // "frame load interrupted": normal when a navigation becomes a download
        guard !(nsError.domain == "WebKitErrorDomain" && nsError.code == 102) else { return }
        // "plug-in handled load" (204): a raw media file shown in WebKit's viewer
        guard !(nsError.domain == "WebKitErrorDomain" && nsError.code == 204) else { return }
        loadError = nsError.localizedDescription
        canOverrideCertificate = CertificateTrust.isOverridable(nsError)
        if let host = lastAttemptedURL?.host() {
            title = host
        }
    }

    /// accept the certificate this host last presented, then reload; scoped to
    /// that one certificate by `SecTrustCopyExceptions`
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
            // a linked split pane loads plain link clicks in its pair
            if manager?.routeLinkedNavigation(from: self, to: url) == true {
                return (.cancel, preferences)
            }
        }
        // a scheme WebKit doesn't render belongs to another app
        if let url = navigationAction.request.url, !ExternalSchemes.isInternal(url.scheme) {
            // only the main frame or a new window may ask; a subframe is cancelled silently
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

        // an attachment downloads even when its mime type is displayable
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

    /// `window.close()`
    func webViewDidClose(_ webView: WKWebView) {
        if let confirmed = onConfirmedClose {
            onConfirmedClose = nil
            confirmed()
        } else {
            onRequestClose?()
        }
    }

    /// `<input type=file>` was clicked
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
            // `accept` is a hint, not a rule
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

    /// `beforeunload`'s leave prompt. SPI: without it WebKit unloads without asking
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

    /// put a page's question on screen; refused while the page is silenced or
    /// another of its dialogs is up
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
            // a leave prompt never offers silencing
            checkbox: dialogsThisPage > 1 && kind != .leaveConfirm ? .silencePage : nil
        ) { [weak self] answer in
            self?.pendingDialog = nil
            respond(answer)
        }
    }

    /// hand a link in a scheme WebKit can't render to its app, once the user agrees
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

    /// camera or microphone: a remembered per-site answer; WebKit treats no handler as deny
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

    /// location: a remembered per-site answer
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

/// the tab as the WebExtensions runtime sees it; unimplemented methods fall back to WebKit
extension BrowserTab: WKWebExtensionTab {
    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        guard isPrivate else { return ExtensionManager.shared.browserWindow }
        return manager.flatMap(ExtensionManager.shared.privateWindow(of:))
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
