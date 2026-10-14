"""Pretty Studio — 3D device hero shot (Blender, headless).

    blender -b --factory-startup --python device_shot.py -- shot.json

Builds a modern phone procedurally (rounded titanium band, black glass, the app's screen as an
emissive video texture with a glossy coat, buttons, camera plateau), lights it like a product
studio (soft key, two rim strips, gentle fill, glossy reflections), animates a camera move, and
renders RGBA PNG frames with motion blur. The last frame is a straight-on pose whose screen height
matches `end_height` of the output, so the shot hands off seamlessly to the flat device.

shot.json:
  screen        path to the screen video (exact screen pixels, no bezel)
  screen_size   [w, h] pixels of that video
  out_dir       where frame_####.png go
  width, height output size; fps; frames
  move          hero | orbit | rise | tilt | spin | float | flat | dolly | closeup | macro | duo | slide | turntable
  focus         closeup: [x, y] point of the screen to move in on (0-1, top-left origin)
  screen2       duo: a second screen video for the device behind
  end_height    fraction of the output height the screen fills at the end (e.g. 0.62)
  end_center_y  fraction (0 top .. 1 bottom) of the screen centre at the end
  finish        black | natural | silver | white | blue | desert | gold
  screen_offset seconds into the screen video at frame 1
"""
import bpy, bmesh, json, math, sys
from mathutils import Vector

args = json.load(open(sys.argv[sys.argv.index("--") + 1]))
W, H = int(args["width"]), int(args["height"])
FPS, FRAMES = int(args.get("fps", 30)), int(args["frames"])
MOVE = args.get("move", "hero")
SW, SH = args["screen_size"]

# ---- scene -------------------------------------------------------------------------------------
bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene
scene.render.engine = "BLENDER_EEVEE"
scene.render.resolution_x, scene.render.resolution_y = W, H
scene.render.resolution_percentage = 100
scene.render.fps = FPS
scene.frame_start, scene.frame_end = 1, FRAMES
scene.render.film_transparent = True
# Motion blur samples the screen video at several moments; while the app scrolls that ghosts the UI.
# Crisp UI wins — blur only when asked.
scene.render.use_motion_blur = bool(args.get("motion_blur", False))
scene.render.motion_blur_shutter = 0.35
scene.eevee.taa_render_samples = int(args.get("samples", 48))
scene.eevee.use_raytracing = True
scene.eevee.use_shadows = True
scene.view_settings.view_transform = "Standard"
scene.view_settings.look = "None"
scene.render.image_settings.file_format = "PNG"
scene.render.image_settings.color_mode = "RGBA"
scene.render.image_settings.color_depth = "8"
scene.render.filepath = args["out_dir"].rstrip("/") + "/frame_"

# Studio world: dark with a soft gradient so glass and metal have something to reflect.
world = bpy.data.worlds.new("Studio"); scene.world = world
world.use_nodes = True
wn = world.node_tree.nodes; wl = world.node_tree.links
for n in list(wn): wn.remove(n)
out = wn.new("ShaderNodeOutputWorld")
bg = wn.new("ShaderNodeBackground")
grad = wn.new("ShaderNodeTexGradient"); grad.gradient_type = "SPHERICAL"
tc = wn.new("ShaderNodeTexCoord")
ramp = wn.new("ShaderNodeValToRGB")
ramp.color_ramp.elements[0].color = (0.004, 0.004, 0.005, 1)
ramp.color_ramp.elements[1].color = (0.12, 0.12, 0.13, 1)
wl.new(tc.outputs["Generated"], grad.inputs["Vector"])
wl.new(grad.outputs["Fac"], ramp.inputs["Fac"])
wl.new(ramp.outputs["Color"], bg.inputs["Color"])
bg.inputs["Strength"].default_value = 0.6
wl.new(bg.outputs["Background"], out.inputs["Surface"])

