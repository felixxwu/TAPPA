#!/usr/bin/env python3
"""Build the Alps' two conifer billboards from a CC0 source pack.

    textures/tree-snow.webp        dense spruce, snow painted onto the branch tops
    textures/tree-snow-laden.webp  scruffier spruce that already carries real snow

Run from the repo root:  python3 tools/gen_snow_trees.py
The source pack is downloaded on first run and cached in tools/.cache/.

SOURCE / LICENCE
    "high-res tree textures" by rubberduck, https://opengameart.org/content/high-res-tree-textures
    CC0 1.0 (public domain dedication) — no attribution required, no credits entry
    needed. Recorded here so the provenance of a shipped binary asset is not lost.

WHY TWO SPECIES
    The pack's densest conifer has the best silhouette but almost no snow on it
    (measured: 0.4% of opaque pixels are bright), while the one that genuinely carries
    snow (6.7%) is shorter and scruffier. Neither alone makes a convincing alpine
    stand, so the region mixes them — RegionLibrary's tree_mix already supports this
    (Greece runs 70/30). See features/snow-region.md.

WHY THE SNOW IS PAINTED, NOT DRAWN
    Snow settles on UPWARD-FACING surfaces. On a billboard the usable proxy is "an
    opaque pixel with mostly transparent pixels directly above it" — i.e. the top edge
    of a branch mass. Tinting those toward white puts snow exactly where a branch
    catches it and nowhere else, which is what stops it reading as a white wash over
    the whole tree. Photographic, so it matches the existing tree.png / tree-greece.webp
    cutouts rather than clashing with them.
"""

import io
import os
import random
import urllib.request
import zipfile

from PIL import Image, ImageFilter

SRC_URL = "https://opengameart.org/sites/default/files/trees_1K.zip"
CACHE = os.path.join(os.path.dirname(__file__), ".cache")
SHEET = "tree_collection_1K.png"

# Which segmented trees to use, left to right in the source sheet.
DENSE_INDEX = 0   # best silhouette, effectively bare
LADEN_INDEX = 2   # already carries real snow

TARGET_H = 256    # matches the existing tree.png billboard height

SEED = 20260816

# How many times colour is flooded outward before the alpha is closed. Must comfortably
# exceed the widest sky gap the close fills, or the middle of that gap stays black and
# shows up in game as a speck. 14 clears every gap in this pack with room to spare.
_BLEED_PASSES = 14

# Radius of the morphological close applied to the alpha before tracing.
#
# THIS VALUE HAS A CLIFF, and landing on the wrong side of it ships invisible trees.
# TreeSilhouette traces the cutout's OUTLINE into the billboard's geometry; fed a
# filigree of thin needle filaments it produces degenerate slivers with essentially no
# area, so the tree renders as a scatter of specks with no body. Measured fill of the
# traced mesh against its own bounding box, for the dense conifer:
#
#     close=3  ->   0.3%      close=7  -> 108%
#     close=5  ->   0.2%      close=9  -> 111%
#
# There is no gentle degradation between 5 and 7 — it is a step. 7 is the first value
# that works and the shipped trees sit there; do not lower it without re-measuring the
# traced AREA (a bounding box stays full-size even when the mesh is empty, so bbox is
# not a check). test_snow_region.gd asserts the area for exactly this reason.
_CLOSE_RADIUS = 7


def _fetch_sheet():
    os.makedirs(CACHE, exist_ok=True)
    local = os.path.join(CACHE, SHEET)
    if os.path.exists(local):
        return Image.open(local).convert("RGBA")
    print(f"downloading {SRC_URL} ...")
    req = urllib.request.Request(SRC_URL, headers={"User-Agent": "Mozilla/5.0"})
    with urllib.request.urlopen(req) as r:
        blob = r.read()
    with zipfile.ZipFile(io.BytesIO(blob)) as z:
        name = next(n for n in z.namelist() if n.endswith(SHEET))
        with open(local, "wb") as f:
            f.write(z.read(name))
    return Image.open(local).convert("RGBA")


def _segment(sheet):
    """Split the collection sheet into individual trees on empty alpha columns."""
    w, h = sheet.size
    alpha = sheet.split()[3].load()
    runs, start = [], None
    for x in range(w):
        used = any(alpha[x, y] > 40 for y in range(0, h, 3))
        if used and start is None:
            start = x
        elif not used and start is not None:
            if x - start > 40:
                runs.append((start, x))
            start = None
    if start is not None:
        runs.append((start, w))
    out = []
    for x0, x1 in runs:
        t = sheet.crop((x0, 0, x1, h))
        out.append(t.crop(t.getbbox()))
    return out


