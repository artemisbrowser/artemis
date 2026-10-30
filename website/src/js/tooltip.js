import { mq } from "./core.js";

const tip = document.querySelector(".tip");
const GLYPH = {
  meta: "⌘",
  shift: "⇧",
  alt: "⌥",
  ctrl: "⌃",
  enter: "↵",
  down: "↓",
  up: "↑",
  esc: "esc",
};
let cur = null;
let timer = 0;
let warm = 0; // until this time a tooltip shows at once

function show() {
  const keys = cur.dataset.tipKeys?.split(" ") ?? [];
  const caps = document.createElement("span");
  for (const k of keys) {
    const kc = caps.appendChild(document.createElement("kbd"));
    kc.className = "kc sm";
    kc.dataset.k = k;
    kc.textContent = GLYPH[k] ?? k.toUpperCase();
  }
  tip.replaceChildren(cur.dataset.tip, ...(keys.length ? [caps] : []));
  const r = cur.getBoundingClientRect();
  const w = tip.offsetWidth;
  const h = tip.offsetHeight;
  const below = r.bottom + 8 + h <= innerHeight;
  const cx = r.left + r.width / 2;
  const start = cx - 6 + w <= innerWidth - 8;
  // the 2 px corner points back at the control
  tip.dataset.at = `${below ? "below" : "above"} ${start ? "start" : "end"}`;
  tip.style.translate = `${Math.max(8, start ? cx - 6 : cx + 6 - w)}px ${below ? r.bottom + 8 : r.top - 8 - h}px`;
  tip.classList.add("on");
}

function hide() {
  clearTimeout(timer);
  if (tip.classList.contains("on")) warm = performance.now() + 1000;
  tip.classList.remove("on");
  cur = null;
}

const rest = () => {
  clearTimeout(timer);
  timer = setTimeout(show, performance.now() < warm ? 0 : 700);
};

document.addEventListener("pointerover", (e) => {
  const el = e.target.closest?.("[data-tip]");
  if (el === cur) return;
  hide();
  if (!el || e.pointerType === "touch" || !mq.fine.matches) return;
  cur = el;
  rest();
});
document.addEventListener(
  "pointermove",
  () => cur && !tip.classList.contains("on") && rest(),
  { passive: true },
);
document.addEventListener(
  "pointerout",
  (e) => cur && !cur.contains(e.relatedTarget) && hide(),
);
document.addEventListener("pointerdown", hide);
addEventListener("scroll", () => cur && hide(), { passive: true });
addEventListener("keydown", (e) => e.key === "Escape" && hide());
