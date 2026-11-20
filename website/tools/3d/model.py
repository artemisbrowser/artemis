# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

# blender -b --factory-startup -P tools/3d/model.py -- OUT.glb
# A 14-inch laptop in Space Black, built from measurements, for render.py (--flip-uv 0).
# Units are cm, Z up, front -y; the lid is closed, only lid parts are named lid*, and it turns about HINGE.
# Material names are render.py roles; "print", "lens", "mark", "sensor", "contact", "gasket", "cover",
# "pin" and "bore" are kept as exported.
# Legends need Inter Regular 4.1 (OFL-1.1, github.com/rsms/inter) at ~/.cache/artemis/fonts/Inter-Regular.ttf.
import math, os, re, sys
import xml.etree.ElementTree as ET
import bpy, bmesh
from mathutils import Matrix, Vector, geometry
from mathutils.bvhtree import BVHTree

OUT = sys.argv[sys.argv.index("--") + 1]
bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene

W, D, R, LD = 31.02, 21.64, 1.11, 21.66
FOOT, H, LIDH = 0.16, 1.12, 0.335
Z0, ZT = FOOT, FOOT + H
LZ = ZT + 0.04  # the lid's display face, closed: its gasket rests on the deck
HINGE = (10.5655, 0.8922)  # the lid's axis (y, z): opened 110 degrees, the lid lands on the reference's


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
    "alloy": ((0.093, 0.089, 0.095), 0.553, 1.0), "seam": ((0.0931, 0.0891, 0.0952), 0.641, 1.0),
    "pad": ((0.0833, 0.0799, 0.085), 0.553, 1.0), "well": ((0.0052, 0.0055, 0.006), 0.605, 0.2),
    "keycap": ((0.0035, 0.0036, 0.004), 0.55, 0.2), "print": ((0.8, 0.8, 0.8), 0.4),
    "hinge": ((0.0035, 0.0036, 0.004), 0.55, 0.2), "sensor": ((0.0035, 0.0036, 0.004), 0.58, 0.2),
    "grille": ((0.0, 0.0, 0.0), 1.0), "foot": ((0.0, 0.0, 0.0), 0.8, 0.2), "gasket": ((0.0, 0.0, 0.0), 0.8, 0.2),
    "port": ((0.05, 0.05, 0.05), 0.87), "bore": ((0.025, 0.025, 0.025), 0.8), "pin": ((0.0689, 0.0678, 0.0644), 0.5, 0.75),
    "contact": ((0.206, 0.206, 0.206), 0.2, 1.0),
    "glass": ((0.0, 0.0, 0.0), 1.0), "cover": ((0.035, 0.035, 0.035), 0.8, 0.2), "screen": ((0.0, 0.0, 0.0), 0.05),
    "lens": ((0.0, 0.0, 0.0), 1.0), "mark": ((0.22, 0.22, 0.23), 0.05, 1.0)}.items()}


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
    """a rounded rectangle, counter-clockwise; r is one radius or four from the +x +y corner on; coincident points dropped"""
    pts = []
    for k, ((sx, sy), r) in enumerate(zip(((1, 1), (-1, 1), (-1, -1), (1, -1)), r if isinstance(r, tuple) else (r,) * 4)):
        r = min(r, hw, hh)
        for j in range(n + 1):
            a = math.pi / 2 * (k + j / n)
            pts.append((cx + sx * (hw - r) + r * math.cos(a), cy + sy * (hh - r) + r * math.sin(a)))
    return [p for i, p in enumerate(pts) if math.dist(p, pts[i - 1]) > 1e-7]


def clip_y(pts, y0):
    """the part of a closed outline at y >= y0"""
    out = []
    for p, q in zip(pts, pts[1:] + pts[:1]):
        if p[1] >= y0:
            out.append(p)
        if (p[1] - y0) * (q[1] - y0) < 0:
            out.append((p[0] + (y0 - p[1]) / (q[1] - p[1]) * (q[0] - p[0]), y0))
    return out


def rings(hw, hh, r, profile, n=24, cx=0.0, cy=0.0):
    """profile is (inset, z) from bottom to top"""
    return [[(x, y, z) for x, y in rrect(hw - i, hh - i, max(r - i, 0.005), n, cx, cy)] for i, z in profile]


