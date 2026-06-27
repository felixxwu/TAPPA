#!/usr/bin/env python3
"""Align an equirectangular sky panorama to the project's sun convention.

The car/terrain use a FAKE directional light (GameConfig.sun_direction); for the
shading to match the visible sun, the panorama's sun must sit at a known spot.
Convention: the sun is rolled to the image's HORIZONTAL CENTRE, which in Godot's
panorama mapping is the -Z direction (what the camera looks down by default).
A horizontal roll is a pure yaw, so the horizon stays level (no tilt).

Drop-in workflow for a new sky:
    python3 tools/align_sky_sun.py textures/sky_new.png
then paste the printed `sun_direction` into GameConfig (sun is centred, so the
azimuth is always -Z; only the elevation — the y/z split — changes per sky).
If in-game the lit side is OPPOSITE the sun, flip the sign of sun_direction.z
(covers the panorama winding convention; verify once visually).

Usage: align_sky_sun.py IN.png [OUT.png]   (OUT defaults to overwriting IN)
"""
import sys, math
import numpy as np
from PIL import Image

CANON_U = 0.5  # sun column fraction after alignment (image centre == -Z)


def main():
    path = sys.argv[1]
    out = sys.argv[2] if len(sys.argv) > 2 else path
    a = np.asarray(Image.open(path).convert("RGB"), dtype=np.float32)
    H, W, _ = a.shape
    lum = a.mean(2)
    # Sun = the bright blob. Take the centroid of the brightest pixels; average the
    # column circularly so a sun near the seam doesn't bias the centre.
    thr = lum.max() * 0.985
    ys, xs = np.where(lum >= thr)
    ang = xs / W * 2 * math.pi
    u = (math.atan2(np.sin(ang).mean(), np.cos(ang).mean()) % (2 * math.pi)) / (2 * math.pi)
    v = ys.mean() / H

    shift = int(round((CANON_U - u) * W)) % W
    rolled = np.roll(a, shift, axis=1)
    Image.fromarray(rolled.astype(np.uint8)).save(out)

    # sun_direction at the centred azimuth (-Z) and the sun's detected elevation.
    polar = v * math.pi                 # 0 = zenith, pi/2 = horizon
    y = math.cos(polar)
    z = -math.sin(polar)                # centre column -> -Z
    elev = 90.0 - math.degrees(polar)
    print(f"detected sun at u={u:.3f} v={v:.3f}  (elevation {elev:.1f} deg)")
    print(f"rolled {shift}px -> sun centred; wrote {out}")
    print(f"sun_direction = Vector3(0.0, {y:.3f}, {z:.3f})")


if __name__ == "__main__":
    main()
