// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

// A procedural laptop: lengths in cm, +y up, the hinge at the back (-z), the viewer in front (+z).
import * as THREE from "three";
import { RectAreaLightUniformsLib } from "three/addons/lights/RectAreaLightUniformsLib.js";
import { RoundedBoxGeometry } from "three/addons/geometries/RoundedBoxGeometry.js";

const W = 31.26, D = 22.12, BASE_H = 0.95, LID_D = 21.5, LID_H = 0.5;
const SCREEN_W = 30.2, SCREEN_H = SCREEN_W * (1033 / 1589), SCREEN_TOP = 0.45;
const DEG = Math.PI / 180;

const smooth = (x) => { x = Math.min(1, Math.max(0, x)); return x * x * (3 - 2 * x); };
const lerp = (a, b, p) => a + (b - a) * p;

// a rounded rectangle in the xz plane, extruded upwards from y 0 to h
function slab(w, d, h, r, bevel) {
  const s = new THREE.Shape(), x = w / 2 - bevel, y = d / 2 - bevel, rr = r - bevel;
  s.moveTo(-x + rr, -y);
  s.lineTo(x - rr, -y); s.quadraticCurveTo(x, -y, x, -y + rr);
  s.lineTo(x, y - rr); s.quadraticCurveTo(x, y, x - rr, y);
  s.lineTo(-x + rr, y); s.quadraticCurveTo(-x, y, -x, y - rr);
  s.lineTo(-x, -y + rr); s.quadraticCurveTo(-x, -y, -x + rr, -y);
  const g = new THREE.ExtrudeGeometry(s, { depth: h - 2 * bevel, bevelEnabled: true, bevelThickness: bevel, bevelSize: bevel, bevelSegments: 4, curveSegments: 12 });
  g.rotateX(-Math.PI / 2);
  g.translate(0, bevel, 0);
  return g;
}

