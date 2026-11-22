// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import { mq } from "./core.js";

// A pill grows into its card in place and the stage swaps to its picture. Stage child 0 is the closed view.
for (const v of document.querySelectorAll("[data-viewer]")) {
  const list = v.querySelector(".pills");
  const items = [...list.children];
  const shots = [...v.querySelector(".stage").children];
  const [up, down] = v.querySelectorAll(".step");
  const css = getComputedStyle(v);
  const spring = { duration: parseFloat(css.getPropertyValue("--dur-pill")), easing: css.getPropertyValue("--spring-pill") };
  const px = (n) => n + "px";
  let cur = -1;
  let live = [];
  for (const li of items) li.querySelector("p").hidden = false;

  // Sizes animate between the measured states. On a phone the row also scrolls the card to the middle,
  // and every pill starts offset by that jump so nothing moves on the first frame.
  function show(i, focus) {
    const moved = [...new Set([cur, i])].filter((j) => j >= 0);
    const from = moved.map((j) => items[j].getBoundingClientRect());
    const lead = items[0].getBoundingClientRect().left;
    for (const a of live.splice(0)) a.cancel();
    items.forEach((li, j) => {
      li.classList.toggle("open", j === i);
      li.querySelector("[aria-expanded]").setAttribute("aria-expanded", j === i);
    });
    shots.forEach((s, j) => s.classList.toggle("on", j === i + 1));
    v.classList.toggle("active", i >= 0);
    up.disabled = i <= 0;
    down.disabled = i === items.length - 1;
    if (i >= 0) list.scrollLeft = items[i].offsetLeft - (list.clientWidth - items[i].offsetWidth) / 2;
    if (!mq.reduce.matches) {
      const to = moved.map((j) => items[j].getBoundingClientRect());
      live = moved.map((j, k) =>
        items[j].animate({ width: [from[k].width, to[k].width].map(px), height: [from[k].height, to[k].height].map(px) }, spring),
      );
      const dx = lead - items[0].getBoundingClientRect().left;
      if (dx) for (const li of items) live.push(li.animate({ translate: [`${dx}px 0`, "0 0"] }, spring));
    }
    if (focus) (i >= 0 ? items[i].querySelector("p") : items[cur].querySelector("button")).focus({ preventScroll: true });
    cur = i;
  }

  // One circle pops at the middle of the stack (the start of the row on a phone), then bursts into the pills.
  function enter() {
    list.classList.add("in");
    if (mq.reduce.matches) return;
    const r = items.map((li) => li.getBoundingClientRect());
    const y = r[1].top === r[0].top ? r[0].top : (r[0].top + r.at(-1).bottom - r[0].height) / 2;
    const burst = { ...spring, delay: 600, fill: "backwards" };
    items.forEach((li, j) => {
      li.animate(
        {
          translate: [`${r[0].left - r[j].left}px ${y - r[j].top}px`, "0 0"],
          clipPath: [`inset(0 calc(100% - ${r[j].height}px) 0 0 round 28px)`, "inset(0 0 0 0 round 28px)"],
        },
        burst,
      );
      if (j) li.animate({ opacity: [0, 1] }, { duration: 30, delay: 600, fill: "backwards" });
      li.querySelector("span").animate({ opacity: [0, 1] }, { duration: 350, delay: 700 + 70 * j, fill: "backwards" });
    });
    items[0].animate({ scale: [0, 1] }, { duration: parseFloat(css.getPropertyValue("--dur-pop")), easing: css.getPropertyValue("--spring-pop") });
  }
  new IntersectionObserver(
    ([e], io) => {
      if (!e.isIntersecting && e.boundingClientRect.top > 0) return;
      io.disconnect();
      enter();
    },
    { rootMargin: "0px 0px -12% 0px" },
  ).observe(list);

  items.forEach((li, i) => (li.querySelector("[aria-expanded]").onclick = () => show(i, true)));
  v.querySelector(".shut").onclick = () => show(-1, true);
  for (const b of [up, down]) b.onclick = () => show(cur + +b.dataset.step, false);
  v.addEventListener("keydown", (e) => {
    if (e.key === "Escape" && cur >= 0) show(-1, true);
  });
}
