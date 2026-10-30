import { root, mq, go } from "./core.js";
import { mods, onMods } from "./keys.js";
import { setSitebar } from "./sitebar.js";

const peek = document.getElementById("peek");
const panel = peek.querySelector(".peek-panel");
const content = peek.querySelector(".peek-content");
const openBtn = peek.querySelector('[data-act="open"]');
const behind = () => document.querySelectorAll("main, #nav, .foot, .skip");
let opener = null;
let target = null;
let hideTimer = 0;

// what: a template name ("shortcuts" opens template#peek-shortcuts) or a section, shown as its heading and lede.
export function openPeek(what, from = document.activeElement) {
  const nodes = [];
  if (typeof what === "string") {
    const t = document.getElementById("peek-" + what);
    if (!t) return;
    nodes.push(t.content.cloneNode(true));
    target = null;
  } else {
    const s = what.querySelector("[data-peek-summary]") ?? what;
    const h = s.querySelector("h1, h2");
    if (!h) return go(what.id);
    const title = document.createElement("h2");
    title.append(...h.cloneNode(true).childNodes);
    const lede = [...s.querySelectorAll("p")].find(
      (p) => h.compareDocumentPosition(p) & 4,
    );
    for (const n of [title, lede]) {
      if (!n) continue;
      const c = n === title ? n : n.cloneNode(true);
      for (const x of [c, ...c.querySelectorAll("*")])
        ["id", "inert"].forEach((a) => x.removeAttribute(a));
      nodes.push(c);
    }
    target = what.id;
  }
  content.replaceChildren(...nodes);
  content.querySelector("h2").id = "peek-title";
  openBtn.hidden = !target;
  opener = from;
  setSitebar(false);
  clearTimeout(hideTimer);
  peek.hidden = false;
  root.classList.add("peek-open");
  for (const el of behind()) el.inert = true;
  requestAnimationFrame(() => peek.classList.add("on"));
  panel.scrollTop = 0;
  panel.focus({ preventScroll: true });
}

export function closePeek() {
  if (!peek.classList.contains("on")) return;
  peek.classList.remove("on");
  root.classList.remove("peek-open");
  for (const el of behind()) el.inert = false;
  opener?.focus({ preventScroll: true });
  hideTimer = setTimeout(() => (peek.hidden = true), 150);
}

peek.addEventListener("click", (e) => {
  const act = e.target.closest("[data-act]")?.dataset.act;
  if (act === "open") {
    const id = target;
    closePeek();
    go(id);
  } else if (act === "close" || e.target.matches(".peek-scrim")) closePeek();
});
// Tab cycles inside the box, through the panel itself so it can scroll again; everything behind it is inert.
peek.addEventListener("keydown", (e) => {
  if (e.key !== "Tab") return;
  const f = [
    panel,
    ...[...peek.querySelectorAll("a[href], button")].filter(
      (x) => !x.closest("[hidden]"),
    ),
  ];
  const i = f.indexOf(document.activeElement);
  e.preventDefault();
  f.at(i < 0 ? 0 : (i + (e.shiftKey ? -1 : 1)) % f.length).focus();
});

/* ---------- link capsule: what a click would do in Artemis, relabelled under held modifiers ---------- */
const cap = document.querySelector(".lcap");
const capText = cap.firstElementChild;
const LINKS = 'a[href^="#"], a[data-peek], a[data-get]';
const host = new URL(document.querySelector('link[rel="canonical"]').href).host;
const domain = /artemis_domain/i.test(host) ? "" : host;
let capFor = null;

function label(a) {
  const href = a.getAttribute("href");
  const name =
    a.dataset.peek || a.hasAttribute("data-get")
      ? a.textContent.trim()
      : (document.getElementById(href.slice(1))?.closest("[data-name]")?.dataset
          .name ?? a.textContent.trim());
  const m = mods();
  if (m.has("alt"))
    return m.has("meta")
      ? "In Artemis, this opens in Scout"
      : "In Artemis, this opens in Split View";
  if (m.has("shift"))
    return `Open ${name} in ${m.has("meta") ? "a New Tab" : "Peek"}`;
  if (m.has("meta")) return `Open ${name} in a Background Tab`;
  return domain ? domain + "/" + href.replace(/^\//, "") : `Artemis › ${name}`;
}

function showCap(a) {
  capFor = a;
  const t = label(a);
  if (capText.textContent !== t) {
    if (cap.classList.contains("on"))
      capText.animate(
        { opacity: [0, 1] },
        { duration: 120, easing: "cubic-bezier(0, 0, .58, 1)" },
      );
    capText.textContent = t;
  }
  cap.classList.add("on");
}
function hideCap() {
  capFor = null;
  cap.classList.remove("on");
}

document.addEventListener("pointerover", (e) => {
  const a = e.target.closest?.(LINKS);
  if (
    a &&
    mq.fine.matches &&
    e.pointerType !== "touch" &&
    !a.closest('[aria-hidden="true"]')
  )
    showCap(a);
});
document.addEventListener("pointerout", (e) => {
  if (
    capFor &&
    e.target.closest?.(LINKS) === capFor &&
    !capFor.contains(e.relatedTarget)
  )
    hideCap();
});
addEventListener("scroll", () => capFor && hideCap(), { passive: true });
onMods(() => capFor && showCap(capFor));

document.addEventListener("click", (e) => {
  const a = e.target.closest?.(LINKS);
  if (!a || e.defaultPrevented || e.metaKey || e.ctrlKey) return;
  // a browser downloads on ⌥-click, so it is cancelled and the capsule flashes its Split View text
  if (e.altKey) {
    e.preventDefault();
    if (capFor)
      cap.animate(
        { scale: [1, 1.06, 1] },
        { duration: 260, easing: "ease-out" },
      );
    return;
  }
  const from = a.closest("[inert]") ? document.activeElement : a;
  const href = a.getAttribute("href");
  if (a.dataset.peek) {
    e.preventDefault();
    openPeek(a.dataset.peek, from);
  } else if (href.startsWith("#") && href.length > 1) {
    const sec = document.getElementById(href.slice(1));
    if (!sec) return;
    e.preventDefault();
    hideCap();
    e.shiftKey ? openPeek(sec.closest("section") ?? sec, from) : go(sec.id);
  }
});
addEventListener("keydown", (e) => {
  if (e.key !== "Escape") return;
  hideCap();
  closePeek();
});