def arc(cx, cz, r, a0, a1, steps):
    return [(cx + r * math.cos(a), cz + r * math.sin(a))
            for a in (math.radians(a0 + (a1 - a0) * t / steps) for t in range(steps + 1))]


def fillet(top, r, steps=4):
    """(inset, z) from a vertical side round into a flat top at z = top"""
    return [(r + x, z) for x, z in arc(0, top - r, r, 180, 90, steps)]


def spline(pts, step=0.02):
    """a centripetal Catmull-Rom curve through pts, (inset, z), with points about step apart"""
    P = [Vector(pts[0]) * 2 - Vector(pts[1]), *map(Vector, pts), Vector(pts[-1]) * 2 - Vector(pts[-2])]
    out = [pts[0]]
    for p0, p1, p2, p3 in zip(P, P[1:], P[2:], P[3:]):
        t1 = (p1 - p0).length ** 0.5 + 1e-9
        t2 = t1 + (p2 - p1).length ** 0.5 + 1e-9
        t3 = t2 + (p3 - p2).length ** 0.5 + 1e-9
        n = max(1, math.ceil((p2 - p1).length / step))
        for k in range(1, n + 1):
            t = t1 + (t2 - t1) * k / n
            a1, a2, a3 = (p0 * (t1 - t) + p1 * t) / t1, (p1 * (t2 - t) + p2 * (t - t1)) / (t2 - t1), (p2 * (t3 - t) + p3 * (t - t2)) / (t3 - t2)
            b1, b2 = (a1 * (t2 - t) + a2 * t) / t2, (a2 * (t3 - t) + a3 * (t - t1)) / (t3 - t1)
            c = (b1 * (t2 - t) + b2 * (t - t1)) / (t2 - t1)
            out.append((max(c.x, 0.0), c.y))
    return out


def prism(g, pts2d, z0, z1, mat, basis=Matrix.Identity(3), at=Vector()):
    """an extruded outline; basis maps local (u, v, height) to world"""
    ring = lambda z: [tuple(at + basis @ Vector((u, v, z))) for u, v in pts2d]
    g.loft([ring(z0), ring(z1)], mat)


def inflate(pts, d):
    """each vertex pushed d along its mitred normal; pts are counter-clockwise in y-up"""
    out = []
    for i, p in enumerate(pts):
        a, b = pts[i - 1], pts[(i + 1) % len(pts)]
        n1, n2 = [Vector((q[1] - o[1], o[0] - q[0])).normalized() for o, q in ((a, p), (p, b))]
        m = (n1 + n2).normalized()
        out.append((p[0] + m.x * d / max(m.dot(n1), 0.3), p[1] + m.y * d / max(m.dot(n1), 0.3)))
    return out


def boolean(target, op, other):
    """applies other to target and removes other"""
    mod = target.modifiers.new("b", "BOOLEAN")
    mod.operation, mod.solver, mod.object, mod.material_mode, mod.use_self = op, "EXACT", other, "TRANSFER", True
    bpy.context.view_layer.update()
    target.data = bpy.data.meshes.new_from_object(target.evaluated_get(bpy.context.evaluated_depsgraph_get()))
    target.modifiers.clear()
    bpy.data.objects.remove(other)


# ---------------------------------------------------------------- base
base = Geo()
BASE = [(1.2, 0), *spline([(0.9, 0), (0.611, 0.016), (0.459, 0.05), (0.3094, 0.1211)]),
        *spline([(0.2777, 0.1429), (0.204, 0.206), (0.12, 0.3), (0.074, 0.398), (0.029, 0.539), (0.003, 0.787), (0, 0.9),
                 *[(i, H - 0.02 + z) for i, z in fillet(0.02, 0.02, 3)]])]
BAND = ["alloy"] * (len(BASE) - 1)
BAND[BASE.index((0.2777, 0.1429)) - 2] = "seam"  # the bottom case's lip, just under the crease where the top case starts
base.loft(rings(W / 2, D / 2, R, [(i, Z0 + z) for i, z in BASE], n=32), BAND)
base_obj = base.obj("base")
skin = base.obj("skin")

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
          for x, e in [(-x, e) for x, e in SCOOP[:0:-1]] + SCOOP], "alloy")
