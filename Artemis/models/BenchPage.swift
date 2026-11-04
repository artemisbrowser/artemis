// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import Foundation

/// the bench's stand-in for a web page: thousands of rows, a grid of composited cards
/// and a requestAnimationFrame loop doing fixed work per frame (counted in
/// `window.__ticks`), byte-identical for a given index on every run
enum BenchPage {
    static func html(index: Int) -> String {
        let hue = index * 43 % 360
        var rows = ""
        rows.reserveCapacity(400_000)
        for i in 0..<2500 {
            rows += "<div class=\"row\"><span class=\"dot\"></span>"
            rows += "<span class=\"t\">Row \(i) — page \(index) — lorem ipsum dolor sit amet, "
            rows += "consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore "
            rows += "et dolore magna aliqua, ut enim ad minim veniam.</span>"
            rows += "<span class=\"tag\">tag\(i % 12)</span></div>"
        }
        var cards = ""
        for i in 0..<60 {
            let h = (hue + i * 7) % 360
            cards += "<div class=\"card\" style=\"--h:\(h)\">"
            cards += "<div class=\"thumb\"></div><div class=\"cap\">Card \(i)</div></div>"
        }
        return """
            <!doctype html><html><head><meta charset="utf-8"><title>Bench page \(index)</title>
            <style>
              :root { color-scheme: dark }
              body { margin:0; font:13px/1.5 -apple-system, sans-serif; color:#eee;
                     background:linear-gradient(160deg,hsl(\(hue),60%,12%),hsl(\(hue + 40),60%,6%)); }
              header { position:sticky; top:0; z-index:9; height:60px; display:flex;
                       align-items:center; backdrop-filter:blur(14px);
                       background:hsla(\(hue),60%,20%,.5); box-shadow:0 2px 12px #0008 }
              .spin { width:28px; height:28px; margin:16px; border-radius:50%;
                      background:conic-gradient(hsl(\(hue),80%,60%),transparent) }
              .bar { flex:1; height:6px; margin-right:16px; border-radius:3px;
                     background:linear-gradient(90deg,hsl(\(hue),80%,60%),transparent) }
              .grid { display:grid; grid-template-columns:repeat(6,1fr); gap:12px; padding:16px }
              .card { border-radius:12px; overflow:hidden; background:#ffffff0d;
                      box-shadow:0 6px 18px #0009; transform:translateZ(0) }
              .thumb { height:90px;
                       background:radial-gradient(circle at 30% 30%,
                                  hsl(var(--h),80%,55%), hsl(var(--h),60%,18%)) }
              .cap { padding:8px 10px; font-size:12px; opacity:.85 }
              .row { display:flex; gap:8px; align-items:center; padding:6px 12px;
                     border-bottom:1px solid #ffffff14 }
              .dot { width:10px; height:10px; border-radius:50%;
                     background:hsl(\(hue),70%,55%); box-shadow:0 0 6px hsl(\(hue),70%,55%) }
              .t { flex:1; white-space:nowrap; overflow:hidden; text-overflow:ellipsis }
              .tag { font-size:11px; padding:2px 8px; border-radius:8px; background:#ffffff1a }
            </style></head><body>
            <header><div class="spin"></div><div class="bar"></div></header>
            <div class="grid">\(cards)</div>\(rows)
            <script>
            // a fixed amount of work per animation frame, plus a style mutation
            // so the frame has something to paint
            (function () {
              var spin = document.querySelector('.spin');
              var bar = document.querySelector('.bar');
              var t = 0;
              window.__ticks = 0;
              window.__marks = {};
              // a page nobody is looking at should stop getting frames; the bench
              // reads these counters to check that it actually does
              window.__mark = function (name) {
                window.__marks[name] = window.__ticks;
                return window.__ticks;
              };
              function frame() {
                window.__ticks++;
                var acc = 0;
                for (var i = 0; i < 120000; i++) acc += Math.sqrt(i % 977);
                t = (t + 3) % 360;
                spin.style.transform = 'rotate(' + t + 'deg)';
                bar.style.opacity = 0.6 + 0.4 * Math.sin(t / 40) + acc * 0;
                requestAnimationFrame(frame);
              }
              requestAnimationFrame(frame);
            })();
            </script>
            </body></html>
            """
    }
}
