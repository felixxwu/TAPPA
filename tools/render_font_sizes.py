#!/usr/bin/env python3
"""Render fonts/Jersey10.ttf across a size sweep to find its pixel-grid sweet spot.

Jersey 10 ships no hinted bitmap strikes (fonts/Jersey10.ttf.import disables
them), so its outline-to-pixel rounding only lands clean at certain point
sizes — off those sizes, stroke widths that should match come out 1px apart
and glyphs read as uneven/disfigured (see features/ui-design-system.md). This
sweeps a size range with a hard 1-bit threshold (no antialiasing/greyscale),
matching the game's actual import settings, and writes one stacked PNG so the
sizes can be eyeballed side by side.

Run: python3 tools/render_font_sizes.py [out.png]
Needs Pillow (`pip install pillow`) — not a project dependency, dev-only.
"""

import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent.parent
FONT_PATH = ROOT / "fonts" / "Jersey10.ttf"
TEXT = "STAGE 3/8  $4250  02:14 NEW RUN"
SIZES = [8, 10, 12, 14, 16, 18, 20, 24, 28, 32]
SCALE = 6  # nearest-neighbor upscale so tiny glyphs are visible
PAD = 4


def render_size(size: int) -> Image.Image:
    font = ImageFont.truetype(str(FONT_PATH), size)
    tmp = Image.new("L", (1, 1))
    bbox = ImageDraw.Draw(tmp).textbbox((0, 0), TEXT, font=font)
    w = bbox[2] - bbox[0] + PAD * 2
    h = bbox[3] - bbox[1] + PAD * 2
    img = Image.new("L", (w, h), color=0)
    ImageDraw.Draw(img).text((PAD - bbox[0], PAD - bbox[1]), TEXT, font=font, fill=255)
    img = img.point(lambda p: 255 if p >= 128 else 0)  # hard threshold: no AA/greyscale
    return img.resize((w * SCALE, h * SCALE), Image.NEAREST)


def main() -> None:
    out_path = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "jersey10_sizes.png"
    rows = [(size, render_size(size)) for size in SIZES]
    label_h = 20
    max_w = max(img.width for _, img in rows)
    total_h = sum(img.height + label_h + 10 for _, img in rows)
    sheet = Image.new("RGB", (max_w + 20, total_h + 20), color=(10, 10, 10))
    draw = ImageDraw.Draw(sheet)
    label_font = ImageFont.load_default()

    y = 10
    for size, img in rows:
        draw.text((10, y), f"{size}px", font=label_font, fill=(0, 255, 80))
        y += label_h
        sheet.paste(img.convert("RGB"), (10, y))
        y += img.height + 10

    sheet.save(out_path)
    print(f"wrote {out_path} ({sheet.width}x{sheet.height})")


if __name__ == "__main__":
    main()
