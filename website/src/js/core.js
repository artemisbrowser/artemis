// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

// Shared state with no imports. Every other module may import this one.
export const root = document.documentElement;
export const params = new URLSearchParams(location.search);
export const mq = {
  reduce: matchMedia("(prefers-reduced-motion: reduce)"),
  fine: matchMedia("(hover: hover) and (pointer: fine)"),
  coarse: matchMedia("(hover: none) and (pointer: coarse)"),
  phone: matchMedia("(max-width: 734px)"),
};

// Position of a damped spring released at rest, 0 to 1, t in seconds.
export const spring = (zeta, omega) => (t) => {
  if (t <= 0) return 0;
  const wd = omega * Math.sqrt(1 - zeta * zeta);
  return 1 - Math.exp(-zeta * omega * t) * (Math.cos(wd * t) + ((zeta * omega) / wd) * Math.sin(wd * t));
};
export const mix = (a, b, u) => a + (b - a) * u;
// Keyframes of fn(seconds) at 60 a second; `sampled` is the timing that plays them in real time.
export const frames = (fn) => Array.from({ length: 103 }, (_, k) => fn(k / 60));
export const sampled = { duration: 1700, easing: "linear" };

// Also moves focus to the section's heading. Skipped content-visibility sections resize mid-flight, so a
// jump that ran its course (the reader did not take over) is re-aimed once on landing.
export function go(id) {
  const s = document.getElementById(id);
  if (!s) return;
  if (s.open === false) s.open = true;
  const behavior = mq.reduce.matches ? "auto" : "smooth";
  const off = () =>
    s.getBoundingClientRect().top -
    parseFloat(getComputedStyle(root).scrollPaddingTop);
  const aim = Math.min(scrollY + off(), root.scrollHeight - innerHeight);
  const ac = new AbortController();
  const fix = () => {
    ac.abort();
    if (Math.abs(scrollY - aim) < 2 && Math.abs(off()) > 1)
      s.scrollIntoView({ behavior });
  };
  s.scrollIntoView({ behavior });
  "onscrollend" in window
    ? addEventListener("scrollend", fix, { signal: ac.signal })
    : setTimeout(fix, 900);
  setTimeout(() => ac.abort(), 2500);
  const h = s.querySelector("h1, h2") ?? s;
  h.tabIndex = -1;
  h.focus({ preventScroll: true });
}
