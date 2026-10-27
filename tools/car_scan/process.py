# Turns the aligned scan into a game body: level it, cut out the wheels, decimate, bake the scan's colour onto the low-poly, export .glb.
# blender -b car_aligned.blend --python process.py -- <outDir> [--tris N] [--wheel-radius M] ...  (see --help)
import bpy, bmesh, sys, os, math, argparse
import numpy as np
sys.path.append(os.path.dirname(os.path.abspath(__file__)))
import cameras, texturing
from texturing import tris, outward
from mathutils import Matrix, Vector

ap = argparse.ArgumentParser(prog='process.py')
ap.add_argument('out')
ap.add_argument('--tris', type=int, default=1000, help='low-poly body budget; the arch cuts add their own on top')
ap.add_argument('--wheel-radius', type=float, default=0.31, help='tyre radius in metres; the arches are cut around it')
ap.add_argument('--cut-radius', type=float, default=0.35, help='radius of the hollowed-out wheel arch')
ap.add_argument('--cut-inner', type=float, default=0.55, help='how far in from the centreline the arch cavity goes')
ap.add_argument('--clearance', type=float, default=0.13, help='everything below this height is the scan\'s fake underside')
ap.add_argument('--axle-zone', type=float, nargs=2, help='min/max distance from the car\'s middle to search for each axle\'s tyre contacts (default: from the car\'s length)')
ap.add_argument('--glass-min-z', type=float, default=0.8, help='beltline height: filled-in surfaces above it are painted as dark glass')
ap.add_argument('--plate-size', type=float, nargs=2, default=(0.34, 0.17), help='rear number plate width x height to blank out')
ap.add_argument('--tex-size', type=int, default=1024)
ap.add_argument('--wheel-values', help='fits.json from wheels.py: measured wheel positions and radius, overriding --wheel-radius/--cut-radius')
ap.add_argument('--paint-poses', help='the paint video\'s cameras in this scan\'s space (register.py); its frames colour the body instead of the scan')
ap.add_argument('--paint-frames', help='folder of the paint video\'s frames')
args = ap.parse_args(sys.argv[sys.argv.index('--') + 1:])
TARGET_TRIS, WHEEL_RADIUS, CUT_RADIUS, CUT_INNER = args.tris, args.wheel_radius, args.cut_radius, args.cut_inner
CLEARANCE, PLATE_SIZE, TEX_SIZE, GLASS_MIN_Z = args.clearance, tuple(args.plate_size), args.tex_size, args.glass_min_z
out = args.out

high = bpy.data.objects['car_scan']
me = high.data
def contacts(): return texturing.wheel_contacts(me, args.axle_zone)

M = Matrix.Identity(4)
def xf(m):
    global M
    me.transform(m); M = m @ M

c = contacts()
front = (c[(-1, 1)] + c[(1, 1)]) / 2
rear = (c[(-1, -1)] + c[(1, -1)]) / 2
left = (c[(-1, 1)] + c[(-1, -1)]) / 2
right = (c[(1, 1)] + c[(1, -1)]) / 2
up = (front - rear).cross(right - left).normalized()
if up.z < 0: up = -up
xf(up.rotation_difference(Vector((0, 0, 1))).to_matrix().to_4x4())
xf(Matrix.Translation((0, 0, -min(v.co.z for v in me.vertices))))
c = contacts()
# Straighten by the wheels, not the body outline (mirrors and scan lumps skew the outline), and put the origin midway between the axles.
axis = (c[(-1, 1)] - c[(-1, -1)]) + (c[(1, 1)] - c[(1, -1)])
xf(Matrix.Rotation(math.atan2(axis.x, axis.y), 4, 'Z'))
c = contacts()
mid = sum(c.values(), Vector()) / 4
xf(Matrix.Translation((-mid.x, -mid.y, 0)))
c = contacts()
with open(os.path.join(out, 'scan_transform.txt'), 'w') as f: f.write(' '.join(str(x) for row in M for x in row))  # lets the untouched scan be shown in the same place
if args.wheel_values:
    c, WHEEL_RADIUS = texturing.wheels_from_fits(args.wheel_values)
    CUT_RADIUS = WHEEL_RADIUS + 0.05
print('WHEELS', {k: tuple(round(x, 3) for x in v) for k, v in c.items()})

