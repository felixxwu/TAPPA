# Builds a level-editor-lab save from fetch.py's data: LiDAR ground as the heightmap, the OSM road network as chains, and a tree at every LiDAR canopy peak with its species guessed from height and satellite colour.
# Usage: python make_level.py <name> [--size 600; any square, the level's `size`] [--centre E N]   -> data/<name>/level.json (unpacked; pack_level.js packs it for tools/levels/)
from collections import Counter
import argparse, json, math, sys, os, numpy as np, xml.etree.ElementTree as ET
from pyproj import Transformer
from scipy import ndimage as nd
ap = argparse.ArgumentParser(); ap.add_argument("name"); ap.add_argument("--size", type=int, default=600)
ap.add_argument("--centre", type=float, nargs=2, metavar=("E", "N")); args = ap.parse_args()
DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "data", args.name)
META = json.load(open(DIR + "/meta.json"))
CE, CN = args.centre or META["centre"]               # square centre, British National Grid metres
SIZE = args.size; N = round(SIZE / 3); CELL = SIZE / N
E0, N0 = META["mosaic_origin"]                       # the mosaic's north-west corner: row 0 = N0, col 0 = E0, 1 m per cell
dtm, dsm = np.load(DIR + "/lidar/dtm_mosaic.npy"), np.load(DIR + "/lidar/dsm_mosaic.npy")
pix = lambda E, Nn: (E - E0, N0 - Nn)                # (col, row)
def sample(a, E, Nn):
    return float(nd.map_coordinates(a, [[N0 - Nn], [E - E0]], order=1)[0])
# lab x = east, z = south, origin at the square centre
base = sample(dtm, CE, CN)
cs = np.arange(N + 1) * CELL - SIZE / 2
gx, gz = np.meshgrid(cs, cs)
hm = np.round(nd.map_coordinates(dtm, [N0 - (CN - gz), CE + gx - E0], order=1) - base, 2).ravel().tolist()

# roads: every kept OSM way as a graph, clipped to the square, split into chains at junctions and ends.
# Ways come from roads_keep_*.json ({"keep": [way ids]}) when present, else track/unclassified not hidden under canopy.
import argparse, glob
tr = Transformer.from_crs(4326, 27700, always_xy=True)
root = ET.parse(DIR + "/osm.xml").getroot()
nodes = {n.get('id'): tr.transform(float(n.get('lon')), float(n.get('lat'))) for n in root.iter('node')}
HALF = SIZE / 2 - 10
chm_raw = np.nan_to_num(dsm - dtm)
canopy = lambda E, Nn: float(nd.map_coordinates(nd.minimum_filter(chm_raw[max(0,int(N0-Nn)-3):int(N0-Nn)+4, max(0,int(E-E0)-3):int(E-E0)+4], 3), [[3], [3]], order=0)[0])
keep = None
for f in sorted(glob.glob(DIR + "/roads_keep_*.json")):
    keep = (keep or set()) | set(map(str, json.load(open(f))["keep"]))
def clip(a, b):  # Liang-Barsky: the part of segment a-b inside the square minus 10 m, as (t0, t1) or None
    t0, t1 = 0.0, 1.0
    for p, q in ((a[0] - b[0], a[0] - (CE - HALF)), (b[0] - a[0], CE + HALF - a[0]), (a[1] - b[1], a[1] - (CN - HALF)), (b[1] - a[1], CN + HALF - a[1])):
        if p == 0:
            if q < 0: return None
        elif p < 0: t0 = max(t0, q / p)
        else: t1 = min(t1, q / p)
    return (t0, t1) if t0 < t1 else None
pos, adj, ew = {}, {}, {}
def half_width(t):  # OSM here has no width tags, so guess from the road class and track grade (1 = firmest); 3.0 marks a paved public road
    if t.get('highway') in ('unclassified', 'tertiary', 'secondary', 'primary'): return 3.0
    if t.get('highway') == 'service': return 2.5
    return {'grade1': 2.6, 'grade2': 2.2, 'grade3': 1.9, 'grade4': 1.7, 'grade5': 1.6}.get(t.get('tracktype'), 2.2 if t.get('highway') == 'track' else 1.8)
def vertex(a_id, a, b, t):  # an original node at t=0/1, else a new node where the segment meets the square's edge
    if t == 0: k, p = a_id[0], a
    elif t == 1: k, p = a_id[1], b
    else: p = (a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t); k = ("cut", round(p[0], 2), round(p[1], 2))
    pos[k] = p; return k
