# Builds a square around a fetched level's centre on one British National Grid, north-up:
# satellite (0.5 m/px), LiDAR DTM/DSM (1 m/px) and OSM roads, plus an overlay to check they line up.
# Usage: python align.py <data_dir> [size_m]   (needs fetch.py's meta.json, lidar mosaics and an osm xml in data_dir)
import io, json, math, os, sys, urllib.request, concurrent.futures as cf
import numpy as np, xml.etree.ElementTree as ET
from PIL import Image, ImageDraw
from pyproj import Transformer
from scipy import ndimage as nd

D = sys.argv[1]
SIZE = int(sys.argv[2]) if len(sys.argv) > 2 else 2000
TAG = f"{SIZE // 1000}km" if SIZE % 1000 == 0 else f"{SIZE}m"
RES, LEVEL = 0.5, 600
meta = json.load(open(f"{D}/meta.json"))
CE, CN = meta["centre"]
E0, N1 = CE - SIZE / 2, CN + SIZE / 2  # top-left corner
PX = int(SIZE / RES)
to_m = Transformer.from_crs(27700, 3857, always_xy=True)
to_bng = Transformer.from_crs(4326, 27700, always_xy=True)

# satellite: Esri z18 tiles, then resample each BNG pixel from the web-mercator mosaic
Z, R = 18, 20037508.342789244
TS = 2 * R / 2 ** Z / 256
cs = [to_m.transform(CE + dx * SIZE / 2, CN + dy * SIZE / 2) for dx in (-1, 1) for dy in (-1, 1)]
tx0, tx1 = int((min(c[0] for c in cs) + R) / (TS * 256)), int((max(c[0] for c in cs) + R) / (TS * 256))
ty0, ty1 = int((R - max(c[1] for c in cs)) / (TS * 256)), int((R - min(c[1] for c in cs)) / (TS * 256))
def tile(xy):
    x, y = xy
    u = f"https://services.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{Z}/{y}/{x}"
    for _ in range(4):
        try: return xy, Image.open(io.BytesIO(urllib.request.urlopen(urllib.request.Request(u, headers={"User-Agent": "level-editor-lab/1.0"}), timeout=30).read())).convert("RGB")
        except Exception as e: err = e
    raise err
mos = Image.new("RGB", ((tx1 - tx0 + 1) * 256, (ty1 - ty0 + 1) * 256))
with cf.ThreadPoolExecutor(8) as ex:
    for (x, y), im in ex.map(tile, [(x, y) for x in range(tx0, tx1 + 1) for y in range(ty0, ty1 + 1)]):
        mos.paste(im, ((x - tx0) * 256, (y - ty0) * 256))
print("tiles", (tx1 - tx0 + 1) * (ty1 - ty0 + 1))
mos = np.asarray(mos)
sat = np.empty((PX, PX, 3), np.uint8)
cc = np.arange(PX)
for r in range(0, PX, 500):  # strips keep the per-pixel coordinate arrays small on big squares
    c2, rr = np.meshgrid(cc, np.arange(r, min(r + 500, PX)))
    mx, my = to_m.transform(E0 + (c2 + 0.5) * RES, N1 - (rr + 0.5) * RES)
    px = (mx + R) / TS - tx0 * 256 - 0.5
    py = (R - my) / TS - ty0 * 256 - 0.5
    for k in range(3):
        sat[r:r + len(rr), :, k] = nd.map_coordinates(mos[..., k], [py, px], order=1).clip(0, 255)
del mos
Image.fromarray(sat).save(f"{D}/satellite_{TAG}.jpg", quality=92)

# LiDAR: crop the 1 km-tile mosaic (origin in meta.json) to the square
me, mn = meta["mosaic_origin"]
c0, r0 = int(E0 - me), int(mn - N1)
for k in ("dtm", "dsm"):
    a = np.load(f"{D}/lidar/{k}_mosaic.npy")[r0:r0 + SIZE, c0:c0 + SIZE]
    assert a.shape == (SIZE, SIZE) and not np.isnan(a).all()
    np.save(f"{D}/{k}_{TAG}.npy", a)
    print(k, "nan", int(np.isnan(a).sum()), "range", np.nanmin(a), np.nanmax(a))

