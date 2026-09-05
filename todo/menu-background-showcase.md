# Menu background showcase (spec, not yet built)

**Status: drafted with the user, not implemented.** This is a spec for the `todo/`
process (CLAUDE.md) — read it before starting, and keep it in sync as pieces land.

## The ask

The hub (`hub.tscn` / `hub_shell.gd`, [hub-shell.md](hub-shell.md)) is currently a bare
`Control` — flat colour/UI, nothing behind it. The ask is a **live 3D scenic
background**: a fixed, authored track the camera flies around and cuts between angles
on while the player sits in the menu, similar in spirit to the between-stage replay
cinematic ([event-replay.md](event-replay.md)) but with no car, no run, and no player
input — pure scenery.

**Decisions already made with the user (do not re-litigate without reason):**

1. **Fixed-seed procedural track.** Reuse `TrackGenerator`/`TrackGenParams` with one
   hardcoded seed picked for good scenery, rather than hand-placing a bespoke scene.
2. **Live 3D scene**, not a pre-baked video loop — same "real camera behind the menu"
   shape as the rest of the game, accepting the runtime GPU/CPU cost (including
   mobile — needs LOD/quality care, see Open questions).
3. **All six shipped regions** (`home`, `home_coast`, `greece`, `greece_coast`, `snow`,
   `taiga`) get a segment, not a curated subset.
4. **Why one track instead of six separate scenes**, per the user directly: *"The
   mixed terrain is just an optimisation to make sure there is no lag between camera
   cuts."* All six regions must already be resident and rendered before the first cut,
   so a cut is a camera move, never a load. This is the load-bearing reason for
   building one scene with six segments rather than swapping/reloading a
   single-region world per shot the way a stage does today.
5. **Never cut close to a region border.** Camera shots must stay far enough inside a
   segment that the seam between two regions' looks is never in frame — the segments
   should read as one continuous world, not six worlds glued together.

## Why this needs new machinery, not a reuse of `world.gd`

Today, "a region" and "a driven world" are 1:1: `world.gd::_apply_region_look`
resolves **one** `region_id` per stage and pushes that region's whole look (sky,
`Floor.chunk_material` textures, foliage split) onto the single shared floor/sky
material ([regions.md](regions.md)). There is no code path today that renders more
than one region's look in the same scene at once — the one system that ever did
(`Overworld._apply_region_look`, blending regions spatially with a rank→LUT texture
and per-chunk foliage keys) belonged to the diegetic overworld, which is **deleted**
(`PIVOT-CHANGES.md`). `regions.md` calls the LUT idea "the reusable half" of that
deleted system — it's the one piece of prior art for exactly this problem.

`world.gd` itself is not a good host to extend for this: its `_ready` is wired
through `RunSession`, `DrivingContext.apply_stage_config`, `StageManager`, the car,
damage, coins, the pause menu, etc. — all run/session concerns this feature has none
of. **This should be its own standalone scene/script**, sharing only the
low-level generation and rendering primitives (`TrackGenerator`, `TerrainManager`,
`Foliage`), not `world.gd` or `main.tscn`.

## Proposed shape

### New files

- `scripts/menu_showcase.gd` (`class_name MenuShowcase`, extends `Node3D`) — builds
  the fixed track once, slices it into six region segments, spawns one
  `TerrainManager` (or the minimal subset of it needed — see open question below),
  one set of region-tinted ground chunks, and one `BillboardField` per
  segment/species mix. Analogous in spirit to `world.gd::_generate_track` +
  `_build_persistent_managers` + `_apply_region_look`, but built standalone and with
  no run/session coupling.
- `scripts/menu_showcase_camera.gd` (`class_name MenuShowcaseCamera`, extends
  `Camera3D`) — the shot-rotation director. Modelled directly on
  `scripts/replay_camera.gd`'s pattern (`enum Shot`, a deterministic `_tick(delta)`,
  fixed per-shot dwell, `look_at` per shot, the constant-subject-size FOV zoom for any
  wide/pulled-back shots) but with **no target car** — shots frame fixed points along
  the centerline instead of a followed `Node3D`.
- `menu_showcase.tscn` — the scene `HubShell` instantiates behind its UI.

### Track generation and region slicing

