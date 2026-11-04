import { root, mq, say, go } from "./core.js";
import { SITE_SECTIONS } from "./data.js";
import { openPeek } from "./peek.js";
import { setSitebar } from "./sitebar.js";

const KIND = {
  literal: -1,
  math: -1,
  tab: 0,
  history: 1,
  section: 1,
  action: 2,
  space: 3,
};
const esc = (s) => String(s).replace(/[&<>"]/g, (c) => `&#${c.charCodeAt(0)};`);
const glyph = (id) => `<svg class="ico"><use href="#${id}"/></svg>`;
const wait = (ms) => new Promise((r) => setTimeout(r, ms));

// Arithmetic only: digits, . + - * / × ÷ ^ ( ), at least one operator between numbers. Never eval.
export function evaluate(expr) {
  const s = expr.replace(/^\s*=/, "").replace(/\s+/g, "");
  if (!/^[\d.+\-*/×÷^()]+$/.test(s) || !/[\d.)][+\-*/×÷^][-+(]*[\d.]/.test(s))
    return null;
  let i = 0;
  const primary = () => {
    if (s[i] === "(") {
      i++;
      const v = sum();
      if (s[i++] !== ")") throw 0;
      return v;
    }
    const m = /^(\d+\.?\d*|\.\d+)/.exec(s.slice(i));
    if (!m) throw 0;
    i += m[0].length;
    return +m[0];
  };
  const unary = () =>
    s[i] === "-" ? (i++, -unary()) : s[i] === "+" ? (i++, unary()) : primary();
  const factor = () => {
    const b = unary();
    return s[i] === "^" ? (i++, b ** factor()) : b;
  };
  const term = () => {
    let v = factor();
    while (s[i] && "*×/÷".includes(s[i]))
      v = "*×".includes(s[i++]) ? v * factor() : v / factor();
    return v;
  };
  const sum = () => {
    let v = term();
    while (s[i] === "+" || s[i] === "-")
      v = s[i++] === "+" ? v + term() : v - term();
    return v;
  };
  try {
    const v = sum();
    return i === s.length && Number.isFinite(v) ? +v.toFixed(10) : null;
  } catch {
    return null;
  }
}

// Item = { kind, title, sub, words, tag, icon, verb, keys, run, split, always }. title, sub and words are text; icon and tag
// are markup. index(query) may return items marked always: true, which are listed even when the title does not match.
export function createCommandBar(
  el,
  {
    index,
    literal,
    scopes = true,
    maxRows = 8,
    onRun,
    onClose,
    idPrefix = "cmd",
  },
) {
  const input = el.querySelector("input");
  const list = el.querySelector(".cmd-list");
  const lead = el.querySelector(".cmd-field .ico");
  const scopeBtns = [...el.querySelectorAll(".scope")];
  const unscoped = input.placeholder;
  const mode = (b) => b.dataset.tip.toLowerCase(); // the app's scope token, after the @
  let results = [];
  let sel = 0;
  let scope = null; // the scope button picked
  let token = 0; // bumped by visitor input and by open/close, which stops a scripted type()
  list.id = idPrefix + "-list";
  input.setAttribute("aria-controls", list.id);

  function search(q) {
    const v = q.trim();
    const lq = v.toLowerCase();
    const modes =
      scope || !/^@\S*$/.test(v)
        ? []
        : scopeBtns.filter((b) => mode(b).startsWith(lq.slice(1)));
    if (modes.length)
      return modes.map((b) => ({
        kind: "scope",
        title: `Search ${b.dataset.tip}`,
        sub: "@" + mode(b),
        icon: b.innerHTML,
        verb: "Narrow",
        run: () => ((input.value = ""), narrow(b)),
      }));
    const out = [];
    if (v && !scope) {
      out.push(literal(v));
      const m = evaluate(v);
      if (m !== null)
        out.push({
          kind: "math",
          title: String(m),
          sub: v.replace(/^=\s*/, "") + " =",
          icon: "=",
          verb: "Copy",
          run: () => navigator.clipboard?.writeText(String(m)).catch(() => {}),
        });
    }
    const scored = [];
    for (const it of index(v)) {
      if (scope && it.kind !== scope.dataset.scope) continue;
      const t = it.title.toLowerCase();
      const k = t.indexOf(lq);
      const s = !lq
        ? 1
        : k === 0
          ? 3
          : k > 0
            ? /[\s(-]/.test(t[k - 1])
              ? 2
              : 1
            : it.always ||
                (lq.length > 2 &&
                  ` ${[it.words, it.sub].join(" ")}`
                    .toLowerCase()
                    .includes(" " + lq))
              ? 1
              : 0;
      if (s) scored.push([s, it]);
    }
    scored.sort((a, b) => b[0] - a[0] || KIND[a[1].kind] - KIND[b[1].kind]);
    return [...out, ...scored.map((x) => x[1])].slice(
      0,
      scope ? maxRows + 1 : maxRows,
    );
  }

  function mark(title, q) {
    const k = q ? title.toLowerCase().indexOf(q) : -1;
    return k < 0
      ? esc(title)
      : esc(title.slice(0, k)) +
          "<b>" +
          esc(title.slice(k, k + q.length)) +
          "</b>" +
          esc(title.slice(k + q.length));
  }

  function render() {
    const q = input.value.trim().toLowerCase();
    list.innerHTML = results
      .map((r, i) => {
        const tile = r.kind === "tab" || r.kind === "history" ? " tile" : "";
        const keys = (r.keys ?? [])
          .map((k) => `<kbd class="kc sm" aria-hidden="true">${esc(k)}</kbd>`)
          .join("");
        return (
          `<li class="opt" role="option" id="${idPrefix}-o${i}" data-n="${i}" aria-selected="${i === sel}">` +
          `<span class="oi${tile}">${r.icon ?? ""}</span><span class="ot">${r.kind === "literal" || r.kind === "math" ? esc(r.title) : mark(r.title, q)}</span>` +
          `<span class="os"><span class="os-t">${esc(r.sub ?? "")}</span>${keys}</span>${r.tag ? `<span class="tag">${r.tag}</span>` : ""}` +
          `<span class="verb" aria-hidden="true">${esc(r.verb)}<kbd class="kc sm">↵</kbd></span></li>`
        );
      })
      .join("");
    el.dataset.rows = results.length;
    select(0);
  }

  function select(i) {
    sel = i;
    for (const o of list.children)
      o.setAttribute("aria-selected", String(+o.dataset.n === i));
    input.setAttribute("aria-expanded", String(results.length > 0));
    results.length
      ? input.setAttribute("aria-activedescendant", `${idPrefix}-o${i}`)
      : input.removeAttribute("aria-activedescendant");
  }

  function update() {
    const typed = !scopes || !!scope || !!input.value;
    el.dataset.state = typed ? "typed" : "empty";
    results = typed ? search(input.value) : [];
    render();
  }

  // A scope lists one kind of row; its prompt names the field, and its glyph leads it in the space's accent.
  function pick(b) {
    scope = b;
    input.placeholder = b?.dataset.prompt ?? unscoped;
    input.setAttribute("aria-label", input.placeholder);
    lead.firstElementChild.setAttribute(
      "href",
      b?.querySelector("use").getAttribute("href") ?? "#i-search",
    );
    lead.style.cssText = b ? "color: var(--accent); stroke-width: 2.3" : "";
  }

  // The field takes focus, or says its new prompt when it already has it.
  function narrow(b) {
    pick(b);
    update();
    document.activeElement === input
      ? say(input.placeholder)
      : input.focus({ preventScroll: true });
  }

  const move = (d) =>
    results.length && select((sel + d + results.length) % results.length);

  function run(split) {
    const r = results[sel];
    if (r?.kind === "scope") return r.run();
    close();
    if (!r) return;
    (split && r.split ? r.split : r.run)?.();
    onRun?.(r, split);
  }

  // scope: 0 unscoped, 1–4 the ⌘1–⌘4 scope; left out, the bar keeps the one it has
  function open({
    value = "",
    focus = true,
    selectAll = false,
    scope: s,
  } = {}) {
    token++;
    el.inert = false;
    if (s !== undefined) pick(scopeBtns[s - 1]);
    input.value = value;
    update();
    if (focus) input.focus({ preventScroll: true });
    if (selectAll) input.select();
  }

  function close() {
    if (el.dataset.state === "closed") return;
    token++;
    el.dataset.state = "closed";
    el.inert = true;
    // the scope goes once the 150 ms fade is over, unless the bar opened again
    const t = token;
    if (scope) setTimeout(() => t === token && pick(null), 150);
    input.setAttribute("aria-expanded", "false");
    input.removeAttribute("aria-activedescendant");
    if (document.activeElement === input) input.blur();
    onClose?.();
  }

  // Resolves false when the visitor (or open/close) interrupts. Pass a pausable sleep to stop time with a demo runner.
  async function type(text, { jitter = true, sleep = wait } = {}) {
    const t = ++token;
    for (const c of text) {
      input.value += c;
      update();
      await sleep(
        50 +
          (jitter ? Math.random() * 25 : 12) +
          (input.value.length === 1 ? 110 : 0),
      );
      if (t !== token) return false;
    }
    return true;
  }

  input.addEventListener("input", () => {
    token++;
    const v = input.value;
    // typing a whole "@tabs " drops into that scope
    const b =
      !scope &&
      /^@.* $/.test(v) &&
      scopeBtns.find((x) => mode(x) === v.slice(1).trim().toLowerCase());
    if (!b) return update();
    input.value = "";
    narrow(b);
  });
  input.addEventListener("keydown", (e) => {
    if (e.isComposing) return;
    if (e.key === "ArrowDown" || e.key === "ArrowUp")
      move(e.key === "ArrowDown" ? 1 : -1);
    else if (e.key === "Enter") run(e.metaKey);
    else if (e.key === "Escape") {
      e.stopPropagation();
      // the ⌘T bar steps back through the typed text, then the scope; the page bar closes
      if (scopes && input.value) set("");
      else if (scope) narrow(null);
      else close();
    } else if (e.key === "Backspace" && scope && !input.value) narrow(null);
    else return;
    e.preventDefault();
  });
  // ⌘1–⌘4 toggle a scope and keep the typed text
  el.addEventListener("keydown", (e) => {
    const b = scopeBtns[/^Digit([1-4])$/.exec(e.code)?.[1] - 1];
    if (!b || !e.metaKey || e.altKey || e.ctrlKey || e.shiftKey) return;
    e.preventDefault();
    narrow(scope === b ? null : b);
  });
  list.addEventListener("pointermove", (e) => {
    const o = e.target.closest(".opt");
    if (o && +o.dataset.n !== sel) select(+o.dataset.n);
  });
  list.addEventListener("click", (e) => {
    const o = e.target.closest(".opt");
    if (!o) return;
    sel = +o.dataset.n;
    run(e.metaKey);
  });
  for (const b of scopeBtns) b.addEventListener("click", () => narrow(b));
  document.addEventListener("pointerdown", (e) => {
    if (el.dataset.state !== "closed" && !el.contains(e.target)) close();
  });

  const set = (value) => {
    input.value = value;
    update();
  };
  return {
    open,
    close,
    set,
    type,
    get isOpen() {
      return el.dataset.state !== "closed";
    },
  };
}

/* ---------- the page command bar ---------- */

const registry = [];
// fn(query) returns the items to list for that query; they show even when their titles do not match.
export const addPageItems = (fn) => registry.push(fn);

const pagebar = document.getElementById("pagebar");
const card = pagebar.querySelector(".cmd");
const pill = document.querySelector(".nav-pill");
const peekRow = (title, sub, id, icon) => ({
  kind: "action",
  title,
  sub,
  icon: glyph(icon),
  verb: "Peek",
  run: () => openPeek(id),
});
const ACTIONS = [
  {
    kind: "action",
    title: "Download Artemis",
    sub: "macOS 26 or later",
    icon: glyph("i-download"),
    verb: "Open",
    run: () => document.querySelector("[data-get]").click(),
  },
  peekRow("Keyboard shortcuts", "On this site", "shortcuts", "i-command"),
  peekRow(
    "What stays on your Mac",
    "No account and no telemetry",
    "mac",
    "i-shield",
  ),
  peekRow("The licence", "Source-available", "licence", "i-doc"),
  {
    kind: "action",
    title: "Source code",
    sub: "On GitHub",
    icon: glyph("i-code"),
    verb: "Open",
    run: () =>
      document.querySelector('#sitebar a[href^="https://github"]').click(),
  },
];
const SECTIONS = SITE_SECTIONS.filter(([id]) =>
  document.getElementById(id),
).map(([id, title, sub]) => ({
  kind: "section",
  title,
  sub,
  icon: glyph(
    document
      .querySelector(`#sitebar a[href="#${id}"] use`)
      ?.getAttribute("href")
      .slice(1) ?? "i-doc",
  ),
  verb: "Go",
  run: () => go(id),
}));

const fcap = document.querySelector(".fcap");
let hits = [];
let at = 0;
let capT = 0;
let held = null;
function step(k) {
  at = (k + hits.length) % hits.length;
  const r = hits[at];
  CSS.highlights?.set("find-now", new Highlight(r));
  r.startContainer.parentElement.scrollIntoView({
    block: "center",
    behavior: mq.reduce.matches ? "auto" : "smooth",
  });
  tell(hits.length > 1 ? `${at + 1} of ${hits.length} matches` : "1 match");
}
function tell(text) {
  fcap.textContent = text;
  fcap.classList.add("on");
  clearTimeout(capT);
  capT = setTimeout(() => fcap.classList.remove("on"), 2500);
  say(text);
}
function unfind() {
  hits = [];
  CSS.highlights?.delete("find");
  CSS.highlights?.delete("find-now");
  fcap.classList.remove("on");
}

// Starts at the first match below the nav. ↵ and ⇧↵ step while focus stays where the search left it; Esc clears.
function find(q) {
  const s = q.toLowerCase();
  const ranges = [];
  const walker = document.createTreeWalker(
    document.getElementById("main"),
    NodeFilter.SHOW_TEXT,
    {
      acceptNode: (n) =>
        n.parentElement.closest('[aria-hidden="true"], template, .cmd, .nav') ||
        n.parentElement.checkVisibility?.({ visibilityProperty: true }) ===
          false
          ? NodeFilter.FILTER_REJECT
          : NodeFilter.FILTER_ACCEPT,
    },
  );
  for (let n; (n = walker.nextNode());) {
    const t = n.data.toLowerCase();
    for (let i = t.indexOf(s); i >= 0; i = t.indexOf(s, i + s.length)) {
      const r = new Range();
      r.setStart(n, i);
      r.setEnd(n, i + s.length);
      ranges.push(r);
    }
  }
  hits = ranges;
  held = document.activeElement;
  CSS.highlights?.set("find", new Highlight(...ranges));
  if (!ranges.length) return tell(`No matches for “${q}”`);
  const k = ranges.findIndex((r) => r.getBoundingClientRect().top >= 80);
  step(Math.max(0, k));
}

const css = (name) => getComputedStyle(root).getPropertyValue(name).trim();
let opener = null;
let anim = null;
let said = 0;

// The bar grows out of the nav pill (the address morph); phones get a plain sheet.
function morph(open) {
  const p = pill?.getBoundingClientRect();
  if (!p?.width || mq.reduce.matches) return null;
  const b = card.getBoundingClientRect();
  const from = `translate(${p.left + p.width / 2 - (b.left + b.width / 2)}px, ${p.top - b.top}px) scale(${p.width / b.width})`;
  const flat = css(open ? "--ease-out-flat" : "--ease-in-flat");
  card.animate(
    { transform: open ? [from, "none"] : ["none", from] },
    open
      ? {
          duration: parseFloat(css("--dur-address")),
          easing: css("--spring-address"),
        }
      : { duration: 200, easing: flat },
  );
  // only the closing fade holds its end value: a filling opacity animation would keep the glass from blurring
  return card.animate(
    { opacity: open ? [0, 1] : [1, 0] },
    {
      duration: open ? 120 : 200,
      easing: flat,
      fill: open ? "none" : "forwards",
    },
  );
}

const bar = createCommandBar(card, {
  index: (q) => [
    ...SECTIONS,
    ...ACTIONS,
    ...registry.flatMap((fn) => fn(q).map((it) => ({ ...it, always: true }))),
  ],
  literal: (q) => ({
    kind: "literal",
    title: q,
    icon: glyph("i-search"),
    verb: "Find on Page",
    run: () => find(q),
  }),
  scopes: false,
  idPrefix: "pb",
  onClose() {
    clearTimeout(said);
    if (document.activeElement === document.body)
      opener?.focus({ preventScroll: true });
    anim?.cancel();
    anim = morph(false);
    if (anim) anim.onfinish = () => (pagebar.hidden = true);
    else pagebar.hidden = true;
  },
});

export function openPageBar(value = "") {
  if (bar.isOpen) return;
  opener = document.activeElement;
  unfind();
  setSitebar(false);
  anim?.cancel();
  pagebar.hidden = false;
  bar.open({ value });
  anim = morph(true);
}

let wasOpen = false;
for (const b of document.querySelectorAll(".nav-pill, .nav-search")) {
  b.addEventListener("pointerdown", () => (wasOpen = bar.isOpen));
  b.addEventListener("click", () =>
    wasOpen ? (wasOpen = false) : openPageBar(),
  );
}
card.querySelector("input").addEventListener("input", () => {
  clearTimeout(said);
  said = setTimeout(() => {
    const n = card.querySelectorAll(".opt").length;
    say(n === 1 ? "1 result" : n + " results");
  }, 400);
});
pagebar.addEventListener(
  "focusout",
  (e) => e.relatedTarget && !pagebar.contains(e.relatedTarget) && bar.close(),
);
addEventListener("keydown", (e) => {
  if (e.key === "Escape") return unfind();
  if (e.key !== "Enter" || !hits.length || e.target !== held) return;
  e.preventDefault();
  step(at + (e.shiftKey ? -1 : 1));
});
