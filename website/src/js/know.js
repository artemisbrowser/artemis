// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import { mq } from "./core.js";

// A pill opens into its card and swaps the stage to its picture. Stage child 0 is the closed view.
for (const v of document.querySelectorAll("[data-viewer]")) {
  const items = [...v.querySelectorAll(".pills > li")];
  const shots = [...v.querySelector(".stage").children];
  const [up, down] = v.querySelectorAll(".step");
  let cur = -1;

  function show(i, focus) {
    const run = () => {
      items.forEach((li, j) => {
        li.classList.toggle("open", j === i);
        li.querySelector("[aria-expanded]").setAttribute("aria-expanded", j === i);
        li.querySelector("p").hidden = j !== i;
      });
      shots.forEach((s, j) => s.classList.toggle("on", j === i + 1));
      v.classList.toggle("active", i >= 0);
      up.disabled = i <= 0;
      down.disabled = i === items.length - 1;
      if (focus) (i >= 0 ? items[i].querySelector("p") : items[cur].querySelector("button")).focus({ preventScroll: true });
      cur = i;
    };
    if (document.startViewTransition && !mq.reduce.matches) document.startViewTransition(run);
    else run();
  }

  items.forEach((li, i) => (li.querySelector("[aria-expanded]").onclick = () => show(i, true)));
  v.querySelector(".shut").onclick = () => show(-1, true);
  for (const b of [up, down]) b.onclick = () => show(cur + +b.dataset.step, false);
  v.addEventListener("keydown", (e) => {
    if (e.key === "Escape" && cur >= 0) show(-1, true);
  });
}
