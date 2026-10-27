# Renders what Claude needs to judge a scanned wheel: each wheel seen face-on at 500 px per metre with a 10 cm grid and
# the fitted circle and centre drawn over it (a circle that misses the tyre's edge means a nudge in wheel_scan.json),
# and, once wheels.py has built the game wheel, that wheel at several turns under flat light (any highlight that turns
# with it is baked light that wasn't averaged out).
# blender -b <scan.blend> --python wheel_inspect.py -- <wheelsDir>
import bpy, sys, os, json, math
import numpy as np
from mathutils import Vector

out = sys.argv[sys.argv.index('--') + 1]
fits = json.load(open(os.path.join(out, 'fits.json')))
PX_PER_M, SIZE = 500, 600
sc = bpy.context.scene
sc.render.engine = 'BLENDER_WORKBENCH'
sc.display.shading.color_type = 'TEXTURE'
sc.display.shading.light = 'FLAT'
sc.render.resolution_x = sc.render.resolution_y = SIZE
for o in bpy.data.objects:
    o.hide_render = 'usd_to_aligned' not in o   # only the scan
cam = bpy.data.objects.new('inspect_cam', bpy.data.cameras.new('inspect_cam')); sc.collection.objects.link(cam); sc.camera = cam
cam.data.type, cam.data.ortho_scale = 'ORTHO', SIZE / PX_PER_M


def render_to_array(path):
    sc.render.filepath = path
    bpy.ops.render.render(write_still=True)
    img = bpy.data.images.load(path)
    px = np.array(img.pixels[:], np.float32).reshape(SIZE, SIZE, 4)
    bpy.data.images.remove(img)
    return px


def save_array(px, path):
    img = bpy.data.images.new(os.path.basename(path), SIZE, SIZE)
    img.pixels = px.ravel(); img.filepath_raw = path; img.file_format = 'PNG'; img.save()
    bpy.data.images.remove(img)


for name, fit in fits.items():
    centre, axle = Vector(fit['centre']), Vector(fit['axle'])
    cam.location = centre + axle * 3
    cam.rotation_euler = (-axle).to_track_quat('-Z', 'Z').to_euler()
    path = os.path.join(out, f'check_{name}.png')
    px = render_to_array(path)
    yy, xx = np.mgrid[0:SIZE, 0:SIZE] - SIZE / 2 + 0.5
    grid = (np.abs((xx % 50) - 25) > 24.5) | (np.abs((yy % 50) - 25) > 24.5)   # every 10 cm
    px[grid] = px[grid] * 0.6 + np.array([0.6, 0.6, 1.0, 1.0]) * 0.4
    ring = np.abs(np.hypot(xx, yy) - fit['radius'] * PX_PER_M) < 1.2
    cross = ((np.abs(xx) < 1) | (np.abs(yy) < 1)) & (np.hypot(xx, yy) < 15)
    px[ring | cross] = (1.0, 0.1, 0.6, 1.0)
    save_array(px, path)
    print('CHECK', name, path)

# The finished game wheel, turned 0/30/60/90 degrees under flat light.
glb = os.path.join(out, 'wheel.glb')
if os.path.exists(glb):
    for o in bpy.data.objects: o.hide_render = True
    bpy.ops.import_scene.gltf(filepath=glb)
    wheel = bpy.context.selected_objects[0]
    wheel.hide_render = False; wheel.location = (0, 0, 20)
    wheel.rotation_mode = 'XYZ'   # the glTF importer leaves objects on quaternions, which ignore rotation_euler
    cam.location = wheel.location + Vector((3, 0, 0))
    cam.rotation_euler = Vector((-1, 0, 0)).to_track_quat('-Z', 'Z').to_euler()
    for deg in (0, 30, 60, 90):
        wheel.rotation_euler = (math.radians(deg), 0, 0)
        sc.render.filepath = os.path.join(out, f'spin_{deg}.png'); bpy.ops.render.render(write_still=True)
    print('SPIN renders in', out)
