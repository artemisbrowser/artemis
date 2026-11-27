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
  // the app marks pages loaded after the visit that unlocked the icon, so this shows on that visit only
  if (!root.dataset.artemisIcon) setTimeout(egg, 1200);
}

function egg() {
  const box = document.createElement("div");
  box.className = "egg surface";
  box.setAttribute("role", "dialog");
  box.setAttribute("aria-labelledby", "egg-t");
  box.setAttribute("aria-describedby", "egg-d");
  box.tabIndex = -1;
  box.innerHTML = `<img class="light" src="/assets/img/home-icon-light.webp" width="168" height="168" alt="" />
    <img class="dark" src="/assets/img/home-icon-dark.webp" width="168" height="168" alt="" />
    <div>
      <p class="egg-t" id="egg-t">Browsing Artemis… on Artemis?!</p>
      <p class="egg-d" id="egg-d">You patriot, you.<br />Here, have an app icon 😉</p>
      <p class="fine">It’s in Settings › Customization.</p>
    </div>
    <button class="egg-x" type="button" aria-label="Close"><svg class="ico" aria-hidden="true"><use href="#i-xmark" /></svg></button>`;
  document.body.append(box);
  const back = document.activeElement;
  const ac = new AbortController();
  const close = () => {
    ac.abort();
    if (box.contains(document.activeElement))
      back && back !== document.body ? back.focus({ preventScroll: true }) : document.activeElement.blur();
    box.classList.remove("on");
    setTimeout(() => box.remove(), 200);
  };
  box.querySelector("button").addEventListener("click", close, { signal: ac.signal });
  addEventListener("keydown", (e) => e.key === "Escape" && close(), { signal: ac.signal });
  addEventListener("pointerdown", (e) => box.contains(e.target) || close(), { signal: ac.signal });
  requestAnimationFrame(() => requestAnimationFrame(() => {
    box.classList.add("on");
    box.focus({ preventScroll: true });
  }));
}