# ---- phone geometry (meters; an iPhone Pro is ~71.5 x 149.6 x 8.25 mm) -------------------------
aspect = SH / SW
TABLET = max(aspect, 1 / aspect) < 1.6  # iPad-shaped screens get iPad proportions
if TABLET:
    screen_w = 0.1785 if aspect >= 1 else 0.2485
    screen_h = screen_w * aspect
    band, depth, corner = 0.0072, 0.0058, 0.0185
else:
    screen_w = 0.0662
    screen_h = screen_w * aspect
    band, depth, corner = 0.0028, 0.0083, 0.0105
body_w, body_h = screen_w + band * 2, screen_h + band * 2
screen_corner = corner - band * 0.9

def rounded_outline(w, h, r, seg=16):
    pts = []
    for cx, cy, a0 in [(w / 2 - r, h / 2 - r, 0), (-w / 2 + r, h / 2 - r, 90), (-w / 2 + r, -h / 2 + r, 180), (w / 2 - r, -h / 2 + r, 270)]:
        for i in range(seg + 1):
            a = math.radians(a0 + 90 * i / seg)
            pts.append((cx + r * math.cos(a), cy + r * math.sin(a)))
    return pts

def slab(name, w, h, r, d, z0=0.0):
    me = bpy.data.meshes.new(name); ob = bpy.data.objects.new(name, me)
    bpy.context.collection.objects.link(ob)
    bm = bmesh.new()
    verts = [bm.verts.new((x, y, z0)) for x, y in rounded_outline(w, h, r)]
    face = bm.faces.new(verts)
    ext = bmesh.ops.extrude_face_region(bm, geom=[face])
    for v in [e for e in ext["geom"] if isinstance(e, bmesh.types.BMVert)]:
        v.co.z += d
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    bm.to_mesh(me); bm.free()
    for p in me.polygons: p.use_smooth = True
    return ob

FINISH = {"black": (0.018, 0.018, 0.02), "natural": (0.42, 0.39, 0.35), "silver": (0.7, 0.71, 0.72), "white": (0.86, 0.86, 0.87),
          "blue": (0.12, 0.17, 0.26), "desert": (0.55, 0.45, 0.36), "gold": (0.72, 0.6, 0.42)}.get(args.get("finish", "black"), (0.018, 0.018, 0.02))

def mat(name, color, metallic=0.0, rough=0.3, coat=0.0):
    m = bpy.data.materials.new(name); m.use_nodes = True
    b = m.node_tree.nodes.get("Principled BSDF")
    b.inputs["Base Color"].default_value = (*color, 1)
    b.inputs["Metallic"].default_value = metallic
    b.inputs["Roughness"].default_value = rough
    if "Coat Weight" in b.inputs: b.inputs["Coat Weight"].default_value = coat
    return m

metal = mat("Titanium", FINISH, metallic=1.0 if args.get("finish", "black") not in ("black", "white") else 0.85, rough=0.36)
glass_mat = mat("BlackGlass", (0.004, 0.004, 0.005), rough=0.04, coat=1.0)
cam_mat = mat("CamGlass", (0.02, 0.02, 0.022), rough=0.12, coat=1)
lens_mat = mat("Lens", (0.01, 0.01, 0.012), metallic=0.6, rough=0.08, coat=1)

