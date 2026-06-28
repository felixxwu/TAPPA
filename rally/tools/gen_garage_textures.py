#!/usr/bin/env python3
"""Generate the procedural textures for the garage interior (scripts/garage.gd).

Pure-PIL (no numpy) so it runs anywhere PIL is installed. Writes a small set of
tileable / panel textures into textures/:

    garage_floor.png     concrete slab with expansion joints + oil stains (tiles)
    garage_wall.png      light ribbed wall panel, scuffed at the bottom (tiles X)
    garage_cabinet.png   red tool-chest front: stainless counter + 4 drawers
    garage_pegboard.png  perforated board with a few hung tools (tiles)
    garage_bench.png     worn wooden workbench top (tiles)

Re-run after tweaking, then `godot --headless --import` to (re)import them.
Usage: tools/gen_garage_textures.py
"""
import os
import random
from PIL import Image, ImageDraw, ImageChops, ImageFilter

S = 512
OUT = os.path.join(os.path.dirname(__file__), "..", "textures")
random.seed(7)


def grain(base_img, sigma, opacity):
    """Overlay grey noise onto base_img to add surface grain."""
    n = Image.effect_noise((S, S), sigma).convert("RGB")
    return Image.blend(base_img, ImageChops.overlay(base_img, n), opacity)


def solid(color):
    return Image.new("RGB", (S, S), color)


def save(img, name):
    img.save(os.path.join(OUT, name))
    print("wrote", name)


def floor():
    img = grain(solid((120, 122, 128)), 26, 0.35)
    d = ImageDraw.Draw(img, "RGBA")
    # Oil / fluid stains.
    for _ in range(7):
        x, y = random.randint(0, S), random.randint(0, S)
        r = random.randint(20, 70)
        d.ellipse([x - r, y - r, x + r, y + r], fill=(50, 48, 52, 70))
    # Expansion joints on the tile edges (so the grid is continuous when tiled).
    for p in (0, S // 2):
        d.line([(p, 0), (p, S)], fill=(86, 88, 94, 255), width=4)
        d.line([(0, p), (S, p)], fill=(86, 88, 94, 255), width=4)
    # A faint painted bay line.
    d.line([(S - 40, 0), (S - 40, S)], fill=(190, 180, 70, 90), width=8)
    save(img.filter(ImageFilter.GaussianBlur(0.4)), "garage_floor.png")


def wall():
    img = solid((208, 208, 202))
    d = ImageDraw.Draw(img, "RGBA")
    # Vertical panel seams.
    for x in range(0, S + 1, 64):
        d.line([(x, 0), (x, S)], fill=(184, 184, 178, 255), width=2)
    # Top rail + a horizontal mid seam.
    d.rectangle([0, 0, S, 10], fill=(150, 150, 146, 255))
    d.line([(0, 150), (S, 150)], fill=(190, 190, 184, 255), width=2)
    img = grain(img, 10, 0.18)
    # Scuff / grime gradient along the bottom.
    d = ImageDraw.Draw(img, "RGBA")
    for i in range(140):
        a = int(70 * (i / 140.0) ** 2)
        d.line([(0, S - i), (S, S - i)], fill=(60, 58, 56, a))
    save(img, "garage_wall.png")


def cabinet():
    img = solid((168, 34, 42))            # red chest body
    d = ImageDraw.Draw(img, "RGBA")
    # Stainless counter top.
    d.rectangle([0, 0, S, 78], fill=(196, 198, 202))
    for i in range(78):                   # subtle counter sheen
        d.line([(0, i), (S, i)], fill=(255, 255, 255, max(0, 40 - i)))
    # Drawers.
    top, n = 92, 4
    gap = 14
    dh = (S - top - gap * (n + 1)) // n
    for k in range(n):
        y0 = top + gap + k * (dh + gap)
        y1 = y0 + dh
        d.rounded_rectangle([18, y0, S - 18, y1], radius=8, fill=(150, 26, 34))
        d.line([(18, y0 + 2), (S - 18, y0 + 2)], fill=(210, 90, 96, 200), width=2)   # top bevel
        d.line([(18, y1 - 2), (S - 18, y1 - 2)], fill=(96, 14, 20, 220), width=3)     # bottom shade
        # Handle.
        hy = (y0 + y1) // 2
        d.rounded_rectangle([S // 2 - 70, hy - 9, S // 2 + 70, hy + 9], radius=9,
                            fill=(54, 54, 58))
        d.rounded_rectangle([S // 2 - 70, hy - 9, S // 2 + 70, hy - 3], radius=6,
                            fill=(120, 120, 126))
    # Corner bolts.
    for cx, cy in [(28, 90), (S - 28, 90), (28, S - 14), (S - 28, S - 14)]:
        d.ellipse([cx - 5, cy - 5, cx + 5, cy + 5], fill=(40, 40, 44))
    save(grain(img, 8, 0.12), "garage_cabinet.png")


def pegboard():
    img = grain(solid((212, 206, 196)), 10, 0.15)
    d = ImageDraw.Draw(img, "RGBA")
    for y in range(16, S, 30):            # peg holes
        for x in range(16, S, 30):
            d.ellipse([x - 3, y - 3, x + 3, y + 3], fill=(150, 144, 134, 255))
    # A few hung tools (dark silhouettes).
    d.line([(90, 60), (90, 200)], fill=(60, 62, 66, 255), width=10)        # long tool shaft
    d.ellipse([76, 50, 104, 78], outline=(60, 62, 66, 255), width=10)      # ring spanner head
    d.rectangle([200, 70, 230, 210], fill=(70, 60, 50, 255))               # hammer handle
    d.rectangle([185, 60, 245, 90], fill=(60, 62, 66, 255))                # hammer head
    d.polygon([(330, 70), (360, 70), (350, 220), (340, 220)], fill=(64, 66, 70, 255))  # screwdriver
    save(img, "garage_pegboard.png")


def bench():
    img = solid((124, 86, 52))            # worn wood
    d = ImageDraw.Draw(img, "RGBA")
    for y in range(0, S + 1, 96):         # plank seams
        d.line([(0, y), (S, y)], fill=(80, 54, 32, 255), width=4)
    for _ in range(10):                   # grain streaks + stains
        y = random.randint(0, S)
        d.line([(0, y), (S, y)], fill=(100, 70, 42, 120), width=random.randint(1, 3))
    for _ in range(5):
        x, y = random.randint(0, S), random.randint(0, S)
        r = random.randint(14, 40)
        d.ellipse([x - r, y - r, x + r, y + r], fill=(70, 48, 30, 90))
    save(grain(img, 16, 0.25), "garage_bench.png")


if __name__ == "__main__":
    floor(); wall(); cabinet(); pegboard(); bench()
    print("done ->", os.path.normpath(OUT))