# the hinge cut-out along the back, (y, z) measured: the deck rolls down into a lip, a floor below; the lip is
# shallower behind the knuckles and notched between them; the hinge bar's ends show outboard; vents behind
XB = Matrix(((0, 0, 1), (1, 0, 0), (0, 1, 0)))  # u -> y, v -> z, height -> x
XV = Matrix(((1, 0, 0), (0, 0, 1), (0, 1, 0)))  # u -> x, v -> z, height -> y
LIP = [(10.4, 1.4), (10.4, 1.281), (10.524, 0.961), (10.521, 0.932), (10.493, 0.907), (10.468, 0.906), (10.445, 0.921),
       (10.401, 1.048), (10.352, 1.117), (10.286, 1.169), (10.226, 1.196), (10.19, 1.18), (10.196, 0.883), (10.212, 0.786),
       (10.229, 0.74), (10.283, 0.658), (10.477, 0.468), (10.519, 0.406), (10.554, 0.329), (10.554, 0.32), (11.2, 0.32), (11.2, 1.4)]
KTOP = [(10.4, 1.4), (10.4, 1.281), (10.434, 1.194), (10.388, 1.171), (10.337, 1.132), (10.26, 1.182), (10.193, 1.203)]
BAR = [(10.193, 1.0), (10.62, 1.0), (10.66, 0.98), (10.69, 0.9), (10.68, 0.83), (10.65, 0.79), (10.57, 0.755), (10.235, 0.745)]
prism(cut, LIP, -10.26, 10.26, "alloy", XB)
for k in range(-2, 3):
    prism(cut, rrect(0.41, 0.08, 0.08, 8, 0.99 * k, 1.075), 10.19, 10.6, "alloy", XV)
for s in (1, -1):
    prism(cut, KTOP + LIP[12:], *sorted((s * 10.24, s * 11.76)), "alloy", XB)
    prism(cut, KTOP + BAR + LIP[15:], *sorted((s * 11.75, s * 11.83)), "alloy", XB)
    prism(cut, rrect(2.805, 0.224, 0.001, 1, s * 8.855, 0.615), 10.146, 10.6, "alloy", XV)
    prism(cut, rrect(1.46, 0.1, 0.04, 6, s * 3.99, 0.79), 9.36, 10.6, "hinge", XV)
    for k in range(5):
        x = s * (6.5755 + 1.1375 * k)
        # the mouth; corners are quarter ellipses, 0.19 across by 0.15 high
        prism(cut, [(u, v * 0.15 / 0.19) for u, v in rrect(0.521, 0.2 * 0.19 / 0.15, 0.19, 8, x, 0.64 * 0.19 / 0.15)], 9.36, 10.6, "hinge", XV)
        prism(cut, [(9.36, 0.5), (9.36, 0.455), (10.0, 0.393), (10.6, 0.393), (10.6, 0.5)], x - 0.33, x + 0.33, "hinge", XB)
# the headphone jack: a dark sleeve lines the case's hole, then the bore steps in and narrows to a point
JACK = Matrix(((0, 0, -1), (1, 0, 0), (0, 1, 0))), Vector((0, 3.5, Z0 + 0.746))


def at_jack(u, v, d):
    return tuple(JACK[1] + JACK[0] @ Vector((u, v, W / 2 - d)))


def wall_inset(z):
    return next(i0 + (i1 - i0) * (z - Z0 - z0) / (z1 - z0) for (i0, z0), (i1, z1) in zip(BASE, BASE[1:]) if z0 <= z - Z0 <= z1)


cut.loft([[at_jack(u, v, d) for u, v in rrect(r, r, r, 8)]
          for r, d in ((0.02, 1.39), (0.155, 1.25), (0.155, 0.91), (0.198, 0.91), (0.198, -1))], "bore")


def bore(g, pts, depth, chamfer, mat, basis, at):
    """a hole `depth` in from W / 2 through the side wall, its rim chamfered at 45 degrees"""
    wall = lambda q, dh: [tuple(at + basis @ Vector((u, v, W / 2 - wall_inset(at.z + v) + dh))) for u, v in q]
    flat = lambda q, h: [tuple(at + basis @ Vector((u, v, h))) for u, v in q]
    rim = inflate(pts, 2 * chamfer)
    g.loft([flat(pts, W / 2 - depth), wall(pts, -chamfer), wall(rim, chamfer), flat(rim, W / 2 + 1)], mat)


