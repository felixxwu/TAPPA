# Turns a low-poly body into a textured game body: wheel arches, UVs, colour (from the scan or a paint video), flat fills
# for glass and holes, a blank number plate, and the exported .glb. Shared by process.py (bodies built from the scan) and
# texture.py (bodies modelled by hand over the scan).
import bpy, os, json, subprocess, math
import numpy as np
from mathutils import Vector
import cameras

def tris(o): return sum(len(p.vertices) - 2 for p in o.data.polygons)

def outward(o):
    # Paint and glass are told apart by which way each face points, so every face must point out of the car.
    bpy.context.view_layer.objects.active = o
    bpy.ops.object.mode_set(mode='EDIT'); bpy.ops.mesh.select_all(action='SELECT'); bpy.ops.mesh.normals_make_consistent(inside=False); bpy.ops.object.mode_set(mode='OBJECT')

def wheel_contacts(me, axle_zone=None):
    # Where each tyre touches the ground, found as the lowest scan points in each corner.
    co = np.empty(len(me.vertices) * 3, np.float32); me.vertices.foreach_get('co', co); co = co.reshape(-1, 3)
    # Every car's wheels sit roughly 40-90% of the way from its middle to its ends, and well out from its centreline.
    half_length = np.abs(co[:, 1]).max()
    zone = axle_zone or (0.4 * half_length, 0.92 * half_length)
    tyre_min_x = 0.25 * (co[:, 0].max() - co[:, 0].min())
    pts = {}
    for sx in (-1, 1):
        for sy in (-1, 1):
            q = co[(co[:, 0] * sx > tyre_min_x) & (co[:, 1] * sy > zone[0]) & (co[:, 1] * sy < zone[1])]
            pts[(sx, sy)] = Vector(q[q[:, 2] < q[:, 2].min() + 0.01].mean(0))
    return pts

def wheels_from_fits(path):
    """Wheel positions and tyre radius measured by wheels.py (its fits.json): the arches are cut round these, so the
    game's wheels, sized from the same numbers, sit in them."""
    fits = json.load(open(path))
    names = {'fl': (-1, 1), 'fr': (1, 1), 'rl': (-1, -1), 'rr': (1, -1)}
    wheels = {names[n]: Vector((f['centre'][0], f['centre'][1], 0.0)) for n, f in fits.items()}
    return wheels, float(np.median([f['radius'] for f in fits.values()]))

def arch_material():
    arch = bpy.data.materials.get('arch') or bpy.data.materials.new('arch')
    arch.use_nodes = True
    arch.node_tree.nodes['Principled BSDF'].inputs['Base Color'].default_value = (0.02, 0.02, 0.02, 1)
    return arch

def cut_wheels(obj, wheels, wheel_radius, cut_radius, cut_inner, segments=12):
    # Hollow out an arch at each wheel for the game's own wheels to sit in. Where the arch rises past a floor inside the
    # body (a pickup's bed) it would punch through, so first add a tub a little bigger than the arch, kept inside the
    # body's sides and above its underside; the cut then leaves the tub's shell over the wheel.
    import bmesh
    wall = 0.04
    co = np.array([v.co for v in obj.data.vertices])
    for (sx, sy), p in wheels.items():
        near = co[np.abs(co[:, 1] - p.y) < 1.0]   # a low-poly body may have no vertex right over the wheel
        side, bottom = np.abs(near[:, 0]).max() - 0.02, near[:, 2].min() + 0.01
        for radius, x0, x1, op in ((cut_radius + wall, cut_inner - wall, side, 'UNION'), (cut_radius, cut_inner, cut_inner + 1.5, 'DIFFERENCE')):
            bpy.ops.mesh.primitive_cylinder_add(vertices=segments, radius=radius, depth=x1 - x0,
                location=(sx * (x0 + x1) / 2, p.y, wheel_radius), rotation=(0, math.pi / 2, 0))
            cutter = bpy.context.object
            cutter.data.materials.append(arch_material())
            if op == 'UNION':
                bm = bmesh.new(); bm.from_mesh(cutter.data)
                bm.transform(cutter.matrix_world)
                bmesh.ops.bisect_plane(bm, geom=bm.verts[:] + bm.edges[:] + bm.faces[:], plane_co=(0, 0, bottom), plane_no=(0, 0, 1), clear_inner=True)
                bmesh.ops.holes_fill(bm, edges=[e for e in bm.edges if e.is_boundary], sides=0)
                bm.transform(cutter.matrix_world.inverted()); bm.to_mesh(cutter.data); bm.free()
            mod = obj.modifiers.new('cut', 'BOOLEAN')
            mod.operation, mod.solver, mod.object = op, 'EXACT', cutter
            mod.use_self = mod.use_hole_tolerant = True   # decimation leaves small self-intersections
            bpy.context.view_layer.objects.active = obj
            bpy.ops.object.modifier_apply(modifier=mod.name)
            bpy.data.objects.remove(cutter)

