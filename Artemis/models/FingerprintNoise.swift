// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import Foundation
import WebKit

/// per-site noise in canvas readback, the WebGL GPU strings, Web Audio data and `hardwareConcurrency`:
/// one answer per site within a controller (a profile, or its incognito pages) for the launch, different
/// across sites, controllers and launches. the seed is drawn per controller and never persisted
enum FingerprintNoise {
    static let enabledKey = "fingerprintDefence"

    /// read once per launch: `removeAllUserScripts`, the only removal API, would drop extension
    /// content scripts
    static let isEnabled = UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true

    /// at document start, before any page script reads a surface
    static func install(into controller: WKUserContentController) {
        guard isEnabled else { return }
        controller.addUserScript(
            WKUserScript(
                source: script(seed: UInt32.random(in: 1...UInt32.max)), injectionTime: .atDocumentStart,
                forMainFrameOnly: false))
    }

    private static func script(seed: UInt32) -> String {
        """
        (() => {
          // one number per (controller, origin). xorshift over the seed
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

          // a replacement reads as its native original: name, length, no
          // prototype, and its source through Function.prototype.toString
          const natives = new WeakMap();
          const toString = Function.prototype.toString;
          const nativeToString = {
            toString() { return toString.call(natives.get(this) || this); },
          }.toString;
          natives.set(nativeToString, toString);
          Function.prototype.toString = nativeToString;

          const wrap = (object, name, make) => {
            const original = object && object[name];
            if (typeof original !== "function") return;
            const body = make(original);
            const replacement = { [name](...args) { return body.apply(this, args); } }[name];
            Object.defineProperty(replacement, "length", { value: original.length });
            natives.set(replacement, original);
            object[name] = replacement;
          };

          // --- canvas -------------------------------------------------------
          const C2D = window.CanvasRenderingContext2D && CanvasRenderingContext2D.prototype;
          const readPixels = C2D && C2D.getImageData;
          wrap(C2D, "getImageData", (original) => function (...args) {
            const result = original.apply(this, args);
            try { perturb(result.data); } catch (e) {}
            return result;
          });

          const noisyCopy = (canvas) => {
            // perturb a scratch copy, so the encoded bytes differ without the
            // visible canvas changing; past a megapixel only the flipped pixels
            // make the round trip
            const copy = document.createElement("canvas");
            copy.width = canvas.width;
            copy.height = canvas.height;
            const { width, height } = copy;
            const context = copy.getContext("2d");
            context.drawImage(canvas, 0, 0);
            if (width * height <= 1 << 20) {
              context.putImageData(context.getImageData(0, 0, width, height), 0, 0);
              return copy;
            }
            // the pixels perturb() flips over the whole image, in its order
            for (let i = 0; i < offsets.length; i++) {
              const at = Math.floor(offsets[i] * width * height);
              const x = at % width, y = Math.floor(at / width);
              const pixel = readPixels.call(context, x, y, 1, 1);
              pixel.data[i % 3] ^= 1;
              context.putImageData(pixel, x, y);
            }
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
          const noised = new WeakSet();
          const jitter = (array) => {
            for (let i = 0; i < offsets.length && i < array.length; i++) {
              const at = Math.floor(offsets[i] * array.length);
              array[at] += (offsets[i] - 0.5) * 1e-7;
            }
          };
          wrap(
            window.AudioBuffer && AudioBuffer.prototype, "getChannelData",
            (original) => function (...args) {
              // a live view of the buffer, the same array on every call
              const data = original.apply(this, args);
              try {
                if (!noised.has(data)) { noised.add(data); jitter(data); }
              } catch (e) {}
              return data;
            });
          wrap(
            window.AnalyserNode && AnalyserNode.prototype, "getFloatFrequencyData",
            (original) => function (array) {
              original.call(this, array);
              try { jitter(array); } catch (e) {}
            });

          // --- navigator ----------------------------------------------------
          const NAVIGATOR = window.Navigator && Navigator.prototype;
          const cores = NAVIGATOR && Object.getOwnPropertyDescriptor(NAVIGATOR, "hardwareConcurrency");
          if (cores && cores.get) {
            const get = Object.getOwnPropertyDescriptor(
              { get hardwareConcurrency() { return 8; } }, "hardwareConcurrency").get;
            natives.set(get, cores.get);
            Object.defineProperty(NAVIGATOR, "hardwareConcurrency", { ...cores, get });
          }
        })();
        """
    }
}