# ports: (side, centre y, outline, depth, rim chamfer), all centred 7.446 mm above the bottom
stadium = lambda l, h, n=8: rrect(l / 2, h / 2, h / 2, n)
TB = stadium(0.839, 0.261)
HDMI = [(-0.7215, 0.243), (-0.7215, -0.091), (-0.6015, -0.211), (0.6015, -0.211), (0.7215, -0.091), (0.7215, 0.243)]
SD = rrect(1.13, 0.12, 0.05, 6)
HDMI_IN = [(-0.66, 0.185), (-0.66, -0.08), (-0.56, -0.175), (0.56, -0.175), (0.66, -0.08), (0.66, 0.185)]
PZ = Z0 + 0.7446
PORTS = [(-1, 8.126, stadium(1.734, 0.301), 0.105, 0.015), (-1, 6.2755, TB, 0.65, 0.01), (-1, 4.7875, TB, 0.65, 0.01),
         (1, 8.1265, HDMI, 0.28, 0.008), (1, 8.1265, HDMI_IN, 0.79, 0), (1, 6.2755, TB, 0.65, 0.01),
         (1, 3.8175, rrect(1.3285, 0.1255, 0.05, 6), 0.25, 0.01), (1, 3.76, SD, 1.49, 0), (1, 4.95, rrect(0.1, 0.12, 0.05, 6), 1.28, 0)]
tongues = []
for side, y, outline, depth, chamfer in PORTS:
    basis = Matrix(((0, 0, side), (1, 0, 0), (0, 1, 0)))  # u -> y, v -> z, height -> outward x
    at = Vector((0, y, PZ - 0.0686 if outline is HDMI or outline is HDMI_IN else PZ))
    if chamfer:
        bore(cut, outline, depth, chamfer, "alloy", basis, at)
    else:
        prism(cut, outline, W / 2 - depth, W / 2 + 1, "pin" if outline is SD else "port", basis, at)
    if outline is TB:
        # the blade's nose is chamfered and rounded in plan; the contacts start behind it
        blade = [(rrect(hw, hh, 0.012, 4), d) for hw, hh, d in ((0.289, 0.015, 0.196), (0.3, 0.03, 0.211), (0.314, 0.03, 0.22),
                                                                 (0.3225, 0.03, 0.24), (0.331, 0.03, 0.27), (0.3345, 0.03, 0.64))][::-1]
        tongues += [([(stadium(0.83, 0.25), 0.65), (stadium(0.83, 0.25), 0.64)], basis, at, "port"),
                    ([(stadium(0.56, 0.12), 0.64), (stadium(0.56, 0.12), 0.48)], basis, at, "port"), (blade, basis, at, "port"),
                    ([(rrect(0.3, 0.035, 0.01, 4), 0.497), (rrect(0.3, 0.035, 0.01, 4), 0.232)], basis, at, "pin")]
    elif outline is HDMI_IN:
        tongues.append(([(rrect(0.57, 0.04, 0.01, 4, 0, 0.005), d) for d in (0.79, 0.3)], basis, at, "port"))
    elif outline is SD:
        tongues += [([(rrect(0.07, 0.03, 0.005, 2, 0.232 * k - 0.95, -0.09), d) for d in (1.49, 1.0)], basis, at, "pin") for k in range(9)]
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
    cut.loft(rings(1.05, 1.05, 1.05, [(0, Z0 - 1), (0, Z0), (0.09, Z0 + 0.032)], 16, x, y), "alloy")
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
parts.loft([[at_jack(u, v, wall_inset(JACK[1].z + v) if d is None else d) for u, v in rrect(r, r, r, 8)]
            for r, d in ((0.1975, None), (0.179, None), (0.179, 0.91), (0.1975, 0.91), (0.1975, None))], "bore", cap=(False, False))
parts.loft(rings(PAD[0], PAD[1], PAD[2], [(0, ZT - 0.12), *[(i, ZT - 0.022 + z) for i, z in fillet(0.012, 0.012, 3)]],
                 16, PAD[3], PAD[4]), "pad")