def screen_material(name, path):
    sm = bpy.data.materials.new(name); sm.use_nodes = True
    nt = sm.node_tree; nodes = nt.nodes; links = nt.links
    for n in list(nodes): nodes.remove(n)
    mo = nodes.new("ShaderNodeOutputMaterial")
    img = bpy.data.images.load(path)
    img.source = "MOVIE"
    tex = nodes.new("ShaderNodeTexImage"); tex.image = img
    tex.image_user.frame_duration = FRAMES
    tex.image_user.frame_start = 1
    tex.image_user.frame_offset = int(round(float(args.get("screen_offset", 0)) * FPS))
    tex.image_user.use_auto_refresh = True
    emit = nodes.new("ShaderNodeEmission"); emit.inputs["Strength"].default_value = 1.0
    gloss = nodes.new("ShaderNodeBsdfGlossy"); gloss.inputs["Roughness"].default_value = 0.14
    fres = nodes.new("ShaderNodeFresnel"); fres.inputs["IOR"].default_value = 1.45
    # A whisper of reflection at most (glass, not a mirror): the UI must stay perfectly readable.
    scale = nodes.new("ShaderNodeMath"); scale.operation = "MULTIPLY"; scale.inputs[1].default_value = float(args.get("glare", 0.0))
    mix = nodes.new("ShaderNodeMixShader")
    links.new(tex.outputs["Color"], emit.inputs["Color"])
    links.new(fres.outputs["Fac"], scale.inputs[0])
    links.new(scale.outputs["Value"], mix.inputs["Fac"])
    links.new(emit.outputs["Emission"], mix.inputs[1])
    links.new(gloss.outputs["BSDF"], mix.inputs[2])
    links.new(mix.outputs["Shader"], mo.inputs["Surface"])
    return sm

def box(name, size, loc, material, r=0.0006, parent=None):
    b = slab(name, size[0], size[1], r, size[2], 0)
    b.location = loc; b.data.materials.append(material); b.parent = parent; return b

def build_device(tag, screen_path):
    root = bpy.data.objects.new("Device" + tag, None); bpy.context.collection.objects.link(root)
    body = slab("Body" + tag, body_w, body_h, corner, depth, -depth); body.parent = root
    bev = body.modifiers.new("Rim", "BEVEL"); bev.width = 0.0016; bev.segments = 6; bev.limit_method = "ANGLE"; bev.angle_limit = math.radians(40)
    body.data.materials.append(metal)
    glass = slab("FrontGlass" + tag, body_w - 0.0004, body_h - 0.0004, corner - 0.0002, 0.0004, -0.0001); glass.parent = root
    glass.data.materials.append(glass_mat)
    scr = slab("Screen" + tag, screen_w, screen_h, screen_corner, 0.00005, 0.0003); scr.parent = root
    me = scr.data
    me.uv_layers.new(name="UV")
    uv = me.uv_layers["UV"].data
    for poly in me.polygons:
        for li in poly.loop_indices:
            co = me.vertices[me.loops[li].vertex_index].co
            uv[li].uv = ((co.x + screen_w / 2) / screen_w, (co.y + screen_h / 2) / screen_h)
    me.materials.append(screen_material("Screen" + tag, screen_path))
    if TABLET:
        box("Top" + tag, (0.02, 0.0012, 0.0022), (body_w * 0.32, body_h / 2 + 0.0005, -depth * 0.55), metal, parent=root)
        plateau = box("Camera" + tag, (0.02, 0.02, 0.0012), (-body_w / 2 + 0.016, body_h / 2 - 0.016, -depth - 0.0011), cam_mat, r=0.005, parent=root)
        lenses = [(0.0, 0.0)]
    else:
        for nm, sz, y in [("Action", 0.006, 0.28), ("VolUp", 0.0095, 0.18), ("VolDown", 0.0095, 0.1)]:
            box(nm + tag, (0.0012, sz, 0.0022), (-body_w / 2 - 0.0005, body_h * y, -depth * 0.6), metal, parent=root)
        box("Power" + tag, (0.0012, 0.016, 0.0022), (body_w / 2 + 0.0005, body_h * 0.16, -depth * 0.6), metal, parent=root)
        plateau = box("Camera" + tag, (0.03, 0.032, 0.0018), (-body_w / 2 + 0.019, body_h / 2 - 0.019, -depth - 0.0017), cam_mat, r=0.006, parent=root)
        lenses = [(-0.0065, 0.0068), (-0.0065, -0.0068), (0.0068, 0.0)]
    for (dx, dy) in lenses:
        bpy.ops.mesh.primitive_cylinder_add(radius=0.0048 if not TABLET else 0.004, depth=0.0016,
                                            location=(plateau.location.x + dx, plateau.location.y + dy, -depth - 0.0028))
        lens = bpy.context.object; lens.data.materials.append(lens_mat); lens.parent = root
    return root

