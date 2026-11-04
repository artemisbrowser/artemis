// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

// node tools/frames.mjs <url> <outDir> <tag> --track oow|spaces --at "0,0.28,0.52" [--engine chromium|webkit]
//   [--w 1440 --h 900] [--dark] [--mobile] [--reduced] [--wait 2200] [--peek: one more frame, pointer on the left edge]
// --at takes track progress p (scrollY = top + p × (height − innerHeight)) or a raw "y1200".
import fs from "node:fs";
import path from "node:path";

const pwDir = process.env.PLAYWRIGHT_BROWSERS_PATH
  ? path.dirname(process.env.PLAYWRIGHT_BROWSERS_PATH)
  : process.cwd();
const { chromium, webkit, devices } = await import("playwright").catch(
  () => import(path.join(pwDir, "node_modules/playwright/index.mjs")),
);

const args = process.argv.slice(2);
const [url, outDir, tag] = args;
const opt = (k, d) => {
  const i = args.indexOf("--" + k);
  return i < 0
    ? d
    : args[i + 1] && !args[i + 1].startsWith("--")
      ? args[i + 1]
      : true;
};
if (!url || !outDir || !tag) {
  console.error(
    "usage: node tools/frames.mjs <url> <outDir> <tag> --track oow|spaces --at 0,0.5 [...]",
  );
  process.exit(1);
}
const engine = opt("engine", "chromium");
const mobile = !!opt("mobile", false);
const w = +opt("w", mobile ? 390 : 1440);
const h = +opt("h", mobile ? 844 : 900);
const track = `.track-${opt("track", "oow")}`;
const at = String(opt("at", "0")).split(",");
fs.mkdirSync(outDir, { recursive: true });

// at most SHOT_SLOTS browsers machine-wide (default 2), shared with the other render tools
const locks = path.join(pwDir, "locks");
fs.mkdirSync(locks, { recursive: true });
const slot = await (async () => {
  for (;;) {
    if (!fs.existsSync(path.join(pwDir, "PAUSE")))
      for (let i = 0; i < +(process.env.SHOT_SLOTS || 2); i++) {
        const p = path.join(locks, `slot${i}`);
        try {
          fs.mkdirSync(p);
          fs.writeFileSync(path.join(p, "pid"), String(process.pid));
          return p;
        } catch {
          try {
            process.kill(+fs.readFileSync(path.join(p, "pid"), "utf8"), 0);
          } catch {
            if (
              Date.now() -
                (fs.statSync(p, { throwIfNoEntry: false })?.mtimeMs ?? 0) >
              5000
            )
              fs.rmSync(p, { recursive: true, force: true });
          }
        }
      }
    await new Promise((r) => setTimeout(r, 1000));
  }
})();
process.on("exit", () => fs.rmSync(slot, { recursive: true, force: true }));
for (const s of ["SIGINT", "SIGTERM"]) process.on(s, () => process.exit(1));

const browser = await (engine === "webkit" ? webkit : chromium).launch();
const ctx = await browser.newContext({
  viewport: { width: w, height: h },
  deviceScaleFactor: mobile ? 3 : 2,
  isMobile: mobile && engine === "chromium",
  hasTouch: mobile,
  colorScheme: opt("dark", false) ? "dark" : "light",
  reducedMotion: opt("reduced", false) ? "reduce" : "no-preference",
  userAgent: mobile ? devices["iPhone 15 Pro"].userAgent : undefined,
});
const page = await ctx.newPage();
const errors = [];
page.on("console", (m) => m.type() === "error" && errors.push(m.text()));
page.on("pageerror", (e) => errors.push("pageerror: " + e.message));
await page.goto(url, { waitUntil: "load" });
await page.waitForTimeout(+opt("wait", 2200));
const out = [];
for (const a of at) {
  const y = await page.evaluate(
    ([a, sel]) => {
      if (a.startsWith("y")) return +a.slice(1);
      const t = document.querySelector(sel);
      if (!t) throw new Error(`no ${sel} on the page`);
      return Math.round(
        t.getBoundingClientRect().top +
          scrollY +
          +a * (t.offsetHeight - innerHeight),
      );
    },
    [a, track],
  );
  await page.evaluate(async (target) => {
    const start = scrollY;
    for (let k = 1; k <= 14; k++) {
      scrollTo(0, start + ((target - start) * k) / 14);
      await new Promise((r) => requestAnimationFrame(r));
    }
  }, y);
  await page.waitForTimeout(900);
  const f = path.join(outDir, `${tag}-${a.replace(".", "_")}.png`);
  await page.screenshot({ path: f, caret: "initial" });
  out.push(f);
}
if (opt("peek", false)) {
  await page.mouse.move(200, h / 2);
  await page.mouse.move(3, h / 2, { steps: 6 });
  await page.waitForTimeout(900);
  const f = path.join(outDir, `${tag}-peek.png`);
  await page.screenshot({ path: f, caret: "initial" });
  out.push(f);
}
const state = await page.evaluate(() => ({
  sda: document.documentElement.classList.contains("sda"),
  pin: document.documentElement.classList.contains("pin"),
  h: document.documentElement.scrollHeight,
}));
console.log(JSON.stringify({ tag, engine, state, errors, out }, null, 1));
await browser.close();
