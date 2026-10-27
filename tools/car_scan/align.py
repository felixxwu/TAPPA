# Imports the scan, rotates its long axis onto Blender's Y axis, scales it to real length, sits it on the ground and saves a .blend.
# blender -b --python align.py -- <model.usdz> <out.blend> <length_m> [--flip] [--masks <masksDir>]
import bpy, bmesh, math, sys, os
import numpy as np
sys.path.append(os.path.dirname(os.path.abspath(__file__)))
import cameras
from mathutils import Matrix, Vector
argv = sys.argv[sys.argv.index('--') + 1:]
src, dst, LENGTH = argv[0], argv[1], float(argv[2])
FLIP = '--flip' in argv
MASKS = argv[argv.index('--masks') + 1] if '--masks' in argv else None
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.wm.usd_import(filepath=src)
mesh = [o for o in bpy.context.scene.objects if o.type == 'MESH'][0]
bpy.context.view_layer.objects.active = mesh
mesh.select_set(True)
usd_to_blender = mesh.matrix_world.copy()   # the importer turns USD's Y-up into Blender's Z-up; the saved cameras are in USD space
bpy.ops.object.parent_clear(type='CLEAR_KEEP_TRANSFORM')
bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
for o in list(bpy.context.scene.objects):
    if o is not mesh: bpy.data.objects.remove(o)

def carve(me, to_usd, poses_path, masks_dir):
    # Delete whatever lands outside the car's mask when seen from the saved cameras. The car itself always
    # projects inside its own outline; the floor, walls and the shell rebuilt from the blacked-out background don't.
    poses, masks = cameras.load(poses_path, masks_dir, every=3, size=(320, 180))
    co = np.empty(len(me.vertices) * 3, np.float32); me.vertices.foreach_get('co', co)
    co = (np.c_[co.reshape(-1, 3), np.ones(len(me.vertices))] @ np.array(to_usd).T)[:, :3]
    seen = np.zeros(len(co)); outside = np.zeros(len(co))
    for pose, m in zip(poses, masks):
        m = m | np.roll(m, 1, 0) | np.roll(m, -1, 0) | np.roll(m, 1, 1) | np.roll(m, -1, 1)   # forgive the mask's edge by a pixel
        s, hit = cameras.inside(co, pose, m)
        seen += s; outside += s & ~hit
    bad = (outside / np.maximum(seen, 1) > 0.15) | (seen == 0)
    bm = bmesh.new(); bm.from_mesh(me); bm.verts.ensure_lookup_table()
    bmesh.ops.delete(bm, geom=[bm.verts[i] for i in np.flatnonzero(bad)], context='VERTS')
    bm.to_mesh(me); bm.free()
    print('CARVED %d of %d verts outside the car, seen from %d cameras' % (bad.sum(), len(bad), len(poses)))

def crop_to_car(me):
    # Object Capture can't separate the car from the garage, so it reconstructs the floor and walls too.
    # Level the floor, drop its flat faces, then keep the bulky loose piece: walls are thin, shadow blobs small.
    bm = bmesh.new(); bm.from_mesh(me); bm.faces.ensure_lookup_table()
    up = Vector((0, 0, 1))
    for _ in range(4):
        flat = [f for f in bm.faces if abs(f.normal.dot(up)) > 0.8]
        up = sum((f.normal * f.calc_area() * (1 if f.normal.dot(up) > 0 else -1) for f in flat), Vector()).normalized()
    rot = up.rotation_difference(Vector((0, 0, 1))).to_matrix().to_4x4()
    bm.transform(rot); me.transform(rot)
    zs = sorted(v.co.z for v in bm.verts)
    span = max(max(v.co.x for v in bm.verts) - min(v.co.x for v in bm.verts), max(v.co.y for v in bm.verts) - min(v.co.y for v in bm.verts))
    bins = {}
    for z in zs: bins[round(z / (span * 0.002))] = bins.get(round(z / (span * 0.002)), 0) + 1
    floor = max(bins, key=bins.get) * span * 0.002
    tol = span * 0.01
    # Masked frames usually leave no floor; then the busiest height is the roof or bonnet, which must stay.
    if floor - zs[0] > 0.05 * (zs[-1] - zs[0]):
        floor = zs[0]
    else:
        bmesh.ops.delete(bm, geom=[f for f in bm.faces if f.normal.z > 0.9 and all(abs(v.co.z - floor) < tol for v in f.verts)], context='FACES')
    seen, islands = set(), []
    for f in bm.faces:
        if f in seen: continue
        island, stack = [], [f]; seen.add(f)
        while stack:
            g = stack.pop(); island.append(g)
            for e in g.edges:
                for n in e.link_faces:
                    if n not in seen: seen.add(n); stack.append(n)
        islands.append(island)
    def bulk(island):
        vs = [v.co for f in island for v in f.verts]
        dx = max(v.x for v in vs) - min(v.x for v in vs); dy = max(v.y for v in vs) - min(v.y for v in vs)
        return len(island) if min(dx, dy) > 0.2 * max(dx, dy) else 0
    keep = set(max(islands, key=bulk))
    bmesh.ops.delete(bm, geom=[f for f in bm.faces if f not in keep], context='FACES')
    bmesh.ops.translate(bm, verts=bm.verts, vec=(0, 0, -floor))
    bm.to_mesh(me); bm.free()
    print('CROPPED to %d of %d loose pieces, %d tris kept' % (1, len(islands), len(keep)))
    return Matrix.Translation((0, 0, -floor)) @ rot

poses = src + '.poses.json'
if MASKS and os.path.exists(poses):
    carve(mesh.data, usd_to_blender.inverted(), poses, MASKS)
cropped = crop_to_car(mesh.data)
pts =[v.co.xy.copy() for v in mesh.data.vertices]
def area(a):
    c, s = math.cos(a), math.sin(a)
    xs = [p.x*c - p.y*s for p in pts]; ys = [p.x*s + p.y*c for p in pts]
    return (max(xs)-min(xs)) * (max(ys)-min(ys)), max(xs)-min(xs), max(ys)-min(ys)
best = min((area(math.radians(d/4)) + (math.radians(d/4),) for d in range(0, 720)), key=lambda t: t[0])
a = best[3] + (math.pi/2 if best[1] > best[2] else 0) + (math.pi if FLIP else 0)
spin = Matrix.Rotation(a, 4, 'Z')
mesh.data.transform(spin)
vs = [v.co for v in mesh.data.vertices]
lo = Vector((min(v.x for v in vs), min(v.y for v in vs), min(v.z for v in vs)))
hi = Vector((max(v.x for v in vs), max(v.y for v in vs), max(v.z for v in vs)))
k = LENGTH / (hi.y - lo.y)
fit = Matrix.Scale(k, 4) @ Matrix.Translation(-Vector(((lo.x+hi.x)/2, (lo.y+hi.y)/2, lo.z)))
mesh.data.transform(fit)
size = (hi - lo) * k
print('ALIGNED rotation %.2f deg, size %.2f x %.2f x %.2f m, tris %d' % (math.degrees(a), size.x, size.y, size.z, sum(len(p.vertices)-2 for p in mesh.data.polygons)))
mesh.name = 'car_scan'
# process.py builds the outer shell from the same cameras, so it needs the way back to their coordinates.
if MASKS and os.path.exists(poses):
    mesh['usd_to_aligned'] = [x for row in fit @ spin @ cropped @ usd_to_blender for x in row]
    mesh['poses'], mesh['masks'] = os.path.abspath(poses), os.path.abspath(MASKS)
bpy.ops.file.pack_all()
bpy.ops.wm.save_as_mainfile(filepath=dst)
