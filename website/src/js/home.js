// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import { root } from "./core.js";

// Artemis sets data-artemis to its short version on this site's pages only, digits and dots.
const have = root.dataset.artemis;
const get = document.getElementById("hero-get");
if (have && get) {
  const nums = (v) => v.split(/[^\d.]/)[0].split(".").map(Number);
  const older = (a, b) => {
    const x = nums(a), y = nums(b);
    for (let i = 0; i < Math.max(x.length, y.length); i++)
      if ((x[i] || 0) !== (y[i] || 0)) return (x[i] || 0) < (y[i] || 0);
    return false;
  };
  const short = (v) => v.replace(/^(\d+\.\d+)\.0$/, "$1");
  const latest = get.dataset.latest;
  const label = get.querySelector(".get-label");
  root.classList.add("home");
  document.querySelector(".hero-tag").textContent = "Welcome home.";
  if (latest && older(have, latest)) label.textContent = `Update ready: Artemis ${short(latest)}`;
  else {
    label.textContent = `You’re on Artemis ${short(have)} ✓`;
    get.removeAttribute("href");
    get.removeAttribute("data-get");
    get.classList.add("is-current");
  }
  get.parentElement.querySelector(".fine").textContent = "Home icon unlocked in Settings › Customization.";
}
