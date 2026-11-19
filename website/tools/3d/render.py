# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

# blender -b --factory-startup -P tools/3d/render.py -- --glb laptop.glb --screen mock/screen-spaces.jpg --out DIR
#   [--shots side,closed,glow,three-quarter,seq,seq@N] [--samples 128] [--height 1080] [--frames 120]
#   [--map roles.json] [--lid REGEX] [--rest-angle DEG] [--turn DEG] [--flip-uv 0|1]
# Any laptop glTF works: it is turned by --turn, scaled to 31.26 cm wide and set on the floor, and its
# materials are given roles by name (printed; --map {"regex": "role"|"keep"} overrides). Objects matching
# --lid swing about a hinge found at their lowest back edge; --rest-angle is the lid's angle in the file.
# Cycles studio for the laptop: black sweep, softbox strips, the CC0 studio HDRI, a screen whose spill is neutral.
# Units are cm (1 BU = 1 cm); poses use mock/laptop.js's orbit (az, el, dist, y, z, fov) in its Y-up space.
import argparse, json, math, os, re, sys
import bpy, bmesh
from mathutils import Vector

HERE = os.path.dirname(os.path.abspath(__file__))
HDRI = os.path.join(HERE, "../../mock/env/studio_small_09_1k.hdr")

a = argparse.ArgumentParser()
a.add_argument("--glb", required=True)
a.add_argument("--screen", required=True)
a.add_argument("--out", required=True)
a.add_argument("--shots", default="side,closed,glow,three-quarter,seq")
a.add_argument("--samples", type=int, default=128)
a.add_argument("--height", type=int, default=1080)
a.add_argument("--frames", type=int, default=120)
a.add_argument("--map")
a.add_argument("--lid", default=r"^(lid|display|screen|top)")
a.add_argument("--rest-angle", type=float, default=0)
a.add_argument("--turn", type=float, default=0)
a.add_argument("--flip-uv", type=int, default=1, help="1 for mock/'s export, whose V runs the other way")
args = a.parse_args(sys.argv[sys.argv.index("--") + 1:])

# linear base colour, roughness, HDRI strength
FINISHES = {"black": ((0.026, 0.027, 0.03), 0.34, 0.15), "silver": ((0.62, 0.63, 0.64), 0.3, 0.6)}

# name: (finish, aspect w:h, pose); lid in degrees, glow scales the screen's spill
SHOTS = {
    "side": ("silver", 2600 / 520, dict(lid=0, glow=0, az=-1.5708, el=0.015, dist=92, y=0.8, z=0, fov=4)),
    "closed": ("black", 2200 / 900, dict(lid=0, glow=0, az=0, el=0.165, dist=82, y=0.8, z=0, fov=12)),
    "glow": ("black", 2220 / 1120, dict(lid=30, glow=0.8, az=0, el=0.19, dist=85, y=4.5, z=0, fov=14)),
    "three-quarter": ("silver", 720 / 540, dict(lid=110, glow=0.7, az=-0.85, el=0.3, dist=100, y=5, z=-2, fov=18)),
}

lerp = lambda a, b, t: a + (b - a) * t
smooth = lambda t: (lambda c: c * c * (3 - 2 * c))(min(1, max(0, t)))


def hero(p):
    """mock/laptop.js SHOTS.hero with its lid curve, p = scroll 0..1"""
    o = smooth(p / 0.75)
    return dict(lid=lerp(9, 108, o), glow=lerp(0.8, 0.7, o), az=0, el=lerp(0.42, 0.06, smooth(p)), dist=lerp(95, 58, smooth(p)), y=lerp(0, 10, o), z=lerp(4, -1, o), fov=26)


bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene
scene.render.engine = "CYCLES"
prefs = bpy.context.preferences.addons["cycles"].preferences
prefs.compute_device_type = "METAL"
prefs.get_devices()
for d in prefs.devices:
    d.use = True
scene.cycles.device = "GPU"
scene.cycles.samples = args.samples
scene.cycles.use_denoising = True
scene.render.use_persistent_data = True
scene.view_settings.view_transform = "AgX"
scene.view_settings.look = "AgX - Medium High Contrast"
scene.render.image_settings.file_format = "PNG"