def _paint_snow(img, strength=0.85, depth=7, rng=None, bleed=3):
    """Tint upward-facing branch edges toward white.

    `depth` is how many pixels above a candidate must be clear for it to count as an
    exposed top edge — larger means only the most prominent branch shoulders catch
    snow, smaller frosts everything including the interior. `bleed` is how far the snow
    runs down the branch below that edge, i.e. how THICK each cap is.

    Note the interaction with _consolidate_alpha: closing the alpha's gaps removes many
    of the interior sky holes, and therefore many of the top edges this keys off, so a
    consolidated tree needs more bleed to carry the same amount of snow. Tune against
    the printed percentage rather than the parameters.
    """
    rng = rng or random.Random(SEED)
    img = img.convert("RGBA")
    w, h = img.size
    src = img.load()
    out = img.copy()
    dst = out.load()
    for x in range(w):
        for y in range(h):
            r, g, b, a = src[x, y]
            if a < 128:
                continue
            # Is this pixel on a top edge? Count clear pixels in the column above it.
            clear = 0
            for dy in range(1, depth + 1):
                yy = y - dy
                if yy < 0 or src[x, yy][3] < 128:
                    clear += 1
            if clear < depth - 1:
                continue
            # Break the edge up so the snow line is ragged, not a traced outline.
            k = strength * rng.uniform(0.45, 1.0)
            dst[x, y] = (
                int(r + (247 - r) * k),
                int(g + (250 - g) * k),
                int(b + (255 - b) * k),
                a,
            )
            # Let it bleed a pixel or two down the branch so it has thickness.
            for dy in range(1, rng.randint(1, bleed) + 1):
                yy = y + dy
                if yy >= h or src[x, yy][3] < 128:
                    break
                r2, g2, b2, a2 = src[x, yy]
                k2 = k * (0.55 ** dy)
                dst[x, yy] = (
                    int(r2 + (247 - r2) * k2),
                    int(g2 + (250 - g2) * k2),
                    int(b2 + (255 - b2) * k2),
                    a2,
                )
    return out


def _lift_shadows(img, floor_lum=62, desaturate=0.25):
    """Raise crushed blacks so no pixel reads as a speck against snow.

    These are photographs shot against a bright sky, so the shadow between the needles
    is clipped to near-black — 4% of the dense tree and 17% of the scruffy one. On a
    green summer stage that reads as depth. In a white-out alpine scene, surrounded by
    snow ground and a pale sky, each of those pixels reads as a black dot hanging in the
    air, which is what "dark specks around the trees" actually is. The billboard is an
    OPAQUE cutout, so every one of them is drawn.

    Lifting the floor keeps the tonal range (the tree still reads as dark against snow)
    while removing the pure blacks that pop. The slight desaturation goes with it: a
    conifer in flat overcast light is grey-green, not the saturated green of a sunlit
    photo.
    """
    img = img.convert("RGBA")
    px = img.load()
    w, h = img.size
    for y in range(h):
        for x in range(w):
            r, g, b, a = px[x, y]
            if a < 128:
                continue
            lum = 0.3 * r + 0.59 * g + 0.11 * b
            r = r + (lum - r) * desaturate
            g = g + (lum - g) * desaturate
            b = b + (lum - b) * desaturate
            if lum < floor_lum:
                # Compress toward the floor rather than clamping, so shadow detail
                # survives instead of flattening into one grey.
                k = (floor_lum - lum) / max(1.0, floor_lum)
                r += (floor_lum - r) * k
                g += (floor_lum - g) * k
                b += (floor_lum - b) * k
            px[x, y] = (
                max(0, min(255, int(r))),
                max(0, min(255, int(g))),
                max(0, min(255, int(b))),
                a,
            )
    return img


def _bright_fraction(img):
    """Percentage of opaque pixels that read as snow. The tuning feedback for the
    painter above — the two trees should land in the same rough band, or the mix
    reads as one snowy species next to one that missed the weather."""
    px = img.load()
    w, h = img.size
    tot = bright = 0
    for y in range(h):
        for x in range(w):
            r, g, b, a = px[x, y]
            if a > 128:
                tot += 1
                if (r + g + b) / 3 > 150:
                    bright += 1
    return 100.0 * bright / max(1, tot)


