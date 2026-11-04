// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import { params, mq, say } from "../core.js";
import { ICONS } from "../data.js";

const sec = document.getElementById("fin");
const mark = sec.querySelector(".mark");
const dock = sec.querySelector(".dock");
const icons = [...dock.children];
const label = sec.querySelector(".dock-l").children;

/* ---------- the Dock: one radio group; without JS the mark and the Dock stay a still picture ---------- */
mark.tabIndex = 0;
mark.ariaLabel += " Press the left or right arrow to spin it.";
dock.inert = false;
function pick(btn, quiet) {
  const [, name, word, light, base] = ICONS.find(
    (i) => i[0] === btn.dataset.icon,
  );
  for (const b of icons) {
    b.ariaChecked = b === btn;
    b.tabIndex = b === btn ? 0 : -1;
  }
  label[0].textContent = name;
  label[1].textContent = word;
  // icon URLs exist only as hashed literals in the markup, so the picture is copied from the DOM
  const pic = btn.firstElementChild;
  const src = pic.lastElementChild.currentSrc;
  for (const w of document.querySelectorAll(".get-well"))
    w.replaceChildren(pic.cloneNode(true));
  document.querySelector(".brand picture")?.replaceWith(pic.cloneNode(true));
  if (src) {
    for (const i of document.querySelectorAll("img.sicon")) i.src = src;
    for (const l of document.querySelectorAll("link[rel=icon]")) {
      l.type = "image/png";
      l.href = src;
    }
  }
  sec.style.cssText = `--m-light:${light};--m-base:${base}`;
  if (!quiet) say(`${name} icon.`);
}
for (const b of icons) {
  b.onclick = () => pick(b);
  if (b.dataset.icon === params.get("dock")) pick(b, true);
}
dock.onkeydown = (e) => {
  const n = icons.indexOf(e.target);
  const m =
    {
      Home: 0,
      End: 9,
      ArrowRight: n + 1,
      ArrowDown: n + 1,
      ArrowLeft: n + 9,
      ArrowUp: n + 9,
    }[e.key] % 10;
  if (n < 0 || isNaN(m) || e.metaKey || e.ctrlKey || e.altKey) return;
  e.preventDefault();
  pick(icons[m]);
  icons[m].focus();
};

// --m and --dx are written for every pointer; CSS shows them only for a fine pointer at ≥ 735 wide.
// A button's rect is its untransformed slot. Only the row nearest the pointer grows, and each icon in it
// moves by the growth to its left, less half the row's, so the row widens about its centre.
let px = -1e9;
let py = 0;
let magRaf = 0;
const magnify = () => {
  magRaf = 0;
  const rects = icons.map((b) => b.getBoundingClientRect());
  const mid = (r) => Math.abs(r.y + r.height / 2 - py);
  const row = rects.reduce((a, r) => (mid(r) < mid(a) ? r : a)).y;
  const grow = rects.map((r) =>
    r.y === row
      ? 0.5 *
        r.width *
        Math.max(0, 1 - Math.abs(px - r.x - r.width / 2) / (2 * r.width))
      : 0,
  );
  const total = grow.reduce((a, g) => a + g, 0);
  let left = 0;
  icons.forEach((b, i) => {
    b.style.setProperty("--m", 1 + grow[i] / rects[i].width);
    b.style.setProperty(
      "--dx",
      rects[i].y === row ? left + grow[i] / 2 - total / 2 : 0,
    );
    left += grow[i];
  });
};
dock.onpointermove = dock.onpointerleave = (e) => {
  px = e.type === "pointermove" && e.pointerType !== "touch" ? e.clientX : -1e9;
  py = e.clientY;
  magRaf ||= requestAnimationFrame(magnify);
};

/* ---------- the mark: angle a in rad, spin w in rad/s, pull x y in px ---------- */
const s = { a: 0, w: 0, x: 0, y: 0, vx: 0, vy: 0 };
const T = 2 * Math.PI;
const home = () => Math.round(s.a / T) * T;
let held = null;
let samples = [];
let raf = 0;
let last = 0;
// the front comet trails the A by up to 0.08 rad in the direction of spin
const draw = () =>
  (mark.style.cssText = `--a:${s.a}rad;--lag:${0.08 * Math.max(-1, Math.min(1, s.w / 1.5))}rad;translate:${s.x}px ${s.y}px`);
