# Garage — rally-team service-park model

A standalone, procedurally-built 3D model of a **rally-team service-park
garage**: a low modular structure of **two open, empty service bays** under one
flat roof, with a plain dark fascia band across the front, dark divider pillars,
off-white fabric walls and a simple ceiling light rig. The bays are deliberately
**bare** so the game can stage its own contents inside them (e.g. the player's
car). The model carries **no team branding**.

## Where it lives

| Thing | File |
|-------|------|
| Model builder | `scripts/garage.gd` |
| Scene | `garage.tscn` (a `Node3D` running `garage.gd`) |
| Multi-angle renderer | `tools/render_garage.gd` (SceneTree) + `tools/render_garage.sh` |
| Reference renders | `docs/garage/*.png` |
| Test | `tests/headless/test_garage.gd` |

## How it's built

Like `hq.gd` and `podium.gd`, the geometry is **procedural** — built from Godot
primitives (`BoxMesh`, `PlaneMesh`) via the `_block` helper. There is **no
imported mesh** and no signage, so the model stays light and every proportion is
a tweakable constant.

`garage.gd` is **self-contained and autoload-free**: it builds its own
`WorldEnvironment`, sun and per-bay `OmniLight3D`, and pulls in no `Config` /
`Save` / `RallySession` singletons. That keeps it cheap to instance in headless
tests and lets the render harness `new()` it directly, isolated from the
project's normal boot.

`build()` runs one function per element (called from `_ready`, or directly):

- `_build_ground` — gravel field + tarmac apron.
- `_build_structure` — concrete slab, back/side fabric walls, the dark front
  pillars (`NUM_BAYS + 1` of them), the plain fascia header band, and the flat
  roof with a front overhang.
- `_build_ceiling_rig` — one emissive light strip + one soft `OmniLight3D` per
  bay, just enough to light the empty interior.

### Orientation convention

The garage **opens toward +Z** (the apron / the viewer looks in from +Z), the
back wall is at −Z, and the bays run along X with bay 0 on the left (−X). The
origin sits on the ground at the centre of the front edge.

### Re-proportioning

Tweak the constants at the top of `garage.gd` (`NUM_BAYS`, `BAY_WIDTH`,
`BAY_DEPTH`, `WALL_H`, `FASCIA_H`, …) and the palette `C_*` colours; every build
step derives its layout from `_total_width`, `_bay_center_x` and
`_pillar_center_x`, so the whole structure re-flows.

## Rendering from different angles

The headless dummy renderer can't read back pixels, so the harness renders into
a fixed-size `SubViewport` under a virtual X display:

```sh
tools/render_garage.sh        # writes docs/garage/01..05_*.png at 1280x720
```

`tools/render_garage.gd` builds the model in an offscreen `SubViewport`
(`own_world_3d`), then captures the same scene from the camera poses in `SHOTS`
(front three-quarter, front-on, bay interior, side, high overview) and saves each
to `docs/garage/`. `render_garage.sh` supplies the `xvfb` display + the
`opengl3` driver (the only way to capture images in this headless environment)
and filters the autoload parse-error noise.

To iterate on the look: edit `garage.gd`, re-run `render_garage.sh`, eyeball the
PNGs, repeat.

## Notes / future work

- The model is a **standalone asset** today; it is not yet wired into the HQ
  hub (which still uses the placeholder block garage in `hq.gd`). Swapping the
  HQ garage for this empty shell — and parking the player's car inside it — would
  be a natural follow-up.
- Materials are plain `StandardMaterial3D` (not the project's PS1 shaders), so
  the model reads cleanly on its own; if dropped into the run/HQ scenes it would
  want the shared `ps1_models` material to match the game's aesthetic.
