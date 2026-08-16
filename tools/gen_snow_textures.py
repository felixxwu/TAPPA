#!/usr/bin/env python3
"""Generate the snow region's art (features/snow-region.md).

Four assets, all procedural so they can be re-rolled and re-tuned rather than
hand-painted once and frozen:

    textures/snow-ground.jpg   64x64   tiling  deep snow off the road
    textures/snow-road.jpg     64x64   tiling  packed/tracked snow road

The two conifer billboards are NOT built here — they are real photographs, cut from a
CC0 pack by tools/gen_snow_trees.py. An early procedural conifer lived here and was
dropped: the game's existing trees (tree.png, tree-greece.webp) are photographic
cutouts, so a flat vector-style fir was the one asset in the region that clashed.

textures/sky-snow.jpg is NOT generated here. It is a real CC0 photograph — "Horn-koppe
Snow" from Poly Haven (https://polyhaven.com/a/horn-koppe_snow), CC0 1.0, no attribution
required — downscaled to 1024x512 to match the existing sky-greece.jpg panorama. An
earlier procedural gradient sky lived here and was dropped: the other skies in the game
are photographs, and a hand-rolled gradient was visibly the odd one out.

Run from the repo root:  python3 tools/gen_snow_textures.py

Sibling of tools/gen_map_texture.py and tools/gen_garage_textures.py. Pure PIL —
this repo has no numpy, so the noise below is hand-rolled.

THE ONE THING NOT TO "SIMPLIFY": the ground textures are deliberately NOT flat
white. This renderer is unshaded with baked vertex lighting (features/rendering.md),
so a dead-flat albedo has no form at all — a snowfield would read as a white
silhouette with the horizon drawn on it. The low-amplitude noise below is what gives
the ground shape under a flat light, and dropping it undoes the whole look.
"""

import math
import random

from PIL import Image

# Fixed so re-running produces byte-identical art: these are checked-in assets, and
# a regenerate that silently changed them would show up as noise in every diff.
SEED = 20260816

GROUND_SIZE = 64
SKY_W, SKY_H = 1024, 512


# --- tiling value noise ------------------------------------------------------
# A lattice of random values, bilinearly interpolated with WRAPPING indices, so the
# result tiles seamlessly. Called at a few octaves to get something that reads as
# wind-blown drift rather than TV static.


def _lattice(cells, rng):
    return [[rng.random() for _ in range(cells)] for _ in range(cells)]


def _smooth(t):
    # Smoothstep: kills the lattice's linear-interpolation diamond artefacts, which
    # are very visible on a near-white surface.
    return t * t * (3.0 - 2.0 * t)


def _sample(lat, cells, u, v):
    x, y = u * cells, v * cells
    x0, y0 = int(math.floor(x)), int(math.floor(y))
    fx, fy = _smooth(x - x0), _smooth(y - y0)
    # Wrapping keeps the tile seamless.
    x0, y0 = x0 % cells, y0 % cells
    x1, y1 = (x0 + 1) % cells, (y0 + 1) % cells
    a = lat[y0][x0] + (lat[y0][x1] - lat[y0][x0]) * fx
    b = lat[y1][x0] + (lat[y1][x1] - lat[y1][x0]) * fx
    return a + (b - a) * fy


def _fbm(size, octaves, rng, cells0=2):
    """Fractal noise in [0,1], tileable, returned as a size*size float list.

    `cells0` is the coarsest octave's lattice resolution, i.e. the FEATURE SCALE. It
    matters more than the octave count: the ground tiles want big soft drifts (2), but
    the bush clump is only a few hundred pixels across on screen, so the same value
    there produces one grey blob instead of snow caught on foliage.
    """
    out = [0.0] * (size * size)
    amp, total = 1.0, 0.0
    cells = cells0
    for _ in range(octaves):
        lat = _lattice(cells, rng)
        for y in range(size):
            for x in range(size):
                out[y * size + x] += amp * _sample(lat, cells, x / size, y / size)
        total += amp
        amp *= 0.5
        cells *= 2
    return [v / total for v in out]


def _ground(path, base, noise_amp, tint, rng, grit=0.0, grit_color=(120, 122, 128)):
    """A tiling ground texture: flat base + low-amplitude drift + optional grit."""
    size = GROUND_SIZE
    n = _fbm(size, 4, rng)
    img = Image.new("RGB", (size, size))
    px = img.load()
    for y in range(size):
        for x in range(size):
            # Centre the noise on zero so it darkens and brightens equally — a
            # one-sided offset would drift the whole surface off the authored base.
            d = (n[y * size + x] - 0.5) * 2.0 * noise_amp
            px[x, y] = tuple(
                max(0, min(255, int(base[c] + d + tint[c]))) for c in range(3)
            )
    if grit > 0.0:
        # Sparse dark specks: grit and stone punched through packed snow. Without
        # these the road tile is indistinguishable from the deep-snow tile at speed.
        for _ in range(int(size * size * grit)):
            x, y = rng.randrange(size), rng.randrange(size)
            j = rng.randint(-18, 18)
            px[x, y] = tuple(
                max(0, min(255, grit_color[c] + j)) for c in range(3)
            )
    img.save(path, quality=92)
    print(f"wrote {path} ({size}x{size})")


def main():
    rng = random.Random(SEED)
    # Deep snow: brightest, coolest, and the smoothest of the three — undisturbed.
    _ground(
        "textures/snow-ground.jpg",
        base=(226, 231, 238),
        noise_amp=13.0,
        tint=(0, 2, 6),
        rng=rng,
    )
    # Packed snow road: a little darker and warmer (compacted, dirtied), with grit
    # showing through, so the road is legible against the verge at speed.
    _ground(
        "textures/snow-road.jpg",
        base=(198, 202, 208),
        noise_amp=17.0,
        tint=(2, 1, 0),
        rng=rng,
        grit=0.035,
    )


if __name__ == "__main__":
    main()
