# The Overworld HQ — a life-size drivable map

A **second hub** you drive rather than click. Instead of orbiting the map table and picking a
pin, the player drives their car across a life-size version of the same world map — the same
land, the same coast, the same regions in the same corners — and physically arrives at a rally
to enter it, or drives into the garage to work on the car.

The shipped map-table HQ (`hq.tscn`) is **not replaced or modified**. This is a second hub a
developer opts into.

**Tests:** `tests/headless/test_overworld.gd`, `tests/headless/test_overworld_garage.gd`, `tests/headless/test_overworld_route.gd`, `tests/headless/test_overworld_blocks.gd`, `tests/headless/test_overworld_fog_wall.gd`

Design doc: `docs/superpowers/specs/2026-08-17-overworld-hq-design.md` (read it for the
decisions D1–D10 and the slice ordering; this file describes what actually exists).

## The flag, and how to reach it

| Piece | Where |
|---|---|
| The gate | `GameConfig.overworld_enabled` — **ships `false`** |
| Which scene is "the hub" | `Scenes.hub_path()` (`scripts/scenes.gd`); `Scenes.is_hub_scene` for the music predicate |
| The boot redirect | `HqController._maybe_redirect_to_overworld` — after `_ensure_selection()`, after the benchmark check, and gated on `starter_picked` |
| The dev way in | Settings → Dev → **"Enter the Overworld HQ"** (`SettingsMenu._enter_overworld`) — flips the flag on the LIVE config only, so it is a one-session switch |
| The scene | `overworld.tscn` + `scripts/overworld.gd` (`class_name Overworld`) |

**Nothing changes when the flag is off.** `hub_path()` returns `res://hq.tscn`, the redirect
returns false before touching anything, and `overworld.tscn` is never loaded — so none of the
generation, cache or streaming cost below is ever paid.

## The scene

`main.tscn` minus everything stage-specific. `Floor` (a `TerrainManager`), `WorldEnvironment`,
`Car` (+ `BonnetCamera`), `ChaseCamera`, `CameraManager`, `PostProcess`, `FogVeil`,
`MobileControls`, `PauseMenu`.

Deliberately **absent**, each for a reason:

- **`StageManager`, start line, pacenotes, arches, signs, spectators** — there is no stage.
- **`TrackProgress`** — it teleports a far-off-road car back to the road within seconds, which
  in a roadless open world would fight the player constantly.
- **`HUD`** — a stage readout (elapsed, countdown, stage-complete) with nothing to read out.
  See "Not done yet".

