#!/usr/bin/env python3
"""Generate a seamless, tileable leaf/foliage texture for the low-poly tree.

CC0 / self-authored — external texture libraries (ambientCG, Poly Haven,
OpenGameArt, ...) are blocked by this environment's egress policy, so the
canopy texture is synthesised here instead: many small leaf shapes scattered
in varied greens over a dark base, drawn with wrap-around so the image tiles.

Output: textures/leaves.png (mapped onto the canopy by tools/lowpoly_tree.gd).
"""
import math
import os
import random

from PIL import Image, ImageDraw

SIZE = 512
OUT = os.path.join(os.path.dirname(__file__), "..", "textures", "leaves.png")

# Skybox-matched greens (dark gaps -> mid leaves -> sunlit highlights).
BASE = (28, 40, 18)
GREENS = [
    (40, 58, 24),
    (52, 74, 30),
    (66, 92, 36),
    (84, 112, 44),
    (104, 134, 56),  # sunlit
]


def draw_leaf(draw, cx, cy, r, ang, col):
    # a simple rotated teardrop: two arcs approximated by a rotated ellipse plus
    # a slightly darker base — cheap but reads as a leaf en masse.
    w = r
    h = r * 1.7
    pts = []
    for i in range(12):
        t = (i / 12.0) * math.tau
        # teardrop profile: narrower at one end
        rad = 0.5 + 0.5 * math.cos(t)
        ex = math.cos(t) * w * (0.6 + 0.4 * rad)
        ey = math.sin(t) * h * 0.5 - (1.0 - rad) * h * 0.15
        rx = ex * math.cos(ang) - ey * math.sin(ang)
        ry = ex * math.sin(ang) + ey * math.cos(ang)
        pts.append((cx + rx, cy + ry))
    draw.polygon(pts, fill=col)
    # vein / highlight streak
    hi = tuple(min(255, int(c * 1.25)) for c in col)
    vx = math.sin(ang) * h * 0.32
    vy = -math.cos(ang) * h * 0.32
    draw.line([(cx - vx, cy - vy), (cx + vx, cy + vy)], fill=hi, width=1)


def main():
    rnd = random.Random(20240629)
    img = Image.new("RGB", (SIZE, SIZE), BASE)
    draw = ImageDraw.Draw(img)

    # Layered back-to-front: darker/smaller leaves first, brighter on top, so the
    # canopy has depth instead of a flat speckle.
    layers = [
        (260, (10, 18), GREENS[0:2]),
        (300, (9, 16), GREENS[1:3]),
        (320, (8, 14), GREENS[2:4]),
        (220, (6, 11), GREENS[3:5]),
    ]
    for count, (rmin, rmax), palette in layers:
        for _ in range(count):
            cx = rnd.uniform(0, SIZE)
            cy = rnd.uniform(0, SIZE)
            r = rnd.uniform(rmin, rmax)
            ang = rnd.uniform(0, math.tau)
            col = rnd.choice(palette)
            # jitter the colour a touch per leaf
            col = tuple(max(0, min(255, c + rnd.randint(-8, 8))) for c in col)
            # draw at all 9 wrapped offsets so the texture tiles seamlessly
            for dx in (-SIZE, 0, SIZE):
                for dy in (-SIZE, 0, SIZE):
                    draw_leaf(draw, cx + dx, cy + dy, r, ang, col)

    img.save(OUT)
    print("wrote", os.path.normpath(OUT), img.size)


if __name__ == "__main__":
    main()
