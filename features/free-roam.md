# Free roam — streamed road-first island (prototype)

**Source:** `scripts/free_roam/free_roam.gd` (scene root), `scripts/free_roam/terrain_streamer.gd`
(`TerrainStreamer`), `scripts/free_roam/road_terrain.gd` (`RoadTerrain`),
`scripts/free_roam/road_network.gd` (`RoadNetwork`), `scripts/free_roam/auto_driver.gd` (`AutoDriver`), `scripts/free_roam/road_recovery.gd` (`RoadRecovery`), `scripts/free_roam/road_sites.gd` (`RoadSites`), `scripts/free_roam/road_barriers.gd` (`RoadBarriers`), `scripts/free_roam/biome_director.gd` (`BiomeDirector`), `scripts/free_roam/rest_stops.gd` (`RestStops`), `scripts/free_roam/region_banner.gd` (`RegionBanner`), `scripts/free_roam/rest_stop_page.gd` (`RestStopPage`), `scripts/free_roam/lab_noise.gd` (`LabNoise`), `scripts/free_roam/free_roam_settings.gd`
(`FreeRoamSettings`), `free_roam.tscn`

**Tests:** `tests/headless/test_free_roam.gd`, `tests/headless/test_free_roam_shell.gd`, `tests/headless/test_free_roam_biomes.gd`, `tests/headless/test_free_roam_rest_stops.gd`

The free-roam game (`todo/2026-10-19-free-roam-pivot.md`), entered from the title screen
(`title.tscn`). It's driven from the persistent world in the profile, which covers the seed, car,
pose, lit rest stops and map; see [world-session.md](world-session.md). The old hub and region
run are unreachable from the game. Drive with the usual controls; **R**
puts the car back on the nearest road. A label in the top-left shows the streaming stats.

**The game builds the same island as `tools/road_network_lab.html` for the same seed.**
`LabNoise` reproduces the lab's random stream (mulberry32), hash and value noise bit for bit,
and `RoadNetwork` / `RoadTerrain` follow the lab's growth, wiggle and height maths step by step,
holding coordinates in 64-bit floats (Vector2 is 32-bit). Checked on seed 1: identical
junctions and identical heights at 175 inland points. Two details keep it exact:
- a near-tie (within 1 nm) between road segments goes to the lower segment number in both,
  because two roads meeting at a junction are only equally near up to rounding;
- point counts use `ceil(x - 1e-9)`, so a length that divides exactly can't flip on
  last-digit rounding differences between the browser's `cos`/`sin` and Godot's.

This parity is **no longer a requirement**. From 2026-10-20 the game is the reference and
may diverge from the lab (decision 32 in `todo/2026-10-19-free-roam-pivot.md`). Until
something breaks it, the two still match: the lab's defaults (its "Radial growth, dead ends
pruned" algorithm) are `FreeRoamSettings`' defaults, checked on seed 5687 (same 49 nodes and
50 edges). Heights still differ in the last 400 m before the coast and at site pads, which
only the game has.

## The three layers

1. **`RoadNetwork` — the layout, built once at boot.** Radial growth from spawn: branches step
   outward, fork, and join existing road when they run into it (`_grow`). Dead ends no longer than
   `prune_dead_ends_m` (measured back to their junction) are then cut, repeatedly, so a fork
   whose branches all die out goes too (`_prune_dead_ends`). Each link then becomes
   a wiggled polyline (`_densify`, a seeded noise offset inside a band around the straight line,
   landing exactly on both ends; `road_twist` sets how far it may swing and `bend_length_m` how
often it turns). The polylines are flattened into segments in a 100 m grid, and
   everything downstream asks one question: `nearest(p, max_d)`, which leaves its answer in
   `hit_d` / `hit_q` / `hit_s` / `hit_edge` / `hit_side` / `hit_dir` so a query allocates nothing.
   `candidates_for` gathers, once per chunk, every segment that can be nearest for any point in
   the chunk, sorted nearest the chunk centre first, so per-sample queries (`nearest_in`) scan a
   short list. `nearest_in` skips a candidate without the full distance maths when even its
   nearest possible point (its distance from the segment's midpoint `seg_mx`/`seg_my`, less its
   half-length `seg_half`) is further than the best found so far; the margin keeps near-ties in, so
   the answer is the full scan's. Measured 2026-10-26: 16.6 → 5.0 µs per query, a height sample
   35 → 24 µs on a desktop (it was the biggest single cost of a sample).
2. **`RoadTerrain` — height built from the roads.** Same model as the lab
   (`tools/road_network_lab.html`):
   - **Base field:** low-frequency noise that ignores roads (`base_h`). It sets the roads' own
     height and decides lakes (`is_lake`: base below the water level), so the layout can avoid
     water before any terrain exists. It is lifted near spawn so spawn is always dry.
   - **Mountains:** ridged noise that rises only with distance from the nearest road, so roads
     sit in valleys.
   - **Ribbon:** a bank or drop beside each road, varying along it and per side.
   - **Coast:** the island fades to a sea floor below a noisy coastline.
   - **Bumps:** two octaves of Perlin noise (`LabNoise.perlin`, `bump_height_m` /
     `bump_scale_m`) over everything. The road takes the bump at its own centre line, so it
     rolls along its length but stays level across.
   - **Water never cuts a road.** The road (its base plus its bump, `_road_base`) stays at least
     3 m above the water. Lake ground near a road rises into a bank up to it, over
     `FreeRoamSettings.lake_road_bank_m` past the road's edge, and the coast's fade to the sea
     floor stops short of a road the same way. `test_free_roam.gd` →
     `test_every_road_stays_above_the_water_edge_to_edge`.

   Every query is a pure function of position, so any chunk can be built alone, in any order.
3. **`TerrainStreamer` — budgeted streaming.** See below.

## Streaming under a strict frame budget