for w in root.iter('way'):
    t = {k.get('k'): k.get('v') for k in w.iter('tag')}
    if keep is not None:
        if w.get('id') not in keep: continue
    elif t.get('highway') not in ('track', 'unclassified'): continue
    hw = half_width(t)
    ids = [x.get('ref') for x in w.iter('nd') if x.get('ref') in nodes]
    for ia, ib in zip(ids, ids[1:]):
        a, b = nodes[ia], nodes[ib]; c = clip(a, b)
        if not c: continue
        if keep is None and canopy((a[0] + b[0]) / 2, (a[1] + b[1]) / 2) >= 4: continue  # a "track" under full canopy isn't drivable
        u, v = vertex((ia, ib), a, b, c[0]), vertex((ia, ib), a, b, c[1])
        if u != v: adj.setdefault(u, set()).add(v); adj.setdefault(v, set()).add(u); ew[frozenset((u, v))] = hw
plen = lambda ks: sum(math.dist(pos[x], pos[y]) for x, y in zip(ks, ks[1:]))
brk = {k for k, n in adj.items() if len(n) != 2}
used, chains = set(), []
def walk(path):
    while path[-1] not in brk:
        nxt = [x for x in adj[path[-1]] if x != path[-2]]
        if not nxt or frozenset((path[-1], nxt[0])) in used: break
        used.add(frozenset((path[-1], nxt[0]))); path.append(nxt[0])
    return path
for s0 in brk:
    for n1 in adj[s0]:
        if frozenset((s0, n1)) not in used:
            used.add(frozenset((s0, n1))); chains.append(walk([s0, n1]))
for s0 in adj:  # pure loops (no junction): cut in half so each piece has distinct ends
    for n1 in adj[s0]:
        if frozenset((s0, n1)) not in used:
            used.add(frozenset((s0, n1))); p = walk([s0, n1]); h = len(p) // 2; chains += [p[:h + 1], p[h:]]
deg = lambda k: len(adj[k])
chains = [c for c in chains if not (deg(c[0]) == 1 and deg(c[-1]) == 1 and plen(c) < 20)
          and not ((deg(c[0]) == 1) != (deg(c[-1]) == 1) and plen(c) < 8)]
def dp(p, eps):  # Douglas-Peucker
    if len(p) < 3: return p
    a, b = np.array(p[0]), np.array(p[-1]); ab = b - a; L = np.linalg.norm(ab) or 1
    d = [abs(ab[0] * (q[1] - a[1]) - ab[1] * (q[0] - a[0])) / L for q in p[1:-1]]; i = int(np.argmax(d)) + 1
    return dp(p[:i + 1], eps)[:-1] + dp(p[i:], eps) if d[i - 1] > eps else [p[0], p[-1]]
chains.sort(key=plen, reverse=True)
def node_widths(c):  # a node takes the wider of the two ways it joins
    ws = [ew[frozenset(e)] for e in zip(c, c[1:])]
    return {pos[k]: max(ws[max(i - 1, 0)], ws[min(i, len(ws) - 1)]) for i, k in enumerate(c)}
def chain_nodes(c):
    w = node_widths(c)
    return [{"x": round(E - CE, 1), "z": round(CN - Nn, 1), "w": w[(E, Nn)], "m": None, "tension": 1, **({"tarmac": True} if w[(E, Nn)] >= 3 else {})}
            for E, Nn in dp([pos[k] for k in c], 4)]
roads = [chain_nodes(c) for c in chains]
ends = Counter(k for c in chains for k in (c[0], c[-1]))
total = sum(plen(c) for c in chains)

# trees: one per canopy peak in the LiDAR (DSM - DTM). Species from what the photos and satellite show:
#   dark canopy in dense plantation -> Sitka spruce (young spruce where it's under 13 m);
#   bright canopy (broadleaves read lighter green from above), mostly along roads, rides and the forest edge ->
#   birch / alder / rowan by height, alder more on low wet ground; low growth (1-3 m) in the open -> scrub.
from PIL import Image
sat = np.asarray(Image.open(DIR + "/satellite.jpg").convert("RGB")).astype(float)
sat_lum = nd.uniform_filter(0.3 * sat[..., 0] + 0.59 * sat[..., 1] + 0.11 * sat[..., 2], 7)
R = 6378137; mx = lambda lon: R * math.radians(lon); my = lambda lat: R * math.log(math.tan(math.pi / 4 + math.radians(lat) / 2))
lon0, lat0, lon1, lat1 = META["sat_bbox"]
sx0, sx1, sy0, sy1 = mx(lon0), mx(lon1), my(lat0), my(lat1)
to_ll = Transformer.from_crs(27700, 4326, always_xy=True)
def sat_at(E, Nn):
    lo, la = to_ll.transform(E, Nn)
    c, r = (mx(lo) - sx0) / (sx1 - sx0) * sat.shape[1], (sy1 - my(la)) / (sy1 - sy0) * sat.shape[0]
    return sat_lum[int(min(max(r, 0), sat.shape[0] - 1)), int(min(max(c, 0), sat.shape[1] - 1))]