VOXEL = 0.04
# From the levelled scan back to the coordinates the saved cameras live in.
to_usd = np.array((M @ Matrix(np.array(high['usd_to_aligned']).reshape(4, 4).tolist())).inverted())

def build_shell():
    # The scan sees through glass and leaves holes in plain panels, so the body is built from the car's outline in
    # every frame instead: the space no camera saw as background. That comes out closed, with solid windows and no interior.
    poses, masks = cameras.load(high['poses'], high['masks'], every=3, size=(640, 360))
    co = np.empty(len(me.vertices) * 3, np.float32); me.vertices.foreach_get('co', co); co = co.reshape(-1, 3)
    lo = co.min(0) - 2 * VOXEL
    n = np.ceil((co.max(0) + 2 * VOXEL - lo) / VOXEL).astype(int)
    idx = np.stack(np.meshgrid(*[np.arange(k) for k in n], indexing='ij'), -1).reshape(-1, 3)
    centres = lo + (idx + 0.5) * VOXEL
    usd = (np.c_[centres, np.ones(len(centres))] @ to_usd.T)[:, :3]
    # Depth images need the scan's surface, not just its corners, or cameras see through the gaps to the far side.
    tri = np.empty(len(me.loop_triangles) * 3, np.int32) if me.calc_loop_triangles() is None else None
    me.loop_triangles.foreach_get('vertices', tri); tri = co[tri.reshape(-1, 3)]
    surface = np.concatenate([co] + [tri @ np.array(w) for w in ((1/3, 1/3, 1/3), (.5, .5, 0), (0, .5, .5), (.5, 0, .5), (2/3, 1/6, 1/6), (1/6, 2/3, 1/6), (1/6, 1/6, 2/3))])
    co_usd = (np.c_[surface, np.ones(len(surface))] @ to_usd.T)[:, :3]
    seen = np.zeros(len(usd)); outside = np.zeros(len(usd))
    for pose, m in zip(poses, masks):
        s, hit = cameras.inside(usd, pose, m)
        seen += s; outside += s & ~hit
    # A vote rather than a strict intersection, so one bad mask can't punch a hole through the body.
    solid = ((seen >= 10) & (outside <= 0.1 * seen)).reshape(n)
    vi = np.clip(((co - lo) / VOXEL).astype(int), 0, n - 1)
    print('SHELL holds %.1f%% of the scan (should be ~100)' % (100 * solid[vi[:, 0], vi[:, 1], vi[:, 2]].mean()))
    z = lo[2] + (np.arange(n[2]) + 0.5) * VOXEL
    solid[:, :, z < CLEARANCE] = False
    # An outline can't see dents, flat panels or an open bed, so below the beltline carve the shell back to the scan:
    # any voxel a camera sees the scan's surface *behind* is empty space. Above the beltline the shell stays, which is
    # what keeps the glass and roof closed (the scan sees through glass into the cab).
    metre = np.linalg.norm(to_usd[:3, 0])
    below = centres[:, 2] < GLASS_MIN_Z
    freed = np.zeros(len(usd)); looked = np.zeros(len(usd))
    for pose in poses:
        u, v, d, ok = cameras.project(co_usd, pose, (320, 180))
        depth = np.full((180, 320), np.inf); np.minimum.at(depth, (v[ok], u[ok]), d[ok])
        depth = np.minimum.reduce([np.roll(np.roll(depth, a, 0), b, 1) for a in (-1, 0, 1) for b in (-1, 0, 1)])   # close the gaps between scan points
        u, v, d, ok = cameras.project(usd, pose, (320, 180))
        behind = depth[v.clip(0, 179), u.clip(0, 319)]
        # No scan there (a hole), or the voxel hidden behind the scan from here: this camera can't tell either way.
        evidence = ok & below & np.isfinite(behind) & (d < behind + 0.06 * metre)
        looked += evidence; freed += evidence & (d < behind - 0.06 * metre)
    solid &= ~((freed >= 3) & (freed >= 0.3 * looked)).reshape(n)
    # Carving through the side windows also hollows out the cab below the beltline; refill anything the outside can't reach.
    outside = np.zeros_like(solid); outside[[0, -1]] = outside[:, [0, -1]] = outside[:, :, [0, -1]] = True
    outside &= ~solid
    while True:
        grown = outside | np.pad(outside, 1)[2:, 1:-1, 1:-1] | np.pad(outside, 1)[:-2, 1:-1, 1:-1] | np.pad(outside, 1)[1:-1, 2:, 1:-1] \
            | np.pad(outside, 1)[1:-1, :-2, 1:-1] | np.pad(outside, 1)[1:-1, 1:-1, 2:] | np.pad(outside, 1)[1:-1, 1:-1, :-2]
        grown &= ~solid
        if (grown == outside).all(): break
        outside = grown
    solid = ~outside
    solid[:, :, z < CLEARANCE] = False
    # One square face wherever a solid voxel meets an empty one.
    S = np.pad(solid, 1)
    quads = []
    for axis in range(3):
        a, b, c = axis, (axis + 1) % 3, (axis + 2) % 3
        for p in np.argwhere(np.diff(S.astype(np.int8), axis=axis) != 0):
            corner = np.zeros(3, int); corner[a] = p[a]
            q = []
            for db, dc in ((-1, -1), (0, -1), (0, 0), (-1, 0)):
                k = corner.copy(); k[b] = p[b] + db; k[c] = p[c] + dc; q.append(tuple(k))
            quads.append(q)
    corners = {k: i for i, k in enumerate(sorted({k for q in quads for k in q}))}
    verts = [tuple(lo + np.array(k) * VOXEL) for k in corners]
    sm = bpy.data.meshes.new('car_shell')
    sm.from_pydata(verts, [], [[corners[k] for k in q] for q in quads])
    o = bpy.data.objects.new('car_shell', sm); bpy.context.scene.collection.objects.link(o)
    bpy.context.view_layer.objects.active = o
    rem = o.modifiers.new('remesh', 'REMESH'); rem.mode, rem.voxel_size = 'VOXEL', VOXEL * 0.75
    sm_ = o.modifiers.new('smooth', 'LAPLACIANSMOOTH'); sm_.iterations, sm_.lambda_factor, sm_.use_volume_preserve = 10, 1.0, True
    for mod in list(o.modifiers): bpy.ops.object.modifier_apply(modifier=mod.name)
    outward(o)
    vs = np.array([v.co for v in o.data.vertices])
    print('SHELL %d tris, size %.2f x %.2f x %.2f m' % (tris(o), *(vs.max(0) - vs.min(0))))
    return o

