// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import { root, mq } from "./core.js";

const tracks = [];
let queued = true; // scroll frames start after the first write: until then the tracks are unmeasured
let secs = [];
let anchor = null;

// Layout is read here only: after layout changes the page's size, on resize, on load, on pin changes, or when a
// track's animations change.
export function measure() {
  const vh = innerHeight;
  const drive = root.matches(".pin.no-sda");
  for (const t of tracks) {
    const r = t.el.getBoundingClientRect();
    t.top = r.top + scrollY;
    t.span = Math.max(1, r.height - vh);
    t.out = vh / t.span;
    // without scroll timelines, --sp (registered, not inherited) goes on each element its paused scrub runs on
    t.scrub = drive
      ? new Set(
          t.el
            .getAnimations({ subtree: true })
            .filter((a) => a.playState === "paused")
            .map((a) => a.effect.target),
        )
      : [];
    t.sp = "";
  }
  secs = [...document.querySelectorAll("main > section")].map((s) => {
    const r = s.getBoundingClientRect();
    return [s, r.top + scrollY, r.height];
  });
  tick();
}

// Reads scrollY only. A beat is "" while the track is off screen or the page is not pinned.
function write() {
  queued = false;
  const y = scrollY;
  const pin = root.classList.contains("pin");
  const a = secs.find(([, top, h]) => top + h > y + 75);
  anchor = a && [a[0], (y + 75 - a[1]) / a[2]];
  for (const t of tracks) {
    const raw = (y - t.top) / t.span;
    root.classList.toggle("past-" + t.el.id, raw > 1);
    const p = Math.min(1, Math.max(0, raw));
    const sp = p.toFixed(4);
    if (sp !== t.sp)
      for (const el of t.scrub) el.style.setProperty("--sp", (t.sp = sp));
    const beat =
      pin && raw >= -t.out && raw <= 1 + t.out
        ? (t.beats.findLast((b) => p >= b[1])?.[0] ?? "")
        : "";
    if (beat !== t.beat) {
      const prev = t.beat;
      t.el.dataset.beat = t.beat = beat;
      t.onBeat?.(beat, prev);
    }
  }
}

function tick() {
  if (!queued) {
    queued = true;
    requestAnimationFrame(write);
  }
}

// beats: [[name, from, to], …] in progress p (0..1), contiguous and in order.
// Register before the first frame: a track added later has no geometry until the next measure().
export function track(el, { beats = [], onBeat } = {}) {
  tracks.push({ el, beats, onBeat, beat: "", sp: "" });
}

addEventListener("scroll", tick, { passive: true });
addEventListener("resize", measure);
addEventListener("load", measure);
// The first write lands after layout and before paint. Body is observed for good only from the next frame: WebKit
// renders content-visibility sections inside the first frame's observer loop, after body's notification.
const first = new ResizeObserver(() => {
  measure();
  write();
  first.disconnect();
  requestAnimationFrame(() =>
    new ResizeObserver(measure).observe(document.body),
  );
});
first.observe(document.body);
// Crossing the pin gate keeps the reader at the same point of the section under the nav line, as the last
// write saw it: by the time this fires the viewport has already changed.
mq.pin.addEventListener("change", () => {
  const a = anchor;
  requestAnimationFrame(() => {
    measure();
    const q = a?.[0].getBoundingClientRect();
    if (q) scrollTo(0, scrollY + q.top - 75 + a[1] * q.height);
  });
});
