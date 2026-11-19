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
cls.add("js");

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
