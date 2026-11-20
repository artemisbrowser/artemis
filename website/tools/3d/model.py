# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

# blender -b --factory-startup -P tools/3d/model.py -- OUT.glb
# A 14-inch laptop in Space Black, built from measurements, for render.py (--flip-uv 0).
# Units are cm, Z up, front -y; the lid is closed, only lid parts are named lid*, and it turns about HINGE.
# Material names are render.py roles; "print", "lens", "mark", "sensor" and "contact"
# are kept as exported.
# Legends need Inter Regular 4.1 (OFL-1.1, github.com/rsms/inter) at ~/.cache/artemis/fonts/Inter-Regular.ttf.
import math, os, re, sys
import xml.etree.ElementTree as ET
import bpy, bmesh
from mathutils import Matrix, Vector

OUT = sys.argv[sys.argv.index("--") + 1]
bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene

W, D, R = 31.02, 21.64, 1.11
FOOT, H, LIDH = 0.16, 1.12, 0.36
Z0, ZT = FOOT, FOOT + H
LZ = ZT + 0.02  # the lid's display face, closed
HINGE = (10.655, 0.767)  # the lid's axis (y, z): at 110 degrees its back edge sits behind the base, 0.27 off its floor


def material(name, color, rough, metal=0.0):
    m = bpy.data.materials.new(name)
    if m.node_tree is None:
        m.use_nodes = True
    b = m.node_tree.nodes["Principled BSDF"]
    b.inputs["Base Color"].default_value = (*color, 1)
    b.inputs["Roughness"].default_value = rough
    b.inputs["Metallic"].default_value = metal
    return m


M = {n: material(n, *a) for n, a in {
    "alloy": ((0.093, 0.089, 0.095), 0.545, 1.0), "well": ((0.005, 0.005, 0.006), 0.6, 0.2),
    "keycap": ((0.003, 0.004, 0.004), 0.55, 0.2), "print": ((0.8, 0.8, 0.8), 0.4),
    "pad": ((0.083, 0.08, 0.085), 0.545, 1.0), "scoop": ((0.02, 0.02, 0.022), 0.4, 1.0),
    "recess": ((0.02, 0.02, 0.022), 0.45, 1.0), "grille": ((0.003, 0.003, 0.003), 0.9),
    "port": ((0.05, 0.05, 0.05), 0.87), "foot": ((0.01, 0.01, 0.01), 0.85),
    "hinge": ((0.003, 0.004, 0.004), 0.55, 0.2), "glass": ((0.002, 0.002, 0.002), 0.04),
    "screen": ((0.0, 0.0, 0.0), 0.05), "lens": ((0.01, 0.012, 0.02), 0.1),
    "mark": ((0.22, 0.22, 0.23), 0.05, 1.0), "sensor": ((0.003, 0.004, 0.004), 0.58, 0.2), "contact": ((0.206, 0.206, 0.206), 0.2, 1.0)}.items()}


class Geo:
    """vertices and faces, each face with a material name"""

    def __init__(self):
        self.v, self.f, self.m, self.uv = [], [], [], {}

    def add(self, pts):
        i = len(self.v)
        self.v += [tuple(p) for p in pts]
        return list(range(i, i + len(pts)))

    def face(self, idx, mat):
        self.f.append(list(idx))
        self.m.append(mat)

    def loft(self, rings, mats, cap=(True, True)):
        """rings of equal length joined in order; mats is one name or one per band"""
        idx = [self.add(r) for r in rings]
        n = len(rings[0])
        assert all(len(r) == n for r in rings)
        for b in range(len(rings) - 1):
            mat = mats if isinstance(mats, str) else mats[b]
            a, c = idx[b], idx[b + 1]
            for i in range(n):
                j = (i + 1) % n
                self.face((a[i], a[j], c[j], c[i]), mat)
        first = mats if isinstance(mats, str) else mats[0]
        last = mats if isinstance(mats, str) else mats[-1]
        if cap[0]:
            self.face(idx[0][::-1], first)
        if cap[1]:
            self.face(idx[-1], last)

    def obj(self, name, closed=True, weld=True):
        me = bpy.data.meshes.new(name)
        me.from_pydata(self.v, [], self.f)
        names = list(dict.fromkeys(self.m))
        for n in names:
            me.materials.append(M[n])
        for p, n in zip(me.polygons, self.m):
            p.material_index = names.index(n)
        if self.uv:
            layer = me.uv_layers.new(name="UVMap")
            for loop in me.loops:
                layer.data[loop.index].uv = self.uv(Vector(self.v[loop.vertex_index]))
        bm = bmesh.new()
        bm.from_mesh(me)
        if weld:
            bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1e-5)
        if closed:
            bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
        bm.to_mesh(me)
        bm.free()
        o = bpy.data.objects.new(name, me)
        scene.collection.objects.link(o)
        return o


