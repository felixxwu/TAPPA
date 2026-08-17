#!/usr/bin/env python3
"""Build the taiga region's spire billboard from the same CC0 source pack as the Alps.

    textures/tree-taiga.webp   tall narrow spruce, bare lower trunk

Run from the repo root:  python3 tools/gen_taiga_tree.py

SOURCE / LICENCE
    "high-res tree textures" by rubberduck, https://opengameart.org/content/high-res-tree-textures
    CC0 1.0 (public domain dedication) — no attribution required, no credits entry
    needed. The pack is already cached in tools/.cache/ by gen_snow_trees.py, and this
    script reuses that download plus that script's segmentation and alpha
    consolidation. Recorded here as well so the provenance of a shipped binary asset is
    not lost if the two tools ever drift apart.

WHY THIS TREE
    The pack holds seven conifers. The Alps take #0 (densest silhouette) and #2 (the
    one carrying real snow); of the five left, #5 is by a wide margin the narrowest —
    natural w/h 0.30 against 0.40-0.63 for the rest — with a bare lower trunk and a
    single leader. That is the black-spruce spire, and it is the whole point of the
    taiga region: the silhouette does the work of making the corner read as somewhere
    else, since the region otherwise shares home's sky, gravel and tarmac.

WHY NO SNOW PASS AND NO SHADOW LIFT
    Both exist in gen_snow_trees.py to solve problems this tree does not have. The snow
    painter is obvious; the shadow lift is subtler — it raises crushed blacks because on
    a white-out alpine stage every clipped pixel reads as a speck hanging in the air.
    The taiga stands on home's green ground under home's sky, exactly like tree.png,
    where those same shadows read as depth between the needles. So this is a straight
    cut: consolidate the alpha, resize, ship.

WHY IT IS RENDERED TALLER THAN THE OTHER BILLBOARDS
    Every other tree is TARGET_H 256; this one is 384, purely to spend texels where
    they are seen. The region draws this species at roughly twice the height of the
    home broadleaf (RegionLibrary's taiga `size_scale`), so at 256 it would cover about
    twice the screen height of tree.png with the same number of texels — visibly softer
    than every other tree in the game, and softest exactly along the whorl edges that
    make the silhouette read.

    It is NOT about the close radius blobbing the cutout. That was the initial theory,
    on the reasoning that _consolidate_alpha's fixed 7 px close eats proportionally more
    of the narrowest tree in the pack. Measured across resolutions, the effect is real
    but gentle and has no cliff — opaque fill of the bounding box runs 39.8% at 192,
    38.8% at 256, 37.7% at 320, 36.4% at 384, 35.3% at 448. The whorls survive at every
    one of them, so 256 would have traced perfectly well. Recorded because the
    _CLOSE_RADIUS note next door documents a genuine cliff, and it would be easy to
    assume this tree sits near one too.
"""

import os
import sys

from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from gen_snow_trees import _consolidate_alpha, _fetch_sheet, _segment

# Which segmented tree, left to right in the source sheet. See "WHY THIS TREE".
SPIRE_INDEX = 5

# Taller than the other billboards on purpose — see "WHY IT IS RENDERED TALLER".
TARGET_H = 384

OUT = "textures/tree-taiga.webp"


def _resize(img, target_h=TARGET_H):
    w, h = img.size
    return img.resize((max(1, round(w * target_h / h)), target_h), Image.LANCZOS)


def _fill_fraction(img):
    """Opaque share of the bounding box — the regression check on the alpha close.

    This tree ships at 36.4%. The number matters because a close radius large enough to
    swallow the gaps BETWEEN the whorls would fill the silhouette in toward a solid
    triangle and throw away the one property the tree was chosen for, and a blobbed tree
    still looks like a tree at thumbnail size — so measure rather than eyeball. Well
    under 50% means the whorls are still open. See "WHY IT IS RENDERED TALLER" for the
    figures across resolutions.
    """
    px = img.load()
    w, h = img.size
    return 100.0 * sum(
        1 for y in range(h) for x in range(w) if px[x, y][3] > 128
    ) / max(1, w * h)


def main():
    trees = _segment(_fetch_sheet())
    print(f"segmented {len(trees)} trees from the sheet")
    raw = trees[SPIRE_INDEX]
    print("source #%d is %dx%d (w/h %.2f)" % (SPIRE_INDEX, raw.size[0], raw.size[1],
                                              raw.size[0] / raw.size[1]))
    tree = _consolidate_alpha(_resize(raw))
    tree.save(OUT, lossless=True)
    print("wrote %s  %dx%d  (%.1f%% fill)" % (OUT, tree.size[0], tree.size[1],
                                              _fill_fraction(tree)))


if __name__ == "__main__":
    main()
