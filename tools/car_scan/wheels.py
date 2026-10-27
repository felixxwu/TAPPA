# Turns a car scan's four wheels into one game wheel: find and unwrap each wheel, colour it from the paint video,
# average out the baked light, and rebuild it low-poly. The judgement calls live in a per-car values file.
# blender -b <scan.blend> --python wheels.py -- <outDir> [--poses <paint.poses.json> --frames <paintFramesDir>] [--scan <object>] [--values <wheel_scan.json>]
# Without a paint video the colour comes from the scan's own texture.
import bpy, sys, os, json, argparse, subprocess
import numpy as np
from mathutils import Matrix
sys.path.append(os.path.dirname(os.path.abspath(__file__)))
import texturing, wheel_math

ap = argparse.ArgumentParser(prog='wheels.py')
ap.add_argument('out')
ap.add_argument('--poses'); ap.add_argument('--frames')
ap.add_argument('--scan', help='the scan object (default: the one carrying the camera link)')
ap.add_argument('--values', help='per-car judgement calls (blender/<car>/wheel_scan.json)')
args = ap.parse_args(sys.argv[sys.argv.index('--') + 1:])
os.makedirs(args.out, exist_ok=True)
values = json.load(open(args.values)) if args.values and os.path.exists(args.values) else {}

scan = bpy.data.objects[args.scan] if args.scan else next(o for o in bpy.data.objects if 'usd_to_aligned' in o)
me = scan.data
if args.poses:
    to_usd = np.array((Matrix(np.array(scan['levelling']).reshape(4, 4).tolist()) @ Matrix(np.array(scan['usd_to_aligned']).reshape(4, 4).tolist())).inverted())
NAMES = {(-1, 1): 'fl', (1, 1): 'fr', (-1, -1): 'rl', (1, -1): 'rr'}   # front is +y, the car's left is -x


