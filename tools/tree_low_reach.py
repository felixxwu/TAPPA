# Prints how far each tree atlas spreads from its trunk in its lowest 3 m, for the `low` field of KINDS in tools/level_editor_lab.html.
# Run from the repo root after re-exporting an atlas: python3 tools/tree_low_reach.py (needs Pillow).
from PIL import Image

LOW_M = 3.0
HEIGHTS = {"tree.png": 9.375, "tree-greece.webp": 4.0, "tree-taiga.webp": 22.5, "tree-snow.webp": 12.9,
           "tree-snow-laden.webp": 12.4, "levels/trees/sitka_spruce.png": 22, "levels/trees/young_spruce.png": 10,
           "levels/trees/birch.png": 9, "levels/trees/rowan.png": 5, "levels/trees/alder.png": 9, "levels/trees/scrub.png": 1.4}

for kind, h0 in HEIGHTS.items():
    im = Image.open(("tools/" if "/" in kind else "textures/") + kind).getchannel("A")
    w, h = im.size
    fw, a, mpp = w // 6, im.load(), h0 / h
    ds = sorted(abs(x + 0.5 - fw / 2) * mpp for f in range(6) for y in range(h - min(h, round(LOW_M / h0 * h)), h)
                for x in range(fw) if a[f * fw + x, y] > 100)
    # The 95th percentile, so a few long bare twigs don't push the whole species back from the road.
    print(f'"{kind}": low {ds[int(len(ds) * 0.95)]:.1f}')
