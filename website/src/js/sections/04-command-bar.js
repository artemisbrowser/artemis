import { params, mq, say, registerKeys } from "../core.js";
import { mountWindow } from "../window.js";
import { SPACES } from "../data.js";

const rig = document.querySelector('[data-rig="cmd"]');
const $ = (s) => rig.querySelector(s);
const win = mountWindow(rig, { cmd: true });
const input = $(".cmd input");
const take = $(".take");
const btn = document.querySelector('[data-act="tour"]');
const chs = [...document.querySelectorAll(".cmd-ch")];
const authored = new Set(rig.querySelectorAll(".row"));
const frame = params.get("cmd");
const still = !!frame || mq.reduce.matches || params.has("nosettle");
// one beat per chapter: Search, then the ⌘1–⌘4 scopes; Q[k] is typed with scope k, END[k] is what its ↵ did
const Q = ["betelgeuse", "sow", "seed", "split", "work"];
const END = [
  (via) => win.showPage("model-note", { load: !via, query: Q[0], note: "s" }),
  (via) => win.setSpace(2, { via }),
  (via) => win.showPage("Seed potatoes, when to chit", { load: !via }),
  () => win.setSplit(2),
  (via) => (win.setSpace(1, { via }), unsplit()),
];

let token = 0; // bumped by the hand-over, Replay and the chapters, which end the running script
let started = still;
let paused = false;
let own = false; // the island is at least 35% visible
let driving = false;
let want = -1; // the scripted bar: -1 closed, else open in that scope
let prog = null;
let wake = null; // the sleep parked while the pass can't be seen

const label = (t) => (btn.textContent = t);
const ready = () => !paused && own && !document.hidden && !mq.phone.matches;
const sync = () => {
  prog?.[ready() ? "play" : "pause"]();
  if (!ready() || !wake) return;
  const w = wake;
  wake = null;
  w();
};
const bar = (s, value = input.value) => {
  want = s;
  if (s < 0) return win.closeCommandBar();
  win.openCommandBar({ value, focus: false, scope: s });
};

// Time only passes while the pass can be seen and is not paused; sync() wakes a parked sleep.
// A sleep from an ended script never resolves.
const sleep = (ms) =>
  new Promise((ok) => {
    const t = token;
    let last = performance.now();
    const tick = () => {
      if (t !== token) return;
      if (!ready())
        return void (wake = () => ((last = performance.now()), tick()));
      const now = performance.now();
      ms -= now - last;
      last = now;
      ms > 0 ? setTimeout(tick, Math.min(ms, 60)) : ok();
    };
    tick();
  });

// Chapters before k are full and k fills over its beat; k past the last marks the tour played.
function chapter(k) {
  prog = null;
  chs.forEach((c, j) => {
    const i = c.lastElementChild;
    for (const a of i.getAnimations()) a.cancel();
    i.style.scale = j < k || (j === k && still) ? "1" : "";
    if (j !== k) return c.removeAttribute("aria-current");
    c.setAttribute("aria-current", "step");
    // the loop's sleeps plus its typing, in ms
    if (!still)
      prog = i.animate(
        { scale: ["0 1", "1 1"] },
        { duration: 3300 + (k && 650) + 62.5 * Q[k].length, fill: "forwards" },
      );
  });
  sync();
}

async function play(k = 0) {
  if (still) {
    label("Try it");
    chapter(k);
    if (!mq.phone.matches) bar(k, Q[k]);
    return;
  }
  label(paused ? "Play" : "Pause");
  for (; k < Q.length; k++) {
    chapter(k);
    await sleep(300);
    win.hud(["⌘", "T"]);
    await sleep(150);
    bar(0, "");
    if (k) {
      await sleep(500);
      win.hud(["⌘", k]);
      await sleep(150);
      bar(k, "");
    }
    await sleep(400);
    while (input.value !== Q[k])
      await win.typeQuery(Q[k].slice(input.value.length), { sleep });
    await sleep(900);
    win.hud(["↵"]);
    bar(-1);
    await sleep(140);
    END[k]();
    await sleep(1300);
  }
  chapter(k);
  label("Replay");
}