chm = nd.gaussian_filter(np.nan_to_num(dsm - dtm), 1)
c0, r0 = pix(CE - SIZE / 2, CN + SIZE / 2)
win = chm[int(r0):int(r0) + SIZE, int(c0):int(c0) + SIZE]
ground = dtm[int(r0):int(r0) + SIZE, int(c0):int(c0) + SIZE]
cover = nd.uniform_filter((win > 3).astype(float), 31)            # share of canopy within ~15 m
low_ground = ground < nd.uniform_filter(ground, 151) - 3           # hollows and the valley floor, where alder grows
lum_cut = 67                                                       # dark/bright split found on the satellite image earlier
# metres from the road, as a raster over the square (the road's polyline drawn in, then a distance transform)
from PIL import ImageDraw
mask = Image.new("L", (SIZE, SIZE), 0)
for ch in roads: ImageDraw.Draw(mask).line([(n["x"] + SIZE / 2, n["z"] + SIZE / 2) for n in ch], fill=255, width=3)
road_d = nd.distance_transform_edt(np.asarray(mask) == 0)
rng = np.random.default_rng(1)
trees = []
def add(r, c, kind, h):
    s = round(h / KH[kind], 2)
    trees.append({"x": round(c - SIZE / 2 + rng.uniform(-0.4, 0.4), 1), "z": round(r - SIZE / 2 + rng.uniform(-0.4, 0.4), 1),
                  "rot": int(rng.integers(360)), "sx": s, "sy": s, "kind": "levels/trees/" + kind + ".png"})
KH = {"sitka_spruce": 22, "young_spruce": 10, "birch": 9, "rowan": 5, "alder": 9, "scrub": 1.4}
peaks = (win == nd.maximum_filter(win, size=7)) & (win > 3.5)
for r, c in zip(*np.nonzero(peaks)):
    h = float(win[r, c]); E, Nn = CE - SIZE / 2 + c, CN + SIZE / 2 - r
    bright = sat_at(E, Nn) > lum_cut
    verge = 4 < road_d[r, c] < 18 and cover[r, c] < 0.8  # the photos: a broadleaf fringe between the road and the spruce wall
    if road_d[r, c] <= 4: continue
    if not bright and cover[r, c] > 0.5 and not verge:
        add(r, c, "sitka_spruce" if h >= 13 else "young_spruce", h)
    elif h < 7:
        add(r, c, "rowan", max(h, 3))
    else:
        add(r, c, "alder" if low_ground[r, c] and rng.random() < 0.7 else ("birch" if rng.random() < 0.65 else "alder"), min(h, 16))
scrub = (win == nd.maximum_filter(win, size=5)) & (win > 0.8) & (win < 3.5) & (cover < 0.4) & (road_d > 4)
sr, sc = np.nonzero(scrub)
for r, c in zip(sr, sc):
    if rng.random() < min(1, 900 * (SIZE / 600) ** 2 / max(1, len(sr))): add(r, c, "scrub", float(win[r, c]))
# the verges are bushy in the photos even where the LiDAR sees nothing taller than grass
vr, vc = np.nonzero((road_d > 4.5) & (road_d < 14) & (win < 3))
for k in rng.choice(len(vr), size=min(len(vr), int(300 * (SIZE / 600) ** 2)), replace=False): add(vr[k], vc[k], "scrub", rng.uniform(0.8, 1.8))
print("species", dict(Counter(t["kind"].split("/")[-1][:-4] for t in trees)))
json.dump({"size": SIZE, "seed": 1, "relief": 0, "roads": roads, "trees": trees, "heightmap": hm}, open(DIR + "/level.json", "w"), separators=(",", ":"))
print(f"{len(roads)} chains, {sum(1 for n in ends.values() if n >= 3)} junctions, {total / 1000:.2f} km; {peaks.sum()} canopy peaks -> {len(trees)} trees; height range {min(hm):.0f}..{max(hm):.0f} m")
