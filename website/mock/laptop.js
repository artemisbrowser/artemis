// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

// A procedural laptop: lengths in cm, +y up, the hinge at the back (-z), the viewer in front (+z).
import * as THREE from "three";
import { RectAreaLightUniformsLib } from "three/addons/lights/RectAreaLightUniformsLib.js";
import { RoundedBoxGeometry } from "three/addons/geometries/RoundedBoxGeometry.js";
import { HDRLoader } from "three/addons/loaders/HDRLoader.js";

// 14-inch dimensions, measured from product shots against the published 31.26 x 22.12 x 1.55
const W = 31.26, D = 22.12, BASE_H = 0.95, LID_H = 0.45, FOOT = 0.1, R_PLAN = 0.85;
const PIVOT_Z = -D / 2 + 0.45, LID_D = D - 0.45;
const SCREEN_W = 30.14, SCREEN_H = SCREEN_W * (1033 / 1589), SCREEN_TOP = 0.6;
const WELL_W = 27.9, WELL_D = 11.5, WELL_Z = -D / 2 + 1.5 + WELL_D / 2;
const DEG = Math.PI / 180;

const smooth = (x) => { x = Math.min(1, Math.max(0, x)); return x * x * (3 - 2 * x); };
const lerp = (a, b, p) => a + (b - a) * p;

// quarter arcs as [inset, y] profile points, top edge (outer to side) and bottom edge (side to under)
const topRound = (h, r, n = 6) => Array.from({ length: n + 1 }, (_, k) => { const a = (k / n) * Math.PI / 2; return [r * (1 - Math.sin(a)), h - r * (1 - Math.cos(a))]; });
const bottomRound = (r, n = 8) => Array.from({ length: n + 1 }, (_, k) => { const a = (k / n) * Math.PI / 2; return [r * (1 - Math.cos(a)), r * (1 - Math.sin(a))]; });

// a rounded-rect plan (w x d, corner r) swept down a side profile of [inset, y], capped top and bottom
function loft(w, d, r, profile, seg = 12) {
  const ring = (inset) => {
    const hw = w / 2 - r, hd = d / 2 - r, rr = r - inset, pts = [];
    for (const [cx, cz, a0] of [[hw, hd, 0], [-hw, hd, 90], [-hw, -hd, 180], [hw, -hd, 270]])
      for (let k = 0; k <= seg; k++) { const a = (a0 + (k / seg) * 90) * DEG; pts.push([cx + rr * Math.cos(a), cz + rr * Math.sin(a)]); }
    return pts;
  };
  const pos = [], idx = [], n = 4 * (seg + 1);
  for (const [inset, y] of profile) for (const [x, z] of ring(inset)) pos.push(x, y, z);
  for (let j = 0; j < profile.length - 1; j++) for (let i = 0; i < n; i++) {
    const a = j * n + i, b = j * n + ((i + 1) % n), c = a + n, e = b + n;
    idx.push(a, b, c, b, e, c);
  }
  for (const [which, up] of [[0, true], [profile.length - 1, false]]) {
    const [inset, y] = profile[which], o = pos.length / 3;
    pos.push(0, y, 0);
    for (const [x, z] of ring(inset)) pos.push(x, y, z);
    for (let i = 0; i < n; i++) { const p = o + 1 + i, q = o + 1 + ((i + 1) % n); idx.push(...(up ? [o, q, p] : [o, p, q])); }
  }
  const g = new THREE.BufferGeometry();
  g.setAttribute("position", new THREE.Float32BufferAttribute(pos, 3));
  g.setIndex(idx);
  g.computeVertexNormals();
  return g;
}

// a flat rounded rect facing +z, with uvs spanning it; rTop and rBottom round each pair of corners
function card(w, h, rTop, rBottom = rTop) {
  const s = new THREE.Shape(), x = w / 2, y = h / 2;
  s.moveTo(-x + rBottom, -y);
  s.lineTo(x - rBottom, -y); s.absarc(x - rBottom, -y + rBottom, rBottom, -Math.PI / 2, 0);
  s.lineTo(x, y - rTop); s.absarc(x - rTop, y - rTop, rTop, 0, Math.PI / 2);
  s.lineTo(-x + rTop, y); s.absarc(-x + rTop, y - rTop, rTop, Math.PI / 2, Math.PI);
  s.lineTo(-x, -y + rBottom); s.absarc(-x + rBottom, -y + rBottom, rBottom, Math.PI, Math.PI * 1.5);
  const g = new THREE.ShapeGeometry(s, 16), p = g.attributes.position, uv = g.attributes.uv;
  for (let i = 0; i < p.count; i++) uv.setXY(i, p.getX(i) / w + 0.5, p.getY(i) / h + 0.5);
  return g;
}
const flat = (g) => g.rotateX(-Math.PI / 2);