def rrect(hw, hh, r, n=24, cx=0.0, cy=0.0):
    """a rounded rectangle, counter-clockwise; coincident points dropped"""
    r = min(r, hw, hh)
    pts = []
    for k, (sx, sy) in enumerate(((1, 1), (-1, 1), (-1, -1), (1, -1))):
        for j in range(n + 1):
            a = math.pi / 2 * (k + j / n)
            pts.append((cx + sx * (hw - r) + r * math.cos(a), cy + sy * (hh - r) + r * math.sin(a)))
    return [p for i, p in enumerate(pts) if math.dist(p, pts[i - 1]) > 1e-7]


def rings(hw, hh, r, profile, n=24, cx=0.0, cy=0.0):
    """profile is (inset, z) from bottom to top"""
    return [[(x, y, z) for x, y in rrect(hw - i, hh - i, max(r - i, 0.005), n, cx, cy)] for i, z in profile]


def arc(cx, cz, r, a0, a1, steps):
    return [(cx + r * math.cos(a), cz + r * math.sin(a))
            for a in (math.radians(a0 + (a1 - a0) * t / steps) for t in range(steps + 1))]


def fillet(top, r, steps=4):
    """(inset, z) from a vertical side round into a flat top at z = top"""
    return [(r + x, z) for x, z in arc(0, top - r, r, 180, 90, steps)]


def prism(g, pts2d, z0, z1, mat, basis=Matrix.Identity(3), at=Vector()):
    """an extruded outline; basis maps local (u, v, height) to world"""
    ring = lambda z: [tuple(at + basis @ Vector((u, v, z))) for u, v in pts2d]
    g.loft([ring(z0), ring(z1)], mat)


def boolean(target, op, other):
    """applies other to target and removes other"""
    mod = target.modifiers.new("b", "BOOLEAN")
    mod.operation, mod.solver, mod.object, mod.material_mode = op, "EXACT", other, "TRANSFER"
    bpy.context.view_layer.update()
    target.data = bpy.data.meshes.new_from_object(target.evaluated_get(bpy.context.evaluated_depsgraph_get()))
    target.modifiers.clear()
    bpy.data.objects.remove(other)


def ellipse_ring(x, cy, cz, ry, rz, n=48):
    return [(x, cy + ry * math.cos(2 * math.pi * k / n), cz + rz * math.sin(2 * math.pi * k / n)) for k in range(n)]


# ---------------------------------------------------------------- base
base = Geo()
BASE = [(1.2, 0), (0.9, 0), (0.611, 0.016), (0.459, 0.05), (0.309, 0.121), (0.298, 0.13), (0.31, 0.14),
        (0.273, 0.15), (0.204, 0.206), (0.12, 0.3), (0.074, 0.398), (0.029, 0.539), (0.003, 0.787), (0, 0.9),
        *[(i, H - 0.02 + z) for i, z in fillet(0.02, 0.02, 3)]]
BAND = ["alloy"] * (len(BASE) - 1)
BAND[5] = BAND[6] = "well"  # the dark seam where the bottom case meets the top case
base.loft(rings(W / 2, D / 2, R, [(i, Z0 + z) for i, z in BASE], n=32), BAND)
base_obj = base.obj("base")

cut = Geo()
# keyboard well, trackpad slot, speaker grille slots
# the well's wall coves 0.94 mm down over 0.3 cm: (inset, mm below the deck), measured
WELL = [(-0.03, 0), *zip((-0.02 + 0.02 * k for k in (0, 1, 2, 3, 5, 7, 9, 11, 13, 15)),
                         (0.03, 0.15, 0.26, 0.36, 0.53, 0.67, 0.78, 0.85, 0.88, 0.91))][::-1]
cut.loft(rings(13.915, 5.721, 0.42, [(i, ZT - d / 10) for i, d in WELL] + [(-0.03, ZT + 1)], 12, 0, 3.493),
         ["well"] * len(WELL) + ["alloy"])
PAD = (6.21, 3.88, 0.38, 0, -6.419)
cut.loft(rings(PAD[0] + 0.02, PAD[1] + 0.02, PAD[2] + 0.02, [(0, ZT - 0.12), (0, ZT - 0.01), (-0.01, ZT), (-0.01, ZT + 1)],
               12, PAD[3], PAD[4]), ["well", "alloy", "alloy"])