def surface_with_normals():
    # Points across the scan's surface (as texturing.surface_points) with the normal of the face each one sits on.
    pts = texturing.surface_points(me)
    vn = np.empty(len(me.vertices) * 3, np.float32); me.vertices.foreach_get('normal', vn)
    tn = np.empty(len(me.loop_triangles) * 3, np.float32); me.loop_triangles.foreach_get('normal', tn)
    tn = tn.reshape(-1, 3)
    return pts, np.concatenate([vn.reshape(-1, 3)] + [tn] * ((len(pts) - len(me.vertices)) // len(tn)))


def save_png(path, rgb):
    img = (np.clip(rgb, 0, 1) * 255).astype(np.uint8)
    subprocess.run(['ffmpeg', '-v', 'error', '-y', '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-s', f'{img.shape[1]}x{img.shape[0]}', '-i', '-', path],
        input=img.tobytes(), check=True)


def nudge(fit, n):
    # Claude's corrections from the values file: move the centre (dy, dz metres) and turn the axle (yaw, pitch degrees).
    fit = dict(fit)
    if 'centre' in n: fit['centre'] = fit['centre'] + np.array([0.0, *n['centre']])
    if 'axle_deg' in n:
        yaw, pitch = np.radians(n['axle_deg'])
        R = np.array(Matrix.Rotation(yaw, 3, 'Z') @ Matrix.Rotation(pitch, 3, 'Y'))
        fit['axle'] = R @ fit['axle']
    return fit


pts, normals = surface_with_normals()
fits, unwraps = {}, {}
for (sx, sy), contact in texturing.wheel_contacts(me).items():
    name = NAMES[(sx, sy)]
    box = (np.abs(pts[:, 1] - contact.y) < 0.6) & (pts[:, 2] < 0.9) & (pts[:, 0] * sx > 0.4)
    # A tight arch can outscore the tyre it hugs; the values file can rule out circles that big.
    fit = wheel_math.fit_standing(pts[box], np.array(contact), sx, values.get('max_radius', 0.6))
    p = pts - fit['centre']
    along = p @ fit['axle']
    radial = np.linalg.norm(p - np.outer(along, fit['axle']), axis=1)
    # The wheel, not the arch; outwards it reaches further, since a hubcap can stand well proud of the tyre.
    on = box & (radial < fit['radius'] * 1.03) & (along > -fit['width'] * 0.6) & (along < fit['width'] * 0.6 + 0.15)
    fit = nudge(fit, values.get('nudges', {}).get(name, {}))
    # The scan gives each ring's depth; the paint video gives every image cell its own colour.
    profile = wheel_math.face_profile(pts[on], fit)
    cells = wheel_math.cell_points(fit, profile)
    pts_all = np.r_[cells['face_points'], cells['tread_points']]
    if args.poses:
        colour, weight = texturing.paint_from_video(pts_all, np.r_[cells['face_normals'], cells['tread_normals']], me, to_usd, args.poses, args.frames)
    else:
        colour, weight = texturing.colour_from_scan(pts_all, scan)
    n_face = len(cells['face_points'])
    un = {'face_rgb': colour[:n_face].reshape(48, 192, 3), 'face_seen': (weight[:n_face] > 1e-3).reshape(48, 192),
          'face_depth': np.repeat(profile[:, None], 192, 1),
          'tread_rgb': colour[n_face:].reshape(16, 192, 3), 'tread_seen': (weight[n_face:] > 1e-3).reshape(16, 192),
          'tread_radius': np.full((16, 192), fit['radius'])}
    fits[name], unwraps[name] = fit, un
    save_png(os.path.join(args.out, f'wheel_{name}_face.png'), un['face_rgb'])
    save_png(os.path.join(args.out, f'wheel_{name}_tread.png'), un['tread_rgb'])
    print('WHEEL %s radius %.3f width %.3f centre (%.3f, %.3f, %.3f) axle (%.3f, %.3f, %.3f) points %d' % (
        name, fit['radius'], fit['width'], *fit['centre'], *fit['axle'], on.sum()))

json.dump({n: {k: (v.tolist() if hasattr(v, 'tolist') else v) for k, v in f.items()} for n, f in fits.items()},
    open(os.path.join(args.out, 'fits.json'), 'w'), indent=1)

include = [n for n in values.get('include', list(unwraps)) if n in unwraps]
suggested = [wheel_math.suggest_spokes(unwraps[n]['face_rgb'], unwraps[n]['face_seen']) for n in include]
spokes = values.get('spokes') or max(set(suggested), key=suggested.count)
print('SPOKES suggested %s, using %d, from wheels %s' % (suggested, spokes, include))
wheel = wheel_math.symmetrise([unwraps[n] for n in include], spokes)
save_png(os.path.join(args.out, 'wheel_face.png'), wheel['face_rgb'])
save_png(os.path.join(args.out, 'wheel_tread.png'), wheel['tread_rgb'])

# Build the game wheel: one profile from the hub across the dished face, over the tread and back in along a flat,
# plain inside face (the scan never sees a tyre's inner side, and nobody looks at it), spun round the axle.
R = float(np.median([fits[n]['radius'] for n in include])); W = float(np.median([fits[n]['width'] for n in include]))
depth = wheel['face_depth'][:, 0]
ring_r = (np.arange(len(depth)) + 0.5) / len(depth) * R
face = [(float(np.interp(r, ring_r, depth)), r) for r in np.r_[np.linspace(0, R * 0.85, 7), R * 0.95]]   # a hubcap may stand proud of the tyre
profile = face + [(W / 2, R * 0.99), (W * 0.4, R), (-W * 0.4, R), (-W / 2, R * 0.99)] + [(-W / 2, r) for x, r in reversed(face)]
SECTORS, TEX = 16, 256
n_face = len(face)

def uv_of(i, j):
    x, r = profile[i]
    a = j / SECTORS * 2 * np.pi
    if i < n_face:   # the outer face: the disc on the left half of the texture
        rr = r / R
        return (0.25 + 0.25 * rr * np.cos(a), 0.5 - 0.5 * rr * np.sin(a))
    if i >= len(profile) - n_face:   # the inside face: a corner outside the disc, which holds the tyre's colour
        return (0.01, 0.99)
    return (0.5 + 0.5 * j / SECTORS, 1 - (x / W + 0.5))   # the tread strip on the right half

verts, faces, uvs = wheel_math.lathe(profile, SECTORS, uv_of)
tread_img = wheel['tread_rgb'][(np.arange(TEX) * wheel['tread_rgb'].shape[0] // TEX)][:, (np.arange(TEX) * wheel['tread_rgb'].shape[1] // TEX)]
texture = np.concatenate([wheel_math.disc_image(wheel['face_rgb'], TEX), tread_img], 1)
tex_path = os.path.join(args.out, 'wheel_texture.png')
save_png(tex_path, texture)

mesh = bpy.data.meshes.new('wheel')
mesh.from_pydata(verts, [], faces)
uv = mesh.uv_layers.new(name='UVMap')
for poly, corners in zip(mesh.polygons, uvs):
    for li, c in zip(poly.loop_indices, corners): uv.data[li].uv = c
obj = bpy.data.objects.new('wheel', mesh); bpy.context.scene.collection.objects.link(obj)
import bmesh
bm = bmesh.new(); bm.from_mesh(mesh); bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1e-5); bmesh.ops.triangulate(bm, faces=bm.faces)
bmesh.ops.recalc_face_normals(bm, faces=bm.faces); bm.to_mesh(mesh); bm.free()
mat = bpy.data.materials.new('wheel'); mat.use_nodes = True
tex = mat.node_tree.nodes.new('ShaderNodeTexImage'); tex.image = bpy.data.images.load(tex_path)
mat.node_tree.links.new(tex.outputs['Color'], mat.node_tree.nodes['Principled BSDF'].inputs['Base Color'])
mesh.materials.append(mat)
for o in bpy.context.scene.objects: o.select_set(o is obj)
bpy.ops.export_scene.gltf(filepath=os.path.join(args.out, 'wheel.glb'), use_selection=True, export_format='GLB')
print('MEASURED wheel_radius %.3f wheel_width %.3f, wheel %d tris' % (R, W, len(mesh.polygons)))
