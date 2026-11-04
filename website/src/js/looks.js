// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

export const ORDER = [
  "nebula",
  "ember",
  "tide",
  "aurora",
  "sunset",
  "bloom",
  "ink",
  "charcoal",
];
export const state = { looks: ["tide", "charcoal", "ember"] };
const subs = new Set();

// A host holds exactly two .lk layers. The outgoing one stays opaque under the incoming fade, then drops its look.
export function paint(
  host,
  look,
  { ms = 0, ease = "cubic-bezier(.42,0,.58,1)" } = {},
) {
  const [a, b] = host.children;
  const top = a.hasAttribute("data-top") ? a : b;
  host.anim?.finish();
  host.done?.();
  if (top.dataset.look === look) return;
  const next = top === a ? b : a;
  next.dataset.look = look;
  next.setAttribute("data-top", "");
  top.removeAttribute("data-top");
  top.style.opacity = 1;
  const done = (host.done = () => {
    host.done = host.anim = null;
    top.style.opacity = "";
    delete top.dataset.look;
  });
  if (!ms) return done();
  host.anim = next.animate({ opacity: [0, 1] }, { duration: ms, easing: ease });
  host.anim.onfinish = () => host.done === done && done();
}

export function setLook(spaceIndex, look, opts = {}) {
  const L = state.looks;
  if (L[spaceIndex] === look) return;
  const j = L.indexOf(look);
  L[spaceIndex] = look;
  if (j >= 0) {
    const k = ORDER.indexOf(look) + 1;
    L[j] = [...ORDER.slice(k), ...ORDER.slice(0, k)].find(
      (x) => !L.includes(x),
    );
  }
  for (const fn of subs) fn(state, opts);
}

export function subscribe(fn) {
  subs.add(fn);
  return () => subs.delete(fn);
}
