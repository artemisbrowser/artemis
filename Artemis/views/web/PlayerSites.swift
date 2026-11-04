// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

/// what both apps' media controls know of particular players, as page-world script. `nativeCC(getVideo)`,
/// `youTubeCaptions` and `netflixCaptions` each list (id, label, lang), select and turn off caption tracks;
/// `skipAdSelectors` find an ad's skip control
nonisolated enum PlayerSites {
    static let script = """
      function nativeCC(getV) {
        // metadata and chapter tracks are never captions, and are left as the page set them
        function cc(t) { return t.kind === 'subtitles' || t.kind === 'captions'; }
        return {
          list: function () {
            var v = getV(), o = [];
            if (v && v.textTracks) for (var i = 0; i < v.textTracks.length; i++) {
              var t = v.textTracks[i];
              if (cc(t)) o.push({ id: String(i), label: t.label || t.language || ('Subtitles ' + (i + 1)), lang: t.language });
            }
            return o;
          },
          active: function () {
            var v = getV();
            if (v && v.textTracks) for (var i = 0; i < v.textTracks.length; i++) {
              var t = v.textTracks[i];
              if (cc(t) && (t.mode === 'showing' || t.mode === 'hidden')) return String(i);
            }
            return '';
          },
          select: function (id) {
            var v = getV(); if (!v || !v.textTracks) return;
            var idx = parseInt(id, 10);
            // 'hidden' keeps cues active (we render them) without browser drawing
            for (var i = 0; i < v.textTracks.length; i++)
              if (cc(v.textTracks[i])) v.textTracks[i].mode = (i === idx ? 'hidden' : 'disabled');
          },
          off: function () {
            var v = getV(); if (!v || !v.textTracks) return;
            for (var i = 0; i < v.textTracks.length; i++) if (cc(v.textTracks[i])) v.textTracks[i].mode = 'disabled';
          }
        };
      }

      var youTubeCaptions = (function () {
          function P() { return document.getElementById('movie_player') || document.querySelector('.html5-video-player'); }
          function trackName(t) {
            if (!t) return '';
            if (t.name) return t.name.simpleText || (t.name.runs && t.name.runs[0] && t.name.runs[0].text) || '';
            if (t.languageName && t.languageName.name) return t.languageName.name;
            return t.displayName || t.languageCode || '';
          }
          return {
            list: function () {
              var p = P(); if (!p) return [];
              // the player response lists every caption track before the captions module loads
              try {
                if (p.getPlayerResponse) {
                  var r = p.getPlayerResponse();
                  var ct = r && r.captions && r.captions.playerCaptionsTracklistRenderer
                    && r.captions.playerCaptionsTracklistRenderer.captionTracks;
                  if (ct && ct.length) return ct.map(function (t) {
                    var asr = t.kind === 'asr';
                    return { id: (t.languageCode || '') + (asr ? '.asr' : ''),
                      label: (trackName(t) || t.languageCode) + (asr ? ' (auto)' : ''), lang: t.languageCode };
                  });
                }
              } catch (e) {}
              try {
                if (p.loadModule) p.loadModule('captions');
                var tl = (p.getOption && p.getOption('captions', 'tracklist')) || [];
                return tl.map(function (t, i) {
                  return { id: t.languageCode || String(i), label: trackName(t) || ('Track ' + (i + 1)), lang: t.languageCode };
                });
              } catch (e) { return []; }
            },
            active: function () {
              var p = P(); if (!p || !p.getOption) return '';
              try { var t = p.getOption('captions', 'track');
                if (!t || !t.languageCode) return '';
                return t.languageCode + (t.kind === 'asr' ? '.asr' : '');
              } catch (e) { return ''; }
            },
            select: function (id) {
              var p = P(); if (!p) return;
              try {
                if (p.loadModule) p.loadModule('captions');
                var lc = id, kind = '';
                if (id.indexOf('.asr') !== -1) { lc = id.replace('.asr', ''); kind = 'asr'; }
                var track = { languageCode: lc };
                if (kind) track.kind = 'asr';
                p.setOption('captions', 'track', track);
                p.setOption('captions', 'reload', true);
              } catch (e) {}
            },
            off: function () { var p = P(); if (!p) return; try { p.setOption('captions', 'track', {}); } catch (e) {} }
          };
        })();

      var netflixCaptions = (function () {
          function P() {
            try { var vp = netflix.appContext.state.playerApp.getAPI().videoPlayer;
              var ids = vp.getAllPlayerSessionIds(); return vp.getVideoPlayerBySessionId(ids[ids.length - 1]);
            } catch (e) { return null; }
          }
          return {
            list: function () {
              var p = P(); if (!p) return [];
              try { return (p.getTimedTextTrackList() || []).filter(function (t) { return !t.isNoneTrack; })
                .map(function (t) { return { id: String(t.trackId),
                  label: (t.displayName || t.bcp47 || 'Subtitles') + (t.trackType === 'ASSISTIVE' ? ' (CC)' : ''), lang: t.bcp47 }; });
              } catch (e) { return []; }
            },
            active: function () {
              var p = P(); if (!p) return '';
              try { var t = p.getTimedTextTrack(); return (t && !t.isNoneTrack) ? String(t.trackId) : ''; } catch (e) { return ''; }
            },
            select: function (id) {
              var p = P(); if (!p) return;
              try { var l = p.getTimedTextTrackList() || [];
                for (var i = 0; i < l.length; i++) if (String(l[i].trackId) === String(id)) { p.setTimedTextTrack(l[i]); return; }
              } catch (e) {}
            },
            off: function () {
              var p = P(); if (!p) return;
              try { var l = p.getTimedTextTrackList() || [];
                for (var i = 0; i < l.length; i++) if (l[i].isNoneTrack) { p.setTimedTextTrack(l[i]); return; }
              } catch (e) {}
            }
          };
        })();

      var skipAdSelectors = ['.ytp-skip-ad-button', '.ytp-ad-skip-button-modern',
        '.ytp-ad-skip-button', 'button[class*="skip-ad"]', '[class*="skip-ad"] button'];
      """
}
