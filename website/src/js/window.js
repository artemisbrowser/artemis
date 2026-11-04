// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import { SPACES, HOST, TABS, HISTORY } from "./data.js";
import { state, paint, subscribe, setLook as pickLook } from "./looks.js";
import { registerReplica, mq } from "./core.js";
import { createCommandBar } from "./cmdbar.js";
import { openPeek } from "./peek.js";

const ALL = [...TABS.flatMap((s) => [...s.pinned, ...s.today]), ...HISTORY];
// a tab's page is a full page id, or its own title when it only has a dek (rendered into the lite page)
const pid = (t) => (t[3].includes(" ") ? t[0] : t[3]);
const tabOf = (id) => ALL.find((t) => pid(t) === id);
const EASE = "cubic-bezier(.42,0,.58,1)";
const OUT = "cubic-bezier(0,0,.58,1)";
const make = (tag, cls, text = "") =>
  Object.assign(document.createElement(tag), {
    className: cls,
    textContent: text,
  });
const mounted = new WeakMap();

export function mountWindow(rig, opts = {}) {
  if (mounted.has(rig)) return mounted.get(rig);
  const win = rig.querySelector(".win");
  const $ = (s) => win.querySelector(s);
  const $$ = (s) => [...win.querySelectorAll(s)];
  const hosts = [
    ...rig.querySelectorAll("[data-host]"),
    ...(opts.sky ? [opts.sky] : []),
  ];
  const strip = $(".strip");
  const pages = $(".page-pin");
  const dom = $(".dom");
  const S = {
    space: 0,
    sidebar: "pinned",
    float: "hidden",
    split: 1,
    focus: 0,
    edge: 10,
  };
  const shown = SPACES.map((s) => s.page);
  const subs = {};
  let previous = shown[0];
  let front = pages?.querySelector(".pg.on");
  let cmd;

  const emit = (type, d) => subs[type]?.forEach((fn) => fn(d));
  const look = () => state.looks[S.space];
  const instant = (fn) => {
    win.dataset.instant = "";
    fn();
    requestAnimationFrame(() =>
      requestAnimationFrame(() => delete win.dataset.instant),
    );
  };
  const repaint = (ms, ease) => {
    win.dataset.accent = look();
    for (const h of hosts) paint(h, look(), { ms, ease });
  };
  const load = (then) => {
    const tube = $(".loadbar");
    tube.classList.add("on");
    setTimeout(() => {
      then?.();
      tube.classList.remove("on");
    }, 260);
  };

  function swap(el) {
    if (el === front) return;
    front = el;
    if (win.hasAttribute("data-instant")) {
      for (const p of pages.querySelectorAll(".pg.on"))
        p.classList.remove("on", "in");
      return el.classList.add("on");
    }
    el.classList.add("on", "in");
    el.animate({ opacity: [0, 1] }, { duration: 80, easing: EASE }).onfinish =
      () => {
        if (front !== el) return;
        for (const p of pages.querySelectorAll(".pg.on"))
          if (p !== el) p.classList.remove("on");
        el.classList.remove("in");
      };
  }
  function lite([title, host, , dek]) {
    const el = pages.querySelector('[data-page="lite"]');
    const masthead = ALL.find((t) => t[1] === host && pid(t) === t[3])[3];
    const skin = pages.querySelector(`[data-page="${masthead}"]`);
    const col = make("div", "pcol");
    col.append(make("p", "pt", title), make("p", "pd", dek));
    el.className = `pg ${skin.classList[1]}${el === front ? " on" : ""}`;
    el.replaceChildren(skin.firstElementChild.cloneNode(true), col);
    return el;
  }
  function render(id, query, note) {
    let el = pages.querySelector(`[data-page="${id}"]`);
    const tab = tabOf(id);
    if (query !== undefined) {
      el.querySelector(".pt").textContent = query;
      el.dataset.note = note;
    } else if (!el) el = lite(tab);
    swap(el);
    dom.textContent = tab ? HOST[tab[1]] : el.querySelector(".pt").textContent;
  }
  function select(title, fav) {
    const panel = strip.children[S.space];
    let row = [...panel.querySelectorAll(".row")].find(
      (r) => r.textContent.trim() === title,
    );
    if (!row) {
      row = make("div", "row");
      row.append(make("i", "fi fi-" + fav), make("span", "t", title));
      panel.querySelector(".row.new").after(row);
    }
    panel.querySelector(".row.lit")?.classList.remove("g", "lit");
    row.classList.add("g", "lit");
  }

  function showPage(id, { load: slow = false, query, note } = {}) {
    if (id === shown[S.space] && query === undefined) return;
    const tab = tabOf(id);
    previous = shown[S.space];
    shown[S.space] = id;
    win.dataset.nav = "";
    select(tab ? tab[0] : query, tab ? tab[2] : "globe");
    slow ? load(() => render(id, query, note)) : render(id, query, note);
  }

  function setSpace(i, { via = "click" } = {}) {
    if (i === S.space) return;
    const from = S.space;
    S.space = i;
    if (via === "instant") instant(() => {});
    else win.dataset.via = via;
    if (via === "click" && Math.abs(i - from) > 1) {
      strip.style.transition = "none";
      strip.style.setProperty("--si", i - Math.sign(i - from));
      strip.offsetWidth; // commits the jump so only the last slot slides
      strip.style.transition = "";
    }
    strip.style.setProperty("--si", i);
    win.dataset.space = i;
    win.dataset.profile = SPACES[i].profile;
    $(".prof use").setAttribute(
      "href",
      "#i-person" + (SPACES[i].profile === "work" ? "-work" : ""),
    );
    const glide = via === "scroll" || via === "swipe";
    const ms =
      via === "instant" ? 0 : glide ? (mq.reduce.matches ? 200 : 420) : 200;
    const ease = glide ? OUT : EASE;
    // a glide spreads its restyles over four frames: strip, page, backdrops, window accent;
    // a newer setSpace drops the frames still pending
    const later = glide
      ? (f) => requestAnimationFrame(() => S.space === i && f())
      : (f) => f();
    later(() => {
      if (pages) render(shown[i]);
      later(() => {
        for (const h of hosts) paint(h, look(), { ms, ease });
        later(() => (win.dataset.accent = look()));
      });
    });
    emit("space", i);
  }

  function setSidebar(open, { instant: now = false } = {}) {
    const v = open ? "pinned" : "hidden";
    if (S.sidebar === v) return;
    const go = () => (win.dataset.sidebar = S.sidebar = v);
    now ? instant(go) : go();
    emit("sidebar", open);
  }

  function pills() {
    const panes = $$(".pane");
    const sel = strip.children[S.space].querySelector(".row.lit");
    panes.forEach((p, k) =>
      p.classList.toggle("f", S.split > 1 && k === S.focus),
    );
    strip.querySelector(".srow")?.remove();
    for (const r of strip.querySelectorAll(".row[hidden]")) r.hidden = false;
    sel.hidden = S.split > 1;
    if (S.split < 2) return;
    const row = make("div", "srow");
    panes.slice(0, S.split).forEach((p, k) => {
      const [title, host, fav] = tabOf(
        p.dataset.page || p.firstElementChild.dataset.page,
      ) ?? [p.querySelector(".pt").textContent, , "globe"];
      // a split is one sidebar row: the other members' own rows give way to it
      if (k)
        for (const r of strip.children[S.space].querySelectorAll(".row"))
          r.hidden ||= r.textContent.trim() === title;
      const pill = make("span", "spill g lit");
      pill.append(make("i", "fi fi-" + fav), make("span", "t", title));
      row.append(pill);
      if (k === S.focus) dom.textContent = HOST[host] ?? title;
    });
    sel.after(row);
  }
  // A pane's frame springs from where it is drawn to its new tile by translate, width and height;
  // its top and left never animate.
  function setSplit(n) {
    if (n === S.split) return;
    const box = $(".panes");
    const panes = $$(".pane");
    const at = (p, o = box.getBoundingClientRect()) => {
      const r = p.getBoundingClientRect();
      return [r.x - o.x, r.y - o.y, r.width, r.height];
    };
    const from = panes.map((p) => at(p));
    for (const p of panes) {
      p.anim?.cancel();
      p.removeAttribute("style");
    }
    if (pages && S.split === 1)
      [shown[S.space], previous].forEach((id, k) => {
        panes[k].dataset.page = id;
        panes[k].replaceChildren(
          (pages.querySelector(`[data-page="${id}"]`) || front).cloneNode(true),
        );
      });
    win.dataset.split = S.split = n;
    S.focus = Math.min(S.focus, n - 1);
    pills();
    emit("split", n);
    const cs = getComputedStyle(box);
    if (win.hasAttribute("data-instant") || cs.visibility === "hidden") return;
    const dur = cs.getPropertyValue("--dur-panel").trim();
    const timing = {
      duration: parseFloat(dur) * (dur.endsWith("ms") ? 1 : 1000),
      easing: cs.getPropertyValue("--spring-panel").trim(),
    };
    panes.forEach((p, k) => {
      const [x, y, w, h] = from[k];
      const to = at(p);
      if (String(to) === String(from[k])) return;
      // per axis, a page holds its end size where its pane enters or shrinks and follows the frame
      // where it grows from a visible size; a closing page keeps its size; past the page is its paper
      const [pw, ph] = to[2] && to[3] ? to.slice(2) : [w, h];
      if (!w || pw <= w) p.style.setProperty("--pw", pw + "px");
      if (!h || ph <= h) p.style.setProperty("--ph", ph + "px");
      p.style.backgroundColor = getComputedStyle(
        p.firstElementChild,
      ).backgroundColor;
      p.anim = p.animate(
        {
          translate: [`${x - to[0]}px ${y - to[1]}px`, "0px 0px"],
          width: [w + "px", to[2] + "px"],
          height: [h + "px", to[3] + "px"],
        },
        timing,
      );
      p.anim.onfinish = () => p.removeAttribute("style");
    });
  }
  // keyframes and page holds are px, so a resize lands a running split at once
  addEventListener("resize", () =>
    $$(".pane").forEach((p) => p.anim?.finish()),
  );

  function hud(keys) {
    const el = $(".hud");
    el.replaceChildren(...keys.map((k) => make("kbd", "kc", k)));
    const from =
      el.anim?.playState === "running" ? getComputedStyle(el).opacity : 0;
    el.anim?.cancel();
    el.anim = el.animate(
      { opacity: [from, 1, 1, 0], offset: [0, 0.133, 0.778, 1], easing: EASE },
      900,
    );
    el.anim.onfinish = () => el.replaceChildren();
  }

  const ctl = {
    rig,
    win,
    instant,
    get state() {
      return { ...S };
    },
    setSpace,
    setLook: (i, lk, { ms = 350 } = {}) => pickLook(i, lk, { ms }),
    setSidebar,
    setFloat(v) {
      if (S.float !== v) win.dataset.float = S.float = v;
    },
    setEdge(p) {
      if (S.edge !== p) win.style.setProperty("--edge", (S.edge = p));
    },
    setSplit,
    focusPane(i) {
      if (i === S.focus || i >= S.split) return;
      S.focus = i;
      pills();
    },
    showPage,
    copyLink() {
      const use = $(".url .link use");
      if (use.getAttribute("href") === "#i-check") return;
      use.setAttribute("href", "#i-check");
      setTimeout(() => use.setAttribute("href", "#i-link"), 1200);
    },
    hud,
    rim() {
      const r = $(".rim");
      r.classList.remove("sweep");
      r.offsetWidth; // restarts the sweep
      r.classList.add("sweep");
    },
    openCommandBar: (o) => cmd.open(o),
    closeCommandBar: () => cmd.close(),
    typeQuery: (text, o) => cmd.type(text, o),
    on: (type, fn) => (subs[type] ||= []).push(fn),
  };

  if (opts.cmd) {
    const el = $(".cmd");
    const fav = (t) => `<i class="fi fi-${t[2]}"></i>`;
    const sym = (id, lk) =>
      `<svg class="${lk ? "sicon" : "gl"}"${lk ? ` data-accent="${lk}"` : ""}><use href="#${id}"/></svg>`;
    const act = (title, id, keys, words, run, verb = "Run", sub) => ({
      kind: "action",
      title,
      sub,
      words,
      icon: sym(id),
      keys,
      verb,
      run,
    });
    const index = () => [
      ...TABS.flatMap((sp, s) =>
        [...sp.pinned, ...sp.today].map((t) => ({
          kind: "tab",
          title: t[0],
          sub: HOST[t[1]],
          icon: fav(t),
          tag:
            s === S.space
              ? ""
              : sym(SPACES[s].glyph, state.looks[s]) + SPACES[s].name,
          verb: "Switch to Tab",
          run: () => (setSpace(s), showPage(pid(t))),
          split: () => (setSpace(s), showPage(pid(t)), setSplit(2)),
        })),
      ),
      ...HISTORY.map((t) => ({
        kind: "history",
        title: t[0],
        sub: HOST[t[1]],
        icon: fav(t),
        verb: "Open",
        run: () => showPage(pid(t), { load: true }),
        split: () => (showPage(pid(t)), setSplit(2)),
      })),
      ...SPACES.map((sp, i) => ({
        kind: "space",
        title: sp.name,
        icon: sym(sp.glyph, state.looks[i]),
        keys: ["⌃", i + 1],
        verb: "Switch to Space",
        run: () => setSpace(i),
      })),
      act("Toggle Sidebar", "i-sidebar", ["⌘", "S"], "hide show collapse", () =>
        setSidebar(S.sidebar !== "pinned"),
      ),
      act(
        S.split > 1 ? "Unsplit" : "Split View",
        "i-split",
        ["⌥", "⌘", "V"],
        "tile side",
        () => setSplit(S.split > 1 ? 1 : 2),
      ),
      act(
        "Copy Page Link",
        "i-link",
        ["⇧", "⌘", "C"],
        "url share",
        ctl.copyLink,
      ),
      act(
        "Keyboard Shortcuts",
        "i-command",
        [],
        "keys",
        () => openPeek("shortcuts"),
        "Peek",
        "On this site",
      ),
    ];
    // the model note says what Artemis would do: open the address, send a bang to its site, or search
    const literal = (v) => {
      const note = /^!\w/.test(v)
        ? "b"
        : /^[\w-]+(\.[\w-]+)+(\/\S*)?$/.test(v)
          ? "u"
          : "s";
      return {
        kind: "literal",
        title: v,
        icon: sym("i-search"),
        verb: note === "u" ? "Open" : "Search",
        run: () => showPage("model-note", { load: true, query: v, note }),
      };
    };
    cmd = createCommandBar(el, {
      index,
      literal,
      idPrefix: "rc",
      onRun: (item, split) => emit("cmd", { run: item, split }),
      onClose: () => emit("cmd", { open: false }),
    });
    new MutationObserver(() => (win.dataset.cmd = el.dataset.state)).observe(
      el,
      { attributeFilter: ["data-state"] },
    );
  }

  subscribe((st, { ms = 350 } = {}) => {
    for (const p of $$(".panel")) p.dataset.accent = st.looks[p.dataset.space];
    if (win.dataset.accent === look()) return;
    repaint(mq.reduce.matches ? Math.min(ms, 200) : ms, EASE);
  });
  for (const p of $$(".panel")) p.dataset.accent = state.looks[p.dataset.space];
  repaint(0);
  if (opts.space) setSpace(opts.space, { via: "instant" });
  if (opts.owner !== false) registerReplica(rig, look);
  mounted.set(rig, ctl);
  return ctl;
}
