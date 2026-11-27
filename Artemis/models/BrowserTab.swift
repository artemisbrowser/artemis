// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

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

/// a retired page's navigation delegate: with none, WebKit hands unloadable URLs to other apps
private final class RetiredPage: NSObject, WKNavigationDelegate {
    static let shared = RetiredPage()

    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, preferences: WKWebpagePreferences
    ) async -> (WKNavigationActionPolicy, WKWebpagePreferences) { (.cancel, preferences) }

    func webView(
        _ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse
    ) async -> WKNavigationResponsePolicy { .cancel }
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

    /// what you called this tab, kept on its record wherever the tab goes; never
    /// set on an incognito tab
    var customName: String?

    /// your name for the tab, else the model's for its page; nil shows the page
    /// title. an incognito tab has neither
    @MainActor
    var name: String? {
        isPrivate ? nil : customName ?? TabNameStore.shared.generated(for: url ?? pendingURL)
    }

    /// the sidebar's title: `name`, else the page title
    @MainActor
    var displayTitle: String { name ?? title }
    private(set) var url: URL?
    private(set) var isLoading = false
    private(set) var progress: Double = 0
    /// true briefly after a load completes so the progress bar can run to 100%
    private(set) var isFinishingLoad = false
    /// a stopped load ends without the run to 100%
    @ObservationIgnored private var stopRequested = false

    /// the url last asked of `load`, or the main-frame url that last failed;
    /// survives failed loads, unlike `webView.url`
    private(set) var lastAttemptedURL: URL?
    /// the url `load` asked for, until that navigation commits or otherwise ends
    private(set) var requestedURL: URL?
    /// the page `load` left for an extension's page, while this web view is that extension's
    @ObservationIgnored private var pageUnderExtension: URL?
    /// this web view is built from an extension's configuration: WebKit loads only that extension's pages in it
    @ObservationIgnored private var isExtensionView = false
    /// never asked to load anything
    var isBlank: Bool { url == nil && pendingURL == nil && lastAttemptedURL == nil }
    @ObservationIgnored private var requestedNavigation: WKNavigation?
    /// a main-frame load the app or a link click started, and the site it started on
    @ObservationIgnored private var restartable: (navigation: WKNavigation, site: String)?
    /// the load a cross-site redirect restarted, and how many restarts in a row
    @ObservationIgnored private var restarted: WKNavigation?
    @ObservationIgnored private var restarts = 0
    /// when the main frame's current document committed
    @ObservationIgnored private(set) var committedAt = Date.distantPast
    /// the origin of the frame that opened this page with `window.open` or a link to a new window,
    /// until the page commits another site
    @ObservationIgnored private(set) var openerOrigin: String?
    /// the press in the opener's page that opened this one, good for this page's first download
    @ObservationIgnored private var openerPress: Date?
    /// the view came from WebKit for `window.open`; replacing it severs the opener
    @ObservationIgnored private var isOpenedByPage = false
    /// the press that last let a download through; each press lets through one
    @ObservationIgnored private var spentDownloadGesture = Date.distantPast
    @ObservationIgnored private var spentLaunchGesture = Date.distantPast
    /// when a load the app started, or the press that opened this page, happened; good for one app
    /// launch within `gestureWindow`, and after it for one question that never opens unasked
    @ObservationIgnored private var launchOwed = Date.distantPast
    /// frames (`_WKFrameHandle`) whose latest navigation WebKit counts as the user's
    @ObservationIgnored private var userInitiatedFrames: Set<NSObject> = []
    /// seconds a press in this tab's page stays good for one download and one app launch
    private static let gestureWindow: TimeInterval = 10
    /// human-readable load failure, nil when fine; drives the error page
    private(set) var loadError: String?
    static let crashLoopError = "Artemis stopped reloading it after it crashed twice in a minute."
    static let webArchiveError = "Web archives open only from a file on this Mac. Download it, then open the file."
    /// set while the tab shows a local web archive, in a web view of the reader's own
    private(set) var reader: WebArchiveReader?
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
    var faviconHost: String? { (url ?? lastAttemptedURL ?? pendingURL)?.host() }

    /// from the persistent per-host store, so it shows before a restored tab loads
    var favicon: NSImage? { FaviconStore.shared.icon(for: faviconHost) }

    /// a vivid colour sampled from the favicon; nil until the icon resolves
    var faviconAccent: Color? { FaviconStore.shared.accent(for: faviconHost) }

    /// pinned tabs live in their own sidebar section and persist across launches
    var isPinned = false

    /// a favourite: shown in the grid shared by every space
    var isEssential = false

    /// the home a pinned tab or favourite returns to when closed; away from it, the
    /// row or tile reads as "off" its page. nil for a Today tab
    var pinnedURL: URL? {
        didSet { if pinnedURL != oldValue { homeLanding = nil } }
    }

    /// where the page at `pinnedURL` moved itself with no press behind the move; reads as home too
    var homeLanding: URL?
    /// the main-frame navigation under way is a load of home, or home's page moving itself
    @ObservationIgnored private var navigatingAsHome = false
    /// when the app last asked for home: a press before it is no press in home's page
    @ObservationIgnored private var homeLoadStarted = Date.distantPast
    /// the last change of `url` left home, with no load asked of the tab
    @ObservationIgnored private var movedFromHome = false

    /// the connected coding agent that has driven this tab; nil once it disconnects
    var agentName: String?
    /// an agent task's say over each navigation here, with the time of the user's own press when one
    /// started it; false cancels it
    var agentGate: ((WKNavigationAction, Date?) -> Bool)?

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

    /// a pin with no page: closed to its url, or restored unloaded. A sleeping pin still has one
    var isDormantPin: Bool { isPinned && pendingURL != nil && !isHibernated }

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

    /// the window that wired this tab, and whether it was a browser window, whose
    /// tabs are shared and outlive it
    @ObservationIgnored weak var maker: TabManager?
    @ObservationIgnored var isShared = false

    /// the window this page answers to. A Scout, incognito or Peek page keeps the one that
    /// made it; a shared tab or favourite takes a browser window showing it, else one on its
    /// space (its profile, for a favourite), else the front one, else the next window's manager
    var manager: TabManager? {
        guard isShared, maker?.peekTab !== self else { return maker }
        let windows = BrowserWindows.shared
        let mains = [windows.browserScope].compactMap { $0 } + windows.mainManagers
        return mains.first { $0.isShowing(self) }
            ?? mains.first { isEssential ? $0.currentProfile.id == profileID : $0.space(of: self) === $0.currentSpace }
            ?? mains.first ?? windows.seed ?? maker
    }

    /// rebuilt (not mutated) when the tab changes profile — WebKit fixes a web
    /// view's data store at creation, so a new jar means a new web view
    var webView: WKWebView { madeWebView ?? makeWebView(with: BrowserTab.defaultConfiguration(dataStore: dataStore)) }
    /// the web view if anything has asked for it yet; a restored tab makes it on first use
    @ObservationIgnored private(set) var madeWebView: WKWebView?

    private var hasNeverLoaded: Bool {
        madeWebView.map { $0.url == nil && !$0.isLoading && $0.backForwardList.currentItem == nil } ?? true
    }
    /// a web view's size until a window's card has been laid out. a page that loads at no width takes
    /// each `srcset` image at infinite density, so at a natural size of zero for good
    static let unseenSize = CGSize(width: 1280, height: 800)
    /// web views made since launch, for the launch bench
    nonisolated(unsafe) static var webViewsMade = 0
    /// the cookie jar this tab's web view is bound to. `ProfileStore` caches one
    /// store per profile, so `===` tells a real profile move from a no-op
    @ObservationIgnored private(set) var dataStore: WKWebsiteDataStore
    /// bumps each time `webView` is rebuilt; the SwiftUI host's `.id`, so must stay observed
    private(set) var webViewGeneration = 0 {
        didSet { stillFrame = nil }
    }
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    /// the slot that last held this tab's web view, where the mini-player hands it back
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
    /// an upload's open panel is up
    @ObservationIgnored private(set) var isChoosingFile = false
    /// the user asked this page to stop putting up dialogs; cleared on navigation
    private var suppressesDialogs = false
    /// dialogs since the last commit — the second one earns a suppression offer
    private var dialogsThisPage = 0
    /// bumped by each main-frame decide but a redirect's, and by each stop; a UA write that saw an
    /// older count is stale
    @ObservationIgnored private(set) var userAgentDecisions = 0
    /// the count of the last decide that let its navigation through, and whether it went disguised
    @ObservationIgnored private var userAgentAllowed = 0
    @ObservationIgnored private var allowedDisguised = false
    /// whether the committed page went out disguised; a restore puts this back
    @ObservationIgnored private var committedDisguised = false
    /// each main-frame navigation's count from its decide
    @ObservationIgnored private let navigationDecisions = NSMapTable<WKNavigation, NSNumber>.weakToStrongObjects()

    enum CertificateFailure {
        case overridable
        /// the site requires a secure connection: there is no way past
        case final
    }
    /// this load failed on a certificate the system refused
    private(set) var certificateFailure: CertificateFailure?
    /// each host's trust from this page's challenges, until the next commit. a failed
    /// load carries none, so the certificate its error page asks about is kept here
    @ObservationIgnored private(set) var serverTrusts: [String: SecTrust] = [:]
    /// the main-frame host a certificate exception let through; holds until a page on another host commits,
    /// as the connection it opened can carry that host's later loads, exception or not
    private(set) var exceptionHost: String?
    /// an https page on a connection no certificate exception could have opened
    var isSecure: Bool {
        guard url?.scheme == "https", let host = url?.host(), exceptionHost != host, let certificateTrust
        else { return false }
        return !certificateTrust.hasException(for: host, ephemeral: isPrivate)
            || certificateTrust.requiresSecureConnection(host, ephemeral: isPrivate)
    }

    /// whether saved logins, passkeys and cards may reach `origin`, a frame under the top document on `top`
    /// (this page's by default): no certificate exception lets either through on https. Schemes are the callers' gate
    func offersCredentials(to origin: String, under top: String? = nil) -> Bool {
        [origin, top ?? SitePermissionStore.originString(webView.url) ?? origin].allSatisfy { each in
            let url = URL(string: each)
            guard url?.scheme == "https" else { return true }
            guard let host = url?.host(), let certificateTrust else { return false }
            return host != exceptionHost
                && (!certificateTrust.hasException(for: host, ephemeral: isPrivate)
                    || certificateTrust.requiresSecureConnection(host))
        }
    }

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
    /// an incognito page reads its window's profile's and remembers its own in memory only
    var sitePermissions: SitePermissionStore? { BrowserCore.shared.profile(loginProfile)?.sitePermissions }
    /// an incognito page applies its window's profile's exceptions and keeps its own in memory only
    var certificateTrust: CertificateTrust? { BrowserCore.shared.profile(loginProfile)?.certificateTrust }

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

    /// frames playing media, keyed by `LoginKeys.key`; fed by `MediaStateReporter`
    @ObservationIgnored private var playingFrames: Set<AnyHashable> = []

    /// any frame is playing audio or video; unlike `_isPlayingAudio`, true while muted
    private(set) var isPlayingMediaContent = false

    /// engine-level mute for the tab; survives navigation
    private(set) var isMuted = false

    /// record a frame's playback state; recomputes the tab-level flag
    func setFramePlaying(_ playing: Bool, frame: AnyHashable) {
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
    @ObservationIgnored private var mediaFrames: [AnyHashable: (info: WKFrameInfo, media: PageMedia)] = [:]
    /// the frame `media` came from, where `sendMediaCommand` goes
    @ObservationIgnored private var mediaFrame: WKFrameInfo?
    /// the media the sidebar's Now Playing card shows: this tab's top-ranked frame
    private(set) var media: PageMedia?

    /// record a frame's controllable media (nil once it has none); re-elects `media`
    func setFrameMedia(_ media: PageMedia?, frame key: AnyHashable, info: WKFrameInfo) {
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

    // the main frame's scroll offset, pushed by ScrollReporter only while something has armed it
    var pageScrollY: Double = 0

    /// documents whose focused element takes typing, by the token each one draws for itself;
    /// fed by `EditingFocusReporter`
    @ObservationIgnored private var editingFrames: Set<String> = []

    /// a field or editor in the page has focus, so ⌘Z belongs to the page
    var isEditingText: Bool { !editingFrames.isEmpty }

    func setFrameEditing(_ editing: Bool, frame: String) {
        let was = isEditingText
        if editing { editingFrames.insert(frame) } else { editingFrames.remove(frame) }
        if was != isEditingText { UndoRoute.shared.refresh() }
    }

    /// a fresh document or web view plays nothing and edits nothing
    private func resetFrameState() {
        editingFrames.removeAll()
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
        guard let webView = madeWebView, webView.responds(to: Selector(("_isPlayingAudio"))) else { return false }
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
        guard webView.url != nil,
            manager == nil || BrowserWindows.shared.allManagers.contains(where: { $0.displayedContentTab === self })
        else {
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
        let article = await ReaderMode.extract(from: webView, url: current)
        // the page may have moved on, or a second toggle got there first
        guard url == current, !isReaderMode else { return }
        guard let article else {
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
        dataStore = configuration.websiteDataStore
        super.init()
        makeWebView(with: configuration)
    }

    private init(id: UUID, deferringIn dataStore: WKWebsiteDataStore) {
        self.id = id
        self.dataStore = dataStore
        super.init()
    }

    @discardableResult
    private func makeWebView(with configuration: WKWebViewConfiguration) -> WKWebView {
        let view = ArtemisWebView(
            frame: CGRect(origin: .zero, size: manager?.pageSize ?? Self.unseenSize), configuration: configuration)
        madeWebView = view
        isExtensionView = configuration.spiValue(forKey: "_requiredWebExtensionBaseURL") != nil
        Self.webViewsMade += 1
        if Self.webViewsMade == 1 { Bench.mark("first web view made") }
        configureWebView()
        observeWebView()
        return view
    }

    /// one-time web-view setup, shared by `init` and `rebuildWebView`
    private func configureWebView() {
        // transparent only until the first commit (see `didCommit`), so a fresh view never
        // flashes white; after that the page owns its canvas and the space never tints it
        webView.setSPIValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .clear
        // extension context menus need to know which tab the menu is for
        (webView as? ArtemisWebView)?.owningTab = self

        // WebKit swipes back and forward only once the page can't scroll further sideways
        webView.allowsBackForwardNavigationGestures = TabManager.swipesNavigate
        webView.allowsMagnification = true
        webView.uiDelegate = self
        webView.navigationDelegate = self
        // carries zoom and mute across a rebuild
        webView.pageZoom = zoomLevel
        applyMuteState()
        resetFrameState()
    }

    /// move the tab to another profile's jar: a fresh web view reloads the page,
    /// losing back/forward history and scroll. a no-op for the same store
    func rebuildWebView(with newStore: WKWebsiteDataStore) {
        guard newStore !== dataStore else { return }
        // a jar's extensions know only its own tabs: this one leaves the old
        // profile's controller here and joins the new one's once rebuilt
        ExtensionManager.shared.tabDidClose(self)
        let wasPending = pendingURL
        let resume = url ?? lastAttemptedURL ?? pendingURL
        replaceWebView(with: BrowserTab.defaultConfiguration(dataStore: newStore))
        dataStore = newStore
        ExtensionManager.shared.tabDidOpen(self)

        // a tab that hadn't loaded stays lazy
        if wasPending == nil, let resume { load(resume) }
    }

    /// a page being dropped: cut off from this tab and silent at once, closed once any fade
    /// over it has landed, so nothing that still holds the view can keep it playing
    func retire() {
        guard let webView = madeWebView else { return }
        webView.navigationDelegate = RetiredPage.shared
        webView.uiDelegate = nil
        webView.stopLoading()
        webView.pauseAllMediaPlayback(completionHandler: nil)
        webView.setAllMediaPlaybackSuspended(true, completionHandler: nil)
        let close = Selector(("_close"))
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak webView] in
            if webView?.responds(to: close) == true { webView?.perform(close) }
        }
    }

    /// a fresh web view, which the url and history observers have re-read empty
    private func replaceWebView(with configuration: WKWebViewConfiguration) {
        // the old view's unanswered question holds a handler nothing could call
        abandonDialog()
        BrowserCore.shared.miniPlayer.exitIfActive(for: self)
        observations.forEach { $0.invalidate() }
        observations = []
        retire()
        pageUnderExtension = nil
        reader = nil
        makeWebView(with: configuration)
        webViewGeneration += 1
    }

    /// the host, less a leading "www.": the title a page stands under until it gives one
    private static func hostTitle(of url: URL) -> String? {
        url.host().map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 }
    }

    /// restore a tab without loading it yet; the host name stands in as the
    /// title until the page is hydrated on first selection (lazy)
    convenience init(
        id: UUID = UUID(), restoring url: URL, pinned: Bool, pinnedURL: URL? = nil,
        lastAccessed: Date = Date(), dataStore: WKWebsiteDataStore? = nil
    ) {
        if PerfFlags.makesWebViewsLazily {
            self.init(id: id, deferringIn: dataStore ?? .default())
        } else {
            self.init(id: id, configuration: BrowserTab.defaultConfiguration(dataStore: dataStore))
        }
        isPinned = pinned
        self.pinnedURL = pinned ? (pinnedURL ?? url) : nil
        pendingURL = url
        self.lastAccessed = lastAccessed
        if let host = Self.hostTitle(of: url) { title = host }
        addressText = url.absoluteString
    }

    /// a restored tab's title until its first navigation
    func adopt(restoredTitle: String) {
        guard !restoredTitle.isEmpty, url == nil else { return }
        title = restoredTitle
    }

    /// a pinned tab or favourite that has navigated away from its home `pinnedURL`
    var isOffPinnedURL: Bool { (url ?? lastAttemptedURL ?? pendingURL).map(isOffHome) ?? false }

    private func isOffHome(_ location: URL) -> Bool {
        guard isPinned || isEssential, let pinnedURL else { return false }
        let here = BrowserTab.normalizedLocation(location)
        return here != BrowserTab.normalizedLocation(pinnedURL)
            && here != homeLanding.map(BrowserTab.normalizedLocation)
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
        FaviconStore.shared.prefetch(
            host: faviconHost, profile: ProfileStore.proxyProfile(of: dataStore), isPrivate: isPrivate)
    }

    /// mark the tab as just-used, resetting its auto-archive clock
    func touch() { lastAccessed = Date() }

    /// load a lazily restored or hibernated tab, through its saved interaction
    /// state when it has one
    func activateIfNeeded() {
        if needsReload {
            needsReload = false
            webView.reload()
        }
        guard let pendingURL else { return }
        self.pendingURL = nil
        isHibernated = false
        if let image = sleepImage {
            wakeStill = image
            sleepFrame = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.wakeStill = nil }
        }
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

    /// until the current load finishes, at most 15 s, or the task is cancelled
    func settle(until done: () -> Bool = { false }) async {
        try? await Task.sleep(for: .milliseconds(200))
        let deadline = Date(timeIntervalSinceNow: 15)
        while webView.isLoading, !done(), Date() < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// loaded for something to read it unseen: a lazy or hibernated tab wakes and settles
    func wake() async {
        if pendingURL != nil {
            activateIfNeeded()
            await settle()
        }
    }

    // MARK: - Hibernation

    /// asleep: the web view and its process are released until next selected
    private(set) var isHibernated = false

    /// WebKit's opaque session blob (scroll, forms, back/forward list), kept while asleep
    @ObservationIgnored private var savedInteractionState: Any?

    /// never put to sleep by the idle timer or memory pressure
    var keepsLoaded = false

    /// the page went stale off screen (its process died, or the rule lists changed); a new
    /// navigation clears it, else the next show reloads
    @ObservationIgnored private var needsReload = false

    /// reload now if some window shows the tab, else on its next show
    func reloadWhenShown() {
        if BrowserWindows.shared.allManagers.contains(where: { $0.onScreenTabIDs.contains(id) }) {
            webView.reload()
        } else {
            needsReload = true
        }
    }
    @ObservationIgnored private var lastCrash: Date?
    /// the web content process the committed page lives in; 0 before a commit
    @ObservationIgnored private var committedProcess: Int32 = 0

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
    /// asleep or not yet restored (an unloaded web view's state is empty). none for a saved copy,
    /// whose pages only its reader can load
    var persistableInteractionState: Any? {
        isHibernated || pendingURL != nil ? savedInteractionState : reader == nil ? webView.interactionState : nil
    }

    /// set by navigation; a debounced save writes only tabs that have it
    @ObservationIgnored var hasUnsavedState = true

    /// a restored tab's state from last launch, replayed by `activateIfNeeded`;
    /// it is already on disk, so a debounced save skips it
    func adopt(interactionState state: Any?) {
        guard pendingURL != nil else { return }
        savedInteractionState = state
        hasUnsavedState = false
    }

    /// a full history clear: the back/forward list goes, from the live page and from
    /// what a lazy or sleeping tab holds; the page on screen stays
    func forgetSessionHistory() {
        savedInteractionState = nil
        // SPI: `_clear` drops every item but the current one
        let clear = Selector(("_clear"))
        if webView.backForwardList.responds(to: clear) { webView.backForwardList.perform(clear) }
        hasUnsavedState = true
    }

    /// a tab worth putting to sleep: loaded, not already asleep, and not doing
    /// anything you'd notice stopping
    var canHibernate: Bool {
        guard !isHibernated, pendingURL == nil else { return false }
        guard let current = url ?? lastAttemptedURL, current.scheme?.hasPrefix("http") == true
        else { return false }
        return !keepsLoaded && !isCapturing && !isPlayingMediaContent && !isMiniPlayerActive
            && !isLoading && agentName == nil && pendingDialog == nil && !isInspectorVisible
    }

    /// release the web view and its web content process, keeping enough to
    /// restore the page exactly
    func hibernate() {
        guard canHibernate, let current = url ?? lastAttemptedURL else { return }
        savedInteractionState = webView.interactionState
        pendingURL = current
        isHibernated = true
        replaceWebView(with: BrowserTab.defaultConfiguration(dataStore: dataStore))
        if title.isEmpty || title == "New Tab", let host = Self.hostTitle(of: current) { title = host }
        url = current
        addressText = current.absoluteString
        canGoBack = false
        canGoForward = false
        debugLog("tab hibernated: \(current.absoluteString)")
    }

    /// the page as it looked going to sleep, as JPEG, until it wakes
    @ObservationIgnored private(set) var sleepFrame: Data?
    var sleepImage: NSImage? { sleepFrame.flatMap(NSImage.init(data:)) }
    /// that still, over the woken page until it finishes or fails loading, for at most 5 s
    private(set) var wakeStill: NSImage?
    /// since when the page has had requests in flight at every policy check
    @ObservationIgnored private var requestsInFlightSince: Date?

    /// put to sleep by policy: first what `canHibernate` can't see at once, then a still of the
    /// page. `idle` is asked again after every wait
    func sleepIfIdle(while idle: () -> Bool) async {
        guard canHibernate, idle() else { return }
        if PerfFlags.sleepExemptions, await isBusy() { return }
        let frame = PerfFlags.keepsSleepFrame ? await still() : nil
        guard canHibernate, idle() else { return }
        hibernate()
        sleepFrame = frame
    }

    /// what sleep would cost: unsent text in a form, a download it started, or a live app, which
    /// may notify, shows a badge or has had requests in flight for 30 s of checks
    private func isBusy() async -> Bool {
        let selector = Selector(("_networkRequestsInProgress"))
        typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
        let inFlight =
            webView.responds(to: selector) && unsafeBitCast(webView.method(for: selector), to: Getter.self)(webView, selector)
        requestsInFlightSince = inFlight ? requestsInFlightSince ?? Date() : nil
        if appBadge != nil || mayNotify || DownloadManager.shared.isDownloading(from: webView) { return true }
        if let since = requestsInFlightSince, since.timeIntervalSinceNow <= -30 { return true }
        return await hasUnsentText()
    }

    /// its site has been allowed to send notifications, which only an awake page can
    var mayNotify: Bool {
        !isPrivate && SitePermissionStore.originString(url).flatMap {
            sitePermissions?.decision(for: $0, .notifications, ephemeral: false)
        } == .allow
    }

    private static let sleepWorld = WKContentWorld.world(name: "artemis-sleep")
    /// typed text a form still holds: a login form's autofill doesn't count
    private static let unsentTextProbe = """
        (() => {
          const skip = ['hidden', 'password', 'submit', 'button', 'reset', 'image', 'file', 'range', 'color']
          for (const e of document.querySelectorAll('input, textarea')) {
            if (e.form && e.form.querySelector('input[type=password]')) continue
            if (e.type === 'checkbox' || e.type === 'radio') { if (e.checked !== e.defaultChecked) return true; continue }
            if (!skip.includes(e.type) && e.value !== e.defaultValue) return true
          }
          const a = document.activeElement
          return !!(a && a.isContentEditable && a.textContent.trim())
        })()
        """

    /// a page too busy to answer within a second has nothing worth keeping awake for
    private func hasUnsentText() async -> Bool {
        final class Once { var done = false }
        let once = Once()
        return await withCheckedContinuation { answer in
            func finish(_ value: Bool) {
                guard !once.done else { return }
                once.done = true
                answer.resume(returning: value)
            }
            webView.evaluateJavaScript(Self.unsentTextProbe, in: nil, in: Self.sleepWorld) { finish((try? $0.get()) as? Bool ?? false) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { MainActor.assumeIsolated { finish(false) } }
        }
    }

    /// the page at its on-screen size, as JPEG
    private func still() async -> Data? {
        guard !webView.bounds.isEmpty else { return nil }
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = false
        guard let image = try? await webView.takeSnapshot(configuration: configuration),
            let picture = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }
        return NSBitmapImageRep(cgImage: picture).representation(using: .jpeg, properties: [.compressionFactor: 0.6])
    }

    /// close a pinned tab's page but keep the pin: it returns to the unloaded state
    /// of a restored pin at `pinnedURL`, with its session dropped
    func closeToPinned() {
        guard let anchor = pinnedURL ?? url ?? lastAttemptedURL ?? pendingURL else { return }
        park(at: anchor)
        url = anchor
    }

    /// unloaded at `target` with its session dropped, as a restored tab is: nothing loads until it is shown
    func park(at target: URL, title: String? = nil) {
        // a never-loaded view is already what a fresh one would be
        let pristine = hasNeverLoaded && (isHibernated || lastAttemptedURL == nil)
        WebNotifications.shared.forgetPage(in: id)
        appBadge = nil
        savedInteractionState = nil
        isHibernated = false
        pendingURL = target
        lastAttemptedURL = nil
        endRequestedLoad()
        loadError = nil
        if pristine {
            adoptCommittedURL()
            stillFrame = nil
            hasUnsavedState = true
        } else {
            replaceWebView(with: BrowserTab.defaultConfiguration(dataStore: dataStore))
        }

        addressText = target.absoluteString
        if let shown = title ?? Self.hostTitle(of: target) { self.title = shown }
        canGoBack = false
        canGoForward = false
    }

    /// the installed Safari's short version, for the UA's `Version/` token: streaming
    /// players gate DRM on it
    static let currentSafariVersion: String = {
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

    private static let webKitFeatures: [String: NSObject] = {
        let list = (WKPreferences.self as AnyObject as? NSObject)?.spiValue(forKey: "_features") as? [NSObject]
        return Dictionary((list ?? []).compactMap { f in (f.spiValue(forKey: "key") as? String).map { ($0, f) } }) { a, _ in a }
    }()

    /// one of WebKit's internal feature flags, by key; a no-op where this WebKit lacks it
    private static func setFeature(_ key: String, _ enabled: Bool, on prefs: WKPreferences) {
        let selector = Selector(("_setEnabled:forFeature:"))
        guard let feature = webKitFeatures[key], prefs.responds(to: selector) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool, AnyObject) -> Void
        unsafeBitCast(prefs.method(for: selector), to: Setter.self)(prefs, selector, enabled, feature)
    }

    /// every tab's process pool; a pool per tab would scan every font on main per tab
    static let processPool = WKProcessPool()

    /// same-site tabs in one jar spread over at most this many web content processes
    static let processesPerSite = 4

    /// scheme plus registrable domain, as WebKit draws process boundaries; nil off the web
    static func site(of url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
            let host = url.host()?.lowercased()
        else { return nil }
        return scheme + "://" + (PasswordStore.registrableDomain(host) ?? host)
    }

    private static let canSharePages =
        WKWebView.instancesRespond(to: Selector(("_webProcessIdentifier")))
        && WKWebViewConfiguration.instancesRespond(to: Selector(("_setRelatedWebView:")))

    /// once `url`'s site fills `processesPerSite` processes in `store` that hold no other site,
    /// a page in the one of them holding fewest tabs, answering and with no dialog up; else nil
    private static func processSharer(for url: URL, in store: WKWebsiteDataStore) -> WKWebView? {
        guard canSharePages, let site = site(of: url) else { return nil }
        var processes: [Int32: (views: [WKWebView], sites: Set<String>, blocked: Bool)] = [:]
        var seen = Set<ObjectIdentifier>()
        for tab in BrowserWindows.shared.allManagers.lazy.flatMap(\.allTabs) where tab.dataStore === store {
            guard let view = tab.madeWebView, seen.insert(ObjectIdentifier(view)).inserted,
                let pid = view.spiValue(forKey: "_webProcessIdentifier") as? Int32, pid > 0,
                let pageSite = tab.committedURL.flatMap(Self.site(of:))
            else { continue }
            let blocked =
                tab.pendingDialog != nil
                || view.spiValue(forKey: "_webProcessIsResponsive") as? Bool == false
            processes[pid, default: ([], [], false)].views.append(view)
            processes[pid]?.sites.insert(pageSite)
            if blocked { processes[pid]?.blocked = true }
        }
        let own = processes.values.filter { $0.sites == [site] }
        guard own.count >= processesPerSite else { return nil }
        return own.filter { !$0.blocked }.min { $0.views.count < $1.views.count }?.views.first
    }

    /// a blank page whose process has run its first load, which costs a fresh process ~25 ms
    private static var warmPage: WKWebView?

    static func warmPage(in store: WKWebsiteDataStore) {
        guard canSharePages, warmPage?.configuration.websiteDataStore !== store else { return }
        let view = WKWebView(frame: .zero, configuration: defaultConfiguration(dataStore: store))
        view.loadHTMLString("", baseURL: nil)
        warmPage = view
    }

    private static func takeWarmPage(in store: WKWebsiteDataStore) -> WKWebView? {
        guard warmPage?.configuration.websiteDataStore === store else { return nil }
        defer { warmPage = nil }
        return warmPage
    }

    /// a page re-entering the window doesn't hold main until it has painted; false where WebKit
    /// lacks the SPI, which keeps the wait
    static let skipsPaintWait: Bool = {
        let has =
            WKWebViewConfiguration.instancesRespond(to: Selector(("_setWaitsForPaintAfterViewDidMoveToWindow:")))
            && WKWebView.instancesRespond(to: Selector(("_doAfterNextPresentationUpdate:")))
        if !has { debugLog("tabs: no _setWaitsForPaintAfterViewDidMoveToWindow:, pages wait to paint on entering a window") }
        return has
    }()

    /// `dataStore` binds the tab to a profile's jar; nil is WebKit's default store,
    /// which is the default profile's
    static func defaultConfiguration(dataStore: WKWebsiteDataStore? = nil) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.processPool = processPool
        if let dataStore { configuration.websiteDataStore = dataStore }
        configuration.applicationNameForUserAgent = "Version/\(currentSafariVersion) Safari/605.1.15"
        configuration.preferences.isElementFullscreenEnabled = true
        // `window.open` and target=_blank need the user's click or key press
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        // Writing Tools rewrites in place inside the page's editors
        configuration.writingToolsBehavior = .complete
        if skipsPaintWait { configuration.setSPIValue(false, forKey: "waitsForPaintAfterViewDidMoveToWindow") }
        // the in-app Web Inspector needs this as well as `isInspectable`
        configuration.preferences.setSPIValue(true, forKey: "developerExtrasEnabled")
        // Delete is the page's key: WebKit would go back on any press the page lets through
        configuration.preferences.setSPIValue(false, forKey: "backspaceKeyNavigationEnabled")
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
        FingerprintNoise.hideInstalledFonts(from: prefs)
        if PerfFlags.backsOffHiddenTimers { setFeature("HiddenPageDOMTimerThrottlingAutoIncreases", true, on: prefs) }
        // an incognito page takes its parent profile's controllers; WebKit lets in
        // only the extensions with private access
        let isPrivate = dataStore?.isPersistent == false
        let profile = dataStore.map(ProfileStore.proxyProfile(of:)) ?? Profile.defaultID
        configuration.webExtensionController = WebExtensionRuntime.controller(for: profile)
        configuration.userContentController = SharedWebContent.userContentController(for: profile, isPrivate: isPrivate)
        return configuration
    }

    // MARK: - Navigation

    /// `afterMount` waits for this turn's display commit, so the page is already in its window
    /// and main is free when its web process asks for a connection
    func load(_ url: URL, afterMount: Bool = false) {
        // WebKit runs a loaded `javascript:` URL in the current document's origin
        guard url.scheme?.lowercased() != "javascript" else { return }
        loadTicket += 1
        // a mounted view is replaced only by a blank one until commit
        if hasNeverLoaded, !isOpenedByPage, madeWebView?.window == nil,
            let sharer = Self.processSharer(for: url, in: dataStore) ?? Self.takeWarmPage(in: dataStore)
        {
            // a cross-site navigation later swaps the page out of the sharer's process
            let configuration = BrowserTab.defaultConfiguration(dataStore: dataStore)
            configuration.perform(Selector(("_setRelatedWebView:")), with: sharer)
            if madeWebView == nil { makeWebView(with: configuration) } else { replaceWebView(with: configuration) }
        }
        if afterMount, webView.window == nil {
            awaitingMount = url
            lastAttemptedURL = url
            let ticket = loadTicket
            let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, false, CFIndex.max) {
                [weak self] observer, _ in
                CFRunLoopObserverInvalidate(observer)
                guard let self, loadTicket == ticket else { return }
                start(url)
            }
            return CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        }
        start(url)
    }

    private func start(_ url: URL) {
        debugLog("tab load: \(url.absoluteString)")
        launchOwed = Date()
        lastAttemptedURL = url
        requestedURL = url
        loadError = nil
        lastAccessed = Date()
        addressText = url.absoluteString
        if url.isFileURL, url.pathExtension.lowercased() == "webarchive" { return openArchive(url) }
        let underneath = pageUnderExtension ?? webView.url
        if let configuration = extensionPageConfiguration(for: url) {
            replaceWebView(with: configuration)
            pageUnderExtension = underneath
        } else if reader != nil || isExtensionView && url.scheme?.hasSuffix("-extension") != true {
            replaceWebView(with: BrowserTab.defaultConfiguration(dataStore: dataStore))
        }
        // a local page reads the home folder it sits in, or else its own folder, so its
        // stylesheets, images and linked pages load. each file stays its own origin
        let home = URL.homeDirectory
        requestedNavigation =
            url.isFileURL
            ? webView.loadFileURL(
                url, allowingReadAccessTo: url.path.hasPrefix(home.path + "/") ? home : url.deletingLastPathComponent())
            : webView.load(URLRequest(url: url))
    }

    /// the url a load waits on its mount for, kept until that load ends; the card mounts the page for it
    private(set) var awaitingMount: URL?
    /// bumped by every load and stop; a load waiting on its mount starts only if still current
    @ObservationIgnored private var loadTicket = 0

    private func openArchive(_ file: URL) {
        let ticket = loadTicket
        Task {
            do {
                let reader = try await WebArchiveReader(file: file)
                guard loadTicket == ticket else { return }
                replaceWebView(with: reader.configuration())
                self.reader = reader
                requestedNavigation = webView.load(URLRequest(url: reader.page))
            } catch {
                guard loadTicket == ticket else { return }
                if reader != nil { replaceWebView(with: BrowserTab.defaultConfiguration(dataStore: dataStore)) }
                loadError = (error as? WebArchiveReader.Failure ?? .unreadable).message
            }
        }
    }

    /// an extension's page loads only in a web view built from its context's configuration
    /// (elsewhere WebKit fails it with -1008); nil when this view can already load it
    private func extensionPageConfiguration(for url: URL) -> WKWebViewConfiguration? {
        guard url.scheme?.hasSuffix("-extension") == true,
            webView.url.map({ $0.scheme == url.scheme && $0.host() == url.host() }) != true
        else { return nil }
        return WebExtensionRuntime.controller(for: ProfileStore.proxyProfile(of: dataStore))
            .extensionContext(for: url)?.pageConfiguration
    }

    func retry() {
        if let lastAttemptedURL {
            load(reloadable(lastAttemptedURL))
        }
    }

    /// an extension's page can't load once its extension is off; the page it covered stands in
    private func reloadable(_ page: URL) -> URL {
        guard let pageUnderExtension, page.scheme?.hasSuffix("-extension") == true,
            WebExtensionRuntime.controllers[ProfileStore.proxyProfile(of: dataStore)]?.extensionContext(for: page) == nil
        else { return page }
        return pageUnderExtension
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
        var name = displayTitle.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-").trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        // APFS caps a file name at 255 UTF-16 units; this leaves room for " (NN).webarchive"
        var units = 0
        name = String(name.prefix { units += $0.utf16.count; return units <= 200 })
        let ext =
            switch kind {
            case .pdf: "pdf"
            case .webArchive: "webarchive"
            case .fullPageImage: "png"
            }
        let file = DownloadItem.uniqueURL(for: DownloadManager.defaultFolder.appendingPathComponent("\(name.isEmpty ? "Page" : name).\(ext)"))
        // claimed before the awaits below, so an export started meanwhile picks another name
        FileManager.default.createFile(atPath: file.path, contents: nil)
        do {
            switch kind {
            case .pdf:
                try await webView.pdf(configuration: WKPDFConfiguration()).write(to: file)
            case .webArchive:
                try await withCheckedThrowingContinuation { done in
                    webView.createWebArchiveData { done.resume(with: $0) }
                }.write(to: file)
            case .fullPageImage:
                guard let image = await fullPageSnapshot()?.cgImage(forProposedRect: nil, context: nil, hints: nil)
                else { throw CocoaError(.fileWriteUnknown) }
                try await Self.writePNG(image, to: file)
            }
        } catch {
            try? FileManager.default.removeItem(at: file)
            let alert = NSAlert()
            alert.messageText = "The page couldn't be exported."
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            if let window = webView.window {
                alert.beginSheetModal(for: window, completionHandler: nil)
            } else {
                alert.runModal()
            }
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([file])
    }

    /// PNG-encodes `image` straight into `file`, off the main actor
    @concurrent
    private nonisolated static func writePNG(_ image: CGImage, to file: URL) async throws {
        guard let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }

    /// the whole document, not just the viewport, capped at 6000×24000pt and 1600pt wide
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
    func reload() {
        if let url, reloadable(url) != url { load(reloadable(url)) } else { webView.reload() }
    }

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
        loadTicket += 1
        stopRequested = true
        endRequestedLoad()
        madeWebView?.stopLoading()
        userAgentDecisions += 1
        if madeWebView != nil { matchUserAgent() }
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
    var isInspectorVisible: Bool { madeWebView != nil && inspectorSPI?.isVisible == true }

    /// ⌥⌘I / menu: open this tab's Web Inspector, or close it if already up. The page is
    /// inspectable, Safari's Develop menu included, only while this has it open
    func toggleInspector() {
        guard let inspector = inspectorSPI else { return }
        if inspector.isVisible { return closeInspector() }
        webView.isInspectable = true
        inspector.show()
        // a docked inspector never paints inside the rounded card
        inspector.detach()
    }

    func closeInspector() {
        if let inspector = inspectorSPI, inspector.isVisible { inspector.close() }
        webView.isInspectable = false
    }

    // MARK: - State mirroring

    /// the main frame's committed url, same-document changes included; SPI, else `webView.url`
    private var committedURL: URL? {
        guard let webView = madeWebView else { return nil }
        guard webView.responds(to: Selector(("_committedURL"))) else { return webView.url }
        return webView.spiValue(forKey: "_committedURL") as? URL
    }

    private func adoptCommittedURL() {
        let committed = reader.map(\.file) ?? committedURL
        guard committed != url else { return }
        movedFromHome = !isOffPinnedURL && requestedURL == nil
        url = committed
        if let committed { addressText = committed.absoluteString }
        hasUnsavedState = true
        ExtensionManager.shared.tabDidChange(.URL, for: self)
    }

    /// no press in the page since home was asked for, nor in the last 20 s, and no agent driving it
    private var movesUnpressed: Bool {
        let window = min(20, Date().timeIntervalSince(homeLoadStarted))
        return agentGate == nil && madeWebView.flatMap { UserGesture.recent(in: $0, within: window) } == nil
    }

    /// home's page moving itself stays home: within home's site at any time, onto another only as home loads
    private func adoptHomeLanding(own: Bool) {
        defer { movedFromHome = false }
        guard own, isOffPinnedURL, let url, let pinnedURL,
            Self.site(of: url) == Self.site(of: pinnedURL) || Date().timeIntervalSince(homeLoadStarted) < 20
        else { return }
        homeLanding = url
    }

    private func observeWebView() {
        observations = [
            // no `.initial`: a swapped-in empty view must not overwrite the page's title
            webView.observe(\.title, options: [.new]) { [weak self] webView, _ in
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
            // `webView.url` runs ahead to a provisional load, which may never commit
            webView.observe(\.url, options: [.initial, .new]) { [weak self] webView, _ in
                guard let self else { return }
                self.adoptCommittedURL()
                // back on the committed page: the request was cancelled or stayed in the document
                if self.requestedURL != nil, webView.url == self.committedURL { self.endRequestedLoad() }
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
                if loading { self.progress = webView.estimatedProgress } else { self.endRequestedLoad() }
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
        // our proxy without its credentials yet fails rather than raise a system dialog;
        // the tabs reload once they land
        if space.isProxy() || space.authenticationMethod == "NSURLAuthenticationMethodHTTPProxy",
            let answer = ExtensionProxyBridge.shared.proxyChallengeAnswer(
                space, in: ProfileStore.proxyProfile(of: dataStore))
        {
            completionHandler(answer.disposition, answer.credential)
            return
        }
        // the only chance to keep the certificate: a load failure carries no trust
        if space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
            let trust = space.serverTrust
        {
            let host = space.host
            serverTrusts[host] = trust
            if certificateTrust?.applyException(to: trust, host: host, ephemeral: isPrivate) == true {
                if host == webView.url?.host() { exceptionHost = host }
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

    /// put the server's login to the user; credentials live for this session only. only the
    /// origin of the main frame's page or load may ask: a cross-origin subresource never does
    @MainActor
    private func askForCredentials(
        _ space: URLProtectionSpace,
        _ completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        // during a main-frame load `webView.url` is the url being loaded
        guard pendingDialog == nil, let page = webView.url, page.scheme == space.protocol,
            page.host()?.lowercased() == space.host.lowercased(),
            (page.port ?? (page.scheme == "https" ? 443 : 80)) == space.port
        else {
            return completionHandler(.cancelAuthenticationChallenge, nil)
        }
        pendingDialog = PageDialogRequest(kind: .httpAuth, message: "", host: space.host, url: page) {
            [weak self] answer in
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
        guard (action.spiValue(forKey: "blockedLoad") as? Bool) == true else { return }
        recordBlockedRequest(url, list: identifier)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        debugLog("didStartProvisionalNavigation url=\(webView.url?.absoluteString ?? "nil")")
        if navigation !== requestedNavigation { endRequestedLoad() }
        needsReload = false
        blockedRequests.removeAll()
        // the old page's frames are gone; anything they were playing has stopped
        resetFrameState()
        // dialog silencing is per page; reset here because `didCommit` can arrive
        // after the new document's first `alert()`
        suppressesDialogs = false
        dialogsThisPage = 0
        certificateFailure = nil
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
        committedAt = Date()
        committedDisguised = !(webView.customUserAgent ?? "").isEmpty
        BrowserWindows.shared.manager(for: webView.window)?.dropStaleHoveredLink(navigating: webView)
        endRequestedLoad()
        manager?.denyPermissions(of: self)
        adoptCommittedURL()
        adoptHomeLanding(own: navigatingAsHome)
        navigatingAsHome = false
        // every response before this commit has been decided
        userInitiatedFrames = []
        // about:blank holds its opener's origin
        if let committedURL, committedURL.scheme != "about",
            SitePermissionStore.originString(committedURL) != openerOrigin
        {
            openerOrigin = nil
        }
        serverTrusts = [:]
        guard reader == nil else { return }
        if Self.canSharePages { committedProcess = webView.spiValue(forKey: "_webProcessIdentifier") as? Int32 ?? 0 }
        webView.setSPIValue(true, forKey: "drawsBackground")
        webView.underPageBackgroundColor = nil
        if let exceptionHost, webView.url?.host() != exceptionHost { self.exceptionHost = nil }
        HomeEgg.pageDidCommit(webView, isSecure: isSecure, isPrivate: isPrivate)
        if appBadge != nil, SitePermissionStore.originString(webView.url) != appBadgeOrigin { appBadge = nil }
        syncZoomToSite()
        endPageTranslation()
        PasswordAutofill.shared.pageDidCommit(in: self)
        PasskeyBridge.shared.answer(nil, for: id)
        Autofill.shared.pageDidCommit(in: self)
        holdHistoryScroll()
    }

    @objc(_webView:navigation:didSameDocumentNavigation:)
    func webView(_ webView: WKWebView, navigation: WKNavigation?, didSameDocumentNavigation type: Int) {
        if type == 3 { holdHistoryScroll() }
        adoptCommittedURL()
        // 3 is a step through history, which is the person's
        adoptHomeLanding(own: type != 3 && movedFromHome && movesUnpressed)
    }

    /// WebKit restores a history item's scroll once, clamped to the page as it stands then, and a clamped
    /// restore holds a swipe's snapshot up until its 3 s watchdog; this lands the scroll once the page has
    /// grown back, until the user scrolls or 5 s pass, and drops the snapshot when it does
    private func holdHistoryScroll() {
        guard let item = webView.backForwardList.currentItem,
            let saved = (item.spiValue(forKey: "_scrollPosition") as? NSValue)?.pointValue, saved.y > 0
        else { return }
        let zoom = webView.pageZoom
        webView.callAsyncJavaScript(
            Self.holdScrollScript, arguments: ["x": saved.x / zoom, "y": saved.y / zoom], in: nil, in: .defaultClient
        ) { [weak self] landed in
            let reset = Selector(("_resetNavigationGestureStateForTesting"))
            guard let view = self?.webView, (try? landed.get()) as? Bool == true, view.backForwardList.currentItem === item,
                view.spiValue(forKey: "_isShowingNavigationGestureSnapshot") as? Bool == true, view.responds(to: reset)
            else { return }
            view.perform(reset)
        }
    }

    private static let holdScrollScript = """
        return new Promise(done => {
          const inputs = ['wheel', 'keydown', 'mousedown', 'touchstart']
          const stop = () => {
            clearTimeout(timer)
            grown.disconnect()
            for (const t of inputs) removeEventListener(t, stop, true)
            done(false)
          }
          const hold = () => {
            if (history.scrollRestoration === 'manual') return stop()
            if (scrollY >= y - 1 || document.documentElement.scrollHeight - innerHeight < y - 1) return
            scrollTo(x, y)
            done(true)
          }
          const grown = new ResizeObserver(hold)
          const timer = setTimeout(stop, 5000)
          for (const t of inputs) addEventListener(t, stop, { capture: true, passive: true })
          grown.observe(document.documentElement)
        })
        """

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        debugLog("didFinish url=\(webView.url?.absoluteString ?? "nil")")
        wakeStill = nil
        loadError = nil
        guard reader == nil else { return }
        fetchFavicon()
        probeReaderAvailability()
        PasswordAutofill.shared.pageDidFinish(in: self)
        Task { await translateIfRuled() }
        if let url = webView.url, url.scheme == "http" || url.scheme == "https" {
            onDidNavigate?(url, webView.title?.isEmpty == false ? webView.title! : (url.host() ?? url.absoluteString))
            // focus the loaded page, as Safari does, so `document.hasFocus()` holds;
            // never the hidden tab, or while a field editor holds first responder
            if let window = webView.window, window.isKeyWindow,
                BrowserWindows.shared.manager(for: window)?.selectedTab === self,
                !(window.firstResponder is NSText) {
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
        wakeStill = nil
        if navigation === requestedNavigation { endRequestedLoad() }
        if let navigation, navigationDecisions.object(forKey: navigation)?.intValue == userAgentAllowed {
            matchUserAgent()
        }
        handleLoadError(error)
    }

    private func endRequestedLoad() {
        requestedNavigation = nil
        requestedURL = nil
        if awaitingMount != nil { awaitingMount = nil }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        wakeStill = nil
        handleLoadError(error)
    }

    /// WebKit calls this in place of the public method. `reason` is a `_WKProcessTerminationReason`:
    /// 0 memory limit, 1 CPU limit, 2 asked for, 3 crash, 4 shared-process crash limit; 3 and 4 are reported
    @objc(_webView:webContentProcessDidTerminateWithReason:)
    func webView(_ webView: WKWebView, processEndedWithReason reason: Int) {
        if reason == 3 || reason == 4 {
            let kind = isEssential ? "favourite" : isPinned ? "pinned tab" : "tab"
            let isShown = BrowserWindows.shared.allManagers.contains { $0.onScreenTabIDs.contains(id) }
            Diagnostics.record(
                area: "webcontent",
                message: "web content process \(reason == 4 ? "hit the crash limit" : "crashed"): \(kind), "
                    + (isShown ? "on screen" : "in the background"),
                inPrivate: isPrivate)
        }
        // WebKit's own limit on a shared process crashing is a loop already
        if reason == 4 { lastCrash = .now }
        webViewWebContentProcessDidTerminate(webView)
    }

    /// WebKit's own timer: the page's process has left a message unanswered for about 3 s
    @objc(_webViewWebProcessDidBecomeUnresponsive:)
    func webViewWebProcessDidBecomeUnresponsive(_ webView: WKWebView) {
        let pid = webView.spiValue(forKey: "_webProcessIdentifier") as? Int32 ?? 0
        let sharing = BrowserWindows.shared.allManagers.lazy.flatMap(\.allTabs).filter { pid != 0 && $0.committedProcess == pid }.count
        let isShown = BrowserWindows.shared.allManagers.contains { $0.onScreenTabIDs.contains(id) }
        let workers = BrowserTab.processPool.spiValue(forKey: "_serviceWorkerProcessCount") as? Int ?? 0
        Diagnostics.record(
            area: "webcontent",
            message: "page stopped answering: \(isShown ? "on screen" : "in the background"), "
                + "\(webView.window == nil ? "unmounted" : "in a window"), \(webView.isLoading ? "loading" : "loaded"), "
                + "pid \(pid) holding \(sharing) tabs, \(workers) worker processes",
            level: .warning, inPrivate: isPrivate)
    }

    /// a page on screen reloads at once; one off screen reloads when next shown.
    /// a second crash within a minute of a page alone in its process stops the loop
    /// at the error page; a shared process can't say whose page took it down
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        debugLog("web content process terminated: \(url?.absoluteString ?? "-")")
        abandonDialog()
        resetFrameState()
        let now = Date()
        let alone =
            committedProcess == 0
            || !BrowserWindows.shared.allManagers.lazy.flatMap(\.allTabs).contains {
                $0 !== self && $0.committedProcess == committedProcess
            }
        defer { if alone { lastCrash = now } }
        if let lastCrash, now.timeIntervalSince(lastCrash) < 60 {
            lastAttemptedURL = url ?? lastAttemptedURL
            loadError = Self.crashLoopError
            return
        }
        reloadWhenShown()
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
        // a link, redirect or back/forward fails without passing through `load`
        if let failing = nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL, failing != lastAttemptedURL {
            lastAttemptedURL = failing
            // with nothing committed, `lastAttemptedURL` is where the tab reads as being
            if url == nil, navigatingAsHome { homeLanding = failing }
        }
        loadError = nsError.localizedDescription
        if !CertificateTrust.isOverridable(nsError) {
            certificateFailure = nil
        } else if let host = lastAttemptedURL?.host(),
            certificateTrust?.requiresSecureConnection(host, ephemeral: isPrivate) ?? true
        {
            certificateFailure = .final
        } else {
            certificateFailure = .overridable
        }
        if let host = lastAttemptedURL?.host() {
            title = host
        }
    }

    /// accept the certificate this host last presented, then reload; scoped to
    /// that one certificate by `SecTrustCopyExceptions`
    @MainActor
    func acceptCertificateAndRetry() {
        guard certificateFailure == .overridable,
            let host = lastAttemptedURL?.host(), let trust = serverTrusts[host],
            certificateTrust?.addException(for: host, trust: trust, ephemeral: isPrivate) == true
        else { return }
        certificateFailure = nil
        retry()
    }

    // MARK: Downloads

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        preferences: WKWebpagePreferences
    ) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        if let reader { return (decide(navigationAction, in: reader), preferences) }
        let source = Self.sourceFrame(of: navigationAction)
        let userInitiated = navigationAction.spiValue(forKey: "_isUserInitiated") as? Bool == true
        if let frame = Self.handle(of: navigationAction.targetFrame) {
            if userInitiated { userInitiatedFrames.insert(frame) } else { userInitiatedFrames.remove(frame) }
        }
        let mainFrame = navigationAction.targetFrame?.isMainFrame == true
        if mainFrame { await ContentBlocker.shared.untilRulesSettled() }
        let redirect = navigationAction.spiValue(forKey: "_isRedirect") as? Bool == true
        if mainFrame, !redirect { userAgentDecisions += 1 }
        let decision = userAgentDecisions
        // a script Artemis runs in the page carries a user gesture too; only a press in the view is the user's
        let pressed = userInitiated ? UserGesture.recent(in: webView, within: 2) : nil
        if let agentGate, navigationAction.request.url != requestedURL, !agentGate(navigationAction, pressed) {
            return (.cancel, preferences)
        }
        // a link that asks to be downloaded is, whatever is held
        if navigationAction.shouldPerformDownload {
            let allowed = await mayDownload(
                navigationAction.request.url.flatMap { $0.scheme?.hasPrefix("http") == true ? $0.lastPathComponent : nil } ?? "",
                from: source.map { SitePermissionStore.originString($0.securityOrigin) }, userInitiated: userInitiated)
            return (allowed ? .download : .cancel, preferences)
        }
        // only a person's click is re-routed (new tab, Scout, a linked pane): those loads count as the
        // app's own. a scripted click runs as a plain navigation; without the SPI every click routes
        let routable = userInitiated || !navigationAction.responds(to: Selector(("_isUserInitiated")))
        if navigationAction.navigationType == .linkActivated, routable, let url = navigationAction.request.url {
            // WebKit reports the button as a mask bit: 1 << 2 is the middle one
            let middle = navigationAction.buttonNumber == 1 << 2
            if let click = LinkClick.route(navigationAction.modifierFlags, middle: middle) {
                onOpenLink?(url, click)
                return (.cancel, preferences)
            }
            // a linked split pane loads plain link clicks in its pair, except a frame's
            // own navigation and a jump within the page
            let toPage = navigationAction.targetFrame?.isMainFrame ?? true
            let inPage = url.fragment != nil
                && url.absoluteString.prefix { $0 != "#" } == webView.url?.absoluteString.prefix { $0 != "#" }
            if toPage, !inPage, manager?.routeLinkedNavigation(from: self, to: url) == true {
                return (.cancel, preferences)
            }
            // a favourite or pinned tab keeps its page: a link to another site opens in Peek
            if isPinned || isEssential, TabManager.pinnedLinksPeek, navigationAction.targetFrame?.isMainFrame == true,
                url.scheme == "https" || url.scheme == "http",
                TabManager.baseDomain(of: url) != webView.url.flatMap(TabManager.baseDomain)
            {
                onOpenLink?(url, .peek)
                return (.cancel, preferences)
            }
        }
        // a scheme WebKit doesn't render belongs to another app
        if let url = navigationAction.request.url, !ExternalSchemes.isInternal(url.scheme) {
            // only the main frame or a new window may ask; a subframe is cancelled silently
            let fromMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
            // the asking frame's host; a new window's first load may name none, so its opener's
            let asker = source?.securityOrigin.host ?? ""
            let site = asker.isEmpty ? openerOrigin.flatMap { URL(string: $0)?.host() } ?? "" : asker
            if fromMainFrame, ExternalSchemes.canOffer(url) {
                if spendLaunch() {
                    offerExternal(url, site: site)
                } else if launchOwed != .distantPast {
                    // a launch owed past its window asks once, and never opens unasked
                    launchOwed = .distantPast
                    offerExternal(url, site: site, unasked: false)
                }
            }
            return (.cancel, preferences)
        }
        // an extension's page a web page may open loads in a view of the extension's, a new one: nothing of
        // the page left comes along. the page is the tab's own when its main frame asks; a tab that has
        // shown nothing has its opener, else the address it was sent to
        if mainFrame, source?.isMainFrame != false, !isExtensionView, let url = navigationAction.request.url,
            url != lastAttemptedURL, url.scheme?.hasSuffix("-extension") == true, mayOpen(url)
        {
            DispatchQueue.main.async { [weak self] in self?.load(url) }
            return (.cancel, preferences)
        }
        // a site an extension's page goes to loads in a browser web view, not the extension's
        if mainFrame, isExtensionView, let url = navigationAction.request.url,
            url.scheme == "https" || url.scheme == "http"
        {
            DispatchQueue.main.async { [weak self] in self?.load(url) }
            return (.cancel, preferences)
        }
        let navigation = mainFrame ? navigationAction.spiValue(forKey: "_mainFrameNavigation") as? WKNavigation : nil
        // a process that starts a load on one site and commits another can't host either's service
        // worker, and a worker-only process exits on every memory warning and relaunches at once:
        // a cross-site redirect restarts as a load of its own in a fresh process
        if let navigation, let url = navigationAction.request.url, let site = Self.site(of: url) {
            if !redirect {
                // a restart is a browser load (Sec-Fetch-Site none, no Strict cookies): a script's link keeps its initiator
                let ours =
                    navigation === requestedNavigation || navigation === restarted
                    || navigationAction.navigationType == .linkActivated && userInitiated
                restartable = ours && !isOpenedByPage ? (navigation, site) : nil
                if navigation !== restarted { restarts = 0 }
            } else if let start = restartable, start.navigation === navigation, start.site != site, restarts < 3,
                navigationAction.request.httpMethod == "GET", navigationAction.request.httpBody == nil,
                !allowedDisguised
            {
                restarts += 1
                let request = navigationAction.request
                let wasRequested = navigation === requestedNavigation
                DispatchQueue.main.async { [weak self] in
                    guard let self, webView === madeWebView else { return }
                    restarted = webView.load(request)
                    if wasRequested {
                        requestedNavigation = restarted
                        requestedURL = url
                    }
                }
                return (.cancel, preferences)
            }
        }
        // set here, the UA already reaches this navigation's own request
        if mainFrame {
            let url = navigationAction.request.url
            // a redirect out of a disguised load stays disguised
            let on = (url?.scheme == "https" || url?.scheme == "http")
                && (ChromeDisguise.isOn(for: url?.host(), ephemeral: isPrivate)
                    || redirect && decision == userAgentAllowed && allowedDisguised)
            if on { await ChromeDisguise.attach(to: webView.configuration.userContentController) }
            guard decision == userAgentDecisions else { return (.cancel, preferences) }
            if !redirect, navigation !== restarted {
                let type = navigationAction.navigationType
                // a load asked of the web view shows in `webView.url` before it is decided; a page's own doesn't
                if navigation === requestedNavigation || type == .reload || webView.url == url && url != committedURL {
                    navigatingAsHome = url.map { !isOffHome($0) } ?? false
                    if navigatingAsHome { homeLoadStarted = Date() }
                } else {
                    navigatingAsHome = !userInitiated && type != .backForward && !isOffPinnedURL && movesUnpressed
                }
            }
            userAgentAllowed = decision
            allowedDisguised = on
            matchUserAgent(on)
            if let navigation { navigationDecisions.setObject(decision as NSNumber, forKey: navigation) }
            ChromeDisguise.gate(preferences, on: on)
            ContentBlocker.shared.gate(preferences, for: url, ephemeral: isPrivate)
        }
        return (navigation != nil && navigation === restarted ? Self.allowInNewProcess : .allow, preferences)
    }

    /// `_WKNavigationActionPolicyAllowInNewProcess`
    private static let allowInNewProcess = WKNavigationActionPolicy(rawValue: WKNavigationActionPolicy.allow.rawValue + 3)!

    /// Chrome's rule for this tab's page sending any tab to `url`, whatever the click: an extension's
    /// page only as `WebExtensionRuntime.opens` allows, unless it is the extension's own page asking
    func mayOpen(_ url: URL) -> Bool {
        guard url.scheme?.hasSuffix("-extension") == true, !isExtensionView || webView.url?.host() != url.host()
        else { return true }
        return WebExtensionRuntime.opens(
            url, to: committedURL ?? openerOrigin.flatMap { URL(string: $0) } ?? lastAttemptedURL,
            in: ProfileStore.proxyProfile(of: dataStore), isPrivate: isPrivate)
    }

    /// the saved copy loads only what the archive holds; a link the person clicks opens the live page in a tab
    private func decide(_ action: WKNavigationAction, in reader: WebArchiveReader) -> WKNavigationActionPolicy {
        guard let url = action.request.url else { return .cancel }
        if reader.serves(url), action.navigationType != .linkActivated || action.targetFrame?.isMainFrame == false {
            return .allow
        }
        let inPage = url.fragment != nil && url.absoluteString.prefix { $0 != "#" } == reader.page.absoluteString
        if inPage { return .allow }
        if action.navigationType == .linkActivated, url.scheme == "https" || url.scheme == "http" {
            let middle = action.buttonNumber == 1 << 2
            onOpenLink?(url, LinkClick.route(action.modifierFlags, middle: middle) ?? .foregroundTab)
        }
        return .cancel
    }

    /// sets the UA for `disguised`, or else for the committed page
    private func matchUserAgent(_ disguised: Bool? = nil) {
        let on = disguised ?? committedDisguised
        let wanted = on ? ChromeDisguise.userAgent : ""
        if (webView.customUserAgent ?? "") != wanted { webView.customUserAgent = wanted }
    }

    /// anything the engine can't render inline becomes a download
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse
    ) async -> WKNavigationResponsePolicy {
        let response = navigationResponse.response
        debugLog(
            "navigationResponse url=\(response.url?.absoluteString ?? "nil") "
                + "mime=\(response.mimeType ?? "nil") "
                + "canShow=\(navigationResponse.canShowMIMEType)")
        let http = response as? HTTPURLResponse
        if let http, let host = response.url?.host(), response.url?.scheme == "https",
            let header = http.value(forHTTPHeaderField: "Strict-Transport-Security"),
            let certificateTrust, !certificateTrust.hasException(for: host, ephemeral: isPrivate)
        {
            certificateTrust.noteStrictTransport(header, host: host, ephemeral: isPrivate)
        }

        if reader != nil { return navigationResponse.canShowMIMEType ? .allow : .cancel }
        // a web archive's page would run as the site the file names: only a local one opens, in the reader
        if response.mimeType?.lowercased() == "application/x-webarchive" {
            if navigationResponse.isForMainFrame, let url = response.url {
                lastAttemptedURL = url
                if url.isFileURL {
                    DispatchQueue.main.async { [weak self] in self?.openArchive(url) }
                } else {
                    loadError = Self.webArchiveError
                }
            }
            return .cancel
        }

        // an attachment downloads even when its mime type is displayable
        let attachment =
            http?.value(forHTTPHeaderField: "Content-Disposition")?.lowercased().contains("attachment") == true
        guard attachment || !navigationResponse.canShowMIMEType else { return .allow }
        // SPI: the frame that started the navigation, not always the one it loads in; nil when the app did
        let initiator: String?
        if navigationResponse.responds(to: Selector(("_navigationInitiatingFrame"))) {
            initiator = (navigationResponse.spiValue(forKey: "_navigationInitiatingFrame") as? WKFrameInfo).map {
                SitePermissionStore.originString($0.securityOrigin)
            }
        } else if navigationResponse.isForMainFrame {
            initiator = nil
        } else {
            // a subframe's own response stands in, where a blob's origin is the one inside it
            let loaded = response.url.flatMap {
                $0.scheme == "blob" ? URL(string: String($0.absoluteString.dropFirst(5))) : $0
            }
            initiator = SitePermissionStore.originString(loaded) ?? ""
        }
        let frame = Self.handle(of: navigationResponse.spiValue(forKey: "_frame") as? WKFrameInfo)
        let userInitiated = frame.flatMap { userInitiatedFrames.remove($0) } != nil
        // a load an agent may have started is asked about like the page's own
        let started = navigationResponse.isForMainFrame && requestedURL != nil && agentName == nil
        let file = response.suggestedFilename ?? response.url?.lastPathComponent ?? ""
        return await mayDownload(file, from: initiator, userInitiated: userInitiated, appStarted: started)
            ? .download : .cancel
    }

    /// a download goes ahead for a load the app started, on the site's allow where no agent drives the tab, or on a press in this
    /// tab's page, or the opener's press that opened it, that no other download spent. a frame from another
    /// origin is never asked about, and its press counts only on a navigation WebKit saw the user start
    private func mayDownload(
        _ file: String, from initiator: String?, userInitiated: Bool, appStarted: Bool = false
    ) async -> Bool {
        let site = SitePermissionStore.originString(committedURL) ?? openerOrigin
        let decision = site.flatMap { sitePermissions?.decision(for: $0, .downloads, ephemeral: isPrivate) }
        let press = (UserGesture.recent(in: webView, within: Self.gestureWindow) ?? openerPress).flatMap {
            $0 > spentDownloadGesture && Date().timeIntervalSince($0) < Self.gestureWindow ? $0 : nil
        }
        guard decision != .deny else {
            // a file the person asked for shows as blocked; a page's own attempts stay silent
            if let press { spentDownloadGesture = press }
            if press != nil || appStarted { DownloadManager.shared.refuse(file, isPrivate: isPrivate) }
            return false
        }
        if appStarted { return true }
        let crossOrigin = initiator.map { $0 != site && $0 != openerOrigin } ?? false
        if let press, userInitiated || !crossOrigin {
            spentDownloadGesture = press
            return true
        }
        guard !crossOrigin else { return false }
        if decision == .allow, agentName == nil { return true }
        guard let site, let manager else { return false }
        return await withCheckedContinuation { asked in
            manager.requestPermission([.downloads], origin: site, tab: self) { asked.resume(returning: $0 == .allow) }
        }
    }

    /// `sourceFrame` is declared nonnull, but is nil for a load the app started
    private static func sourceFrame(of action: WKNavigationAction) -> WKFrameInfo? {
        action.value(forKey: "sourceFrame") as? WKFrameInfo
    }

    /// SPI `_WKFrameHandle`: equal for every info of one frame
    private static func handle(of frame: WKFrameInfo?) -> NSObject? {
        frame?.spiValue(forKey: "_handle") as? NSObject
    }

    func webView(
        _ webView: WKWebView,
        navigationAction: WKNavigationAction,
        didBecome download: WKDownload
    ) {
        debugLog("navigationAction didBecome download")
        DownloadManager.shared.register(download)
    }

    func webView(
        _ webView: WKWebView,
        navigationResponse: WKNavigationResponse,
        didBecome download: WKDownload
    ) {
        debugLog("navigationResponse didBecome download")
        DownloadManager.shared.register(download)
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
                host: host, declaredIconURL: declared, profile: ProfileStore.proxyProfile(of: self.dataStore),
                isPrivate: self.isPrivate)
        }
    }
}

// MARK: - WKUIDelegate

extension BrowserTab: WKUIDelegate {
    /// WebKit's own Download Image and Download Linked File items hand their download here
    @objc(_webView:contextMenuDidCreateDownload:)
    func webView(_ webView: WKWebView, contextMenuDidCreateDownload download: WKDownload) {
        DownloadManager.shared.register(download)
    }

    /// the PDF viewer's own download button hands over the document it already holds
    @objc(_webView:saveDataToFile:suggestedFilename:mimeType:originatingURL:)
    func webView(
        _ webView: WKWebView, saveDataToFile data: Data, suggestedFilename: String, mimeType: String,
        originatingURL: URL?
    ) {
        DownloadManager.shared.save(data, as: suggestedFilename, from: originatingURL, in: webView)
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        let opened = onRequestNewTab?(configuration, windowFeatures)
        if let tab = opened?.navigationDelegate as? BrowserTab {
            tab.isOpenedByPage = true
            tab.openerOrigin = Self.sourceFrame(of: navigationAction).map { SitePermissionStore.originString($0.securityOrigin) }
            tab.agentGate = agentGate
            // a link's press moves to the page it opens and still lets through one file; a script's stays here
            if navigationAction.navigationType == .linkActivated,
                let press = UserGesture.recent(in: webView, within: Self.gestureWindow), press > spentDownloadGesture
            {
                tab.openerPress = press
                spentDownloadGesture = press
            }
            if let press = UserGesture.recent(in: webView, within: Self.gestureWindow), press > spentLaunchGesture {
                tab.launchOwed = press
                spentLaunchGesture = press
            }
        }
        return opened
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
        isChoosingFile = true
        let answer = { [weak self] (urls: [URL]?) in
            guard !answered else { return }
            answered = true
            self?.isChoosingFile = false
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

    /// map the input's `accept` list onto `UTType`s for the picker; dynamic types are
    /// dropped because no file conforms to one, which greys out the whole panel
    private static func acceptedTypes(_ parameters: WKOpenPanelParameters) -> [UTType] {
        let spi = unsafeBitCast(parameters, to: WKOpenPanelParametersSPI.self)
        var types: [UTType] = []
        if parameters.responds(to: Selector(("_acceptedMIMETypes"))) {
            types += spi._acceptedMIMETypes.compactMap { mime in
                switch mime.lowercased() {
                case "image/*": .image
                case "video/*": .movie
                case "audio/*": .audio
                default: UTType(mimeType: mime)
                }
            }
        }
        if parameters.responds(to: Selector(("_acceptedFileExtensions"))) {
            types += spi._acceptedFileExtensions.compactMap {
                UTType(filenameExtension: $0.hasPrefix(".") ? String($0.dropFirst()) : $0)
            }
        }
        return types.filter { !$0.isDynamic }
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
            if !answer.confirmed {
                self?.onConfirmedClose = nil
                self?.matchUserAgent()
            }
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

    /// one app launch for the owner's acts so far: a load the app started, the press that opened
    /// this page, a press in it within the window. a launch spends them all
    private func spendLaunch() -> Bool {
        let press = UserGesture.recent(in: webView, within: Self.gestureWindow)
        guard Date().timeIntervalSince(launchOwed) < Self.gestureWindow || press.map({ $0 > spentLaunchGesture }) == true
        else { return false }
        launchOwed = .distantPast
        if let press { spentLaunchGesture = press }
        return true
    }

    /// hand a link in a scheme WebKit can't render to its app, once the user agrees. `site` is the
    /// host of the frame that asked, empty when none is known
    @MainActor
    private func offerExternal(_ url: URL, site: String, unasked: Bool = true) {
        let scheme = url.scheme?.lowercased() ?? ""
        // a link nothing installed opens is dropped unasked
        guard let appName = ExternalSchemes.handlerName(for: url) else { return }
        let trusted = unasked && !isPrivate
            && ExternalSchemes.isAllowed(site: site, scheme: scheme, in: ProfileStore.proxyProfile(of: dataStore))
        guard !trusted else { return ExternalSchemes.open(url) }
        guard pendingDialog == nil else { return }
        pendingDialog = PageDialogRequest(
            kind: .openExternal(scheme: scheme, appName: appName), message: "",
            host: site,
            // incognito and a page with no site ask every time
            checkbox: isPrivate || site.isEmpty ? nil : .rememberChoice
        ) { [weak self] answer in
            self?.pendingDialog = nil
            guard answer.confirmed else { return }
            ExternalSchemes.open(url)
        }
    }

    /// answer from the panel. `checked` is the "stop showing these" checkbox; `trustEveryApp` is the
    /// trust picked for an app link: false for this app, true for every app, nil for this once
    @MainActor
    func answerDialog(
        _ confirmed: Bool, text: String = "", secondary: String = "", checked: Bool = false, trustEveryApp: Bool? = nil
    ) {
        guard let dialog = pendingDialog else { return }
        if confirmed, case .openExternal = dialog.kind,
            Duration.seconds(Date().timeIntervalSince(dialog.asked)) < PermissionPrompt.armDelay
        { return }
        if dialog.checkbox == .silencePage, checked { suppressesDialogs = true }
        if dialog.checkbox == .rememberChoice, confirmed, let trustEveryApp, case .openExternal(let scheme, _) = dialog.kind {
            ExternalSchemes.allow(
                site: dialog.host, scheme: trustEveryApp ? ExternalSchemes.everyApp : scheme,
                in: ProfileStore.proxyProfile(of: dataStore))
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

    func webView(for context: WKWebExtensionContext) -> WKWebView? { madeWebView }

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
        manager?.focus(self)
    }

    @MainActor
    func setSelected(_ selected: Bool, for context: WKWebExtensionContext) async throws {
        if selected { try await activate(for: context) }
    }

    @MainActor
    func setPinned(_ pinned: Bool, for context: WKWebExtensionContext) async throws {
        guard isPinned != pinned, let manager else { return }
        manager.togglePin(self)
    }

    @MainActor
    func loadURL(_ url: URL, for context: WKWebExtensionContext) async throws {
        if url.isFileURL { throw ExtensionManager.fileURLRefused }
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

    func zoomFactor(for context: WKWebExtensionContext) -> Double { zoomLevel }

    @MainActor
    func setZoomFactor(_ zoomFactor: Double, for context: WKWebExtensionContext) async throws { setZoom(zoomFactor) }

    @MainActor
    func close(for context: WKWebExtensionContext) async throws {
        manager?.close(self)
    }
}
