#!/usr/bin/env python3
"""Generate the HQ map-table satellite texture: one world, four regional corners.

Writes an 848x848 JPEG (matching textures/map_table.jpg's dimensions) into
textures/, styled to sit alongside the existing photographic maps — muted
greens (~[52,84,57]), bare tan ([134,131,101]) and Greek-teal water ([44,69,75]).
No drawn borders — the terrain alone delineates the regions.

The four corners are the game's regions, all visible from the first minute:

    NW  forest        temperate woodland / pasture mosaic, rivers, tarns
    NE  snow          alpine ridges above the snowline, rock on the steep faces
    SW  arid          dry tan desert, sparse drainage
    SE  coast         sea, a bay, and a scatter of small islands

Everything is derived from seeded value-noise, so a different --seed re-rolls
the terrain while keeping each region in its own corner. Requires numpy + PIL.

Re-run after tweaking, then `godot --headless --import` to (re)import.

Usage:
    tools/gen_map_texture.py                      # -> textures/map_world.jpg
    tools/gen_map_texture.py --seed 9             # re-roll the terrain
    tools/gen_map_texture.py --out /tmp/try.jpg   # preview somewhere else
"""
import argparse
import os

import numpy as np
from PIL import Image, ImageFilter

SIZE = 1024          # generated at 1024, downsampled to OUT_SIZE for crispness
OUT_SIZE = 848       # matches textures/map_table.jpg
PAD = 96             # generate oversized and crop — kills warp/gradient edge artifacts

TEXTURES = os.path.join(os.path.dirname(__file__), "..", "textures")

CORNERS = {                    # (u, v) centre of each region's influence
    "forest": (0.15, 0.20),    # NW
    "snow":   (0.85, 0.15),    # NE
    "arid":   (0.14, 0.85),    # SW
    "coast":  (0.87, 0.87),    # SE
}
# Per-region influence radius. Snow runs WIDER than the rest so the alpine corner
# reads as a substantial region rather than a cap in the extreme corner — it is the
# one region whose look can't be produced by re-mixing the others, so it needs room
# to hold its own rallies later (todo/one-map-four-corners.md, snow follow-up).
# A single shared SIGMA can't do that: raising it inflates every corner at once and
# the four just blur into each other.
# The seed the SHIPPED textures/map_world.jpg was generated from. Kept as the
# default so re-running the tool reproduces the map that the rally map_pos values
# were authored against — changing it silently invalidates every coastal pin.
SHIPPED_SEED = 5

SIGMA = 0.36
SIGMA_BY_REGION = {"snow": 0.46}
SEA = 0.30

# Islands seeded in the SE so the coastal region has land to actually race on.
# Deliberately VARIED in size and spacing: a few big enough to carry a stage, a
# scatter of small ones for silhouette, and two set well off the main shore so the
# archipelago reads as an archipelago rather than a fringe of the mainland.
ISLANDS = [(0.74, 0.93, 0.058), (0.88, 0.74, 0.050), (0.955, 0.90, 0.040),
           (0.80, 0.83, 0.034), (0.66, 0.99, 0.036), (0.93, 0.99, 0.030),
           (0.995, 0.66, 0.045),
           (0.62, 0.80, 0.030),   # inner islet, breaks up the open bay
           (0.86, 0.62, 0.034),   # north of the peninsula, extends the shoreline
           (0.71, 0.71, 0.026),   # mid-bay speck
           (0.98, 0.79, 0.028)]   # outer, detaches the eastern edge


def rgb(*c):
    return np.array(c, dtype=np.float64)