GP, GCOLS, GROWS, GX, GY = 0.068, 6, 156, 14.95, -1.81
for s in (1, -1):
    x0, x1 = sorted((s * GX, s * (GX + GP * GCOLS)))
    prism(cut, [(x0, GY), (x1, GY), (x1, GY + GP * GROWS), (x0, GY + GP * GROWS)], ZT - 0.06, ZT + 1, "alloy")
# thumb scoop: a plane rising 0.65 back per unit up from 3.8 mm under the deck, eased out at the ends
# by (x, mm the plane steps forward), measured
SCOOP = [(0, 0), (2.18, 0), (2.24, 0.01), (2.3, 0.04), (2.36, 0.08), (2.42, 0.16), (2.48, 0.28), (2.54, 0.46),
         (2.6, 0.75), (2.64, 1.05), (2.68, 1.46), (2.7, 1.77), (2.73, 2.6)]
sz0, top = ZT - 0.38, ZT + 0.5
cut.loft([[(x, -D / 2 - 0.3, sz0 + (e / 10 - 0.3) / 0.65), (x, -D / 2 + 0.65 * (top - sz0) - e / 10, top), (x, -D / 2 - 0.3, top)]
          for x, e in [(-x, e) for x, e in SCOOP[:0:-1]] + SCOOP], "scoop")
# hinge recess along the back
prism(cut, rrect(11.95, 0.8, 0.15, 8, 0, D / 2 + 0.2), Z0 - 1, ZT + 1, "alloy")
# ports: (side, centre y, z above the bottom, outline, depth)
stadium = lambda l, h, n=8: rrect(l / 2, h / 2, h / 2, n)
TB = stadium(0.84, 0.27)
HDMI = [(-0.72, 0.24), (-0.72, -0.11), (-0.6, -0.23), (0.6, -0.23), (0.72, -0.11), (0.72, 0.24)]
PORTS = [(-1, 7.96, 0.73, stadium(1.42, 0.30), 0.106), (-1, 6.28, 0.736, TB, 0.65),
         (-1, 4.78, 0.736, TB, 0.65), (-1, 3.505, 0.756, rrect(0.18, 0.18, 0.18, 8), 1.4),
         (1, 8.135, 0.676, HDMI, 0.9), (1, 6.28, 0.736, TB, 0.65),
         (1, 3.81, 0.75, rrect(1.33, 0.12, 0.05, 6), 1.49)]
tongues = []
for side, y, z, outline, depth in PORTS:
    basis = Matrix(((0, 0, side), (1, 0, 0), (0, 1, 0)))  # u -> y, v -> z, height -> outward x
    prism(cut, outline, W / 2 - depth, W / 2 + 1, "port", basis, Vector((0, y, Z0 + z)))
    if outline is TB:
        tongues.append((basis, Vector((0, y, Z0 + z))))
# intake slots on the lower curve of each side
for s in (1, -1):
    n = Vector((s * math.cos(math.radians(35.7)), 0, -math.sin(math.radians(35.7))))
    basis = Matrix((Vector((0, 1, 0)), n.cross(Vector((0, 1, 0))), n)).transposed()
    for y0, y1 in ((-8.15, -3.29), (-3.01, 1.85)):
        prism(cut, stadium(y1 - y0, 0.177, 6), -0.4, 0.4, "grille", basis,
              Vector((s * (W / 2 - 0.172), (y0 + y1) / 2, Z0 + 0.312)))
# countersinks the feet sit in: 0.32 mm deep, 10.5 mm radius at the case
FEET = [(sx * 12.865, y) for sx in (1, -1) for y in (8.162, -8.176)]
for x, y in FEET:
    cut.loft(rings(1.05, 1.05, 1.05, [(0, Z0 - 1), (0, Z0), (0.09, Z0 + 0.032)], 16, x, y), "recess")
boolean(base_obj, "DIFFERENCE", cut.obj("cutter"))

# speaker grilles: a perforated panel filling each slot, flush with the deck
grille = Geo()
ang = [k * math.pi / 4 for k in range(8)]
for s in (1, -1):
    for row in range(GROWS):
        for col in range(GCOLS):
            cx, cy = s * (GX + GP * (col + 0.5)), GY + GP * (row + 0.5)
            sq = grille.add([(cx + GP / 2 * math.cos(a) / max(abs(math.cos(a)), abs(math.sin(a))),
                              cy + GP / 2 * math.sin(a) / max(abs(math.cos(a)), abs(math.sin(a))), ZT) for a in ang])
            hole = [(cx + 0.021 * math.cos(a), cy + 0.021 * math.sin(a)) for a in ang]
            top = grille.add([(x, y, ZT) for x, y in hole])
            bot = grille.add([(x, y, ZT - 0.05) for x, y in hole])
            for i in range(8):
                j = (i + 1) % 8
                grille.face((sq[i], sq[j], top[j], top[i]), "alloy")
                grille.face((top[i], top[j], bot[j], bot[i]), "grille")
            grille.face(bot[::-1], "grille")
