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

## Decisions (round 2, with the user)

1. **Full `TerrainManager`**, not a stripped-down static mesh — reuse the existing
   chunked/carve/noise pipeline as-is rather than building a second ground system.

   **Consequence this forces, found while checking the class**:
   `TerrainManager` already carries an ORPHANED per-chunk region-blend hook —
   `region_source` / `region_rank_at()` / `_apply_region_blend` (lines ~205-210,
   ~1131-1154) — the exact rank→LUT mechanism `regions.md` describes as the deleted
   `Overworld`'s "reusable half". It writes a blended rank into `UV2.y` per chunk
   corner for a ground shader's `blend_region` uniform, and is a no-op everywhere
   today (`region_source == null` on every stage) — nothing re-armed it since the
   overworld was deleted. **Decision 4 below (six separate materials, not the LUT)
   means this hook is deliberately NOT used** — do not wire `region_source` for this
   feature. Instead: **one `TerrainManager` instance per segment**, each covering
   only its own segment's chunk range and carrying its own single-region
   `chunk_material` (exactly like a normal stage's one `Floor.chunk_material`, just
   six of them side by side — see the cost correction under decision 4: this is not
   six times the terrain, just the same terrain split six ways). Each instance
   must be **pre-built to full readiness
   before the camera ever cuts to it** — decision 4 in the "already made" list above
   (no load-on-cut) applies just as much to terrain chunks as to anything else, so
   this is NOT the normal "stream chunks in as the camera/car approaches" mode
   `TerrainManager` runs in during a stage; all six instances' chunks in-shot range
   must be resident up front.
2. **No car** — pure scenery, no `kinematic_pose` work needed.
3. **Weather/time DOES vary** — this is new work beyond a first `home`-only
   prototype (see phase 1 below) and needs its own mini-design before it's built:
   candidates are (a) each segment authors a fixed weather/time look, so the
   variety comes from moving between segments (cheapest — reuses per-stage weather
   application once per segment, no runtime cycling logic), or (b) a global
   day/night and/or weather cycle running on a timer across the whole showcase
   independent of which segment is on screen (more dynamic, more moving parts:
   every segment's lighting must be re-derived live, and a weather transition
   mid-shot must not itself look like a cut). **Revisit which of these before
   building step 3 of the phased plan below** — it isn't decided yet, just that
   "vary it" beats "always clear daytime".
4. **Six separate materials**, not the LUT — see the `TerrainManager` consequence
   under decision 1. Simpler to reason about and debug.

   **Correction to an earlier draft of this doc**: splitting into six
   `TerrainManager` instances does **not** multiply the terrain cost the way an
   earlier pass here implied. The total resident chunk/geometry count is the same
   either way — one instance blending six regions' looks over N chunks, or six
   instances each owning a disjoint 1/6th of the same N chunks, is the same amount
   of terrain rendered, just split across objects instead of merged into one. The
   only real per-instance overhead is a handful of extra script/node objects and
   whatever fixed bookkeeping each `TerrainManager` does regardless of its owned
   chunk count (ring iteration, its own `region_source` check, etc.) — additive and
   small, not a 6x multiplier. This was in fact the whole point of the "one track,
   all regions resident" design per the user's own framing: avoiding
   load-on-cut, not avoiding rendering six regions' worth of terrain, which was
   always going to be rendered regardless of how many `TerrainManager` objects it's
   split across.
5. **Mobile budget: match the lowest in-run quality tier**, not a new dedicated
   tier and not "measure later". Reuse the existing per-target quality resolution
   `world.gd` already does before generation
   (`cfg.terrain_lod_bands_m = cfg.terrain_lod_bands_for(_web, _touch)`, consumed by
   `cfg.apply_terrain_lod(floor)`) — feed every `TerrainManager` instance whatever
   LOD bands that resolver returns for the lowest tier (mobile/web), regardless of
   the device actually running it, rather than resolving per-device the way a real
   stage does. The real cost driver is still six regions' worth of terrain resident
   at once (a real cost, independent of the instance-count question above) — this
   caps it at a known-affordable ceiling instead of the desktop tier. Revisit only
   if a profiled build later shows this is still too heavy even at that floor.

## Open questions still outstanding

1. **Weather/time mechanism** — per-segment fixed look vs. a global running cycle,
   per decision 3 above; needs picking before that piece is built.

## Suggested phased build (once the remaining open question is answered)

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
