# Car Scanning (video → game body)

**Source:** `tools/car_scan/scan.sh` (driver), `tools/car_scan/mask.swift`, `tools/car_scan/cameras.py`, `tools/car_scan/register.py`, `tools/car_scan/capture.swift`, `tools/car_scan/align.py`, `tools/car_scan/process.py`, `tools/car_scan/texturing.py`, `tools/car_scan/texture.py`, `tools/car_scan/wheels.py`, `tools/car_scan/wheel_math.py`, `tools/car_scan/wheel_inspect.py`, `tools/car_scan/preview.py`, `tools/car_scan/export.py`, `tools/car_scan/open.py`

**Tests:** none — an offline art tool, checked by eye from its preview renders.

Turns a walk-around video of a car (a Forza garage orbit, the setup the F-150 was filmed in) into a ~1000-triangle textured
body glb like `blender/mx5/mx5.glb`. Runs on macOS only: the reconstruction is Apple's Object
Capture (`RealityKit.PhotogrammetrySession`), which needs Xcode command-line tools for `swiftc`.
Also needs `ffmpeg` and Blender (`/Applications/Blender.app`, override with `$BLENDER`).

## Running it

```
tools/car_scan/scan.sh ~/Downloads/video.mp4 /tmp/scan-f150 5.0 --wheel-radius 0.37 --clearance 0.22
```

The third argument is the car's real length in metres (the scan has no scale of its own). Work
files stay in the work dir; each stage is skipped when its output already exists, so after the
slow Object Capture step (~5–10 min) you can rerun with different `process.py` options in under a
minute. Check `<work>/preview.png`; if the car faces backwards rerun with `FLIP=1`.

Stages:

1. **Frames** — `ffmpeg` samples `FPS` (default 9) frames per second. ~1600 frames of a
   2–3 minute orbit worked well; Object Capture skips blurry or duplicate frames itself.
2. **Mask** — `mask.swift` writes a mask per frame (white = the car) with Vision's subject lifting
   (`VNGenerateForegroundInstanceMaskRequest`, the biggest subject found). Extreme close-ups where
   it finds no car get no mask and are simply skipped by the carving. `mask <frames> <masks> 160`
   does every 160th frame only, for a quick check.
3. **Reconstruct** — `capture.swift` runs Object Capture on the **unmasked** frames at `full` detail,
   giving `model.usdz` (car plus garage floor), and saves every camera's position and lens to
   `model.usdz.poses.json`. Frames must be in camera order; set `UNORDERED=1` when mixing videos.
   Don't black out the background first: the garage is what pins the cameras down. Blacked-out
   frames rebuilt the black as a shell glued to the car, and on the wrapped F-150 placed part of
   the orbit a truck-length off, so the whole truck came out twice. Handing Object Capture the masks
   directly (`PhotogrammetrySample.objectMask`) was also tried: it ignored them.
4. **Align** — `align.py` first carves away everything that isn't the car: it projects each
   scan vertex into every third saved camera and deletes any that land outside that frame's mask
   more than 15% of the time. That removes the garage floor and walls by position rather than
   colour, so dark tyres survive. It
   then crops what's left (drops a flat floor if one remains, keeps the bulky loose piece), turns
   the scan's long axis onto +Y, scales it to the given length and sits it on the ground.
5. **Process** — `process.py` levels the scan on its four tyre contacts and centres it between the
   axles. The body is then built not from the scan but from an outer **shell**: 4 cm voxels kept
   wherever (nearly) every saved camera saw the car, never the background, so it is closed, with
   solid windows, a whole roof and no interior. `--open-box` cuts an open load space (a pickup's
   bed) back out of it, since an outline can't see one. The shell is sliced at `--clearance`, gets
   dark wheel arches cut for the game's own wheels, is decimated, and has the scan's colour baked
   onto it. Where the bake found no scan within 12 cm (windows, holes) it paints flat colour: dark
   glass above `--glass-min-z`, the car's paint elsewhere. Then it paints over the rear number
   plate. Output: `body/car_body.glb` + `.blend`. `cameras.py` holds the camera maths shared with
   `align.py`.
