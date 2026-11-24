// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

// canonical, og:url, og:image, JSON-LD, sitemap and the link capsule's host.
export const DOMAIN = "artemisbrowser.app";
// a price string such as "Free", or null; adds " {PRICE}." to every fine print line and offers to JSON-LD.
export const PRICE = "Free";
// a release stage such as "Public alpha", or null; leads both fine print lines and joins every description.
export const STAGE = null;
// the release DMG; when set, Download shows the four steps to open it and starts it, else /download says none yet.
export const DOWNLOAD_URL = "https://github.com/artemisbrowser/artemis/releases/download/v1.1.0-2/Artemis-1.1.0-2.dmg";
// the Arc block ships only while this is true and src/partials/07-arc.html exists.
export const ARC_BLOCK = true;
// the real sites in the screenshots, each mapped to the credit the home page must carry, or "" when none is owed.
export const HOSTS = {
  "en.wikipedia.org": "Wikipedia text under CC BY-SA 4.0",
  "github.com": "",
  "science.nasa.gov": "",
};

// Fin's note in the closing section, in his words; it may name Arc in either build.
export const NOTE =
  "Since Arc stopped development, I’ve been itching for something better, and more than ever now that it is officially being sunset. So I made my own. It has a familiar Arc feel, with a Liquid Glass redesign, extra features and a WebKit base. I think you’ll love it.";

// the measured section's medians in ms, each bench drawn fastest first; the date and machine fill its method line.
export const MEASURED = {
  on: "24 November 2026",
  machine: "M1 Pro",
  launch: { Artemis: 487, Search: 509, Ardia: 603, Helium: 770 },
  newTab: { Helium: 44, Artemis: 63, Ardia: 90, Search: 137 },
};