// spin speed over the pointer samples of the last 100 ms; the 30 ms floor keeps a tap's jitter from spinning it
const speed = (now) => {
  samples = samples.filter(([t]) => now - t <= 100);
  const [t0, a0] = samples[0] ?? [0, 0];
  const [t1, a1] = samples.at(-1) ?? [0, 0];
  return ((a1 - a0) * 1000) / Math.max(30, t1 - t0);
};
function frame(t) {
  if (held?.spin) s.w = speed(t);
  // fixed 1/240 s substeps, at most 50 ms per frame
  let left = last ? Math.min(0.05, (t - last) / 1000) : 0;
  for (; left > 1e-6; left -= 1 / 240) {
    const h = Math.min(left, 1 / 240);
    if (!held?.spin) {
      // below 2.5 rad/s a detent springs it to the nearest upright, with one small overshoot
      if (Math.abs(s.w) < 2.5) s.w += (-30 * (s.a - home()) - 4 * s.w) * h;
      s.a += s.w * h;
      s.w *= Math.exp(-2.2 * h);
    }
    if (!held?.pull) {
      s.vx -= (180 * s.x + 14 * s.vx) * h;
      s.vy -= (180 * s.y + 14 * s.vy) * h;
      s.x += s.vx * h;
      s.y += s.vy * h;
    }
  }
  last = t;
  draw();
  mark.classList.toggle("held", !!held);
  raf =
    held ||
    Math.abs(s.w) > 0.005 ||
    Math.abs(s.a - home()) > 0.002 ||
    Math.hypot(s.x, s.y, s.vx, s.vy) > 0.05
      ? requestAnimationFrame(frame)
      : (last = 0);
}
const run = () => (raf ||= requestAnimationFrame(frame));
// One turn in dir from the nearest upright: under the 2.2/s friction it coasts to rest there.
// Reduced motion steps 15° at once.
const flick = (dir) => {
  if (mq.reduce.matches) {
    s.a += (dir * Math.PI) / 12;
    draw();
  } else {
    s.w = 2.2 * (home() + dir * T - s.a);
    run();
  }
};

mark.onpointerdown = (e) => {
  if (e.button) return;
  const r = mark.getBoundingClientRect();
  const cx = r.x + r.width / 2;
  const cy = r.y + r.height / 2;
  const dx = e.clientX - cx;
  const dy = e.clientY - cy;
  mark.setPointerCapture(e.pointerId);
  held =
    Math.hypot(dx, dy) > 0.24 * r.width
      ? { spin: 1, cx, cy, off: s.a - Math.atan2(dy, dx) }
      : { pull: 1, x0: e.clientX - s.x, y0: e.clientY - s.y };
  samples = [[e.timeStamp, s.a]];
  s.w = s.vx = s.vy = 0;
  run();
};
mark.onpointermove = (e) => {
  if (held?.spin) {
    const a = Math.atan2(e.clientY - held.cy, e.clientX - held.cx) + held.off;
    s.a = a + Math.round((s.a - a) / (2 * Math.PI)) * 2 * Math.PI;
    samples.push([e.timeStamp, s.a]);
  } else if (held) {
    const dx = e.clientX - held.x0;
    const dy = e.clientY - held.y0;
    const d = Math.hypot(dx, dy) + 1e-9;
    const k = (40 * Math.tanh(d / 40)) / d;
    s.x = dx * k;
    s.y = dy * k;
  }
};
const release = (e) => {
  if (!held) return;
  const reduce = mq.reduce.matches;
  s.w = held.spin && !reduce ? speed(e.timeStamp) : 0;
  if (reduce) {
    s.x = s.y = 0;
    s.a = home();
  }
  held = null;
};
mark.onpointerup = mark.onpointercancel = release;
mark.onkeydown = (e) => {
  const dir = { ArrowLeft: -1, ArrowRight: 1, " ": 1 }[e.key];
  if (!dir) return;
  flick(dir);
  e.preventDefault();
};
mark.nextElementSibling.onclick = () => flick(1);

s.a = (params.get("mark") * Math.PI) / 180 || 0;
draw();
