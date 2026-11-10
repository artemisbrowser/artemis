// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

// Writes src/img/desk-stars.svg, the replica Macs' desktop: a night sky in screen points (1352 × 878),
// seeded so every run draws the same sky. Run: node tools/stars.mjs
import fs from "node:fs";

const W = 1352;
const H = 878;
let seed = 7;
const rand = () => {
  seed = (seed + 0x6d2b79f5) | 0;
  let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
  t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
  return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
};
const gauss = () =>
  Math.sqrt(-2 * Math.log(rand() || 1e-9)) * Math.cos(2 * Math.PI * rand());
const pick = (weights) => {
  let r = rand() * weights.reduce((a, b) => a + b);
  return weights.findIndex((w) => (r -= w) < 0);
};

// the Milky Way rises from lower left to upper right; a third of the stars crowd along it
const [ax, ay, bx, by] = [-80, 820, W + 80, 60];
const len = Math.hypot(bx - ax, by - ay);
const star = () => {
  if (rand() > 0.34) return [rand() * W, rand() * H];
  const t = rand();
  const off = gauss() * 70;
  return [
    ax + (bx - ax) * t - ((by - ay) / len) * off,
    ay + (by - ay) * t + ((bx - ax) / len) * off,
  ];
};

const SIZES = [0.8, 1.2, 1.8];
const INKS = ["#fff", "#d6e4ff", "#ffeccc"];
const ALPHAS = [0.35, 0.55, 0.8, 1];
const buckets = new Map();
for (let i = 0; i < 1500; i++) {
  const [x, y] = star();
  if (x < 0 || y < 0 || x > W || y > H) continue;
  const key = [
    pick([78, 18, 4]),
    pick([80, 13, 7]),
    pick([30, 30, 25, 15]),
  ].join();
  buckets.set(
    key,
    (buckets.get(key) ?? "") + `M${x.toFixed(1)} ${y.toFixed(1)}h0`,
  );
}
const paths = [...buckets].sort().map(([key, d]) => {
  const [s, c, a] = key.split(",").map(Number);
  return `<path stroke="${INKS[c]}" stroke-opacity="${ALPHAS[a]}" stroke-width="${SIZES[s]}" d="${d}"/>`;
});

// bright stars stay below the menu bar, clear of the notch's camera
const bright = Array.from({ length: 14 }, () => {
  let [x, y] = star();
  while (y < 45 || y > H) [x, y] = star();
  return `<circle cx="${x.toFixed(1)}" cy="${y.toFixed(1)}" r="6" fill="url(#glow)"/><circle cx="${x.toFixed(1)}" cy="${y.toFixed(1)}" r="1.3" fill="#fff"/>`;
});

const deg = (Math.atan2(by - ay, bx - ax) * 180) / Math.PI;
const svg = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${W} ${H}" preserveAspectRatio="xMidYMid slice">
<defs>
<linearGradient id="sky" x2="0" y2="1"><stop offset="0" stop-color="#03050b"/><stop offset=".6" stop-color="#070c1c"/><stop offset="1" stop-color="#0e1a36"/></linearGradient>
<radialGradient id="band"><stop offset="0" stop-color="#9fb4e0" stop-opacity=".16"/><stop offset=".5" stop-color="#7f95c8" stop-opacity=".06"/><stop offset="1" stop-color="#7f95c8" stop-opacity="0"/></radialGradient>
<radialGradient id="glow"><stop offset="0" stop-color="#dfe9ff" stop-opacity=".5"/><stop offset="1" stop-color="#dfe9ff" stop-opacity="0"/></radialGradient>
</defs>
<rect width="${W}" height="${H}" fill="url(#sky)"/>
<ellipse cx="${W / 2}" cy="${H / 2 + 10}" rx="${(len / 2).toFixed(0)}" ry="120" fill="url(#band)" transform="rotate(${deg.toFixed(1)} ${W / 2} ${H / 2 + 10})"/>
<g fill="none" stroke-linecap="round">
${paths.join("\n")}
</g>
${bright.join("\n")}
</svg>
`;
fs.writeFileSync(new URL("../src/img/desk-stars.svg", import.meta.url), svg);
console.log(`desk-stars.svg ${(svg.length / 1024).toFixed(1)} KB`);