> **Tried and undone (2026-10-26):** feeding the budget the main thread's measured idle time between frames (a phone browser reports no gpu time, so the budget sits at its floor there). On the phone it read high while loading, the bigger budget slowed the frames, and because the floor below is a share of the *actual* frame time the slow frames then kept the budget high: 22 fps instead of ~44. The phone is CPU-bound anyway, so there was little idle time to find.

`TerrainStreamer.budget_us(frame_s)` is the most terrain work any frame may do: `budget_fraction` of the frame time left over (`spare_us`, a smoothed estimate from the last frames' cpu/gpu load, fed by `free_roam.gd` → `_track_spare_time`), never below `budget_min_fraction` of the actual frame time (so time per second stays constant as fps drops), but that floor is capped at what it would be at `budget_floor_fps` (60): on a phone browser every frame is CPU-bound, and an uncapped floor that grows with slow frames slowed them further (measured 2026-10-26: 30 fps with an 8–11 ms budget). A chunk
(64 m) is built by a resumable `ChunkJob` moving through stages:

| Stage | Unit | How it stays inside the budget |
|---|---|---|
| `PREP` | gather road candidates | atomic, measured |
| `HEIGHTS` | one sample | stops before a sample that would not fit, judged by the decaying peak sample cost (`_peak_us`) |
| `ARRAYS` | vertex packing | clock checked every few vertices |
| `UPLOAD` | `ArrayMesh.add_surface_from_arrays` | atomic, measured per mesh size |
| `ATTACH` | create and add the `MeshInstance3D` | atomic, measured |
| `COLLIDE` | `HeightMapShape3D` + `StaticBody3D` | atomic, measured |
| `PLANT` | one candidate spot (water / road check) | decaying peak, like `HEIGHTS` |
| `SPAWN` | one foliage field, barrier run or site-marker batch | atomic, measured per species and size |

- **Sample-at-a-time stages** (heights, arrays, plant) time every unit and keep a decaying peak
  of its cost (`_peak_us`). They stop before a unit the peak says won't fit, and **a stage that
  stops short ends the frame** (`_step` returns false). Before 2026-10-20 it returned "carry
  on", and the queue spun on the same job until the deadline. That burned the whole budget and
  put most frames a microsecond over it.
- **Spawns are estimated per species and size** (`_spawn_kind`: `spawn_tree_32` etc.), not as
  one average, so a big tree field no longer overruns on a small field's estimate.
- **Atomic units** keep a moving average of their own cost (`_est`), and `_atomic` refuses to
  start one that would not fit in what is left of the frame. The first unit of a frame always
  runs, so a unit dearer than the whole budget still progresses and shows up as an overrun on
  the HUD rather than stalling the world.
- **Three levels of detail** (`TerrainStreamer.Level`), each chunk drawing only its finest built
  mesh (`_show_finest`):
  - **near**, `near_stride_m` (2 m), drawn in `near_tile_m` (32 m) **tiles** smaller than a chunk
    (`TileState`, in `_tiles`): only the 2×2 tiles round the tile corner nearest the car
    (`near_tiles_of`), so the car is always at least half a tile (16 m) inside them. Drawn and
    driven on, nothing planted. A tile is kept until its centre is `NEAR_KEEP_TILES` (1.6 tiles)
    from the car, so wavering on a tile's middle line doesn't rebuild it. Tiles halve the near
    work per metre against 64 m near chunks (it is two new near squares per square driven, so it
    scales with the square's side).
  - **Holes, not overlap:** a chunk's drawn coarse mesh (mid, else far) is rebuilt without the
    quarters its near tiles cover, with a skirt round each hole so no crack shows against the
    tile (`_cut_holes` / `_coarse_mesh`, from the vertex arrays kept on `ChunkState`). The two
    grids differ slightly in height, so drawing both in one place would flicker.
  - **mid**, `mid_stride_m` (8 m) within `mid_radius` (1.5 chunks, so it ends about where the 120 m foliage draw distance does): carries all the planting.
    It **narrows with speed** (`squashed_distance`): ahead it always reaches `mid_radius`, but to
    the sides and behind it shrinks towards `mid_side_frac` / `mid_back_frac` (0.6) of that by
    `mid_squash_speed_mps` (25 m/s), round again when stopped. What enters the band each second
    is its width across the direction of travel times the speed, so a narrower band is less to
    build, and a fast car can't turn into its sides in time.
  - **far**, `far_stride_m` (16 m) out to `far_radius` (6 chunks). Far chunks skip the one-sample
    border and take one-sided slopes at their edges.

  Why (2026-10-26, measured on an Android phone's web build): one height sample cost ~150 µs
  there (31 µs on a desktop), so a 2 m chunk was ~180 ms of noise maths, and with five of them
  per 64 m driven the queue grew all run long. The 2×2 near block needs two new 2 m chunks per
  64 m, and an 8 m mid chunk is 121 samples instead of 1,225.
- **Cheap paths that keep the lab match exact:** the hash multiplies are masked directly (the
  constants are below 2³¹, so nothing overflows), the hash is written out inside `vnoise`,
  points inside the closest possible coastline skip the coast noise, chunks beyond the
  furthest possible coastline are filled with sea floor without sampling, and the ring tint is
  sampled once per chunk.
- **Collision** covers the 2×2 chunks round the chunk corner nearest the car
  (`collision_block_of`; dropped past `NEAR_KEEP_CHUNKS`), so the car is always at least 32 m
  inside it, more than the near tiles give. It is built **per tile** (`_collide_tile`, recorded in
  `TileState.body_level`) from the finest grid there: the quarter of the chunk's mid grid first,
  rebuilt from the tile's near grid when that attaches. So the car always drives on what is drawn
  under it. The safety net (`_rush_collision`) works per tile too.
  `HeightMapShape3D` has unit cells, so the shape is scaled to the stride.
- **Planting waits behind collision.** A mid build stops once its mesh and collision are in
  (`_run_queue` runs it only up to `Stage.PLANT`), and goes back in the queue at
  `PLANT_PRIORITY` (after every chunk's collision and finer meshes, before far meshes) to plant
  its trees, bushes and rocks (`ChunkState.plant_job`, cancelled with the mid mesh). Until
  2026-10-20 a build ran straight on into its foliage, a few ms of spawns per chunk, while the
  next chunk's collision waited. At road speed the car outran its collision and **fell through
  the world** about 0.3–1.5 km out (the "drive out a bit" bug).
- **The safety net (`_guard_collision`, every frame before the queue):** if the chunk under the
  car, or the one it will be over in `collision_rush_s` (0.5 s), has no collision, it is built at
  once with no budget, only as far as the collision (`_rush_collision`; its foliage is left to
  the queue). Each one is a hitch of a few tens of ms instead of a fall, counted in
  `stat_rushes` (HUD readout and the auto driver's report). The 1 ms budget can't build a
  3-chunk-wide collision band at much over 100 km/h in a straight line (a 2 m chunk's heights
  alone were about 45 ms of work), so very fast driving leans on this net: probe on the default
  island, straight line at 144 km/h, one rush every 200–400 m; the auto driver on the roads
  (up to about 80 km/h) needed none in 4 km.
- **Fallen out of the world anyway:** `RoadRecovery.fell_out_of_world` puts the car back on the
  road as soon as it is `GameConfig.recovery_void_depth_m` below the ground, moving or not
  (the stuck rule waits for the car to stop, and a falling car never does).
- **Skirts** hang below every chunk edge, so mixed-detail neighbours never show a crack.
- **Planning (`_plan`)** runs when the car changes chunk, and every 0.25 s otherwise. It
  measures distance from both the car and where it will be in 1.5 s, and queues missing work in
  priority order (the table above `PLANT_PRIORITY`): collision (`d − 2000`), mid meshes that
  need collision (`d − 1000`), near meshes (`d − 200`), other mid meshes (`d − 100`), then
  planting (`d − 50`) and far meshes. A far mesh that would fill a **gap in the horizon** (its
  chunk has no finer mesh or mid build) sits at `d − 50 − far_lead_chunks` (`_far_priority`), so it interleaves with
  planting by distance: planting a chunk `d` away waits for horizon gaps nearer than
  `d + far_lead_chunks` (`FreeRoamSettings.far_lead_chunks`, default 3). A far mesh hidden under
  a finer one stays at `d`. Planting a chunk wholly past the foliage draw distance
  (`tree_render_distance_m`, from the car or where it will be) waits at `d + 1000`
  (`UNSEEN_PLANT_PRIORITY`, `_plant_priority`) behind everything: on a phone the mid band reaches
  past the 90 m foliage distance, and those trees were the dearest spawns in the queue. Before 2026-10-20 planting always beat far meshes,
  so at speed far jobs never ran and the horizon had gaps. Nothing in the plant / far tier can
  overtake a collision or a finer mesh.
- **Dropping:** a chunk sheds its near mesh past `NEAR_KEEP_CHUNKS` (`_drop_near`), its mid mesh,
  foliage and mid / plant jobs past `mid_radius + 1.5` (`_drop_mid`), and its collision and
  collision job with its near mesh (`_drop_collision`), whatever its distance; a far job past `far_radius + 1.5` is
  cancelled; a chunk past `far_radius + 2` (Chebyshev) goes whole (`_drop_chunk`). Until
  2026-10-20 the near / collision drops sat behind the horizon test, so after a medium jump (a
  respawn or travel of ~300–500 m, `prefill_at`) the old chunks just past the horizon kept their
  near mesh, foliage, collision and queued jobs at stale priorities, and `prefill_at` then built
  that stale work too, lengthening the travel hitch. Mid jobs in the hysteresis band (no longer
  wanted, not yet dropped) fall to the mid-mesh tier. Cancelled or finished jobs are purged from
  the queue at each plan (a queue that never drains used to carry them for ever).
- **Settings:** the shipped `FreeRoamSettings` is `GameConfig.free_roam` (a sub-resource in
  `game_config.tres`); production code reads `Config.data.free_roam`, and `free_roam.gd` hands the
  streamer a `duplicate()` since it sets `world_seed` (and the benchmark `straight_road_m`). The
  feedback timings (toast, banner, save / map cadence), dropped-money crystal, cabin lamp and rest
  stop crowd size are in its *Feedback* group. `GameConfig.snapshot_values` / `restore_values`
  deep-copy the resource.
- **Boot:** `prefill()` builds the planned set with no budget before the car is released (headless
  and tests). The game boots with `prefill_async()` instead: `_run_queue` slices of
  `prefill_slice_ms` with a frame between, behind the loading cover, car frozen and locked, and the
  hand-over / warm-up wait for it. Travel and respawn (`prefill_at`) are still synchronous.
  Every change into the world (`Scenes.change_to(FREE_ROAM)` — boot, new world, a rest-stop car/part
  change) first puts a `LoadingScreen` on the tree root, so the synchronous scene load and `_ready`'s
  prefill show the cover instead of a blank grey frame; `_warm_up` adopts that cover rather than
  making its own.
  Then `free_roam.gd._warm_up` compiles every first-use shader behind a `LoadingScreen` with the
  car's controls locked, the same passes as the stage's load (`world.gd._warm_shaders_behind_cover`):
  every `warm_up()`/`clear_warm_up()` node (debris, tyre marks, smoke, flames, crowds), a speck of
  every ring's ground material (`warm_up_materials`), one of every ring's trees plus a bush, every
  rock, a coin, a rest-stop cabin (without its collision box) (`warm_up_spawns`, on flat stand-in ground), and a
  throwaway camera turning full circle above the car and then looking down from high up
  (`_look_around`, the free-roam twin of the stage's corridor fly). Only then do the pause menu,
  the auto-driver or the title menu take over (`_hand_over`). Headless skips the warm-up.
- **Stats** (debug readout and the auto driver's report): overruns, the total overshoot, and
  **spikes** (frames over 1.5× budget), each broken down by the kind of unit that ran last.
- **Height queries** (`height_at`, used by the chase camera) are answered from the loaded
  chunk under the point, interpolated across the same two triangles per cell as the mesh,
  so they are cheap and match the drawn surface. Only unloaded ground falls back to the full
  terrain maths.
- **Road surface queries** (`surface_at`, four per physics tick from the car's wheels, plus one
  per spinning driven wheel from the wheel particles; ~1.5 µs each) read
  the distance to the road stored at every vertex of the finest loaded grid (`near_road_d`, else
  `mid_road_d`) the same way.
- **Road candidates** are gathered once per chunk (`ChunkState.cands`), with a margin wide
  enough for every stride, and shared by its builds at every level.

## Biomes

`RoadTerrain.ring_index` puts every point in a ring, counting outward from spawn with a noisy
border. Ring i wears region `FreeRoamSettings.ring_regions[i]` (`BiomeDirector.region_of`,
wrapping). By default that's home, greece, taiga, snow.

**Per chunk (`TerrainStreamer`):** each ring has its own copy of the ground material, carrying
the region's `grass_texture`, `gravel_texture` and `tarmac_color` (`_material_for`). Trees,
bushes and rocks follow the region at the chunk's centre (`tree_mix`, bush switch, rock
density), so they still switch at chunk edges.

**The ground fades across a border** over about `FreeRoamSettings.biome_fade_m` (the wobble
in the border stretches or squeezes it in places):
- Each border k (between rings k - 1 and k) has a pair material (`_pair_material`): ring
  k - 1's ground with ring k's textures and colours in the shader's `_b` uniforms, and
  `fade_rings` on. The shader (`ps1_models.gdshader`, `ring_coord_at`) works out every pixel's
  `RoadTerrain.ring_coord` itself, using the same integer hash as `LabNoise.vnoise`, and fades grass,
  gravel, tarmac colour and lane-paint colour across it. Change the two together.
- `_arrays` records each chunk's lowest and highest ring coordinate (`ring_lo` / `ring_hi`), and
  `_ground_material` gives the pair material only to chunks the fade reaches. Every other chunk
  keeps its single-ring material and pays nothing for the fade.
- The baked vertex tint (the region's `terrain_tint`, white when unset) fades over the same band
  (`ring_tint_at` / `_tint_at_ring`), so the bushes' baked light matches.
- `ring_materials()` includes the pair materials, so the weather tints both slots
  (`BiomeDirector.TINTED`) and the boot warm-up compiles them.
- `tools/biome_fade_capture.tscn` photographs a few borders from above, to check them by eye.

**Road paint is per pixel, not per vertex.** The near mesh is a 2 m grid (16 m far away), and the
road is only 3.8 m wide, so a per-vertex road weight (what the stage did on its 0.5 m grid)
draws the road's edge along the triangles: a zig-zag. Instead `TerrainStreamer._arrays` bakes
the *distance* to the road into each vertex, and the ground shader (`ps1_models.gdshader`, the
`paint_road_per_pixel` path that `_material_for` turns on) works out the weight per fragment:

| Channel | Carries |
| --- | --- |
| `UV.x` | distance to the road, signed by side (`RoadTerrain.last_road_sd`). Linear across the centreline, so it interpolates exactly over a triangle that straddles the road |
| `UV.y` | unsigned distance less a slack of 0.75 × the stride. The shader's distance is `max(abs(UV.x), UV.y)`: where the side flips between two roads (junctions, or midway between parallel roads) `UV.x` interpolates through a false zero and `UV.y` catches it; across a real centreline `UV.y` overshoots by less than the slack, so it never wins |
| `UV2.x` | tarmac weight (baked for every vertex within one triangle of painted road) |
| `UV2.y` | arc length along the road (`last_road_s`), for the dashes |
| `COLOR.a` | lane-marking weight (`last_road_mark`): 0 on rest-stop pads and within `marking_junction_clear_m` of a junction (`RoadNetwork.junction_gap`), fading in over 4 m |

With `UV` taken, the ground texture is placed from the world position (`ground_uv_per_m`,
which is `UV_PER_M`). The weight itself is `RoadTerrain.paint_weight` (the shader's uniforms
are `paint_mid_m` / `paint_half_m`): the road's own edge, faded over `road_paint_fade_m`. Grip
still reads the shoulder (`road_weight`, `surface_at`). `tools/road_paint_capture.tscn` takes
screenshots of a gravel road, a tarmac road and a junction to check it by eye.

**Lane markings on tarmac** are drawn by the same shader pass: two solid edge lines
`road_marking_edge_inset_m` inside the road's edge and a dashed centre line, sized by the
GameConfig `Road Markings` group (`road_marking_width_m`, `road_marking_center_dash_m`,
`road_marking_center_gap_m`, `road_markings_enabled`) and coloured by the region's
`road_marking_color` (yellow in Greece) or `road_marking_color`'s default. They only appear
where the tarmac weight is over half. This replaces the stage's `RoadMarkings` mesh, which was
never wired into free roam.

**Road surface (gravel / tarmac):** a region with `"road_surface": "tarmac"` paves its ring's
roads (Greece, ring 1, by default; every other ring is gravel). `RoadTerrain.tarmac_weight` is
0–1 per point: its ring's surface, blended over `road_surface_blend_m` where two rings meet (it
uses the same wobbly ring border as `ring_index`). It is the `.y` of `surface_at`, so grip, tyre
marks and wheel debris switch to tarmac through their existing tarmac paths, and it is baked
into each chunk vertex's UV2.x (near painted road), which the ground shader uses to
mix the gravel texture toward the ring's `tarmac_color`.

**Terrain shading (the stage's fake light):** each chunk vertex's colour is its ring tint times
`TerrainStreamer.ground_light(normal)`, which is `TerrainManager.light_for_normal` (hemisphere
ambient plus one low sun aligned with the skybox, the same formula a stage bakes) under the
GameConfig Lighting group: `sun_direction`, `sun_color`, `sky_color`, `ground_color` and
`terrain_light_amount` (0 = flat). The values are read once when the streamer is made, so every
chunk in a session shares the same light. The normal comes from central differences on the
chunk's own height grid (one-sided at a far chunk's edge), so it is baked during the budgeted
`ARRAYS` stage and costs nothing per frame; the shared call adds about 0.3 µs per vertex
(~0.3 ms per 33×33 near chunk, spread across frames by the stage's clock checks). The bushes'
`light_at` uses the same function, so they sit in the ground's light. Until 2026-10-20 the
streamer used its own light (`0.55 + 0.5·max(0, n·sun)` with a high sun that did not match the
skybox), which left the island much brighter and flatter-looking than a stage.

**Following the car (`BiomeDirector`, a node in `free_roam.tscn`):** every 0.25 s it reads the
car's ring and the weather.
- **Handling:** a new ring writes its region's surface grip, deep snow and frozen lakes onto the
  live config, from the authored values (`apply_handling`, the twin of the deleted stage-config handling block). It also re-wires the car's lake drag,
  which is off where lakes are frozen.
- **Wheel debris look:** a new ring also re-seats the wheel particles' off-road particle from
  the region look (`_seat_particle_look` → `WheelParticles.apply_region_look`: Greece's dry
  blades, the snow ring's white powder clods), as `world.gd` does once per stage.
- **Weather drift:** driving time is cut into slots of `weather_hold_s`. Each (ring, slot) draws
  from the ring's weighted pool in `ring_weather` (`"dry:5,rain:1"`, seeded by the world seed,
  `weather_for`). A new condition sets `cfg.weather`, wind sway, the road tint on every ring
  material (from the authored colours, so it never compounds), the particle field on the chase
  camera, and the night headlight cone (pushed every frame while lit).
- **Cross-fade:** a new target (`target_look`: the region's background colour, then the
  weather's overcast look and panorama) blends the fog and background colours, fog density and
  sky affect over `look_crossfade_s`. The panorama can't blend, so it swaps halfway, under a
  fog swell.
- **Exit:** `_exit_tree` puts back the weather, grip, sun dimming, wind and headlight globals.

**Not ported from the stage:** storm lightning, and night's terrain re-bake. Night darkens the
ground through the albedo tint only. Foliage spawned before a weather change keeps the light it
was spawned with. There is **one water level** for the whole island (no per-ring waterline).

## Sites: rest stops, loot slots and dead ends

`RoadSites` plans every place that hangs off the network, once at boot from the whole graph
(decisions 30–31 in `todo/2026-10-19-free-roam-pivot.md`). Rest stops and dead ends are flat round pads.
`RoadTerrain.height` flattens the ground under it to its road's height (`pad_h`, blending back
over `pad_blend_m`, widened where the pad sits far above or below the land so the fade's slope stays
under `pad_blend_max_slope`, up to `pad_blend_max_m` — `RoadSites.blend_m`) and reports it as road, so it draws as gravel, grips as road and nothing is
planted on it (`is_clear`).

- **Rest stops (`REST`):** spawn is the first, centred on the spawn junction, its `dir` the
  way the road leaves spawn (`_road_out_of_spawn`), and its cabin back down that road
  (`RoadSites.back`). The car starts, and respawns there, `GameConfig.spawn_ahead_m` down the
  road out facing away from the cabin (`RestStops.pose_at(0)`, which `free_roam.gd` uses for a
  fresh world too). Until 2026-10-25 spawn faced `Vector3.FORWARD`, which the one road out
  (heading +x/+z) flipped round, so the car started pointed into the cabin. The rest are
  placed breadth-first from spawn, carrying "road since the last rest stop" into each junction
  (the least over the ways in). A stop goes down each time that reaches the spacing for its
  ring: its region's `rest_stop_spacing_m` (RegionLibrary, `rest_stop_spacing_of`), or
  `FreeRoamSettings.rest_stop_spacing_m` for a region that sets none.
- **Loot slots (`LOOT`):** placed the same way at `loot_slot_spacing_m`, kept clear of rest
  stops and water. They sit on the road's centreline with radius 0 and no pad: the ground isn't
  flattened and they stay out of `pad_at` / `is_clear`, so the coin floats over the road and is
  collected by driving over or past it. Each holds a coin ([loot.md](loot.md)).
- **Dead ends (`DEAD_END`):** a clearing at every junction with only one road (spawn aside).
- **Roadside placement** (`_place_along`, `_try_roadside`, rest stops only): never within `JUNCTION_CLEAR_M` of
  a junction. The pad sits beside the road on a seeded side, or the other side if that one is
  water, another road or another pad. When neither side fits, it tries again `RETRY_STEP_M`
  further on.
- **Site markers:** each rest stop in near chunks has a **log cabin** (`_site_marker`,
  `models/cabin/log_cabin.glb`, CC-BY, credit in `models/cabin/README.md`), set back
  `GameConfig.rest_stop_cabin_back_m` from the pad's centre away from the road, door facing the
  road, inside the crowd's arc. It is solid (a box over its walls, `CABIN_WALLS`, in the damage
  obstacle group). Its interior floor (the model's `Interior` plane, seen through the ajar
  door and under the bottom log) is always a plain plank-brown material, and once lit a warm
  `BEACON_LIT` lamp (`Lamp`, an `OmniLight3D`) hangs inside (`_light_cabin`, via
  `refresh_site_marker`). The floor used to be painted unshaded `BEACON_LIT` when lit, which read
  as a flat yellow square through the door. A loot site or dead end
  holding a coin shows a spinning gold disc over the road (`_coin_marker`, `shaders/coin.gdshader`, rebuilt by `refresh_loot_markers` when coins are taken or come back). Both the queued
  marker spawn and the refresh go through `_place_loot_site_marker`, which removes the site's
  `Loot%d` / `Site%d` first, so a refresh landing between a chunk getting its foliage node and
  its marker spawn running still leaves one marker (a duplicate used to be renamed `@Loot%d@N`,
  which no refresh removed, so a coin stayed after its pickup). A taken coin shows nothing.
- **No beacons:** the tall beams of light over rest stops (`SiteBeacons`) were removed on
  2026-10-23 when the cabins arrived; from afar, rest stops show only on the minimap.

On the default island (seed 1): 147 rest stops, 78 loot slots and 27 dead ends on 48 km of road.

## Damage and rest stops

The car runs the **thermal damage chain** (`DamageModel.thermal`, `features/damage.md`):
cooling fails at half health, the engine then only heats up, overheating drains HP, and at 0 HP
the car gives up. The HUD shows a temperature gauge and a cooling warning (`features/hud.md`).

Players see rest stops as **checkpoints**: every player-facing string says "Checkpoint", while the
code (`RestStops`, `RestStopPage`, `RoadSites.Kind.REST`, the save's `lit_sites`) keeps the old name.

`CheckpointBanner` (`scripts/free_roam/checkpoint_banner.gd`, on `RestStops.lit`): the first time a
checkpoint is lit, a full-width "Checkpoint reached" band fades in, with a small "Damage
repaired" subtitle under it (`SUBTITLE`, at `UITheme.FONT_SIZE`; lighting always goes through
`RestStops._pass`, which fully repairs the car), holds `banner_hold_s` (3 s) and fades
out while the car drives on (the tween runs through pauses). The band is presentation only: the ring's stock goes on sale from `RestStops.lit` → `LootDirector.site_lit` (see loot.md). The band itself is
the static `CheckpointBanner.build_band(text, subtitle = "")`, shared with the region banner
(which passes no subtitle).

`RegionBanner` (`scripts/free_roam/region_banner.gd`, made in `free_roam.gd._ready`): the first time
the car drives into a biome ring in this world, the same band shows the ring's region name
(`name_for`: `RegionLibrary` `name` of `BiomeDirector.region_of`). "First time" is
`WorldSession.reach_ring` returning true (the persisted `max_ring` high-water mark, checked every
0.25 s in `_physics_process`), so it survives reloads and ring 0 (spawn) never shows. If the
checkpoint band is up, the region band waits for it to finish rather than stacking.

`RestStops` makes the REST sites into Dark Souls bonfires:
- **Driving past:** reaching a rest stop — its pad, or anywhere on the road beside it, at any speed
  (`rest_reached` → `RoadSites.reached`, swept over the step's travel with
  `RoadSites.road_margin`, so neither speed nor the far lane can miss it) — lights it (its cabin
  doorway glows orange and its minimap mark turns orange), makes it the respawn point (`last_site`) and fully heals the car
  (`DamageModel.repair`, cooling included; `healed`). Spawn is lit from the start. A move there by
  travel or respawn (`move_car_to`) counts as already arrived, and so does a car SPAWNED at a rest
  stop (a new game, Continue, the reload after a parts or car change): the first `step` only notes
  where the car is (`_primed`), so the page doesn't open until it drives away and comes back.
  Teleports (travel, respawn, the R reset) are not swept as drives: `RestStops.move_car_to`,
  `RoadRecovery.reset_done` → `car_teleported` on `RestStops` and `LootDirector` reset the swept
  start, and `free_roam.gd` resets its odometer's start on the same two signals. The `RoadSites.TELEPORT_M` jump guard (shared by `RestStops`, `LootDirector` and the odometer) stays as the backstop for teleports with no signal (the boot placement, `AutoDriver.place_on_route`).
- **Opening the page:** at a rest stop, nearly stopped (below `GameConfig.rest_stop_open_speed_mps`, because gamepad A is also the handbrake), `menu_select` (Enter /
  gamepad A) opens the rest-stop page (`features/menus.md`); `RestStops.can_open` says when (it is also false until `free_roam._hand_over`, `RestStops.input_enabled`, so nothing opens under the boot warm-up), and
  the minimap's line shows the prompt. On touch the prompt reads "Tap" and tapping it calls
  `RestStops.open_here` (`MiniMap._on_prompt_input`). Coming to a halt alone does nothing.
- **Respawn:** on `gave_up` the engine cuts out completely (`EngineSim.killed`: no combustion,
  clutch open so no drive or engine braking, revs spin down to 0, `EngineAudio` pushes silence;
  `EngineSim.reset` clears it) and, `GameConfig.wreck_page_delay_s` later (counted down in
  `RestStops.step`), `RestStops.wrecked` opens the wreck page (`RestStopPage.open_wrecked`,
  View.WRECKED: it says how much money was dropped — `LootDirector.wreck` leaves it at the wreck on `gave_up`). The game keeps running: the
  car rolls on driverless (`RestStops.is_wrecked`, all `ai_*` inputs zero) and rest stops ignore it. Its
  Respawn card (or Back) calls `respawn()`: the car is moved to the last lit rest stop (`move_car_to`:
  stream the destination in with `TerrainStreamer.prefill_at`, then put the car on its road beside
  the pad), repaired, and its engine temperature reset to 0 (a respawn is a fresh car; a rest-stop
  repair keeps the heat). `respawned` carries the wreck position.
- **Travel:** goes to any lit rest stop, with the same move plus a repair.
- **Crowds:** each rest stop has a live crowd (`SpectatorGroup`, `TerrainStreamer._rest_crowd`) of
  `rest_stop_crowd_size` gathered in a band in front of its cabin, between the door and the road.
  As on the old stages they keep apart, back away from the car and drift home, steer off the road
  (rasterised around the crowd only, `_road_cells_near`) and out of the cabin (its wall outline,
  `_cabin_wall_points`, stands in for the trees they avoid), and get knocked over if hit. No
  ragdoll pool: bodies are built on a knock, so streaming a crowd in stays cheap
  (`features/spectators.md`).

The car is fielded through `apply_owned` with a transient owned-car dict (`free_roam.gd →
owned`), so the rest-stop page's tuning works on the shared `TuningPanel` / `car.retune` path.

## Barriers

`RoadBarriers` plans crash barriers once at boot, and each near chunk builds its share with the
stage's `BarrierField` (modules, MultiMesh batching, solid collision in the damage obstacle
group), under the foliage node. The rules match the stage's corner barriers
(`features/barriers.md`):
- **Sharp bends only:** a polyline vertex that turns by more than
  `FreeRoamSettings.barrier_turn_min_deg`. The run covers the outside of the chord before
  it, the arc the road edge makes about the vertex, and the chord after it, reaching
  `barrier_lead_m + BEND_REACH_M` each way.
- **Only where the land falls away:** `BarrierLayout._land_falls_away`, with the stage's
  `GameConfig` `barrier_*` drop and bank settings. It's judged once per three modules to keep
  boot cheap, about 0.3 s on the default island.
- **Open where it should be:** none within 20 m of a junction or 4 m of a pad, and none
  shorter than `barrier_min_run_modules`.

Roads are built into valleys, so the land rarely falls away beside them. The default island has
only about 190 modules.

## Trees, bushes and rocks

Mid chunks are planted after their mesh (and collision) is attached, through the same
`Foliage.spawn_trees` / `spawn_bushes` / `spawn_rocks` the stages used, so a tree looks and
collides exactly as before. `Foliage` and its fields take any terrain with `height_at` (and
`light_at` for the bushes' baked light); the streamer hands them a `PlantGround` (below) that
provides both.

- **Spots** come from jittered grids in world space (`tree_cell_m`, `bush_cell_m`,
  `rock_cell_m`), so a chunk always plants the same things in the same places.
  - **The ground they stand on** (`PlantGround`, `plant_height`): every kept spot stands on the
    exact terrain height, worked out and cached in the budgeted `PLANT` stage (`seat_exact`),
    because the chunk is drawn at 8 m and later at 2 m and a plant seated on either grid would
    float over the other. Other points inside the planting chunk (the water check, a bush's
    light samples) read its mid grid; outside it (cells near the +x/+z edge spill up to 0.85 of
    a cell into the neighbour, rock outcrops and rest-stop crowds spill either way) the exact
    terrain height, using that point's own chunk's road candidates (`_cands_of`), cached per
    spot. Foliage, barriers and crowds are all given this ground rather than the streamer's
    `height_at`. Until 2026-10-20 they read the neighbour's loaded mesh, whatever LOD it had
    (often the 16 m far mesh, or none), so spilled plants floated or sank once the near mesh
    arrived (by up to 28 m on the default island's mountainsides), and the water check depended
    on load order. The road check uses the spot's own chunk's candidates for the same reason.
    Cost (default island, container CPU): about 13% of spots fall outside their chunk, at ~33 µs
    each for the exact height against ~1 µs for a mesh read, paid in the budgeted `PLANT` stage
    (a bush's light samples are warmed there too); the spawns reuse the cache.
  - **Roadside density** (`_roadside_keep`, every region): trees and bushes crowd the road and
    thin out away from it. Right at the tree line every clear spot grows and the forest noise
    leaves no gaps; over `roadside_falloff_m` the kept share eases down to `far_tree_density` /
    `far_bush_density`, and trees there also need the forest noise (`forestiness`, the share of
    land that is forest). It reads the road distance `_spot_is_clear` just left in
    `network.hit_d`, so the noise test runs in the budgeted `PLANT` stage, not on the candidates.
  - Rock groups are thinned by `rock_group_chance` × the region's rock density, then fanned
    into outcrops with `TreeScatter.cluster`.
  - Each spot is rejected if it is in water or within the road's half width plus
    `tree_road_margin_m` plus the plant's own radius (not the shoulder, so trees stand right by
    the tarmac).
- **Biomes:** each ring uses its region's `tree_mix`, bush switch (`spawns_bush_mesh`) and
  rock density (see *Biomes*).
- **Under the budget:** the `PLANT` stage checks a few spots at a time, and `SPAWN` builds
  one foliage field per species as its own unit of work. Splitting fields per foliage bin was
  tried (2026-10-26) and undone: on a phone each field has ~0.9 ms of fixed setup whatever its
  size, so splitting multiplied the work and added draw calls.
- **`GameConfig.vegetation_enabled = false`** leaves out the trees, bushes and rocks only
  (`_plant_candidates`). Every mid build still runs `PLANT` / `SPAWN`, because the barriers
  (with their collision), rest-stop crowds, site posts and coins spawn from it too; until
  2026-10-20 turning vegetation off removed those as well.
- **Lifetime:** the foliage lives on `ChunkState.foliage` and is freed with the mid mesh.
  It is only planted within the mid ring, which matches `tree_render_distance_m` (120 m). A phone
  browser draws it to `tree_render_distance_web_touch_m` (90 m) instead: `free_roam.gd._enter_tree`
  writes `GameConfig.tree_render_distance_for` onto the config before anything is planted, as the
  old stage did in `world.gd`.
- **Bush brushing:** each chunk's bushes get a `BushField` watching the car, so brushing one
  costs HP and drag as on the stage. **Knocking trees over** needs nothing extra: it lives in
  `car.gd` and works on any colliding `TreeMeshField`.

## The shell

`free_roam.tscn` carries the same player-facing layers as the stage scene (`main.tscn`), copied
node for node:
- `HUD` (`hud.gd`): speed, gear and the Health / boost / nitrous gauges. The stage-only labels
  (timer, countdown, stage complete) stay hidden because nothing calls them.
- `MobileControls`, `CameraManager` with the bonnet camera, `PostProcess` and `SpeedLines`.
- `PauseMenu`, armed once `prefill` is done. It has no Photo Mode row (`offer_photo_mode =
  false`), "Reset to road" calls `RoadRecovery.reset_now`, and "Quit to title" goes to
  `title.tscn` with free roam's own confirm text (both set on the node in `free_roam.tscn`).
- `MiniMapLayer/MiniMap` (layer 2, with the HUD): the heading-up, perspective-tilted minimap,
  top-centre. Tap it (or M / gamepad Back) for the full map. See [minimap.md](minimap.md).
- `WheelParticles` (made in `free_roam.gd._ready`, as `world.gd` makes the stage's): gravel
  clods on the road and grass blades off it from spinning or locked driven wheels. It reads
  `TerrainStreamer.surface_at`, the same query the tyres' grip uses (the car finds the streamer
  as its terrain), and its shader is warmed behind the boot (`_warm_up`). Until
  2026-10-20 free roam never created it, so nothing was thrown. See
  [wheel-dust.md](wheel-dust.md). `free_roam.gd._ready` also creates the stage's `EngineSmoke`
  (bonnet smoke on each misfire — the visible sign of an overheating engine in the damage chain)
  and `ExhaustFlames` (limiter backfires, nitrous), and `TireMarks` in its UNGATED mode
  (`setup(null, …)`: no centreline, so the streamer's `surface_at` road weight alone decides —
  ruts on the gravel roads, nothing on grass). A teleport (`RestStops.car_teleported_to`,
  `RoadRecovery.reset_done`) calls `TireMarks.break_ribbons`, so a mark never bridges the jump.
- The streaming readout moved to its own `DebugStats` layer. It starts hidden; **P**
  (`toggle_perf_overlay`) toggles it in every build, release/web exports included.
  Its `frame` line is the rough share of the frame budget still free (`frame_headroom`): the
  budget is `Engine.max_fps`, else the display refresh rate; spent time is the busier of CPU
  (process + physics + render submit) and GPU, measured on the root and `PostProcess/View`
  viewports only while the readout is shown.

**Road recovery** (`RoadRecovery`) replaces `TrackProgress`' recovery, which needs a single
centreline. On request (the `reset_to_road` action: **R** / right-stick click, or the pause menu) it puts the car on the nearest road, facing
along it the way the car was pointing (`road_pose`). By itself it uses the stage's stuck rule and
`GameConfig` fields (`recovery_*`): the car is stationary and can't get out (flipped, flooring
it and going nowhere, or below the ground) for `recovery_timeout_s`. A wrecked car (0 HP with the thermal chain on) is never reset, by request or by itself, so a reset can't revive the engine before the Respawn; a reset keeps the nitrous tank's charge (only a respawn or travel, which go through `Car.reset_to`, refill it). `RestStops._on_gave_up` disarms the pause menu, so neither pause nor the map can be opened (and a quick travel started) in the seconds before the wreck page.

## The auto driver

`AutoDriver` drives the car by itself and keeps score of the streaming:
- **holes:** physics ticks where the car is over a chunk with no collision yet. This must stay
  0, and `test_the_auto_driver_never_reaches_ground_without_collision` checks it on a short
  drive across a small synthetic island;
- **rushes:** times the safety net had to build collision over budget (see *Streaming*). The
  same test also asserts at most 3 rushes, since the safety net alone keeps holes at 0 whatever
  the queue order: a planner or queue regression (a rush on nearly every chunk) shows up here
  first. On the container CPU (2026-10-20) that drive needed 0–2 at the 1 ms budget (it varies
  with machine load) and 4 at half the budget;
- **overruns:** frames over the terrain budget;
- **resets:** times it got stuck and was put back on the route.

**Route** (`plan_route`): from the nearest junction it walks link to link, preferring links it
hasn't driven that lead away from spawn, and avoiding dead ends. It stops at a dead end rather
than turning round. **Steering** is pure pursuit (`BenchmarkRunner.steer_toward`) towards a
point ahead on the route (`point_ahead`). The tracker (`advance`) only takes the nearest
segment a few ahead, never one behind. **Speed** (`safe_speed`) is the fastest the car can go
and still brake to every bend's limit, `sqrt(lateral_accel / curvature)`, within the next
250 m. `top_speed_mps` / `lateral_accel` / `brake_decel` are per-driver vars, so the benchmark
can drive calmer than the streaming test. `place_on_route(i)` puts the car on route point `i`
(the unstick uses it, and the benchmark starts the car on the route's first point).

**Straight-road island** (`FreeRoamSettings.straight_road_m` > 0): `RoadNetwork.build` skips
growth and makes one dead-straight road of that length out from spawn; terrain, foliage, sites
and rings build around it as usual. Only the benchmark uses it ([benchmark.md](benchmark.md)).

Run it from the command line to drive 3 km of the real island and print the report:
`godot --headless --path . --fixed-fps 60 -- --auto-drive`. On the default island
(2026-10-20, container CPU, after the stage 2 fixes) it finished the 3 km with 0 holes at about
50 km/h, with 2.2% of frames over the 1 ms budget (40 ms of overshoot in total) and 12 spikes
over 1.5 ms (worst 3.2 ms) in 13,500 frames. Before the fixes, 36% of frames were over.

## Not in the prototype yet

Threading. Pickups ([loot.md](loot.md)), the damage chain and rest stops as checkpoints (*Damage
and rest stops* above) are in. The remaining work is
staged in `todo/2026-10-19-free-roam-pivot.md` → *Staging*. The settings
live on a `FreeRoamSettings` resource rather than `GameConfig` while the shape settles.
