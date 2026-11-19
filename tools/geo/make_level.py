# Builds a level-editor-lab save from fetch.py's data: LiDAR ground as the heightmap, the longest drivable OSM
# track as the road, and a tree at every LiDAR canopy peak with its species guessed from height and satellite colour.
# Usage: python make_level.py <name>   -> data/<name>/level.json (unpacked; pack_level.js packs it for tools/levels/)
import json, math, sys, os, numpy as np, xml.etree.ElementTree as ET
from pyproj import Transformer
from scipy import ndimage as nd
DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "data", sys.argv[1])
META = json.load(open(DIR + "/meta.json"))
CE, CN = META["centre"]                              # square centre, British National Grid metres
SIZE = int(META["size"]); N = SIZE // 3; CELL = SIZE / N
E0, N0 = META["mosaic_origin"]                       # the mosaic's north-west corner: row 0 = N0, col 0 = E0, 1 m per cell
dtm, dsm = np.load(DIR + "/lidar/dtm_mosaic.npy"), np.load(DIR + "/lidar/dsm_mosaic.npy")
pix = lambda E, Nn: (E - E0, N0 - Nn)                # (col, row)
def sample(a, E, Nn):
    return float(nd.map_coordinates(a, [[N0 - Nn], [E - E0]], order=1)[0])
# lab x = east, z = south, origin at the square centre
hm, base = [], sample(dtm, CE, CN)
for r in range(N + 1):
    for c in range(N + 1):
        x, z = c * CELL - SIZE / 2, r * CELL - SIZE / 2
        hm.append(round(sample(dtm, CE + x, CN - z) - base, 2))

# roads: track + unclassified ways as a graph, clipped to the square; take the longest simple path
tr = Transformer.from_crs(4326, 27700, always_xy=True)
root = ET.parse(DIR + "/osm.xml").getroot()
nodes = {n.get('id'): tr.transform(float(n.get('lon')), float(n.get('lat'))) for n in root.iter('node')}
inside = lambda p: abs(p[0] - CE) < SIZE / 2 - 10 and abs(p[1] - CN) < SIZE / 2 - 10
chm_raw = np.nan_to_num(dsm - dtm)
canopy = lambda E, Nn: float(nd.map_coordinates(nd.minimum_filter(chm_raw[max(0,int(N0-Nn)-3):int(N0-Nn)+4, max(0,int(E-E0)-3):int(E-E0)+4], 3), [[3], [3]], order=0)[0])
adj = {}
for w in root.iter('way'):
    t = {k.get('k'): k.get('v') for k in w.iter('tag')}
    if t.get('highway') not in ('track', 'unclassified'): continue
    ids = [x.get('ref') for x in w.iter('nd')]
    for a, b in zip(ids, ids[1:]):
        mid = ((nodes[a][0] + nodes[b][0]) / 2, (nodes[a][1] + nodes[b][1]) / 2)
        if inside(nodes[a]) and inside(nodes[b]) and canopy(*mid) < 4:  # a "track" under full canopy isn't a drivable road
            d = math.dist(nodes[a], nodes[b]); adj.setdefault(a, []).append((b, d)); adj.setdefault(b, []).append((a, d))
def angle(a, b, c):  # how sharply the path turns at b, degrees
    d1, d2 = (b[0] - a[0], b[1] - a[1]), (c[0] - b[0], c[1] - b[1])
    return math.degrees(abs(math.atan2(d1[0] * d2[1] - d1[1] * d2[0], d1[0] * d2[0] + d1[1] * d2[1])))
def far(src):  # farthest node by path length, DFS with no revisits (graph is small and mostly a tree)
    best = (0, [src]); stack = [(src, 0, [src], {src})]
    while stack:
        u, L, path, seen = stack.pop()
        if L > best[0]: best = (L, path)
        for v, d in adj[u]:
            turn = 0 if len(path) < 2 else angle(nodes[path[-2]], nodes[u], nodes[v])
            if v not in seen and turn < 100 and len(stack) < 200000: stack.append((v, L + d, path + [v], seen | {v}))
    return best
ends = [n for n in adj if len(adj[n]) == 1] or list(adj)
best = max((far(e) for e in ends), key=lambda b: b[0])
pts = [nodes[i] for i in best[1]]
def dp(p, eps):  # Douglas-Peucker
    if len(p) < 3: return p
    a, b = np.array(p[0]), np.array(p[-1]); ab = b - a; L = np.linalg.norm(ab) or 1
    d = [abs(np.cross(ab, np.array(q) - a)) / L for q in p[1:-1]]; i = int(np.argmax(d)) + 1
    return dp(p[:i + 1], eps)[:-1] + dp(p[i:], eps) if d[i - 1] > eps else [p[0], p[-1]]
road = [{"x": round(E - CE, 1), "z": round(CN - Nn, 1), "w": 2.2, "m": None, "tension": 1} for E, Nn in dp(pts, 4)]

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
ImageDraw.Draw(mask).line([(n["x"] + SIZE / 2, n["z"] + SIZE / 2) for n in road], fill=255, width=3)
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
    if rng.random() < min(1, 900 / max(1, len(sr))): add(r, c, "scrub", float(win[r, c]))
# the verges are bushy in the photos even where the LiDAR sees nothing taller than grass
vr, vc = np.nonzero((road_d > 4.5) & (road_d < 14) & (win < 3))
for k in rng.choice(len(vr), size=min(len(vr), 300), replace=False): add(vr[k], vc[k], "scrub", rng.uniform(0.8, 1.8))
from collections import Counter
print("species", dict(Counter(t["kind"].split("/")[-1][:-4] for t in trees)))
json.dump({"seed": 1, "relief": 0, "road": road, "trees": trees, "heightmap": hm}, open(DIR + "/level.json", "w"), separators=(",", ":"))
print(f"road {best[0]:.0f} m, {len(road)} nodes; {peaks.sum()} canopy peaks -> {len(trees)} trees; height range {min(hm):.0f}..{max(hm):.0f} m")
