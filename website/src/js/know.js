// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import { mq, spring, mix, frames, sampled } from "./core.js";

// A pill grows into its card in place and the stage swaps to its picture. Stage child 0 is the closed view.
for (const v of document.querySelectorAll("[data-viewer]")) {
  const list = v.querySelector(".pills");
  const items = [...list.children];
  const shots = [...v.querySelector(".stage").children];
  const [up, down] = v.querySelectorAll(".step");
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
      // [width, height, head start in seconds]: the column, then the row closing, opening and stepping
      const one = (s, lead = 0) => [s, s, lead];
      const [sw, sh, lead] = !isRow() ? one(spring(0.72, 15), -0.017) : i < 0 ? one(spring(0.99, 23), 0.025) : cur < 0 ? [spring(0.65, 17.5), spring(0.6, 13.5), 0] : one(spring(0.9, 14.5), 0.017);
      const tween = (s, f) => frames((t) => f(s(t + lead)));
      // sizes run through layout, so the others follow; a translate covers what layout cannot, like the scroll jump
      const to = items.map((li) => li.getBoundingClientRect());
      items.forEach((li, j) => {
        if (from[j].width !== to[j].width || from[j].height !== to[j].height)
          live.push(li.animate({ width: tween(sw, (u) => px(mix(from[j].width, to[j].width, u))), height: tween(sh, (u) => px(mix(from[j].height, to[j].height, u))) }, sampled));
      });
      const start = items.map((li) => li.getBoundingClientRect());
      items.forEach((li, j) => {
        const dx = from[j].left - start[j].left;
        const dy = from[j].top - start[j].top;
        if (Math.abs(dx) > 0.5 || Math.abs(dy) > 0.5) live.push(li.animate({ translate: tween(sw, (u) => `${dx * (1 - u)}px ${dy * (1 - u)}px`) }, sampled));
      });
    }
    if (focus) (i >= 0 ? items[i].querySelector("p") : items[cur].querySelector("button")).focus({ preventScroll: true });
    cur = i;
  }
  const isRow = () => items[1].offsetLeft > items[0].offsetLeft;
  function enter() {
    list.classList.add("in");
    if (mq.reduce.matches) return;
    const r = items.map((li) => li.getBoundingClientRect());
    const buttons = items.map((li) => li.querySelector("button"));
    const glass = getComputedStyle(items[0]).backgroundColor;
    const solid = glass.replace(/[\d.]+\)$/, "1)");
    const late = (duration, delay, easing = "linear") => ({ duration, delay, easing, fill: "backwards" });
    const fade = "cubic-bezier(0.3, 0, 1, 1)";
    if (isRow()) {
      // one blob rises to the foot of the screen, widens from the middle into a bar, and the bar parts into the pills
      const rise = spring(0.42, 11);
      const grow = spring(0.52, 11.5);
      const ease = spring(0.98, 10);
      const gap = r[1].left - r[0].right;
      const mid = innerWidth / 2;
      const size = (j, t) => {
        if (j || t >= 0.454) return [mix(40, r[j].width, grow(t - 0.454)), mix(36, r[j].height, ease(t - 0.62))];
        const s = 0.7 + 0.6 * Math.exp(-t / 0.135);
        return [(30 + 26 * rise(t - 0.04)) * s, (80 - 24 * rise(t - 0.17)) * s];
      };
      list.animate(frames((t) => ({ translate: `0 ${180 * (1 - rise(t))}px` })), sampled);
      items.forEach((li, j) => {
        li.animate(
          frames((t) => {
            const [w, h] = size(j, t);
            // widths run through layout, so the translate is measured from where layout has put the pill
            let x = r[0].left;
            for (let i = 0; i < j; i++) x += size(i, t)[0] + gap;
            const sy = Math.max(1, h / r[j].height);
            const round = Math.min(w, r[j].height) / 2;
            return {
              width: `${w}px`,
              translate: `${(t < 0.454 ? mid - w / 2 : mix(mid - 20, r[j].left, ease(t - 0.53))) - x}px ${j || t >= 0.454 ? 0 : 0.18 * (36 - h)}px`,
              scale: `1 ${sy}`,
              borderRadius: `${round}px / ${round / sy}px`,
              clipPath: `inset(${Math.max(0, (r[j].height - h) / 2)}px 0 round 28px)`,
            };
          }),
          sampled,
        );
        if (j) li.animate({ opacity: [0, 0] }, 454);
        li.animate({ backgroundColor: [solid, glass] }, late(500, 1000, "ease-out"));
        buttons[j].animate({ opacity: [0, 1] }, late(270, 775, fade));
      });
      return;
    }
    // a circle grows in from the left to where the middle pill sits and widens into it; the others swell out above and below it
    const m = (items.length - 1) >> 1;
    const pop = spring(0.56, 11.5);
    const widen = spring(0.72, 24.5);
    const swell = spring(0.7, 18);
    const settle = spring(0.7, 14.5);
    items.forEach((li, j) => {
      const k = Math.abs(j - m);
      const { width, height } = r[j];
      if (!k) {
        li.animate(
          frames((t) => {
            const s = t < 0.548 ? pop(t) : 1;
            return { width: `${mix(height, width, widen(t - 0.548))}px`, scale: s, translate: `${100 * (s - 1)}px 0` };
          }),
          sampled,
        );
        li.animate({ backgroundColor: [solid, solid] }, 548);
        buttons[j].animate({ opacity: [0, 1] }, late(230, 789, fade));
        return;
      }
      const at = 0.502 + 0.046 * k;
      const dir = Math.sign(m - j);
      li.animate(
        frames((t) => {
          const u = swell(t - at);
          const w = mix(height, width, u);
          return { width: `${w}px`, transformOrigin: "bottom", scale: mix(0.5, 1, u), translate: `${(width - w) / 2}px ${dir * 35 * (1 - settle(t - 0.594))}px` };
        }),
        sampled,
      );
      li.animate({ opacity: [0, 1] }, late(35, 642));
      buttons[j].animate({ opacity: [0, 1] }, late(350, 716 + 37 * k, fade));
      buttons[j].animate({ translate: [`0 ${dir * 4}px`, "0 0"] }, late(250, 800, "ease-out"));
    });
  }
  // desktop: 60% of the viewer on screen. Phone: the row's stuck place, 284px into the viewer, on screen.
  const need = Math.min(isRow() ? 284 : 0.6 * v.offsetHeight, 0.8 * innerHeight);
  new IntersectionObserver(
    ([e], io) => {
      if (!e.isIntersecting && e.boundingClientRect.top > 0) return;
      io.disconnect();
      enter();
    },
    { rootMargin: `0px 0px -${need}px 0px` },
  ).observe(v);

  items.forEach((li, i) => (li.querySelector("[aria-expanded]").onclick = () => show(i, true)));
  v.querySelector(".shut").onclick = () => show(-1, true);
  for (const b of [up, down]) b.onclick = () => show(cur + +b.dataset.step, false);
  // phone: a one-finger sideways swipe on an open card steps like the chevrons
  let x0, y0;
  v.addEventListener("touchstart", (e) => ([x0, y0] = e.touches.length > 1 ? [NaN, NaN] : [e.touches[0].clientX, e.touches[0].clientY]), { passive: true });
  v.addEventListener(
    "touchend",
    (e) => {
      const t = e.changedTouches[0];
      const dx = t.clientX - x0;
      const to = cur - Math.sign(dx);
      if (cur >= 0 && isRow() && Math.abs(dx) > 40 && Math.abs(dx) > 2 * Math.abs(t.clientY - y0) && items[to]) show(to, false);
    },
    { passive: true },
  );
  v.addEventListener("keydown", (e) => {
    if (e.key === "Escape" && cur >= 0) show(-1, true);
  });
}
