# Textures a body modelled by hand over the scan: cuts its wheel arches and paints it from the scan or the paint video.
# blender -b <scan.blend> --python texture.py -- <outDir> --body <object> [--scan <object>] [--paint-poses P --paint-frames F] [...]
# The body must sit exactly over the scan as saved (levelled, origin midway between the axles); its modifiers are applied.
import bpy, sys, os, argparse
import numpy as np
from mathutils import Matrix
sys.path.append(os.path.dirname(os.path.abspath(__file__)))
import texturing

ap = argparse.ArgumentParser(prog='texture.py')
ap.add_argument('out')
ap.add_argument('--body', required=True, help='the hand-made low-poly body object')
ap.add_argument('--scan', help='the scan object (default: the one carrying the camera link)')
ap.add_argument('--wheel-radius', type=float, default=0.31)
ap.add_argument('--cut-radius', type=float, default=0.35)
ap.add_argument('--wheel-values', help='fits.json from wheels.py: measured wheel positions and radius, overriding the two above')
ap.add_argument('--cut-inner', type=float, default=0.55)
ap.add_argument('--glass-min-z', type=float, default=0.8)
ap.add_argument('--tex-size', type=int, default=1024)
ap.add_argument('--paint-poses'); ap.add_argument('--paint-frames')
args = ap.parse_args(sys.argv[sys.argv.index('--') + 1:])
os.makedirs(args.out, exist_ok=True)

high = bpy.data.objects[args.scan] if args.scan else next(o for o in bpy.data.objects if 'usd_to_aligned' in o)
src = bpy.data.objects[args.body]
low = bpy.data.objects.new('car_body', bpy.data.meshes.new_from_object(src.evaluated_get(bpy.context.evaluated_depsgraph_get())))
low.matrix_world = src.matrix_world
bpy.context.scene.collection.objects.link(low)
src.hide_set(True); src.hide_render = True
bpy.context.view_layer.objects.active = low
bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
bpy.ops.object.mode_set(mode='EDIT'); bpy.ops.mesh.select_all(action='SELECT'); bpy.ops.mesh.remove_doubles(threshold=0.001)
bpy.ops.mesh.quads_convert_to_tris(); bpy.ops.object.mode_set(mode='OBJECT')

wheels = texturing.wheel_contacts(high.data)
if args.wheel_values:
    wheels, args.wheel_radius = texturing.wheels_from_fits(args.wheel_values)
    args.cut_radius = args.wheel_radius + 0.05
print('WHEELS', {k: tuple(round(x, 3) for x in v) for k, v in wheels.items()})
texturing.cut_wheels(low, wheels, args.wheel_radius, args.cut_radius, args.cut_inner)
texturing.outward(low)
print('LOW tris', texturing.tris(low))

to_usd = None
if args.paint_poses:
    levelling = Matrix(np.array(high['levelling']).reshape(4, 4).tolist())
    to_usd = np.array((levelling @ Matrix(np.array(high['usd_to_aligned']).reshape(4, 4).tolist())).inverted())
texturing.texture(low, high, args.out, wheels, args.wheel_radius, args.cut_radius, args.cut_inner, args.glass_min_z,
    tex_size=args.tex_size, to_usd=to_usd, paint_poses=args.paint_poses, paint_frames=args.paint_frames)
