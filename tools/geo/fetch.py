# Downloads the real-world data for one level square: Welsh Government LiDAR ground (DTM) and surface (DSM)
# heights, OpenStreetMap roads, and an Esri satellite image, into tools/geo/data/<name>/ for the other geo scripts.
# Usage: python fetch.py <name> <easting> <northing> [size_m]   (square centre in British National Grid metres)
import json, math, sys, os, urllib.request, numpy as np, tifffile
from pyproj import Transformer

name, CE, CN = sys.argv[1], float(sys.argv[2]), float(sys.argv[3])
SIZE = float(sys.argv[4]) if len(sys.argv) > 4 else 600
MARGIN = 300  # extra data around the square, so filters near its edge still see real neighbours
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "data", name)
os.makedirs(OUT + "/lidar", exist_ok=True)
UA = {"User-Agent": "level-editor-lab/1.0"}
get = lambda url: urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=120).read()

# LiDAR comes in 1 km tiles named by their south-west corner; the catalogue gives each tile's download links.
e0, e1 = int((CE - SIZE / 2 - MARGIN) // 1000), int((CE + SIZE / 2 + MARGIN) // 1000)
n0, n1 = int((CN - SIZE / 2 - MARGIN) // 1000), int((CN + SIZE / 2 + MARGIN) // 1000)
cat = json.loads(get("https://datamap.gov.wales/geoserver/ows?service=WFS&version=1.0.0&request=GetFeature"
                     "&typename=geonode%3Awelsh_government_lidar_tile_catalogue_2020_2023&outputFormat=json&srsName=EPSG%3A27700"
                     f"&BBOX={e0 * 1000 + 1},{n0 * 1000 + 1},{e1 * 1000 + 999},{n1 * 1000 + 999}"))
links = {}
for f in cat["features"]:
    x, y = f["geometry"]["coordinates"][0][0]
    links[(round(x / 1000), round(y / 1000))] = f["properties"]
cols, rows = e1 - e0 + 1, n1 - n0 + 1
for k in ("dtm", "dsm"):
    M = np.full((rows * 1000, cols * 1000), np.nan, np.float32)
    for i, e in enumerate(range(e0, e1 + 1)):
        for j, n in enumerate(range(n1, n0 - 1, -1)):  # north at the top
            if (e, n) not in links: sys.exit(f"no LiDAR tile at {e}km E {n}km N (outside Wales, or not in the 2020-23 survey)")
            path = f"{OUT}/lidar/{k}_{e}{n}.tif"
            if not os.path.exists(path): open(path, "wb").write(get("https://" + links[(e, n)][k + "_link"]))
            a = tifffile.imread(path).astype(np.float32); a[a < -1000] = np.nan
            M[j * 1000:(j + 1) * 1000, i * 1000:(i + 1) * 1000] = a
    np.save(f"{OUT}/lidar/{k}_mosaic.npy", M)

# The satellite image and OSM cover the same area in longitude/latitude.
to_ll = Transformer.from_crs(27700, 4326, always_xy=True)
corners = [to_ll.transform(CE + dx * (SIZE / 2 + MARGIN), CN + dy * (SIZE / 2 + MARGIN)) for dx in (-1, 1) for dy in (-1, 1)]
lon0, lon1 = min(c[0] for c in corners), max(c[0] for c in corners)
lat0, lat1 = min(c[1] for c in corners), max(c[1] for c in corners)
open(f"{OUT}/osm.xml", "wb").write(get(f"https://api.openstreetmap.org/api/0.6/map?bbox={lon0},{lat0},{lon1},{lat1}"))
# Requested in Web Mercator so the pixels are square and map linearly onto mercator x/y (see sat_bbox users).
R = 6378137
mx, my = (lambda lon: R * math.radians(lon)), (lambda lat: R * math.log(math.tan(math.pi / 4 + math.radians(lat) / 2)))
x0, x1, y0, y1 = mx(lon0), mx(lon1), my(lat0), my(lat1)
W = 2048; H = round(W * (y1 - y0) / (x1 - x0))
open(f"{OUT}/satellite.jpg", "wb").write(get("https://services.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/export"
                                             f"?bbox={x0},{y0},{x1},{y1}&bboxSR=3857&imageSR=3857&size={W},{H}&format=jpg&f=image"))

json.dump({"centre": [CE, CN], "size": SIZE, "mosaic_origin": [e0 * 1000, (n1 + 1) * 1000], "sat_bbox": [lon0, lat0, lon1, lat1]},
          open(f"{OUT}/meta.json", "w"))
print(f"{name}: {cols}x{rows} LiDAR tiles, satellite {W}x{H}, OSM {lon0:.4f},{lat0:.4f}..{lon1:.4f},{lat1:.4f}")
