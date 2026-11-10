// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import { root, params, mq, keyHandlers, watchReplicas } from "./core.js";
import "./scroll.js";
import "./tooltip.js";
import { openPageBar } from "./cmdbar.js";
import { openPeek } from "./peek.js";
import { setSitebar } from "./sitebar.js";
import { ORDER, state, paint } from "./looks.js";

// Classes first: section modules load after this and read them.
const cls = root.classList;
const modes = () =>
  ["fine", "coarse", "pin"].forEach((k) => cls.toggle(k, mq[k].matches));
modes();
for (const k of ["fine", "coarse", "pin"])
  mq[k].addEventListener("change", modes);
cls.add(
  "js",
  CSS.supports("animation-timeline: view()") && params.get("sda") !== "0"
    ? "sda"
    : "no-sda",
);
if (params.has("nosettle")) cls.add("nosettle");
const look = (k) => ORDER.includes(params.get(k)) && params.get(k);
if (look("space")) state.looks[0] = look("space");

/* ---------- nav: the name of the section filling the screen ---------- */
const nav = document.getElementById("nav");
const rows = document.querySelectorAll('#sitebar a.row[href^="#"]');
const secs = document.querySelectorAll("main > section[data-name]");
let name = "";
const nameIO = new IntersectionObserver(
  (es) => {
    for (const { isIntersecting, target: s } of es) {
      if (!isIntersecting || !s.dataset.name || s.dataset.name === name)
        continue;
      name = s.dataset.name;
      for (const t of document.querySelectorAll(".nav-pill-t"))
        t.textContent = name;
      for (const r of rows) {
        const on = r.getAttribute("href") === "#" + s.id;
        r.classList.toggle("g", on);
        r.classList.toggle("lit", on);
        on
          ? r.setAttribute("aria-current", "location")
          : r.removeAttribute("aria-current");
      }
    }
  },
  { rootMargin: "-35% 0px -64% 0px" },
);
for (const s of secs) nameIO.observe(s);

// The nav's Download joins once the hero's has scrolled away above.
const heroGet = document.getElementById("hero-get");
const navGet = nav.querySelector(".get");
// Rects are read fresh: after a restored scroll the observer's only entry can predate layout. The CTA is read only
// while its section is on screen: inside a skipped content-visibility section, a read lays the section out.
const closeGet = document.querySelector(".cta-close .get");
const closeSec = closeGet?.closest("section");
const shown = (r) => r.bottom > 0 && r.top < innerHeight;
function syncGet() {
  const on =
    heroGet.getBoundingClientRect().bottom < 0 &&
    !(
      closeGet &&
      shown(closeSec.getBoundingClientRect()) &&
      shown(closeGet.getBoundingClientRect())
    );
  nav.classList.toggle("has-get", on);
  navGet.tabIndex = on ? 0 : -1;
  navGet.setAttribute("aria-hidden", !on);
}
if (heroGet) {
  const io = new IntersectionObserver(syncGet);
  io.observe(heroGet);
  if (closeGet) io.observe(closeGet);
  addEventListener("pageshow", syncGet);
  addEventListener("load", () => requestAnimationFrame(syncGet));
}

addEventListener("keydown", (e) => {
  const slash = e.key === "/" && !e.metaKey && !e.ctrlKey && !e.altKey;
  const k =
    (e.metaKey || e.ctrlKey) &&
    !e.altKey &&
    !e.shiftKey &&
    e.key.toLowerCase() === "k";
  if (
    (!slash && !k) ||
    e.defaultPrevented ||
    e.isComposing ||
    cls.contains("peek-open")
  )
    return;
  if (
    e.target.closest?.(
      "textarea, select, [contenteditable], input:not([type=radio], [type=checkbox], [type=range])",
    )
  )
    return;
  e.preventDefault();
  if (!keyHandlers.some((fn) => fn(e))) openPageBar();
});

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

/* ---------- the site sidebar wears the look of the replica most recently half visible, and follows its space ---------- */
const sitebarBd = document.querySelector(".sitebar-bd");
const lookOf = new Map();
let owner = null;
let barLook = "tide";
// html[data-accent] records the owner's look for tools; nothing on the page reads it
function accent(l) {
  if (!l) return;
  root.dataset.accent = l;
  if (l === barLook) return;
  barLook = l;
  paint(sitebarBd, l, {
    ms: document.getElementById("sitebar").dataset.open === "true" ? 200 : 0,
  });
}
const follow = new MutationObserver(() => accent(lookOf.get(owner)()));
// A rig is half visible by height, so a window that bleeds off the side still counts. Ownership passes on
// the rising edge only, so two half-visible rigs never trade it back and forth.
const ownerIO = new IntersectionObserver(
  (es) => {
    for (const e of es) {
      const was = e.target.half;
      const h = e.boundingClientRect.height;
      // a rig in a skipped content-visibility subtree has no box yet
      e.target.half = h > 0 && e.intersectionRect.height >= 0.5 * h;
      if (e.target.half && !was && e.target !== owner) {
        owner = e.target;
        follow.disconnect();
        follow.observe(owner, {
          subtree: true,
          attributeFilter: ["data-look"],
        });
        accent(lookOf.get(owner)());
      }
    }
  },
  { threshold: Array.from({ length: 21 }, (_, i) => i / 20) },
);
watchReplicas((rig, fn) => {
  lookOf.set(rig, fn);
  ownerIO.observe(rig);
});
accent(look("accent"));

/* ---------- the bundle runs every other section; a deletable block links its own module from inside it ---------- */
for (const l of document.querySelectorAll(
  'link[rel="modulepreload"][href*="/sections/"]',
))
  import(l.href);

if (params.has("peek")) openPeek(params.get("peek"));
if (params.get("sitebar") === "1") setSitebar(true, { via: "edge" });

const [day, hour] = [
  { weekday: "short", day: "numeric", month: "short" },
  { hour: "numeric", minute: "2-digit" },
].map((o) => new Intl.DateTimeFormat(undefined, o));
(function tick() {
  const now = `${day.format().replace(/,/g, "")} ${hour.format()}`;
  for (const t of document.querySelectorAll(".menubar time"))
    t.textContent = now;
  setTimeout(tick, 60000 - (Date.now() % 60000));
})();