C_FOREST_DK = rgb(36, 55, 39)
C_FOREST    = rgb(58, 88, 60)
C_MEADOW    = rgb(104, 118, 82)
C_GRASS     = rgb(94, 108, 78)
C_SCRUB     = rgb(128, 126, 98)
C_SAND      = rgb(170, 152, 116)
C_DUNE      = rgb(190, 172, 135)
C_ROCK      = rgb(112, 106, 94)
C_ROCK_DK   = rgb(74, 70, 64)
C_SNOW      = rgb(226, 229, 233)
C_SEA_DP    = rgb(24, 42, 54)
C_SEA_SH    = rgb(58, 98, 108)
C_RIVER     = rgb(52, 76, 84)
C_TARN      = rgb(36, 56, 64)
C_SURF      = rgb(138, 168, 172)


# ---------------------------------------------------------------- noise ----
def _grid_noise(rng, res, n):
    """One octave of value noise: a random lattice, smoothstep-interpolated."""
    g = rng.random((res + 1, res + 1))
    t = np.linspace(0, res, n, endpoint=False)
    i0 = np.floor(t).astype(int)
    f = t - i0
    s = f * f * (3 - 2 * f)
    g00, g01 = g[np.ix_(i0, i0)], g[np.ix_(i0, i0 + 1)]
    g10, g11 = g[np.ix_(i0 + 1, i0)], g[np.ix_(i0 + 1, i0 + 1)]
    top = g00 + (g01 - g00) * s[None, :]
    bot = g10 + (g11 - g10) * s[None, :]
    return top + (bot - top) * s[:, None]


def fbm(rng, n, base_res=4, octaves=7, persistence=0.5):
    out = np.zeros((n, n))
    amp, tot, res = 1.0, 0.0, base_res
    for _ in range(octaves):
        out += amp * _grid_noise(rng, res, n)
        tot += amp
        amp *= persistence
        res *= 2
    return out / tot


def sample(field, xs, ys):
    m = field.shape[0]
    xs, ys = np.clip(xs, 0, m - 1.001), np.clip(ys, 0, m - 1.001)
    x0, y0 = np.floor(xs).astype(int), np.floor(ys).astype(int)
    x1, y1 = np.minimum(x0 + 1, m - 1), np.minimum(y0 + 1, m - 1)
    fx, fy = xs - x0, ys - y0
    return (field[y0, x0] * (1 - fx) * (1 - fy) + field[y0, x1] * fx * (1 - fy)
            + field[y1, x0] * (1 - fx) * fy + field[y1, x1] * fx * fy)


def warp(field, dx, dy, amount):
    """Domain warp — pushes noise off the grid so nothing reads as axis-aligned."""
    m = field.shape[0]
    yy, xx = np.mgrid[0:m, 0:m]
    return sample(field, xx + dx * amount, yy + dy * amount)


def smoothstep(e0, e1, x):
    t = np.clip((x - e0) / (e1 - e0), 0, 1)
    return t * t * (3 - 2 * t)


def norm(a):
    return (a - a.min()) / (a.max() - a.min() + 1e-9)


def blur(a, r):
    lo, hi = a.min(), a.max()
    q = ((a - lo) / (hi - lo + 1e-9) * 255).astype(np.uint8)
    q = np.asarray(Image.fromarray(q).filter(ImageFilter.GaussianBlur(r)), dtype=np.float64)
    return q / 255 * (hi - lo) + lo