# the feet are domed: (radius cm, mm below the case), measured
DOME = [(0.1, 1.61), (0.3, 1.6), (0.48, 1.57), (0.64, 1.54), (0.72, 1.49), (0.78, 1.4), (0.82, 1.29), (0.86, 1.09),
        (0.9, 0.82), (0.92, 0.55), (0.945, 0.12), (0.95, -0.4)]
for x, y in FEET:
    parts.loft(rings(0.95, 0.95, 0.95, [(0.95 - r, Z0 + 0.0001 - d / 10) for r, d in DOME], 16, x, y), "foot")
for x, y in [(sx * 14.44, sy * 9.85) for sx in (1, -1) for sy in (1, -1)]:
    parts.loft(rings(0.16, 0.16, 0.16, [(0, Z0 - 0.0005), (0, Z0 + 0.01)], 8, x, y), "port")
for sections, basis, at, mat in tongues:
    parts.loft([[tuple(at + basis @ Vector((u, v, W / 2 - d))) for u, v in outline] for outline, d in sections], mat)
# the magnetic charging port: an insulating face with five contacts
mag_basis, mag_at = Matrix(((0, 0, -1), (1, 0, 0), (0, 1, 0))), Vector((0, 8.126, PZ))
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
            keys.loft(rings(0.15, 0.035, 0.03, [(0, z - 0.002), (0, z + 0.024)], 4, cx, cy - 0.56), "keycap")
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
# (inset, cm behind the glass face), measured: a groove, a bead 0.4 mm proud, an alloy lip, the chamfered back edge
GASKET = [(0.124, 0.085), (0.111, 0.085), (0.11, -0.021), (0.106, -0.031), (0.102, -0.035), (0.098, -0.038), (0.09, -0.04),
          (0.074, -0.04), (0.066, -0.039), (0.062, -0.037), (0.058, -0.034), (0.054, -0.029), (0.051, 0.01)]
LIDP = GASKET + [(0.014, 0.01), (0.01, 0.012), (0.006, 0.016), (0.002, 0.024), (0, 0.035), (0, LIDH - 0.2)] + \
    [(i, LIDH - d) for i, d in [(0.002, 0.172), (0.006, 0.131), (0.014, 0.093), (0.03, 0.066), (0.05, 0.042), (0.07, 0.024),
                                (0.09, 0.015), (0.11, 0.009), (0.13, 0.004), (0.17, 0)]]
lid.loft(rings(W / 2, LD / 2, R, [(i, LZ + z) for i, z in LIDP], 32), ["gasket"] * (len(GASKET) - 1) + ["alloy"] * (len(LIDP) - len(GASKET)))
lid_obj = lid.obj("lid")
# the hinge end, (y, cm behind the glass face) measured shut: a matte chin outboard, a dark cover over an alloy
# flange in the middle, alloy knuckles between; the bead stops short of them
EDGE = clip_y(rrect(W / 2 - 0.045, LD / 2 - 0.045, R - 0.045, 32), 10.23)
CHIN = [(10.255, 0.09), (10.256, -0.01), (10.272, -0.026), (10.307, -0.023), (10.373, 0.016), (10.437, 0.038), (10.533, 0.055),
        (10.658, 0.05), (10.788, 0.008), (10.788, 0.09)]
COVER = [(10.468, 0.094), (10.468, -0.008), (10.624, -0.405), (10.639, -0.434), (10.658, -0.449), (10.685, -0.454), (10.715, -0.442),
         (10.715, 0.094)]
FLANGE = [(10.735, 0.144), (10.734, -0.383), (10.724, -0.465), (10.698, -0.545), (10.634, -0.649), (10.639, -0.663), (10.807, -0.634),
          (10.827, -0.507), (10.833, -0.42), (10.837, 0.144)]
KNUCKLE = [(10.468, 0.144), (10.468, -0.008), (10.524, -0.151), (10.408, -0.24), (10.361, -0.288), (10.324, -0.347), (10.306, -0.407),
           (10.306, -0.469), (10.321, -0.528), (10.351, -0.581), (10.397, -0.626), (10.449, -0.654), (10.51, -0.669), (10.626, -0.665),
           (10.807, -0.634), (10.827, -0.509), (10.837, -0.315), (10.838, 0.144)]
