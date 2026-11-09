// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

// canonical, og:url, og:image, JSON-LD, sitemap and the link capsule's host.
export const DOMAIN = "artemisbrowser.app";
// a price string such as "Free", or null; adds " {PRICE}." to every fine print line and offers to JSON-LD.
export const PRICE = "Free";
// a release stage such as "Public alpha", or null; leads both fine print lines and joins every description.
export const STAGE = null;
// the release DMG; when set, Download shows the four steps to open it and starts it, else /download says none yet.
export const DOWNLOAD_URL = "https://github.com/artemisbrowser/artemis/releases/download/v1.0.0-2/Artemis-1.0.0-2.dmg";
// the Arc block ships only while this is true and src/partials/07-arc.html exists.
export const ARC_BLOCK = true;
// the real sites the replica shows, only as page shots, favicons and titles inside its window; each maps to the
// credit the footer must carry for its page shots, or "" when it appears only as a favicon and title.
export const HOSTS = {
  "en.wikipedia.org": "Wikipedia text under CC BY-SA 4.0",
  "www.openstreetmap.org": "© OpenStreetMap contributors",
  "github.com": "",
  "www.notion.so": "",
  "app.slack.com": "",
  "linear.app": "",
  "www.figma.com": "",
  "calendar.google.com": "",
  "mail.google.com": "",
};

// Fin's note in the closing section, in his words; it may name Arc in either build.
export const NOTE =
  "Arc felt like heaven. Since it stopped development, I’ve been itching for something better, and more than ever now that Arc is officially being sunset. So I made my own. It has a familiar Arc feel, with a Liquid Glass redesign, extra features and a WebKit base. I think you’ll love it.";