# ------------------------------------------------------------ generation ---
def generate(seed):
    n = SIZE + 2 * PAD
    rng = np.random.default_rng(seed)
    yy, xx = np.mgrid[0:n, 0:n]
    u = (xx - PAD) / SIZE
    v = (yy - PAD) / SIZE

    # Region influence: gaussians normalised to sum to 1, with a gentle per-axis
    # wobble — enough to break clean radial arcs, small enough that each corner
    # still firmly owns its quadrant.
    wu = (fbm(rng, n, 3, 4) - 0.5) * 0.10
    wv = (fbm(rng, n, 3, 4) - 0.5) * 0.10
    w = {}
    for k, (cu, cv) in CORNERS.items():
        sig = SIGMA_BY_REGION.get(k, SIGMA)
        w[k] = np.exp(-((u + wu - cu) ** 2 + (v + wv - cv) ** 2) / (2 * sig ** 2))
    tot = sum(w.values())
    for k in w:
        w[k] /= tot

    wx = (fbm(rng, n, 3, 5) - 0.5) * 2
    wy = (fbm(rng, n, 3, 5) - 0.5) * 2
    base = warp(fbm(rng, n, 5, 9, 0.52), wx, wy, 60)
    ridged = warp(1 - np.abs(fbm(rng, n, 7, 8, 0.55) * 2 - 1), wx, wy, 40)
    hills = warp(fbm(rng, n, 12, 6, 0.5), wx, wy, 25)

    # ALPINE MASSING — real mountain relief in the snow corner.
    # Its own RNG stream, seeded off `seed`: the main `rng` is consumed sequentially, so
    # drawing from it here would shift every later call and re-roll the entire map.
    rng_alp = np.random.default_rng(seed * 7919 + 17)
    # base_res 3 (vs `ridged`'s 7) is the whole point — FEW, LARGE ridges read as a
    # mountain range, where high-frequency noise just reads as static.
    ridged_big = warp(1 - np.abs(fbm(rng_alp, n, 3, 5, 0.58) * 2 - 1), wx, wy, 40)
    # HARD-GATED to the snow corner. w["snow"] is a normalised gaussian and so is never
    # exactly zero — ungated, even a faint tail reaches the coast a thousand pixels away.
    # The smoothstep floors it to zero outside the massif, which is what makes it safe to
    # feed into `elev` at all: the NE holds no sea and (deliberately) no rally pins, so
    # reshaping terrain there cannot move a coastline or re-site a pin.
    alpine_gate = smoothstep(0.46, 0.72, w["snow"])

    elev = (0.50 * base
            + 0.14 * hills
            + 0.72 * w["snow"] * (0.30 + 0.90 * ridged)
            + 0.08 * w["forest"] * base
            - 0.68 * smoothstep(0.28, 0.68, w["coast"])
            - 0.04 * w["arid"])
    for cu, cv, rad in ISLANDS:
        elev += 0.30 * np.exp(-((u - cu) ** 2 + (v - cv) ** 2) / (2 * rad ** 2))
    elev = norm(elev)
    # Applied post-norm and clipped (not re-normalised) so the rest of the map's
    # elevation range — and therefore every threshold derived from it — is unchanged.
    # Kept for the shared relief blur below — see the note there for why the ALPINE-
    # modified elev must not go into it.
    elev_base = elev
    elev = np.clip(elev + 0.20 * alpine_gate * (ridged_big - 0.42), 0, 1)

    land = elev > SEA
    depth = np.clip((SEA - elev) / SEA, 0, 1)
    alt = np.clip((elev - SEA) / (1 - SEA), 0, 1)
    slope = np.hypot(*np.gradient(blur(elev, 1.2) * 900.0))

    arid = np.clip(0.38 + 1.15 * w["arid"] - 0.52 * w["forest"] + 0.14 * w["coast"]
                   - 0.12 * w["snow"] + (fbm(rng, n, 5, 6) - 0.5) * 0.62, 0, 1)

    # Snow: high ground only, and scoured off the steep faces so rock shows through.
    snowline = 0.70 - 0.24 * w["snow"] + (fbm(rng, n, 7, 5) - 0.5) * 0.11
    snow = np.clip(smoothstep(0.0, 0.13, alt - snowline)
                   * smoothstep(0.16, 0.42, w["snow"])
                   * (1 - 0.70 * smoothstep(1.3, 3.2, slope)), 0, 1)

    # Bare rock on the flanks of the big ridges — snowy crests over exposed faces is
    # what separates "mountains" from a flat white field. `slope` here is the REAL
    # terrain slope, which now includes the alpine massing folded into elev above.
    alpine = alpine_gate * smoothstep(0.20, 0.55, alt)
    snow = np.clip(snow * (1 - 0.30 * smoothstep(1.6, 4.0, slope) * alpine), 0, 1)

    # The alpine term is added AFTER the blur, not inside it. blur() normalises by its
    # argument's own min/max, so folding a raised massif into the same call widens that
    # range and silently shifts the quantisation — and therefore the shading — across the
    # ENTIRE map. Blurring it separately keeps the rest of the world bit-identical.
    # blur() quantises against its argument's own min/max, so ANY term that raises the
    # massif inside this call widens that range and shifts the shading across the ENTIRE
    # map — including the far corners, which is exactly what "don't change the shapes"
    # rules out. So this blurs the UNMODIFIED elevation (identical range to before the
    # alpine work) and the massing is layered on afterwards, pre-blurred separately.
    relief = blur(elev_base + 0.22 * w["snow"] * ridged, 0.8) \
        + 1.05 * alpine * blur(ridged_big, 0.8)
    gy, gx = np.gradient(relief * 620.0)
    shade = np.clip(1.0 + 0.42 * (-gx - gy) / np.sqrt(2), 0.64, 1.42)   # lit from the NW
    # Deepen the shading contrast on the massif so the big ridges cast readable relief.
    shade = np.clip(shade * (1.0 + 0.45 * alpine * (shade - 1.0) * 2.4), 0.46, 1.70)

    # -- ground cover -------------------------------------------------------
    pxw = (fbm(rng, n, 6, 5) - 0.5) * 2
    pyw = (fbm(rng, n, 6, 5) - 0.5) * 2
    micro = fbm(rng, n, 260, 3, 0.62)        # pixel-scale grain: sells photo over render
    grain = fbm(rng, n, 70, 5, 0.55)
    copse = smoothstep(0.50, 0.63, warp(fbm(rng, n, 44, 5, 0.5), wx, wy, 12))
    wood = smoothstep(0.43, 0.60, warp(fbm(rng, n, 34, 6, 0.5), pxw, pyw, 22))
    # Quantising a warped noise into bands gives irregular field-shaped parcels;
    # a raw lattice would read as obvious squares.
    parcel = blur(np.floor(warp(fbm(rng, n, 30, 3, 0.5), pxw, pyw, 55) * 7.0) / 7.0, 0.6)

    # Damp ground is a MOSAIC of woodland and open pasture — a solid dark green
    # mass is the giveaway that a map was rendered rather than photographed.
    timber = C_FOREST[None, None] * (1 - grain)[..., None] + C_FOREST_DK[None, None] * grain[..., None]
    timber = (timber * (1 - 0.30 * copse)[..., None]
              + C_FOREST_DK[None, None] * (0.30 * copse)[..., None])
    pasture = (C_MEADOW[None, None] * (1 - parcel)[..., None]
               + C_GRASS[None, None] * parcel[..., None])
    veg = pasture * (1 - wood)[..., None] + timber * wood[..., None]
    mid = C_GRASS[None, None] * (1 - parcel)[..., None] + C_SCRUB[None, None] * parcel[..., None]
    dry = C_SAND[None, None] * (1 - grain)[..., None] + C_DUNE[None, None] * grain[..., None]

    a1 = smoothstep(0.26, 0.56, arid)[..., None]
    a2 = smoothstep(0.54, 0.84, arid)[..., None]
    ground = veg * (1 - a1) + mid * a1
    ground = ground * (1 - a2) + dry * a2

    rock = C_ROCK[None, None] * (1 - grain)[..., None] + C_ROCK_DK[None, None] * grain[..., None]
    r = smoothstep(0.42, 0.74, alt)[..., None] * smoothstep(0.5, 1.6, slope)[..., None]
    ground = ground * (1 - r) + rock * r
    s = snow[..., None]
    ground = ground * (1 - s) + C_SNOW[None, None] * s
    ground *= (1.0 + ((parcel - 0.5) * 0.20 * (1 - a2[..., 0])
                      + (micro - 0.5) * 0.20) * (1 - snow))[..., None]

    water = (C_SEA_SH[None, None] * (1 - depth ** 0.55)[..., None]
             + C_SEA_DP[None, None] * (depth ** 0.55)[..., None])
    water *= (1.0 + (micro - 0.5) * 0.05)[..., None]

    lw = smoothstep(-0.003, 0.003, elev - SEA)[..., None]
    col = water * (1 - lw) + ground * lw

    # -- hydrology ----------------------------------------------------------
    # The crests of a ridged noise read as thin winding channels.
    riv = 1 - np.abs(warp(fbm(rng, n, 9, 7, 0.55), wx, wy, 30) * 2 - 1)
    river = (smoothstep(0.972, 0.996, riv) * land * smoothstep(0.88, 0.30, alt)
             * (1 - 0.65 * smoothstep(0.55, 0.85, arid)))
    col = col * (1 - river[..., None]) + C_RIVER[None, None] * river[..., None]

    lake_n = warp(fbm(rng, n, 20, 5, 0.5), wx, wy, 14)
    tarn = (smoothstep(0.268, 0.222, lake_n) * land
            * smoothstep(0.40, 0.24, alt) * smoothstep(1.2, 0.5, slope))
    col = col * (1 - tarn[..., None]) + C_TARN[None, None] * tarn[..., None]

    col *= (1.0 + (shade - 1.0) * lw[..., 0] * (0.25 + 0.55 * alt))[..., None]
    surf = smoothstep(0.0, 0.008, np.abs(elev - SEA))
    col = col * surf[..., None] + C_SURF[None, None] * (1 - surf)[..., None]

    col = np.clip(col, 0, 255)[PAD:PAD + SIZE, PAD:PAD + SIZE]
    land_c = land[PAD:PAD + SIZE, PAD:PAD + SIZE]

    # No admin/border overlay: the terrain itself delineates the four regions, and
    # drawn boundary lines just read as stray marks on the table.
    arr = np.asarray(Image.fromarray(col.astype(np.uint8))
                     .filter(ImageFilter.GaussianBlur(0.25)), dtype=np.float64).copy()

    # Sit it alongside the photographic sources: desaturate a touch, vignette, grain.
    g = arr.mean(axis=2, keepdims=True)
    arr = g + (arr - g) * 0.92
    gu, gv = np.mgrid[0:SIZE, 0:SIZE][1] / SIZE, np.mgrid[0:SIZE, 0:SIZE][0] / SIZE
    arr *= (1 - 0.13 * smoothstep(0.38, 0.80, np.hypot(gu - 0.5, gv - 0.5)))[..., None]
    arr += rng.normal(0, 2.2, arr.shape)

    img = Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8))
    img = img.resize((OUT_SIZE, OUT_SIZE), Image.LANCZOS)

    stack = np.stack([w[k][PAD:PAD + SIZE, PAD:PAD + SIZE] for k in CORNERS])
    dom = stack.argmax(axis=0)
    # NB: keyed "snow_cover", not "snow" — the per-region shares below use the
    # corner names, and "snow" is one of them.
    stats = {"sea": float(1 - land_c.mean()),
             "snow_cover": float((snow[PAD:PAD + SIZE, PAD:PAD + SIZE] > 0.5).mean())}
    for i, k in enumerate(CORNERS):
        stats[k] = float((dom == i).mean())
    return img, stats


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--seed", type=int, default=SHIPPED_SEED, help="re-roll the terrain")
    ap.add_argument("--out", default=os.path.join(TEXTURES, "map_world.jpg"))
    args = ap.parse_args()

    img, stats = generate(args.seed)
    img.save(args.out, quality=90, subsampling=0)
    print("wrote %s (%dx%d, seed %d)" % (args.out, img.size[0], img.size[1], args.seed))
    print("  sea %.1f%%  snow %.1f%%" % (100 * stats["sea"], 100 * stats["snow_cover"]))
    print("  region share: " + "  ".join("%s %.0f%%" % (k, 100 * stats[k]) for k in CORNERS))


if __name__ == "__main__":
    main()
