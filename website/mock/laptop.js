// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

// A procedural laptop: lengths in cm, +y up, the hinge at the back (-z), the viewer in front (+z).
import * as THREE from "three";
import { RoomEnvironment } from "three/addons/environments/RoomEnvironment.js";
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
  const keys = rows.reduce((n, [, r]) => n + r.length, 0);
  const mesh = new THREE.InstancedMesh(new RoundedBoxGeometry(1, 1, 1, 2, 0.12), material, keys);
  const m = new THREE.Matrix4(), q = new THREE.Quaternion();
  let z = -D / 2 + 1.35, i = 0;
  for (const [depth, widths] of rows) {
    const unit = (KW - GAP * (widths.length - 1)) / widths.reduce((a, b) => a + b);
    let x = -KW / 2;
    for (const w of widths) {
      const kw = w * unit;
      m.compose(new THREE.Vector3(x + kw / 2, BASE_H + 0.03, z + depth / 2), q, new THREE.Vector3(kw, 0.1, depth));
      mesh.setMatrixAt(i++, m);
      x += kw + GAP;
    }
    z += depth + GAP;
  }
  return mesh;
}

export async function mount(host, { screen, capture }) {
  RectAreaLightUniformsLib.init();
  const renderer = new THREE.WebGLRenderer({ antialias: true, preserveDrawingBuffer: capture });
  renderer.setPixelRatio(Math.min(devicePixelRatio, 2));
  renderer.toneMapping = THREE.AgXToneMapping;
  renderer.toneMappingExposure = 1.1;
  host.append(renderer.domElement);

  const scene = new THREE.Scene();
  scene.background = new THREE.Color(0x000000);
  const pmrem = new THREE.PMREMGenerator(renderer);
  scene.environment = pmrem.fromScene(new RoomEnvironment(), 0.04).texture;
  scene.environmentIntensity = 0.22;

  const camera = new THREE.PerspectiveCamera(26, 1, 1, 400);

  const tex = await new THREE.TextureLoader().loadAsync(`screen-${screen}.jpg`);
  tex.colorSpace = THREE.SRGBColorSpace;
  tex.anisotropy = renderer.capabilities.getMaxAnisotropy();

  const aluminium = new THREE.MeshPhysicalMaterial({ color: 0x2a2b2e, metalness: 0.9, roughness: 0.38 });
  const blackGlass = new THREE.MeshStandardMaterial({ color: 0x030304, roughness: 0.35 });
  const keyMat = new THREE.MeshStandardMaterial({ color: 0x050506, roughness: 0.5 });

  const laptop = new THREE.Group();
  scene.add(laptop);

  laptop.add(new THREE.Mesh(slab(W, D, BASE_H, 1.1, 0.16), aluminium));
  const well = new THREE.Mesh(new THREE.PlaneGeometry(27.6, 10.7).rotateX(-Math.PI / 2), new THREE.MeshStandardMaterial({ color: 0x08080a, roughness: 0.8 }));
  well.position.set(0, BASE_H + 0.002, -D / 2 + 1.25 + 10.7 / 2 - 0.1);
  laptop.add(well, keyboard(keyMat));

  const pad = new THREE.Mesh(slab(15.2, 9.0, 0.02, 0.6, 0.005), new THREE.MeshPhysicalMaterial({ color: 0x35363a, metalness: 0.85, roughness: 0.26 }));
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
    const open = smooth((p - 0.15) / 0.7);
    lid.rotation.x = -lerp(9, 108, open) * DEG;
    glow.intensity = lerp(6, 2.5, open);
    const az = lerp(0.5, -0.28, smooth(p)) + 0.05 * Math.sin(t * 0.25);
    const el = lerp(0.07, 0.3, smooth(p));
    const dist = lerp(62, 80, smooth(p));
    const target = new THREE.Vector3(0, lerp(1.2, 8.5, open), lerp(1, -2, open));
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