def nodes(mat):
    mat.use_nodes = True
    t = mat.node_tree
    t.nodes.clear()
    return t, t.nodes.new("ShaderNodeOutputMaterial")


def principled(name, color, rough, metal=0.0, coat=0.0):
    m = bpy.data.materials.new(name)
    t, out = nodes(m)
    b = t.nodes.new("ShaderNodeBsdfPrincipled")
    b.inputs["Base Color"].default_value = (*color, 1)
    b.inputs["Roughness"].default_value = rough
    b.inputs["Metallic"].default_value = metal
    b.inputs["Coat Weight"].default_value = coat
    t.links.new(b.outputs[0], out.inputs[0])
    return m, b


# the HDRI on a dome the camera can't see, light-linked below so it lights and reflects in the laptop only
scene.world = bpy.data.worlds.new("black")
scene.world.color = (0, 0, 0)
bpy.ops.mesh.primitive_uv_sphere_add(radius=2500, segments=64, ring_count=32)
dome = bpy.context.object
dome.visible_camera = False
dm = bpy.data.materials.new("hdri")
t, out = nodes(dm)
env = t.nodes.new("ShaderNodeTexEnvironment")
env.image = bpy.data.images.load(HDRI)
bg = t.nodes.new("ShaderNodeEmission")
t.links.new(t.nodes.new("ShaderNodeTexCoord").outputs["Object"], env.inputs["Vector"])
t.links.new(env.outputs[0], bg.inputs[0])
t.links.new(bg.outputs[0], out.inputs[0])
dome.data.materials.append(dm)

# the sweep and panels turn with the camera's azimuth, so every shot sees the same studio
rig = bpy.data.objects.new("rig", None)
scene.collection.objects.link(rig)

# sweep: flat floor running into a curve up behind the laptop
bm = bmesh.new()
prof = [(y, 0.0) for y in range(-400, 120, 40)] + [(120 + 150 * math.sin(i / 16 * math.pi / 2), 150 - 150 * math.cos(i / 16 * math.pi / 2)) for i in range(1, 17)] + [(270, 300)]
rows = [[bm.verts.new((x, y, z)) for x in (-3000, 3000)] for y, z in prof]
for r0, r1 in zip(rows, rows[1:]):
    bm.faces.new((r0[0], r0[1], r1[1], r1[0]))
me = bpy.data.meshes.new("sweep")
bm.to_mesh(me)
sweep = bpy.data.objects.new("sweep", me)
scene.collection.objects.link(sweep)
sweep.parent = rig
for p in me.polygons:
    p.use_smooth = True
# a dark gloss that keeps 15% of what it reflects; the panels don't light it, so only the screen's spill shows
floor, floor_b = principled("floor", (0.12, 0.12, 0.12), 0.3)
ft = floor.node_tree
fmix, fblack = ft.nodes.new("ShaderNodeMixShader"), ft.nodes.new("ShaderNodeEmission")
fmix.inputs[0].default_value = 0.15
fblack.inputs["Strength"].default_value = 0
ft.links.new(fblack.outputs[0], fmix.inputs[1])
ft.links.new(floor_b.outputs[0], fmix.inputs[2])
ft.links.new(fmix.outputs[0], ft.nodes["Material Output"].inputs[0])
sweep.data.materials.append(floor)


