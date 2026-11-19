// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import { mq } from "./core.js";

// An autoplaying gallery advances when the active dot's fill animation ends, so pausing the fill pauses the gallery.
for (const g of document.querySelectorAll("[data-gallery]")) {
  const track = g.querySelector(".gallery-track");
  const items = [...track.children];
  const dots = g.querySelector(".dots");
  const play = g.querySelector(".playpause");
  let cur = -1;
  let playing = !!play && !mq.reduce.matches;
  let seen = false;

  const left = (i) => items[i].offsetLeft - items[0].offsetLeft;
  const to = (i) =>
    track.scrollTo({
      left: left(i),
      behavior: mq.reduce.matches ? "auto" : "smooth",
    });

  const tabs = items.map((it, i) => {
    const li = document.createElement("li");
    li.setAttribute("role", "presentation");
    const b = document.createElement("button");
    b.className = "dot";
    b.type = "button";
    b.setAttribute("role", "tab");
    b.setAttribute("aria-label", it.querySelector("h2, h3").textContent);
    b.onclick = () => to(i);
    li.append(b);
    dots?.append(li);
    return b;
  });

  function mark(i) {
    if (i === cur) return;
    cur = i;
    tabs.forEach((b, j) => {
      b.setAttribute("aria-selected", j === i);
      b.tabIndex = j === i ? 0 : -1;
    });
  }
  function state() {
    g.classList.toggle("playing", playing);
    g.classList.toggle("paused", !seen);
    if (!play) return;
    play.querySelector("use").setAttribute("href", playing ? "#i-pause" : "#i-play");
    play.setAttribute("aria-label", playing ? "Pause the highlights" : "Play the highlights");
  }

  track.addEventListener("scroll", () => {
    const x = track.scrollLeft;
    let best = 0;
    items.forEach((_, i) => {
      if (Math.abs(left(i) - x) < Math.abs(left(best) - x)) best = i;
    });
    mark(best);
  }, { passive: true });
  track.addEventListener("pointerdown", () => {
    playing = false;
    state();
  });
  dots?.addEventListener("animationend", (e) => {
    if (e.animationName === "dwell") to((cur + 1) % items.length);
  });
  dots?.addEventListener("keydown", (e) => {
    const d = { ArrowLeft: -1, ArrowRight: 1 }[e.key];
    if (!d || !items[cur + d]) return;
    to(cur + d);
    tabs[cur + d].focus();
  });
  play?.addEventListener("click", () => {
    playing = !playing;
    state();
  });
  new IntersectionObserver(([e]) => {
    seen = e.isIntersecting;
    state();
  }, { threshold: 0.5 }).observe(track);

  mark(0);
  state();
}
