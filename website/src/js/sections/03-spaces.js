// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import { mountWindow } from "../window.js";
import { track } from "../scroll.js";
import { ORDER, state, subscribe } from "../looks.js";
import { SPACES } from "../data.js";
import { root, mq, say } from "../core.js";

const sec = document.getElementById("spaces");
const $$ = (s) => [...sec.querySelectorAll(s)];
const win = mountWindow(sec.querySelector(".rig"), {
  sky: sec.querySelector(".sp-sky"),
});
const strip = win.win.querySelector(".strip");
const swipe = sec.querySelector(".sp-swipe");
const chips = $$(".sp-chip");
const caps = $$(".sp-cap > span");
const sws = $$(".sp-sw");
const has = (c) => root.classList.contains(c);
const show = (i) => say(`Showing the ${SPACES[i].name} space.`);
const slot = () => swipe.firstElementChild.getBoundingClientRect().width;
const beatSpace = (b) => ({ work: 1, skye: 2 })[b] ?? 0;
let jump = false; // a pinned chip has switched already; beats wait until its scroll lands

// pinned, the caption cell says how to switch until the Personal beat
function sync() {
  const i = win.state.space;
  const cap = has("pin") && /^(void|frame)$/.test(sec.dataset.beat) ? 3 : i;
  swipe.dataset.space = i;
  chips.forEach((c, k) => c.setAttribute("aria-pressed", k === i));
  caps.forEach((c, k) => c.classList.toggle("on", k === cap));
  for (const s of sws) {
    const on = s.dataset.look === state.looks[i];
    s.setAttribute("aria-checked", on);
    s.tabIndex = on ? 0 : -1;
  }
}
win.on("space", sync);
subscribe(sync);
sync();

// void and frame are Personal before the sky arrives and while the frame dissolves;
// the first beat after "" (off screen, unpinned or just loaded) lands at once
track(sec, {
  beats: [
    ["void", 0, 0.06],
    ["frame", 0.06, 0.26],
    ["personal", 0.26, 0.38],
    ["work", 0.38, 0.7],
    ["skye", 0.7, 1],
  ],
  onBeat: (b, prev) => {
    sync();
    if (b && !jump)
      win.setSpace(beatSpace(b), { via: prev ? "scroll" : "instant" });
  },
});
function land() {
  if (!jump) return;
  jump = false;
  const b = sec.dataset.beat;
  if (b) win.setSpace(beatSpace(b), { via: "scroll" });
}
addEventListener("scrollend", land, { passive: true });

// Pinned, a chip switches at once and scrolls to its beat; beats drive the window again once the scroll lands.
chips.forEach((c, i) =>
  c.addEventListener("click", () => {
    const behavior = mq.reduce.matches ? "auto" : "smooth";
    const r = sec.getBoundingClientRect();
    show(i);
    win.setSpace(i, { via: "click" });
    if (!has("pin")) return swipe.scrollTo({ left: i * slot(), behavior });
    const top =
      scrollY + r.top + (r.height - innerHeight) * [0.3, 0.54, 0.85][i];
    if (Math.abs(top - scrollY) < 1) return;
    jump = true;
    if (!("onscrollend" in window)) setTimeout(land, 900);
    scrollTo({ top, behavior });
  }),
);

// ⌃1 to ⌃3 while the window is half in view, and pinned a touch swipe across it, step through the chips as in the app
let near = false;
new IntersectionObserver(([e]) => (near = e.intersectionRatio >= 0.5), {
  threshold: 0.5,
}).observe(sec.querySelector(".sp-island"));
addEventListener("keydown", (e) => {
  const i = { Digit1: 0, Digit2: 1, Digit3: 2 }[e.code];
  if (
    i === undefined ||
    !near ||
    !e.ctrlKey ||
    e.metaKey ||
    e.altKey ||
    e.shiftKey ||
    e.repeat ||
    e.target.closest?.("input, textarea, [contenteditable], #peek")
  )
    return;
  e.preventDefault();
  chips[i].click();
});
let x0 = 0;
let y0 = 0;
win.rig.addEventListener(
  "touchstart",
  (e) => ({ clientX: x0, clientY: y0 } = e.touches[0]),
  { passive: true },
);
win.rig.addEventListener("touchend", (e) => {
  const { clientX: x, clientY: y } = e.changedTouches[0];
  if (
    has("pin") &&
    Math.abs(x - x0) > 40 &&
    Math.abs(x - x0) > 1.5 * Math.abs(y - y0)
  )
    chips[win.state.space + Math.sign(x0 - x)]?.click();
});

// the other spaces' pages lay out once after load, so their first beat skips text shaping
addEventListener(
  "load",
  () =>
    setTimeout(() => {
      const pgs = SPACES.map((s) =>
        win.win.querySelector(`.pg[data-page="${s.page}"]`),
      );
      for (const p of pgs) p.style.display = "block";
      win.win.offsetHeight;
      for (const p of pgs) p.style.display = "";
    }),
  { once: true },
);

function commit() {
  const i = Math.round(swipe.scrollLeft / slot());
  if (i === win.state.space) return;
  win.setSpace(i, { via: "swipe" });
  show(i);
}
let raf = 0;
let idle = 0;
swipe.addEventListener(
  "scroll",
  () => {
    if (!("onscrollend" in window)) {
      clearTimeout(idle);
      idle = setTimeout(commit, 120);
    }
    if (raf || !has("no-sda")) return;
    raf = requestAnimationFrame(() => {
      raf = 0;
      strip.style.transition = "none";
      strip.style.translate = `${-swipe.scrollLeft}px 0`;
    });
  },
  { passive: true },
);
swipe.addEventListener("scrollend", commit);
// Pinning hides the overlay, which forgets its offset; the strip drops the rAF translate.
mq.pin.addEventListener("change", () =>
  requestAnimationFrame(() => {
    strip.style.translate = strip.style.transition = "";
    swipe.scrollLeft = win.state.space * slot();
  }),
);

function pick(n) {
  const i = win.state.space;
  if (state.looks[i] === ORDER[n]) return;
  win.setLook(i, ORDER[n]);
  say(`${SPACES[i].name} now uses ${sws[n].getAttribute("aria-label")}.`);
}
sws.forEach((s, n) => s.addEventListener("click", () => pick(n)));
sec.querySelector(".sp-picker").addEventListener("keydown", (e) => {
  const n = sws.indexOf(e.target);
  const m =
    {
      Home: 0,
      End: 7,
      ArrowRight: n + 1,
      ArrowDown: n + 1,
      ArrowLeft: n + 7,
      ArrowUp: n + 7,
    }[e.key] % 8;
  if (n < 0 || isNaN(m) || e.metaKey || e.ctrlKey || e.altKey) return;
  e.preventDefault();
  pick(m);
  sws[m].focus();
});
