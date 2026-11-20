# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

# blender -b --factory-startup -P tools/3d/model.py -- OUT.glb
# A 14-inch laptop in Space Black, built from measurements, for render.py (--flip-uv 0).
# Units are cm, Z up, front -y; the lid is closed, only lid parts are named lid*, and it turns about HINGE.
# Material names are render.py roles; "print" and "lens" are kept as exported.
import math, sys
import bpy, bmesh
from mathutils import Matrix, Vector

OUT = sys.argv[sys.argv.index("--") + 1]
bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene

W, D, R = 31.02, 21.64, 1.27
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
    "alloy": ((0.026, 0.027, 0.03), 0.34, 1.0), "well": ((0.004, 0.004, 0.004), 0.7),
    "keycap": ((0.008, 0.008, 0.009), 0.5), "print": ((0.42, 0.42, 0.44), 0.5),
    "pad": ((0.026, 0.027, 0.03), 0.26, 1.0), "scoop": ((0.02, 0.02, 0.022), 0.4, 1.0),
    "recess": ((0.02, 0.02, 0.022), 0.45, 1.0), "grille": ((0.003, 0.003, 0.003), 0.9),
    "port": ((0.002, 0.002, 0.002), 0.6), "foot": ((0.01, 0.01, 0.01), 0.85),
    "hinge": ((0.015, 0.015, 0.016), 0.4, 1.0), "glass": ((0.002, 0.002, 0.002), 0.04),
    "screen": ((0.0, 0.0, 0.0), 0.05), "lens": ((0.01, 0.012, 0.02), 0.1)}.items()}


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
# each with a 0.02 bright-cut chamfer at the deck
CHAMFER = lambda floor: [(0, floor), (0, ZT - 0.02), (-0.02, ZT), (-0.02, ZT + 1)]
cut.loft(rings(13.945, 5.755, 0.42, CHAMFER(ZT - 0.275), 12, 0, 3.505), ["well", "alloy", "alloy"])
PAD = (6.21, 3.88, 0.38, 0, -6.41)
cut.loft(rings(PAD[0] + 0.03, PAD[1] + 0.03, PAD[2] + 0.03, CHAMFER(ZT - 0.12), 12, PAD[3], PAD[4]), ["well", "alloy", "alloy"])
GP, GCOLS, GROWS, GX, GY = 0.068, 6, 156, 14.95, -1.81
for s in (1, -1):
    x0, x1 = sorted((s * GX, s * (GX + GP * GCOLS)))
    prism(cut, [(x0, GY), (x1, GY), (x1, GY + GP * GROWS), (x0, GY + GP * GROWS)], ZT - 0.06, ZT + 1, "alloy")
# thumb scoop: an elliptic channel with round ends at the front edge
ends = [math.radians(a) for a in range(0, 91, 10)]
ends = [(-1, a) for a in ends[::-1]] + [(1, a) for a in ends]
cut.loft([ellipse_ring(s * (2.42 + 0.3 * math.sin(a)), -D / 2, ZT, 0.30 * max(math.cos(a), 0.02),
                       0.22 * max(math.cos(a), 0.02)) for s, a in ends], "scoop")
# hinge recess along the back
prism(cut, rrect(11.95, 0.8, 0.15, 8, 0, D / 2 + 0.2), Z0 - 1, ZT + 1, "alloy")
# ports: (side, centre y, z above the bottom, outline, depth)
stadium = lambda l, h, n=8: rrect(l / 2, h / 2, h / 2, n)
TB = stadium(0.84, 0.27)
HDMI = [(-0.71, 0.23), (-0.71, -0.11), (-0.59, -0.23), (0.59, -0.23), (0.71, -0.11), (0.71, 0.23)]
PORTS = [(-1, 8.13, 0.746, stadium(1.10, 0.22), 0.15), (-1, 6.28, 0.756, TB, 0.6),
         (-1, 4.80, 0.756, TB, 0.6), (-1, 3.505, 0.756, rrect(0.18, 0.18, 0.18, 8), 0.8),
         (1, 8.135, 0.676, HDMI, 0.6), (1, 6.28, 0.756, TB, 0.6),
         (1, 3.85, 0.62, rrect(1.21, 0.11, 0.05, 6), 0.6)]
tongues = []
for side, y, z, outline, depth in PORTS:
    basis = Matrix(((0, 0, side), (1, 0, 0), (0, 1, 0)))  # u -> y, v -> z, height -> outward x
    prism(cut, outline, W / 2 - depth, W / 2 + 1, "port", basis, Vector((0, y, Z0 + z)))
    if outline is TB:
        tongues.append((basis, Vector((0, y, Z0 + z))))
