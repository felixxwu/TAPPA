# Scanned 3D Wheels Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn a car's photogrammetry scan into one de-lit, round, spoke-symmetric low-poly wheel model per car, and show it in game in place of the textured cylinder for cars that have one.

**Architecture:** An offline step in `tools/car_scan/` unwraps each scanned wheel into polar images (colour from the paint video, depth from the scan), averages them over the spoke repeat and across all four wheels, and rebuilds a lathe tyre plus a polar-grid rim face as `blender/<car>/wheel.glb`. The judgement values (centre/axle nudges, spoke count) live in a committed `blender/<car>/wheel_scan.json` that Claude authors from inspection renders. In game, `car.gd` → `_relocate_wheels` instances the wheel model under each wheel's `Visual` node when the spec names one.

**Tech Stack:** Blender 5.2 Python + numpy (Blender's bundled `python3.13` has numpy, no PIL/scipy), ffmpeg for image I/O, Godot 4.6 GDScript, GUT tests.

**Spec:** `todo/2026-10-27-scanned-wheels.md`

## Global Constraints

- Measured size from the scan is the truth: radius and width go into the car's `wheel_radius`, `wheel_width_front`, `wheel_width_rear`.
- One wheel model per car, used on all four corners; a staggered car (front/rear clearly different) gets one model per axle, never a non-uniformly scaled one (`ps1_models_lit.gdshader` assumes uniform scale).
- Cars without a wheel model keep today's cylinder path exactly.
- PS1 look, low tris, chase-cam distance only.
- Never test tunable/catalogue values or depend on a real catalogue entry (`CarFixtures.install()`); never pin the F-150's numbers.
- Subagents implement; the parent runs the tests. Offline Python tools get one runnable self-check, not a suite.

## Review Focus

1. **Switching cars back and forth** (wheel-model car → cylinder car → wheel-model car on the same `car.tscn` instance, and frozen props from `car_prop.gd`): the cylinder must reappear, no duplicate wheel models pile up. → Task 5 test.
2. **Spec radius differs from the model's own radius** (someone retunes `wheel_radius`): the model must scale uniformly to the spec radius so it still meets the ground. → Task 5 test.
3. **Right-hand wheels showing their inner face**: all four wheel nodes share one orientation, so the model must be turned outward per side. → Task 5 test.
4. **A scan wheel partly missing or merged with the arch** (fewer than four usable wheels): the averaging must work from whichever wheels `wheel_scan.json` includes, and refuse with a clear message if none. → Task 2 self-check.
5. **A spoke count that doesn't divide the polar grid's columns**: the N-fold average must still be exact (resample, don't drop columns). → Task 2 self-check.

---

### Task 1: Find and unwrap each scanned wheel

**Files:**
- Create: `tools/car_scan/wheel_math.py` (bpy-free numpy: fitting, polar resampling, averaging; runnable self-check under `__main__`)
- Create: `tools/car_scan/wheels.py` (Blender driver; this task adds the unwrap stage)

**Interfaces:**
- Consumes: `texturing.wheel_contacts(me) -> {(sx, sy): Vector}`, `texturing.paint_from_video(points, normals, scan_me, to_usd, poses_path, frames_dir) -> (colour[N,3], weight[N])`, `texturing.surface_points(me)`; the scan object's custom props `usd_to_aligned`, `levelling`.
- Produces: `wheel_math.fit_wheel(points: ndarray[N,3], side: int) -> dict(centre: ndarray[3], axle: ndarray[3], radius: float, width: float)`; `wheel_math.unwrap(points, colours, fit, rings=48, sectors=192) -> dict(face_rgb[rings,sectors,3], face_depth[rings,sectors], tread_rgb[16,sectors,3], tread_radius[16,sectors], seen[...] masks)`. `wheels.py` CLI: `blender -b <scan.blend> --python wheels.py -- <outDir> --poses P --frames F [--values blender/<car>/wheel_scan.json]`.

- [ ] **Step 1: Write the self-check** in `wheel_math.py`'s `__main__`: build a synthetic tyre (radius 0.37, width 0.24, axle along x, centre (0.8, 1.5, 0.37)) as a point cloud, offset and tilt it 3°, then assert `fit_wheel` recovers the centre within 5 mm, the axle within 0.5°, radius within 5 mm, width within 1 cm; and that `unwrap` of a colour that is a pure function of angle round-trips (column mean of `face_rgb` matches the input within 0.02).
- [ ] **Step 2: Run it to see it fail** — `/Applications/Blender.app/Contents/Resources/5.2/python/bin/python3.13 tools/car_scan/wheel_math.py` → fails (functions missing).
- [ ] **Step 3: Implement `fit_wheel` and `unwrap`.** Axle = the smallest-variance principal direction of the wheel's points, signed to point away from the car (`side`); centre = least-squares circle fit of the tread points projected onto the plane normal to the axle; radius = that circle's radius; width = the spread along the axle of points within 3 cm of the radius. `unwrap` bins points by (distance from axle centre, angle) for the outer face and (position across tread, angle) for the tread, averaging colour and depth per bin and leaving a `seen` mask for empty bins.
- [ ] **Step 4: Run the self-check** → prints `wheel_math OK`.
- [ ] **Step 5: Implement the unwrap stage in `wheels.py`.** For each contact: take scan `surface_points` inside a box around it (|y − contact.y| < 0.6, z < 0.85, |x| > 0.4, side matching), fit, colour the points with `paint_from_video` (normals from the scan's vertex normals), unwrap; apply any per-wheel `centre_nudge`/`axle_nudge` from the values file before unwrapping. Save `<outDir>/wheel_<fl|fr|rl|rr>_{face,tread}.png` (8-bit, via ffmpeg rawvideo) and `<outDir>/fits.json`. Print `WHEEL fl radius 0.371 width 0.238 ...` per wheel.
- [ ] **Step 6: Run on the F-150** (`f150_scan.blend`, the registered `paint.poses.json`, the paint frames) and check four `WHEEL` lines with radii within 2 cm of each other.
- [ ] **Step 7: Commit** `tools/car_scan/wheel_math.py tools/car_scan/wheels.py`.

### Task 2: Average away the baked light and the asymmetry

**Files:**
- Modify: `tools/car_scan/wheel_math.py`
- Modify: `tools/car_scan/wheels.py`

**Interfaces:**
- Consumes: Task 1's unwrap dicts.
- Produces: `wheel_math.suggest_spokes(face_rgb, seen, max_n=12) -> int`; `wheel_math.symmetrise(unwraps: list[dict], spokes: int) -> dict` (same shape as one unwrap, every bin filled: face averaged over the `spokes`-fold rotation and across wheels, mirrored left/right to one orientation; tread averaged over all angles).

- [ ] **Step 1: Extend the self-check:** a synthetic 5-spoke face (spokes as dark wedges) multiplied by a fake directional light `0.6 + 0.4·cos(θ − 40°)`, across four wheels lit from different angles with 20% of bins unseen, `sectors=192` (5 doesn't divide 192). Assert `suggest_spokes` returns 5; after `symmetrise` the per-ring colour varies with angle only at the spoke frequency (residual of the light term < 0.03); every bin is filled. Also assert `symmetrise([])` raises `ValueError` mentioning "no usable wheels".
- [ ] **Step 2: Run** → fails.
- [ ] **Step 3: Implement.** `suggest_spokes`: strongest peak of the angular autocorrelation of the seen face colour over n = 3…max_n. `symmetrise`: resample each ring to a multiple of `spokes` columns (linear interpolation in angle) before folding, weight bins by `seen`, fill remaining empty bins from the nearest ring.
- [ ] **Step 4: Run** → `wheel_math OK`.
- [ ] **Step 5: Wire into `wheels.py`:** spoke count = values file's `spokes` if set, else `suggest_spokes` (printed as `SPOKES suggested 6`); wheels averaged = values file's `include` (default all four). Save `<outDir>/wheel_face.png`, `wheel_tread.png`.
- [ ] **Step 6: Commit.**

### Task 3: Inspection renders for Claude's judgement calls

**Files:**
- Create: `tools/car_scan/wheel_inspect.py`
- Create: `blender/f150/wheel_scan.json`

**Interfaces:**
- Consumes: `fits.json` and the PNGs from Tasks 1–2.
- Produces: `wheel_scan.json` schema: `{"spokes": int|null, "include": ["fl","fr","rl","rr"], "nudges": {"fl": {"centre": [dy, dz], "axle_deg": [yaw, pitch]}, ...}}` (all optional; metres, degrees).

- [ ] **Step 1: Implement `wheel_inspect.py`** (Blender, `-- <scan.blend> <outDir>`): per wheel, an orthographic face-on render of the scan wheel at 500 px/m with a 10 cm grid, the fitted circle and centre drawn over it (drawn as a thin torus + cross in the scene, so no image library is needed); a stack of the four unwrapped face strips; and, after Task 4 exists, the finished wheel at spin angles 0/30/60/90° under flat light in one sheet. A wrong centre shows as a wavy outer edge in the strip.
- [ ] **Step 2: Run on the F-150 and author `blender/f150/wheel_scan.json`** by reading the renders: nudge any wheel whose circle misses the rim edge, confirm or override the spoke count, drop a wheel that's merged with the arch. Re-run Tasks 1–2 with the file until the strips' outer edges are straight.
- [ ] **Step 3: Commit** `tools/car_scan/wheel_inspect.py blender/f150/wheel_scan.json`.

### Task 4: Rebuild the low-poly wheel and export it

**Files:**
- Modify: `tools/car_scan/wheels.py`
- Modify: `tools/car_scan/texture.py`, `tools/car_scan/process.py` (read the measured radius)

**Interfaces:**
- Consumes: `symmetrise` output, mean `fit` radius/width.
- Produces: `blender/<car>/wheel.glb` — one mesh, axle along +X, outer face toward +X, centred on the origin, radius = measured radius, in metres; `blender/<car>/wheel_texture.png`; printed line `MEASURED wheel_radius 0.371 wheel_width 0.238`. `texture.py`/`process.py` accept `--wheel-values <outDir>/fits.json` as the default for `--wheel-radius` (and `--cut-radius` = radius + 0.05).

- [ ] **Step 1: Build the mesh in `wheels.py`:** tyre = lathe of the averaged tread radius profile (16 steps across, 24 around); rim face = polar grid (8 rings × 24 sectors) displaced by the averaged face depth; inner face = the outer face mirrored. UVs: face as a disc, tread as a strip, in one 512 px texture assembled from the averaged images. Target ≤ 600 tris.
- [ ] **Step 2: Export** with `export_scene.gltf` to `blender/<car>/wheel.glb` and save the texture; print `MEASURED`.
- [ ] **Step 3: Run on the F-150**, then `wheel_inspect.py`'s spin sheet; check by eye that no highlight rotates with the wheel. Record what you saw in the commit message.
- [ ] **Step 4: Wire `--wheel-values` into `texture.py` and `process.py`; re-run `texture.py` on the F-150 with it so the arches are cut from the measured radius, and re-export the body (`export.py`).**
- [ ] **Step 5: Commit** the tools, `blender/f150/wheel.glb`, `wheel_texture.png`, and the re-exported body.

### Task 5: Show wheel models in game

**Files:**
- Modify: `scripts/car.gd` (`_relocate_wheels`)
- Modify: `scripts/car_library.gd` (doc the optional `wheel_model` field in the header; F-150 entry in Task 6)
- Test: `tests/headless/test_wheel_models.gd` (new), `tests/headless/fixtures/test_wheel.tscn` (new)

**Interfaces:**
- Consumes: spec field `wheel_model: String` (res path to a glb shaped as Task 4 produces) and the spec's `wheel_radius`.
- Produces: under each `VehicleWheel3D/Visual`, a child node named `WheelModel` when the spec has `wheel_model`; `Visual/Tire` hidden then, shown otherwise.

- [ ] **Step 1: Write the failing tests** (synthetic specs via `CarFixtures.install()`, one fixture car given `"wheel_model": "res://tests/headless/fixtures/test_wheel.tscn"` — a new test-owned scene holding one `MeshInstance3D` with a `CylinderMesh` of radius 0.5 turned to an X axle, so no test depends on a real car's asset; no assertions on catalogue numbers):
  - `test_wheel_model_car_hides_the_cylinder_and_shows_the_model`: after `apply_car(i)`, every wheel has `Visual/WheelModel` visible and `Visual/Tire` hidden.
  - `test_cylinder_car_after_a_wheel_model_car_restores_the_cylinder`: apply model car, then a fixture car without the field: `Tire` visible, no `WheelModel` child; apply the model car again: exactly one `WheelModel` per wheel.
  - `test_wheel_model_scales_to_the_spec_radius`: give the fixture two different `wheel_radius` values in turn; the `WheelModel`'s global AABB height ≈ 2 × spec radius (± 1 cm) each time.
  - `test_wheel_model_outer_face_points_away_from_the_car`: for each wheel, the `WheelModel`'s global +X axis dotted with the car's right vector has the sign of the wheel's local x position.
- [ ] **Step 2: Run** `./run_tests.sh --fast test_wheel_models` → FAIL.
- [ ] **Step 3: Implement in `_relocate_wheels`:** when `spec.get("wheel_model", "")` is set, load it once (cache per path like `_wheel_mats`), instance as `WheelModel` under `Visual` if missing, uniform scale = spec radius / the model's own radius (its AABB half-height), rotate 180° about Y for wheels whose mount x has the sign that faces the model inward, apply `_apply_model_material` with the model's own texture; hide `Tire`. Otherwise free any `WheelModel` and show `Tire`. Spin/steer need no change (`drivetrain.gd` → `_update_visuals` already rotates `Visual`).
- [ ] **Step 4: Run** `./run_tests.sh --fast test_wheel_models test_car_types test_car_library test_car_preview_cache test_wheel_customization` → PASS.
- [ ] **Step 5: Update `features/rendering.md`** (per-car wheel section: the model path beside the cylinder path) and commit.

### Task 6: Ship the F-150's wheels

**Files:**
- Modify: `scripts/car_library.gd` (F-150 entry), `features/car-scanning.md`, `todo/2026-10-27-scanned-wheels.md`

- [ ] **Step 1:** Set the F-150's `wheel_model` to `res://blender/f150/wheel.glb` and its `wheel_radius` / `wheel_width_front` / `wheel_width_rear` to the `MEASURED` values; keep `track`/`wheelbase` matched to the arches.
- [ ] **Step 2: Run** `./run_tests.sh --fast test_car_types test_car_stats test_car_library test_wheel_models test_smoke` → PASS (roster physics: sits on the ground, absorbs a drop, stays upright, drives forward).
- [ ] **Step 3:** Document the wheel step in `features/car-scanning.md` (commands, `wheel_scan.json`, what each inspection render is for); ask the user whether to trim the spec's completed items.
- [ ] **Step 4: Commit.**
