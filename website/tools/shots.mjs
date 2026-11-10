// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

// node tools/shots.mjs [--only name,…] [--fav]   captures the real pages and favicons the replica shows into src/img.
// Needs Playwright (see tools/review.mjs) and cwebp. Outputs are committed. Credits are in 09-footer and THIRD-PARTY-NOTICES.md.
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const pwDir = process.env.PLAYWRIGHT_BROWSERS_PATH
  ? path.dirname(process.env.PLAYWRIGHT_BROWSERS_PATH)
  : process.cwd();
const { chromium } = await import("playwright").catch(
  () => import(path.join(pwDir, "node_modules/playwright/index.mjs")),
);
const args = process.argv.slice(2);
const only = args.includes("--only")
  ? args[args.indexOf("--only") + 1].split(",")
  : null;

// [name, url, sizes]; a size is [label, CSS width, CSS height, scale] and matches a replica page box in points
const PAGE = ["page", 730, 620, 2];
const PANE = ["pane", 365, 620, 2];
const HERO = ["hero", 1072, 829, 1.5];
const SHOTS = [
  [
    "wp-orion",
    "https://en.wikipedia.org/wiki/Orion_(constellation)",
    [HERO, PAGE, PANE],
  ],
  ["wp-betelgeuse", "https://en.wikipedia.org/wiki/Betelgeuse", [PAGE, PANE]],
  ["wp-sourdough", "https://en.wikipedia.org/wiki/Sourdough", [PAGE, PANE]],
  ["wp-skye", "https://en.wikipedia.org/wiki/Isle_of_Skye", [PAGE, PANE]],
  ["gh-artemis", "https://github.com/artemisbrowser/artemis", [PAGE, PANE]],
  [
    "osm-skye",
    "https://www.openstreetmap.org/#map=14/57.4126/-6.1960",
    [PAGE, PANE],
  ],
];
// [name, page that names its icons, or the icon itself]
const FAVICONS = [
  ["wikipedia", "https://en.wikipedia.org/wiki/Main_Page"],
  ["github-dark", "https://github.githubassets.com/favicons/favicon-dark.svg"],
  ["osm", "https://www.openstreetmap.org/"],
  ["youtube", "https://www.youtube.com/"],
  ["spotify", "https://open.spotify.com/"],
  ["figma", "https://www.figma.com/"],
  ["notion", "https://www.notion.com/"],
  ["slack", "https://slack.com/"],
  ["linear", "https://linear.app/"],
  ["gmail", "https://ssl.gstatic.com/ui/v1/icons/mail/rfr/gmail.ico"],
  [
    "calendar",
    "https://calendar.google.com/googlecalendar/images/favicons_2020q4/calendar_9.ico",
  ],
];

const out = path.join(ROOT, "src/img");
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "shots-"));
const browser = await chromium.launch();

// a visit as a first-time reader would see it, minus banners, Wikipedia's coordinate and status icons,
// and GitHub's counts and licence line, which go stale
const HIDE = `#siteNotice, #centralNotice, .cn-fundraising, .frb, .mw-dismissable-notice, .vector-sticky-header,
  #coordinates, .mw-indicators, .wmamapbutton, [class*="insights__"], .mt-2:has([class*="licensesTrigger"]),
  .Counter, [class*="CounterLabel"], [data-testid="cookie-banner"], .cookie-consent { display: none !important; }`;

async function capture([name, url, sizes], scheme) {
  for (const [label, w, h, scale] of sizes) {
    const ctx = await browser.newContext({
      viewport: { width: w, height: h },
      deviceScaleFactor: scale,
      colorScheme: scheme,
      locale: "en-GB",
      bypassCSP: true,
    });
    const page = await ctx.newPage();
    await page.goto(url, { waitUntil: "load", timeout: 60000 });
    await page.addStyleTag({ content: HIDE });
    // Wikipedia follows the system theme for logged-out readers only once the client preference says so
    await page.evaluate((s) => {
      const c = document.documentElement.classList;
      if (
        c.contains("skin-theme-clientpref-day") ||
        c.contains("skin-theme-clientpref-os")
      ) {
        c.remove(
          "skin-theme-clientpref-day",
          "skin-theme-clientpref-os",
          "skin-theme-clientpref-night",
        );
        c.add(
          s === "dark"
            ? "skin-theme-clientpref-night"
            : "skin-theme-clientpref-day",
        );
      }
    }, scheme);
    await page.waitForTimeout(3000);
    const png = path.join(tmp, `${name}-${label}-${scheme}.png`);
    await page.screenshot({ path: png });
    // the colour at the right edge fills the page box where it is wider than the shot
    const bg = await page.evaluate(() => {
      let el = document.elementFromPoint(innerWidth - 2, innerHeight - 2);
      for (; el; el = el.parentElement) {
        const c = getComputedStyle(el).backgroundColor;
        if (!/rgba\(0, 0, 0, 0\)|transparent/.test(c)) return c;
      }
      return "rgb(255, 255, 255)";
    });
    const dest = path.join(
      out,
      "shots",
      `shot-${name}-${label}-${scheme}.webp`,
    );
    fs.mkdirSync(path.dirname(dest), { recursive: true });
    execFileSync("cwebp", ["-quiet", "-q", "80", "-m", "6", png, "-o", dest]);
    console.log(
      `${path.relative(ROOT, dest)}  ${(fs.statSync(dest).size / 1024).toFixed(0)} KB  bg ${bg}`,
    );
    await ctx.close();
  }
}

async function favicon([name, url]) {
  const ctx = await browser.newContext({
    deviceScaleFactor: 1,
    locale: "en-GB",
  });
  const page = await ctx.newPage();
  let icon = url;
  if (!/\.(ico|png|svg)$/.test(url)) {
    await page.goto(url, { waitUntil: "domcontentloaded", timeout: 60000 });
    icon = await page.evaluate(() => {
      const links = [
        ...document.querySelectorAll(
          'link[rel~="icon"], link[rel="shortcut icon"]',
        ),
      ].filter((l) => !l.media || matchMedia(l.media).matches);
      const size = (l) =>
        Math.max(
          0,
          ...(l.sizes?.value || "")
            .split(" ")
            .map((s) => +s.split("x")[0] || 0),
        );
      const svg = links.find(
        (l) => /\.svg(\?|$)/.test(l.href) || l.type === "image/svg+xml",
      );
      const best = links
        .filter((l) => size(l) <= 96)
        .sort((a, b) => size(b) - size(a))[0];
      return (
        (svg || best || links[0])?.href ||
        new URL("/favicon.ico", location.href).href
      );
    });
  }
  const draw = await ctx.newPage();
  await draw.setViewportSize({ width: 64, height: 64 });
  await draw.setContent(
    `<style>html,body{margin:0;background:transparent}img{width:64px;height:64px;display:block}</style><img src="${icon}">`,
  );
  await draw.waitForFunction(() => document.images[0].complete, null, {
    timeout: 30000,
  });
  const dest = path.join(out, "fav", `fav-${name}.png`);
  fs.mkdirSync(path.dirname(dest), { recursive: true });
  await draw.screenshot({ path: dest, omitBackground: true });
  console.log(`${path.relative(ROOT, dest)}  from ${icon}`);
  await ctx.close();
}

const fav = args.includes("--fav");
for (const f of fav ? FAVICONS : [])
  if (!only || only.includes(f[0])) await favicon(f);
for (const s of fav ? [] : SHOTS)
  if (!only || only.includes(s[0]))
    for (const scheme of ["light", "dark"]) await capture(s, scheme);
await browser.close();
fs.rmSync(tmp, { recursive: true, force: true });
