# Renders a .glb from five angles with its texture, for checking a scan by eye: blender -b --python preview.py -- <file.glb> <outPrefix>
import bpy, sys, math
from mathutils import Vector
glb, out = sys.argv[sys.argv.index('--') + 1:][:2]
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=glb)
sc = bpy.context.scene
sc.render.engine = 'BLENDER_WORKBENCH'
sc.display.shading.color_type = 'TEXTURE'
sc.display.shading.light = 'STUDIO'
sc.render.resolution_x, sc.render.resolution_y = 800, 500
sc.display.shading.background_type = 'VIEWPORT'; sc.display.shading.background_color = (0.55, 0.6, 0.65)
cam = bpy.data.objects.new('cam', bpy.data.cameras.new('cam')); sc.collection.objects.link(cam); sc.camera = cam
cam.data.lens = 50
tgt = Vector((0, 0, 0.6))
for i, (az, el) in enumerate([(35, 20), (145, 20), (-90, 5), (-35, 45), (0, 0)]):
    a, e = math.radians(az), math.radians(el)
    cam.location = tgt + Vector((math.cos(a) * math.cos(e), math.sin(a) * math.cos(e), math.sin(e))) * 8.5
    cam.rotation_euler = (tgt - cam.location).to_track_quat('-Z', 'Y').to_euler()
    sc.render.filepath = f'{out}_{i}.png'
    bpy.ops.render.render(write_still=True)
