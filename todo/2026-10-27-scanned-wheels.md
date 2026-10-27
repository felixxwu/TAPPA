# Scanned 3D wheels

Replace the textured cylinder wheel with a real wheel model taken from each car's photogrammetry
scan, one car at a time, starting with the F-150.

## Why

Every car body is now a scan (`tools/car_scan/`, see `features/car-scanning.md`), but the wheels
are still a `CylinderMesh` with a flat `wheel.png` on each end. A scanned wheel gives the real
tyre profile, rim dish and spokes. The catch: the scan's colour has the garage's directional light
baked in, so a wheel textured straight from the scan shows a highlight that spins with the wheel.

## Goals

- An offline pipeline (alongside `tools/car_scan/`) that turns a car scan into one low-poly,
  textured wheel model per car, with the baked lighting removed, centred on its axle, perfectly
  round and exactly symmetric in its spoke pattern.
- The wheel's **measured size from the scan is the truth**: its radius and width become the car's
  `wheel_radius`, `wheel_width_front` and `wheel_width_rear` in `CarLibrary`, and the body
  pipeline cuts its wheel arches from that same measured radius (replacing `process.py
  --wheel-radius`), so wheel and arch always agree.
- **Claude makes the judgement calls** — de-lighting, symmetry, centring and roundness — using
  inspection tools the pipeline provides, and records its chosen values in a small per-car file
  that's committed, so a re-run reproduces the same wheel. This mirrors how the lamp positions in
  `GameConfig.lamp_offsets` were authored by reading renders (`features/car-lamps.md`).
- In game, a car whose spec names a wheel model shows it; every other car keeps today's cylinder.

## Non-goals

- Fine detail. The wheel is only really seen in chase cam while the car is turning, so it needs
  to read at that distance: tyre silhouette, sidewall, rim face at an angle. PS1 look, low tris.
- The cosmetic wheel swap. The swap menu no longer exists. Don't design around it (see "Cleanup").
- Phasing out the cylinder. It stays as the fallback until every car is scanned; that removal is
  later, separate work.
- Different front and rear rims. One wheel model per car, used on all four corners.
  *(Claude's call)* If a car's front and rear tyres measure clearly different (a staggered car),
  average each axle's pair separately and export one model per axle instead of scaling one model —
  `ps1_models_lit.gdshader` assumes uniform scale for its normals. The F-150 isn't staggered.

## Constraints

- Same capture setup as the F-150 (Forza garage orbit video, ~1600 frames through Apple Object
  Capture). The MX-5's video was a test environment; don't tune for it.
- The scan only sees the **outer** face of each tyre. The inner face is never captured.
- Size values in `CarLibrary` are authored data: tests must not pin them (CLAUDE.md testing rules).
- Jersey 10 / menu rules don't apply; no UI is involved.

## Dependency

Done (2026-10-27): the F-150 is in the game — `blender/f150/f150.glb`, `CarLibrary` id `f150`, `Car/F150Body`.
Its scan is the levelled wrap scan in the `f150_scan.blend` the body was modelled in (scan object `f150_scan`,
carrying the camera link), and its paint video's cameras are registered to that scan (`paint.poses.json`,
see `features/car-scanning.md`). The wrap only covers paintwork, so the scan's tyres and rims are real;
wheel colour still comes from the paint video's frames via `texturing.paint_from_video`, which sees each
wheel from many angles and lights.

## How it works (decided)

### 1. Find and unwrap each wheel

Start from the levelled, centred high-poly scan — the same levelling `process.py` does from the
four tyre contacts (its `contacts()` and the transform it writes to `body/scan_transform.txt`).
For each of the four wheels, fit the axle (the direction the outer face points) and its centre,
then resample the scan into two **polar images** — rows by distance from the centre, columns by
angle around it — holding the outer face's colour and its depth along the axle. The tread is a
third strip: colour and radius by angle and by position across the tread.

### 2. Remove the light using the wheel's symmetry

