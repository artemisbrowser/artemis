import { params, mq, say } from "../core.js";
import { mountWindow } from "../window.js";

const win = mountWindow(document.querySelector('[data-rig="split"]'));
const radios = document.getElementsByName("split-n");
const lead = document.querySelector(".split-readout b");
const tail = lead.nextSibling;
const pick = tail.textContent;
const STEP = { ArrowLeft: -1, ArrowUp: -1, ArrowRight: 1, ArrowDown: 1 };

function tile(n, announce) {
  radios[n - 1].checked = true;
  lead.textContent = radios[n - 1].ariaLabel + ".";
  tail.textContent =
    n > 1 ? ` ${mq.coarse.matches ? "Tap" : "Click"} one to focus it.` : pick;
  // unsplitting keeps the url pill on the focused pane's host, so pane 0 takes focus first
  if (n === 1) win.focusPane(0);
  win.setSplit(n);
  win.rig.tabIndex = n > 1 ? 0 : -1;
  if (announce) say(n > 1 ? `Split view, ${n} panes.` : lead.textContent);
}
document.querySelector(".split-seg").onchange = (e) =>
  tile(+e.target.value, true);

// .win is inert, so a click lands on the rig and is matched to a pane by position
win.rig.onclick = ({ clientX: x, clientY: y }) => {
  const k = [...win.win.querySelectorAll(".pane")].findIndex((p) => {
    const r = p.getBoundingClientRect();
    return x > r.left && x < r.right && y > r.top && y < r.bottom;
  });
  if (k < 0) return;
  win.focusPane(k);
  // WebKit does not focus the rig on a click
  if (win.state.split > 1) win.rig.focus({ preventScroll: true });
};
win.rig.onkeydown = (e) => {
  const { split: n, focus } = win.state;
  if (!STEP[e.key] || n < 2 || e.metaKey || e.ctrlKey || e.altKey) return;
  e.preventDefault();
  const k = (focus + STEP[e.key] + n) % n;
  win.focusPane(k);
  say(`Pane ${k + 1} focused.`);
};

const n = +params.get("split");
if (n > 1 && n < 5) win.instant(() => tile(n));
