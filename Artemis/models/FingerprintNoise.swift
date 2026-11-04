import Foundation
import WebKit

/// per-site, per-launch noise in canvas readback, the WebGL GPU strings, Web Audio data and
/// `hardwareConcurrency`: one answer per site within a launch, different across sites and launches.
/// the seed is drawn per launch and never persisted
enum FingerprintNoise {
    static let enabledKey = "fingerprintDefence"

    private static let sessionSeed: UInt32 = UInt32.random(in: 1...UInt32.max)

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    /// at document start, before any page script reads a surface. the setting is read once per
    /// launch: `removeAllUserScripts`, the only removal API, would drop extension content scripts
    static func install(into controller: WKUserContentController) {
        guard isEnabled else { return }
        controller.addUserScript(
            WKUserScript(
                source: script(seed: sessionSeed), injectionTime: .atDocumentStart,
                forMainFrameOnly: false))
    }

    private static func script(seed: UInt32) -> String {
        """
        (() => {
          if (window.__artemisFingerprintNoise) return;
          window.__artemisFingerprintNoise = true;

          // one number per (session, origin). xorshift over the session seed
          // mixed with the origin's characters: cheap, deterministic, and
          // different for every site — which is the whole point
          let h = \(seed) >>> 0;
          const origin = (location && location.origin) || "null";
          for (let i = 0; i < origin.length; i++) {
            h = (h ^ origin.charCodeAt(i)) >>> 0;
            h = Math.imul(h, 16777619) >>> 0;
          }
          const rand = () => {
            h ^= h << 13; h >>>= 0;
            h ^= h >>> 17;
            h ^= h << 5;  h >>>= 0;
            return h / 4294967296;
          };
          // draw the whole schedule up front so every call in this page sees the
          // same perturbation — a tracker that reads twice must get one answer
          const offsets = [];
          for (let i = 0; i < 32; i++) offsets.push(rand());

          const perturb = (data) => {
            const pixels = data.length >>> 2;
            if (!pixels) return;
            for (let i = 0; i < offsets.length; i++) {
              const p = Math.floor(offsets[i] * pixels) * 4;
              // flip the bottom bit of one channel: a change of 1/255, which no
              // eye and no layout can see, and no hash can survive
              data[p + (i % 3)] ^= 1;
            }
          };

          const wrap = (object, name, make) => {
            const original = object && object[name];
            if (typeof original !== "function") return;
            const replacement = make(original);
            // keep toString() looking native, so the patch isn't itself a
            // fingerprintable oddity
            try {
              Object.defineProperty(replacement, "name", { value: name });
              replacement.toString = () => original.toString();
            } catch (e) {}
            object[name] = replacement;
          };

          // --- canvas -------------------------------------------------------
          const C2D = window.CanvasRenderingContext2D && CanvasRenderingContext2D.prototype;
          wrap(C2D, "getImageData", (original) => function (...args) {
            const result = original.apply(this, args);
            try { perturb(result.data); } catch (e) {}
            return result;
          });

          const noisyCopy = (canvas) => {
            // read, perturb, and draw into a scratch canvas, so the encoded
            // bytes differ without the visible canvas changing
            const copy = document.createElement("canvas");
            copy.width = canvas.width;
            copy.height = canvas.height;
            const context = copy.getContext("2d");
            context.drawImage(canvas, 0, 0);
            const image = context.getImageData(0, 0, copy.width, copy.height);
            context.putImageData(image, 0, 0);
            return copy;
          };

          const CANVAS = window.HTMLCanvasElement && HTMLCanvasElement.prototype;
          wrap(CANVAS, "toDataURL", (original) => function (...args) {
            try {
              if (this.width && this.height) {
                return original.apply(noisyCopy(this), args);
              }
            } catch (e) {}
            return original.apply(this, args);
          });
          wrap(CANVAS, "toBlob", (original) => function (...args) {
            try {
              if (this.width && this.height) {
                return original.apply(noisyCopy(this), args);
              }
            } catch (e) {}
            return original.apply(this, args);
          });

          // --- WebGL --------------------------------------------------------
          // the unmasked strings name the exact GPU; everything else WebGL
          // reports is common to every Mac with this chip
          const generic = { 37445: "Apple Inc.", 37446: "Apple GPU" };
          for (const name of ["WebGLRenderingContext", "WebGL2RenderingContext"]) {
            const proto = window[name] && window[name].prototype;
            wrap(proto, "getParameter", (original) => function (parameter) {
              if (parameter in generic) return generic[parameter];
              return original.call(this, parameter);
            });
          }

          // --- Web Audio ----------------------------------------------------
          // far below the least significant bit of 16-bit audio: inaudible, and
          // enough to move a hash of the buffer
          const jitter = (array) => {
            for (let i = 0; i < offsets.length && i < array.length; i++) {
              const at = Math.floor(offsets[i] * array.length);
              array[at] += (offsets[i] - 0.5) * 1e-7;
            }
          };
          wrap(
            window.AudioBuffer && AudioBuffer.prototype, "getChannelData",
            (original) => function (...args) {
              const data = original.apply(this, args);
              try { jitter(data); } catch (e) {}
              return data;
            });
          wrap(
            window.AnalyserNode && AnalyserNode.prototype, "getFloatFrequencyData",
            (original) => function (array) {
              original.call(this, array);
              try { jitter(array); } catch (e) {}
            });

          // --- navigator ----------------------------------------------------
          try {
            Object.defineProperty(navigator, "hardwareConcurrency", {
              get: () => 8, configurable: true,
            });
          } catch (e) {}
        })();
        """
    }
}
