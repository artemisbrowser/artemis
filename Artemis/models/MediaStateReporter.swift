import WebKit

/// a frame's controllable media: an unmuted element playing, or paused mid-track,
/// with whatever `navigator.mediaSession.metadata` the page declared
struct PageMedia: Equatable {
    var isPlaying: Bool
    var title: String
    var artist: String
    var album: String
    var artwork: URL?
    /// the page registered previous/next-track handlers
    var hasTracks: Bool
    /// stamped by the owning tab each time playback (re)starts
    var startedAt = Date.distantPast

    /// playing beats paused, then the most recently started wins
    var rank: (Int, Date) { (isPlaying ? 1 : 0, startedAt) }
}

/// what the Now Playing card can ask of a page. resolved in the page: its own
/// `mediaSession` handler when registered, else the media element (seeks of the seconds given, else 10)
enum MediaCommand: String {
    case toggle, back, forward
}

/// Reports which tabs are playing audio or video, for the sidebar's speaker
/// indicator, the mute control and the Now Playing card.
///
/// WebKit knows this internally (`_isPlayingAudio`) but that SPI is false for a
/// *muted* video — which is exactly the tab you still want an (un)mute control
/// on — and it isn't reliably KVO-observable. So playback state comes from the
/// page instead: one persistent user script installed on the shared content
/// controller listens for media events in every frame of every tab and posts a
/// state change. Event-driven, so idle tabs cost nothing (no polling timer).
///
/// Frames report independently (a video is usually in an iframe), so each message
/// carries its frame's url and the tab keeps the set of frames currently playing;
/// the tab counts as playing while that set is non-empty.
///
/// The script runs in the page world: the `mediaSession` action handlers it
/// captures (and invokes for `MediaCommand`) only exist there.
final class MediaStateReporter: NSObject, WKScriptMessageHandler {
    static let messageName = "artemisMediaState"

    /// (webView that sent it, its frame, frame key, is that frame playing, its controllable media)
    private let onChange: (WKWebView, WKFrameInfo, String, Bool, PageMedia?) -> Void

    init(onChange: @escaping (WKWebView, WKFrameInfo, String, Bool, PageMedia?) -> Void) {
        self.onChange = onChange
    }

    static func install(into controller: WKUserContentController, handler: MediaStateReporter) {
        controller.add(handler, name: messageName)
        controller.addUserScript(
            WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false))
    }

    func userContentController(
        _ controller: WKUserContentController, didReceive message: WKScriptMessage
    ) {
        guard let webView = message.webView,
            let body = message.body as? [String: Any],
            let playing = body["playing"] as? Bool
        else { return }
        let frame = message.frameInfo.request.url?.absoluteString
            ?? (message.frameInfo.isMainFrame ? "main" : "sub")
        let media = (body["session"] as? [String: Any]).map { s in
            PageMedia(
                isPlaying: s["playing"] as? Bool ?? false,
                title: s["title"] as? String ?? "",
                artist: s["artist"] as? String ?? "",
                album: s["album"] as? String ?? "",
                artwork: (s["artwork"] as? String).flatMap(URL.init(string:)),
                hasTracks: s["tracks"] as? Bool ?? false)
        }
        onChange(webView, message.frameInfo, frame, playing, media)
    }

    private static let source = """
    (function(){
      if (window.__artemisMediaInstalled) return;
      window.__artemisMediaInstalled = true;
      var last = null, timer = null, handlers = {}, ms = navigator.mediaSession;
      function post(state){
        try { window.webkit.messageHandlers.artemisMediaState.postMessage(state); } catch (e) {}
      }
      function anyPlaying(){
        var els = document.querySelectorAll('video,audio');
        for (var i = 0; i < els.length; i++) {
          var m = els[i];
          if (!m.paused && !m.ended && m.readyState >= 2) return true;
        }
        return false;
      }
      // the element a Now Playing control acts on: unmuted, playing or paused mid-track
      function session(){
        var els = document.querySelectorAll('video,audio'), paused = null;
        for (var i = 0; i < els.length; i++) {
          var m = els[i];
          if (m.muted || m.volume === 0 || m.ended) continue;
          if (!m.paused && m.readyState >= 2) return m;
          if (!paused && m.currentTime > 0) paused = m;
        }
        return paused;
      }
      function snapshot(){
        var m = session(), s = null;
        if (m) {
          var md = ms && ms.metadata, list = (md && md.artwork) || [];
          // smallest artwork at least 64px wide, else the first listed
          var art = list.length ? list[0].src : '', w = Infinity;
          for (var i = 0; i < list.length; i++) {
            var n = parseInt(list[i].sizes, 10) || 0;
            if (n >= 64 && n < w) { art = list[i].src; w = n; }
          }
          s = {playing: !m.paused, title: (md && md.title) || '', artist: (md && md.artist) || '',
               album: (md && md.album) || '', artwork: art,
               tracks: !!(handlers.previoustrack || handlers.nexttrack)};
        }
        return {playing: anyPlaying(), session: s};
      }
      function report(){
        timer = null;
        var state = snapshot(), key = JSON.stringify(state);
        if (key === last) return;
        last = key;
        post(state);
      }
      function schedule(){
        if (timer) return;
        // coalesce the burst of events a player fires while starting up
        timer = setTimeout(report, 150);
      }
      if (ms) {
        var setHandler = ms.setActionHandler;
        ms.setActionHandler = function(action, fn){
          handlers[action] = fn;
          schedule();
          return setHandler.call(ms, action, fn);
        };
        var proto = Object.getPrototypeOf(ms), d = Object.getOwnPropertyDescriptor(proto, 'metadata');
        if (d && d.set) Object.defineProperty(proto, 'metadata', {
          configurable: true, enumerable: d.enumerable, get: d.get,
          set: function(v){ d.set.call(this, v); schedule(); }
        });
      }
      var actions = {play: ['play'], pause: ['pause'],
                     back: ['previoustrack', 'seekbackward'], forward: ['nexttrack', 'seekforward']};
      Object.defineProperty(window, '__artemisMedia', {value: function(c, seconds){
        var step = seconds > 0 ? seconds : 10;
        var m = session();
        if (c === 'toggle') c = m && !m.paused ? 'pause' : 'play';
        var names = actions[c] || [];
        for (var i = 0; i < names.length; i++) {
          var h = handlers[names[i]];
          if (h) { try { h({action: names[i], seekOffset: step}); } catch (e) {} return; }
        }
        if (!m) return;
        if (c === 'play') m.play().catch(function(){});
        else if (c === 'pause') m.pause();
        else if (names.length) m.currentTime = Math.max(0, m.currentTime + (c === 'back' ? -step : step));
      }});
      ['play','playing','pause','ended','emptied','loadeddata','abort','volumechange'].forEach(function(name){
        document.addEventListener(name, schedule, true);
      });
      // a page can be torn down mid-playback without ever firing 'pause'
      window.addEventListener('pagehide', function(){
        var gone = {playing: false, session: null}, key = JSON.stringify(gone);
        if (last !== null && last !== key) { last = key; post(gone); }
      });
    })();
    """
}