def surface_points(me):
    # The scan's corners plus points across each of its triangles: depth images built from the corners alone have gaps,
    # and a camera looking through them sees the far side of the car as if nothing were in front of it.
    co = np.empty(len(me.vertices) * 3, np.float32); me.vertices.foreach_get('co', co); co = co.reshape(-1, 3)
    me.calc_loop_triangles()
    tri = np.empty(len(me.loop_triangles) * 3, np.int32); me.loop_triangles.foreach_get('vertices', tri); tri = co[tri.reshape(-1, 3)]
    weights = ((1/3, 1/3, 1/3), (.5, .5, 0), (0, .5, .5), (.5, 0, .5), (2/3, 1/6, 1/6), (1/6, 2/3, 1/6), (1/6, 1/6, 2/3))
    return np.concatenate([co] + [tri @ np.array(w) for w in weights])

def paint_from_video(points, normals, scan_me, to_usd, poses_path, frames_dir):
    # Colours each point from the paint video: a blend of the frames that see it most squarely, skipping frames where
    # something else (another part of the car) is in front of it. The scan's depth from each camera decides that.
    poses = json.load(open(poses_path))
    metre = np.linalg.norm(to_usd[:3, 0])
    P = (np.c_[points, np.ones(len(points))] @ to_usd.T)[:, :3]
    N = normals @ to_usd[:3, :3].T; N /= np.linalg.norm(N, axis=1, keepdims=True) + 1e-9
    sc = surface_points(scan_me)
    sc = (np.c_[sc, np.ones(len(sc))] @ to_usd.T)[:, :3]
    W, H = 640, 360
    acc, wsum = np.zeros((len(P), 3)), np.zeros(len(P))
    for name, pose in sorted(poses.items()):
        path = os.path.join(frames_dir, name)
        if not os.path.exists(path): continue
        img = np.frombuffer(subprocess.run(['ffmpeg', '-v', 'error', '-i', path, '-vf', f'scale={W}:{H}', '-pix_fmt', 'rgb24', '-f', 'rawvideo', '-'],
            capture_output=True, check=True).stdout, np.uint8).reshape(H, W, 3) / 255
        u, v, z, ok = cameras.project(sc, pose, (W, H))
        depth = np.full((H, W), np.inf); np.minimum.at(depth, (v[ok], u[ok]), z[ok])
        depth = np.minimum.reduce([np.roll(np.roll(depth, a, 0), b, 1) for a in (-1, 0, 1) for b in (-1, 0, 1)])   # close the gaps between scan points
        u, v, z, ok = cameras.project(P, pose, (W, H))
        u, v = u.clip(0, W - 1), v.clip(0, H - 1)
        visible = ok & (z <= depth[v, u] + 0.05 * metre)
        to_cam = pose['translation'] - P
        facing = (N * to_cam).sum(1) / np.linalg.norm(to_cam, axis=1)
        w = np.where(visible, np.clip(facing, 0, 1) ** 4, 0)   # strongly prefer head-on views: they're sharpest and least reflective
        acc += w[:, None] * img[v, u]; wsum += w
    return acc / np.maximum(wsum, 1e-9)[:, None], wsum

