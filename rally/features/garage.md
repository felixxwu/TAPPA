# Garage — rally-team service-park model

A standalone, procedurally-built 3D model of a **WRC manufacturer service-park
garage**, modelled after the Toyota Gazoo Racing awning from the reference
photos: a long, low modular run of open service bays under one continuous flat
roof, a branded fascia band across the front, driver/crew name pillars between
the bays, white fabric curtains, a bright ceiling light rig, white branded floor
mats, and a hero rally car raised on a service lift surrounded by pit clutter
and crew figures.

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
primitives (`BoxMesh`, `CylinderMesh`, `SphereMesh`, `TorusMesh`) and `Label3D`
signage via the `_block` / `_text` helpers. There is **no imported mesh**, so the
model stays light and every proportion is a tweakable constant.

`garage.gd` is **self-contained and autoload-free**: it builds its own
`WorldEnvironment`, sun and per-bay `OmniLight3D`s, and pulls in no `Config` /
`Save` / `RallySession` singletons. That keeps it cheap to instance in headless
tests and lets the render harness `new()` it directly, isolated from the
project's normal boot.

`build()` runs one function per element (called from `_ready`, or directly):

- `_build_ground` — gravel field + tarmac apron.
- `_build_structure` — concrete slab, back/side fabric walls, inter-bay
  partition curtains, the dark front pillars, the fascia header band + tagline
  sub-strip, and the flat roof with a front overhang.
- `_build_floor_mat` — one white vinyl mat per bay with a dark border, red front/
  back accent stripes and a flat `GR` mark.
- `_build_ceiling_rig` — emissive light strips + a truss spine, plus one soft
  `OmniLight3D` per bay so the interior actually lifts.
- `_build_crew_pillars` — a vertical crew name plate on each bay pillar
  (`CREW_NAMES`).
- `_build_branding` — the `GR` logo plate, the `TOYOTA GAZOO Racing` wordmark and
  the `Pushing the limits for Better` tagline on the fascia.
- `_build_lift_and_car` — a service lift platform + legs in the centre bay, with
  a stylised liveried rally car (`#18`) raised on it.
- `_build_pit_clutter` — flight cases / tool cabinets, a tyre stack, a coiled red
  air line on a reel, and a pit timing screen showing the famous `11:26:54`.
- `_build_crew_figures` — stylised mechanics in black-and-red kit for scale.

### Orientation convention

The garage **opens toward +Z** (the apron / the viewer looks in from +Z), the
back wall is at −Z, and the bays run along X with bay 0 on the left (−X). The
origin sits on the ground at the centre of the front edge. `CENTER_BAY` is the
bay that holds the hero car.

### Re-proportioning

Tweak the constants at the top of `garage.gd` (`NUM_BAYS`, `BAY_WIDTH`,
`BAY_DEPTH`, `WALL_H`, `FASCIA_H`, …) and the palette `C_*` colours; every build
step derives its layout from `_total_width`, `_bay_center_x` and
`_pillar_center_x`, so the whole structure re-flows. `CREW_NAMES` drives the
pillar plates.

## Rendering from different angles

The headless dummy renderer can't read back pixels, so the harness renders into
a fixed-size `SubViewport` under a virtual X display:

```sh
tools/render_garage.sh        # writes docs/garage/01..06_*.png at 1280x720
```

`tools/render_garage.gd` builds the model in an offscreen `SubViewport`
(`own_world_3d`), then captures the same scene from the camera poses in `SHOTS`
(front three-quarter, front-on, bay interior, side, high overview, branding
detail) and saves each to `docs/garage/`. `render_garage.sh` supplies the
`xvfb` display + the `opengl3` driver (the only way to capture images in this
headless environment) and filters the autoload parse-error noise.

To iterate on the look: edit `garage.gd`, re-run `render_garage.sh`, eyeball the
PNGs, repeat.

## Notes / future work

- The model is a **standalone asset** today; it is not yet wired into the HQ
  hub (which still uses the placeholder block garage in `hq.gd`). Swapping the
  HQ garage for this model would be a natural follow-up.
- Materials are plain `StandardMaterial3D` (not the project's PS1 shaders), so
  the model reads cleanly on its own; if dropped into the run/HQ scenes it would
  want the shared `ps1_models` material to match the game's aesthetic.
