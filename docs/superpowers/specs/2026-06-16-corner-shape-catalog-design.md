# Corner Shape Catalog — Design

**Date:** 2026-06-16
**Status:** Approved for planning

## Goal

Establish the geometric vocabulary for rally track generation by defining each
pacenote turn type as a 2D bezier curve, and provide a standalone catalog scene
that renders all turn types side by side so their shapes can be visually
confirmed. Track *generation* itself is out of scope — this is the shape
library and a viewer.

## Background: the pacenote system

Rally corners use a severity gradient plus named special cases:

- **Gradient 1–6** — 1 is the sharpest (~85°, tight radius), 6 is the gentlest
  (~12°, large radius). Both the turned angle *and* the radius scale with the
  number (higher number = wider angle tolerance and larger radius).
- **Square** — a sharp ~90° corner, tight radius.
- **Hairpin** — ~180°, tight radius.
- **Straight** — a straight section, defined by its length in meters.

The bezier curve is the **source of truth**, not the angle/radius. This lets
compound corners be authored directly, e.g. "Right 4 tightens 2" (starts as a 4,
tightens to a 2 mid-corner) or "Left 2 opens late".

## Decisions

- **2D definitions.** Each corner is a `Curve2D` in meters (1 unit = 1 m), entry
  at the origin heading +Y. The 2D curve will later be imprinted onto the 3D
  terrain surface — that lift is a separate, future concern.
- **All corners hand-authored.** No parametric `(angle, radius)` → curve
  generator. The arc→bezier math is fiddly and a bug source; the set is small
  and fixed (~10 curves). One uniform code path: load control points → `Curve2D`.
  Sensible-looking defaults are authored so the standard corners read correctly.
- **Catalog is a standalone 2D scene.** It does not touch the car, terrain, or
  main game scene.

## Data model

Following the existing `CarLibrary` precedent (a `class_name … extends
RefCounted` script with a `const` array of dictionaries — *not* a `.tres`), the
corner library is a GDScript class:

```
CornerLibrary (class_name, extends RefCounted)   # scripts/corner_library.gd
  const CORNERS: Array[Dictionary]
    each: { "name": String, "points": Array }
      # name:   "4", "Hairpin", "Right 4 tightens 2", ...
      # points: ordered control points, each [position, in_control, out_control]
      #         as Vector2 (meters; entry at origin heading +Y, in/out relative
      #         to position per Curve2D.add_point)
  static func build_curve(spec: Dictionary) -> Curve2D
    # assembles a Curve2D from a CORNERS entry's points
```

- Data libraries live in code (like `CarLibrary`); only tuning values live in
  `config/game_config.tres`. So no `.tres` file is created.
- `build_curve` is the single place that turns point data into a `Curve2D`,
  reused by both the catalog scene and the tests.
- No extra per-corner metadata (severity number, recommended speed) for now —
  `name` + `points` is sufficient.

## The catalog set

The shipped library contains:

- **Gradient 1, 2, 3, 4, 5, 6** — increasing radius and decreasing angle as the
  number rises (1 ≈ 85° tight … 6 ≈ 12° gentle).
- **Square** — sharp ~90°, tight radius.
- **Hairpin** — ~180°, tight radius.
- **Straight** — a 50 m straight line.
- **Right 4 tightens 2** — a multi-point compound corner that begins as a 4 and
  tightens to a 2, demonstrating the authored-control-point path.

## Catalog scene

`corner_catalog.tscn` + `scripts/corner_catalog.gd` (a `Node2D`), placed at the
project root alongside `main.tscn` / `car.tscn` to match convention.

On `_ready()`:

1. Load `config/corner_library.tres`.
2. For each `CornerDef`, lay it out left-to-right in a single row, auto-spaced by
   each curve's bounding box plus a fixed gutter, scaled meters → pixels.
3. Per corner, draw:
   - **Centerline** — the tessellated curve (`Curve2D.tessellate()`), as a
     `Line2D` or `_draw()` polyline.
   - **Control points** — small markers at each `Curve2D` point.
   - **Tangent handles** — thin lines from each point to its in/out control
     positions, with small end markers.
   - **Entry marker** — a green dot at the curve start.
   - **Label** — the corner's `name` as text above the curve.

This scene is the one you run to see every turn type at once.

## Testing

`tests/headless/test_corner_library.gd` (GUT) asserts:

- `CornerLibrary.build_curve()` produces a non-empty `Curve2D` (≥ 2 points) for
  every entry in `CornerLibrary.CORNERS`.
- Corner names are unique.
- The expected standard corners are all present: `1`–`6`, `Square`, `Hairpin`,
  `Straight`, and the compound `Right 4 tightens 2`.

`./run_tests.sh` must pass (run in the background) before the work is complete.

## Documentation

- New `features/track.md` — first file of the track-generation feature area:
  documents the corner library, the `Curve2D`-in-meters convention, the data
  model, and the catalog scene.
- Add a `track.md` row to the `features/README.md` feature index and
  file-to-feature quick map.

## Out of scope

- Track generation / sequencing corners into a course.
- Imprinting curves onto 3D terrain.
- A parametric corner generator.
- In-game use of the corner library.
```