shell = build_shell()

# Object Capture seals the underside down to the ground; slice it off at sill height and cap it flat.
me.materials.append(texturing.arch_material())
bm = bmesh.new(); bm.from_mesh(me)
bmesh.ops.bisect_plane(bm, geom=bm.verts[:] + bm.edges[:] + bm.faces[:], plane_co=(0, 0, CLEARANCE), plane_no=(0, 0, 1), clear_inner=True)
for f in bmesh.ops.holes_fill(bm, edges=[e for e in bm.edges if e.is_boundary], sides=0)['faces']:
    f.material_index = len(me.materials) - 1
bm.to_mesh(me); bm.free()

low = shell.copy(); low.data = shell.data.copy(); low.name = 'car_body'
bpy.context.scene.collection.objects.link(low)
bpy.context.view_layer.objects.active = low
# Decimate before cutting the wheels so the budget goes to the body and the arches stay crisp circles; in steps,
# because one huge cut folds thin parts like the bed walls into spikes.
before = None
while tris(low) > TARGET_TRIS * 1.05 and tris(low) != before:   # stop if it stalls
    before = tris(low)
    dec = low.modifiers.new('dec', 'DECIMATE')
    dec.ratio = max(TARGET_TRIS / tris(low), 0.35)
    dec.use_collapse_triangulate = True
    bpy.ops.object.modifier_apply(modifier='dec')
texturing.cut_wheels(low, c, WHEEL_RADIUS, CUT_RADIUS, CUT_INNER)
bpy.context.view_layer.objects.active = low
bpy.ops.object.mode_set(mode='EDIT'); bpy.ops.mesh.select_all(action='SELECT'); bpy.ops.mesh.quads_convert_to_tris(); bpy.ops.object.mode_set(mode='OBJECT')
outward(low)
print('LOW tris', tris(low))
texturing.texture(low, high, out, c, WHEEL_RADIUS, CUT_RADIUS, CUT_INNER, GLASS_MIN_Z, PLATE_SIZE, TEX_SIZE,
    to_usd=to_usd, paint_poses=args.paint_poses, paint_frames=args.paint_frames)
