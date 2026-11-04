// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import { params, mq, say, go } from "../core.js";
import { addPageItems } from "../cmdbar.js";
import { paint } from "../looks.js";

const isl = document.querySelector(".arc-island");
const $ = (s) => isl.querySelector(s);
const win = $(".win");
const ptr = $(".arc-ptr");
const rows = [...isl.querySelectorAll(".arc-rows li")];
const [move, allow, pager] = [".arc-go", ".arc-btns :last-child", ".pager"].map(
  $,
);
const LOOKS = ["tide", "tide", "charcoal", "ember"];
const set = (k, on) => isl.toggleAttribute("data-" + k, !!on);
let run = 0;
let shown = false;
let resume = null;
let at = [];
const visible = () => (shown ? 0 : new Promise((r) => (resume = r)));

function space(i, ms) {
  win.dataset.space = i;
  win.dataset.accent = LOOKS[i];
  paint($(".win-bd"), LOOKS[i], { ms, ease: "cubic-bezier(0,0,.58,1)" });
}
// the pointer's tip to a point of el given as fractions of its box; longer trips take longer
function aim(el, x, y) {
  const a = el.getBoundingClientRect();
  const b = win.getBoundingClientRect();
  const p = [a.left - b.left + a.width * x, a.top - b.top + a.height * y];
  ptr.style.transitionDuration =
    Math.min(600, 220 + Math.hypot(p[0] - at[0], p[1] - at[1]) || 600) + "ms";
  ptr.style.translate = (at = p).map((v) => v + "px").join(" ");
}
function press(el) {
  el.animate([{}, { scale: 0.96, filter: "brightness(1.3)" }, {}], 160);
  ptr.animate([{}, { scale: 0.86 }, {}], 160);
}
const swipe = (i, x) => (
  (ptr.style.transitionTimingFunction = "cubic-bezier(0,0,.58,1)"),
  aim(pager, x, 0.42),
  space(i, 420)
);

// [ms to wait, then step]. The reader ticks all but passwords, the keychain asks for Arc's key, Arc's spaces
// land beside Personal, the app opens the first, and a swipe walks the rest. Time passes only while in view.
const STEPS = [
  [
    0,
    () => {
      win.dataset.instant = "";
      for (const r of rows) r.classList.remove("on");
      isl.dataset.ask = "";
      for (const k of ["done", "shut", "fill", "ptr"]) set(k);
      ptr.style.cssText = "";
      at = [];
      space(0);
      requestAnimationFrame(() =>
        requestAnimationFrame(() => delete win.dataset.instant),
      );
    },
  ],
  ...rows.slice(0, 5).flatMap((r, i) => [
    [i ? 220 : 450, () => (set("ptr", 1), aim(r, 0.085, 0.45))],
    [i ? 380 : 750, () => (press(r), r.classList.add("on"))],
  ]),
  [350, () => aim(move, 0.45, 0.55)],
  [650, () => (press(move), (isl.dataset.ask = "on"))],
  [300, () => aim(allow, 0.5, 1.9)],
  [1000, () => aim(allow, 0.45, 0.6)],
  [550, () => press(allow)],
  [160, () => ((isl.dataset.ask = ""), set("done", 1))],
  [800, () => aim(move, 0.45, 0.55)],
  [500, () => press(move)],
  [160, () => set("shut", 1)],
  [250, () => (space(1, 420), set("fill", 1))],
  [900, () => aim(pager, 0.8, 0.42)],
  [900, () => swipe(2, 0.5)],
  [1400, () => swipe(3, 0.2)],
  [1300, () => (ptr.style.opacity = 0)],
];

async function play() {
  const me = ++run;
  for (const [ms, step] of STEPS) {
    for (let t = ms; t > 0; t -= 40) {
      await visible();
      await new Promise((r) => setTimeout(r, 40));
    }
    if (me !== run) return;
    step();
  }
}

// the markup is the finished frame; ?arc=keychain holds the prompt open, ?arc=N stops after N steps
const p = params.get("arc");
if (p || mq.reduce.matches || params.has("nosettle")) {
  run = 1;
  for (const [, step] of STEPS.slice(0, p === "keychain" ? 14 : +p)) step();
} else STEPS[0][1]();

new IntersectionObserver(
  ([e]) => {
    shown = e.intersectionRatio > 0.55;
    if (!shown) return;
    resume?.();
    resume = null;
    if (!run) play();
  },
  { threshold: 0.6 },
).observe(isl);

isl.nextElementSibling.onclick = () => {
  play();
  say(
    "Replaying. All but passwords are ticked, then Arc’s three spaces arrive with their tabs.",
  );
};

addPageItems((q) =>
  /\b(arc|import)/i.test(q)
    ? [
        {
          kind: "section",
          title: "Move in from Arc",
          sub: "On this page",
          icon: '<svg class="ico"><use href="#i-download"/></svg>',
          verb: "Go",
          run: () => go("arc"),
        },
      ]
    : [],
);