function grille() {
  const c = Object.assign(document.createElement("canvas"), { width: 64, height: 1024 });
  const x = c.getContext("2d");
  x.fillStyle = "#000"; x.fillRect(0, 0, 64, 1024);
  x.fillStyle = "#fff";
  for (let row = 0; row < 128; row++) for (let col = 0; col < 8; col++) {
    x.beginPath(); x.arc(4 + col * 8 + (row % 2) * 4 - 2, 4 + row * 8, 1.7, 0, 7); x.fill();
  }
  return new THREE.CanvasTexture(c);
}

function meanColour(img) {
  const c = Object.assign(document.createElement("canvas"), { width: 16, height: 16 });
  const x = c.getContext("2d", { willReadFrequently: true });
  x.drawImage(img, 0, 0, 16, 16);
  const d = x.getImageData(0, 0, 16, 16).data;
  let r = 0, g = 0, b = 0;
  for (let i = 0; i < d.length; i += 4) { r += d[i]; g += d[i + 1]; b += d[i + 2]; }
  const n = d.length / 4;
  return new THREE.Color().setRGB(r / n / 255, g / n / 255, b / n / 255, THREE.SRGBColorSpace);
}

// key widths in units; every row spans 14.5. "arrows" is the inverted T in the last three units
const ROWS = [
  [[1.5, "esc"], ..."F1 F2 F3 F4 F5 F6 F7 F8 F9 F10 F11 F12".split(" ").map((l) => [1, l]), [1, "touchid"]],
  [..."~` !1 @2 #3 $4 %5 ^6 &7 *8 (9 )0 _- +=".split(" ").map((l) => [1, l]), [1.5, "delete"]],
  [[1.5, "tab"], ..."QWERTYUIOP".split("").map((l) => [1, l]), [1, "{["], [1, "}]"], [1, "|\\"]],
  [[1.75, "caps lock"], ..."ASDFGHJKL".split("").map((l) => [1, l]), [1, ":;"], [1, "\"'"], [1.75, "return"]],
  [[2.25, "shift"], ..."ZXCVBNM".split("").map((l) => [1, l]), [1, "<,"], [1, ">."], [1, "?/"], [2.25, "shift"]],
  [[1, "fn"], [1, "control"], [1, "option"], [1.25, "command"], [5, ""], [1.25, "command"], [1, "option"], [3, "arrows"]],
];
const KEY_W = 27.5, KEY_D = 1.6, KEY_GAP = 0.27, KEY_PITCH = 1.85, KEYS_D = 5 * KEY_PITCH + KEY_D;