# intake slots on the lower curve of each side
for s in (1, -1):
    n = Vector((s * math.cos(math.radians(40)), 0, -math.sin(math.radians(40))))
    basis = Matrix((Vector((0, 1, 0)), n.cross(Vector((0, 1, 0))), n)).transposed()
    for y0, y1 in ((-7.78, -3.3), (-3.08, 1.82)):
        prism(cut, stadium(y1 - y0, 0.05, 6), -0.4, 0.4, "grille", basis,
              Vector((s * (W / 2 - 0.16), (y0 + y1) / 2, Z0 + 0.25)))
# counterbores the feet sit in
FEET = [(sx * 12.82, sy * 8.13) for sx in (1, -1) for sy in (1, -1)]
for x, y in FEET:
    prism(cut, rrect(1.07, 1.07, 1.07, 12, x, y), Z0 - 1, Z0 + 0.02, "recess")
cutter = cut.obj("cutter")
mod = base_obj.modifiers.new("cut", "BOOLEAN")
mod.operation, mod.solver, mod.object, mod.material_mode = "DIFFERENCE", "EXACT", cutter, "TRANSFER"
bpy.context.view_layer.update()
base_obj.data = bpy.data.meshes.new_from_object(base_obj.evaluated_get(bpy.context.evaluated_depsgraph_get()))
base_obj.modifiers.clear()
bpy.data.objects.remove(cutter)

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
parts.loft(rings(PAD[0], PAD[1], PAD[2], [(0, ZT - 0.12), *[(i, ZT - 0.015 + z) for i, z in fillet(0.012, 0.012, 3)]],
                 16, PAD[3], PAD[4]), "pad")
for x, y in FEET:
    prof = [(1.0 - r, z) for r, z in [(0.8, 0), (0.88, 0.004), (0.94, 0.016), (0.98, 0.04), (1.0, 0.07), (1.0, Z0 + 0.02)]]
    parts.loft(rings(1.0, 1.0, 1.0, prof, 16, x, y), "foot")
for x, y in [(sx * 14.44, sy * 9.85) for sx in (1, -1) for sy in (1, -1)]:
    parts.loft(rings(0.09, 0.09, 0.09, [(0, Z0 - 0.004), (0, Z0 + 0.01)], 6, x, y), "port")
BY, BZ = HINGE
parts.loft([ellipse_ring(s * x, BY, BZ, r, r, 64) for s, x, r in
            [(-1, 11.85, 0.34), (-1, 11.83, 0.4), (-1, 11.79, 0.42), (1, 11.79, 0.42), (1, 11.83, 0.4), (1, 11.85, 0.34)]],
           "hinge")
for basis, at in tongues:
    prism(parts, rrect(0.33, 0.035, 0.03, 4), W / 2 - 0.6, W / 2 - 0.1, "port", basis, at)
parts.obj("parts")

# ---------------------------------------------------------------- keyboard
UNIT, GAP, KH, PITCH_Y, KX0, KY0, KR = 1.68, 0.215, 1.62, 1.846, -13.63, 8.93, 0.15
KTOP = ZT + 0.015
L = lambda *t: list(t)
pair = lambda top, bottom: L((top, 0.40, "c", 0.36), (bottom, 0.50, "c", -0.30))
letter = lambda c: L((c, 0.58, "c", 0))
F = [(UNIT, L((f"F{i}", 0.22, "b", 0))) for i in range(1, 13)]
ROWS = [
    [(2.625, L(("esc", 0.30, "bl", 0))), *F, (UNIT, "touch")],
    [(UNIT, pair("~", "`")), *[(UNIT, pair(a, b)) for a, b in zip("!@#$%^&*()_+", "1234567890-=")],
     (2.625, L(("⌫", 0.36, "br", 0)))],
    [(2.625, L(("⇥", 0.36, "bl", 0))), *[(UNIT, letter(c)) for c in "QWERTYUIOP"],
     *[(UNIT, pair(a, b)) for a, b in zip("{}|", "[]\\")]],
    [(3.10, L(("•", 0.30, "tl", 0), ("⇪", 0.36, "bl", 0))), *[(UNIT, letter(c)) for c in "ASDFGHJKL"],
     *[(UNIT, pair(a, b)) for a, b in zip(":\"", ";'")], (3.10, L(("⏎", 0.36, "br", 0)))],
    [(4.0475, L(("⇧", 0.36, "bl", 0))), *[(UNIT, letter(c)) for c in "ZXCVBNM"],
     *[(UNIT, pair(a, b)) for a, b in zip("<>?", ",./")], (4.0475, L(("⇧", 0.36, "br", 0)))],
    [(UNIT, L(("🌐", 0.30, "bl", 0), ("fn", 0.28, "br", 0))), (UNIT, L(("⌃", 0.32, "tl", 0), ("control", 0.24, "b", 0))),
     (UNIT, L(("⌥", 0.32, "tl", 0), ("option", 0.24, "b", 0))), (2.16, L(("⌘", 0.32, "tl", 0), ("command", 0.24, "b", 0))),
     (9.245, L()), (2.16, L(("⌘", 0.32, "tr", 0), ("command", 0.24, "b", 0))),
     (UNIT, L(("⌥", 0.32, "tr", 0), ("option", 0.24, "b", 0))), (UNIT, "arrows"), (UNIT, "arrows"), (UNIT, "arrows")],
]
keys = Geo()
legends = []  # (text, size, anchor, dy, key centre x, y, half w, half h)