def _consolidate_alpha(img, close=_CLOSE_RADIUS):
    """Bridge the gaps in a photographic cutout's alpha so it traces to ONE body.

    Foliage.tree_silhouette_mesh runs TreeSilhouette.build over the alpha to make the
    billboard's geometry, and that tracer wants a coherent mass. A photographed conifer's
    alpha is not one: it is hundreds of disconnected needle and branch islands with sky
    between them. Fed that, the tracer skips island after island as degenerate and can
    emit a mesh with almost no geometry at all — measured, the scruffier of the two trees
    came out as 12 vertices 0.004 units tall, i.e. INVISIBLE IN GAME while looking
    perfectly fine as a texture.

    A morphological close (dilate then erode by the same radius) joins neighbouring
    islands without inflating the overall silhouette, so the tree keeps its shape and
    its photographic detail — only the sky gaps between adjacent needles close up.

    Verify with the vertex counts, not by eye: a texture that looks right can still
    trace to nothing.
    """
    img = img.convert("RGBA")
    w, h = img.size

    # 1. EXTEND THE COLOUR OUTWARD, THOROUGHLY. This is not cosmetic — it is the fix for
    # dark specks floating around the trees in game.
    #
    # The billboard is an OPAQUE cutout: TreeSilhouette traces a polygon from the alpha
    # and there is no alpha test at draw time, so every pixel inside that polygon is
    # drawn, including ones that were transparent. Closing the alpha (step 2) fills the
    # sky gaps between branches, and a cutout's transparent pixels carry whatever RGB
    # the encoder left — here, near-black. Fill them shallowly and the deeper gaps still
    # render as black flecks hanging in mid-air.
    #
    # So flood real foliage colour across every transparent pixel until nothing dark is
    # left for the polygon to reveal. Cheap at billboard resolution and done once,
    # offline.
    px = img.load()
    for _ in range(_BLEED_PASSES):
        snap = img.copy()
        sp = snap.load()
        changed = False
        for y in range(h):
            for x in range(w):
                if sp[x, y][3] >= 128:
                    continue
                acc, n = [0, 0, 0], 0
                for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                    xx, yy = x + dx, y + dy
                    if 0 <= xx < w and 0 <= yy < h and _has_colour(sp[xx, yy]):
                        for c in range(3):
                            acc[c] += sp[xx, yy][c]
                        n += 1
                if n:
                    px[x, y] = (acc[0] // n, acc[1] // n, acc[2] // n, px[x, y][3])
                    changed = True
        if not changed:
            break

    # 2. Close the alpha so the tree traces to ONE body (see the note on the tracer).
    r, g, b, a = img.split()
    a = a.filter(ImageFilter.MaxFilter(close))   # dilate: join neighbouring islands
    a = a.filter(ImageFilter.MinFilter(close))   # erode: give back the added margin
    img = Image.merge("RGBA", (r, g, b, a))

    # 3. Drop anything still detached from the trunk. Each surviving island would be
    # traced as its OWN little quad, which is a speck hanging in the air next to the
    # tree. Measured, a conifer here is >99% one component and the strays are 3-7 px,
    # so this removes visual noise and nothing else.
    return _largest_island_only(img)


# A pixel counts as a colour source only if it is opaque OR has already been filled by
# an earlier pass. Without the brightness floor the fill would happily spread the
# original black outward instead of replacing it.
def _has_colour(p):
    return p[3] >= 128 or sum(p[:3]) > 24


def _largest_island_only(img):
    """Keep the biggest connected opaque region; erase every other one."""
    w, h = img.size
    px = img.load()
    seen = [[False] * w for _ in range(h)]
    comps = []
    for y0 in range(h):
        for x0 in range(w):
            if seen[y0][x0] or px[x0, y0][3] < 128:
                continue
            stack, cells = [(x0, y0)], []
            seen[y0][x0] = True
            while stack:
                cx, cy = stack.pop()
                cells.append((cx, cy))
                for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                    nx, ny = cx + dx, cy + dy
                    if 0 <= nx < w and 0 <= ny < h and not seen[ny][nx] \
                            and px[nx, ny][3] >= 128:
                        seen[ny][nx] = True
                        stack.append((nx, ny))
            comps.append(cells)
    if not comps:
        return img
    comps.sort(key=len, reverse=True)
    for cells in comps[1:]:
        for x, y in cells:
            px[x, y] = (px[x, y][0], px[x, y][1], px[x, y][2], 0)
    return img


def _resize(img):
    w, h = img.size
    return img.resize((max(1, round(w * TARGET_H / h)), TARGET_H), Image.LANCZOS)


def main():
    rng = random.Random(SEED)
    trees = _segment(_fetch_sheet())
    print(f"segmented {len(trees)} trees from the sheet")

    # RESIZE FIRST, then paint. Painting at source resolution and downscaling
    # afterwards averages the snow away almost entirely — the branch edges are one or
    # two pixels wide at 1K, and an 8x reduction blends them back into the needles
    # (measured: the full-res pass survived as under 2% bright pixels). At billboard
    # resolution the branch masses are chunky enough that a top edge is several pixels
    # deep, so the snow lands as visible caps instead of a faint rime.
    dense = _paint_snow(_lift_shadows(_consolidate_alpha(_resize(trees[DENSE_INDEX]))), strength=0.95, depth=2, rng=rng, bleed=7)
    dense.save("textures/tree-snow.webp", lossless=True)
    print("wrote textures/tree-snow.webp  (%.1f%% snow)" % _bright_fraction(dense))

    # The laden one already has real snow; a lighter pass only, so the photographed
    # drifts stay the dominant read and the two trees still agree in tone.
    laden = _paint_snow(_lift_shadows(_consolidate_alpha(_resize(trees[LADEN_INDEX]))), strength=0.7, depth=2, rng=rng, bleed=6)
    laden.save("textures/tree-snow-laden.webp", lossless=True)
    print("wrote textures/tree-snow-laden.webp  (%.1f%% snow)" % _bright_fraction(laden))


if __name__ == "__main__":
    main()
