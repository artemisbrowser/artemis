// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import { root, mq, go } from "./core.js";

const bar = document.getElementById("sitebar");
const btn = document.querySelector(".nav-sb");
let open = false;
let y0 = 0;
let timer = 0;

// via "edge" uses the quicker reveal and leaves focus where it is; via "button" moves focus to the first row.
export function setSitebar(on, { via = "button" } = {}) {
  if (on === open) return;
  open = on;
  y0 = scrollY;
  bar.dataset.via = via;
  bar.dataset.open = on;
  bar.inert = !on;
  root.classList.toggle("sitebar-open", on);
  btn?.setAttribute("aria-expanded", on);
  if (on && via === "button")
    bar.querySelector(".row").focus({ preventScroll: true });
  if (!on && bar.contains(document.activeElement))
    btn?.focus({ preventScroll: true });
}

btn?.addEventListener("click", () => setSitebar(!open));
bar.querySelector(".circ").addEventListener("click", () => setSitebar(false));
bar.addEventListener("click", (e) => {
  const a = e.target.closest("a.row");
  if (!a) return;
  const href = a.getAttribute("href");
  if (
    href.startsWith("#") &&
    !a.dataset.peek &&
    !e.shiftKey &&
    !e.metaKey &&
    !e.altKey
  ) {
    e.preventDefault();
    go(href.slice(1));
  }
  setSitebar(false);
});

// Pointer at the left edge for 100 ms opens it, except while pin 1 owns that edge (html.oow-on).
addEventListener(
  "pointermove",
  (e) => {
    if (e.pointerType === "touch" || !mq.fine.matches) return;
    if (open) {
      if (e.clientX > 300 && !bar.contains(document.activeElement))
        setSitebar(false);
    } else if (e.clientX <= 8 && !root.matches(".oow-on, .peek-open")) {
      timer ||= setTimeout(() => {
        timer = 0;
        setSitebar(true, { via: "edge" });
      }, 100);
    } else {
      clearTimeout(timer);
      timer = 0;
    }
  },
  { passive: true },
);
addEventListener(
  "scroll",
  () => open && Math.abs(scrollY - y0) > 200 && setSitebar(false),
  { passive: true },
);
addEventListener("keydown", (e) => e.key === "Escape" && setSitebar(false));