The baked light makes colour vary with angle (the highlight sits on one side). A wheel with N
spokes repeats every 360°/N, so averaging the polar images over those N slices cancels the light
while keeping the spoke pattern. The tread is averaged all the way round. The four wheels were
each lit from a different side, so they're averaged together too. The same averaging makes the
depth exactly N-fold symmetric and the radius perfectly constant, so the shape comes out round.

### 3. Rebuild a low-poly wheel

Build the mesh from the averaged images: a round tyre (lathe of the averaged tread profile) and a
rim face from the averaged depth on a coarse polar grid, with the averaged colour as its texture.
The outer face is mirrored to make the inner one. Output the measured radius and width (per axle).

*(Claude's call)* If the scan's rim face turns out to be mush (Object Capture often fills the gaps
between spokes), fall back to a smooth dished rim shape from the averaged depth's radial profile
only, with the spoke pattern carried by the texture. Decide from the F-150 scan's actual quality.

### 4. Claude's inspection tools

The pipeline gives Claude, for each judgement:

- **Centring and roundness** — a face-on orthographic render of each raw wheel with the fitted
  circle and centre drawn over it at a known scale (like the lamp renders: px per metre plus a
  grid), and the unwrapped polar strip. A wrong centre shows as a wavy rim edge in the strip.
  Claude nudges the centre / axle and re-renders until it's straight.
- **Spoke count and de-lighting** — a suggested repeat count measured from the polar colour
  image, the strip itself to confirm it by eye, and renders of the finished wheel at several spin
  angles under flat light. Lighting that rotates with the wheel is the failure to catch.

Claude's values (per-wheel centre / axle corrections, spoke count, which wheels to include in the
average) go in a per-car file committed next to the car's assets (e.g. `blender/f150/wheel_scan.json`).
The pipeline reads it on re-run.

### 5. In the game

- The pipeline prints the measured `wheel_radius` / `wheel_width_front` / `wheel_width_rear`;
  Claude writes them into the car's `CarLibrary` entry. These drive physics too (ride height,
  gearing via radius) — that's intended: the scan is the truth.
- A new optional spec field (e.g. `wheel_model`) on the `CarLibrary` entry names the wheel glb.
- `car.gd` → `_relocate_wheels` is the single place a wheel visual is built. With a wheel model,
  it hides the `Tire` cylinder and shows the model under each wheel's `Visual` node; without one,
  it does exactly what it does now.
- Spin and steer need no change: `drivetrain.gd` → `_update_visuals` already rotates the `Visual`
  node from the simulated spin and steer angle.
- All four wheel nodes in `car.tscn` have the same orientation, so the model's outer face must be
  turned to face outward on the left-hand wheels.
- Light it in game like the body (`ps1_models_lit.gdshader`, which includes the headlight cone)
  rather than `ps1_wheel_tire.gdshader`, which only textures the two flat ends of a cylinder.

## Left to the builder

- Polar image resolution, mesh grid density and triangle budget (keep it low; chase-cam only).
- Whether the levelling is shared code with `process.py` or the wheel step reads its saved
  transform; and how `scan.sh` orders the wheel and body stages so the arch cut gets the
  measured radius.
- How the suggested spoke count is computed.
- The exact name and shape of the per-car values file and the spec field.
- Tests: a `car.gd` test that a spec with a wheel model shows it and hides the cylinder and one
  without keeps the cylinder (synthetic spec via `CarFixtures`, no real catalogue entry), plus one
  small self-check for the averaging (a synthetic N-spoke wheel with a fake directional light
  comes out with the light gone and the spokes kept).
- Updating `features/car-scanning.md` and `features/rendering.md` for the new wheel path.

## Cleanup (separate, flagged)

The wheel-swap feature's menu is gone but its code remains: `scripts/wheel_style.gd`,
`car.gd`'s `_owned_wheel_texture` override and its preview re-skin helper, and
`features/wheel-customization.md`, which still describes the swap as live. Worth removing on its
own, not as part of this work.
