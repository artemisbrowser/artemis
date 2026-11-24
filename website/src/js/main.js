// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import { root, params, mq } from "./core.js";
import { openPeek } from "./peek.js";
import "./gallery.js";
import "./know.js";

const cls = root.classList;
const modes = () => ["fine", "coarse"].forEach((k) => cls.toggle(k, mq[k].matches));
modes();
for (const k of ["fine", "coarse"]) mq[k].addEventListener("change", modes);

/* ---------- lazy shots take their srcset once the page has a width ---------- */
// WebKit never loads a lazy srcset image whose source was picked while a background view was zero wide
function widen() {
  if (!innerWidth) return;
  removeEventListener("resize", widen);
  for (const img of document.querySelectorAll("img[data-srcset]")) img.srcset = img.dataset.srcset;
}
addEventListener("resize", widen);
widen();

/* ---------- appearance: the toggle overrides the system for this visit only ---------- */
const sys = matchMedia("(prefers-color-scheme: dark)");
const toggle = document.querySelector("[data-theme-toggle]");
const dark = () => (root.dataset.theme ?? (sys.matches ? "dark" : "light")) === "dark";
function paintToggle() {
  toggle.querySelector("use").setAttribute("href", dark() ? "#i-sun" : "#i-moon");
  toggle.setAttribute("aria-label", `Switch to ${dark() ? "light" : "dark"} appearance`);
}
if (["light", "dark"].includes(params.get("theme"))) root.dataset.theme = params.get("theme");
toggle.addEventListener("click", () => {
  root.dataset.theme = dark() ? "light" : "dark";
  paintToggle();
});
sys.addEventListener("change", paintToggle);
paintToggle();

/* ---------- the nav's Download joins once the hero's has scrolled away above ---------- */
const nav = document.getElementById("nav");
const navGet = nav.querySelector("[data-get]");
const heroGet = document.getElementById("hero-get");
function syncGet() {
  const on = heroGet.getBoundingClientRect().bottom < 0;
  nav.classList.toggle("has-get", on);
  navGet.tabIndex = on ? 0 : -1;
  navGet.setAttribute("aria-hidden", !on);
}
new IntersectionObserver(syncGet).observe(heroGet);
addEventListener("pageshow", syncGet);

/* ---------- reveals fire once, the first time an element enters from either edge ---------- */
const hidden = new Set(document.querySelectorAll(".reveal"));
const reveals = new IntersectionObserver(
  (entries) => {
    const shown = entries.filter((e) => e.isIntersecting).map((e) => e.target);
    // d1/d2 stagger only reveals that arrive together; one arriving alone, as in a stacked phone column, starts at once
    for (const el of shown) el.classList.add("in", ...(shown.length === 1 ? ["lone"] : []));
    // a fling or a restored scroll can carry reveals past the line unseen; they are shown with the next arrivals
    const passed = [...hidden].filter((el) => !shown.includes(el) && el.getBoundingClientRect().bottom < 0);
    for (const el of passed) el.classList.add("in", "lone");
    for (const el of [...shown, ...passed]) {
      hidden.delete(el);
      reveals.unobserve(el);
    }
  },
  { rootMargin: "0px 0px -15% 0px" },
);
for (const el of hidden) reveals.observe(el);

/* ---------- the Arc-to-Artemis sidebars move once 3/4 of them, or of a short viewport, is on screen ---------- */
const moveArt = document.querySelector(".move-art");
if (moveArt) {
  const t = Math.min(0.75, (innerHeight * 0.75) / moveArt.offsetHeight);
  const play = new IntersectionObserver(
    ([e]) => {
      if (e.intersectionRatio < t) return;
      moveArt.classList.add("play");
      play.disconnect();
    },
    { threshold: t },
  );
  play.observe(moveArt);
}

/* ---------- the nav marks the section crossing mid-viewport; on phones its links drop from a chevron ---------- */
const links = [...nav.querySelectorAll('.localnav-links a[href^="#"]')];
const menu = nav.querySelector("[data-nav-menu]");
const current = new IntersectionObserver(
  (entries) => {
    for (const e of entries)
      links
        .find((a) => a.hash === `#${e.target.id}`)
        .toggleAttribute("aria-current", e.isIntersecting);
  },
  { rootMargin: "-50% 0px -50% 0px" },
);
for (const a of links) current.observe(document.querySelector(a.hash));
const shut = () => menu.setAttribute("aria-expanded", false);
menu.addEventListener("click", () =>
  menu.setAttribute("aria-expanded", menu.getAttribute("aria-expanded") !== "true"),
);
for (const el of [nav.querySelector(".localnav-links"), nav.nextElementSibling]) el.addEventListener("click", shut);
addEventListener("keydown", (e) => e.key === "Escape" && shut());

/* ---------- phones get the link for later, never a Mac download ---------- */
if (mq.coarse.matches)
  for (const a of document.querySelectorAll("[data-get]")) {
    const label = a.querySelector(".get-label");
    if (label) label.textContent = "Send to my Mac";
    a.addEventListener("click", async (e) => {
      e.preventDefault();
      const url = location.origin + "/";
      try {
        if (navigator.share)
          return await navigator.share({ title: "Artemis", url });
        await navigator.clipboard.writeText(url);
        if (!label) return;
        label.textContent = "Link copied";
        setTimeout(() => (label.textContent = "Send to my Mac"), 2000);
      } catch {}
    });
  }

if (params.has("peek")) openPeek(params.get("peek"));