grille.obj("grille", closed=False)

# trackpad, feet, screws, hinge barrel
parts = Geo()
parts.loft(rings(PAD[0], PAD[1], PAD[2], [(0, ZT - 0.12), *[(i, ZT - 0.022 + z) for i, z in fillet(0.012, 0.012, 3)]],
                 16, PAD[3], PAD[4]), "pad")
# the feet are domed: (radius cm, mm below the case), measured
DOME = [(0.1, 1.61), (0.3, 1.6), (0.48, 1.57), (0.64, 1.54), (0.72, 1.49), (0.78, 1.4), (0.82, 1.29), (0.86, 1.09),
        (0.9, 0.82), (0.92, 0.55), (0.945, 0.12), (0.95, -0.4)]
for x, y in FEET:
    parts.loft(rings(0.95, 0.95, 0.95, [(0.95 - r, Z0 + 0.0001 - d / 10) for r, d in DOME], 16, x, y), "foot")
for x, y in [(sx * 14.44, sy * 9.85) for sx in (1, -1) for sy in (1, -1)]:
    parts.loft(rings(0.16, 0.16, 0.16, [(0, Z0 - 0.0005), (0, Z0 + 0.01)], 8, x, y), "port")
BY, BZ = HINGE
parts.loft([ellipse_ring(s * x, BY, BZ, r, r, 64) for s, x, r in
            [(-1, 11.85, 0.34), (-1, 11.83, 0.4), (-1, 11.79, 0.42), (1, 11.79, 0.42), (1, 11.83, 0.4), (1, 11.85, 0.34)]],
           "hinge")
for basis, at in tongues:
    prism(parts, rrect(0.33, 0.035, 0.03, 4), W / 2 - 0.6, W / 2 - 0.1, "port", basis, at)
# the magnetic charging port: an insulating face with five contacts
mag_basis, mag_at = Matrix(((0, 0, -1), (1, 0, 0), (0, 1, 0))), Vector((0, 8.12, Z0 + 0.735))
prism(parts, stadium(1.07, 0.10), W / 2 - 0.11, W / 2 - 0.041, "port", mag_basis, mag_at)
for dy in (-0.38, -0.19, 0, 0.19, 0.38):
    prism(parts, rrect(0.026, 0.026, 0.026, 6), W / 2 - 0.042, W / 2 - 0.0408, "contact", mag_basis, mag_at + Vector((0, dy, 0)))
parts.obj("parts")

# ---------------------------------------------------------------- keyboard
UNIT, GAP, KH, PITCH_Y, KX0, KY0, KR = 1.68, 0.2165, 1.62, 1.8505, -13.639, 8.928, 0.15
KTOP = ZT + 0.013
# character keys are dished: (superellipse radius over the flat top, cm below KTOP), measured
DISH = [(0.1, 0.029), (0.18, 0.028), (0.26, 0.027), (0.34, 0.026), (0.42, 0.025), (0.5, 0.024), (0.58, 0.022),
        (0.66, 0.019), (0.74, 0.015), (0.82, 0.011), (0.9, 0.008), (0.98, 0.005)]
se = lambda dx, dy, a, b: ((abs(dx) / a) ** 4 + (abs(dy) / b) ** 4) ** 0.25


def cap_z(x, y, cx, cy, hw, hh, dished):
    s = se(x - cx, y - cy, hw - 0.012, hh - 0.012)
    if not dished or s >= DISH[-1][0]:
        return KTOP
    for (s0, d0), (s1, d1) in zip(DISH, DISH[1:]):
        if s < s1:
            return KTOP - d0 - (d1 - d0) * max(s - s0, 0) / (s1 - s0)