at = Vector((0, 0, LZ))
bead, chin, keep = Geo(), Geo(), Geo()
prism(bead, EDGE, LZ - 0.1, LZ + 0.06, "gasket")
boolean(lid_obj, "DIFFERENCE", bead.obj("bead"))
for s in (1, -1):
    prism(chin, CHIN, *sorted((s * 11.83, s * 15.6)), "gasket", XB, at)
prism(keep, EDGE, LZ - 0.1, LZ + 0.2, "gasket")
boolean(chin_obj := chin.obj("lid-chin"), "INTERSECT", keep.obj("keep"))
hinge = Geo()
prism(hinge, COVER, -10.25, 10.25, "cover", XB, at)
prism(hinge, FLANGE, -10.25, 10.25, "alloy", XB, at)
for s in (1, -1):
    prism(hinge, KNUCKLE, *sorted((s * 10.25, s * 11.83)), "alloy", XB, at)
hinge.obj("lid-hinge")

glass = Geo()
GP = [(0.013, LZ), (0.009, LZ + 0.001), (0.005, LZ + 0.005), (0, LZ + 0.009), (0, LZ + 0.085)]
glass.loft([[(x, y, z) for x, y in rrect(15.385 - i, 10.4695 - i, (0.25 - i, 0.25 - i, R - 0.124 - i, R - 0.124 - i), 32, 0, -0.2355)]
            for i, z in GP], "glass")
prism(glass, rrect(11.83, 0.111, 0.001, 1, 0, 10.332), LZ, LZ + 0.085, "glass")  # the border reaches further between the knuckles
glass.obj("lid-glass")

SX, SY0, SY1 = 15.05, -10.365, 9.468  # the panel: 30.10 x 19.83, its top edge at the lid's front
SH, SA, SN = (SY1 - SY0) / 2, 1.0, 3.6  # superellipse corners: size, exponent
sgn = lambda c: math.copysign(1, c)
outline = [(sgn(c) * (SX - SA + SA * abs(c) ** (2 / SN)), (SY0 + SY1) / 2 + sgn(s) * (SH - SA + SA * abs(s) ** (2 / SN)))
           for c, s in ((math.cos(t), math.sin(t)) for t in (2 * math.pi * k / 128 for k in range(128)))]
screen = Geo()
screen.face(screen.add([(x, y, LZ - 0.0002) for x, y in outline])[::-1], "screen")
screen.uv = lambda p: ((p.x + SX) / (2 * SX), (SY1 - p.y) / (SY1 - SY0))
screen.obj("lid-screen", closed=False)

cam = Geo()
PY = -9.89
for pts, z, mat in [(rrect(0.585, 0.32, 0.32, 12, 0, PY), LZ - 0.0003, "glass"),
                    (rrect(0.0875, 0.0875, 0.0875, 12, 0.2725, PY), LZ - 0.0004, "lens")]:
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


def adopt_normals(me, src):
    """corners of me lying on src's surface and facing its way take src's interpolated normal"""
    src.calc_loop_triangles()
    tris = src.loop_triangles
    tree = BVHTree.FromPolygons([v.co for v in src.vertices], [t.vertices for t in tris])
    out = [c.vector.copy() for c in me.corner_normals]
    for p in me.polygons:
        for li in p.loop_indices:
            co = me.vertices[me.loops[li].vertex_index].co
            hit, fn, i, d = tree.find_nearest(co)
            if hit and d < 1e-4 and fn.dot(p.normal) > 0.98:
                t = tris[i]
                out[li] = geometry.barycentric_transform(hit, *(src.vertices[v].co for v in t.vertices),
                                                         *(src.corner_normals[l].vector for l in t.loops)).normalized()
    me.normals_split_custom_set(out)


adopt_normals(base_obj.data, skin.data)
bpy.data.objects.remove(skin)
for o in scene.objects:
    print(f"model.py: {o.name:12s} {sum(len(p.vertices) - 2 for p in o.data.polygons):7d} tris")
bpy.ops.export_scene.gltf(filepath=OUT, export_format="GLB", export_yup=True, export_apply=True)