# OSM roads (any highway) to BNG metres
osm = f"{D}/osm_{TAG}.xml" if os.path.exists(f"{D}/osm_{TAG}.xml") else f"{D}/osm.xml"
root = ET.parse(osm).getroot()
nodes = {n.get("id"): to_bng.transform(float(n.get("lon")), float(n.get("lat"))) for n in root.iter("node")}
roads = []
for w in root.iter("way"):
    tags = {t.get("k"): t.get("v") for t in w.iter("tag")}
    if "highway" in tags:
        roads.append((w.get("id"), tags, [nodes[n.get("ref")] for n in w.iter("nd") if n.get("ref") in nodes]))
chm = np.nan_to_num(np.load(f"{D}/dsm_{TAG}.npy") - np.load(f"{D}/dtm_{TAG}.npy"))
def canopy(p):  # share of the way that runs under trees taller than 4 m; make_level drops "tracks" hidden in forest
    s = [(a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t) for a, b in zip(p, p[1:]) for t in np.linspace(0, 1, max(2, int(math.dist(a, b) / 2)))]
    s = [(int(N1 - n), int(e - E0)) for e, n in s if 0 <= e - E0 < SIZE and 0 <= N1 - n < SIZE]
    return round(float(np.mean([chm[r, c] >= 4 for r, c in s])), 2) if s else None
json.dump({"origin_bng_top_left": [E0, N1], "size_m": SIZE,
           "roads": [{"id": i, "highway": t["highway"], "tags": t, "canopy": canopy(p), "bng": [[round(e, 2), round(n, 2)] for e, n in p]} for i, t, p in roads]},
          open(f"{D}/roads_{TAG}.json", "w"))
print("roads", len(roads))

# overlay at 1 m/px: satellite x hillshade, OSM in red, the 600 m level square in yellow
dtm = np.load(f"{D}/dtm_{TAG}.npy")
dtm = np.nan_to_num(dtm, nan=float(np.nanmean(dtm)))
gy, gx = np.gradient(dtm)
shade = np.clip(0.6 + 0.4 * (-gx - gy) / np.hypot(1, np.hypot(gx, gy)), 0.3, 1.2)
small = np.asarray(Image.fromarray(sat).resize((SIZE, SIZE), Image.BILINEAR), np.float32)
Image.fromarray(small.astype(np.uint8)).save(f"{D}/satellite_{TAG}_1m.jpg", quality=90)
ov = Image.fromarray((small * shade[..., None]).clip(0, 255).astype(np.uint8))
dr = ImageDraw.Draw(ov)
for _, _, p in roads:
    dr.line([(e - E0, N1 - n) for e, n in p], fill=(255, 40, 40), width=max(2, SIZE // 1000))
c, h = SIZE / 2, LEVEL / 2
dr.rectangle([c - h, c - h, c + h, c + h], outline=(255, 230, 0), width=max(2, SIZE // 1000))
ov.save(f"{D}/aligned_{TAG}_overlay.jpg", quality=88)
open(f"{D}/README_{TAG}.txt", "w").write(
    f"{SIZE} m square centred on BNG {CE:.0f} E, {CN:.0f} N, north up, top-left = BNG {E0:.0f} E, {N1:.0f} N.\n"
    f"satellite_{TAG}.jpg: {PX}x{PX}, {RES} m/px (Esri World Imagery z18, reprojected to BNG).\n"
    f"dtm_{TAG}.npy / dsm_{TAG}.npy: {SIZE}x{SIZE} float32 heights, 1 m/px, same grid (row 0 = north).\n"
    f"roads_{TAG}.json: OSM highway ways in BNG metres. aligned_{TAG}_overlay.jpg: all three over each other (1 m/px).\n")
