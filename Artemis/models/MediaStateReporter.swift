// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import WebKit

/// a frame's controllable media: an unmuted element playing, or paused mid-track,
/// with the title the page declared in `navigator.mediaSession.metadata`
struct PageMedia: Equatable {
    var isPlaying: Bool
    var title: String
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

/// per-frame playback state, keyed by frame identity so a Shorts swipe's url change keeps it.
/// `_isPlayingAudio` is false for a muted video, so a script reports instead; it runs in the
/// page world, the only place the `mediaSession` handlers it captures and invokes exist
final class MediaStateReporter: NSObject, WKScriptMessageHandler {
    private static let messageName = "artemisMediaState"

    /// (webView that sent it, its frame, frame key, is that frame playing, its controllable media)
    private let onChange: (WKWebView, WKFrameInfo, AnyHashable, Bool, PageMedia?) -> Void

    init(onChange: @escaping (WKWebView, WKFrameInfo, AnyHashable, Bool, PageMedia?) -> Void) {
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
        let frame = LoginKeys.key(message.frameInfo)
        let media = (body["session"] as? [String: Any]).map { s in
            PageMedia(
                isPlaying: s["playing"] as? Bool ?? false,
                title: s["title"] as? String ?? "",
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
          var md = ms && ms.metadata;
          s = {playing: !m.paused, title: (md && md.title) || '',
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
