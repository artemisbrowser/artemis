// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import { mq, spring, mix, frames, sampled } from "./core.js";

const rise = spring(0.42, 10.5);
const grow = spring(0.52, 10.5);
const out = (u) => 1 - (1 - Math.min(1, Math.max(0, u))) ** 2;
// cubic-bezier(0.4, 0, 0.55, 1)
function glideEase(u) {
  let t = u;
  for (let k = 0; k < 6; k++) {
    const x = 1.2 * (1 - t) ** 2 * t + 1.65 * (1 - t) * t * t + t ** 3;
    t -= (x - u) / (1.2 * (1 - t) ** 2 + 0.9 * (1 - t) * t + 1.35 * t * t || 1);
  }
  return 3 * (1 - t) * t * t + t ** 3;
}

// A dot fills over one slide's dwell and the gallery advances when the fill ends, so pausing the fill
// pauses the gallery. Dots, tabs, caption and slide copy follow the scroll position. Without a
// .gallery-ctl there are no dots and no autoplay.
for (const g of document.querySelectorAll("[data-gallery]")) {
  const track = g.querySelector(".gallery-track");
  const items = [...track.children];
  const ctl = g.querySelector(".gallery-ctl");
  const nav = g.querySelector(".dotnav");
  const dots = g.querySelector(".dots");
  const play = g.querySelector(".playpause");
  const tablist = g.querySelector(".gallery-tabs");
  const bar = tablist.querySelector(".gallery-bar");
  const caps = [...g.querySelectorAll(".gallery-caps p")];
  let cur = -1;
  // play: the fill runs. hold: frozen mid-fill. stop: no fill. end: the last slide's fill is done.
  let mode = ctl && !mq.reduce.matches ? "play" : "stop";
  let seen = false;
  let glide = 0;
  let fill;
  let at = 0;

  // where the track rests on each slide; the last ones rest at the track's end
  const stops = () => items.map((it) => Math.min(it.offsetLeft - items[0].offsetLeft, track.scrollWidth - track.clientWidth));
  function settle() {
    cancelAnimationFrame(glide);
    track.classList.remove("gliding");
  }
  function to(i) {
    settle();
    const x0 = track.scrollLeft;
    const x1 = stops()[i];
    if (mq.reduce.matches || x0 === x1) return void (track.scrollLeft = x1);
    const t0 = performance.now();
    let last = x0;
    track.classList.add("gliding");
    // a scroll that is not ours means the reader took over
    const step = (t) => {
      if (Math.abs(track.scrollLeft - last) > 2) return set("stop");
      const u = Math.min(1, Math.max(0, (t - t0) / (+g.dataset.glide || 975)));
      track.scrollLeft = x0 + (x1 - x0) * glideEase(u);
      last = track.scrollLeft;
      if (u < 1) glide = requestAnimationFrame(step);
      else settle();
    };
    glide = requestAnimationFrame(step);
  }

  const pick = (i) => {
    set("stop");
    to(i);
  };
  // the dots are a pointer shortcut; the tabs are the keyboard and screen reader control
  const pips = (ctl ? items : []).map((_, i) => {
    const li = document.createElement("li");
    const b = document.createElement("button");
    b.className = "dot";
    b.type = "button";
    b.tabIndex = -1;
    b.onclick = () => pick(i);
    li.append(b);
    dots.append(li);
    return b;
  });
  const tabs = items.map((it, i) => {
    const b = document.createElement("button");
    b.type = "button";
    b.id = `${g.id}-tab-${i}`;
    b.setAttribute("role", "tab");
    b.setAttribute("aria-controls", caps[i].id);
    b.textContent = it.dataset.tab ?? it.querySelector("h2, h3").textContent;
    b.onclick = () => pick(i);
    caps[i].setAttribute("aria-labelledby", b.id);
    bar.before(b);
    return b;
  });
  // The fill starts a cap's width off the dot, so a glide to the next slide is over before it shows.
  function dwell(i) {
    fill?.cancel();
    at = i;
    const from = getComputedStyle(pips[i], "::after").translate;
    fill = pips[i].animate({ translate: [from, "0 0"] }, { duration: 6150, fill: "forwards", pseudoElement: "::after" });
    fill.onfinish = () => {
      if (i === items.length - 1) return set("end");
      to(i + 1);
      dwell(i + 1);
    };
    if (!seen) fill.pause();
  }
  function set(m) {
    mode = m;
    if (m === "stop") {
      settle();
      fill?.cancel();
    }
    if (!ctl) return;
    const [icon, label] = { play: ["#i-pause", "Pause"], end: ["#i-replay", "Replay"] }[m] ?? ["#i-play", "Play"];
    play.querySelector("use").setAttribute("href", icon);
    play.setAttribute("aria-label", `${label} the highlights`);
  }
  function sync() {
    const xs = stops();
    const j = Math.max(0, Math.min(items.length - 2, xs.findLastIndex((x) => x <= track.scrollLeft)));
    const f = j + (track.scrollLeft - xs[j]) / (xs[j + 1] - xs[j] || 1);
    items.forEach((it, i) => {
      const d = Math.max(-1, Math.min(1, i - f));
      const k = 1 - Math.abs(d);
      it.style.setProperty("--d", d.toFixed(4));
      it.style.setProperty("--o", (k ** 3).toFixed(4));
      pips[i]?.style.setProperty("--k", k.toFixed(4));
    });
    // the underline slides between neighbouring tabs as the track does
    const u = f - j;
    const [a, b] = [tabs[j], tabs[j + 1]];
    bar.style.width = `${a.offsetWidth + (b.offsetWidth - a.offsetWidth) * u}px`;
    bar.style.translate = `${a.offsetLeft + (b.offsetLeft - a.offsetLeft) * u}px 0`;
    const i = Math.min(items.length - 1, Math.round(f));
    if (i === cur) return;
    cur = i;
    if (mode === "play" && i !== at && !track.classList.contains("gliding")) set("stop");
    tabs.forEach((b, j) => {
      b.setAttribute("aria-selected", j === i);
      b.tabIndex = j === i ? 0 : -1;
      caps[j].classList.toggle("on", j === i);
      caps[j].setAttribute("aria-hidden", j !== i);
      items[j].classList.toggle("off", j !== i);
    });
  }

  // One blob rises, widens into the dot bar and lets the play button out to its right.
  function enter() {
    if (!ctl.classList.contains("wait")) return;
    ctl.classList.remove("wait");
    if (mode === "play") dwell(cur);
    if (mq.reduce.matches) return;
    const c = ctl.getBoundingClientRect();
    const n = nav.getBoundingClientRect();
    const p = play.getBoundingClientRect();
    const mid = c.left + c.width / 2 - (n.left + n.width / 2);
    const away = c.left + c.width / 2 - 20 - (p.left + p.width / 2);
    const late = (duration, delay, easing) => ({ duration, delay, easing, fill: "backwards" });
    ctl.animate(frames((t) => ({ translate: `0 ${180 * (1 - rise(t))}px` })), sampled);
    nav.animate(
      frames((t) => {
        const shrink = out((t - 0.25) / 0.18);
        return {
          width: `${mix(mix(52, 41, shrink), n.width, grow(t - 0.44))}px`,
          height: `${mix(mix(47, 37, shrink), n.height, grow(t - 0.65))}px`,
          translate: `calc(-50% + ${mid * (1 - out((t - 0.44) / 0.6))}px) -50%`,
        };
      }),
      { ...sampled, pseudoElement: "::before" },
    );
    play.animate(frames((t) => ({ translate: `${away * (1 - out((t - 0.5) / 0.6))}px 0` })), sampled);
    play.animate(
      frames((t) => ({
        width: `${(p.width / 56) * (50 * out((t - 0.5) / 0.25) + 6 * Math.min(1, Math.max(0, (t - 0.95) / 0.35)))}px`,
        height: `${p.height * Math.min(1, Math.max(0, (t - 0.5) / 0.47))}px`,
      })),
      { ...sampled, pseudoElement: "::before" },
    );
    const glass = getComputedStyle(nav, "::before").backgroundColor;
    const solid = { backgroundColor: [glass.replace(/[\d.]+\)$/, "1)"), glass] };
    for (const el of [nav, play]) el.animate(solid, { ...late(400, 1000, "ease"), pseudoElement: "::before" });
    const dot = pips[cur];
    dots.animate({ opacity: [0, 1] }, late(100, 740, "ease-in"));
    dots.animate({ translate: ["28px 0", "0 0"] }, late(300, 850, "ease-out"));
    dot.animate({ width: ["8px", `${dot.offsetWidth}px`] }, late(230, 780, "ease-out"));
    const ico = play.querySelector(".ico");
    ico.animate({ opacity: [0, 1] }, late(100, 940, "ease-in"));
    ico.animate({ scale: [0.5, 1] }, late(200, 940, "ease-out"));
  }

  track.addEventListener("scroll", sync, { passive: true });
  addEventListener("resize", sync);
  track.addEventListener("pointerdown", () => set("stop"));
  // a tap on a slide beside the one in view brings it in, and does not open its Learn more
  track.addEventListener(
    "click",
    (e) => {
      const i = items.indexOf(e.target.closest(".gallery-track > li"));
      if (i < 0 || i === cur) return;
      e.preventDefault();
      e.stopPropagation();
      pick(i);
    },
    true,
  );
  tablist.addEventListener("keydown", (e) => {
    const i = { ArrowLeft: cur - 1, ArrowRight: cur + 1, Home: 0, End: items.length - 1 }[e.key];
    if (i === undefined || !items[i]) return;
    e.preventDefault();
    tabs[i].focus();
    pick(i);
  });
  sync();
  set(mode);
  if (!ctl) continue;
  nav.style.setProperty("--n", items.length);
  play.addEventListener("click", () => {
    if (mode === "play") fill.pause();
    else if (mode === "hold") fill.play();
    else {
      if (mode === "end") to(0);
      dwell(mode === "end" ? 0 : cur);
    }
    set(mode === "play" ? "hold" : "play");
  });
  ctl.addEventListener("focusin", enter);
  new IntersectionObserver(
    ([e]) => {
      seen = e.intersectionRatio >= 0.5;
      if (e.intersectionRatio >= 0.6) setTimeout(enter, 100);
      if (mode === "play") fill?.[seen ? "play" : "pause"]();
    },
    { threshold: [0.5, 0.6] },
  ).observe(track);

  ctl.classList.add("wait");
}