function drive() {
  const open = $(".cmd").dataset.state !== "closed";
  if (!driving) {
    driving = true;
    want = -1;
    token++;
    prog?.pause();
    prog = null;
    for (const c of chs) c.removeAttribute("aria-current");
    label("Replay");
    if (!mq.reduce.matches) win.rim();
    say("You’re driving. Esc steps back, then closes the bar.");
  }
  take.hidden = true;
  win.openCommandBar({ value: open ? input.value : "", selectAll: open });
}

// Split View pairs the page with the one shown before it: a fresh Personal holds Sourdough behind Orion.
function fresh() {
  win.showPage("slowloaf-sourdough");
  win.showPage(SPACES[0].page);
}

// fn's restyle of el lands at once; the flush commits it before el's transitions come back
function snap(el, fn) {
  el.style.transition = "none";
  fn();
  el.offsetWidth;
  el.style.transition = "";
}

// A page opened while split replaces the split at once.
function unsplit() {
  snap($(".panes"), () => win.setSplit(1));
}

// The window as beat k finds it: fresh, then every earlier beat's ↵ at once.
function reset(k) {
  token++;
  started = true;
  driving = paused = false;
  snap($(".cmd"), () => bar(-1));
  input.value = "";
  take.hidden = false;
  win.instant(() => {
    unsplit();
    win.setSidebar(true, { instant: true });
    for (const r of rig.querySelectorAll(".row")) authored.has(r) || r.remove();
    for (const i of [2, 1, 0]) {
      win.setSpace(i, { via: "instant" });
      win.showPage(SPACES[i].page);
    }
    fresh();
    for (const f of END.slice(0, k)) f("instant");
  });
  show({});
}

// The tab the bar last opened, shown under the bar on phones.
function show({ kind, sub = $(".dom").textContent }) {
  const row = $(`.panel[data-space="${win.state.space}"] .lit`);
  const tab = $(".cmd-tab");
  tab.firstElementChild.className = row.firstElementChild.className;
  tab.querySelector("b").textContent = row.textContent.trim();
  tab.querySelector("span").textContent = kind === "literal" ? "" : sub;
}

const tell = (text) => driving && say(text);
win.on("space", (i) => tell(`Switched to ${SPACES[i].name}.`));
win.on("split", (n) =>
  tell(n > 1 ? `Split view, ${n} panes.` : "Split view closed."),
);
win.on("sidebar", (open) => tell(open ? "Sidebar shown" : "Sidebar hidden"));
win.on("cmd", ({ run, split }) => {
  if (run) {
    if (run.kind === "action" || run.kind === "math") return;
    if (!split) unsplit();
    return show(run);
  }
  if (!driving) return want < 0 || bar(want); // a click elsewhere closed the scripted bar
  input.value = "";
  take.hidden = false;
  if (document.activeElement === document.body)
    take.focus({ preventScroll: true });
});

input.addEventListener("focus", () => driving || drive());
take.addEventListener("click", drive);
btn.addEventListener("click", () => {
  const t = btn.textContent;
  if (t === "Try it") return drive();
  if (t === "Replay") return (reset(0), play());
  paused = t === "Pause";
  label(paused ? "Play" : "Pause");
  sync();
});
chs.forEach((c, k) => c.addEventListener("click", () => (reset(k), play(k))));
registerKeys(() => own && (drive(), true));
document.addEventListener("visibilitychange", sync);
new IntersectionObserver(
  ([e]) => {
    own = e.intersectionRatio >= 0.35;
    if (e.intersectionRatio >= 0.5 && !started && !mq.phone.matches) {
      started = true;
      driving || sleep(900).then(() => play());
    }
    sync();
  },
  { threshold: [0, 0.35, 0.5] },
).observe(rig);

fresh();
if (frame === "drive") {
  drive();
  win.openCommandBar({ value: "s" });
} else if (frame === "done") {
  reset(5);
  chapter(5);
  label("Replay");
} else if (still) {
  const k = +(frame === "typed");
  if (k) reset(k);
  play(k);
}