L = lambda *t: list(t)
Dished = type("Dished", (list,), {})
# legend sizes are font sizes, set so each glyph's measured width or height matches the reference
pair = lambda top, bottom: Dished(L((top, 0.41, "c", 0.30), (bottom, 0.79, "c", -0.33)))
letter = lambda c: Dished(L((c, 0.75, "c", 0)))
word, mod = 0.50, 0.64
F = [(UNIT, L((f"F{i}", 0.275, "c", -0.44))) for i in range(1, 13)]
ROWS = [
    [(2.625, L(("esc", 0.47, "bl", 0))), *F, (UNIT, "touch")],
    [(UNIT, L(*pair("~", "`"))), *[(UNIT, pair(a, b)) for a, b in zip("!@#$%^&*()_+", "1234567890-=")],
     (2.625, L(("⌫", mod, "br", 0)))],
    [(2.625, L(("⇥", mod, "bl", 0))), *[(UNIT, letter(c)) for c in "QWERTYUIOP"],
     *[(UNIT, pair(a, b)) for a, b in zip("{}", "[]")], (UNIT, L(*pair("|", "\\")))],
    [(3.10, L(("•", 0.4, "tl", 0), ("⇪", mod, "bl", 0))), *[(UNIT, letter(c)) for c in "ASDFGHJKL"],
     *[(UNIT, pair(a, b)) for a, b in zip(":\"", ";'")], (3.10, L(("⏎", mod, "br", 0)))],
    [(4.0475, L(("⇧", mod, "bl", 0))), *[(UNIT, letter(c)) for c in "ZXCVBNM"],
     *[(UNIT, pair(a, b)) for a, b in zip("<>?", ",./")], (4.0475, L(("⇧", mod, "br", 0)))],
    [(UNIT, L(("fn", word, "br", 0))), (UNIT, L(("⌃", mod, "tl", 0), ("control", word, "b", 0))),
     (UNIT, L(("⌥", mod, "tl", 0), ("option", word, "b", 0))), (2.16, L(("⌘", mod, "tl", 0), ("command", word, "b", 0))),
     (9.245, L()), (2.16, L(("⌘", mod, "tr", 0), ("command", word, "b", 0))),
     (UNIT, L(("⌥", mod, "tr", 0), ("option", word, "b", 0))), (UNIT, "arrows"), (UNIT, "arrows"), (UNIT, "arrows")],
]
keys = Geo()
touch = Geo()
legends = []  # (text, size, anchor, dy, key centre x, y, half w, half h, dished)
trenches = []  # (centre x, y, half w, half h) of each cap's slot in the well floor


def key(cx, cy, hw, hh, dished=False):
    prof = [(0, ZT - 0.1), *[(i, KTOP - 0.012 + z) for i, z in fillet(0.012, 0.012, 3)]]
    loops = rings(hw, hh, KR, prof, 8, cx, cy)
    if dished:  # each contour point on its rim point's ray from the centre
        loops += [[(cx + (x - cx) * k, cy + (y - cy) * k, KTOP - d) for x, y, _ in loops[-1]
                   for k in [s / se(x - cx, y - cy, hw - 0.012, hh - 0.012)]] for s, d in DISH[::-1]]
    keys.loft(loops, "keycap")


for r, row in enumerate(ROWS):
    cy, x = KY0 - KH / 2 - r * PITCH_Y, KX0
    arrows = 0
    for w, spec in row:
        cx, hw, hh = x + w / 2, w / 2 - (0.01 if w > 9 else 0.02), KH / 2 - 0.012  # caps stand in from the pitch
        if spec == "arrows":
            half = (KH - 0.06) / 2
            if arrows == 1:
                key(cx, cy + 0.03 + half / 2, hw, half / 2 - 0.01)
                legends.append(("▲", 0.26, "c", 0, cx, cy + 0.03 + half / 2, hw, half / 2 - 0.01, False))
            key(cx, cy - 0.03 - half / 2, hw, half / 2 - 0.01)
            legends.append(("◀▼▶"[arrows], 0.26, "c", 0, cx, cy - 0.03 - half / 2, hw, half / 2 - 0.01, False))
            trenches.append((cx, cy - (arrows != 1) * (0.03 + half / 2), hw, hh if arrows == 1 else half / 2 - 0.01))
            arrows += 1
        else:
            dished = isinstance(spec, Dished)
            key(cx, cy, hw, hh, dished)
            trenches.append((cx, cy, hw, hh))
            if spec == "touch":  # the sensor sits 0.18 mm down in a round well, a fine groove around it
                tid = Vector((cx, cy, 0))
                circle = [(0.48 * math.cos(a), 0.48 * math.sin(a)) for a in (2 * math.pi * k / 96 for k in range(96))]
                prism(touch, circle, KTOP - 0.05, KTOP - 0.018, "sensor", at=tid)
            else:
                legends += [(t, s, a, dy, cx, cy, hw, hh, dished) for t, s, a, dy in spec]
        if spec != "touch" and r == 3 and spec and spec[0][0] in ("F", "J"):
            z = cap_z(cx, cy - 0.56, cx, cy, hw, hh, True)
            keys.loft(rings(0.18, 0.022, 0.022, [(0, z - 0.002), (0, z + 0.008)], 4, cx, cy - 0.56), "keycap")
        x += w + GAP