- One `TrackGenParams` built with a dedicated constant seed
  (`MenuShowcase.SHOWCASE_SEED`, picked by eye for scenery — same "authored,
  hand-tuned, never asserted as a value" rule as everywhere else per CLAUDE.md) and a
  high enough `turn_count` that the resulting `centerline` (a `Curve2D`, per
  `TrackGenerator.generate`'s documented result shape — see
  `scripts/track_generator.gd` lines ~224-227, 384-387) is long enough to divide into
  six roughly-equal arc-length segments.
- Segment boundaries are arc-length offsets along that one `Curve2D`
  (`Curve2D.get_baked_length()` / `sample_baked`), assigned to
  `RegionLibrary.ordered()` in order (array order here carries real meaning for this
  feature specifically — a display convenience, not the progression-order rule
  `regions.md` documents for gating, which stays untouched).
- Each segment's terrain/foliage/materials apply that segment's
  `RegionLibrary.look_of(region_id)` exactly as `world.gd._apply_region_look` does
  for a whole stage today, just scoped to that arc-length range instead of the whole
  floor.

### Applying six looks in one scene

This is the crux and the actual novel work — `world.gd`'s theming assumes one shared
material for the entire floor. Options to weigh (do not commit to one without
checking cost against the mobile budget in `features/testing.md`'s cost-model
sibling docs and `todo/performance-optimisations.md`):

1. **Per-segment ground chunks**: six separate ground meshes/materials, each textured
   from its own region's `grass_texture`/`gravel_texture`/`tarmac_color`, seated only
   under their own arc-length range. Simplest to reason about; six materials instead
   of a LUT.
2. **Revive the overworld's rank→LUT idea** (`regions.md` → "Where the look is
   applied depends on the world"): a rank→look LUT keyed by segment, sampled per
   fragment by arc-length/segment id, so the ground is one mesh with a blended
   material. More GPU-elegant, more work to stand up from a deleted system.

Foliage: one `Foliage.spawn_trees`/`spawn_bushes` call (or `BillboardField`) per
segment, using that segment's `tree_mix`/`spawn_bush_mesh` — this part is a direct,
low-risk reuse of the existing per-region foliage split (`world.gd`'s existing
`tree_mix` handling, see [regions.md](regions.md) → "Tree species split"), just fed
scatter points already filtered by arc-length range per segment instead of running
once over the whole floor.

### Camera choreography and the border-safety rule

- Shots are anchored to **fixed points/segments of the centerline**, not to a moving
  target — the opposite of `ReplayCamera`, which always tracks a car. Reasonable
  starting shot set per segment (mirroring `ReplayCamera`'s variety): a slow orbit
  over a scenic bend, a high wide establishing shot, a low ground-level flyby along a
  straight. `ReplayCamera`'s constant-subject-size FOV trick doesn't apply here (no
  single small subject) but its dwell/`_advance_shot()`/deterministic-`_tick`
  structure is worth copying wholesale for consistency and testability
  (`tests/headless/test_replay_camera.gd` is the template for a
  `test_menu_showcase_camera.gd`).
- **Border margin**: define a constant safety margin (e.g. `BORDER_MARGIN_M`) and
  restrict every shot's frustum/position to stay that far from each segment's start
  and end arc-length — enough that neither the seam nor the next region's differently
  textured ground/sky is ever visible at the edge of frame. Where a shot is wide
  (the "high wide" establishing shot), its position must be picked so its *view
  distance* at that FOV doesn't reach the neighbouring segment's ground, not just its
  own position.
- Shot list should cover all six segments in rotation, e.g. `[home shot A, home shot
  B, home_coast shot A, greece shot A, ...]`, cycling continuously while the menu is
  up.

### Hosting

`hub.tscn` is a bare `Control` with no `Viewport`/3D content today
([menus.md](menus.md) confirms it's "deliberately just a full-rect Control"). No
`SubViewport`/`Sprite3D` compositing (`WorldPanel`'s trick, see
[world-panel.md](world-panel.md)) is needed here — that mechanism exists for
embedding 2D UI *into* a 3D scene at an angle. This is the reverse and simpler:
`Node3D` content and `CanvasItem` content coexist natively in one `Viewport`, with
2D always compositing over 3D — so `MenuShowcase` can simply be instantiated as a
plain child/sibling in `hub.tscn`, with its `MenuShowcaseCamera.current = true`, and
`HubShell`'s existing UI just draws on top with no changes to it at all.

## Open questions for the user (before implementation starts)

1. **Full `TerrainManager` or a stripped-down ground?** `TerrainManager` is a large,
   chunked LOD system built for a moving car (`chunk_coord_for`, streaming chunks
   around a followed position). A static camera flying a small fixed loop may not
   need chunk streaming at all — a single pre-baked static mesh per segment could be
   far cheaper and simpler, at the cost of not reusing the terrain carve/noise
   pipeline. Worth prototyping both before committing.
2. **Any car/vehicle in shot for scale**, or pure empty scenery? The ask as phrased
   ("showing off the landscape") reads as scenery-only; a driven or kinematically
   posed car (`car.gd`'s existing `kinematic_pose` mode, built for the rival ghost —
   [event-replay.md](event-replay.md) → "A second consumer") could add life for
   free if wanted later, but is out of scope for a first pass unless asked for.
3. **Weather/time-of-day**: static (always clear, daytime) for a first pass, or does
   it need to vary?
4. **Mobile budget**: what frame/quality cap is acceptable for a screen that is *only*
   ever a background — should it degrade LOD further than an in-run stage would?
5. **Per-segment ground approach** (six materials vs. reviving the LUT) — see above.

## Suggested phased build (once the open questions are answered)

1. Prototype: one fixed-seed track, ONE region's look applied over the whole thing,
   a `MenuShowcaseCamera` with a couple of fixed shots cutting on a timer — prove the
   hosting-in-`hub.tscn` approach and the camera-choreography shape cheaply before
   spending effort on multi-region theming.
2. Slice into six segments, apply per-segment looks (ground + foliage), tune segment
   lengths so no camera position/FOV combination can see across a border.
3. Add the full shot rotation across all six segments + tests
   (`test_menu_showcase_camera.gd` mirroring `test_replay_camera.gd`'s deterministic
   `_tick` coverage; a smoke test in `test_smoke.gd` that the scene builds and the
   camera is `current`).
4. Wire into `hub_shell.gd`/`hub.tscn`, verify no regression to hub input/nav
   (`test_hub_shell.gd`, `test_menu_nav.gd`) and performance on the frame/quality
   budget decided above.
5. Update [hub-shell.md](hub-shell.md) and add a new `features/menu-showcase.md`
   (indexed in `features/README.md`) documenting the shipped mechanism, per CLAUDE.md's
   feature-docs rule.