6. **Preview** — `preview.py` renders it from four angles into `preview.png`.

To look it over in Blender, with the full scan parked beside the game body:
`$BLENDER <work>/body/car_body.blend --python tools/car_scan/open.py`.

## Two videos: shape from a wrap, colour from the paint

Plain gloss paint gives photogrammetry almost nothing to match, so the scan comes out holey. Film the
car twice in the same spot, garage and lighting: once in a random high-contrast wrap (camo, noise;
not stripes or checks, which repeat) and once in its real paint, matte if possible. Then:

```
PAINT=~/Downloads/paint.mp4 tools/car_scan/scan.sh ~/Downloads/wrap.mp4 <work> <length_m> [options]
```

The wrap video goes through the whole pipeline above and gives the shape. The paint video is never
reconstructed (it would be holey too). Instead:

1. `PAINT_FPS` (default 3) frames per second are taken from it.
2. One camera-finding-only Object Capture run (`capture ... poses`) goes over every third wrap frame
   and all the paint frames together, unmasked: the garage, tyres, trim and glass are the same in both
   videos and tie them into one space. It writes `joint.usdz.poses.json`.
3. `register.py` fits the scale, rotation and offset that carry that run's wrap cameras onto the wrap
   reconstruction's own cameras, and moves the paint cameras across with it (`paint.poses.json`). It
   refits on the best-agreeing half, because some cameras come out misplaced in one run (on the
   F-150 a misplaced stretch of the wrap run is also what doubled its bed); the printed misfit
   should be well under 1% of the orbit radius.
4. `process.py --paint-poses --paint-frames` colours each texel from the paint frames that see it
   most head-on, skipping any frame where another part of the car is in front of it (checked against
   the scan's depth from that camera). Spots no paint frame faced get the same flat fill as holes.

## Hand-modelled bodies (`texture.py`)

The automatic body (`process.py`'s outline shell, decimated) is still rough. The F-150 instead used a
low-poly body modelled by hand over the levelled scan, then textured by `texture.py`:

```
$BLENDER -b <scan.blend> --python tools/car_scan/texture.py -- <outDir> --body <object> \
    --wheel-radius 0.37 --cut-radius 0.42 --glass-min-z 1.3 --paint-poses <work>/paint.poses.json --paint-frames <work>/paint_frames
```

`<scan.blend>` holds the levelled scan (its custom properties link it back to the saved cameras:
`usd_to_aligned`, `levelling`, `poses`, `masks`) and the hand-made body, which must sit over the scan
exactly as saved. Modifiers (e.g. a Mirror) are applied, wheel arches are cut, with a tub left over each
wheel where an arch would punch through a floor (a pickup's bed), and it is given fresh UVs. The baking,
paint projection, glass and gap fills and plate blanking are `texturing.py`, shared with `process.py`.
`open.py` parks the scan 3 m to the side for comparison.

## Scanned wheels (`wheels.py`)

```
$BLENDER -b <scan.blend> --python tools/car_scan/wheels.py -- <outDir> --poses <work>/paint.poses.json \
    --frames <work>/paint_frames --values blender/<car>/wheel_scan.json
$BLENDER -b <scan.blend> --python tools/car_scan/wheel_inspect.py -- <outDir>
```

Builds one game wheel from the scan's four (`wheel_math.py` holds the maths and runs a self-check on synthetic
wheels: `python3 tools/car_scan/wheel_math.py`):

1. **Fit** — each wheel is fitted as standing on its ground contact, axle along ±x (`fit_standing`): the radius
   is the circle through the contact with the most scan points on its lower half, where only the tyre's outline
   is (the arch is all above, the crowded face sits off the ring). A free fit wandered badly: the scan sees too
   little of a tyre's inner side. Points up to 0.15 m outward of the tyre are kept, as a hubcap stands proud.
2. **Unwrap** — a sample point per image cell, laid on the fitted wheel (`cell_points`): the face at each
   ring's outermost scan depth (`face_profile`), the tread across its width; the paint video colours them
   (`texturing.paint_from_video`). Sampling per cell, not per scan point, keeps the images full: the F-150's
   scan has ~800 points per wheel against 9 216 cells.
3. **Average** (`symmetrise`) — the face folded over its spoke repeat and averaged across the wheels (lined up
   by turn first), the tread averaged all the way round. The light's direction is fixed while the pattern
   repeats, so its baked highlight cancels.
4. **Rebuild** — a lathe: the dished outer face, the tread, and a flat inside face in plain tyre colour, 16
   sides, ~580 tris; texture = the face as a disc beside the tread strip. Writes `wheel.glb`,
   `wheel_texture.png` and `fits.json`, and prints `MEASURED wheel_radius … wheel_width …`.

Claude's judgement calls go in `blender/<car>/wheel_scan.json` (`spokes`, `include`, per-wheel `nudges` of
`centre` [dy, dz] and `axle_deg` [yaw, pitch]), made from `wheel_inspect.py`'s renders: `check_<wheel>.png` (the
wheel face-on, 500 px/m, 10 cm grid, fitted circle and centre in pink: the circle should sit on the tyre's edge)
and `spin_<deg>.png` (the built wheel at four turns: a highlight that turns with it is light that didn't
average out). The suggested spoke count is unreliable on near-round hubcaps; read it off `check_*.png`.

Then cut the body's arches at the measured wheels (`texture.py`/`process.py --wheel-values <outDir>/fits.json`,
which also sets the cut radius) and give the car's `CarLibrary` entry `wheel_model`, `wheel_radius`,
`wheel_width_front/rear`, `track` and `wheelbase` from `fits.json`. The game side is `car.gd` →
`_apply_wheel_model` ([rendering.md](rendering.md) → Scanned wheel models).

