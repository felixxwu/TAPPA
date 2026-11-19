# Top-down preview of make_level.py's output: hillshade, trees coloured by species, the road.
# Usage: python preview.py <name>   -> data/<name>/level_preview.png
import json, sys, os, numpy as np
from PIL import Image, ImageDraw
DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "data", sys.argv[1])
L = json.load(open(DIR + "/level.json")); n = int(len(L["heightmap"]) ** 0.5); S = (n - 1) * 3
h = np.array(L["heightmap"]).reshape(n, n)
gy, gx = np.gradient(h); s = np.clip(0.8 - (gx + gy) / 3 * 1.5, 0.3, 1.3)
img = Image.fromarray((np.stack([s * 130, s * 160, s * 110], -1)).clip(0, 255).astype(np.uint8)).resize((1000, 1000)); d = ImageDraw.Draw(img)
k = 1000 / S; P = lambda x, z: ((x + S / 2) * k, (z + S / 2) * k)
COL = {"sitka_spruce": (20, 45, 25), "young_spruce": (40, 80, 45), "birch": (230, 230, 120), "rowan": (230, 120, 60), "alder": (90, 200, 90), "scrub": (190, 160, 230)}
for t in sorted(L["trees"], key=lambda t: t["kind"].startswith("levels/trees/s")):
    x, y = P(t["x"], t["z"]); r = max(2, 2.5 * t["sx"] * k); d.ellipse([x - r, y - r, x + r, y + r], fill=COL[t["kind"].split("/")[-1][:-4]])
d.line([P(n["x"], n["z"]) for n in L["road"]], fill=(255, 255, 255), width=5)
img.save(DIR + "/level_preview.png")