def panel(name, size, at, aim, radiance, fade=0.0, soft=0.0):
    """a one-sided softbox of size (w, h) cm at `at` facing `aim`, unseen by the camera; fade darkens it towards its bottom
    edge, soft ramps its outer `soft` fraction to black on every side"""
    bm = bmesh.new()
    vs = [bm.verts.new((x * size[0] / 2, y * size[1] / 2, 0)) for x, y in ((-1, -1), (1, -1), (1, 1), (-1, 1))]
    f = bm.faces.new(vs)
    uv = bm.loops.layers.uv.new()
    for loop, (u, v) in zip(f.loops, ((0, 0), (1, 0), (1, 1), (0, 1))):
        loop[uv].uv = (u, v)
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    m = bpy.data.materials.new(name)
    t, out = nodes(m)
    em, front, grad = t.nodes.new("ShaderNodeEmission"), t.nodes.new("ShaderNodeMath"), t.nodes.new("ShaderNodeMath")
    front.operation, grad.operation = "SUBTRACT", "MULTIPLY_ADD"
    front.inputs[0].default_value = radiance
    t.links.new(t.nodes.new("ShaderNodeNewGeometry").outputs["Backfacing"], front.inputs[1])
    sep = t.nodes.new("ShaderNodeSeparateXYZ")
    t.links.new(t.nodes.new("ShaderNodeTexCoord").outputs["UV"], sep.inputs[0])
    t.links.new(sep.outputs["Y"], grad.inputs[0])
    grad.inputs[1].default_value, grad.inputs[2].default_value = fade, 1 - fade
    mul = t.nodes.new("ShaderNodeMath")
    mul.operation = "MULTIPLY"
    t.links.new(front.outputs[0], mul.inputs[0])
    t.links.new(grad.outputs[0], mul.inputs[1])
    if soft:
        for axis in "XY":
            # min(1, u(1-u) / (soft(1-soft))): 1 inside the margin, ramping to 0 at the edge
            inv, edge, win = (t.nodes.new("ShaderNodeMath") for _ in range(3))
            inv.operation, edge.operation, win.operation = "SUBTRACT", "MULTIPLY", "MINIMUM"
            inv.inputs[0].default_value = 1
            t.links.new(sep.outputs[axis], inv.inputs[1])
            t.links.new(sep.outputs[axis], edge.inputs[0])
            t.links.new(inv.outputs[0], edge.inputs[1])
            scale = t.nodes.new("ShaderNodeMath")
            scale.operation = "DIVIDE"
            t.links.new(edge.outputs[0], scale.inputs[0])
            scale.inputs[1].default_value = soft * (1 - soft)
            t.links.new(scale.outputs[0], win.inputs[0])
            win.inputs[1].default_value = 1
            prev, mul = mul, t.nodes.new("ShaderNodeMath")
            mul.operation = "MULTIPLY"
            t.links.new(prev.outputs[0], mul.inputs[0])
            t.links.new(win.outputs[0], mul.inputs[1])
    t.links.new(mul.outputs[0], em.inputs["Strength"])
    t.links.new(em.outputs[0], out.inputs[0])
    me.materials.append(m)
    o = bpy.data.objects.new(name, me)
    o.location = at
    o.rotation_euler = (Vector(aim) - Vector(at)).to_track_quat("Z", "Y").to_euler()
    o.visible_camera = False
    o.parent = rig
    scene.collection.objects.link(o)


panel("top", (70, 30), (0, 10, 75), (0, 0, 0), 1.2)
panel("back", (100, 40), (0, 70, 40), (0, 0, 2), 1.5, fade=1.0)
panel("key", (14, 70), (-70, -45, 35), (0, 0, 0), 1.0, soft=0.3)
panel("rim", (14, 70), (75, 30, 30), (0, 0, 0), 0.8, soft=0.3)
panel("front", (44, 16), (0, -20, 0.3), (0, -20, 10), 0.5, soft=0.15)

before = set(bpy.data.objects)
bpy.ops.import_scene.gltf(filepath=args.glb)
laptop = bpy.data.collections.new("laptop")
scene.collection.children.link(laptop)
for o in set(bpy.data.objects) - before:
    laptop.objects.link(o)
for o in before:
    if o.type == "MESH" and o is not sweep:
        o.light_linking.receiver_collection = laptop
new = set(bpy.data.objects) - before
roots = [o for o in new if o.parent not in new]
model = bpy.data.objects.new("model", None)
laptop.objects.link(model)
for o in roots:
    o.parent = model
model.rotation_euler.z = math.radians(args.turn)


def verts(objs):
    bpy.context.view_layer.update()
    return [o.matrix_world @ v.co for o in objs if o.type == "MESH" for v in o.data.vertices]


# 31.26 cm wide, centred, feet on the floor
vs = verts(new)
model.scale *= 31.26 / (max(v.x for v in vs) - min(v.x for v in vs))
vs = verts(new)
model.location -= Vector(((max(v.x for v in vs) + min(v.x for v in vs)) / 2, (max(v.y for v in vs) + min(v.y for v in vs)) / 2, min(v.z for v in vs)))

