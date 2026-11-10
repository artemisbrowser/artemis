// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

// WebKit cancels a page's loads when a download starts, so the clips load first (up to 3 s)
// and any image or clip cut off after that loads again.
export async function download(href, clips) {
  const wait = (ms) => new Promise((r) => setTimeout(r, ms));
  const ready = (v) =>
    v.readyState === 4 ||
    new Promise((r) => v.addEventListener("canplaythrough", r, { once: true }));
  await Promise.race([Promise.all(clips.map(ready)), wait(3000)]);
  location.href = href;
  for (let n = 0; n < 10; n++) {
    await wait(1000);
    for (const i of document.images)
      if (i.complete && !i.naturalWidth && i.getAttribute("src"))
        i.src = i.getAttribute("src");
    for (const v of clips) if (v.error && v.isConnected) v.load();
  }
}
const dmg = document.querySelector(".dl [data-dmg]");
if (dmg) {
  const clips = [...document.querySelectorAll(".steps video")];
  if (!matchMedia("(prefers-reduced-motion: reduce)").matches)
    for (const v of clips) v.play().catch(() => {});
  download(dmg.href, clips);
}