phone = build_device("", args["screen"])
second = build_device("2", args["screen2"]) if args.get("screen2") else None

# ---- lights ------------------------------------------------------------------------------------
def area(name, loc, rot, size, energy, color=(1, 1, 1), shape="RECTANGLE", sy=None):
    l = bpy.data.lights.new(name, "AREA"); l.energy = energy; l.color = color; l.shape = shape
    l.size = size
    if sy: l.size_y = sy
    o = bpy.data.objects.new(name, l); o.location = loc; o.rotation_euler = rot
    bpy.context.collection.objects.link(o); return o
area("Key", (-0.25, 0.32, 0.38), (math.radians(-38), math.radians(-28), 0), 0.6, 30)
area("RimL", (-0.3, 0.0, -0.1), (0, math.radians(-110), 0), 0.04, 30, sy=0.6)
area("RimR", (0.3, 0.05, -0.1), (0, math.radians(110), 0), 0.04, 30, sy=0.6)
area("Fill", (0.25, -0.2, 0.45), (math.radians(25), math.radians(28), 0), 0.5, 10)
# A long strip above the camera: the hero glint that slides across the glass as the phone turns.
area("Glint", (0.0, 0.18, 0.32), (math.radians(-30), 0, 0), 0.8, 6, sy=0.02)

# ---- camera + move -----------------------------------------------------------------------------
cam_data = bpy.data.cameras.new("Cam"); cam_data.lens = 85; cam_data.sensor_fit = "VERTICAL"; cam_data.sensor_height = 24
cam = bpy.data.objects.new("Cam", cam_data); bpy.context.collection.objects.link(cam); scene.camera = cam
# Distance so the screen fills end_height of the frame, straight on.
end_h = float(args.get("end_height", 0.62))
vfov = 2 * math.atan(cam_data.sensor_height / 2 / cam_data.lens)
dist = (screen_h / end_h) / (2 * math.tan(vfov / 2))
# Vertical framing: shift the phone so its screen centre lands at end_center_y.
cy = float(args.get("end_center_y", 0.5))
frame_h_world = 2 * dist * math.tan(vfov / 2)
phone_y_end = (cy - 0.5) * frame_h_world  # positive = lower on screen → move phone down (negative y)
cam.location = (0, 0, dist)
cam.rotation_euler = (0, 0, 0)

def key(obj, frame, loc=None, rot=None):
    if loc is not None: obj.location = loc; obj.keyframe_insert("location", frame=frame)
    if rot is not None: obj.rotation_euler = rot; obj.keyframe_insert("rotation_euler", frame=frame)

end_loc = (0, -phone_y_end, 0)
F = FRAMES
r = math.radians
if MOVE == "orbit":
    key(phone, 1, (0.01, -phone_y_end - 0.006, -0.02), (r(6), r(-28), r(-3)))
    key(phone, int(F * 0.7), end_loc, (0, r(-4), 0)); key(phone, F, end_loc, (0, 0, 0))
elif MOVE == "rise":
    key(phone, 1, (0, -phone_y_end - 0.14, -0.05), (r(-38), r(10), 0))
    key(phone, int(F * 0.78), end_loc, (r(2), 0, 0)); key(phone, F, end_loc, (0, 0, 0))
elif MOVE == "tilt":
    key(phone, 1, (0, -phone_y_end + 0.01, -0.03), (r(-24), r(18), r(4)))
    key(phone, int(F * 0.8), end_loc, (0, 0, 0)); key(phone, F, end_loc, (0, 0, 0))
elif MOVE == "spin":
    key(phone, 1, (0, -phone_y_end, -0.04), (r(4), r(-200), 0))
    key(phone, int(F * 0.82), end_loc, (0, r(-2), 0)); key(phone, F, end_loc, (0, 0, 0))