keys_obj = keys.obj("keys")
pits = Geo()
for cx, cy, hw, hh in trenches:  # 0.4 mm wide, 1.67 mm below the well floor
    pits.loft(rings(hw + 0.04, hh + 0.04, KR + 0.04, [(0, ZT - 0.258), (0, ZT - 0.08)], 8, cx, cy), "grille")
boolean(base_obj, "DIFFERENCE", pits.obj("pits"))
hole = Geo()
prism(hole, [(0.5 * math.cos(a), 0.5 * math.sin(a)) for a in (2 * math.pi * k / 96 for k in range(96))],
      KTOP - 0.047, KTOP + 1, "keycap", at=tid)
boolean(keys_obj, "DIFFERENCE", hole.obj("hole"))
touch.obj("touchid")

# legends: glyphs a hair above the caps, following the dish
temp, font = [], bpy.data.fonts.load(os.path.expanduser("~/.cache/artemis/fonts/Inter-Regular.ttf"))
for t, s, *_ in legends:
    cu = bpy.data.curves.new("t", "FONT")
    cu.body, cu.size, cu.resolution_u, cu.font = t, s, 10, font
    o = bpy.data.objects.new("t", cu)
    scene.collection.objects.link(o)
    temp.append(o)
bpy.context.view_layer.update()
deps = bpy.context.evaluated_depsgraph_get()
glyphs = Geo()
MARGIN = 0.27
for o, (t, s, a, dy, cx, cy, hw, hh, dished) in zip(temp, legends):
    me = o.evaluated_get(deps).to_mesh()
    vs = [v.co.copy() for v in me.vertices]
    x0, x1 = min(v.x for v in vs), max(v.x for v in vs)
    y0, y1 = min(v.y for v in vs), max(v.y for v in vs)
    if len(t) > 1 and t.isalpha():
        y0 = 0  # words sit on their baseline, so descenders hang below it
    tx = {"l": cx - hw + MARGIN - x0, "r": cx + hw - MARGIN - x1}.get(a[-1] if a[-1] in "lr" else "", cx - (x0 + x1) / 2)
    ty = {"t": cy + hh - MARGIN + 0.02 - y1, "b": cy - hh + MARGIN - y0}.get(a[0], cy + dy - (y0 + y1) / 2)
    idx = glyphs.add([(v.x + tx, v.y + ty, cap_z(v.x + tx, v.y + ty, cx, cy, hw, hh, dished) + 0.001) for v in vs])
    me.calc_loop_triangles()  # glyph faces are concave ngons
    for tri in me.loop_triangles:
        glyphs.face([idx[i] for i in tri.vertices], "print")
    o.to_mesh_clear()
for o in temp:
    bpy.data.objects.remove(o)


# function-row icons and the globe: stroke centrelines in mm, round-jointed
def box(x0, y0, x1, y1, r=0.35):
    return (arc(x1 - r, y1 - r, r, 0, 90, 4) + arc(x0 + r, y1 - r, r, 90, 180, 4) + arc(x0 + r, y0 + r, r, 180, 270, 4)
            + arc(x1 - r, y0 + r, r, 270, 360, 4) + [(x1, y1 - r)])


def sun(r, r0, r1):
    return [arc(0, 0, r, 0, 360, 32)] + [[(r0 * math.cos(a), r0 * math.sin(a)), (r1 * math.cos(a), r1 * math.sin(a))]
                                         for a in (math.pi * k / 4 for k in range(8))]


def speaker(x0=0):
    return [[(x0, 0.55), (x0 + 0.7, 0.55), (x0 + 2.0, 1.35), (x0 + 2.0, -1.35), (x0 + 0.7, -0.55), (x0, -0.55), (x0, 0.55)]]


tri = lambda tip, base, h=1.15: [(base, h), (tip, 0), (base, -h), (base, h)]
waves = lambda *rs: [arc(1.2, 0, r, -40, 40, 10) for r in rs]
ICONS = [
    sun(0.7, 1.15, 1.45),
    sun(0.8, 1.25, 1.8),
    [box(-2.15, 0.15, -0.1, 1.3), box(-1.8, -1.3, -0.1, -0.15), box(0.35, -1.3, 2.15, 1.3)],
    [arc(-0.3, 0.3, 1.0, 0, 360, 32), [(0.42, -0.42), (1.35, -1.35)]],
    [arc(0, 1.1, 0.42, 0, 180, 12) + arc(0, 0.35, 0.42, 180, 360, 12) + [(0.42, 1.1)],
     arc(0, 0.45, 0.85, 180, 360, 16), [(0, -0.4), (0, -1.45)], [(-0.6, -1.45), (0.6, -1.45)]],
    [arc(0, 0, 1.45, 60, 300, 32) + arc(1.33, 0, 1.4, 244.3, 115.7, 24)],
    [tri(-2.2, 0), tri(0, 2.2)],
    [tri(0.05, -2.2), [(1.0, -1.15), (1.0, 1.15)], [(2.05, -1.15), (2.05, 1.15)]],
    [tri(0, -2.2), tri(2.2, 0)],
    speaker() + [[(-0.4, 1.6), (2.4, -1.6)]],
    speaker() + waves(1.35),
    speaker() + waves(1.35, 2.0, 2.65),
]
GLOBE = [arc(0, 0, 1.9, 0, 360, 40), [(x * 0.45, y) for x, y in arc(0, 0, 1.9, 0, 360, 32)], [(0, -1.9), (0, 1.9)], [(-1.9, 0), (1.9, 0)],
         [(-1.65, 0.95), (1.65, 0.95)], [(-1.65, -0.95), (1.65, -0.95)]]


