// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

// The ticket leans under the pointer, and confetti falls over /invite once the page has loaded: on to
// the ticket, the heading, the line under it, the buttons and the foot of the page. Once all of it has
// landed it fades.
const light = document.querySelector(".ticket-light");
// the pointer from the ticket's centre, -0.5 to 0.5, and the lean on its way there
let aim = [0, 0];
const at = [0, 0];
let then = 0;
let following = 0;
const follow = (now) => {
  // a tenth of a second to close 63% of the gap, at any frame rate
  const k = then ? 1 - Math.exp((then - now) / 100) : 0;
  then = now;
  const far = Math.abs(aim[0] - at[0]) + Math.abs(aim[1] - at[1]) > 0.002;
  // the last step lands on the pointer, so a ticket at rest is exactly flat
  at[0] += (aim[0] - at[0]) * (far ? k : 1);
  at[1] += (aim[1] - at[1]) * (far ? k : 1);
  light.parentNode.style.setProperty("--tx", at[0]);
  light.parentNode.style.setProperty("--ty", at[1]);
  if (!far) then = 0;
  following = far && requestAnimationFrame(follow);
};
const lean = (x, y) => {
  aim = [x, y];
  following ||= requestAnimationFrame(follow);
};
light.addEventListener("pointermove", (e) =>
  lean(e.offsetX / light.offsetWidth - 0.5, e.offsetY / light.offsetHeight - 0.5),
);
light.addEventListener("pointerleave", () => lean(0, 0));

const COLOURS = ["#4a8fd8", "#57c89a", "#e2bf55", "#da8097", "#e8a77c"];
const rand = (a, b) => a + Math.random() * (b - a);

