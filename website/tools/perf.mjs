// node tools/perf.mjs <url> [--rate 4] [--to selector] [--warm]   J5: wheel-scrolls from the top to the end of
// the selector (default both pins) under CPU throttling in full Chromium; prints long animation frames and rAF gaps.
// --warm scrolls once before measuring, so the cold first-scroll frame is reported apart from the steady state.
import fs from "node:fs";
import path from "node:path";

const pwDir = process.env.PLAYWRIGHT_BROWSERS_PATH
  ? path.dirname(process.env.PLAYWRIGHT_BROWSERS_PATH)
  : process.cwd();
const { chromium } = await import("playwright").catch(
  () => import(path.join(pwDir, "node_modules/playwright/index.mjs")),
);
const args = process.argv.slice(2);
const opt = (k, d) => {
  const i = args.indexOf("--" + k);
  return i < 0 ? d : (args[i + 1] ?? true);
};
const url = args[0];
const to = opt("to", ".track-spaces");

const locks = path.join(pwDir, "locks");
fs.mkdirSync(locks, { recursive: true });
const slot = await (async () => {
  for (;;) {
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
          fs.rmSync(p, { recursive: true, force: true });
        }
      }
    }
    await new Promise((r) => setTimeout(r, 1000));
  }
})();
process.on("exit", () => fs.rmSync(slot, { recursive: true, force: true }));

const browser = await chromium.launch({ channel: "chromium" });
const ctx = await browser.newContext({
  viewport: { width: 1440, height: 900 },
  deviceScaleFactor: 2,
  colorScheme: "dark",
});
const page = await ctx.newPage();
await page.goto(url, { waitUntil: "load" });
await page.waitForTimeout(1500);
const end = await page.evaluate((s) => {
  const r = document.querySelector(s).getBoundingClientRect();
  return r.bottom + scrollY - innerHeight;
}, to);
await page.mouse.move(720, 450);
const wheel = async () => {
  for (let y = 0; y < end; y += 60) {
    await page.mouse.wheel(0, 60);
    await page.waitForTimeout(16);
  }
};
if (opt("warm", false)) {
  await wheel();
  await page.evaluate(() => scrollTo(0, 0));
  await page.waitForTimeout(800);
}
const cdp = await ctx.newCDPSession(page);
await cdp.send("Emulation.setCPUThrottlingRate", { rate: +opt("rate", 4) });
await page.evaluate(() => {
  window.__f = [];
  window.__loaf = [];
  new PerformanceObserver((l) =>
    l.getEntries().forEach((e) =>
      __loaf.push({
        ms: Math.round(e.duration),
        y: Math.round(scrollY),
        scripts: e.scripts.map(
          (s) => `${s.invoker} ${Math.round(s.duration)}ms ${s.sourceFunctionName}`,
        ),
        layout: Math.round(
          e.styleAndLayoutStart
            ? e.startTime + e.duration - e.styleAndLayoutStart
            : 0,
        ),
      }),
    ),
  ).observe({ type: "long-animation-frame" });
  let last = 0;
  const t = (now) => {
    if (last) __f.push(now - last);
    last = now;
    requestAnimationFrame(t);
  };
  requestAnimationFrame(t);
});
await wheel();
await page.waitForTimeout(600);
const r = await page.evaluate(() => {
  const f = __f.slice(2).sort((a, b) => b - a);
  return {
    frames: f.length,
    worst: f.slice(0, 5).map(Math.round),
    p95: Math.round(f[Math.floor(f.length * 0.05)]),
    over34: f.filter((x) => x > 34).length,
    loafOver50: __loaf.filter((l) => l.ms > 50),
  };
});
console.log(JSON.stringify(r));
await browser.close();