function grille() {
  const c = Object.assign(document.createElement("canvas"), { width: 64, height: 1024 });
  const x = c.getContext("2d");
  x.fillStyle = "#000"; x.fillRect(0, 0, 64, 1024);
  x.fillStyle = "#fff";
  for (let row = 0; row < 128; row++) for (let col = 0; col < 8; col++) {
    x.beginPath(); x.arc(4 + col * 8 + (row % 2) * 4 - 2, 4 + row * 8, 1.6, 0, 7); x.fill();
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

function keyboard(material) {
  const KW = 27.0, U = 1.62, GAP = 0.22, FN = 0.95;
  const rows = [
    [FN, Array(14).fill(1)],
    [U, [...Array(13).fill(1), 1.5]],
    [U, [1.5, ...Array(13).fill(1)]],
    [U, [1.8, ...Array(11).fill(1), 1.8]],
    [U, [2.3, ...Array(10).fill(1), 2.3]],
    [U, [1, 1, 1, 1.25, 5.2, 1.25, 1, 1, 1, 1]],
  ];
  // one instanced mesh per key size, so each key keeps an unscaled rounded bevel
  const sizes = new Map();
  let z = -D / 2 + 1.35;
  for (const [depth, widths] of rows) {
    const unit = (KW - GAP * (widths.length - 1)) / widths.reduce((a, b) => a + b);
    let x = -KW / 2;
    for (const w of widths) {
      const kw = w * unit, id = `${kw.toFixed(3)} ${depth}`;
      if (!sizes.has(id)) sizes.set(id, { kw, depth, at: [] });
      sizes.get(id).at.push(new THREE.Vector3(x + kw / 2, BASE_H + 0.075, z + depth / 2));
      x += kw + GAP;
    }
    z += depth + GAP;
  }
  const group = new THREE.Group(), m = new THREE.Matrix4();
  for (const { kw, depth, at } of sizes.values()) {
    const mesh = new THREE.InstancedMesh(new RoundedBoxGeometry(kw, 0.14, depth, 3, 0.06), material, at.length);
    at.forEach((v, i) => mesh.setMatrixAt(i, m.makeTranslation(v)));
    group.add(mesh);
  }
  return group;
}

// fine streaks along x, as a roughness map for a brushed finish
function brushed() {
  const c = Object.assign(document.createElement("canvas"), { width: 512, height: 512 });
  const x = c.getContext("2d");
  let seed = 7;
  const rand = () => (seed = (seed * 16807) % 2147483647) / 2147483647;
  x.fillStyle = "#d8d8d8"; x.fillRect(0, 0, 512, 512);
  for (let i = 0; i < 2600; i++) {
    const v = 170 + Math.floor(rand() * 85);
    x.fillStyle = `rgb(${v},${v},${v})`;
    x.fillRect(rand() * 512, rand() * 512, 40 + rand() * 200, 1);
  }
  const t = new THREE.CanvasTexture(c);
  t.wrapS = t.wrapT = THREE.RepeatWrapping;
  t.repeat.set(1 / 12, 1 / 12);
  return t;
}

// a black studio with softbox strips: crisp highlights along the edges, dark faces
function studio() {
  const s = new THREE.Scene(), box = (w, h, v, pos, look) => {
    const m = new THREE.Mesh(new THREE.PlaneGeometry(w, h), new THREE.MeshBasicMaterial({ color: new THREE.Color(v, v, v), side: THREE.DoubleSide }));
    m.position.set(...pos); m.lookAt(...look); s.add(m);
  };
  s.background = new THREE.Color(0x020202);
  box(70, 30, 2.5, [0, 50, 10], [0, 0, 0]);
  box(6, 50, 5, [-55, 18, 15], [0, 5, 0]);
  box(6, 50, 4, [55, 18, -10], [0, 5, 0]);
  box(70, 4, 3, [0, 10, -60], [0, 5, 0]);
  box(120, 40, 1.4, [0, 15, 70], [0, 5, 0]);
  box(80, 6, 4, [0, 45, 55], [0, 0, 0]);
  return s;
}

// camera paths over scroll progress p, given the lid's openness o; t drifts the orbit
const SHOTS = {
  orbit: (p, o, t) => ({ az: lerp(0.5, -0.28, smooth(p)) + 0.05 * Math.sin(t * 0.25), el: lerp(0.07, 0.3, smooth(p)), dist: lerp(62, 80, smooth(p)), y: lerp(1.2, 8.5, o), z: lerp(1, -2, o) }),
  hero: (p, o) => ({ az: 0, el: lerp(0.42, 0.06, smooth(p)), dist: lerp(95, 58, smooth(p)), y: lerp(0, 10, o), z: lerp(4, -1, o) }),
};

export async function mount(host, { screen, capture, shot = "orbit" }) {
  RectAreaLightUniformsLib.init();
  const renderer = new THREE.WebGLRenderer({ antialias: true, preserveDrawingBuffer: capture });
  renderer.setPixelRatio(Math.min(devicePixelRatio, 2));
  renderer.toneMapping = THREE.NeutralToneMapping;
  renderer.toneMappingExposure = 1;
  host.append(renderer.domElement);

  const scene = new THREE.Scene();
  scene.background = new THREE.Color(0x000000);
  const pmrem = new THREE.PMREMGenerator(renderer);
  scene.environment = pmrem.fromScene(studio(), 0.02).texture;
  scene.environmentIntensity = 1.5;

  const camera = new THREE.PerspectiveCamera(26, 1, 1, 400);

  const tex = await new THREE.TextureLoader().loadAsync(`screen-${screen}.jpg`);
  tex.colorSpace = THREE.SRGBColorSpace;
  tex.anisotropy = renderer.capabilities.getMaxAnisotropy();

  const aluminium = new THREE.MeshPhysicalMaterial({ color: 0x5d5e63, metalness: 1, roughness: 0.32, roughnessMap: brushed(), anisotropy: 0.7 });
  const blackGlass = new THREE.MeshStandardMaterial({ color: 0x030304, roughness: 0.35 });
  const keyMat = new THREE.MeshStandardMaterial({ color: 0x020203, roughness: 0.55 });

  const laptop = new THREE.Group();
  scene.add(laptop);

  laptop.add(new THREE.Mesh(slab(W, D, BASE_H, 1.1, 0.16), aluminium));
  const well = new THREE.Mesh(new THREE.PlaneGeometry(27.6, 10.7).rotateX(-Math.PI / 2), new THREE.MeshStandardMaterial({ color: 0x010101, roughness: 0.9 }));
  well.position.set(0, BASE_H + 0.002, -D / 2 + 1.25 + 10.7 / 2 - 0.1);
  laptop.add(well, keyboard(keyMat));

  const pad = new THREE.Mesh(slab(15.2, 9.0, 0.02, 0.6, 0.005), new THREE.MeshPhysicalMaterial({ color: 0x3a3b3e, metalness: 0.6, roughness: 0.28, clearcoat: 0.25, clearcoatRoughness: 0.2 }));
  pad.position.set(0, BASE_H, D / 2 - 0.9 - 4.5);
  laptop.add(pad);

  const dots = grille();
  for (const side of [-1, 1]) {
    const g = new THREE.Mesh(new THREE.PlaneGeometry(1.4, 10.4).rotateX(-Math.PI / 2), new THREE.MeshStandardMaterial({ color: 0x020203, roughness: 0.9, alphaMap: dots, transparent: true }));
    g.position.set(side * (27.6 / 2 + 0.95), BASE_H + 0.003, well.position.z);
    laptop.add(g);
  }

  const hinge = new THREE.Mesh(new THREE.CylinderGeometry(0.42, 0.42, 25, 32).rotateZ(Math.PI / 2), new THREE.MeshPhysicalMaterial({ color: 0x1a1a1c, metalness: 0.8, roughness: 0.45 }));
  hinge.position.set(0, BASE_H - 0.05, -D / 2 + 0.42);
  laptop.add(hinge);

  // the lid's pivot sits on the hinge; rotation.x = -angle opens it
  const lid = new THREE.Group();
  lid.position.set(0, BASE_H + 0.06, -D / 2 + 0.25);
  laptop.add(lid);
  const shell = new THREE.Mesh(slab(W, LID_D, LID_H, 1.1, 0.14), aluminium);
  shell.position.z = LID_D / 2;
  lid.add(shell);

  const bezel = new THREE.Mesh(new THREE.PlaneGeometry(W - 0.3, LID_D - 0.3).rotateX(Math.PI / 2), blackGlass);
  bezel.position.set(0, -0.001, LID_D / 2);
  const display = new THREE.Mesh(
    new THREE.PlaneGeometry(SCREEN_W, SCREEN_H).rotateX(Math.PI / 2),
    new THREE.MeshBasicMaterial({ map: tex, toneMapped: false }),
  );
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
    const m = new THREE.Mesh(new THREE.PlaneGeometry(W * 1.5, D * 1.6).rotateX(-Math.PI / 2), new THREE.MeshBasicMaterial({ map: new THREE.CanvasTexture(c), transparent: true, depthWrite: false }));
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
    lid.rotation.x = -lerp(9, 108, open) * DEG;
    glow.intensity = lerp(3.5, 1.6, open);
    const { az, el, dist, y, z } = SHOTS[shot](p, open, t);
    const target = new THREE.Vector3(0, y, z);
    camera.position.set(target.x + dist * Math.cos(el) * Math.sin(az), target.y + dist * Math.sin(el), target.z + dist * Math.cos(el) * Math.cos(az));
    camera.lookAt(target);
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
  } else {
    renderer.setAnimationLoop((ms) => render(progress(), ms / 1000));
  }
  window.ready3d = true;
}