## Per-car options (`process.py --help`)

Everything else is derived from the scan (wheel search zone from its length and width, rear
bumper and plate from its tail). What has to be given per car:

- `--wheel-radius` / `--cut-radius` — tyre radius, and how big an arch to cut around it.
- `--axle-zone MIN MAX` — only if the WHEELS line prints nonsense (body comes out tilted): the
  distance from the car's middle to search for each axle's tyre contacts, which must bracket
  half the wheelbase. Defaults to 40–92% of half the car's length.
- `--clearance` — height below which the scan is discarded (Object Capture fills the underside
  down to the floor).
- `--glass-min-z` — beltline height; filled-in surfaces above it are painted as glass.
- `--open-box X0 X1 Y0 Y1 Z0` — an open load space to cut out of the shell, in metres after
  levelling (origin midway between the axles, length along Y).

The game's wheels sit at the WHEELS contacts the process step prints, so the car's `wheelbase`
in `CarLibrary` must match the scan's (the MX-5's 2.25 m) or the wheels clip the arches.

## Into the game

The F-150 (`blender/f150/`) went in this way: hand-modelled body textured with `texture.py`, then
`export.py`, a `CarLibrary` entry whose `track`/`wheelbase`/`wheel_radius` match the scan's WHEELS
contacts and arch cut, and an `F150Body` node in `car.tscn` sitting at minus the car's settled ride
height (`car.gd` → `settled_ride_height`), since the exported body's origin is on the ground.

```
$BLENDER -b <work>/body/car_body.blend --python tools/car_scan/export.py -- <work>/body blender/<car> <car>
```

writes `blender/<car>/<car>.glb` + `.blend` with the nose on +X like the other bodies. Wiring it
into `car.tscn` and `CarLibrary` (`use_model`, `model_node`, `model_texture`) is covered in
[rendering.md](rendering.md) (Authored body models); mind the two-textures-per-car trap in
[asset-pipeline.md](asset-pipeline.md).
