// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

// node tools/frame.mjs <capture.png> <name> [--backdrop img] [--width 2000]
// Puts a window capture on a backdrop at the laptop's screen size, renders it on the laptop from tools/3d and writes
// src/img/framed/<name>.webp. A capture already the screen's shape is used as is. Needs Playwright, Blender and cwebp.
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { takeSlot } from "./slot.mjs";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const pwDir = process.env.PLAYWRIGHT_BROWSERS_PATH
  ? path.dirname(process.env.PLAYWRIGHT_BROWSERS_PATH)
  : process.cwd();
const args = process.argv.slice(2);
const [input, name] = args;
const opt = (k, d) => (args.includes("--" + k) ? args[args.indexOf("--" + k) + 1] : d);
if (!input || !name) throw new Error("usage: node tools/frame.mjs <capture.png> <name> [--backdrop img] [--width px]");

const BLENDER = process.env.BLENDER || "/Applications/Blender.app/Contents/MacOS/Blender";
const GLB = process.env.LAPTOP_GLB || path.join(os.homedir(), ".cache/artemis/3d-render/mbp14.glb");
// the laptop's screen in device px
const [W, H] = [3024, 1964];

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "frame-"));
const dataUrl = (f) => `data:image/png;base64,${fs.readFileSync(f).toString("base64")}`;
const size = (f) => execFileSync("sips", ["-g", "pixelWidth", "-g", "pixelHeight", f], { encoding: "utf8" }).match(/\d+/g).slice(-2).map(Number);

let screen = path.resolve(input);
const [iw, ih] = size(screen);
if (Math.abs(iw / ih - W / H) > 0.01) {
  const { chromium } = await import("playwright").catch(
    () => import(path.join(pwDir, "node_modules/playwright/index.mjs")),
  );
  await takeSlot(pwDir);
  const backdrop = path.resolve(opt("backdrop", path.join(ROOT, "assets/spaces/space-tide-880x592.png")));
  const browser = await chromium.launch();
  const page = await browser.newPage({ viewport: { width: W / 2, height: H / 2 }, deviceScaleFactor: 2 });
  // the window keeps its capture's point size, shrunk only to fit 88% x 86% of the screen
  await page.setContent(`<style>
    body { margin: 0; height: 100vh; display: grid; place-items: center; background: url(${dataUrl(backdrop)}) center / cover; }
    img { width: ${iw / 2}px; max-width: 88vw; max-height: 86vh; object-fit: contain; filter: drop-shadow(0 22px 40px rgb(0 0 0 / 0.45)); }
  </style><img src="${dataUrl(screen)}">`);
  screen = path.join(tmp, "screen.png");
  await page.screenshot({ path: screen });
  await browser.close();
}

const width = Number(opt("width", "2000"));
execFileSync(BLENDER, ["-b", "--factory-startup", "-P", path.join(ROOT, "tools/3d/render.py"), "--", "--glb", GLB, "--screen", screen,
  "--out", tmp, "--shots", "front", "--samples", "64", "--height", String(Math.round((width * 1208) / 2000)), "--flip-uv", "0",
  "--backdrop", "none", "--hinge", "10.5655", "0.8922"], { stdio: "ignore" });
const dest = path.join(ROOT, "src/img/framed", `${name}.webp`);
fs.mkdirSync(path.dirname(dest), { recursive: true });
execFileSync("cwebp", ["-quiet", "-q", "82", "-alpha_q", "100", path.join(tmp, "front.png"), "-o", dest]);
fs.rmSync(tmp, { recursive: true, force: true });
console.log(path.relative(process.cwd(), dest));