`SpeedLines` **is** present (its own `CanvasLayer` + full-screen `ColorRect`, pointed at
`Car`, with a scene-local copy of `main.tscn`'s speed-lines material) — see "Visual effects".

The floor material, environment, sky and post-process sub-resources are **copies** of
`main.tscn`'s rather than shared with it, so nothing this scene tints can leak into a stage.
That is what makes the sky swap below safe: where `main.tscn` keeps a `PanoramaSkyMaterial`,
`overworld.tscn`'s `Sky` carries its OWN `ShaderMaterial` running
`shaders/overworld_sky.gdshader` (two panorama samplers + a blend weight), declared inline as a
`[sub_resource]` of this scene and referenced by nothing else in the project. Stages are
completely unaffected.

The panorama is still resolved **unconditionally** by `Overworld._apply_region_look` (via
`_sky_texture_for` / the static `sky_panorama_path`), for the same reason
`world.gd::_apply_region_look` does it: the material outlives any one region, so a conditional
assign lets one region's sky follow the player everywhere. A region authoring no `sky_panorama`
falls back to `GameConfig.default_sky_panorama`, and failing that to the texture the scene
ships with (captured once by `_capture_sky_baseline`, exactly as `_capture_ground_baseline`
does for the ground).

`Overworld._ready` follows `world.gd::_ready`'s order, and the order is load-bearing in the
same places: region look → floor material → deep snow → terrain seed/layers →
`apply_terrain_light` **before the first chunk build** → `apply_terrain_lod` → bounds + chunk
store → car fielding → `controls_locked` → precompute → `build_initial` → horizon → water →
foliage → the real FPS cap → pause arming.

### Every boot value is resolved in one preamble, before anything reads it

`_ready` opens with a contiguous block that resolves **`_headless`, `_cheap`, `_size_m`,
`_bounds` and `_hq_map_pos`** — and nothing may read them before it. This follows `world.gd`'s
house pattern (seat the config *before* anything reads it) rather than a boot value object.

An `OverworldBoot` value object — a `RefCounted` holding the resolved values, built at the top
of `_ready` and passed to every builder — was designed and **rejected**, for three reasons worth
keeping so nobody re-derives them. The preamble already buys the property the object would have
bought. `world.gd` sets the house precedent for exactly this problem and is *not* an object (it
resolves into the global `Config.data`), so adding one here would create a second idiom for one
problem. And `load_radius` could not come along: it lives on `TerrainManager`, is set in the
cheap branch and read at ~10 sites as `tm.load_radius`, so the object would either exclude it —
leaving open the very split it was meant to close — or reach into the terrain. Revisit only if a
second world ever wants to share resolved boot state; that case does not exist today.

`_hq_map_pos` is the one that earned the rule. It is profile-derived
(`RallyLibrary.hq_map_pos`), it feeds the road network and the garage pad, and both are folded
into the chunk cache key — so it cannot move while the world is alive. It used to be assigned
*below* the spawn resolve, and because `_default_spawn_map_pos` returns it and `return_pose_for`
offsets away from it, the launch spawn was computed against its declared default (the map
centre) while the garage and the whole road network were built beside the player's first-car
rally. The car spawned in the grass. Its only inputs are `Save.profile`, `_size_m` and
`Config.data`, so it belongs in the preamble.

The guard against that class of bug is **unset-by-construction**: `_size_m` declares `0.0`,
`_bounds` an empty `Rect2`, `_hq_map_pos` and `_spawn_face_target` `Vector2.INF`. A plausible
default (`_size_m` once declared `4000.0`, four times the shipped size) answers an early read
*successfully*, so the boot carries on with a coherent but wrong world instead of failing.
`size_m()` and `bounds()` are public, so they `assert` the sentinel is gone — the enforceable
version of "resolved once, then read-only", GDScript having no `final`.
`test_boot_values_are_unset_until_ready_resolves_them` pins the declarations;
`test_the_launch_spawn_uses_the_resolved_garage_position` is the ordering regression guard.

One ordering problem is **not** fixable this way: the spawn pose must resolve before the roads
exist (the region look is chosen from the spawn), so the road snap is a genuine second pass,
`_snap_spawn_pose_to_road`. That is a real data dependency, not an ordering slip.

The car is fielded from the profile's **selected** car through `Car.apply_owned` with **no
session active** — the shape Free Roam already uses (`Overworld._field_car`).

## Coordinates

`scripts/overworld.gd` is the single source of truth, and both directions are **static** so a
test can exercise the round trip with no scene:

```gdscript
Overworld.world_xz(map_pos, size_m)   # (map_pos - Vector2(0.5, 0.5)) * size_m, map_pos.y -> world z
Overworld.map_pos_of(world_pos, size_m)   # the exact inverse; Y ignored
Overworld.bounds_for(size_m)          # the world Rect2, centred on the origin
```

Instance accessors: `size_m()`, `bounds()`, `car_map_pos()`.

## The two borders — do not conflate them

| Border | What it is | Where | Changes over time? |
|---|---|---|---|
| **Coastline** | The fixed perimeter of the map | The map's outer edge | No |
| **Fog frontier** | The edge of what the player has revealed | A union of circles, anywhere inland | Yes — grows as rallies complete |

### Coastline

Owned by the terrain, not by this scene. `Overworld` calls
`TerrainManager.apply_overworld_bounds(cfg, rect)`, which seats the load radius, the per-frame
build budget, generate-on-miss, encoded-light capture and the taper in one call. The falloff
itself is `TerrainManager.taper_height`, applied **inside height generation** (see
`compute_chunk_data` → `_apply_edge_taper` and `_noise_height_at`) so the cached grid, the
`HeightMapShape3D` collision and the `height_at` query cannot disagree about where the ground
is at the shore. Past the bounds the inward distance clamps at zero, so the sea floor is a flat
shelf at full depth — the sea is the answer to "what stops the player driving out".

The water in it is `LakeField` (`Overworld._build_water`), whose plane already spans 10 km and
so covers the map many times over. **One** waterline for the whole plane, driven from the
same `track_water_level_m` the taper used — a per-region waterline here would leave the shore
either dry or drowned. `Car.set_water_query` is wired to it.

### Fog frontier

The lit test is `RallyLibrary.position_revealed(map_pos, profile)` — the **exact** predicate
that gates rally entry, so what looks lit and what is enterable can never disagree
(`Overworld.position_revealed`). The mask is the shared 64×64 R8 builder
`HqController.build_fog_mask(profile)`, which rasterises `RallyLibrary.lit_sources`.

Two halves:

- **Soft turn-back — implemented.** `Overworld._update_fog_boundary` darkens `FogVeil/Tint`
  and pushes the car back toward the last pose it held inside the frontier; only a car that
  has driven `FOG_HARD_MARGIN_M` beyond it is teleported, and then only onto ground it has
  actually stood on. Soft rather than a collider because the lit region is a union of circles
  and a scalloped invisible wall reads as a bug.
- **Unlit ground — implemented.** `Overworld._push_fog_uniforms` pushes the mask as the global
  shader parameters `ow_fog_mask` / `ow_fog_size_m` / `ow_fog_unlit` / `ow_fog_amount`, declared
  in `shaders/overworld_fog.gdshaderinc` and included by **both** ground shaders
  (`ps1_models`, `ps1_terrain_snow` — the Alps use the snow one, and the frontier must not vanish
  on snow), with the names registered in `project.godot`'s `[shader_globals]`.

  It **multiplies** the finished light term, unlike the headlight cone which adds to it: unexplored
  ground goes dark whatever is lighting it, so a player cannot drive up to the frontier and light
  it with their headlights.

  `ow_fog_amount` is the master switch and a bit-for-bit no-op at 0, which matters because global
  shader parameters **persist across scene changes** and every stage draws with these shaders.
  `Overworld._exit_tree` disarms it — deliberately **not** gated on headless, so the anti-leak
  path is the one a headless test can actually execute. Same leak class `HeadlightCone.reset()`
  exists to prevent.

  The mask is sampled at `world_xz / ow_fog_size_m + 0.5`, the exact inverse of
  `Overworld.world_xz`. If the two ever diverge the fog slides off the pins it is drawn around.

  `_exit_tree` disarms **`ow_fog_amount` and `ow_fog_size_m`** — the shader early-outs on *either*,
  so zeroing the size is a second, independent no-op guarantee for every other scene (a future
  shader that forgot the amount check still reads no fog). The **mask is deliberately left**: it is
  a `sampler2D` slot with no null-shaped value to write, and attempting one risks a runtime error on
  the way out for the sake of a few KB that nothing can sample once both scalars are off.

### The frontier wall — the WARNING, not the wall

`scripts/overworld_fog_wall.gd` (`OverworldFogWall`, built by `Overworld._build_fog_wall`) stands a
**translucent curtain on the frontier**, so the edge of where the player may go is something they
see coming rather than something they learn about by being shoved back from it.

**D4 still refuses a collider, and this does not change that.** The soft push stays the mechanism;
the curtain is only its warning. Nothing here has a collision shape and nothing here applies a
force — `_update_fog_boundary` remains the only thing that moves the car. The two are compatible
precisely because D4 rejected a *collider*, not a picture of where the boundary is. (That comment in
`overworld.gd` now says so, so the next reader does not "restore" the missing wall or delete the
visual as a violation.)

- **The look is the LIGHT TUBE's**, as asked: a vertical translucent band, solid at the base and
  fading out with height, with the fade baked into **vertex colours** on the same curve. It reads
  `OverworldZone.TUBE_FADE_POW` and `TUBE_RINGS` from the tube itself rather than re-authoring a
  second fade, so the two cannot drift into two different visual languages. Material choices are the
  tube's too: unshaded, alpha-blended, double-sided, shadowless, no depth write.
- **Geometry, not a shader curtain** — and this was weighed. A terrain *fragment* shader can only
  paint the **ground**: it has nothing standing in the air to shade, so a curtain needs geometry
  whatever draws it. The cheap shader-only alternative (a cylinder that follows the camera, made
  visible where it crosses the mask) puts the wall at a fixed distance from the car instead of at the
  frontier, which reads as a curtain chasing you. Tracing the union's rim instead costs a few
  thousand distance tests **on a progression event only**, and it leaves every stage shader
  untouched — which makes the "no-op in every other scene" guarantee **structural** (a node in this
  scene's tree, freed with it) rather than one more global uniform someone must remember to disarm.
- **The shape is the frontier's own.** `contour(sources, size_m)` walks each lit circle's rim and
  drops the arcs that fall inside another circle, yielding the same scalloped union the map draws.
  It is traced from `RallyLibrary.lit_sources` — the **same circles** the fog mask is rasterised from
  and `position_revealed` tests — so the wall cannot stand anywhere the player is not actually turned
  back. `static` and pure (circles in, world polylines out), which is how the tests assert
  "it stands on the boundary" as agreement with `position_lit_by` **without sampling a pixel**.
- **It grows with progression**, on the same `Save.profile_changed` hook the zones and the roadblocks
  use, so a completed rally pushes the frontier outward in the same session with no reload.
- **NO DISTANCE CULL** — and the absence is load-bearing. The arcs used to carry the shared
  `MeshUtil.apply_visibility_range`, which measures camera→node **origin**; an arc is anchored at its
  **centroid**, and a lone lit circle's arc is a closed loop whose centroid is the circle's *centre*.
  At the shipped numbers that is `map_reveal_radius × overworld_size_m` = 0.16 × 1000 = **160 m** from
  every point of the rim, against a `tree_render_distance_m` of **120 m** — so the ring drew while the
  player sat in the middle of their lit region and **vanished as they drove up to it**. Exactly
  inverted, and the cause of "the border disappears when you get close". A distance cull was never
  right here anyway: the wall's whole job is to read *before* the veil and the push-back explain it.
  Roadside clutter culls; a boundary does not. `test_overworld_fog_wall.gd` pins that no range is set.
- **One mesh PER ARC, not one map-wide surface.** Late in the game the frontier is tens of circles,
  which as a single surface is tens of thousands of alpha-blended, non-depth-writing triangles —
  overdraw mobile web cannot afford — and it could never be culled, because the shared
  render-distance cull measures camera→node **origin** and a map-spanning mesh's origin says nothing
  about where its geometry is. Split per arc and anchored at each arc's own **centroid**, the cull
  is exactly what the split buys: each arc has a **tight AABB**, so Godot's own **frustum** culling
  drops the ones behind the camera — which is where the saving actually comes from, and it is correct
  at any distance, unlike the origin-measured range cull above. A re-trace **replaces** the arcs: the
  frontier's shape changes when it grows, so last progression's arcs are wrong geometry, not
  reusable geometry.
- **Zero per-frame cost**: no `_process`, and nothing about it depends on where the camera is.
- **Its base is sunk `BASE_SINK_M` below the sampled ground.** The frontier is far from the car, so
  the height sample comes from `TerrainManager.height_at`'s scalar fallback (pad + taper, **no road
  carve**) — the same residency hazard the roadblocks document. On a 22 m curtain a few tens of
  centimetres of disagreement is invisible, but only if it errs *downward*: otherwise the base lifts
  and you can see under the wall.
- Tunables: `overworld_fog_wall_enabled`, `_height_m`, `_alpha`, `_color` — **black** at 0.4, so the
  edge of the world reads as the world *running out* rather than as a hazard stripe: it darkens what is
  behind it, which is the same thing crossing it does to the whole screen (`FOG_VEIL_ALPHA`). It was
  red, which said "danger" about ground that is merely unknown. One consequence to know: once the car
  *is* past the frontier the veil darkens everything, so a black wall reads as part of that darkening
  rather than as a separate object — acceptable, since by then the push-back is already explaining
  itself. Colour and alpha are pushed on
  every rebuild; the **height is baked into the vertices**, so retuning it shows on the next rebuild
  rather than instantly — unlike the tube's height, which rides a node scale. A curtain's base
  follows undulating terrain and so cannot.
- Headless: `visuals: false` traces the frontier and builds no mesh; `armed()`, `curtain_count()`,
  `contour_lines()` and `contour_length_m()` are the test seams
  (`tests/headless/test_overworld_fog_wall.gd`).

## The chunk cache and the first-launch precompute

- **Store:** `OverworldCache` (`scripts/overworld_cache.gd`), attached to the terrain through
  `TerrainManager.set_chunk_source` — a duck-typed `read`/`write`/`has` contract, so a store is
  always a pure speed-up and never a correctness dependency.
- **When it is attached** (`Overworld._open_chunk_cache`): the authored
  `overworld_cache_enabled` **and** `cfg.overworld_cache_active_for(is_web, is_touch)` (false on
  web — `user://` is IndexedDB there and its quota is shared with the profile), **and** not the cheap test path,
  **and** not headless. The test suite must never write tens of MB into the user data
  directory, and a cache failure must never touch the save (`Save.save_disabled` is a sticky
  global and is never written from here).
- **Key:** `OverworldCache.invalidation_key(cfg, tm.texture_tile_per_meter)`, combined in
  `_open_chunk_cache` with `_roads.network_hash()`, `_region_blend.stamp()` and `_pads.stamp()`. A
  mismatch wipes both files before the first write, as does a `FORMAT_VERSION` bump.
- **What a record holds:** quantised int16 heights, RGB8 baked light, and — new — the three
  **derived surface channels** as raw f32 (`road_weight`, `tarmac_weight`, `region_rank`, i.e.
  `COLOR.a` / `UV2.x` / `UV2.y`), appended as a trailing payload section behind
  `PAYLOAD_VERSION` 2 / `FORMAT_VERSION` 2. They exist so a **read** can skip
  `_apply_road_carve` and `_apply_region_blend` entirely: precomputing to disk had removed the
  height generation and nothing else, and the carve's per-vertex network query was making every
  chunk-boundary crossing a multi-frame spike with *nothing generating*. f32 and not a quantised
  byte because the cache's contract is an exact round trip — see
  [terrain.md](terrain.md) → "The stored surface channels". The section is optional in both
  directions, so a record without it (or with a mis-sized one) just recomputes as before.
- **Precompute** (`Overworld._precompute_map`): the first entry with a cache that does not
  already hold the map generates the chunks it needs in batches of `PRECOMPUTE_BATCH` per awaited
  frame, behind the `LoadingScreen`, reporting a **count** (`"Preparing the world… n / total"`)
  because it is long enough to need one. Wall-clock, the reads/generates/deferred split and MB
  are printed, never asserted (all derive from tunables).
- **PROGRESSIVE: it only bakes what the player can currently reach.** It used to bake the whole
  enumeration — ~900 coords at the shipped 1 km once the load-radius margin is counted — before
  the player could drive around their own garage, i.e. a long first-launch wait for ground that
  progression will not open for hours. Now each launch bakes the **reach set** and defers the
  rest to the launch that first brings them within it, which is a loading screen the player is
  already watching (returning from a rally is a scene load). No new trigger, no mid-drive
  generation — there is no thread to offload to.
  - **The reach set** is `Overworld.reach_sources` / `chunk_in_reach` (both `static` and pure, so
    the rule is testable with no scene): `RallyLibrary.lit_sources(profile)` — the SAME union of
    reveal circles the pins, the zones, the fog mask, the map's road filter and the roadblocks
    derive from — **dilated** by `reach_margin_map`, plus the **garage** and the **spawn** with a
    zero base radius (both are reachable without being lit: `map_hq_reveal_radius` ships at 0 and
    the garage is fog-EXEMPT, and a persisted return pose need not sit inside any circle).
  - **The dilation is a safety bound, not a fudge:** `FOG_HARD_MARGIN_M + (load_radius + 2) ×
    CHUNK_M`. The frontier is a **soft push** — a car beyond it is only teleported once it is
    `FOG_HARD_MARGIN_M` past the last lit pose — and the terrain then streams a `load_radius`
    ring around wherever the car is, all of which must already exist, because this project
    deliberately chose **loud holes over generate-on-miss**. The extra ring absorbs testing a
    chunk by its centre and any single-frame overshoot before the teleport check fires.
  - **The entry window is still prebaked into MEMORY every launch**, unconditionally and ahead of
    the reach test. That is a different cache answering a different question: `cache_chunk` is the
    only thing that fills the resident `_chunk_cache` with prebaked LOD meshes, and skipping it
    once already reintroduced the chunk-boundary hitch on the second launch.
  - **Growth only.** Reveal never shrinks, so the reach set only ever grows and the append-only
    disk cache needs no invalidation for this.
- **Batched index writes.** `OverworldCache.write` rewrites the WHOLE index per chunk, which is
  quadratic across a bulk pass — and progressive precompute means many smaller passes. The
  precompute now wraps its loop in `begin_batch()` / `end_batch()` with a `flush_index()` per
  awaited frame. The DATA record is still appended and flushed per chunk, so an interrupted batch
  loses only the *naming* of its last records — which reads as a miss and is regenerated, exactly
  the pre-existing crash semantics.
- **Resumability is free** and has no bookkeeping: the store is write-through and a missing
  chunk is simply regenerated, so we only skip coords the cache already `has()`. There is no
  resume state to corrupt.
- **Quantised at generation time.** `_write_chunk` snaps the generated grid with
  `OverworldCache.snap_heights` before writing, so a cache round trip is exact rather than
  approximate and the stored grid, the collision heightfield and the bilinear query are the
  same numbers.
- **Resident cache eviction.** `Overworld._process` calls `TerrainManager.evict_to_cap()` every
  `EVICT_INTERVAL` frames; the cap is **derived** from the load ring (there is no authored
  field — the design left it "TBD by measurement"). `evict_to_cap` independently guarantees it
  never frees a chunk whose node is live nor anything inside the built window.

## Look, region by region

`OverworldRegion` (`scripts/overworld_region.gd`) resolves the region **positionally** —
`region_at`, `look_at`, `water_level_at`, `surface_grip_at` — where `world.gd` resolves one
region for the whole stage. `Overworld._apply_region_look` sets the same fields
`world.gd::_apply_region_look` does (floor grass/gravel textures, sky panorama, tarmac colour,
ground tint, background + fog colour) and is re-checked every `REGION_INTERVAL` frames.

### Region blending

The three parts of a region's look transition differently, and deliberately so.

**The ground blends SPATIALLY, at the fixed region boundary.** Crossing a line must not restyle
ground the player can still see behind them, so the change is carried by the terrain data rather
than by a global material swap:

- **The bake.** `TerrainManager._apply_region_blend` (a grid post-pass in `compute_chunk_data`,
  after the road carve and the coastline taper, before the height quantum, and repeated in
  `_rehydrate_chunk_data` *only when the record carries no stored `UV2.y`* — the chunk cache now
  stores the baked rank, so the usual read splices it in and skips this pass) writes a
  **canonical region rank** into the otherwise-unused **`UV2.y`** of every vertex. It is a no-op without a `region_source`, which is every stage.
- **Why a rank, not a blend weight.** The shader can only cross-fade between the two region
  parameter sets actually uploaded, and which two those are follows the car — a pair-dependent
  value could never be cached. So each region id gets one fixed number in 0..1 (assigned by sorted
  id, `Overworld.RegionBlendSource`), and the baked field is those numbers interpolated by
  `OverworldRegion.region_weights_at`: a pure, continuous function of position.
- **The decode — TWO PATHS, and the split matters.** `ps1_models.gdshader` /
  `ps1_terrain_snow.gdshader` both gate on `blend_region`, which ships **false**; a stage never
  writes `UV2.y` and renders bit-for-bit as before.
  - **Colour (ground tint + tarmac) → the all-regions LUT.** `region_lut_look` walks fixed-length
    uniform arrays `region_rank[8]` / `region_tint[8]` / `region_tarmac[8]` (ascending rank,
    `region_count` entries in use), finds the two entries bracketing the baked rank and
    interpolates them with the same `region_blend_width` feather. So **every** region colours its
    own ground, however far away and whatever the car is near.
  - **Ground texture → the two-slot pair.** `region_blend_t` inverse-lerps the baked rank between
    `region_rank_a` / `region_rank_b` and cross-fades `albedo_texture` → `albedo_texture_b`. A
    texture sampler cannot live in a plain uniform array, so this stays a pair: a chunk belonging
    to some third region wears a *near* region's grass under its **own** tint. Accepted — tint
    carries almost all of the read at distance, and the two paths agree exactly at each region's
    own rank. The gravel sampler is *not* doubled either (the road is a thin ribbon).
- **The pair.** `Overworld._push_region_pair` uploads slot A = the region the car is in, slot B =
  the strongest *other* region there (the one it is approaching), via the pure static
  `Overworld.region_pair_of`. It runs on **every** region check, not only on a crossing, because B
  changes while the car is still inside A. With no second region it parks `region_rank_b` on
  `region_rank_a` — the texture factor goes to 0 while `blend_region` stays **true**, which is what
  keeps the LUT (and therefore distant ground's colours) live deep inside a region.
- **The LUT upload.** `Overworld._push_region_lut` runs **once** (it depends only on the roster's
  region set and each region's authored look), built by the pure static
  `Overworld.region_look_lut` from `RegionBlendSource.ids()` + `RegionLibrary.look_of`, falling
  back to `GameConfig.terrain_tint` / `tarmac_color` for a region that authors neither. The tail is
  padded with the last real entry (inert — ranks above the last clamp to it). `REGION_LUT_MAX` (8)
  must be bumped in `Overworld` **and** both shaders together if the roster outgrows it;
  `region_look_lut` pushes a warning rather than silently mis-colouring.
- **Three-region junctions.** Only the *texture* pair is affected now: the two strongest win (ties
  broken by region id, so the choice is deterministic and cannot oscillate) and a third region's
  grass comes from the nearer slot. Its **colours are correct** regardless — that was the
  "distant terrain shows the wrong region's colours when crossing a boundary" bug, and the LUT is
  the fix.
- **Cache.** The baked rank changes the stored bytes, so `_open_chunk_cache` folds
  `RegionBlendSource.stamp()` (the region id set + its ordering) into the invalidation key beside
  `OverworldRoads.network_hash()`. **This forces a one-time re-warm** of an existing chunk cache.
- **Tunables:** `overworld_region_blend_enabled` (part of the cache key) and
  `overworld_region_blend_width` (a pure shader remap — crisp line vs. gradient, free to change).

**The whole sky cross-fades over time** — background colour, fog colour AND the panorama, all
on ONE tween (`Overworld._fade_sky`, `overworld_region_fade_s`), so the haze and the sky can
never disagree. A distant haze genuinely does change as you travel. `_look_tween` is killed
before a new fade starts, and the whole thing no-ops under `_headless` (both slots are parked on
the incoming sky at weight 0, which is the same state a completed fade leaves behind).

**The panorama fade** rides `shaders/overworld_sky.gdshader`: two `sampler2D` panoramas
(`panorama_a`, `panorama_b`), a `sky_blend` weight in 0..1 and a `sky_energy` multiplier. It
samples both with `SKY_COORDS` — the engine's own equirectangular mapping, the same one Godot's
built-in panorama sky shader uses — so at `sky_blend = 0` it is pixel-identical to the
`PanoramaSkyMaterial` it replaced.

**The mid-fade crossing rule** (`Overworld.sky_fade_plan`, static and pure): two samplers cannot
hold three skies, so a crossing arriving mid-fade must overwrite one of the two live textures.
The incoming panorama goes into the slot that is currently **least visible** and the weight
sweeps towards it — at `blend <= 0.5` slot A dominates, so B takes the new sky and the weight
runs to 1; above 0.5 the roles mirror and it runs to 0. The weight therefore moves continuously
from wherever it already is rather than being reset to 0, and the visible step is capped at half
a unit of weight instead of the full unit a "collapse B into A and restart" would cost.

**The collapse is free.** Because the slots alternate, a finished fade leaves the weight exactly
on 1.0 or 0.0 and the destination slot simply IS the current region — no texture copy. Which
slot is on screen is derived from the weight (`Overworld.sky_live_slot`), never tracked in a
second variable that could drift.

## Foliage

Streamed per chunk rather than scattered once, because there is no stage to scatter along.
`OverworldScatter` (`scripts/overworld_scatter.gd`) is the chunk-local, disc-free driver —
`TreeScatter.scatter` returns nothing without a track's turn anchors, so the driver is new even
though the hashes carry over.

`Overworld._stream_foliage` fills a few chunks per frame inside a `_foliage_radius` ring
(budgeted by `overworld_chunk_build_budget`) and **frees a chunk's props when it leaves the
ring**, so a long drive cannot grow the prop count without bound. Per chunk
(`_scatter_chunk`): trees split by the region's `RegionLibrary.tree_mix` weights via
`OverworldScatter.species_groups` → `Foliage.spawn_trees`; bushes when
`RegionLibrary.spawns_bush_mesh`; and rocks at `RegionLibrary.rock_density`. Every pass gets
the **submerged-culling predicate**, so nothing grows in the sea the taper creates.

One judgement call: rocks spawn **one species per chunk**, picked deterministically from the
coord, rather than one field per species. The stage world affords three fields because it
builds them once; out here every chunk in the ring would pay for three. Variety comes from
neighbouring chunks drawing different species.

## The horizon

`distant_terrain_enabled` ships false and an open world needs a backdrop, so
`Overworld._build_horizon` builds `DistantTerrain.build_static` from the **explicit** map bounds
(`_bounds.grow(distant_terrain_radius_m)`) rather than `corridor_bounds()`, in its own yielded
load stage — it is hundreds of tiles and a synchronous height+light sample per vertex, so it must not
land inside one frame. Skipped in the cheap test path.

## The zone loop

The zone / dwell / marker / ghost-car layer is a **separate module**
(`scripts/overworld_zones.gd` and friends). `Overworld` talks to it through one clearly-marked,
duck-typed seam so this file never grows a parallel implementation:

- `Overworld._build_zones` loads the script if it exists, parents it, then calls
  **`setup(opts)` — one options dictionary**, not `(host, terrain, car)`. The keys it passes are
  `to_world` (a `Callable` wrapping `Overworld.world_xz`), `ground_at` (bound to the resolved
  `TerrainManager`), `car`, `car_scene` and `visuals`. The two `Callable`s matter: they keep
  `Overworld` the single source of truth for the coordinate mapping and the ground query, and the
  zone layer deliberately re-derives neither.
- `Overworld._update_zones` calls `update(delta)` once a frame, then ticks the garage zone.
- `Overworld._on_zone_activated(payload)` accepts either a rally id or a dictionary with
  `rally_id` / `kind`, and **opens the rally-detail card** — it does NOT start anything. See
  "Arriving opens the card" below.

**The manager is parented BEFORE `setup`,** because it builds its zone and marker nodes inside
`setup` and a `Node3D` outside the tree has no global transform for them to sit on.

### Arriving opens the card, it does not start the rally

Driving into a zone opens the **shared `RallyDetail` card** — the same panel the HQ map table
opens, which is why it was extracted into `scripts/rally_detail.gd` in the first place — and the
player starts the rally from there. The dwell is a *navigation* gesture; being thrown into a load
screen for arriving somewhere is what this fixes. (Straight-to-picker was always a stand-in; the
original brief said "the zone is activated and the rally details are shown".)

- **Hosted by `Overworld`** (`_build_rally_detail`), built ONCE and hidden, re-filled per zone by
  `fill()`. Built **last** of the overlays, and that is load-bearing: `_unhandled_input` is
  delivered from the last child up, so the card's nav sees Esc before the authored `PauseMenu`
  (Esc is bound to **both** `pause` and `menu_back`) and before the map.
- **Enter Rally — choose car** opens the **diegetic picker in place** (`_enter_rally_from_detail`
  → "Picking a car in place" below). It no longer leaves for `hq.tscn`. **D3's INTENT stands and
  its VENUE moved**: there is still a pick, because the car you drove here is not necessarily the
  car you want to race — it just happens in front of the car you parked instead of in the HQ car
  park. The card is HIDDEN, not closed, while the picker is up, so the dwell latch, the map veto
  and the control lock all stay exactly as they were and cancelling puts the same card back.
  No DEV win button out here (that callback is the HQ's cheat; `RallyDetail.build` takes an empty
  `Callable` to mean "build none").
- **Navigation:** `MenuNav.attach(page, {on_back, first = enter_button, grab = false})`.
  `MenuNav._enable` flips the card's deliberately `FOCUS_NONE` buttons to `FOCUS_ALL` for **this
  instance only**, so the HQ's copy (no nav, driven from `hq_table.gd`'s input handler) is
  untouched. `grab: false` plus MenuNav's `visibility_changed` re-grab is what avoids
  focus-death: the card is built while hidden, and a Control inside a hidden `CanvasLayer` still
  reports `is_visible_in_tree()`, so an un-deferred grab would yank the cursor off whatever is on
  screen.
- **BACK, while still parked inside the zone**, is the interesting case. The card closes, control
  returns, nothing starts — and the zone is **cancelled** (`OverworldZone.cancel_dwell`), not left
  latched. The latch alone (`_fired`) stops re-emitting only while the car stays put, so the card
  would re-open the moment the player nudged the car inside the circle; clearing the dwell instead
  would refill and re-fire a few seconds later with the player touching nothing. So cancelling
  **disarms** the zone, reusing the arm-on-exit rule: the tube drains (the cancel reads), and
  nothing can fire until the car has been seen **outside** the circle again. "Drive out and come
  back" is then the only way in, and it can never be permanent.
- **`controls_locked` has three owners in this hub** (the loading path, the full map, the card) and
  the garage releases it unconditionally, so `_lock_for_detail` records whether IT took the lock
  and releases only its own — the same discipline as `_on_map_toggled`. `_map_toggle_allowed`
  additionally vetoes **M while the card is up**: two modal screen claimers over one screen, and a
  map close would otherwise release the card's lock for it.
- **Already-open wins.** Zone circles can overlap and the car is stationary while the card is up,
  so a second zone completing underneath must not swap the card out from under the cursor.
- **A non-rally destination** (`kind == "garage"`, the reserved `GARAGE_ZONE_ID`, or an id the
  roster cannot resolve) keeps the old direct route rather than showing an empty card. Nothing
  reaches that today — the garage is a **building** and the zone layer only builds zones from
  roster entries — but the payload shape still admits it.

### What a zone looks like

`OverworldZone` is an `Area3D` at the rally's world position, and its whole state machine is
drivable headless: `tick(delta, car_pos, speed_kmh)` takes every input as an argument, so no
physics server, no viewport and no real car are needed, and `visuals: false` skips every mesh.
That is what keeps the zone tests scene-free and cheap.

The dwell requires speed below `overworld_zone_stop_kmh` sustained for
`overworld_zone_dwell_s`; **any movement zeroes the accumulator**, which is what lets the player
drive off to cancel.

The indicator is a **transparent light tube** standing on the zone (`_build_tube`), not a ground
ring — a ring vanishes to a line at the shallow angle you actually drive at, and the tube's
radius reads as the trigger radius from every direction, so what you see is what you must park
in. One `static` unit mesh (`_shared_tube_mesh`: radius 1, height 1, open both ends) is shared by
every zone and scaled per zone — X/Z by the live `radius()`, Y by
`overworld_zone_tube_height_m`. The sky-fade is baked into the mesh's **vertex colours** (alpha
1 at the base to 0 at the top, shaped by `TUBE_FADE_POW`) and multiplied through
`vertex_color_use_as_albedo`, which leaves `albedo_color` free as the single per-zone dial. The
material is unshaded, alpha-blended, double-sided, shadowless and does **not** write depth, so
the car, the terrain and the floating marker all stay visible through it.

Dwell progress reads on the tube itself (`_push_progress`, the only place that touches the
visuals, driven purely by `progress`):

- **Body** — the always-there column, `GREEN`.
- **Fill** — the same column scaled in Y to `fill_fraction()`, ramping `GREEN` → `GOLD` and
  `overworld_zone_tube_alpha` → `overworld_zone_tube_ready_alpha`. Its top edge is a **fill line
  with a readable position**, which a brightness ramp alone is not.
- **Band** — a thin bright ring riding that edge (`TUBE_BAND_FRACTION` / `TUBE_BAND_SWELL`), so
  the sweep is unmissable; it collapses at `DRAIN_RATE` when the dwell breaks.
- **Completion snap** — at `progress == 1.0` the whole column goes `GOLD` at the ready alpha and
  the band retires. A pure function of progress, so no timer and no change to `tick`.

`fill_fraction()`, `tube_radius()` and `tube_node()` expose this state for headless tests;
`tube_node()` is null when built with `visuals: false`.

Reveal is the shared predicate (`RallyLibrary.rally_revealed`), re-checked at the moment of
firing so a stale cache cannot open a dark zone.

**An unrevealed zone draws NO tube at all.** `_push_progress` sets `_tube_root.visible` from the
same reveal flag, so a dark zone is invisible rather than a dim olive column. The tube is the one
thing about a zone that is legible from kilometres away, so drawing one for a dark rally
advertised a destination the player cannot enter — the complaint that produced this rule was
literally "the distant light tubes look like you can go somewhere". It also makes the tube agree
with the marker, which `OverworldZones._refresh_markers` has always skipped for a dark zone, and
with the **roadblocks** below, which exist to say the opposite. The gate is *reveal*, not
*distance*: a revealed zone still shows its tube at any range, because that one is a real
destination and seeing it across the valley is how the player navigates to it.

`refresh_revealed` pushes the gate itself, so a rally that lights while the player is far away
grows its tube immediately — a far zone is never ticked. `OverworldZones` connects
`Save.profile_changed` to its own `refresh`, so this needs **no scene reload** (skipped when the
caller gated on a non-live profile, so a test's synthetic profile is not overruled).

## The garage — a building you drive into

`scripts/overworld_garage.gd` (`class_name OverworldGarage`). The garage is **not a menu you
teleport to**: it is a real structure standing on the terrain at `RallyLibrary.HQ_MAP_POS` with
two open bays, solid walls, and an opening you drive in through. Driving in seats the car on a
lift, raises it, and opens the tune / upgrade pages **in place**. Nothing changes scene, nothing
touches `hq.tscn`, and `RallySession.return_to_garage` is not involved.

### The seam

Built exactly like `OverworldZones` — parented first, then `setup(opts)`:

| key | meaning |
|---|---|
| `world_pos` | the garage's world point. Alternatively `to_world` (+ optional `map_pos`, default `HQ_MAP_POS`) and it converts — the overworld stays the single source of truth for the mapping. |
| `offset_xz` | world-XZ side-step from that point, applied **before** the ground probe so the building is seated where it stands. See "Standing off the road". |
| `ground_at` | `Callable(Vector3) -> float`. Seats the building on the terrain and settles the wheels on the lift deck. |
| `yaw` | radians. Which way the opening faces (0 = opens toward +Z, garage.gd's own convention). |
| `car` | the player car node. |
| `visuals` | `false` builds no meshes — the colliders are still built, because being a solid building is behaviour, not decoration. |

`update(delta)` once a frame (or `update_with(delta, car_pos, speed_kmh)` with the car's state
injected, which is how the whole path is tested headless). Signals: `entered()` / `exited()`.
Queries: `is_inside()`, `state()`, `page()`, `lift_height()`, `inside_bay(world_pos)`,
`ui_root()`.

### Standing off the road

The HQ pin is a road **junction** — `OverworldRoads` treats it as a node like any other, so edges
arrive at it from several bearings at once. A building centred on the pin therefore sits in the
middle of a crossroads: every road runs into a wall, and the bays are reachable only from
whichever direction happens to face the opening.

So the garage stands **off to the side of the road**, offset perpendicular to it and yawed to face
back at it, the way a real one does. The road then runs across the front of the bays and any
approach ends in one turn and a straight run into the opening.

The pose is derived from the road geometry — never a compass direction — by three pure statics on
`OverworldGarage`, fed by `OverworldRoads.approach_dirs(hq_index())` (the unit bearing each edge
*leaves* the node on, read off the polyline rather than the straight pin-to-pin line):

- **`road_side_dir(dirs)`** — the side to step to. A road is a *line*, not an arrow, so the
  bearings are averaged as **doubled angles** (the axial mean): a plain vector mean of a straight
  through-road cancels to zero and yields no axis at all. Of the two perpendiculars it takes the
  one pointing away from where the roads actually lean (the plain vector sum), so the building
  lands on the emptier side of the junction. A perfectly balanced junction — or no roads — falls
  through to a fixed tie-break rather than to noise.
- **`max_offset_m(pad_radius, bay_width, depth)`** — how far the door plane may stand from the pin
  before a **back corner** leaves the flat pad (`overworld_pad_garage_radius_m`, less
  `PAD_MARGIN_M`). The offset and the depth **share an axis** — the building is stepped sideways
  off the road and then turned to face back at it — so the worst point is a back corner at
  (±half-width, offset + depth), and the offset adds to the depth rather than to the width. Note
  the half-width is half of `total_width_m`, i.e. **two** bays plus the gaps (~8.25 m on the
  shipped numbers), not half a bay. A footprint whose corners already overrun the pad with the
  door plane on the pin answers 0 — no offset can rescue it, and the offset only ever pushes it
  further out.
- **`road_side_placement(...)` / `placement_from_config(dirs)`** — puts them together and returns
  `{ offset, yaw, dir, distance_m }`. `overworld_garage_road_offset_m` is a **wish**: it is clamped
  to `max_offset_m`, so raising it past what the pad can hold does nothing until the pad grows too.
  `Overworld._build_garage` passes `offset` / `yaw` straight into `setup`.

Every step is a pure function of the network, so the same pin field always yields the same pose —
which the terrain chunk cache's stamp depends on (`_roads.network_hash()` feeds the cache key).

> **Why the garage pad is 21 m.** The clamp keeps the back corners on the pad, and the footprint
> is 16.5 m wide × 12 m deep — its back corners are already ~14.6 m from the pin at zero offset.
> At the old 16 m pad radius that left ~1.7 m of side-step, i.e. the clamp cancelled almost the
> whole 8 m offset and the yaw was doing all the work. `overworld_pad_garage_radius_m` is 21 m so
> the authored `overworld_garage_road_offset_m` actually applies. Shrinking one without the other
> silently parks the garage back on the junction.

### Driving in, and driving out

Entry is **geometric, not an Area3D**: `inside_bay` tests the car's position in the garage's own
local space (inside the footprint, at least `ENTRY_INSET_M` past the door plane). That is what
lets the entire enter → lift → pages → exit loop run with no physics server.

Two rules keep it from being a trap:

- **Entering at speed does not grab the car.** The lift only takes it at or below
  `overworld_garage_enter_max_kmh`. The back wall is solid, so arriving fast can only *delay*
  the entry, never prevent it.
- **The arm latch.** Once you leave, the garage will not re-take the car until it has been seen
  OUTSIDE the bay again — the same arm-on-exit latch `OverworldZone` uses. So "reverse back out"
  is a clean exit rather than an instant re-entry, and `Drive Out` never fights the player.

### The lift

`enter()` locks the controls, `reset_to`s the car onto the pad facing **out** of the bay (so
leaving is driving forward, not a three-point turn in a closed room), then freezes it and raises
it over `overworld_garage_lift_time_s` to `overworld_garage_lift_height_m`. `leave()` runs it back
down and unlocks the controls at the bottom.

`reset_to` is the only teleport used, because a bare `global_transform` write is discarded by the
physics server unless it lands inside the step. The car is seated at `settled_ride_height()`
**above** the deck, not on it — seating the body origin on the deck buries the wheels half a
radius into it and leaves the body interpenetrating the ground the moment physics resumes.
`settle_wheels_to_ground` is called **only while the body is frozen**, which is its documented
precondition (the same trap `ghost_car.gd` falls into).

**The descent is LIVE.** `leave()` hands the car back to physics at the *top* of the descent
(`_hand_car_to_physics`), not at the bottom: `freeze` comes off immediately and only
`controls_locked` holds the player off until the platform is down. The lift used to carry a frozen
body all the way down and unfreeze it at the end, which dropped a live car into the world in a
single step with no solver history — the wheels were handed a contact to resolve from nothing and
one would punch through the ground on the way out. Two separate causes, both fixed:

- **Stale wheel visuals.** `settle_wheels_to_ground` translates each wheel `Visual` *down* by its
  droop, and nothing on the live path ever translates it back (`_update_visuals` only spins and
  steers). A released car rendered its wheels sunk by up to a full `wheel_rest_length` below where
  the solver actually had them — a tyre through the floor with the physics perfectly healthy.
  `Car.clear_wheel_visual_droop()` is the documented inverse and is the thing to call **whenever a
  settled prop becomes a driven car again**; the lift is the only place that transition happens.
- **The handover.** With the car live for the descent, gravity brings it down over the short lift
  travel with the wheel rays running, so each wheel catches the ground as it arrives.

While the car is live the lift stops writing its transform (that would overrule the solver every
step) and the **deck follows the car** rather than the clock: a falling car clears the travel in
roughly half the lift's scheduled time, so a clock-driven platform would visibly sink out from
under the wheels. The deck tracks the lower of the two, so it can descend early but never hang
above the car.

### The pages

`Page.HUB` / `TUNE` / `UPGRADES`, hosted on a `CanvasLayer` this node owns. The components are
the shipped ones, fed the same way `hq.gd`'s lift feeds them:

- `TuningPanel.setup(owned, Callable(), Callable())` — a no-op `on_change` is deliberate and
  copied from the HQ lift (a tune edit lands on the next fielding). Its `Reset` / `Wheels`
  buttons are built unparented and adopted into the page's action row; wheel swap is unwired
  here, so the button hides.
- `UpgradesGrid.setup(owned, on_change, Callable(), UpgradesGrid.NO_LIMIT)` — `NO_LIMIT` is
  explicit: the garage is not a commitment point, so no power-to-weight ceiling belongs here.
  `set_back_action` + `bind_close_button` give it Esc/B and its `< Back`.
- `on_change` re-reads `Save.get_car(Save.selected_instance_id())` and **refreshes the car** so a
  fitted part is visible — the HQ respawns a display prop, we `apply_owned` the player's real car
  in place and re-seat it on the lift.
- Repair is offered only when `Save.car_needs_repair`, priced by `Save.repair_price`, and
  disabled when `Save.stars_available()` is short — the same three questions `hq.gd` asks.

**Navigation is `MenuNav`, not the `hq.gd::_unhandled_input` pattern.** The HQ needs its own
handler because its stations are a 3D carousel that left/right drives; these pages are flat
widget lists, which is exactly `MenuNav.attach`'s case — it makes every row focusable (so the
D-pad, stick and arrows work natively), adds WASD, and routes Esc / gamepad-B to the page's back
action. Back is bound in one place (`_open_page`), so "no page is a dead end" is a property of a
single function: TUNE and UPGRADES back to HUB, HUB backs out of the garage.

Three rules that were paid for once and must not be undone:

- **Show the CanvasLayer BEFORE opening the page, not after.** Everything that places the
  cursor — `MenuNav`'s captured `first`, its "nothing focused" fallback, the grab itself — goes
  through `UITheme.is_focusable`, which requires `is_visible_in_tree()`. Build a page while its
  layer is still hidden and nothing resolves as focusable: `first` is null forever and the menu
  comes up with a dead cursor that not even a key press can revive.
- **`UITheme.enforce` after every page build** (`hq.gd` does the same as `_normalize_menus`).
  It is not only cosmetic: `UITheme.row_button` carries no minimum height, and a column of
  zero-height rows all resolves to the same rect, which stops `find_valid_focus_neighbor` from
  finding the row below — i.e. directional nav silently stops working.
- **Focus on open.** `_focus_page` grabs the first row the moment a page appears (immediately
  *and* deferred, both no-ops on anything invisible or dying), so a controller player is never
  shown a menu with no cursor. `_bind_nav` therefore attaches with `grab: false` and owns the
  "one MenuNav per page" rule; it re-attaches on each open only to refresh `first` after a
  rebuild (`UpgradesGrid.rebuild` replaces every tile; `TuningPanel` builds its sliders inside
  its first `setup`).

Config: `overworld_garage_bay_width_m`, `overworld_garage_bay_depth_m`,
`overworld_garage_enter_max_kmh`, `overworld_garage_lift_height_m`, `overworld_garage_lift_time_s`,
`overworld_garage_road_offset_m` (clamped by `overworld_pad_garage_radius_m`).

Tests: `tests/headless/test_overworld_garage.gd`.

### `always_revealed`, and why the garage needs it

`OverworldZone.always_revealed` exempts a zone from the fog gate. Exactly one thing sets it: the
**garage**, which is a destination rather than a roster entry — it has no id, no `map_pos` and no
reveal state, so `rally_revealed` would answer false for it forever and the player could never
reach their own garage.

It is also why the garage is built outside the zone manager, which only ever builds one zone per
ROSTER entry: the garage is not in the roster. It is no longer a zone at all — it is a BUILDING
you drive into, built by `Overworld._build_garage` (`OverworldGarage`), placed off the road axis
from `RallyLibrary.HQ_MAP_POS` (see "The garage — a building you drive into"). The map applies the
same exemption on its own side: `OverworldMap.setup` appends the garage as a destination with no
id, no `map_pos` and no reveal state, and `_is_revealed` short-circuits `Kind.GARAGE` to true.
Nothing in `scripts/` currently SETS `always_revealed` true — the flag survives on
`OverworldZone` as the mechanism, with the garage's exemption now expressed through those two
paths instead.

**This flag must never be used to open a dark rally.** It exists for destinations the roster does
not describe.

### Markers

A marker floats above each zone at `overworld_marker_height_m`. The icon is the life-size version
of the trichotomy `hq.gd::_make_pin` already draws:

| Rally kind | Marker | Source |
|---|---|---|
| Ordinary | Flag | `RallyFlag.build` |
| Car unlock | The car itself, as a frozen ghost on the ground (no floating card — the body *is* the marker) | `RallyLibrary.prize_car_id` + `CarProp.spawn` |
| Part unlock | The unlocked part's own icon | `UpgradeLibrary.unlocked_by(rally_id)` → that upgrade's `slot` → `UpgradeIcons.texture(slot)` |
| Special | Trophy | `RallyTrophy.build` |

#### Icons face the player; only the ghost cars turn

The icons used to rotate continuously (the original request). That was **superseded**: an icon and
a star count are *information*, and information you have to wait for the far side of a rotation to
read is worse than information that looks at you. So:

- **The 2D part card and the STAR LAYER billboard in their MATERIAL** — `BILLBOARD_FIXED_Y`,
  `billboard_keep_scale`. Free, no `_process`, correct at any camera angle. **Yaw-only** on
  purpose: full billboarding tips a floating row toward a camera looking down from a rise, which
  reads as wonky rather than as facing you. (It also retires the part card's documented wart of
  going edge-on and near-vanishing twice per turn.)
- **The 3D tokens (flag, trophy) are yawed by the manager**, not by the material: each of their
  sub-meshes would billboard about *its own* origin and the token would come apart.
  `OverworldZones._advance_spin` does one camera lookup per frame —
  `get_viewport().get_camera_3d()`, the **active** camera, since the hub has chase and bonnet
  cameras — and one `atan2` per LIVE marker (`OverworldZones.facing_yaw` → `Marker.face_camera`).
  Still **no `_process` on any marker**: that rule is what this file's per-frame pass exists to
  enforce, and the live set is a pooled handful inside the draw distance. No camera (headless)
  leaves the icons where they are.
- **The ghost cars still turn**, on the same single shared advancing yaw, and
  `overworld_marker_spin_deg_s` is now *their* tunable (its `GameConfig` doc says so). A parked
  prize car is a showroom turntable and carries no information to read. `Marker.apply_spin` now
  writes that yaw **only when a ghost is actually held**, rather than on every marker in the set.

#### The star layer

A **second layer stacked above the icon** showing how many of the rally's stars the player holds —
`RallyLibrary.MAX_STARS_PER_RALLY` **slots always**, the earned ones filled gold and the rest a
dark opaque olive. Earned-out-of-max, so a never-attempted rally is three empties (the degenerate
case of the same rule, not a special case) and the row reads as "N of 3 available here". The row's
size is therefore constant — nothing re-measures when a pooled marker is re-dressed.

- **Fill vs fill, not fill vs outline.** At 16 px on the horizon an outline disappears, so the
  distinction is a *value* contrast. (`UITheme.MUTED` ships at 55% alpha for panel use and washes
  out against sky; `StarRow` already has `unearned_color` for that class of surface.)
- **One quad, one composed texture**, cached statically per `(earned, total)` — at most
  `MAX_STARS_PER_RALLY + 1` of them for the whole session, built by blending
  **`StarRow.texture`** (which rasterises the shared `StarRow._star_points` geometry). That is
  exactly why that geometry is static: an icon star, a medal-row star and this world-space star
  cannot drift. Nothing here authors a second star shape.
- **Gated on REVEAL**, via the `locked` flag the manager already passes (`not zone.revealed()`) —
  the same predicate as the pins, the light tube, the roadblocks and the map's road filter. Stars
  on a rally the player has not found would leak precisely what the fog withholds. The gate is
  reveal, **not** eligibility: a revealed rally you own no car for still shows its stars, because
  that is a garage problem, not a progression one.
- **No new tunable.** Its height derives from the authored `overworld_marker_height_m` plus
  `ICON_SIZE_M`, so a float-height retune moves both layers; the star size and gap are shape
  constants beside `ICON_SIZE_M`, the convention this file already uses.
- Headless seams: `stars_shown()`, `star_slots()`, `stars_visible()`,
  `OverworldMarker.star_row_texture(earned, total)`.

Two details that are easy to get wrong:

- **A rally that unlocks nothing recognisable falls back to the FLAG, not to
  `UpgradeIcons`' generic tune fallback.** Otherwise every unmapped rally reads as a tuning
  event. `part_slot_of` returns `""` and `kind_of` never reports `PART`.
- **The ghost car is FROZEN.** `CarProp.spawn` is called with `freeze` at its default `true`,
  and the wheel visuals are drooped afterwards with `Car.settle_wheel_visuals` — a frozen prop's
  wheel solver never runs, so without that the wheels stay tucked up in the arches. Note
  `ghost_car.gd` spawns with `"freeze": false` because a replay writes its pose every frame;
  copying its flags here would break the settle precondition.
- **The ghost is lifted by `Car.settled_ride_height()`** (`overworld_zones.gd` → `_ghost_body`'s
  `configure`). `car.tscn`'s body ORIGIN is not the wheel contact plane — it sits roughly
  `wheel_radius + axle travel` above the ground a live car rests on — while the marker's origin
  *is* the zone's ground point, so a ghost seated at `Transform3D.IDENTITY` is buried up to its
  arches. Same seating `hq_carpark._seat_car_at_marker` uses for the parked lineup. Consequently
  `OverworldMarker.adopt_ghost` must **not** reset the body's transform: the lift lives there.
- **The droop is ANALYTIC, not ground-sampled.** `settle_wheels_to_ground` would raycast/sample
  under each wheel's *current* global position, but a ghost body is built parked in the cache
  holder and re-parented between zones, so it would bake in the wrong terrain. Every zone stands
  on a flat pad (see "Flat pads"), so the analytic rest plane is correct everywhere.
- **Facing is re-applied per zone on adoption** (`_assign_ghosts` writes `body.rotation.y =
  _ghost_yaw(zone)`), because one cached body is shared by every zone unlocking that model.

Cost is managed, because there are 38 rallies and a car prop is expensive enough that the HQ
caches its own (`hq._prize_car_props`): markers are pooled and granted only to zones that are
revealed **and** within `overworld_marker_draw_distance_m`; ghost bodies are cached per model and
capped at `overworld_ghost_car_max`, nearest first; and rotation is one shared yaw written onto
the live markers rather than a `_process` per marker.

Routing out of a zone:

| Zone | What happens |
|---|---|
| Rally | Opens the rally-detail card; its Enter opens the **in-hub car picker** ("Picking a car in place"), which starts the rally itself. Nothing leaves for `hq.tscn`, and `pending_rally_pick_id` is deliberately NOT set — that flag makes `hq.gd::_maybe_redirect_to_overworld` refuse to come back. |
| Garage | **Superseded by the drive-in garage below.** The garage is now a BUILDING you drive into (`OverworldGarage`), not a dwell zone and not a scene change; `enter_garage()` / `RallySession.return_to_garage` are no longer how you reach it. |

If a symbol the seam expects is missing, `_build_zones` / `_connect_zone_signal` `push_warning`
with a TODO naming it, and the overworld is still drivable — just with no destinations.

## Picking a car in place

`scripts/overworld_picker.gd` (`OverworldPicker`, built by `Overworld._build_picker`). The camera
swings to a three-quarter view **in front of the very car the player parked**, a menu opens over it,
and the car in front of them is **replaced as they browse**. The car never moves — it stays exactly
where they stopped, and the camera comes to it.

**Two modes, one picker**, so the diegetic look cannot drift between them:

| Mode | Candidates | Confirm |
|---|---|---|
| `RALLY` | owned cars that could ever enter this rally | `started` → the host starts the rally |
| `STARTER` | `CarLibrary.STARTER_MODEL_IDS`, on a profile that owns nothing | `granted` → the car is granted and becomes the hub car |

### The live car is NOT reshaped while browsing

This is the crux. `car.gd::respawn`'s own comment records that swapping cars by repeatedly
reshaping ONE body is what left cars "spinning in place with no traction" — a `VehicleBody3D`
accumulates stale wheel/suspension state when its wheels are relocated again and again, which is
why the tuning lift uses `_rederive_live_config` for a mere upgrade change. `Car.respawn` (a fresh
instance) is the sanctioned alternative, but in this hub a dozen things hold the car — both of
`CameraManager`'s cameras (one is a *child* of it), the zone manager, the map, the garage, the
surface/exhaust effects, `SpeedLines`, `TireMarks`, and 21 `$Car` lookups — so re-instantiating per
browse step is a re-pointing exercise, not a swap.

So **browsing shows a frozen `CarProp`** standing exactly where the real car is, with the real car
hidden behind it and frozen. The prop is the established recipe (the zone ghost cars, the HQ lineup
and the podium all use it), **cached per candidate** — keyed by owned *instance* (two instances of
one model differ in upgrades, tune and wheels) or by model id for a starter preview — so browsing
back and forth costs nothing after the first look.

**The real car is reshaped exactly once, and only on a starter grant** (`refield_live_car`), which
follows the tuning lift's recipe: unfreeze → `apply_owned` → re-seat → clear the wheel droop →
re-disable damage. The rally flow never reshapes it at all: confirming leaves for the stage scene,
which fields the chosen car itself.

### Seating: the contact plane, not the origin

Two car models rest at different heights (`wheel_radius`, axle travel), so re-using a body origin
sinks or floats the replacement. **What is preserved is the CONTACT PLANE under the wheels**,
computed per model from `settled_ride_height()` — for the stand-in prop and for a re-fielded live
car alike. The prop also keeps the car's own basis, so a car parked on a slope is replaced by one
leaning the same way rather than standing bolt upright in the hillside, and its wheel visuals are
drooped (`settle_wheel_visuals`) because a frozen prop's wheel solver never runs. A re-fielded live
car gets `clear_wheel_visual_droop` for the inverse reason, and goes through `reset_to` — the only
safe teleport. *(This project sank three props into the ground in one day for getting this wrong;
`test_overworld_picker.gd` pins the contact-plane property directly.)*

### Camera

**Pitched DOWN, so the car clears its own menu.** The bar is bottom-anchored, so the room in frame is
upward; `overworld_picker_camera_aim_drop_m` aims that many metres *below* the car's middle, which
pitches the shot down and pushes the subject up the frame. Done by moving the **aim**, not the eye:
raising the camera would frame more tarmac and shrink the car, while dropping the aim keeps the same
distance and the same size and just re-centres what is on screen. The colinearity guarantee below is
untouched by it — the drop moves the target along the car's Y, and the guarantee rests on the
standoff's component along its Z.

Its own `Camera3D` made `current` — the protocol `start_line.gd`'s reveal orbit established.
`CameraManager` never writes a transform (it only flips `current` when the player cycles), so an
override does not fight it, and `activate_current()` is the documented hand-back, which restores
**the mode the player chose** rather than assuming the chase camera. `showroom_pose` is `static` and
pure (car pose + a car-space offset + the ride height → the camera pose), so the framing is testable
with no camera, no car and no viewport. Tunables: `overworld_picker_camera_offset` (car space:
x right, y up from the ground, z ahead of the nose) and `overworld_picker_camera_fov`.

One rough edge handled: `CameraManager` still polls `cycle_camera` every frame and has no concept of
an override, so pressing **C** while the picker is open would hand the viewport to the chase camera
and leave the player looking at a hidden car. `update()` re-asserts `current` — two lines here
versus a gate in a shared file.

### Eligibility

`eligible_cars` is exactly the car park's `_can_ever_enter` filter, through the shared `RallyDetail`
decisions — `entry_plan(rally, car).eligible or convertible_for(...)`. One eligibility rule, never
re-derived. A car that can **never** enter (wrong body, country, doors) is **hidden**, as the car
park hides it; a car ineligible on **drive mode alone** is **shown** with the rally's own
`RallyLibrary.ineligibility_reason` sentence and a dead Confirm, because converting it is a garage
decision with a star price on screen. `confirm()` **re-checks** rather than trusting the disabled
button — the car park relied on the button alone.

### What the HQ's start path does that this replicates (and what it does not)

Replicated: re-resolve the owned car and the rally and abort if either is gone;
`Save.set_selected_car`; a loading cover plus **two** awaited frames (one is documented as not
enough for the cover to paint) before `RallySession.start_rally(rally, owned)`, the single start
entry point, which retires `pending_rally_pick_id` and settles the detune bookkeeping itself.

Deliberately **not** replicated: the car park's over-limit / "detune to enter" prompt (dead code —
`_detune_needed` is only ever cleared, and `register_detune_revert` has **no production caller**);
any upgrade auto-application or drivetrain auto-switch (an explicit non-goal there too); HP/repair
gating (advisory only); and `pending_rally_pick_id`. The one platform gate is handled differently:
a touch player who has never chosen a control scheme gets `MobileControls.DEFAULT_SCHEME` written
for them — exactly what the HQ's own flow settles on if that page is dismissed — rather than
rebuilding a whole settings-overlay stash-and-resume to ask a question with a known good default.

### The zone visuals come down while it is open

The player is parked **on** a rally zone when the picker opens — that is how it opens — so the zone's
light tube is a translucent column standing around the very car they are choosing, its marker and star
row float directly above it, and a car-unlock zone parks a full-size ghost car beside it. All of it is
between the camera and the subject, so `OverworldZones.set_visuals_hidden(true)` takes the lot down for
the duration, reached through an injected `hide_zones` hook so the picker never touches the hub's tree.

- **One `visible` flip on the manager node**, not a walk over 38 zones: O(1), it cannot miss a thing
  added later (the star layer arrived after the tubes), and — the load-bearing part — it **cannot fight
  the reveal gating**. Each tube's own `_tube_root.visible` carries whether its rally is revealed, and
  hiding an ancestor leaves that flag untouched, so restoring shows exactly the zones that were showing
  rather than lighting up a dark one. A per-zone walk would have to remember and undo the gate.
- **Visibility is not state.** `update_with` goes on ticking while hidden, so the dwell latch on the
  zone that opened the picker is exactly where it was.
- **Restored through `close()`**, the one funnel every non-confirming exit passes through — cancel, and
  the starter flow (whose host closes the picker itself, since it has no cancel of its own). Tracked
  with a `_zones_hidden` flag so a double open cannot leave the world's zones hidden for the session:
  the same take-only-your-own discipline as the car's freeze and the control lock.
- **Deliberately NOT hidden:** the roadblocks and the frontier wall. Neither is a rally zone, and
  neither stands where the car is parked (a roadblock sits at a frontier crossing, the wall on the edge
  of the revealed region). If a zone near the frontier ever puts the wall behind the car, it is one more
  line.

### The starter pick

A fresh profile owns nothing, so `_field_car` fields a **stand-in catalogue car** (`apply_car(0)`:
fully drivable, no instance id, no upgrades, no saved HP — none of which matters, since damage is off
in the hub) and `_maybe_open_starter_pick` opens the picker **immediately on boot**, after the boot
unlock. Not on first driving somewhere: a loaner would invite "whose car is this?", and every rally
they drove to would refuse them.

- **The grant goes through the shared seam**: `Save.grant_car(model_id)` builds the whole OwnedCar
  and persists it; the picker adds `starter_picked`, **`starter_model_id`** and
  `Save.set_selected_car`. `starter_model_id` is load-bearing, not bookkeeping —
  `RallyLibrary.lit_sources` lights the OPENING rally's circle from it, so a grant without it leaves
  a fresh player on a completely dark map.
- **No cancel.** A player cannot decline to own a car and drive off, so this mode installs **no back
  action at all** — which also leaves `menu_back`/`ui_cancel` unclaimed so **Esc still reaches the
  pause menu** and a player who genuinely wants out can quit. No dead Back button is offered either.
- **THE OPENING RALLY STARTS IMMEDIATELY**, as the old HQ does (`hq.gd::_confirm_starter`): a player
  who has just chosen their first car is dropped into the event that *awards* it rather than left parked
  in a hub with nothing behind them. `RallyLibrary.opening_rally_id_for(model_id)` names that rally —
  the same lookup `lit_sources` uses to light that corner from `starter_model_id`, which the grant
  wrote — and it goes through `_on_picker_started`, **the shared start path**, exactly as the HQ routes
  its opening run through `_proceed_with_start` rather than a private handoff. The picker is closed
  first even though the scene is about to be torn down: that restores the zone visuals, the camera and
  the car's freeze, so a blocked or failed scene change cannot leave the hub in showroom state.
- **The empty case is a real branch.** If no rally awards the model (a synthetic roster, or a content
  edit) the HQ falls back to its garage view; the hub's equivalent is simply **staying here**, which is
  already a place — the loaner becomes the car they just chose (`refield_live_car`, the only path that
  reshapes the live car in place) and they drive off to find a rally themselves.
  `CameraManager.refresh_bonnet_offset` is called there, because the bonnet camera hangs off a body
  whose dimensions just changed.
- `hq.tscn`'s own starter picker is **untouched and still shipping**: with `overworld_enabled` off,
  the HQ is the live game.

### Ordering and locks

`controls_locked` now has **four** owners in this hub (the loading path, the map, the card, the
picker) and the garage releases it unconditionally, so each owner records whether **it** took the
lock and releases only its own (`_lock_for_picker`, the same shape as `_lock_for_detail`). The rally
flow takes **no** lock — the card is already holding it. The starter flow takes it, and must open
**after** the boot unlock at the end of `_build_world`, or the loading path clears the lock one line
later and the picker records itself as the owner of a lock nobody holds. The picker applies the same
take-only-your-own discipline to `freeze`: a car the garage lift already froze is not unfrozen when
the picker closes.

### The bar, and its input model

**No title row.** It captioned a bar whose whole content is a car name, its stats and a Start
button — and cost a row of the frame the car wants. The two modes are told apart by the only words
that carry information: the confirm button reads `Start Rally >` or `Take This Car >`.

**Back on the LEFT, confirm on the RIGHT**, the order every other screen uses (the rally card's
footer is `< Map` then `Enter Rally`), so "back" is always the leftmost thing. The asymmetry survives
it: starter mode still offers **no** Back, so the confirm button is alone in a centred row rather than
beside a gap.

**A carousel along the bottom, not a list down the side.** One car at a time, chosen with
left/right — the shape the old menus use, mirrored from the car park's chevron nav row
(`hq.gd::_build_carpark_nav_row`) and the garage lift's selector: `<`, a centred name with its
position (`(1 OF 3)` — what tells the player there is more than one car at all), `>`, the stats line
under it, then the actions. Bottom-anchored, so the **car** is unobstructed; a list down the side of
a diegetic picker is a menu wearing a showroom's clothes. It reads the same way in STARTER mode, and
better: a fresh player has nothing to compare against, so one car with its numbers under it is
exactly the right amount of information.

Widgets come from `UITheme.row_button` (the shared one) rather than hand-rolled buttons, and the bar
is built ONCE — its shape never changes with the candidate set, unlike the row list, whose length
did (and whose count-only rebuild guard once left the previous rally's names on screen).

**Left/right CHANGE THE CAR — and this is why the bar has no `MenuNav`.** With a focus cursor,
`ui_left`/`ui_right` move the highlight between the two chevrons and the car stops changing: a pad
player presses right and nothing happens except a button lighting up. That is two competing selection
models on one screen, the trap the map cursor fell into. So every button in the bar stays
`FOCUS_NONE` (the chevrons are additionally `menu_nav_skip`ped, so a future nav attached above the
bar still cannot turn them into focus stops), nothing is consumed in the GUI focus phase, and the
picker's own `_unhandled_input` maps it directly:

| Input | Action |
|---|---|
| `ui_left` / `menu_left` (arrows, D-pad, stick, A) | previous car |
| `ui_right` / `menu_right` (arrows, D-pad, stick, D) | next car |
| `ui_accept` / `menu_select` (Enter, gamepad A) | confirm |
| `ui_cancel` / `menu_back` (Esc, gamepad B) | cancel — **rally mode only** |

This is the **second** of the two navigation regimes [menus.md](menus.md) documents (the
`hq.gd._unhandled_input` shape for a diegetic station), chosen deliberately over the `MenuNav` one.
The picker is the LAST child of the hub, and `_unhandled_input` is delivered from the last child up,
so it sees Esc before the authored `PauseMenu` (whose `pause` action is the same key).

**Cycling wraps** (`wrapi`), matching `hq.gd::_cycle_lift_car` — a carousel that stops dead at the
last car reads as broken, especially in a two-car garage. With **one** candidate the chevrons are
hidden *and* disabled (hq's own pair: hidden so the row reads as a plain nameplate, disabled so
neither a click nor a cursor can reach a button that is not on screen) and cycling is a no-op; the
centre label stays, so the bar still names the car.

### The stats line

**The existing car-select summary, not a second one.** `RallyDetail.car_stats_text(owned, entry)` —
drive layout | peak HP | kerb mass | condition, with a fitted nitrous named last — is the same string
the HQ's car-select overlay and tuning lift show. It was extracted out of `hq.gd::_car_stats_text`
into `RallyDetail` (the same move `restriction_text` had already made) so both hubs read one string;
a second copy is precisely the drift that cost this project a web-export fix when the garage forked
hq's repair button.

- **A car the player does not own yet has NO condition field.** A starter candidate (and any
  catalogue preview) carries no `hp` and no instance id: reading the missing key as 0 would print
  `WRECKED` for a brand-new car, and defaulting it to full would print a figure the grant is free to
  contradict. Health belongs to an owned *instance*, not to a model, so the field is **omitted** —
  the line is honest one field shorter, exactly as the nitrous suffix is already optional. For an
  owned car the output is byte-identical to what the HQ has always shown.
- **The ineligibility reason is a separate readout** and is never folded into the summary. A blocked
  player needs the numbers *and* the sentence saying why the car is out, and the sentence is the one
  they act on.

## Pause, and the return pose

**"Quit to HQ" from the overworld pause menu goes to `hq.tscn` at its GARAGE view** — the same
destination the garage zone uses. The overworld *is* the hub, so `Scenes.hub_path()` (which
`pause_menu.gd` calls) would reload this very scene.

`pause_menu.gd` is not this feature's file and exposes no "quit pressed" signal, so
`Overworld._track_pause_menu` redirects it by consent: **while the pause menu is open**,
`RallySession.return_to_garage` is raised; resuming clears it again, so an ordinary pause leaves
no trace. Quitting therefore lands in the hub rather than looping.

"Reset to track" has no track out here; `_on_reset_requested` puts the car back on its wheels at
the last ground it stood on inside the frontier.

**Where the car spawns (D8):** two cases, and only two — `Overworld._resolve_spawn_pose`.

* **Returning from a rally** -> that rally's pin. `RallySession.overworld_return_rally_id` is a
  one-shot set in `RallySession._reset_to_idle`, which every way a rally can end funnels through
  (finish, wreck and abandon alike). `_resolve_spawn_pose` reads and CLEARS it, so a later boot
  that is not a return falls through to the garage. `hq.gd` clears it too, alongside the other
  one-shots: a rally that ends while the overworld is disabled (or under `--headless`, where
  `Scenes.hub_path` forces the shipped HQ) would otherwise leave it set for the rest of the
  process and strand a later overworld entry at a long-finished rally.
* **Otherwise — a cold game start** -> the GARAGE (`RallyLibrary.HQ_MAP_POS`, see
  `_default_spawn_map_pos` for why the garage rather than a completed rally or the map centre).

The id is deliberately SESSION-scoped rather than saved to the profile, and that is what makes
"on game start, spawn at the HQ" fall out for free: a fresh process has no session state, so a
cold boot — including one following a crash mid-rally — reads `""` and goes home. An unknown or
stale id is treated as "not a return" rather than as an error, since the fallback is the garage,
which is always lit, on-road and safe.

This REPLACED a persisted `{x, z, yaw}` pose under a profile key. The rule above covers both
arrival routes, so the key had no remaining consumer and was removed rather than left writing
save state nothing read. A profile written by an older build may still carry the dead key;
`save_manager` ignores unknown keys, so it is inert.

Note a deviation from the D8 text, which said the player is parked OUTSIDE the zone facing away:
the spawn is AT the pin with an arbitrary heading, and re-entry is prevented by the zone's
arm-on-exit latch instead (`OverworldZone` will not fire until the car has left it once). The
practical consequence is that re-entering the rally you just finished means driving out of the
zone and back in.

## The cheap test path — read this before writing a test

A life-size overworld that a test instantiates fully is over the suite's ~5 minute budget by
construction. So the scene ships a cheap mode: a tiny world, no disk cache, no precompute, no
foliage, no horizon, no water, a 1-chunk load ring and no zones.

```gdscript
Overworld.load_mode = Overworld.LoadMode.CHEAP     # BEFORE instancing
var ow: Overworld = load("res://overworld.tscn").instantiate()
add_child(ow)                                      # _ready is synchronous under --headless
```

`LoadMode.AUTO` (the default) resolves to **CHEAP under `--headless`** and FULL otherwise, so
the whole suite gets the cheap path for free; a test only touches `load_mode` to opt a headless
run *into* full generation. `Overworld.cheap_size_m` sets the cheap world's edge length.
Every `await` in the build collapses to a no-op under headless (`_yield_frame`), exactly as
`world.gd`'s does, and `applied_fps_caps` records the cap intent without writing
`Engine.max_fps`. `world_ready` is emitted when the build finishes.

Because the coordinate functions are static, the map↔world round trip needs no scene at all.

## Roads

The map has a **road network between the rally pins**, because bare terrain gave the player
nothing to follow — the first play report was "spawned me in the middle of the forest and I have
no idea where the roads are".

`scripts/overworld_roads.gd` (`OverworldRoads`) owns the geometry. Its nodes are every rally's
`map_pos` plus the garage at `RallyLibrary.HQ_MAP_POS`, and its edges use **the same pairing rule
as `RallyLibrary.reveal_link_pairs`** — `dist(a,b) <= max(reveal_radius_of(a), reveal_radius_of(b))`
— so **the roads lead where progression leads**, along the same graph the HQ table already draws
dashed lines for. Two deliberate differences from that function:

- **The lit filter is dropped.** Roads are authored geography, not progress state; a road must
  not appear as the player explores, or the world rearranges itself behind them.
- **Connectivity is guaranteed, not assumed.** A union-find pass joins any separate components
  with shortest inter-component edges and `push_warning`s per edge it has to invent
  (`joins_added()`). On the shipped roster it adds none — the pin fit already leaves one
  component — so a warning means the fit and the road graph have drifted apart.

Redundant edges are pruned (drop A–B when a kept A–C–B is only marginally longer), which turns a
dense web into something that reads as a network. Edges are gently curved via Catmull-Rom through
seeded control points, **sine-tapered to zero at both ends so a polyline hits its pins exactly** —
that is what makes a road provably reach the zone rather than pass near it.

Besides the per-point carve queries (`road_at`, `distance_to_road_m`, `height_bias_at`,
`segments_in_rect`) the network answers two **node** questions, used by the garage to stand itself
beside the road rather than on it: `hq_index()` (the garage node) and
`approach_dirs(index, min_step_m)` — the unit world-XZ bearing each road *leaves* that node on,
read off the edge polyline so a curved edge reports where the tarmac actually heads. Both are pure.
See "Standing off the road".

### The carve is per chunk, NOT `bake_track`

`bake_track` is one global distance-field pass over a corridor from a single `Curve2D`, filling
map-wide per-cell dictionaries — sized for one track. The overworld is a network over hundreds of
chunks, and `free_load_only_data()` deliberately drops the bake fields after load, so any later
chunk would silently lose its flatten. So `TerrainManager` takes a duck-typed `road_source` and
carves per chunk (`set_road_source`, `_apply_road_carve`): heights flattened toward the roadbed,
`COLOR.a` = road weight, `UV2.x` = tarmac weight. Those are the channels
`shaders/ps1_models.gdshader` already cross-fades on, and `overworld.tscn` already sets
`blend_road = true` — so roads render with the existing gravel/tarmac look and **no shader
change**.

Two ordering rules, both load-bearing:

- It runs **inside generation, before quantisation and before the cache write**, so `heights`,
  the mesh vertices, the `HeightMapShape3D` and the cached bytes share one number.
- **The coastline taper runs after, and wins.** A road reaching the shore sinks into the sea
  rather than standing on an artificial causeway.

#### The allocation-free query pair

The carve's two queries both had a lean twin added, because both sit on the hottest path in the
whole open world:

- **`road_at_into(x, z, out)`** — the one place the point scan is actually implemented, filling a
  caller-owned 5-slot `Array` (`[road_weight, tarmac_weight, distance_m, foot.x, foot.y]`, indexed
  by the `PROBE_*` constants). `road_at` is now a thin Dictionary wrapper over it, so the two can
  never drift. `road_at` allocated a fresh 4-key Dictionary plus a `Vector2` **per vertex** —
  2,601 allocations per carved chunk — which was the single dominant cost of *rehydrating* a
  cached chunk. An out-param rather than a reused scratch field is a choice on merit, not on
  thread-safety (nothing in terrain generation is threaded): it carries no "read it immediately,
  never hold two results" hazard for the caller, and costs integer-indexed reads instead of a
  Dictionary's key hashing. A plain `Array` and not a `PackedFloat32Array` because Packed arrays
  are copy-on-write **values** in GDScript — writes inside the function would never reach the
  caller.
- **`has_segments_in_rect(rect)`** — the cheap per-chunk reject, stopping at the first hit. The
  carve only ever used `segments_in_rect(rect)` as an `is_empty()` test, and building the discarded
  Array of segment Dictionaries was waste on the *common* path (nearly every chunk of ~1,600 is
  road-free). Both share one scan, `_scan_rect`, so the predicate cannot drift from the list.

`surface_at` also routes through the network in a bounded world, so the tyre model gets real
gravel/tarmac grip on the road instead of one flat surface. It memoises on the contact point
because it is asked per wheel per tick.

The network hash is folded into the chunk cache's invalidation key
(`Overworld._open_chunk_cache`), so moving a pin re-warms the cache rather than leaving
yesterday's roads carved into it.

**Not verified:** that every road is *drivable*. The graph is connected and edges hit their pins,
but gradient (a car cannot climb much past ~22% FWD / ~33% RWD at snow grip), lakes and the edge
taper can each sever a road in practice. A drivability audit is the planned answer — see
`todo/overworld-hq.md`.

## Terrain noise — the hub has its own

The hub does NOT share the stages' `terrain_layer*` / `track_seed` height noise. Same generator
(`TerrainManager._make_noise`: PERLIN, `FRACTAL_NONE`, one noise per layer at
`frequency = 1 / wavelength_m`, summed as `noise(x, z) * amplitude_m`), different values, in
`GameConfig.overworld_terrain_*` and read via `GameConfig.overworld_terrain_layers()`.

Why separate: a stage is a narrow corridor a few hundred metres wide where big relief reads as
drama; the hub is a 1 km square the player crosses constantly, where the same relief becomes a
wall between two rally zones. The stage values put only three or four features across the whole
hub, and the amplitude fought the flat pads hard enough to leave undrivable lips coming off them
(measured with `tools/analyse_road_grades.gd`; see `features/testing.md`).

`overworld_terrain_seed` is separate from `track_seed` on purpose: `track_seed` still places the
hub's ROADS and SCATTER, so reshaping the ground does not relocate every road and tree, and
re-rolling the road layout does not force a full terrain rebake.

**Three consumers must agree, and all three are the hub's own values:**

| what | where |
| --- | --- |
| the live terrain | `Overworld._ready` (seeds `TerrainManager.noise_seed` / `layers`) |
| the disk cache's key | `OverworldCache.invalidation_key` |
| the grade analysis tool | `tools/analyse_road_grades.gd` -> `_terrain` |

Getting any one of them wrong is a silent failure rather than an error: key one world's ground on
another world's parameters and the cache serves heights nothing generated; point the tool at the
stage values and it measures a surface the player never drives (which has already happened once).
`test_overworld_cache.gd` pins both directions — the hub's fields invalidate, the stages' fields
do not.

## Flat pads under the zones and the garage

Every rally zone and the garage sit on a **level circle of ground** baked into the terrain, so a
zone's light tube, its floating marker and its parked ghost car — and above all the garage
**building**, which visibly broke on uneven ground — stand flat instead of straddling a slope.

`OverworldPads` (`scripts/overworld_pads.gd`) is the pad set: pure geometry and queries, one pad
per rally at its `map_pos` plus one for the garage at `RallyLibrary.HQ_MAP_POS`. It mirrors
`OverworldRoads`' shape exactly — `pads_in_rect(rect)` for a per-chunk reject, `pad_at(x, z)` for
the per-point weight, `influence_m()`, `stamp()` — and is consumed duck-typed through
`TerrainManager.set_pad_source`. `build()` takes `to_world` as a **Callable** so this file never
re-derives the coordinate mapping, and a `height_at` Callable that resolves each pad's **level**:
the terrain's own generated height at the pad centre, so a pad sits where the ground naturally is
rather than at an arbitrary altitude.

- **Both pads are circles.** The rally pad is `overworld_pad_zone_radius_m`; the garage pad is
  `overworld_pad_garage_radius_m` and is larger. The garage footprint is a rectangle
  (`overworld_garage_bay_width_m` × `overworld_garage_bay_depth_m`), but a circle circumscribing
  it needs no orientation — a rectangular pad would have to know which way the building faces,
  coupling the pad set to `overworld_garage.gd` — and keeps the per-vertex query one squared
  distance. The shipped radius is well beyond the ~7.1 m half-diagonal, so the approach is level
  too.
- **`pad_at` returns a `Vector2`** (weight, target height), not a Dictionary: it runs per vertex
  (2,601 per chunk), a `Vector2` lives inline in a `Variant` so the call allocates nothing, and it
  stays **stateless**, which a reused scratch dict could not be — `compute_chunk_data` runs on
  worker threads.
- **Each pad sizes its own feather.** `overworld_pad_feather_m` is the *minimum*; `_feather_for`
  samples a ring of the raw terrain around the pad and widens the band until the ramp's grade is
  under `overworld_pad_max_grade`, capped at `overworld_pad_max_feather_m`. A fixed band on uneven
  ground builds a lip the car cannot climb — on the very road that led the player in. So
  `feather_m()` is the authored minimum, `pad_feather(i)` is what pad *i* uses, and `influence_m()`
  reports the widest built band. See `features/terrain.md` → "Flat pads" for the maths.
- **A band may not grow into its neighbour.** `_neighbour_cap` limits each feather to half the
  clear gap to the nearest other pad (floored at the authored width), and `_shrink_to_fit` shrinks
  a crowded rally pad's disc when the cap refuses the width the grade needs — the garage pad is
  exempt, since `overworld_garage.gd` clamps the building against the *configured* radius. Both
  were derived from `tools/analyse_road_grades.gd`; see `features/terrain.md` → "Flat pads".
- **A pad's level is the mean over its footprint**, not the height at its centre point, so a pin
  on a bump does not stand proud of everything around it.
- **Overlapping pads:** the strongest weight wins, but the target height is a weight-biased blend
  (`Σ (w/(1−w))·level / Σ (w/(1−w))`). Taking the strongest pad's level outright puts a step where
  two influences cross; the divergence at `w → 1` keeps each pad's own interior level, so this is
  not the naive average that would tilt both.
- **Foliage is kept off.** `_scatter_chunk`'s `dry` predicate rejects any point with a non-zero
  pad weight, feather included, so there is no ring of trunks around the lip.
- **The cache key** folds in `pads.stamp()` beside the road and region stamps
  (`_open_chunk_cache`), because the flatten rewrites the cached *heights*. This forces a
  **one-time re-warm** of an existing chunk cache on the first launch after this change.

Where the roads meet a pad, see `features/terrain.md` → "Flat pads" — the junction is the
interesting part, because every pad centre *is* a road node.

## Wayfinding

**There is no compass strip any more.** `scripts/overworld_compass.gd` / `OverworldCompass` —
a bearing-and-distance tag row along the top band, whose x positions slid as the car turned — is
**deleted**. A bearing answers "which way is it", which is the wrong question out here: the
overworld's roads are a sparse graph through forest and water, so "900 m north-east" still leaves
the player guessing at every junction. Wayfinding is therefore entirely **map-shaped** now, in two
pieces:

- `scripts/overworld_map.gd` (`OverworldMap`) — the minimap and the full map, below. It took over
  the compass's top-band real estate as well as its job.
- `scripts/overworld_route.gd` (`OverworldRoute`) — the **sat-nav**, a route *along the roads*
  drawn on the map; see "The sat-nav route" below.

What survived the compass, and still holds of the map: it shows **only revealed destinations**
plus the garage — via the zone's `revealed()` or `RallyLibrary.rally_revealed`, never a lookalike
test — because the fog exists to withhold the shape of an unexplored roster. Kinds come from
`OverworldMarker.kind_of` (mirrored by `OverworldMap.Kind`), so a pin can never disagree with the
3D marker above the zone. `OverworldMap.destinations()` exposes the computed model for tests with
no renderer, and the minimap itself is a passive readout that takes no input — only the full map
has a cursor (see "The synthetic cursor").

### The minimap and the full map

`scripts/overworld_map.gd` (`OverworldMap`) is **one script with two presentations and one
drawing routine** (`_paint`). It exists because a bearing readout could never answer
**layout** — where the roads go, what is behind you, how close the coast is.

| | Minimap | Full map |
|---|---|---|
| Where | Always-on panel, **top centre** | Full-screen overlay |
| Opened by | — | `toggle_map` — **M** / gamepad **Back** (button 4) |
| Span | `overworld_minimap_zoom_m` metres | the whole `overworld_size_m` |
| Orientation | **camera-up** by default (`overworld_minimap_rotate_with_heading`) | always north-up |
| Names on pins | no | **exactly one** — the hovered pin, else the selected one |
| Hidden while | the full map is open, or `get_tree().paused` | — |
| Roads drawn | only edges with **both** endpoints revealed | same rule (both surfaces agree) |
| Pin icon size | `overworld_map_icon_px` | `overworld_map_icon_full_px` (larger) |

**The minimap points where the CAMERA points, not where the car does** (`_camera_forward`, read
off `get_viewport().get_camera_3d()` so it follows whichever of the chase/bonnet cameras is
active). The player reads the panel against the picture on screen, and that picture is the
camera's: with a drifting car a car-up panel swings away from the view exactly when the driver
needs it. The car's own facing is still drawn — by the arrow, which is now meaningfully
different from straight up. The redraw gate (`_moved_enough`) watches the VIEW heading for the
same reason.

**It hides while the tree is paused.** The layer watches `get_tree().paused` itself from a
`PROCESS_MODE_ALWAYS` `_process` rather than being told by `overworld.gd`, because the pause menu
is opened from more than one path and every extra caller is another place the panel can be left
floating over a modal. Nothing else runs while paused: everything that moves is driven by
`update()`, which the host stops calling.

**No border.** A hairline `draw_rect(..., filled = false)` used to frame it; with `clip_contents`
on, the stroke sits on the panel's own edges, so the left and top halves were clipped to nothing
while the right and bottom survived as a stray 1 px line. A frame that draws two of its four sides
is worse than none, and a border contradicts the panel's no-fill, no-fog "floats over the world"
design anyway.

**Top CENTRE, not top-left.** The panel is anchored `PRESET_CENTER_TOP` and sized
`overworld_minimap_size_px`, offset by `overworld_map_margin_px`. It used to sit top-left purely
to stay clear of the compass strip that owned the middle of the top band; with that strip gone the
centre is both free and the better spot — it is where the eye already is when looking down the
road, so glancing at it costs no head movement. The other claimants are unchanged:
`pause_menu.gd` parks its pause button at `PRESET_TOP_RIGHT`, and `mobile_controls.gd` owns the
bottom band on touch. Heading-up because a bend that reads as left *is* left — a **north
indicator** is drawn either way (`_draw_north`), so the rotating panel can still be correlated
with the north-up full map.

**Do NOT draw `textures/map_world.jpg` under either of them.** The overworld's ground is
procedural Perlin noise from `TerrainManager`; deriving land/sea from that image was a slice-4
aspiration that was never implemented, so its coastline and forests do not correspond to the
ground being driven on, and a map that disagrees with the world is worse than no map. Everything
drawn is ground truth: `OverworldRoads.edges()` polylines (filtered by the reveal gate below), revealed pins by
`OverworldMarker.kind_of`, the player's pose, `MapFog.build` (the same 64×64 mask the terrain
shader multiplies in) and `Overworld.bounds_for` for the coastline. If the terrain is ever
actually derived from that image, a photographic underlay becomes correct and welcome — the note
and the place for it are in `_paint_ground`.

**Pins are ICONS, not coloured dots** (`_paint_pins` → `_draw_glyph`). Shape says *what*, colour
says *state*, so the map can be read without opening it and without the names:

| Kind | Drawn as | Colour |
|---|---|---|
| part unlock | the **part's own `UpgradeIcons` texture**, via `OverworldMarker.part_texture` — the same art the upgrades grid tile and the floating 3D marker wear | `GOLD` |
| car unlock | **that car's own side profile**, traced from its body model — see "Car pin silhouettes" below (generic hatchback body + two wheel bumps when nothing is baked for the model) | `GOLD` |
| ordinary rally | a pennant on a pole, mirroring `RallyFlag` | `INK` |
| special | a trophy cup, mirroring `RallyTrophy` | `RED` |
| garage | a box under a pitched roof | `GREEN` |
| the player | an arrow (heading is half of "where am I"), now with an `INK` outline so it stays the most findable thing on a busier map | `GREEN` |

A rally that unlocks **nothing recognisable** must get the **pennant**, never `UpgradeIcons`'
generic TUNE-wrench fallback — that rule lives in `overworld_marker.gd` → `part_slot_of` (it
returns `""` rather than letting the fallback through) and the map obeys it by caching
`icon: null` on the entry. The kind itself is `OverworldMarker.kind_of`, borrowed whole, so a pin
and the marker above the zone can never disagree.

#### Car pin silhouettes

A car pin draws **the car being offered**, not a generic hatchback: `scripts/car_silhouettes.gd`
(`CarSilhouettes`) holds a side-profile outline per `CarLibrary` model id, and `_draw_glyph`'s
`Kind.CAR` arm asks for `convex_pieces(car_id)` — the `car_id` comes off the pin entry, cached in
`_entry_for_zone` / `_entry_for_rally` from `RallyLibrary.prize_car_id`. A kei van, a long low
coupe and a hot hatch are three visibly different shapes at 14 px.

- **The data is GENERATED and committed as source.** `tools/bake_car_silhouettes.gd` instantiates
  each body `.glb` (found by reading `car.tscn`'s instanced nodes, so the per-model 90 deg yaw and
  ride-height offset come from the scene rather than a hardcoded table), projects its triangles
  side-on into a small coverage mask, stamps that car's two wheels in as discs, traces the mask
  boundary (`BitMap.opaque_to_polygons`, the tracer `tree_silhouette.gd` also uses) and simplifies
  the loop to a few dozen points. Runs **headless** — mesh vertex data is CPU-side, so no GPU
  capture is involved. The game never runs it.
- **Regenerate with:**
  `Godot --headless --path . -s tools/bake_car_silhouettes.gd` (add `++dry` for ASCII previews and
  point counts without writing, `++res=` / `++epsilon=` to trade detail against point count).
  **Rebake when** a body `.glb` changes, a body is re-seated in `car.tscn`, a car is added, **or a
  car's `wheelbase` / `wheel_radius` is retuned** — the wheels are derived from those authored
  values, so an icon can otherwise go quietly stale. The baker self-checks: it rejects a traced
  loop that is not simple, and reloads its own output to prove it parses and decomposes.
- **Why an outline and not a rendered PNG:** it drops straight into the existing
  `draw_colored_polygon` path, stays recolourable (pins are tinted by *state*) and
  resolution-independent across the two map sizes, adds no binary assets, and bakes headlessly.
  A convex **hull** is not enough — it flattens the roofline and the wheel arches into one wedge,
  which is exactly the information that tells the cars apart.
- **Side-on, at true aspect.** Top-down collapses all nine cars to the same rounded rectangle and
  front-on to the same trapezoid. The outline is scaled so the **longer** axis spans the glyph box
  and the shorter one is centred inside it, so a car keeps its real proportions — a 0.46-tall
  muscle car and a 0.94-tall kei van differ by more than their rooflines.
- **Wheels twice, deliberately.** They are unioned into the traced outline (so `outline()` alone is
  the whole car, which is what `PolygonIcon` needs) *and* returned as `wheels()` centres +
  `wheel_radius()`, which the painter lays over the traced arches as `draw_circle` — a traced arch
  is a handful of jagged cells at icon size, a drawn circle is not.
- **The fallback is load-bearing.** Every accessor returns empty/zero for a model with no entry, so
  a car added before someone reruns the baker draws the old generic glyph rather than nothing.
  `""` (what every non-car pin passes) takes the same path.
- Concavity is handled once, not per frame: `convex_pieces` decomposes each outline into convex
  pieces on first use and caches them, matching the authored glyphs' zero-per-frame-allocation
  discipline. `tests/headless/test_car_silhouettes.gd` covers the contract (simple closed loops,
  consistent winding, in-box coordinates, convex pieces, the unknown-model fallback) without
  pinning any shape.

Icon size is in **screen pixels and does not scale with the map's zoom** — one painter serves a
~176 px panel and a full-screen overlay, so a world-space size would either make minimap pins
vanish or make full-map pins bloat. Hence the two separate tunables in the table above.

**Input (it IS a menu, so CLAUDE.md's nav rule applies in full).** `toggle_map` opens and closes
on keyboard *and* gamepad; `ui_cancel` / `menu_back` close; left/right/up/down on both the `ui_*`
family (arrows, D-pad, stick) and the `menu_*` family (WASD) **cycle the selected destination**,
wrapping, with its name and distance in the footer. It has no focusable widgets, so it uses the
`hq.gd::_unhandled_input` pattern rather than `MenuNav.attach`, but it still asks
`MenuNav.input_blocked(self)` and its root joins `MenuNav.SCREEN_CLAIMER_GROUP`.
`toggle_map` is deliberately **not** in `InputRemap.ACTIONS` (that list is the driving controls);
add a row there if it ever needs to be rebindable.

**Pointer input**, because touch is the only way to pick a destination on a phone (and see the
synthetic cursor below for the controller equivalent): mouse motion /
touch drag HOVERS the nearest pin within `overworld_map_pick_px`, and a click or tap SELECTS it
and sets the route. The hit test is `OverworldMap.nearest_pin_id` — **static**, taking its whole
view explicitly and inverting the same projection that drew the pins, so a headless test hit-tests
the real geometry with no pointer (`_full_rect` is captured by `_draw_full` for the live path
rather than recomputed, which is how a hit test drifts off the picture).

### The synthetic cursor (controller / arrow keys)

A controller has no pointer and the map is a **picture**, not a list of widgets, so a pad player had
nothing to aim with — only blind `select_step` cycling read off the footer. The cursor is that
pointer, and it is deliberately **synthetic**: its position goes through the SAME
`_pick_at` -> `_set_hover` -> `select_id` path as the mouse, so the pick radius, the one-name rule
and route-on-select cannot drift between input methods.

**One cursor, two ways to move it** (they always end with cursor, hover and selection agreeing):

| Input | Motion model | Effect |
|---|---|---|
| **Tap** a direction (arrows / WASD / D-pad) | discrete | `select_step(±1)` picks the next pin and the cursor **teleports onto it** (`_cursor_to_selection`) — one press is always one pin. Echoes are not consumed, so holding never machine-guns the roster |
| **Push** the stick (or hold a direction) | continuous, `overworld_map_cursor_px_s` | the cursor **glides**, polled from `Input.get_vector` in `_process` (an analog axis has no "pressed" moment) |

So `select_step` is **not replaced and does not compete**: it is now *one of the two ways to move the
cursor*, the discrete one. A tap gives guaranteed pin-to-pin progress; holding then glides on from
that pin.

**Assist / magnetism:** after every move the cursor hovers the nearest pin within
`overworld_map_pick_px` — **the same radius the mouse and the finger use**, not a second threshold to
retune — and the selection follows. Gliding *past* a pin picks it up, and `ui_accept` then routes to
it exactly as a click does; no pin is unselectable for want of pixel-perfect aim. Gliding over empty
map **keeps** the last selection, so `ui_accept` mid-glide is always safe.

**The garage participates in magnetism, deliberately.** It is a real, routable, always-revealed
destination, and the mouse can already click it — excluding it from the cursor would recreate exactly
the mouse/pad divergence the synthetic-pointer design exists to prevent, and would leave pad players
unable to route home. The "yanked to the garage crossing the middle of the map" worry is bounded by
the pick radius: passing *within* the radius of a pin is being over that pin, which is what aiming
there means, and the keep-the-last-selection rule only covers genuinely empty map.

**Pins can share a pixel, and then aiming is genuinely ambiguous.** `HQ_MAP_POS` hosts the garage,
and a rally authored at the same `map_pos` projects to the same point — `nearest_pin_id` resolves the
tie by last-equal-distance-wins, identically for the mouse and the cursor. This is not a defect (no
pointer can distinguish two pins at one pixel), but it means a TEST must never pick its target pin by
index: `test_overworld_map.gd`'s `_aimable_id` asks `pick_at` which pins resolve to themselves and
goes `pending` when none does. The fixture roster parks its lit seed rally exactly on the garage, so
this case is live, not hypothetical.

`move_cursor` / `place_cursor` are the only entry points (so a headless test exercises exactly what a
stick does), with `cursor_active()` / `cursor_pos()` as the readouts. The cursor is **armed** by
pad/key input and **disarmed** by real mouse motion (two crosshairs, one of them the OS's, is worse
than either) and by closing the map. It is **full-map only** — the minimap is a passive panel with no
selection — drawn last so it is never buried under the pin it sits on, as a **gapped crosshair** (the
pin shows through) that grows a green ring when magnetism has caught something. It cannot leave
`_view_rect()`, and the polling is gated on `_open`, so no stick is read for a cursor once the map is
shut (the car's controls are locked by the host meanwhile).

`full_map_rect()` is now the ONE source of the map's square for the painter, the pointer hit test and
the cursor's bounds — three consumers that must agree to the pixel, since two of them decide what the
third drew. It falls back to an injected `view_size` when there is no Control to measure, which is
what makes picking and the cursor testable headless.

Nav coverage lives in `test_overworld_map.gd` → "The synthetic cursor" (arm-on-key for four actions,
the gamepad equivalent via whatever button the project binds, magnetism, empty-map hold, the clamp,
mouse disarm, close disarm, and the aim-then-`ui_accept` route).

**Only ONE name is drawn on the full map** (`_named_id`): the hovered pin, falling back to the
selected one so a gamepad player still gets a name on the picture. Naming every pin turned a
revealed roster into a wall of overlapping capitals with the roads invisible underneath — the map
stopped answering the layout question that is its only reason to exist.

### Which roads the map paints

**A road is drawn only when BOTH of its endpoints are revealed** (`_refresh_road_visibility` /
`_road_end_open`, gating `_paint_roads` on both surfaces).

This is a **MAP-ONLY** rule. The road network is built and carved into the terrain
progress-independently on purpose, and that is unchanged: every road is still there in the world
and still drivable. Only the painted map withholds them.

The map was already hiding unrevealed **pins** (`_is_revealed`, justified by the fog existing to
withhold the shape of an unexplored roster) while drawing the roads that led to them — and a road
running off into the dark is a signpost to the pin at its far end: it gives away that there is
content there, how far, and in which direction, then invites the player to drive to a rally they
cannot enter yet.

**Both ends, not either.** An edge with one revealed end is dropped whole; a half-drawn road is the
same leak with a shorter line. This is deliberately the same rule as the HQ table's dotted reveal
links ("Both ends must already be REVEALED", [map-exploration.md](map-exploration.md)), so the two
hubs withhold the same shape, and it makes the drawn network **grow** with exploration.

Two exemptions, both narrow: the **garage** end (`__hq__`, the road graph's own node name — not
`GARAGE_ID`) never hides a road, matching its pin's fog exemption; and an **unresolvable** endpoint
(a duck-typed `roads` source with `edges()` but no `nodes()`) **fails open**, because an
unidentifiable network reverting to the old ungated behaviour beats silently blanking every road.

**The predicate is REVEAL, not entry eligibility.** `_has_eligible_car` / `RallyLibrary.is_eligible`
(rating band, car restriction) is a *garage* question whose answer changes when the player buys a
car — a road does not become undrivable because nothing in the garage qualifies, and
`overworld_zones.gd` already renders that state by **greying the marker** rather than removing it.
Endpoint node ids are captured once in `_capture_roads` (from `nodes()`, since `edges()` gives
indices) and the flags recomputed per `refresh()`; `road_count()` / `road_is_shown(i)` /
`road_ends(i)` expose it headless.

### Roadblocks — the world's half of the same rule

`scripts/overworld_blocks.gd` (`OverworldBlocks`, built by `Overworld._build_blocks`) is the
in-world counterpart of the map rule above. The map withholds a road into the dark; the terrain
still **carves and draws** it (that is deliberate and unchanged), so without this the map and the
windscreen contradict each other. Every blocked road therefore gets a short run of **precast
concrete jersey rail** laid **across the carriageway**, facing the driver.

- **Diegetic signage, not a seal.** The run spans the carriageway and nothing more; driving
  around it on the verge works, and that is accepted. Containment is the **fog frontier's soft
  turn-back** (`_update_fog_boundary`) and this file adds no second push, no invisible wall past
  the modules' own footprint and no teleport. Placing the run at the **frontier crossing** is
  what makes the two read as one mechanism — the barrier stands where the push begins.
- **The gate is the one predicate.** `blocked_edges()` builds `RallyLibrary.lit_sources` once and
  tests each graph node with `position_lit_by` — i.e. exactly `rally_revealed`, the predicate the
  pins, the zones, the fog mask and the map's road filter use. No lookalike distance test, and it
  never asks `overworld_map.gd` (the map is a view; the world must not depend on it).
- **Exactly one dark end.** Both lit means open; both dark means the road cannot be reached from
  lit ground at all, so it gets nothing (cheaper, and nobody would ever see it). The garage node
  (`__hq__`) is never dark, the same exemption `OverworldZone.always_revealed` carries.
- **Placement.** Walk the edge polyline from the lit end, find the first sample that is no longer
  lit (the frontier crossing), then step `FRONTIER_SETBACK_M` back **along the polyline** so the
  barrier stands on ground the player can see. Modules are spaced `barrier_section_length_m`
  apart across `roads.width_m() + 2 × SPAN_MARGIN_M`.
- **The frame: pin two axes, DERIVE the third.** `+X` is `BarrierSection`'s driver-facing axis and
  points back down the road at the approaching car, `+Y` is world up, and the run direction is
  `x × y`. Picking `+X` and `+Z` independently is what shipped every barrier **upside down** —
  the Y column came out pointing *down*, and since the model occupies `+Y` only (its AABB starts
  at `y = 0`) the whole block sat under the road. See [barriers.md](barriers.md) → "The frame".
- **ONE height for the whole run, sampled on the CENTRELINE** — not one per module. The carve
  levels the carriageway *across* its width to the ground height at the perpendicular **foot**
  (`TerrainManager._apply_road_carve`), so the road surface under the run *is* the centreline
  height; sampling each module at its own offset asks for the cross-slope the carve replaced and
  tilts the run into the road. It also sidesteps a **residency hazard**: `TerrainManager.height_at`
  falls back to the scalar noise path (pad + taper, **no road carve**) for a chunk that is not
  built yet, and these barriers stand on roads far from the car at world-build time, so they
  always hit that fallback. On the centreline the two pipelines agree by construction — the
  carve's own roadbed target is the ground height at that same point — so the number is the same
  either way. Cheaper, too: one sample per run instead of one per module.
- **Jersey, always.** A stage barrier picks armco vs. jersey from the tarmac weight because it is
  roadside furniture belonging to the road; a roadblock is *temporary works dropped across it*,
  and precast concrete blocks are what that looks like. See [barriers.md](barriers.md).
- **Removal without a reload.** `refresh(profile)` is a **diff**, not a rebuild: runs whose road
  just opened are freed, newly closed roads are built, the rest are untouched. `setup` connects
  `Save.profile_changed`, so completing a rally makes its barrier vanish in the same session.
- **Cost.** Everything is built once during the world build, off the road network — no
  `_process`, nothing per frame, and nothing hooked into terrain streaming, so a chunk crossing
  cannot spike on it. A whole run is one MultiMesh per barrier part plus one `StaticBody3D`
  (`BarrierField.build_modules`), culled at the shared world-prop render distance.
- **Collision** is the modules' own boxes (`ObstacleBody`), so bumping concrete feels like
  concrete. The body joins `DamageModel.OBSTACLE_GROUP` for consistency with every other
  `ObstacleBody`; damage is off in the hub (`_field_car`), so it costs the player nothing here.

Headless: `visuals: false` resolves the plan and builds no nodes. `blocked_edges()` /
`run_count()` / `run_for(i)` are the test seam (`tests/headless/test_overworld_blocks.gd`).

### The sat-nav route

`scripts/overworld_route.gd` (`OverworldRoute.plan`) turns a chosen destination into a **road
path** — Dijkstra over `OverworldRoads`' node/edge graph, stitched from the edges' own polylines,
with the car ATTACHED to the nearest point on the nearest edge (both endpoints seed the search)
so a car halfway down a road is never sent back to the junction behind it. It is drawn by
`_paint_route` on **both** maps, dark casing under a `GREEN` core, and its point is the MINIMAP:
the full map is where you choose, the minimap is where you follow.

`set_route(id)` / `clear_route()` / `route_id()` / `route_points()` / `route_length_m()` are the
model. The route is **re-planned on the ordinary refresh timer**, not trimmed, so it follows the
car and a missed turn re-routes by itself; the footer quotes `route_length_m` ("by road"), which
is the honest number a straight-line distance under-reads. The route is **still drawn where the
roads under it are withheld** — it leads only to a revealed destination the player explicitly
picked, and a sat-nav that vanished for the middle third of the drive would be worse than none.
A route whose destination stops being revealed is **dropped** (`_replan_route` calls
`clear_route()`), and `set_route` refuses an unrevealed id, so routing is gated by the SAME reveal
predicate as the pin, so the sat-nav can never draw a line into withheld content. `ui_accept` /
`menu_select` routes to the selection and cancels when pressed on the destination already routed
to. Covered by `tests/headless/test_overworld_route.gd` (synthetic networks) and the sat-nav block
in `test_overworld_map.gd`.

**Driving is gated by locking the car's controls, NOT by pausing the tree.**
`Overworld._on_map_toggled` sets `Car.controls_locked` (and releases it only if the map was the
thing that took the lock). Two reasons: `get_tree().paused` is owned by `pause_menu.gd`, and a
second owner means one clears the other's pause; and pausing would freeze this scene's chunk
streaming, foliage streaming and cache eviction — the world the player is reading the map to
drive into. It cannot fight the pause menu either: `Overworld._map_toggle_allowed` (the map's
`can_toggle` hook) vetoes while `PauseMenu.is_open()`, and Esc reaches this layer first, where it
closes the map and marks the event handled.

**Cost.** Road polylines are captured once in `setup` (already world XZ) with a per-edge AABB for
culling; drawing pushes ONE `draw_set_transform` and hands the raw point arrays to
`draw_polyline`, so nothing allocates per frame. The **pin glyphs** follow the same discipline:
their outlines are authored once as shared `static var` unit-space (`-1..1`, +y down) point arrays
and positioned by a single `draw_set_transform(p, 0, icon_px)` per pin, so no polygon is built per
pin per frame; a part pin's icon texture is resolved once in `setup` (it costs a reverse walk of
the upgrade catalogue) and cached as `icon` on the entry. `queue_redraw` is gated on the car having
actually moved or the VIEW having turned; the revealed set is rebuilt on `refresh()`
(`REFRESH_INTERVAL_S`), never per frame.

**The fog texture is rebuilt only when the lit set actually CHANGES** (`_fog_stamp`), and it is
updated IN PLACE (`ImageTexture.update`, never a fresh `create_from_image`). This is not an
optimisation — it is the fix for the **black/white flicker** on both maps. A `CanvasItem`'s
recorded draw commands hold a texture by RID and are not re-recorded until `queue_redraw`;
rebuilding the texture twice a second freed the RID the last frame drew with, and the renderer
substitutes its 1x1 **white** fallback, so the map's whole background flashed white until the next
redraw — which the movement gate withholds while the car is stopped, i.e. exactly while the full
map is open. Dropping the fog from the minimap earlier only hid the same bug on one of the two
views. Both hosts are explicitly re-drawn when the fog does change, since the movement gate cannot
know it moved.

**The full map's background is a constant BLACK**: an opaque backdrop (not `UITheme.MODAL_DIM`,
whose 4% leak showed the live overworld still streaming chunks behind it) and a black land plate.
Everything drawn on top carries the meaning; a ground that changes brightness makes the whole
picture read as flickering.

**Model vs drawing**, exactly as the compass splits them: `destinations()`, `selected()`,
`select_step()`, `select_id()`, `is_open()` and the static `project` / `unproject` /
`scale_px` / `heading_rotation` are all live under `visuals: false`, which is what
`tests/headless/test_overworld_map.gd` asserts against with no renderer. Only revealed
destinations are listed (the shared `rally_revealed` / `OverworldZone.revealed()` predicate,
never a lookalike) plus the garage, which is exempt for the same reason
`OverworldZone.always_revealed` exists.

**Two setup seams a test has to use together.** `setup(opts)` takes the pin roster from
`opts.rallies`, whose default is the shipped `RallyLibrary.RALLIES` **const** — which
`RallyLibrary.override_for_test` does not reach, since the override lives on the `_seam`
behind `RallyLibrary.all()`. Reveal, by contrast, goes through `rally_revealed`, which *does*
read the seam. So a test that installs a synthetic roster and does not also pass
`"rallies": RallyLibrary.all()` builds the map over shipped content while judging it against
fixture content, and no fixture id can ever be listed. In the game this never bites, because
`overworld.gd` passes `opts.zones` and the roster branch is skipped entirely.

**Nothing is lit for free.** HQ lights nothing (see
[map-exploration.md](map-exploration.md)), so a fresh profile over a synthetic roster reveals
*no* destination and `destinations()` returns only the garage. A map test that wants pins must
light them the way the game does — mark a rally completed in the live `Save.profile` — which
is what `test_overworld_map.gd`'s `_seed_rally` / `SEED_REVEAL_RADIUS` and
`test_overworld_zones.gd`'s `_complete` both do.

Tunables (all in `config/game_config.tres`): `overworld_minimap_size_px`,
`overworld_minimap_zoom_m`, `overworld_minimap_rotate_with_heading`, `overworld_minimap_alpha`,
`overworld_map_line_width_px`, `overworld_map_route_width_px` (the sat-nav line),
`overworld_map_pick_px` (the pointer/finger/magnetism hit radius),
`overworld_map_cursor_px_s` (the synthetic cursor's glide speed), `overworld_map_pin_px` (the player arrow's unit),
`overworld_map_icon_px`, `overworld_map_icon_full_px`, `overworld_map_fog_alpha`,
`overworld_map_margin_px`.

## Visual effects

The hub renders the same per-car effects a stage does. `Overworld._build_effects` (called from
`_build_world`, behind the loading cover) is the trimmed port of
`world.gd::_build_persistent_managers`; every effect self-gates on its own `GameConfig` flag,
so they are created unconditionally exactly as the stage creates them.

| Effect | Node | Notes |
| --- | --- | --- |
| `TireMarks` | child of the root | `setup(null, …)` — **ungated** mode, see [tire-marks.md](tire-marks.md) → *Ungated mode*. The road network is carved into the terrain's surface weights, so `surface_at()` alone decides where a mark lands. `tire_marks_enabled`. |
| `WheelParticles` | child of the root | `setup($Car)`. `wheel_particles_enabled`. |
| `ExhaustFlames` | child of the **root**, never the car (`setup` sets `_follow_car` and drives its own transform) | `exhaust_flames_enabled`. |
| `SpeedLines` | authored in `overworld.tscn` | `speed_lines_enabled` (the script hides itself when off). |

**The grass-spray overrides are re-issued per region.** A stage has one region and sets
`set_grass_color_override` / `set_grass_square_override` once at build; the hub's region changes
under the player, so `_apply_region_look` calls `_push_grass_overrides(look)` on every crossing
(and `_build_effects` pushes them once for the spawn region, since the first look is applied
before the pool exists). Keys: `grass_particle_color`, `grass_particle_square`.

**Shader pre-warm.** `_warm_effect_shaders` runs while the LoadingScreen is still up and does
what `world.gd` does: find every descendant implementing both `warm_up` and `clear_warm_up`,
call `warm_up(point)` (a point ~2 m in front of the active camera, `_warm_up_point`), await one
process frame, then `clear_warm_up()`. Without it the first skid or backfire pays a
gl_compatibility shader-compile hitch. Skipped under headless.

Deliberately **not** ported: `EngineSmoke` (triggered only by engine misfire, which needs
damage — and damage is off in the hub, so it would be permanently silent), `TrackProgress`,
`StageManager`, `ReplayRecorder`, opponent wrecks, and `RoadMarkings` (needs a per-polyline
loop over the road network — see "Not done yet").

## Not done yet

- **Zones, markers, ghost cars, the dwell tube and the detail panel** — a sibling module; this
  scene only hosts and routes them.
- **No HUD** — no speed readout (wayfinding itself is covered: the compass strip plus the
  minimap / full map above).
- **Road drivability is unaudited** — see "Roads".
- **No `RoadMarkings`** — the stage builds lane paint from one centerline; the hub would need a
  per-polyline loop over the road network. See "Visual effects".
- **Positional grip off the road** — `OverworldRegion.surface_grip_scratch_at` exists but nothing
  calls it yet; off-road grip is still the global scalar from `GameConfig`. (On-road grip *is*
  positional, via `surface_at`.)
- **Threading** — ruled out for now: the web build is single-threaded
  (`variant/thread_support=false`) and the chunk-data computation reads shared scratch on the
  `TerrainManager`, so a worker build is unsafe on every platform until each worker gets its
  own scratch.
- **`overworld_load_radius` / `overworld_chunk_build_budget` are provisional** — the design says
  to size them from a measurement on a real device, and that measurement has not been taken.
