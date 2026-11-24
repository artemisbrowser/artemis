// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

// node tools/3d/export.mjs <out.glb> [silver|black]
// Exports the mock/ laptop, shut and without its screen image, as GLB for render.py. Needs Playwright.
import fs from "node:fs";
import http from "node:http";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { takeSlot } from "../slot.mjs";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const pwDir = process.env.PLAYWRIGHT_BROWSERS_PATH ? path.dirname(process.env.PLAYWRIGHT_BROWSERS_PATH) : process.cwd();
const [out, finish = "black"] = process.argv.slice(2);
if (!out) throw new Error("usage: node tools/3d/export.mjs <out.glb> [silver|black]");

const TYPES = { ".html": "text/html", ".js": "text/javascript", ".jpg": "image/jpeg", ".hdr": "application/octet-stream" };
const server = http.createServer((req, res) => {
  const file = path.join(ROOT, decodeURIComponent(new URL(req.url, "http://x").pathname));
  if (!file.startsWith(ROOT) || !fs.existsSync(file)) return res.writeHead(404).end();
  res.writeHead(200, { "content-type": TYPES[path.extname(file)] || "application/octet-stream" }).end(fs.readFileSync(file));
}).listen(0, "127.0.0.1");
await new Promise((r) => server.once("listening", r));

await takeSlot(pwDir);
const { chromium } = await import("playwright").catch(() => import(path.join(pwDir, "node_modules/playwright/index.mjs")));
const browser = await chromium.launch({ args: ["--use-angle=metal", "--ignore-gpu-blocklist", "--enable-gpu"] });
const page = await browser.newPage({ viewport: { width: 800, height: 500 } });
page.on("pageerror", (e) => console.error("pageerror:", e.message));
await page.goto(`http://127.0.0.1:${server.address().port}/mock/3d.html?capture&finish=${finish}`);
await page.waitForFunction(() => window.ready3d, null, { timeout: 60000 });
const url = await page.evaluate(() => window.gltf3d());
fs.writeFileSync(out, Buffer.from(url.slice(url.indexOf(",") + 1), "base64"));
await browser.close();
server.close();
console.log(out, fs.statSync(out).size);
