// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

// WebKit cancels a page's image loads when a download starts, leaving them complete with no pixels,
// so the steps decode first (up to 3 s) and any image cut off after that loads again.
export async function download(href, imgs) {
  const wait = (ms) => new Promise((r) => setTimeout(r, ms));
  await Promise.race([Promise.allSettled(imgs.map((i) => i.decode())), wait(3000)]);
  location.href = href;
  for (let n = 0; n < 10; n++) {
    await wait(1000);
    for (const i of document.images)
      if (i.complete && !i.naturalWidth && i.getAttribute("src"))
        i.src = i.getAttribute("src");
  }
}

const dmg = document.querySelector(".dl [data-dmg]");
if (dmg) download(dmg.href, [...document.querySelectorAll(".steps img")]);
