// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import { params, mq, say, go } from "../core.js";
import { addPageItems } from "../cmdbar.js";
import { paint } from "../looks.js";

const isl = document.querySelector(".arc-island");
const $ = (s) => isl.querySelector(s);
const win = $(".win");
const ptr = $(".arc-ptr");
const sheet = $(".arc-sheet");
const [imp, allow, done, line, pw] = [
  ".arc-pick .arc-go",
  ".arc-btns :last-child",
  ".arc-sum .arc-go",
  ".arc-step span",
  ".arc-pw",
].map($);
const LOOKS = ["tide", "tide", "charcoal", "ember"];
const set = (k, on) => isl.toggleAttribute("data-" + k, !!on);
const tell = (t) => (line.textContent = t);
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
// the sheet swaps what it shows and springs to the new height, as the app's sheet does
function phase(p) {
  const h = sheet.offsetHeight;
  isl.dataset.phase = p;
  if (shown && !mq.reduce.matches)
    sheet.animate(
      { height: [h + "px", sheet.offsetHeight + "px"] },
      { duration: 450, easing: "cubic-bezier(.3,1.2,.4,1)" },
    );
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
// [ms to wait, then step], in the app's own order: the key, cookies, then spaces and favourites land in the
// sidebar, then history. After Done the pointer leaves and Arc's spaces show in turn. Time passes only in view.
const STEPS = [
  [
    0,
    () => {
      win.dataset.instant = "";
      isl.dataset.ask = "";
      for (const k of ["landed", "shut", "fill", "ptr"]) set(k);
      phase("pick");
      tell("Reading Arc…");
      pw.style.setProperty("--k", 0);
      ptr.style.cssText = "";
      at = [];
      space(0);
      requestAnimationFrame(() =>
        requestAnimationFrame(() => delete win.dataset.instant),
      );
    },
  ],
  [900, () => (set("ptr", 1), aim($(".arc-rows"), 0.6, 0.3))],
  [1500, () => aim(imp, 0.5, 0.55)],
  [700, () => (press(imp), phase("work"))],
  [900, () => (tell("Waiting for the keychain…"), (isl.dataset.ask = "on"))],
  ...Array.from({ length: 10 }, (_, i) => [
    i ? 70 : 800,
    () => pw.style.setProperty("--k", i + 1),
  ]),
  [300, () => aim(allow, 0.5, 0.55)],
  [600, () => press(allow)],
  [160, () => (isl.dataset.ask = "")],
  ...Array.from({ length: 13 }, (_, i) => [
    i ? 90 : 300,
    () => tell(i ? `Cookies… ${i * 100} of 1,240` : "Cookies…"),
  ]),
  [300, () => (tell("Spaces and tabs…"), set("landed", 1))],
  [1400, () => tell("History…")],
  [900, () => phase("sum")],
  [1800, () => aim(done, 0.5, 0.55)],
  [600, () => press(done)],
  [160, () => (set("shut", 1), (ptr.style.opacity = 0))],
  [250, () => (space(1, 420), set("fill", 1))],
  [2000, () => space(2, 420)],
  [2000, () => space(3, 420)],
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
  for (const [, step] of STEPS.slice(0, p === "keychain" ? 15 : +p)) step();
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
    "Replaying. Arc’s spaces, favourites, archive, history and cookies come across, then its spaces open.",
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