async function confetti() {
  const ticket = document.querySelector(".ticket img");
  const heading = document.querySelector(".solo h1");
  const line = document.querySelector(".solo-body");
  const row = document.querySelector(".solo-row");
  // WebKit draws an <img> it has yet to paint into a canvas as nothing, so the edge is read from the file
  const paper = await createImageBitmap(
    await (await fetch(ticket.currentSrc)).blob(),
  );
  await document.fonts.ready;
  const W = document.documentElement.clientWidth;
  const H = document.documentElement.scrollHeight;
  const dpr = Math.min(devicePixelRatio, 2);
  const canvas = document.createElement("canvas");
  canvas.className = "confetti";
  canvas.width = W * dpr;
  canvas.height = H * dpr;
  canvas.style.height = H + "px";
  document.body.append(canvas);
  const ctx = canvas.getContext("2d");

  // the top edge of what `draw` paints in `el`'s box, as a page y for each column of the page
  const edge = (el, draw) => {
    const box = el.getBoundingClientRect();
    const w = Math.ceil(box.width);
    const h = Math.ceil(box.height);
    const scratch = document.createElement("canvas");
    scratch.width = w;
    scratch.height = h;
    const c = scratch.getContext("2d");
    draw(c, box);
    const pixels = c.getImageData(0, 0, w, h).data;
    const tops = new Float32Array(W).fill(Infinity);
    for (let x = 0; x < w; x++)
      for (let y = 0; y < h; y++)
        if (pixels[(y * w + x) * 4 + 3] > 128) {
          tops[Math.round(box.left + scrollX) + x] = box.top + scrollY + y;
          break;
        }
    return tops;
  };
  // each letter where the page set it, so the edge follows wrapping, kerning and tracking
  const letters = (el) => (c, box) => {
    const style = getComputedStyle(el);
    c.font = `${style.fontWeight} ${style.fontSize} ${style.fontFamily}`;
    const rise = c.measureText("").fontBoundingBoxAscent;
    const range = document.createRange();
    const walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
    for (let node; (node = walker.nextNode()); )
      for (let i = 0; i < node.length; i++) {
        range.setStart(node, i);
        range.setEnd(node, i + 1);
        const at = range.getBoundingClientRect();
        c.fillText(node.data[i], at.left - box.left, at.top - box.top + rise);
      }
  };
  const buttons = (c, box) => {
    for (const b of row.children) {
      const at = b.getBoundingClientRect();
      c.roundRect(
        at.left - box.left,
        at.top - box.top,
        at.width,
        at.height,
        parseFloat(getComputedStyle(b).borderRadius),
      );
    }
    c.fill();
  };
  // a piece in lane n can land on surfaces n and after; the last is the foot of the page
  const targets = [ticket, heading, line, row];
  const surfaces = [
    edge(ticket, (c, box) => c.drawImage(paper, 0, 0, box.width, box.height)),
    edge(heading, letters(heading)),
    edge(line, letters(line)),
    edge(row, buttons),
    new Float32Array(W).fill(H - 6),
  ];
  const foot = surfaces.length - 1;

  const over = (el) => {
    const box = el.getBoundingClientRect();
    return rand(box.left, box.right) + scrollX;
  };
  // a taller window gets a faster fall, so the last piece lands about as soon
  const pace = Math.max(1, innerHeight / 900);
  const pieces = Array.from(
    { length: Math.min(160, Math.max(70, W / 8)) },
    (_, n) => {
      // of sixteen: four each for the ticket and the heading, one each for the line and the buttons
      const lane = [0, 1, 4, 4, 0, 1, 4, 2, 0, 1, 4, 4, 0, 1, 4, 3][n % 16];
      const depth = rand(0.7, 1.3);
      return {
        lane,
        x: targets[lane] ? over(targets[lane]) : rand(0, W),
        y: scrollY - rand(20, innerHeight * 0.6),
        drift: rand(-0.4, 0.4),
        fall: rand(3, 4.2) * depth * pace,
        sway: rand(0.3, 1.2),
        wob: rand(0, 6.3),
        wobSpeed: rand(0.05, 0.11),
        rot: rand(0, 6.3),
        spin: rand(-0.12, 0.12),
        flip: rand(0, 6.3),
        flipSpeed: rand(0.08, 0.22),
        face: 1,
        size: rand(8, 12) * depth,
        round: n % 5 === 0,
        colour: COLOURS[n % COLOURS.length],
        rest: false,
        hold: rand(500, 1100),
      };
    },
  );
  addEventListener("resize", () => {
    if (document.documentElement.clientWidth !== W) pieces.length = 0;
  });

  // a ticket that leans holds nothing: what rested on it falls on to the next surface
  light.addEventListener(
    "pointermove",
    () => {
      surfaces[0].fill(Infinity);
      for (const p of pieces)
        if (p.rest && !p.on) {
          p.rest = false;
          p.flip = Math.acos(p.face);
        }
    },
    { once: true },
  );

  let settled = 0;
  let last = performance.now();
  const frame = (now) => {
    // in 60 Hz frames, and at most three after a stall
    const dt = Math.min(3, (now - last) / 16.667);
    last = now;
    ctx.resetTransform();
    ctx.clearRect(0, 0, canvas.width, canvas.height);
    let live = 0;
    let falling = 0;
    for (const p of pieces) {
      if (p.rest) {
        p.face += (p.flat - p.face) * 0.2 * dt;
        p.rot += (p.lie - p.rot) * 0.2 * dt;
      } else {
        const before = p.y;
        p.wob += p.wobSpeed * dt;
        p.flip += p.flipSpeed * dt;
        p.rot += p.spin * dt;
        p.face = Math.cos(p.flip);
        p.x += (p.drift + Math.cos(p.wob) * p.sway) * dt;
        // slower face on to the fall, faster edge on
        p.y += p.fall * (0.75 + 0.5 * Math.abs(Math.sin(p.flip))) * dt;
        const column = Math.max(0, Math.min(W - 1, Math.round(p.x)));
        for (let k = p.lane; k <= foot && !p.rest; k++) {
          const top = surfaces[k][column];
          // only from above, bar the foot of the page, which nothing gets under
          if ((k < foot && before > top) || p.y <= top) continue;
          p.rest = true;
          p.on = k;
          p.y = top - p.size * 0.15;
          p.flat = rand(0.35, 0.75) * (p.face < 0 ? -1 : 1);
          p.lie = Math.round(p.rot / Math.PI) * Math.PI + rand(-0.3, 0.3);
          // the next piece here rests on this one
          for (let x = column - 3; x <= column + 3; x++) surfaces[k][x] -= 1.5;
        }
      }
      if (!p.rest) falling++;
      const gone = settled ? (now - settled - p.hold) / 350 : 0;
      if (gone >= 1) continue;
      live++;
      ctx.setTransform(dpr, 0, 0, dpr, p.x * dpr, p.y * dpr);
      ctx.rotate(p.rot);
      ctx.scale(1, p.face);
      ctx.globalAlpha = Math.min(1, 1 - gone) * (p.face < 0 ? 0.75 : 1);
      ctx.fillStyle = p.colour;
      ctx.beginPath();
      if (p.round) ctx.ellipse(0, 0, p.size / 2, p.size / 2, 0, 0, 7);
      else ctx.rect(-p.size / 2, -p.size * 0.3, p.size, p.size * 0.6);
      ctx.fill();
    }
    if (!falling) settled ||= now;
    if (live) requestAnimationFrame(frame);
    else canvas.remove();
  };
  requestAnimationFrame(frame);
}
if (!matchMedia("(prefers-reduced-motion: reduce)").matches) {
  if (document.readyState === "complete") confetti();
  else addEventListener("load", confetti, { once: true });
}