def stroke(lines, cx, cy, w):  # centred on (cx, cy) in cm
    pts = [p for line in lines for p in line]
    ox = (min(x for x, _ in pts) + max(x for x, _ in pts)) / 2
    oy = (min(y for _, y in pts) + max(y for _, y in pts)) / 2
    at = lambda x, y: Vector((cx + (x - ox) / 10, cy + (y - oy) / 10))
    z = KTOP + 0.001
    for line in lines:
        for (x, y) in line:
            c = at(x, y)
            glyphs.face(glyphs.add([(c.x + w / 2 * math.cos(a), c.y + w / 2 * math.sin(a), z)
                                    for a in (2 * math.pi * k / 10 for k in range(10))]), "print")
        for p, q in zip(line, line[1:]):
            a, b = at(*p), at(*q)
            if (b - a).length < 1e-9:
                continue
            n = Vector((a.y - b.y, b.x - a.x)).normalized() * w / 2
            glyphs.face(glyphs.add([(*(a - n), z), (*(b - n), z), (*(b + n), z), (*(a + n), z)]), "print")


row0 = KX0 + 2.625 + GAP
for i, icon in enumerate(ICONS):
    stroke(icon, row0 + i * (UNIT + GAP) + UNIT / 2, KY0 - KH / 2 + 0.23, 0.024)
stroke(GLOBE, KX0 + 0.47, KY0 - KH / 2 - 5 * PITCH_Y - KH / 2 + 0.46, 0.018)
glyphs.obj("legends", closed=False, weld=False)

# ---------------------------------------------------------------- lid
lid = Geo()
LIDP = [(0.13, 0), (0.03, 0), (0.008, 0.006), (0, 0.025), (0, LIDH - 0.1),
        *[(i, LIDH - 0.1 + z) for i, z in fillet(0.1, 0.1, 6)[1:]]]
lid.loft(rings(W / 2, D / 2, R, [(i, LZ + z) for i, z in LIDP], 32), ["well"] + ["alloy"] * (len(LIDP) - 2))  # a black gasket round the glass
lid.obj("lid")

glass = Geo()
glass.loft(rings(15.38, 10.565, R - 0.13, [(0.01, LZ - 0.003), (0, LZ + 0.004), (0, LZ + 0.04)], 32, 0, -0.135), "glass")
glass.obj("lid-glass")

SX, SY0, SY1 = 15.05, -10.38, 9.46  # the panel: 30.10 x 19.84, its top edge at the lid's front
screen = Geo()
screen.face(screen.add([(x, y, LZ - 0.0045) for x, y in rrect(SX, (SY1 - SY0) / 2, 0.45, 32, 0, (SY0 + SY1) / 2)])[::-1],
            "screen")
screen.uv = lambda p: ((p.x + SX) / (2 * SX), (SY1 - p.y) / (SY1 - SY0))
screen.obj("lid-screen", closed=False)

cam = Geo()
PY = -9.905
for pts, z, mat in [(rrect(0.59, 0.315, 0.315, 12, 0, PY), LZ - 0.0055, "glass"),
                    (rrect(0.18, 0.18, 0.18, 12, 0.27, PY), LZ - 0.0062, "lens"),
                    (rrect(0.10, 0.10, 0.10, 8, -0.27, PY), LZ - 0.0062, "lens")]:
    cam.face(cam.add([(x, y, z) for x, y in pts])[::-1], mat)
cam.obj("lid-camera", closed=False)

# the Artemis mark from the site's icon, mirror-polished in the lid's back: the comet passes
# behind the left leg and over the right, each crossing parted by a GAP of bare alloy
icon = ET.parse(os.path.join(os.path.dirname(os.path.abspath(__file__)), "../../src/static/icon.svg")).getroot()
paths = {e.get("id") or e.get("class"): e.get("d") for e in icon.iter() if e.tag.endswith("path")}
LEG_R = float(next(e.get("stroke-width") for e in icon.iter() if e.get("class") == "a")) / 2
GAP = 16


