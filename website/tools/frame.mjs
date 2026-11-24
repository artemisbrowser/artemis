// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

// node tools/frame.mjs <capture.png> <name> [--backdrop img] [--width 2000] [--shot front|above]
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
if (!input || !name) throw new Error("usage: node tools/frame.mjs <capture.png> <name> [--backdrop img] [--width px] [--shot front|above]");

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
  // the window fills the screen under the 37 pt menu bar but for a 12 pt rim of backdrop;
  // its corners are cut to the window's own radius, 32 px in a 2x capture
  const k = Math.min((0.96 * W) / 2 / iw, (H / 2 - 37 - 24) / ih);
  const comet = fs.readFileSync(path.join(ROOT, "src/static/icon.svg"), "utf8").match(/id="comet" d="([^"]+)"/)[1];
  // the mark in one ink: the A cut round the comet where the comet crosses in front of it
  const mark = `<svg viewBox="60 180 900 665"><defs><path id="c" d="${comet}"/>
    <clipPath id="f"><path clip-rule="evenodd" d="M0,0H1024V1024H0Z M439.2,226.5 195.3,726.5 340.9,797.5 584.8,297.5Z"/></clipPath>
    <mask id="m"><rect width="1024" height="1024" fill="#fff"/><use href="#c" clip-path="url(#f)" stroke="#000" stroke-width="56"/></mask></defs>
    <path d="M268.1,762 512,262 755.9,762" fill="none" stroke="#fff" stroke-width="162" stroke-linecap="round" stroke-linejoin="round" mask="url(#m)"/>
    <use href="#c" clip-path="url(#f)" fill="#fff"/></svg>`;
  const glyph = (w, body) => `<svg viewBox="0 0 ${w} 16" style="width:${w}px" fill="none" stroke="#fff" stroke-width="1.5" stroke-linecap="round">${body}</svg>`;
  const status = [
    glyph(16, '<circle cx="7" cy="7" r="4.6"/><path d="m10.4 10.4 3.6 3.6"/>'),
    glyph(18, '<path d="M2.5 6.6a9.5 9.5 0 0 1 13 0M5 9.3a6 6 0 0 1 8 0M7.4 11.9a2.4 2.4 0 0 1 3.2 0"/><circle cx="9" cy="14" r=".4" stroke-width="1.8"/>'),
    glyph(27, '<rect x="1" y="3" width="22" height="10.5" rx="3.4" stroke-opacity=".5" stroke-width="1.2"/><rect x="3" y="5" width="14.5" height="6.5" rx="1.6" fill="#fff" stroke="none"/><path d="M25 6.5v3.5" stroke-opacity=".5"/>'),
    glyph(22, '<rect x="1" y="3" width="20" height="10" rx="5"/><circle cx="16" cy="8" r="3" fill="#fff" stroke="none"/>'),
  ].join("");
  // the 37 pt menu bar: tinted glass over the backdrop, the camera island left clear between its two halves
  const bar = `<header><span class="mark">${mark}</span><b>Artemis</b>${["File", "Edit", "View", "Navigate", "Spaces", "Window", "Help"].map((m) => `<span>${m}</span>`).join("")}
    <i></i>${status}<span>23 Nov&ensp;10:24</span></header>`;
  await page.setContent(`<style>
    body { margin: 0; height: 100vh; box-sizing: border-box; padding-top: 37px; display: grid; place-items: center; background: url(${dataUrl(backdrop)}) center / cover; }
    img { width: ${iw * k}px; height: ${ih * k}px; border-radius: ${32 * k}px; filter: drop-shadow(0 22px 40px rgb(0 0 0 / 0.45)); }
    header { position: fixed; inset: 0 0 auto; height: 37px; display: flex; align-items: center; gap: 21px; padding: 0 21px 0 20px;
      background: rgb(255 255 255 / 0.1); backdrop-filter: blur(24px) saturate(150%);
      font: 500 13.5px system-ui; color: #fff; text-shadow: 0 0 4px rgb(0 0 0 / 0.12); }
    header i { flex: 1; }
    header svg { display: block; height: 16px; flex: none; }
    header .mark svg { width: 22px; }
    header b { font-weight: 700; }
  </style>${bar}<img src="${dataUrl(screen)}">`);
  screen = path.join(tmp, "screen.png");
  await page.screenshot({ path: screen });
  await browser.close();
}

const width = Number(opt("width", "2000"));
const shot = opt("shot", "front");
// front is cut out for any card; above keeps its black stage
const [ratio, samples, stage] = { front: [1208 / 2000, 64, "none"], above: [9 / 16, 128, "black"] }[shot];
execFileSync(BLENDER, ["-b", "--factory-startup", "-P", path.join(ROOT, "tools/3d/render.py"), "--", "--glb", GLB, "--screen", screen,
  "--out", tmp, "--shots", shot, "--samples", String(samples), "--height", String(Math.round(width * ratio)), "--flip-uv", "0",
  "--backdrop", stage, "--hinge", "10.5655", "0.8922"], { stdio: "ignore" });
const dest = path.join(ROOT, "src/img/framed", `${name}.webp`);
fs.mkdirSync(path.dirname(dest), { recursive: true });
execFileSync("cwebp", ["-quiet", "-q", "82", "-alpha_q", "100", path.join(tmp, `${shot}.png`), "-o", dest]);
fs.rmSync(tmp, { recursive: true, force: true });
console.log(path.relative(process.cwd(), dest));
