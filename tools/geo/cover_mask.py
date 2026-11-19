# Estimates a ground-cover type per metre of a level square from LiDAR canopy height + satellite colour, as a
# starting point to paint over in the level editor. Usage: python cover_mask.py <name>   (after make_level.py)
# Writes data/<name>/cover_index.png (pixel value = type id, row 0 = north edge = lab z -size/2), plus a coloured
# cover_mask.png and the matching satellite crop sat_crop.png for checking it by eye, and puts the cover into level.json.
import sys, os, json, math, numpy as np
from PIL import Image, ImageDraw
from pyproj import Transformer
from scipy import ndimage as nd
DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "data", sys.argv[1])
META = json.load(open(DIR + "/meta.json"))
(CE, CN), SIZE, (E0, N0) = META["centre"], int(META["size"]), META["mosaic_origin"]
dtm, dsm = np.load(DIR + "/lidar/dtm_mosaic.npy"), np.load(DIR + "/lidar/dsm_mosaic.npy")
c0, r0 = int(CE - SIZE // 2 - E0), int(N0 - (CN + SIZE // 2))
chm = nd.gaussian_filter(np.nan_to_num(dsm - dtm), 1)[r0:r0 + SIZE, c0:c0 + SIZE]
# satellite RGB resampled onto the same 1 m grid (rows = south, cols = east)
sat = np.asarray(Image.open(DIR + "/satellite.jpg").convert("RGB")).astype(float)
R = 6378137; mx = lambda lon: R * np.radians(lon); my = lambda lat: R * np.log(np.tan(np.pi / 4 + np.radians(lat) / 2))
lon0, lat0, lon1, lat1 = META["sat_bbox"]
sx0, sx1, sy0, sy1 = mx(lon0), mx(lon1), my(lat0), my(lat1)
cc, rr = np.meshgrid(np.arange(SIZE), np.arange(SIZE))
lo, la = Transformer.from_crs(27700, 4326, always_xy=True).transform(CE - SIZE / 2 + cc + 0.5, CN + SIZE / 2 - rr - 0.5)
sc = np.clip(((mx(lo) - sx0) / (sx1 - sx0) * sat.shape[1]).astype(int), 0, sat.shape[1] - 1)
sr = np.clip(((sy1 - my(la)) / (sy1 - sy0) * sat.shape[0]).astype(int), 0, sat.shape[0] - 1)
rgb = nd.uniform_filter(sat[sr, sc], (5, 5, 1))
Image.fromarray(sat[sr, sc].astype(np.uint8)).save(DIR + "/sat_crop.png")
r, g, b = rgb[..., 0], rgb[..., 1], rgb[..., 2]
lum = 0.3 * r + 0.59 * g + 0.11 * b
straw = (r / np.maximum(g, 1) > 0.88) & (lum > 80)          # tan/beige: dead moor grass
dark = lum < 70                                             # heather reads dark from above...
shadowed = nd.maximum_filter(chm > 6, 9)                   # ...but so does the shadow a spruce wall casts, so skip near tall trees
level = json.load(open(DIR + "/level.json"))
m = Image.new("L", (SIZE, SIZE), 0)
for road in level.get("roads") or [level["road"]]:
    ImageDraw.Draw(m).line([(n["x"] + SIZE / 2, n["z"] + SIZE / 2) for n in road], fill=255, width=4)
road_d = nd.distance_transform_edt(np.asarray(m) == 0)
cls = np.zeros((SIZE, SIZE), np.uint8)                      # 0 = nothing (under forest canopy, or road)
open_ = chm < 3
cls[open_] = 1                                              # verge / meadow grass by default
cls[open_ & straw] = 2                                      # molinia
cls[open_ & (chm > 0.6)] = 4                                # low woody growth the LiDAR can see: bilberry / scrub mounds
cls[open_ & (chm <= 0.6) & dark & ~shadowed & (road_d > 6)] = 3         # heather
cls[open_ & (road_d < 5)] = 1                               # the mown verge right by the road is always grass
cls[road_d < 2] = 0
cls = nd.median_filter(cls, 5)                              # drop single-pixel speckle
PAL = np.array([[0, 0, 0], [120, 200, 60], [200, 180, 130], [110, 60, 100], [40, 110, 40]], np.uint8)
Image.fromarray(PAL[cls]).save(DIR + "/cover_mask.png")
Image.fromarray(cls).save(DIR + "/cover_index.png")
import base64                                               # the level editor's packed cover: one byte per cell, base64
level["cover"] = base64.b64encode(cls.tobytes()).decode()
json.dump(level, open(DIR + "/level.json", "w"), separators=(",", ":"))
names = ["none", "verge grass", "molinia", "heather", "bilberry/scrub"]
print({names[i]: f"{(cls == i).mean() * 100:.0f}%" for i in range(5)})
