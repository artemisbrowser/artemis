// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import { root } from "./core.js";

const MODS = ["ctrl", "alt", "shift", "meta"]; // the app's glyph order, so html[data-mods] reads "shift meta"
const NAMES = {
  Meta: "meta",
  Shift: "shift",
  Alt: "alt",
  Control: "ctrl",
  Enter: "enter",
  Escape: "esc",
  ArrowDown: "down",
  ArrowUp: "up",
  ArrowLeft: "left",
  ArrowRight: "right",
};
const CODES = { Slash: "/", BracketLeft: "[", BracketRight: "]" };
const held = new Set();
const modSet = new Set();
const subs = new Set();

// Letters and digits come from e.code, so ⌥ and ⇧ never change the name.
const nameOf = (e) =>
  NAMES[e.key] ??
  (/^(Key|Digit)./.test(e.code)
    ? e.code.slice(-1).toLowerCase()
    : CODES[e.code]);

function set(k, down) {
  if (!k || held.has(k) === down) return;
  down ? held.add(k) : held.delete(k);
  for (const el of document.querySelectorAll(`.kc[data-k="${k}"]`))
    el.classList.toggle("down", down);
  if (!MODS.includes(k)) return;
  down ? modSet.add(k) : modSet.delete(k);
  const s = MODS.filter((m) => modSet.has(m)).join(" ");
  s ? (root.dataset.mods = s) : delete root.dataset.mods;
  for (const fn of subs) fn(modSet);
}

addEventListener("keydown", (e) => set(nameOf(e), true));
addEventListener("keyup", (e) => {
  const k = nameOf(e);
  // macOS sends no keyup for keys released while ⌘ is held
  if (k === "meta")
    for (const h of [...held]) if (!MODS.includes(h)) set(h, false);
  set(k, false);
});
addEventListener("blur", () => [...held].forEach((k) => set(k, false)));

// The held modifiers as a live Set of "ctrl" "alt" "shift" "meta".
export const mods = () => modSet;
export function onMods(fn) {
  subs.add(fn);
  return () => subs.delete(fn);
}
