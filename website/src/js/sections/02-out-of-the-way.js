// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import { root, params, mq, say } from "../core.js";
import { track } from "../scroll.js";
import { setSitebar } from "../sitebar.js";
import { mountWindow } from "../window.js";

const top = document.getElementById("top");
const outro = document.getElementById("native");
const run = document.getElementById("oow");
const rig = top.querySelector('[data-rig="oow"]');
const ctl = mountWindow(rig);
const { win } = ctl;
const caps = top.querySelectorAll(".cap");
const pinBtn = top.querySelector(".cap-btn");
const c3 = pinBtn.previousElementSibling;
const c3Text = c3.innerHTML;
const sideBtn = top.querySelector('[data-act="sidebar"]');
const range = top.querySelector(".oow-controls input");
const out = top.querySelector(".oow-controls output");
let beat = "";
let edgeT = 0;
let dockT = 0;

const docked = () => win.hasAttribute("data-repin");
// the hold owns the left edge, ⌘S and caption 3 only while its stage is pinned (html.oow-on)
const live = () => beat === "hold" && root.classList.contains("oow-on");
function show() {
  const cap = beat === "hold" ? "c3" : beat;
  for (const c of caps) {
    const on = c.dataset.cap === cap && (cap !== "c3" || live());
    c.classList.toggle("on", on);
    c.inert = !on;
  }
}
// Once a visit, the idle last Today tab tidies itself into the Library while the floating sidebar is open.
// It stays tidied, docked or not, until the reader leaves the hold.
const stale = win.querySelectorAll(".panel > .row:last-child");
const lib = win.querySelector(".fsb .lib");
let tidyT = 0;
let tidied = false;
function float(v) {
  ctl.setFloat(v);
  if (!docked()) c3.innerHTML = v === "open" ? "There they are." : c3Text;
  clearTimeout(tidyT);
  if (v === "open" && !tidied)
    tidyT = setTimeout(() => {
      for (const r of stale) r.dataset.ago = "12 h";
      tidyT = setTimeout(() => {
        for (const r of stale) r.classList.add("out");
        tidyT = setTimeout(() => {
          tidied = true;
          for (const r of stale) r.hidden = true;
          lib.animate(
            { scale: [1, 1.12, 1] },
            { duration: 420, easing: "ease-in-out" },
          );
        }, 240);
      }, 1100);
    }, 1500);
  else if (!tidied || beat !== "hold")
    for (const r of stale) {
      r.hidden = false;
      r.classList.remove("out");
      delete r.dataset.ago;
    }
  show();
}

// Pinned means the track is on screen and the outro is not yet; created after main.js's, so it writes last.
const seen = {};
function own() {
  root.classList.toggle(
    "oow-on",
    root.classList.contains("pin") && seen.top && !seen[outro.id],
  );
  show();
}
const io = new IntersectionObserver((es) => {
  for (const e of es) seen[e.target.id] = e.isIntersecting;
  own();
});
io.observe(top);
io.observe(outro);

function dock(on, tell) {
  if (on === docked()) return;
  clearTimeout(dockT);
  // from the floating sidebar, the docked one lands under it and the card makes room before it goes
  const open = on && ctl.state.float === "open";
  if (open) ctl.instant(() => {});
  win.toggleAttribute("data-repin", on);
  if (open) dockT = setTimeout(() => ctl.instant(() => float("hidden")), 600);
  else float("hidden");
  pinBtn.firstElementChild.textContent = on ? "Hide sidebar" : "Show sidebar";
  if (on) c3.textContent = "The sidebar is back.";
  else c3.innerHTML = c3Text;
  if (tell) say(on ? "Sidebar shown" : "Sidebar hidden");
}

track(run, {
  beats: [
    ["zoom", 0, 0.3],
    ["inside", 0.3, 0.4],
    ["c1", 0.4, 0.62],
    ["c2", 0.62, 0.81],
    ["hold", 0.81, 1],
  ],
  onBeat(b, prev) {
    beat = b;
    if (b === "c1")
      caps[0].querySelectorAll(".kc").forEach((k, i) =>
        setTimeout(() => {
          k.classList.add("down");
          setTimeout(() => k.classList.remove("down"), 260);
        }, i * 50),
      );
    if (b === "hold") {
      float(params.get("hold") === "open" ? "open" : "hidden");
      if (params.get("hold") === "pinned") dock(true);
    } else if (prev === "hold") {
      dock(false);
      float("hidden");
    }
    show();
  },
});

pinBtn.addEventListener("click", () => dock(!docked(), true));
addEventListener("keydown", (e) => {
  if (!live() || e.altKey || e.shiftKey || e.key.toLowerCase() !== "s") return;
  if (!e.metaKey && !e.ctrlKey) return;
  e.preventDefault();
  if (!e.repeat) dock(!docked(), true);
});
// mouse or pen at the window's left edge for 100 ms brings the floating sidebar, as in the app
addEventListener(
  "pointermove",
  (e) => {
    if (beat !== "hold" || e.pointerType === "touch" || docked()) return;
    const r = rig.getBoundingClientRect();
    if (ctl.state.float === "open") {
      // the app's hover area: sidebar 250, overlay grip 18, buffer 10
      if (e.clientX > r.left + (278 * r.width) / 1352) float("hidden");
    } else if (
      e.clientX <= r.left + 8 &&
      e.clientY >= r.top &&
      e.clientY <= r.bottom &&
      live()
    )
      edgeT ||= setTimeout(() => {
        edgeT = 0;
        if (live() && !docked()) float("open");
      }, 100);
    else {
      clearTimeout(edgeT);
      edgeT = 0;
    }
  },
  { passive: true },
);

function side(hide, now) {
  ctl.setSidebar(!hide, { instant: now });
  sideBtn.textContent = hide ? "Show sidebar" : "Hide sidebar";
}
function edge(v) {
  ctl.setEdge(+v);
  range.value = v;
  range.style.setProperty("--v", (v / 16) * 100);
  out.value = +v ? v + " pt" : "None";
  range.setAttribute(
    "aria-valuetext",
    +v ? (v == 1 ? "1 point" : v + " points") : "None",
  );
}
sideBtn.addEventListener("click", () => {
  const hide = ctl.state.sidebar === "pinned";
  side(hide);
  say(hide ? "Sidebar hidden" : "Sidebar shown");
});
range.addEventListener("input", () => edge(range.value));
// the scrub starts from the default window, so the static controls reset when the pin returns
mq.pin.addEventListener("change", () => {
  own();
  if (mq.pin.matches) {
    side(false, true);
    edge(10);
  }
});

outro
  .querySelector('[data-act="sections"]')
  .addEventListener("click", () => setSitebar(true));