def colour_from_scan(points, scan, reach=0.05):
    # Colours each point from the scan's own texture, at the nearest spot on its surface: for a scan made in the car's
    # real paint, with no paint video. Points further than reach from the surface count as unseen.
    from mathutils.bvhtree import BVHTree
    me = scan.data; me.calc_loop_triangles()
    co = np.empty(len(me.vertices) * 3, np.float32); me.vertices.foreach_get('co', co); co = co.reshape(-1, 3)
    tv = np.empty(len(me.loop_triangles) * 3, np.int32); me.loop_triangles.foreach_get('vertices', tv); tv = tv.reshape(-1, 3)
    tl = np.empty(len(me.loop_triangles) * 3, np.int32); me.loop_triangles.foreach_get('loops', tl); tl = tl.reshape(-1, 3)
    uv = np.empty(len(me.loops) * 2, np.float32); me.uv_layers.active.data.foreach_get('uv', uv); uv = uv.reshape(-1, 2)
    tree = BVHTree.FromPolygons(co.tolist(), tv.tolist())
    bsdf = next(n for n in me.materials[0].node_tree.nodes if n.type == 'BSDF_PRINCIPLED')
    img = bsdf.inputs['Base Color'].links[0].from_node.image
    w, h = img.size
    px = np.empty(w * h * 4, np.float32); img.pixels.foreach_get(px); px = px.reshape(h, w, 4)
    rgb, seen = np.zeros((len(points), 3)), np.zeros(len(points))
    for i, p in enumerate(points):
        hit, _, tri, dist = tree.find_nearest(Vector(p), reach)
        if hit is None: continue
        a, b, c = co[tv[tri]]
        bary = np.linalg.lstsq(np.c_[a - c, b - c], np.array(hit) - c, rcond=None)[0]
        t = uv[tl[tri]].T @ np.r_[bary, 1 - bary.sum()]
        rgb[i] = px[int(np.clip(t[1], 0, 1) * (h - 1)), int(np.clip(t[0], 0, 1) * (w - 1)), :3]
        seen[i] = 1
    return rgb, seen