// key caps as instanced bevelled boxes, plus one transparent plane carrying every legend
function keyboard(material) {
  const caps = new Map(), boxes = [];
  const add = (x, z, w, d, label) => boxes.push({ x, z, w, d, label });
  ROWS.forEach((row, r) => {
    const z = -KEYS_D / 2 + r * KEY_PITCH + KEY_D / 2;
    const unit = (KEY_W - KEY_GAP * (row.length - 1)) / row.reduce((a, [w]) => a + w, 0);
    let x = -KEY_W / 2;
    for (const [w, label] of row) {
      if (label === "arrows") {
        const kw = (3 * unit - 2 * KEY_GAP) / 3, half = (KEY_D - 0.1) / 2;
        add(x + kw / 2, z + KEY_D / 4, kw, half, "◀");
        add(x + kw * 1.5 + KEY_GAP, z - KEY_D / 4, kw, half, "▲");
        add(x + kw * 1.5 + KEY_GAP, z + KEY_D / 4, kw, half, "▼");
        add(x + kw * 2.5 + KEY_GAP * 2, z + KEY_D / 4, kw, half, "▶");
      } else add(x + (w * unit) / 2, z, w * unit, KEY_D, label);
      x += w * unit + KEY_GAP;
    }
  });
  const group = new THREE.Group(), m = new THREE.Matrix4();
  for (const b of boxes) {
    const id = `${b.w.toFixed(3)} ${b.d.toFixed(3)}`;
    if (!caps.has(id)) caps.set(id, { ...b, at: [] });
    caps.get(id).at.push(b);
  }
  for (const { w, d, at } of caps.values()) {
    const mesh = new THREE.InstancedMesh(new RoundedBoxGeometry(w, 0.12, d, 3, 0.05), material, at.length);
    at.forEach((b, i) => mesh.setMatrixAt(i, m.makeTranslation(b.x, 0, b.z)));
    group.add(mesh);
  }

  const S = 80, c = Object.assign(document.createElement("canvas"), { width: KEY_W * S, height: KEYS_D * S });
  const g = c.getContext("2d");
  g.fillStyle = g.strokeStyle = "#d9d9de";
  g.textAlign = "center"; g.textBaseline = "middle";
  const font = (cm) => (g.font = `500 ${cm * S}px -apple-system, "Helvetica Neue", Arial, sans-serif`);
  for (const { x, z, w, d, label } of boxes) {
    const cx = (x + KEY_W / 2) * S, cy = (z + KEYS_D / 2) * S, hw = (w / 2) * S, hd = (d / 2) * S;
    if (label === "touchid") { g.lineWidth = 0.04 * S; g.beginPath(); g.arc(cx, cy, 0.5 * S, 0, 7); g.stroke(); }
    else if (label.length === 1) { font(0.36); g.fillText(label, cx, cy); }
    else if (label.length === 2 && !/^F\d$/.test(label)) { font(0.27); g.fillText(label[0], cx, cy - hd * 0.4); g.fillText(label[1], cx, cy + hd * 0.4); }
    else { font(label.length > 3 ? 0.2 : 0.24); g.fillText(label, cx, cy + (/^F/.test(label) ? hd * 0.45 : hd * 0.5)); if (label === "fn") g.fillText("◎", cx - hw * 0.45, cy + hd * 0.5); }
  }
  const tex = new THREE.CanvasTexture(c);
  tex.colorSpace = THREE.SRGBColorSpace;
  tex.anisotropy = 8;
  const legends = new THREE.Mesh(flat(new THREE.PlaneGeometry(KEY_W, KEYS_D)), new THREE.MeshBasicMaterial({ map: tex, transparent: true, opacity: 0.85, depthWrite: false }));
  legends.position.y = 0.061;
  group.add(legends);
  return group;
}

// anodised finishes; metalness 1 so colour is the specular tint, light scales the studio
const FINISHES = {
  black: { alloy: 0x2e2f33, roughness: 0.42, light: 0.45 },
  silver: { alloy: 0xc6c7ca, roughness: 0.36, light: 0.7 },
};

// camera paths over scroll progress p, given the lid's openness o; t drifts the orbit
const SHOTS = {
  orbit: (p, o, t) => ({ az: lerp(0.5, -0.28, smooth(p)) + 0.05 * Math.sin(t * 0.25), el: lerp(0.07, 0.3, smooth(p)), dist: lerp(62, 80, smooth(p)), y: lerp(1.2, 8.5, o), z: lerp(1, -2, o) }),
  hero: (p, o) => ({ az: 0, el: lerp(0.42, 0.06, smooth(p)), dist: lerp(95, 58, smooth(p)), y: lerp(0, 10, o), z: lerp(4, -1, o) }),
};