# the hinge: the lid's lowest verts, at their back
lids = [o for o in new if re.search(args.lid, o.name, re.I) and not (o.parent and re.search(args.lid, o.parent.name, re.I))]
hinge = bpy.data.objects.new("hinge", None)
laptop.objects.link(hinge)
if lids:
    vs = verts({d for o in lids for d in [o, *o.children_recursive]})
    low = min(v.z for v in vs)
    hinge.location = (0, max(v.y for v in vs if v.z < low + 0.3), low)
    bpy.context.view_layer.update()
    for o in lids:
        m = o.matrix_world.copy()
        o.parent = hinge
        o.matrix_world = m
else:
    print("render.py: no object matches --lid; the lid stays at its rest angle")

# roles by material name: mock/'s exact names first, then common names in downloaded models
ROLES = [(r"^(well|grille|port|foot|hinge|glass|scoop|alloy|recess|pad|keycap|screen)$", None),
         (r"bezel", "glass"), (r"screen|display|lcd", "screen"), (r"glass", "glass"),
         (r"alumin|metal|body|chassis|case|shell|silver|space.?(gr[ae]y|black)|anodi", "alloy"),
         (r"keycap|keys?\b|key_|button", "keycap"), (r"feet|foot|rubber", "foot"), (r"trackpad|touchpad", "pad"),
         (r"hinge", "hinge"), (r"grill|speaker", "grille"), (r"port|jack|usb|hdmi|magsafe", "port")]
if args.map:
    ROLES = list(json.load(open(args.map)).items()) + ROLES
# a downloaded model's own textures win for these roles
TEXTURED = {"keycap", "foot", "grille", "port", "pad"}

alloy, alloy_b = principled("alloy", (0.5, 0.5, 0.5), 0.3, metal=1.0)
recess, recess_b = principled("recess", (0.2, 0.2, 0.2), 0.45, metal=1.0)
pad, pad_b = principled("pad", (0.5, 0.5, 0.5), 0.22, metal=1.0)
SIMPLE = {
    "well": principled("well", (0.004, 0.004, 0.004), 0.7)[0],
    "keycap": principled("keycap", (0.008, 0.008, 0.009), 0.5)[0],
    "grille": principled("grille", (0.003, 0.003, 0.003), 0.9)[0],
    "port": principled("port", (0.002, 0.002, 0.002), 0.6)[0],
    "foot": principled("foot", (0.01, 0.01, 0.01), 0.85)[0],
    "hinge": principled("hinge", (0.015, 0.015, 0.016), 0.4, metal=1.0)[0],
    "glass": principled("glass", (0.002, 0.002, 0.002), 0.04, coat=1.0)[0],
    "scoop": recess,
    "alloy": alloy,
    "recess": recess,
    "pad": pad,
}

def flip_v(t, tex):
    """glTF's V runs down the image, three.js's up"""
    m = t.nodes.new("ShaderNodeMapping")
    m.inputs["Location"].default_value[1] = 1
    m.inputs["Scale"].default_value[1] = -1
    t.links.new(t.nodes.new("ShaderNodeTexCoord").outputs["UV"], m.inputs["Vector"])
    t.links.new(m.outputs[0], tex.inputs["Vector"])


# mock/'s legends: the imported unlit material's image, as grey print rather than light
legend = bpy.data.materials.get("legend")
if legend:
    img = next(n.image for n in legend.node_tree.nodes if n.type == "TEX_IMAGE")
    lm, lb = principled("legend-print", (0.35, 0.35, 0.37), 0.5)
    lt = lm.node_tree
    tex = lt.nodes.new("ShaderNodeTexImage")
    tex.image = img
    flip_v(lt, tex)
    lt.links.new(tex.outputs["Alpha"], lb.inputs["Alpha"])
    SIMPLE["legend"] = lm
    ROLES.insert(0, (r"^legend$", "legend"))

# screen: the capture to the camera, a neutral white-grey to everything it lights; glossy glass on top
sm, sb = principled("screen-glass", (0, 0, 0), 0.05)
sb.inputs["Specular IOR Level"].default_value = 0.05
st = sm.node_tree
stex = st.nodes.new("ShaderNodeTexImage")
stex.image = bpy.data.images.load(os.path.abspath(args.screen))
if args.flip_uv:
    flip_v(st, stex)