def svg_points(d):
    """an M/L/A/Z outline as points; arcs are circular"""
    tok = re.findall(r"[MLAZ]|-?[\d.]+", d)
    pts, i = [], 0
    while i < len(tok):
        c = tok[i]
        if c in "ML":
            pts.append((float(tok[i + 1]), float(tok[i + 2])))
            i += 3
        elif c == "A":
            r, fa, fs, x1, y1 = float(tok[i + 1]), int(tok[i + 4]), int(tok[i + 5]), float(tok[i + 6]), float(tok[i + 7])
            x0, y0 = pts[-1]
            hx, hy = (x0 - x1) / 2, (y0 - y1) / 2
            k = (-1 if fa == fs else 1) * math.sqrt(max(0, r * r / (hx * hx + hy * hy) - 1))
            cx, cy = k * hy + (x0 + x1) / 2, -k * hx + (y0 + y1) / 2
            a0 = math.atan2(y0 - cy, x0 - cx)
            da = (math.atan2(y1 - cy, x1 - cx) - a0) % (2 * math.pi)
            if not fs:
                da -= 2 * math.pi
            pts += [(cx + r * math.cos(a0 + da * t / 16), cy + r * math.sin(a0 + da * t / 16)) for t in range(1, 17)]
            i += 8
        else:
            i += 1
    return pts


def stadium(a, b, r, n=16):
    ang = math.atan2(b[1] - a[1], b[0] - a[0])
    return [(p[0] + r * math.cos(t), p[1] + r * math.sin(t)) for p, t0 in ((b, ang - math.pi / 2), (a, ang + math.pi / 2))
            for t in (t0 + math.pi * j / n for j in range(n + 1))]


def inflate(pts, d):
    """each vertex pushed d along its mitred normal; pts are counter-clockwise in y-up"""
    out = []
    for i, p in enumerate(pts):
        a, b = pts[i - 1], pts[(i + 1) % len(pts)]
        n1, n2 = [Vector((q[1] - o[1], o[0] - q[0])).normalized() for o, q in ((a, p), (p, b))]
        m = (n1 + n2).normalized()
        out.append((p[0] + m.x * d / max(m.dot(n1), 0.3), p[1] + m.y * d / max(m.dot(n1), 0.3)))
    return out


def ccw(pts):
    return pts if sum(a[0] * b[1] - b[0] * a[1] for a, b in zip(pts, pts[1:] + pts[:1])) > 0 else pts[::-1]


foot_l, apex, foot_r = svg_points(paths["a"])
comet = svg_points(paths["comet"])
comet = [p for i, p in enumerate(comet) if math.dist(p, comet[i - 1]) > 1e-6]
TOP = LZ + LIDH
# read from behind the open lid: the icon's top toward the closed lid's front, its right toward -x
xs, ys = [p[0] for p in comet + [foot_l, foot_r]], [apex[1] - LEG_R, foot_l[1] + LEG_R]
MK = 3.4 / (ys[1] - ys[0])  # the A stands 3.4 tall
to_lid = lambda pts: ccw([(-(x - (min(xs) + max(xs)) / 2) * MK, (y - sum(ys) / 2) * MK) for x, y in pts])


def mark_solid(pts, z0, z1):
    g = Geo()
    prism(g, pts, z0, z1, "mark")
    return g.obj("lid-mark")


solids = [mark_solid(to_lid(stadium(foot_l, apex, LEG_R)), TOP - 0.002, TOP + 0.0004),
          mark_solid(to_lid(stadium(foot_r, apex, LEG_R)), TOP - 0.002, TOP + 0.0004),
          mark_solid(to_lid(comet), TOP - 0.002, TOP + 0.0004)]
boolean(solids[2], "DIFFERENCE", mark_solid(to_lid(stadium(foot_l, apex, LEG_R + GAP)), TOP - 0.01, TOP + 0.01))
boolean(solids[1], "DIFFERENCE", mark_solid(inflate(to_lid(comet), GAP * MK), TOP - 0.01, TOP + 0.01))
for o in solids[1:]:
    boolean(solids[0], "UNION", o)

# ---------------------------------------------------------------- finish
for o in scene.objects:
    o.data.shade_smooth()
    o.data.set_sharp_from_angle(angle=math.radians(35))
for o in scene.objects:
    print(f"model.py: {o.name:12s} {sum(len(p.vertices) - 2 for p in o.data.polygons):7d} tris")
bpy.ops.export_scene.gltf(filepath=OUT, export_format="GLB", export_yup=True, export_apply=True)
