# Copies the processed body into the game as blender/<car>/<car>.glb + .blend, nose turned to +X like the other car bodies.
# blender -b <work>/body/car_body.blend --python export.py -- <work>/body <repo>/blender/<car> <car>
import bpy, math, sys
from mathutils import Matrix
body, dst, name = sys.argv[sys.argv.index('--') + 1:][:3]
o = bpy.data.objects['car_body']
for x in list(bpy.data.objects):
    if x is not o: bpy.data.objects.remove(x)   # the scan and any hand-made source mesh
o.data.transform(Matrix.Rotation(math.radians(-90), 4, "Z"))
o.name = o.data.name = f'{name}_body'
img = bpy.data.images['car_body_texture']
img.source = 'FILE'; img.filepath = f'{body}/car_body_texture.png'; img.reload(); img.pack()
bpy.ops.object.select_all(action='DESELECT'); o.select_set(True)
bpy.ops.export_scene.gltf(filepath=f'{dst}/{name}.glb', use_selection=True, export_format='GLB')
bpy.ops.outliner.orphans_purge(do_recursive=True)
bpy.context.preferences.filepaths.save_version = 0
bpy.ops.wm.save_as_mainfile(filepath=f'{dst}/{name}.blend')
