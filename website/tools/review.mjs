// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

// node tools/review.mjs <baseUrl> <outDir> [--stops S01,S06|all] [--steps N] [--engine chromium|webkit]
//   [--w 1440 --h 900] [--light] [--reduced] [--mobile] [--nojs] [--contrast] [--forced] [--q "sda=0"] [--tag name]
// One browser per run in a machine-wide render slot; full Chromium paints backdrop-filter.
import fs from "node:fs";
import path from "node:path";
import { takeSlot } from "./slot.mjs";

const pwDir = process.env.PLAYWRIGHT_BROWSERS_PATH
  ? path.dirname(process.env.PLAYWRIGHT_BROWSERS_PATH)
  : process.cwd();
const { chromium, webkit, devices } = await import("playwright").catch(
  () => import(path.join(pwDir, "node_modules/playwright/index.mjs")),
);
const args = process.argv.slice(2);
const [base, outDir] = args;
const opt = (k, d) => {
  const i = args.indexOf("--" + k);
  return i < 0
    ? d
    : args[i + 1] && !args[i + 1].startsWith("--")
      ? args[i + 1]
      : true;
};
const engine = opt("engine", "chromium");
const mobile = !!opt("mobile");
const nojs = !!opt("nojs");
const w = +opt("w", mobile ? 390 : 1440);
const h = +opt("h", mobile ? 844 : 900);
const tag = opt("tag", "r");
const extra = opt("q", "");

// [name, query, target]; a target is [track, p], an element selector to put under the nav, or "bottom"
const STOPS = {
  S01: ["", 0],
  S02: ["", "#know"],
  S03: ["peek=spaces", "#know"],
  S04: ["", "#more"],
  S05: ["", ".stats"],
  S06: ["", "#move-in"],
  S07: ["", "#fin"],
  S08: ["", "bottom"],
};
const want = opt("stops", "");
const stops = want === "all" ? Object.keys(STOPS) : want ? want.split(",") : [];
const steps = +opt("steps", 0);
fs.mkdirSync(outDir, { recursive: true });

await takeSlot(pwDir);

const browser = await (engine === "webkit"
  ? webkit.launch()
  : chromium.launch({ channel: "chromium" }));
const ctx = await browser.newContext({
  viewport: { width: w, height: h },
  deviceScaleFactor: 2,
  isMobile: mobile && engine === "chromium",
  hasTouch: mobile,
  userAgent: mobile ? devices["iPhone 15 Pro"].userAgent : undefined,
  colorScheme: opt("light") ? "light" : "dark",
  reducedMotion: opt("reduced") ? "reduce" : "no-preference",
  contrast: opt("contrast") ? "more" : "no-preference",
  forcedColors: opt("forced") ? "active" : "none",
  javaScriptEnabled: !nojs,
});
const page = await ctx.newPage();
const errors = [];
page.on("pageerror", (e) => errors.push(e.message));
page.on("console", (m) => m.type() === "error" && errors.push(m.text()));

async function glide(y) {
  if (nojs) return page.evaluate((y) => scrollTo(0, y), y);
  await page.evaluate(async (y) => {
    const s = scrollY;
    for (let k = 1; k <= 14; k++) {
      scrollTo(0, s + ((y - s) * k) / 14);
      await new Promise((r) => requestAnimationFrame(r));
    }
  }, y);
}
const state = () =>
  page.evaluate(() => ({
    y: Math.round(scrollY),
    pill: document.querySelector(".nav-pill-t")?.textContent,
    tone: document.getElementById("nav")?.dataset.tone,
    accent: document.documentElement.dataset.accent,
    cls: document.documentElement.className,
    sw: document.documentElement.scrollWidth,
    H: document.documentElement.scrollHeight,
  }));
async function load(q) {
  const qs = ["nosettle", q, extra].filter(Boolean).join("&");
  await page.goto(`${base}?${qs}`, { waitUntil: "load" });
  await page.waitForTimeout(nojs ? 300 : 1200);
}

const report = { tag, engine, w, h, stops: {}, errors };
for (const name of stops) {
  const [q, target] = STOPS[name];
  await load(q);
  const y = await page.evaluate((t) => {
    const nav = 74;
    if (t === "bottom") return document.documentElement.scrollHeight;
    if (Array.isArray(t)) {
      const el = document.querySelector(".track-" + t[0]);
      const r = el.getBoundingClientRect();
      return r.top + scrollY + t[1] * (el.offsetHeight - innerHeight);
    }
    if (typeof t === "number") return t;
    const r = document.querySelector(t)?.getBoundingClientRect();
    if (!r) return 0;
    return r.height < innerHeight - nav && t.includes("island")
      ? r.top + scrollY - (innerHeight - r.height) / 2
      : r.top + scrollY - nav;
  }, target);
  await glide(Math.round(y));
  // the site sidebar closes on scroll, so S22 opens it afterwards from the left edge
  if (name === "S22") {
    await page.mouse.move(200, h / 2);
    await page.mouse.move(3, h / 2, { steps: 6 });
  }
  await page.waitForTimeout(nojs ? 200 : 1100);
  await page.screenshot({
    path: path.join(outDir, `${tag}-${name}.png`),
    caret: "initial",
  });
  report.stops[name] = await state();
}
if (steps) {
  await load("");
  const H = await page.evaluate(
    () => document.documentElement.scrollHeight - innerHeight,
  );
  for (let i = 0; i < steps; i++) {
    await glide(Math.round((H * i) / (steps - 1)));
    await page.waitForTimeout(nojs ? 150 : 700);
    const n = String(i).padStart(2, "0");
    await page.screenshot({
      path: path.join(outDir, `${tag}-step${n}.png`),
      caret: "initial",
    });
    report.stops["step" + n] = await state();
  }
}
fs.writeFileSync(
  path.join(outDir, `${tag}.json`),
  JSON.stringify(report, null, 1),
);
console.log(JSON.stringify(report));
await browser.close();