elif MOVE == "float":
    key(phone, 1, (0.004, -phone_y_end - 0.004, 0), (r(4), r(-12), r(-2)))
    key(phone, F, end_loc, (r(1), r(-3), 0))
elif MOVE == "flat":
    # Lying on a surface, then standing up to face us.
    key(phone, 1, (0, -phone_y_end - 0.05, -0.06), (r(-78), 0, r(-18)))
    key(phone, int(F * 0.8), end_loc, (r(1), 0, 0)); key(phone, F, end_loc, (0, 0, 0))
elif MOVE == "dolly":
    # Straight on, from far away, a slow confident push.
    key(phone, 1, (0, -phone_y_end, -0.32), (r(2), r(-6), 0))
    key(phone, int(F * 0.85), end_loc, (0, 0, 0)); key(phone, F, end_loc, (0, 0, 0))
elif MOVE == "slide":
    key(phone, 1, (-0.12, -phone_y_end, -0.02), (r(3), r(24), r(2)))
    key(phone, int(F * 0.78), end_loc, (0, 0, 0)); key(phone, F, end_loc, (0, 0, 0))
elif MOVE == "turntable":
    key(phone, 1, end_loc, (r(4), r(-34), 0)); key(phone, F, end_loc, (r(2), r(14), 0))
elif MOVE == "closeup":
    # A macro pass over one part of the screen (shallow depth of field), pulling back to the full device.
    fx, fy = args.get("focus", [0.5, 0.4])
    px = -(fx - 0.5) * screen_w
    py = (fy - 0.5) * screen_h
    # The focus point sits on the camera axis while the device is close, then everything settles home.
    key(phone, 1, (px, py, dist * 0.6), (r(8), r(-12), r(-3)))
    key(phone, int(F * 0.55), (px * 0.8, py * 0.8, dist * 0.48), (r(3), r(-5), 0))
    key(phone, F, end_loc, (0, 0, 0))
    cam_data.dof.use_dof = True
    cam_data.dof.aperture_fstop = 2.8
    cam_data.dof.focus_object = phone
elif MOVE == "macro":
    # Push in from the full device to one detail (the payoff) and hold on it, depth of field falling off.
    fx, fy = args.get("focus", [0.5, 0.5])
    px = -(fx - 0.5) * screen_w
    py = (fy - 0.5) * screen_h
    key(phone, 1, end_loc, (0, 0, 0))
    key(phone, int(F * 0.62), (px * 0.95, py * 0.95, dist * 0.5), (r(2), r(-5), 0))
    key(phone, F, (px, py, dist * 0.53), (r(2), r(-6), 0))
    cam_data.dof.use_dof = True
    cam_data.dof.aperture_fstop = 3.2
    cam_data.dof.focus_object = phone
elif MOVE == "duo":
    # Two devices fanned: the main one turns into place while a second (another moment of the app)
    # settles behind and to the side.
    key(phone, 1, (0.02, -phone_y_end - 0.01, -0.03), (r(4), r(-26), r(-3)))
    key(phone, int(F * 0.8), end_loc, (0, 0, 0)); key(phone, F, end_loc, (0, 0, 0))
    if second:
        # Tucked behind and to the side so it peeks out even in a 9:16 frame.
        side = body_w * (0.5 if H > W else 0.75)
        key(second, 1, (side * 1.5, -phone_y_end + body_h * 0.05, -0.11), (r(2), r(-34), r(4)))
        key(second, F, (side, -phone_y_end + body_h * 0.04, -0.07), (0, r(-20), r(3)))
else:  # hero: a confident three-quarter turn that lands straight on, with a gentle push-in
    key(phone, 1, (0.012, -phone_y_end - 0.004, -0.045), (r(8), r(-38), r(-6)))
    key(phone, int(F * 0.8), end_loc, (r(0.5), r(-1.5), 0)); key(phone, F, end_loc, (0, 0, 0))
if second and MOVE != "duo":
    second.hide_render = True

bpy.ops.render.render(animation=True)
print("PRETTY_SHOT_DONE", FRAMES)