spath = st.nodes.new("ShaderNodeLightPath")
smix = st.nodes.new("ShaderNodeMix")
smix.data_type = "RGBA"
st.links.new(spath.outputs["Is Camera Ray"], smix.inputs["Factor"])
st.links.new(stex.outputs["Color"], smix.inputs["B"])
smix.inputs["A"].default_value = (0.89, 0.9, 0.92, 1)
st.links.new(smix.outputs["Result"], sb.inputs["Emission Color"])
strength = st.nodes.new("ShaderNodeMath")
strength.operation = "MULTIPLY_ADD"
st.links.new(spath.outputs["Is Camera Ray"], strength.inputs[0])
st.links.new(strength.outputs[0], sb.inputs["Emission Strength"])
SIMPLE["screen"] = sm

def role(m):
    name = m.name.split(".")[0]
    r = next((r or name for p, r in ROLES if re.search(p, name, re.I)), None)
    textured = m.node_tree and any(n.type == "TEX_IMAGE" for n in m.node_tree.nodes)
    return None if r == "keep" or (r in TEXTURED and textured and name != r) else r


mapped = {}
for o in new:
    for s in o.material_slots if o.type == "MESH" else ():
        if s.material and s.material.name not in mapped:
            mapped[s.material.name] = role(s.material)
        if s.material and mapped[s.material.name]:
            s.material = SIMPLE[mapped[s.material.name]]
for k, v in sorted(mapped.items()):
    print(f"render.py: material {k!r} -> {v or 'kept as imported'}")

cam = bpy.data.objects.new("cam", bpy.data.cameras.new("cam"))
scene.collection.objects.link(cam)
scene.camera = cam
cam.data.sensor_fit = "VERTICAL"
cam.data.clip_start, cam.data.clip_end = 1, 3000


def pose(finish, lid, glow, az, el, dist, y, z, fov):
    color, rough, light = FINISHES[finish]
    for b, k, r in ((alloy_b, 1, rough), (recess_b, 0.45, rough + 0.1), (pad_b, 1, rough - 0.08)):
        b.inputs["Base Color"].default_value = (*(c * k for c in color), 1)
        b.inputs["Roughness"].default_value = r
    bg.inputs["Strength"].default_value = light
    hinge.rotation_euler = (math.radians(args.rest_angle - lid), 0, 0)
    strength.inputs[1].default_value = 1 - glow  # camera rays see 1, spill rays see glow
    strength.inputs[2].default_value = glow
    # mock/laptop.js orbit in Y-up (x, y, z) -> Blender (x, -z, y)
    p = (dist * math.cos(el) * math.sin(az), y + dist * math.sin(el), z + dist * math.cos(el) * math.cos(az))
    rig.rotation_euler = (0, 0, az)
    cam.location = (p[0], -p[2], p[1])
    cam.rotation_euler = (Vector((0, -z, y)) - cam.location).to_track_quat("-Z", "Y").to_euler()
    cam.data.angle = math.radians(fov)


def shoot(path, aspect):
    scene.render.resolution_y = args.height
    scene.render.resolution_x = round(args.height * aspect / 2) * 2
    scene.render.filepath = path
    bpy.ops.render.render(write_still=True)


os.makedirs(args.out, exist_ok=True)
for name in filter(None, args.shots.split(",")):
    if name.startswith("seq@"):
        f = int(name[4:])
        pose("black", **hero(f / (args.frames - 1)))
        shoot(os.path.join(args.out, f"f{f:04d}.png"), 16 / 9)
    elif name == "seq":
        os.makedirs(os.path.join(args.out, "seq"), exist_ok=True)
        for f in range(args.frames):
            pose("black", **hero(f / (args.frames - 1)))
            shoot(os.path.join(args.out, "seq", f"f{f:04d}.png"), 16 / 9)
    else:
        finish, aspect, p = SHOTS[name]
        pose(finish, **p)
        shoot(os.path.join(args.out, f"{name}.png"), aspect)