def key(cx, cy, hw, hh):
    prof = [(0, ZT - 0.135), *[(i, KTOP - 0.03 + z) for i, z in fillet(0.03, 0.03, 4)]]
    keys.loft(rings(hw, hh, KR, prof, 8, cx, cy), "keycap")


for r, row in enumerate(ROWS):
    cy, x = KY0 - KH / 2 - r * PITCH_Y, KX0
    arrows = 0
    for w, spec in row:
        cx = x + w / 2
        if spec == "arrows":
            half = (KH - 0.06) / 2
            if arrows == 1:
                key(cx, cy + 0.03 + half / 2, w / 2, half / 2)
                legends.append(("▲", 0.2, "c", 0, cx, cy + 0.03 + half / 2, w / 2, half / 2))
            key(cx, cy - 0.03 - half / 2, w / 2, half / 2)
            legends.append(("◀▼▶"[arrows], 0.2, "c", 0, cx, cy - 0.03 - half / 2, w / 2, half / 2))
            arrows += 1
        else:
            key(cx, cy, w / 2, KH / 2)
            if spec == "touch":
                keys.loft(rings(0.5, 0.5, 0.5, [(0, KTOP + 0.0005), (0, KTOP + 0.0012)], 16, cx, cy), "glass")
            else:
                legends += [(t, s, a, dy, cx, cy, w / 2, KH / 2) for t, s, a, dy in spec]
        if spec != "touch" and r == 3 and spec and spec[0][0] in ("F", "J"):
            keys.loft(rings(0.18, 0.022, 0.022, [(0, KTOP - 0.001), (0, KTOP + 0.008)], 4, cx, cy - 0.56), "keycap")
        x += w + GAP
keys.obj("keys")

# legends: flat glyphs a hair above the caps
temp = []
for t, s, *_ in legends:
    cu = bpy.data.curves.new("t", "FONT")
    cu.body, cu.size, cu.resolution_u = t, s, 10
    o = bpy.data.objects.new("t", cu)
    scene.collection.objects.link(o)
    temp.append(o)
bpy.context.view_layer.update()
deps = bpy.context.evaluated_depsgraph_get()
glyphs = Geo()
MARGIN = 0.17
for o, (t, s, a, dy, cx, cy, hw, hh) in zip(temp, legends):
    me = o.evaluated_get(deps).to_mesh()
    vs = [v.co.copy() for v in me.vertices]
    x0, x1 = min(v.x for v in vs), max(v.x for v in vs)
    y0, y1 = min(v.y for v in vs), max(v.y for v in vs)
    tx = {"l": cx - hw + MARGIN - x0, "r": cx + hw - MARGIN - x1}.get(a[-1] if a[-1] in "lr" else "", cx - (x0 + x1) / 2)
    ty = {"t": cy + hh - MARGIN + 0.02 - y1, "b": cy - hh + MARGIN - y0}.get(a[0], cy + dy - (y0 + y1) / 2)
    idx = glyphs.add([(v.x + tx, v.y + ty, KTOP + 0.001) for v in vs])
    me.calc_loop_triangles()  # glyph faces are concave ngons
    for tri in me.loop_triangles:
        glyphs.face([idx[i] for i in tri.vertices], "print")
    o.to_mesh_clear()
for o in temp:
    bpy.data.objects.remove(o)
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

# ---------------------------------------------------------------- finish
for o in scene.objects:
    o.data.shade_smooth()
    o.data.set_sharp_from_angle(angle=math.radians(35))
for o in scene.objects:
    print(f"model.py: {o.name:12s} {sum(len(p.vertices) - 2 for p in o.data.polygons):7d} tris")
bpy.ops.export_scene.gltf(filepath=OUT, export_format="GLB", export_yup=True, export_apply=True)
