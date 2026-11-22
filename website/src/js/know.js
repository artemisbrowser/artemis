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
    const from = items.map((li) => li.getBoundingClientRect());
    for (const a of live.splice(0)) a.cancel();
    items.forEach((li, j) => {
      li.classList.toggle("open", j === i);
      li.querySelector("[aria-expanded]").setAttribute("aria-expanded", j === i);
    });
    shots.forEach((s, j) => s.classList.toggle("on", j === i + 1));
    v.classList.toggle("active", i >= 0);
    v.classList.toggle("swap", cur >= 0 && i >= 0);
    up.disabled = i <= 0;
    down.disabled = i === items.length - 1;
    const at = items[i < 0 ? cur : i];
    list.scrollLeft = at.offsetLeft - (list.clientWidth - at.offsetWidth) / 2;
    if (!mq.reduce.matches) {
      // sizes run through layout, so the others follow; a translate covers what layout cannot, like the scroll jump
      const to = items.map((li) => li.getBoundingClientRect());
      items.forEach((li, j) => {
        if (from[j].width !== to[j].width || from[j].height !== to[j].height)
          live.push(li.animate({ width: [from[j].width, to[j].width].map(px), height: [from[j].height, to[j].height].map(px) }, spring));
      });
      const start = items.map((li) => li.getBoundingClientRect());
      items.forEach((li, j) => {
        const dx = from[j].left - start[j].left;
        const dy = from[j].top - start[j].top;
        if (Math.abs(dx) > 0.5 || Math.abs(dy) > 0.5) live.push(li.animate({ translate: [`${dx}px ${dy}px`, "0 0"] }, spring));
      });
    }
    if (focus) (i >= 0 ? items[i].querySelector("p") : items[cur].querySelector("button")).focus({ preventScroll: true });
    cur = i;
  }
  function enter() {
    list.classList.add("in");
    if (mq.reduce.matches) return;
    const r = items.map((li) => li.getBoundingClientRect());
    const row = r[1].top === r[0].top;
    const y = row ? r[0].top : (r[0].top + r.at(-1).bottom - r[0].height) / 2;
    const burst = { ...spring, delay: 540, fill: "backwards" };
    // a row opens as one bar from the middle of the screen: it slides to its place slower than the pills part
    if (row) list.animate({ translate: [`${(innerWidth - r[0].height) / 2 - r[0].left}px 0`, "0 0"] }, { ...burst, duration: 700, easing: "cubic-bezier(0.4, 0, 0.2, 1)" });
    items.forEach((li, j) => {
      li.animate({ translate: [`${r[0].left - r[j].left}px ${y - r[j].top}px`, "0 0"] }, row ? { ...burst, duration: 480, easing: "ease-in-out" } : burst);
      li.animate({ clipPath: [`inset(0 calc(100% - ${r[j].height}px) 0 0 round 28px)`, "inset(0 0 0 0 round 28px)"] }, burst);
      if (j) li.animate({ opacity: [0, 1] }, { duration: 30, delay: 540, fill: "backwards" });
      li.querySelector("button").animate({ opacity: [0, 1] }, { duration: 370, delay: 860 + 12 * j, fill: "backwards" });
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