def texture(low, high, out, wheels, wheel_radius, cut_radius, cut_inner, glass_min_z, plate_size=(0.34, 0.17), tex_size=1024,
            to_usd=None, paint_poses=None, paint_frames=None):
    me = high.data
    img = bpy.data.images.new('car_body_texture', tex_size, tex_size)
    img.generated_color = (0.02, 0.02, 0.02, 1)
    mat = bpy.data.materials.new('car_body')
    mat.use_nodes = True
    tex = mat.node_tree.nodes.new('ShaderNodeTexImage'); tex.image = img
    mat.node_tree.links.new(tex.outputs['Color'], mat.node_tree.nodes['Principled BSDF'].inputs['Base Color'])
    mat.node_tree.nodes['Principled BSDF'].inputs['Roughness'].default_value = 0.5
    mat.node_tree.nodes.active = tex
    low.data.materials.clear(); low.data.materials.append(mat)
    while low.data.uv_layers: low.data.uv_layers.remove(low.data.uv_layers[0])
    low.data.uv_layers.new(name='UVMap')
    bpy.ops.object.select_all(action='DESELECT')
    low.select_set(True); bpy.context.view_layer.objects.active = low
    bpy.ops.object.mode_set(mode='EDIT')
    bpy.ops.mesh.select_all(action='SELECT')
    bpy.ops.uv.smart_project(angle_limit=1.15, island_margin=0.004)
    bpy.ops.object.mode_set(mode='OBJECT')

    sc = bpy.context.scene
    sc.render.engine = 'CYCLES'
    sc.cycles.samples = 4
    sc.cycles.device = 'GPU'
    high.hide_set(False); high.hide_render = False
    high.select_set(True); low.select_set(True); bpy.context.view_layer.objects.active = low
    bpy.ops.object.bake(type='DIFFUSE', pass_filter={'COLOR'}, use_selected_to_active=True,
        cage_extrusion=0.12, max_ray_distance=0.3, margin=8)   # a low-poly body has flat faces well inside the scan

    # Bake where on the scan each texel landed, to tell real surface from filled-in glass and holes, and to find the plate.
    posmat = bpy.data.materials.new('position'); posmat.use_nodes = True
    nt = posmat.node_tree; emit = nt.nodes.new('ShaderNodeEmission')
    nt.links.new(nt.nodes.new('ShaderNodeNewGeometry').outputs['Position'], emit.inputs['Color'])
    nt.links.new(emit.outputs['Emission'], nt.nodes['Material Output'].inputs['Surface'])
    scan_mats = list(me.materials)
    for i in range(len(me.materials)): me.materials[i] = posmat
    pos_img = bpy.data.images.new('position', tex_size, tex_size, float_buffer=True)
    pos_img.generated_color = (0, 0, 100, 1)   # texels no face covers sit far above the car, out of any test below
    tex.image = pos_img
    bpy.ops.object.bake(type='EMIT', use_selected_to_active=True, cage_extrusion=0.12, max_ray_distance=0.3, margin=0)
    tex.image = img
    for i, m in enumerate(scan_mats): me.materials[i] = m
    pos = np.empty(tex_size * tex_size * 4, np.float32); pos_img.pixels.foreach_get(pos); pos = pos.reshape(-1, 4)[:, :3]
    col = np.empty(tex_size * tex_size * 4, np.float32); img.pixels.foreach_get(col); col = col.reshape(-1, 4)

    def bake_own(output):
        # Bakes a property of the low-poly body itself (where each texel is, or which way it faces), not of the scan.
        m = bpy.data.materials.new(output); m.use_nodes = True; nt = m.node_tree
        e = nt.nodes.new('ShaderNodeEmission')
        nt.links.new(nt.nodes.new('ShaderNodeNewGeometry').outputs[output], e.inputs['Color'])
        nt.links.new(e.outputs['Emission'], nt.nodes['Material Output'].inputs['Surface'])
        t = nt.nodes.new('ShaderNodeTexImage'); t.image = bpy.data.images.new(output, tex_size, tex_size, float_buffer=True)
        t.image.generated_color = (0, 0, 100, 1); nt.nodes.active = t
        low.data.materials[0] = m; high.select_set(False)
        bpy.ops.object.bake(type='EMIT', use_selected_to_active=False, margin=0)
        low.data.materials[0] = mat; high.select_set(True)
        px = np.empty(tex_size * tex_size * 4, np.float32); t.image.pixels.foreach_get(px)
        return px.reshape(-1, 4)[:, :3]
    own, normal = bake_own('Position'), bake_own('Normal')
    covered = own[:, 2] < 50
    near_scan = (pos[:, 2] < 50) & (np.linalg.norm(pos - own, axis=1) < 0.12)   # a low-poly body sits up to ~10 cm off the scan; that's still real surface
    filled = covered & ~near_scan

    if paint_poses:
        colour, weight = paint_from_video(np.where(near_scan[:, None], pos, own)[covered], normal[covered], me, to_usd, paint_poses, paint_frames)
        col[covered, :3] = colour
        unseen = np.zeros(len(col), bool); unseen[np.flatnonzero(covered)[weight < 1e-3]] = True
        filled |= unseen
        print('PAINT VIDEO saw %.0f%% of the body' % (100 * (1 - unseen.sum() / covered.sum())))

    # Where the body fills in for the scan (windows, holes) the bake found nothing, or the interior behind. Glass above the
    # beltline goes flat dark, as do the arches and underside; other gaps take the colour of the real surface around them.
    glass = filled & (own[:, 2] > glass_min_z) & (normal[:, 2] < 0.7)
    in_arch = np.zeros(len(own), bool)
    for (sx, sy), wp in wheels.items():
        in_arch |= (np.hypot(own[:, 1] - wp.y, own[:, 2] - wheel_radius) < cut_radius + 0.03) & (np.abs(own[:, 0]) > cut_inner - 0.03)
    dark = covered & (in_arch | (filled & (normal[:, 2] < -0.7)))
    gap = filled & ~glass & ~dark
    col[glass, :3] = (0.03, 0.035, 0.04)
    col[dark, :3] = (0.02, 0.02, 0.02)
    known = (covered & ~gap).reshape(tex_size, tex_size)
    rgb = np.where(known[..., None], col[:, :3].reshape(tex_size, tex_size, 3), 0)
    todo = gap.reshape(tex_size, tex_size)
    # Grow the known colours into the gaps a texel at a time; neighbouring texels are almost always on the same face.
    for _ in range(tex_size // 4):
        if not todo.any(): break
        total = np.zeros_like(rgb); count = np.zeros(known.shape)
        for a, b in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            total += np.roll(np.roll(rgb, a, 0), b, 1); count += np.roll(np.roll(known, a, 0), b, 1)
        grow = todo & (count > 0)
        rgb[grow] = total[grow] / count[grow, None]; known |= grow; todo &= ~grow
    col[:, :3] = np.where(gap[:, None], rgb.reshape(-1, 3), col[:, :3])
    print('FILLED %.0f%% of the body: %.0f%% glass, %.0f%% from the surrounding surface' % (
        100 * filled.sum() / covered.sum(), 100 * glass.sum() / covered.sum(), 100 * gap.sum() / covered.sum()))

    # Blank the rear number plate: every car wears the same plate, so slide a plate-sized rectangle over the rear
    # (1 cm grid, x by height) and take the spot that is most white; badges and lights are bright but not plate-shaped.
    rear_face = (pos[:, 1] < pos[pos[:, 2] < 50, 1].min() + 0.25) & (np.abs(pos[:, 0]) < 0.5) & (pos[:, 2] > 0.2) & (pos[:, 2] < 1.0)
    bright = (col[:, :3].min(1) > 0.4) & (col[:, :3].max(1) - col[:, :3].min(1) < 0.2)   # off-white: the plate is a little warm-tinted
    gx = ((pos[:, 0] + 0.5) * 100).astype(int); gz = ((pos[:, 2] - 0.2) * 100).astype(int)
    total = np.zeros((100, 80)); white = np.zeros((100, 80))
    np.add.at(total, (gx[rear_face], gz[rear_face]), 1); np.add.at(white, (gx[rear_face & bright], gz[rear_face & bright]), 1)
    w, h = round(plate_size[0] * 100), round(plate_size[1] * 100)
    def box_sums(grid):
        c = np.pad(grid.cumsum(0).cumsum(1), ((1, 0), (1, 0)))
        return c[w:, h:] - c[:-w, h:] - c[w:, :-h] + c[:-w, :-h]
    white_in, total_in = box_sums(white), box_sums(total)
    i, j = np.unravel_index(white_in.argmax(), white_in.shape)
    share = white_in[i, j] / max(total_in[i, j], 1)
    if share > 0.4:
        x0, z0 = i / 100 - 0.5, j / 100 + 0.2
        fill = rear_face & (pos[:, 0] > x0) & (pos[:, 0] < x0 + plate_size[0]) & (pos[:, 2] > z0) & (pos[:, 2] < z0 + plate_size[1])
        col[fill, :3] = np.median(col[fill & bright, :3], axis=0)
        print('PLATE blanked at x %.2f..%.2f, z %.2f..%.2f' % (x0, x0 + plate_size[0], z0, z0 + plate_size[1]))
    else:
        print('PLATE not found (best %.0f%% white)' % (100 * share))
    img.pixels.foreach_set(col.ravel())
    img.filepath_raw = os.path.join(out, 'car_body_texture.png'); img.file_format = 'PNG'; img.save()

    bpy.ops.object.select_all(action='DESELECT')
    low.select_set(True)
    bpy.ops.export_scene.gltf(filepath=os.path.join(out, 'car_body.glb'), use_selection=True, export_format='GLB')
    bpy.ops.wm.save_as_mainfile(filepath=os.path.join(out, 'car_body.blend'))
    print('DONE')