export async function mount(host, { screen, capture, shot = "orbit", finish = "black" }) {
  RectAreaLightUniformsLib.init();
  const renderer = new THREE.WebGLRenderer({ antialias: true, preserveDrawingBuffer: capture });
  renderer.setPixelRatio(Math.min(devicePixelRatio, 2));
  renderer.toneMapping = THREE.NeutralToneMapping;
  renderer.toneMappingExposure = 1;
  host.append(renderer.domElement);

  const scene = new THREE.Scene();
  scene.background = new THREE.Color(0x000000);
  const pmrem = new THREE.PMREMGenerator(renderer);
  scene.environment = pmrem.fromEquirectangular(await new HDRLoader().loadAsync("env/studio_small_09_1k.hdr")).texture;
  scene.environmentIntensity = FINISHES[finish].light;

  const camera = new THREE.PerspectiveCamera(26, 1, 1, 400);

  const tex = await new THREE.TextureLoader().loadAsync(`screen-${screen}.jpg`);
  tex.colorSpace = THREE.SRGBColorSpace;
  tex.anisotropy = renderer.capabilities.getMaxAnisotropy();

  const { alloy, roughness } = FINISHES[finish];
  const aluminium = new THREE.MeshPhysicalMaterial({ color: alloy, metalness: 1, roughness });
  const recess = new THREE.MeshStandardMaterial({ color: new THREE.Color(alloy).multiplyScalar(0.45), metalness: 1, roughness: roughness + 0.1 });
  const ink = (color, rough) => new THREE.MeshStandardMaterial({ color, roughness: rough });
  const blackGlass = new THREE.MeshPhysicalMaterial({ color: 0x050506, roughness: 0.12, clearcoat: 0.6 });

  const laptop = new THREE.Group();
  laptop.position.y = FOOT;
  scene.add(laptop);

  const base = new THREE.Mesh(loft(W, D, R_PLAN, [...topRound(BASE_H, 0.1), ...bottomRound(0.4)]), aluminium);
  const well = new THREE.Mesh(flat(card(WELL_W, WELL_D, 0.35)), ink(0x050506, 0.75));
  well.position.set(0, BASE_H + 0.002, WELL_Z);
  const keys = keyboard(ink(0x0b0b0c, 0.6));
  keys.position.set(0, BASE_H + 0.0, WELL_Z);
  laptop.add(base, well, keys);

  const dots = grille();
  for (const side of [-1, 1]) {
    const g = new THREE.Mesh(flat(new THREE.PlaneGeometry(1.3, WELL_D - 0.6)), new THREE.MeshStandardMaterial({ color: 0x050506, roughness: 0.9, alphaMap: dots, transparent: true }));
    g.position.set(side * (WELL_W / 2 + (W - WELL_W) / 4), BASE_H + 0.003, WELL_Z);
    laptop.add(g);
  }

  const padZ = -D / 2 + 17.45;
  const padEdge = new THREE.Mesh(flat(card(13.06, 8.06, 0.58)), recess);
  const pad = new THREE.Mesh(flat(card(13.0, 8.0, 0.55)), new THREE.MeshPhysicalMaterial({ color: alloy, metalness: 0.85, roughness: roughness - 0.08 }));
  padEdge.position.set(0, BASE_H + 0.002, padZ);
  pad.position.set(0, BASE_H + 0.004, padZ);
  laptop.add(padEdge, pad);

  // the thumb scoop on the front edge and the side ports, as recessed decals on the flat faces
  const scoop = new THREE.Mesh(card(5.5, 0.3, 0, 0.15), recess);
  scoop.position.set(0, BASE_H - 0.15, D / 2 + 0.002);
  laptop.add(scoop);
  const portMat = ink(0x060607, 0.7);
  const PORTS = [
    [-1, 2.27, 1.02, 0.3, 0.15], [-1, 4.25, 0.82, 0.26, 0.13], [-1, 5.75, 0.82, 0.26, 0.13], [-1, 7.27, 0.36, 0.36, 0.18],
    [1, 2.25, 1.55, 0.42, 0.06], [1, 4.45, 0.82, 0.26, 0.13], [1, 6.05, 2.7, 0.16, 0.08],
  ];
  for (const [side, from, w, h, r] of PORTS) {
    const m = new THREE.Mesh(card(w, h, r).rotateY(side * Math.PI / 2), portMat);
    m.position.set(side * (W / 2 + 0.002), 0.6, -D / 2 + from + w / 2);
    laptop.add(m);
  }
  const feet = ink(0x111112, 0.85);
  for (const x of [-1, 1]) for (const z of [-1, 1]) {
    const f = new THREE.Mesh(new THREE.CylinderGeometry(0.9, 0.9, FOOT, 32), feet);
    f.position.set(x * (W / 2 - 2.6), -FOOT / 2, z * (D / 2 - 2.0));
    laptop.add(f);
  }

  const hinge = new THREE.Mesh(new THREE.CylinderGeometry(0.38, 0.38, WELL_W, 32).rotateZ(Math.PI / 2), new THREE.MeshPhysicalMaterial({ color: 0x141416, metalness: 0.7, roughness: 0.45 }));
  hinge.position.set(0, BASE_H - 0.04, PIVOT_Z - 0.05);
  laptop.add(hinge);

  // the lid's pivot sits on the hinge; rotation.x = -angle opens it. Lid y 0 is the screen face
  const lid = new THREE.Group();
  lid.position.set(0, BASE_H + 0.03, PIVOT_Z);
  laptop.add(lid);
  const shell = new THREE.Mesh(loft(W, LID_D, R_PLAN, [...topRound(LID_H, 0.2), ...bottomRound(0.05, 3)]), aluminium);
  shell.position.z = LID_D / 2;
  lid.add(shell);

  const bezel = new THREE.Mesh(card(W - 0.36, LID_D - 0.36, R_PLAN - 0.18).rotateX(Math.PI / 2), blackGlass);
  bezel.position.set(0, -0.001, LID_D / 2);
  const display = new THREE.Mesh(card(SCREEN_W, SCREEN_H, 0.55, 0.05).rotateX(Math.PI / 2), new THREE.MeshBasicMaterial({ map: tex, toneMapped: false }));
  display.position.set(0, -0.002, LID_D - SCREEN_TOP - SCREEN_H / 2);
  lid.add(bezel, display);

  // the screen as a light, facing out of the display, so it spills onto the keys and deck
  const glow = new THREE.RectAreaLight(meanColour(tex.image), 3, SCREEN_W, SCREEN_H);
  glow.position.copy(display.position).add(new THREE.Vector3(0, -0.05, 0));
  glow.rotation.x = -Math.PI / 2;
  lid.add(glow);

  const shadow = (() => {
    const c = Object.assign(document.createElement("canvas"), { width: 256, height: 256 });
    const x = c.getContext("2d"), r = x.createRadialGradient(128, 128, 20, 128, 128, 128);
    r.addColorStop(0, "rgba(0,0,0,0.85)"); r.addColorStop(1, "rgba(0,0,0,0)");
    x.fillStyle = r; x.fillRect(0, 0, 256, 256);
    const m = new THREE.Mesh(flat(new THREE.PlaneGeometry(W * 1.5, D * 1.6)), new THREE.MeshBasicMaterial({ map: new THREE.CanvasTexture(c), transparent: true, depthWrite: false }));
    m.position.y = -0.01;
    return m;
  })();
  scene.add(shadow);

  const key = new THREE.DirectionalLight(0xffffff, 0.45);
  key.position.set(-30, 60, 40);
  scene.add(key);

  // p: scroll progress 0..1, t: seconds; the same (p, t) always gives the same frame
  function render(p, t) {
    const open = shot === "hero" ? smooth(p / 0.75) : smooth((p - 0.15) / 0.7);
    draw({ lid: lerp(9, 108, open), glow: lerp(2.2, 1.4, open), ...SHOTS[shot](p, open, t) });
  }

  // lid in degrees, camera orbit (az, el in radians, dist in cm) around a target at (0, y, z)
  function draw({ lid: angle, glow: g, az, el, dist, y, z, fov = 26 }) {
    lid.rotation.x = -angle * DEG;
    glow.intensity = g;
    camera.fov = fov;
    camera.updateProjectionMatrix();
    camera.position.set(dist * Math.cos(el) * Math.sin(az), y + dist * Math.sin(el), z + dist * Math.cos(el) * Math.cos(az));
    camera.lookAt(0, y, z);
    renderer.render(scene, camera);
  }

  function resize() {
    const { width, height } = host.getBoundingClientRect();
    renderer.setSize(width, height, false);
    camera.aspect = width / height;
    camera.updateProjectionMatrix();
  }
  new ResizeObserver(resize).observe(host);
  resize();

  const progress = () => {
    const s = host.parentElement, r = s.getBoundingClientRect();
    return Math.min(1, Math.max(0, -r.top / (r.height - innerHeight)));
  };
  if (capture) {
    window.render3d = (p, t) => { resize(); render(p, t); };
    window.pose3d = (pose) => { resize(); draw(pose); };
  } else {
    renderer.setAnimationLoop((ms) => render(progress(), ms / 1000));
  }
  window.ready3d = true;
}
