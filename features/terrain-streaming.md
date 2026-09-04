# Terrain — Bounded-World Streaming

**Source:** `scripts/terrain_manager.gd` — the bounded/streamed-world seam
(`load_radius`, `stream_on_miss`, `chunk_source`, `road_source`, `pad_source`,
`region_source`, `set_bounds`/`apply_overworld_bounds`, `evict_to_cap`); see
[terrain.md](terrain.md) for the base chunked-terrain system this extends.

**Tests:** `tests/headless/test_terrain_manager_bounds.gd`,
`tests/headless/test_terrain_manager_streaming.gd`


**This whole file documents a producer-less consumer.** `TerrainManager` carries a
**bounded, streamed** world mode — built for the drivable overworld hub that the
roguelike pivot deleted (`todo/roguelike-pivot.md`: "The overworld hub goes too" —
`overworld.tscn`, `scripts/overworld_region.gd`, `scripts/overworld_picker.gd`,
`scripts/overworld_roads.gd`, `scripts/overworld_pads.gd`, `scripts/overworld_cache.gd`,
`scripts/overworld_garage.gd` and `tools/analyse_road_grades.gd` are all gone, along with
the design spec that motivated them). **`TerrainManager`'s side of the seam survives** —
every field, method and pass below is still live code in `scripts/terrain_manager.gd` — but
nothing in production feeds it any more: `apply_overworld_bounds`'s only caller was the
deleted overworld, `set_road_source`/`set_pad_source`/`set_region_source` are never called
outside tests, and the duck-typed producer classes they used to be fed by
(`OverworldRoads`, `OverworldPads`, an `OverworldRegion`) no longer exist in the codebase.

**Why this is documented rather than deleted:** it is real, working, headless-tested
infrastructure — not dead code left behind by an incomplete cleanup. `apply_overworld_bounds`
and `GameConfig.overworld_load_radius` / `overworld_chunk_build_budget` /
`overworld_edge_taper_m` / `overworld_edge_depth_m` / `overworld_size_m` /
`overworld_pad_*_radius_m` are all still read (see [configuration.md](configuration.md));
only `GameConfig.overworld_enabled` has no reader left. If a future feature needs a bounded,
streamed terrain again — a second hub, a free-roam area, anything larger than the fixed
stage corridor — this is where it plugs in, and the duck-typed contracts below (`road_source`,
`pad_source`, `region_source`, `chunk_source`) are what a new producer would implement; they
are not resurrected class names to go find. **Two names in the codebase are misleading survivors,
not orphans — do not delete them on sight:** `TerrainManager.apply_overworld_bounds` (this
whole mode's entry point) and `RallyLibrary`'s `map_reveal_radius` / `overworld_size_m` reads.
This is a set of **additive, off-by-default opt-ins**: leave every field below alone and
behaviour is bit-identical to a stage. Nothing here is used by `main.tscn`.

| Field / method | Default | What it does |
|---|---|---|
| `load_radius: int` | `RADIUS` (3) | Live ring radius, above. |
| `stream_on_miss: bool` | `false` | A cache miss **builds** instead of leaving a hole. |
| `cache_cap_mb: float` | `0.0` (off) | Cap on `cache_size_mb()`; over it, `evict_to_cap()` drops chunks. |
| `chunk_source: Object` | `null` | Duck-typed chunk store (see below). |
| `road_source: Object` | `null` | Duck-typed road network — the per-chunk road carve and `surface_at`'s network branch (see below). No producer ships; see the note above. |
| `capture_encoded_light: bool` | `false` | Keep `l0_light` even when `lazy_finest_lod` is off. |
| `world_bounds: Rect2` | empty | The bounded world; empty = a stage. |
| `edge_taper_m` / `edge_depth_m` / `water_level_m` | `0` | The coastline taper. |
| `bounds_surface: Vector2` | `(0, 0)` | What `surface_at` returns inside bounds. |
| `set_bounds(rect, taper_m, depth_m, water_y)` | — | Declares the bounded world. |
| `clear_bounds()` / `has_bounds()` | — | Back to stage mode / the predicate. |
| `apply_overworld_bounds(cfg, rect)` | — | Seats all of the above from a `GameConfig` in one place. |
| `set_chunk_source(source)` | — | Attaches the store (and arms `capture_encoded_light`). |
| `set_road_source(source)` | — | Attaches (or clears) the road network. Must be seated **before** any chunk is built or cached. |
| `taper_height(h, x, z)` | — | The falloff itself; a no-op outside bounded mode. |

Params are **passed in**, not read off `Config`, so this `@tool` script stays editor-safe
and pure — the same convention as the `light_*` and `cliff_*` fields.
`apply_overworld_bounds` is the one place that reads `GameConfig`
(`overworld_load_radius`, `overworld_chunk_build_budget`, `overworld_edge_taper_m`,
`overworld_edge_depth_m`, `track_water_level_m`).

## Bounds replace the track corridor

An open world has no `set_track`/`bake_track`, and five behaviours degrade without a
corridor. `has_bounds()` is the switch that fixes each:

| Behaviour | Without a corridor | With `set_bounds` |
|---|---|---|
| `chunk_class` | full-res `l_min` 0 for unknown coords, so pruning is dead | explicitly full-res **and** in the collision band — correct, because the car can reach anywhere, so no chunk is "far from the route" |
| `corridor_complete()` | permanently false, so `free_load_only_data()` never fires | `true` — "no chunk can still be asked for the bake fields", which is true by construction (there are none) |
| `corridor_bounds()` | empty `Rect2`, so `DistantTerrain.build_static` builds no horizon | returns `world_bounds` |
| `surface_at` | reads the empty `track_weights`/`track_surface` and answers 0 by accident | asks `road_source` when one is attached (`_road_surface_at`), else returns `bounds_surface` by decision |
| light queries | `lights` freed while `corridor_complete()` stays false → `_cached_light_at` `push_error`s per query | `free_load_only_data()` **keeps** the light and never latches the sentinel; `_cached_light_at` also falls through silently under bounds, so no spam |

Keeping the light is not a leak — in an open world `light_at` is a repeated query and chunks
are generated in *play*, so `lights` is a live input to every `chunk_source` write, not
load-only data. (`compute_chunk_data`'s five post-passes, `_chunk_view`, and the `bake_track` split: [terrain-chunk-modifiers.md](terrain-chunk-modifiers.md).)

## The coastline edge taper (D9)

`taper_height(h, x, z)` drives the height toward `water_level_m - edge_depth_m` as a point
approaches the perimeter of `world_bounds`, smoothstepped over `edge_taper_m`. So the world
is an island and the sea is the border — no invisible wall, no turn-back logic, and it reuses
the waterline `LakeField` already builds ([lakes.md](lakes.md)). Beyond the bounds the inward
distance clamps at 0, so the sea floor is a flat shelf at full depth rather than falling
forever.

**Where it is applied is load-bearing.** It runs *inside height generation*, before any
quantisation or caching, through exactly two call sites — both delegating to the one
`taper_height`:

1. `_noise_height_at` — the pure-noise fallback `height_at` uses for any uncached coord.
2. `TerrainManager._apply_edge_taper`, called by `compute_chunk_data` immediately after
   `TerrainChunkBuilder.build()`, which rewrites `heights` **and** `vertices` in lockstep.

Both paths must agree or the coast disagrees with itself, which is why they share one
function. `heights` is what the `HeightMapShape3D` collision, `height_at` and
`TerrainLod.build_finest` read; `vertices` is what the displayed meshes are built from. It
is done in the manager rather than in `TerrainChunkBuilder` because the builder's height path
is the *static* `TerrainManager._sample_height`, which has no instance and so cannot see the
bounds.

Two accepted consequences, both commented at the code:

- The per-vertex **baked light** is computed inside the builder from the untapered field, so
  the taper slope shades as the inland noise would. Shading only — geometry, collision and
  queries all agree.
- The **coarse** (`stride > 1`) builder path is untapered, and is unreachable in bounded
  mode because `chunk_class` returns `full_res` for every chunk there.

Pin safety: no authored `map_pos` may sit inside the taper band, or its zone drowns. That is
a shipped-content guard on `tools/fit_map_pins.py`, not something this file enforces.

## The road carve (per chunk, not a global bake)

**No producer ships.** This section describes the contract a `road_source` object had to meet
when one existed (`OverworldRoads`, `scripts/overworld_roads.gd`, deleted with the overworld
hub) — a deterministic network over the rally pins plus the garage, queried per point by
`road_at`. `TerrainManager` consumes it through the duck-typed `road_source` (`set_road_source`),
never by class, so this file keeps no dependency on it and `null` (every stage, and every
production build today) is byte-identical to before.

`TerrainManager._apply_road_carve(data, carve_heights)` is the carve, run by
`compute_chunk_data` as a post-pass on the builder's arrays — deliberately **not** through
`bake_track`:

- `bake_track` is one global distance-field pass over a corridor derived from a single
  `Curve2D`, filling map-wide per-cell dictionaries. The overworld is a network over ~1,600
  chunks, so those dictionaries would hold millions of cells.
- `free_load_only_data()` drops `road_heights`/`road_blend` after load, so any chunk generated
  later — and in the overworld *every* chunk is — would silently lose its flatten.

What it writes, in one pass over the grid, is the same four things `bake_track` expresses per
cell:

| The carve writes | `bake_track`'s equivalent | Read by |
|---|---|---|
| `heights` **and** `vertices`, in lockstep | `road_heights` + `road_blend` | the `HeightMapShape3D` collision, `height_at`, `TerrainLod.build_finest` / `build_all`, and the cached bytes |
| vertex colour **alpha** = `road_weight` | `track_weights` (via `_vertex_color_row`) | `ps1_models.gdshader` — `road_t = COLOR.a` under `blend_road` |
| **`UV2.x`** = `tarmac_weight` | `track_surface` (via `_surface_uv2_row`) | the same shader — `tarmac_t = UV2.x` |

**`UV2.y`** is filled by a separate bounded-world-only post-pass, `_apply_region_blend`: the
**canonical region rank** the ground shaders decode into a spatial region cross-fade — through the
all-regions colour LUT (`region_lut_look`) for tint/tarmac and through the two-slot pair
(`region_blend_t`) for the ground texture. It runs after the carve and the coastline taper and before the height quantum,
is repeated in `_rehydrate_chunk_data` (the row builders rebuild `uv2s` from scratch), and is a
no-op without a `region_source` — so a stage never writes it and `blend_region` ships false. The
rank was, when there was a producer, sampled at the chunk's **four corners** and bilinearly
interpolated (`region_weights_at`), because the region field varies over kilometres while a chunk
is 50 m. No `region_source` ships today — see the note at the top of this file.

The roadbed height is the terrain's own **pure noise** at `hit.foot` (the nearest point on the
centreline), blended in by `hit.road_weight` — exactly `bake_track`'s
`road_heights`/`road_blend` pairing. `road_weight` doubles as the flatten weight rather than a
second `height_bias_at` call, because the two are equal today and this is a per-vertex hot
loop; `OverworldRoads.height_bias_at` exists so the flatten band and the colour band *may*
diverge later, and the carve carries a comment saying what to change if they ever do. Noise
instances are built locally (`_build_noises`), not taken from the main-thread cache, because
`compute_chunk_data` runs on worker threads.

**Two ordering rules make it correct:**

1. It runs **inside generation** — after `builder.build()`, before quantisation and before any
   cache write — so the mesh, the collision heightfield, `height_at` and the cached bytes all
   derive from one number. Same reason the coastline taper is a grid pass here.
2. **The coastline taper wins.** `compute_chunk_data` calls `_apply_road_carve` *first* and
   `_apply_edge_taper` *second*, so a road running to the shore is flattened onto the noise
   ground and then dragged down to the sea floor with everything around it. The alternative —
   taper first, then clamp the flatten so it can never raise tapered ground — needs an extra
   rule the flatten has to remember; carve-then-taper needs none, because `taper_height` is a
   plain function of `(h, x, z)` that re-derives the shoreline from scratch. A road therefore
   sinks into the water at the map edge instead of standing on a causeway out to sea.

Cost, and the three things that were paid for nothing before:

- **The per-chunk reject** is `has_segments_in_rect(rect)` where the source has it — a predicate
  that stops at the first hit. `segments_in_rect(rect).is_empty()` answered the same question but
  first built an Array of freshly allocated per-segment Dictionaries that the carve then threw
  away, on the *common* path (nearly every chunk of ~1,600 is road-free). Both share one scan
  (`OverworldRoads._scan_rect`) so the cheap reject cannot drift from the list it predicts.
- **The per-vertex query** is `OverworldRoads.road_at_into(x, z, out)` where the source has it — an
  allocation-free twin of `road_at` filling one caller-owned 5-slot `Array`
  (`[road_weight, tarmac_weight, distance_m, foot.x, foot.y]`, indexed by the `PROBE_*` constants).
  `road_at` is now a thin Dictionary wrapper over it, so the two cannot disagree. A source without
  the variant (the duck-typed fakes in the tests) keeps the dictionary path.
- **The noise set** is the shared `_ensure_noise_cache()` pair, not a fresh `_build_noises()` per
  carved chunk. The old code minted 3–4 new `FastNoiseLite` objects per chunk, justified by a
  comment claiming `compute_chunk_data` runs on worker threads. **It does not** — there is no
  threading anywhere in the terrain path (`WorkerThreadPool` / `Thread` / `Mutex` appear in exactly
  one file in `scripts/`, `cloud/google_sign_in.gd`), and the target platforms include
  single-threaded ones (mobile web), so threads are not an escape hatch either. `TerrainChunkBuilder`
  still calls `_build_noises()` per chunk on the same stale reasoning and is the obvious next win on
  the *generate* path.

A chunk with no road still pays exactly one rect query and returns. Only the full-res grid is carved; the coarse
(`stride > 1`) path is unreachable in bounded mode because `chunk_class` returns `full_res`
there, and the guard says so explicitly rather than leaving it ambiguous.

`_rehydrate_chunk_data` calls the carve with `carve_heights = false` — **colours only** — but only
when the record carries no stored surface channels (see "The stored surface channels" above; with
them, both passes are skipped outright). Its
`heights` came out of a previous `compute_chunk_data` and are already carved (re-flattening
would compound the lerp), but its colour/uv2 rows are rebuilt from `track_weights` /
`track_surface`, which a bounded world never fills, so without this a cached chunk would come
back road-*less* under the wheels' road.

`surface_at` also answers from the network in bounded mode (`_road_surface_at`), returning the
same `(road_weight, tarmac_weight)` pair the dictionary path does, and `bounds_surface` when
fully off it. Without this the tyre model, grip, deep-snow drag and reset logic would all see
one flat surface and a carved road would have no grip difference at all. It is called per wheel
contact per tick and `road_at` returns a Dictionary, so `_road_surface_at` keeps a one-entry
memo keyed on the contact point quantised to a quarter cell — several consumers ask about the
same point in the same tick (`Drivetrain.surface_tire_params`, itself allocation-free via
`_surf_scratch`, plus grip and the snow drag), so the repeats cost nothing. A lean scalar
variant on `OverworldRoads` would remove the miss allocation too, if it ever shows up in a
profile.

`_road_surface_at` also consults `pad_source`, `maxf`'d over the road's own answer with the same
pad-wins precedence `_apply_pad_flatten` bakes into the mesh (see "Flat pads" below) — this is
what keeps `wheel_particles.gd` and `Drivetrain.surface_tire_params` agreeing with what the pad
*looks* like. Both go through this one function, so the fix lives here rather than being
duplicated in each consumer. `set_pad_source` invalidates the one-entry memo for the same reason
`set_road_source` already does: a query made before the pad was attached (or before a pad swap)
must not answer stale afterwards.

## Flat pads

**No producer ships** (same caveat as the road carve above). This section describes the contract
a `pad_source` had to meet when one existed: a **level circle of ground** under every rally zone
and under the garage, so the things standing there sit flat. The pad set was `OverworldPads`
(`scripts/overworld_pads.gd`, deleted with the overworld hub); `TerrainManager` consumes it
duck-typed through `pad_source` / `set_pad_source`, never by class, so `null` — **every stage,
and every production build today** — is byte-identical to before pads existed.

Two entry points for the HEIGHT flatten, both driven by `pad_at(x, z)` (`.x` = feathered weight,
`.y` = target height) — `pad_height(h, x, z)` wraps it for callers that only want the height:

- `_apply_pad_flatten(data)`, a grid post-pass in `compute_chunk_data`, rewriting `heights` and
  `vertices` in lockstep exactly as `_apply_edge_taper` does. It exits on one `pads_in_rect`
  query for the ~1,600 chunks that hold no pad.
- `_noise_height_at`, the pure-noise generator. **This is the deliberate difference from the road
  carve**, which is *not* in the generator (a known latent bug). Everything a pad exists for —
  seating the garage building, a zone's tube and marker, a ghost car, the default spawn, the
  foliage `dry` test — queries `height_at`, which falls back to `_noise_height_at` for any coord
  the chunk cache has not built. Leaving the pad out of the generator would break the pad exactly
  where it is used, so the pad follows the taper, not the carve.

`_apply_pad_flatten` **also bakes tarmac** — `COLOR.a` (road weight) and `UV2.x` (tarmac weight),
the same channels `_apply_road_carve` fills and `ps1_models.gdshader`'s `blend_road` branch reads
— using the *same* `pad_at(x, z).x` weight that drives the height blend, `maxf`'d against whatever
the carve already wrote there. So the whole pad disc (every rally zone **and the garage**) reads as
forecourt rather than roads simply meeting on bare grass at the pin, and it fades to grass across
exactly the same feather band the height flatten uses — one weight, no separate radius to keep in
sync. A `flatten_heights := true` parameter lets `_rehydrate_chunk_data`'s no-stored-surface branch
call it a second time for the tarmac alone (see below).

**Ordering in `compute_chunk_data`, all three rules load-bearing:**

1. **After `_apply_road_carve`.** A pad wins over a road inside it, on *both* channels: the
   forecourt is level ground the road paints across, and its tarmac weight is `maxf`'d over the
   carve's rather than left as the carve wrote it — a dirt/dead road running through a pad (its own
   `tarmac_weight` might be `0`) must not leave a stripe of non-tarmac ground across the pad's own
   surface.
2. **Before `_apply_edge_taper` — the coastline still wins.** The taper re-derives the shoreline
   from `(h, x, z)`, so a pad near the map edge is pulled to the sea floor rather than standing on
   a plinth out of the water. Same rule, same order, as the carve.
3. **`_apply_height_quantum` stays last.**

**Rehydration.** `_rehydrate_chunk_data` splices a stored `surface` section straight back in when
present — it already carries the pad's tarmac contribution bit-for-bit, since it was written from a
`compute_chunk_data` that included this pass. When no `surface` is stored, colours/UV2 are rebuilt
from scratch via `_apply_road_carve(out, false)`, which would otherwise wipe any pad tarmac back out
even though the stored heights already carry the flatten; `_apply_pad_flatten(out, false)` runs
right after it to restore just the two texture channels, mirroring the road carve's own
`carve_heights` split.

`_noise_height_at` applies pad-then-taper for the same reason, so the generator and the baked grid
cannot disagree.

### The junction: roads run *into* every pad

`OverworldRoads` built its graph with the rally pins and the garage as its **nodes**, so a pad
centre was literally a road endpoint with 3–5 edges typically converging there. The roadbed target
(noise along the centreline) and the pad's level agree exactly at the pin and drift apart outward,
so two independent passes would leave a step or a crease in a ring around the pad — at the most
looked-at spot on the map.

The fix is inside `_apply_road_carve`: the roadbed target is itself run through `pad_height`,
evaluated **at the foot** (the nearest point on the centreline). The road therefore *arrives
level*, ramping onto the pad's plane over its last stretch the way a real road eases into a yard.
Inside the pad the road's target **is** the pad level, so the pad pass that follows changes nothing
the carve did not already do and the two cannot fight; outside, both influences decay smoothly.

**Is it genuinely continuous?** Yes by construction, not by tuning — every term is a continuous
function of position, so no combination of tunables can reintroduce a *step*. Two honest caveats:

- The foot point jumps across a road's medial axis (equidistant between two segments), so the
  pad-adjusted target has a hairline discontinuity there. It is damped by the road weight and by
  the fact that the two feet are near-equidistant from the pad centre, i.e. sub-millimetre in
  practice — but it is not exactly zero. Several roads entering within a few degrees of each other
  is the case that makes it largest.
- **Gradient, not continuity, is what actually breaks.** The steepest grade a feather can produce
  is about `1.5 × Δh / feather width`, where `Δh` is the height difference between the pad's level
  and the ground just outside it. With a FIXED band that grade is whatever the site hands you, and
  on a rough site it exceeded the ~22% FWD / ~33% RWD a car climbs at snow grip — a lip the player
  could not drive out over, on the very road that led them in.

**Each pad sized its own feather** (`OverworldPads._feather_for`, called once per pad at
build time, in the now-deleted producer). It sampled a ring of the terrain's *own generated*
height at the candidate band's outer edge, took the worst `|level − h|`, and demanded
`1.5 × Δh / overworld_pad_max_grade` of run for it — re-sampling a couple of times, since
widening moves the ring outward onto possibly rougher ground. The width only ever grew from the
authored `overworld_pad_feather_m` (the *minimum*) and was capped at `overworld_pad_max_feather_m`,
so a pad on a cliff edge accepted a steeper lip rather than flattening the neighbourhood. It stayed
pure and deterministic, and the per-pad width was folded into `stamp()` so the chunk cache
re-warmed when it changed.

**Three constraints resolved the width, and they were derived by MEASUREMENT** — via
`tools/analyse_road_grades.gd` (deleted with the overworld hub), which walked every road on the
real map and reported the grade the car meets:

1. **The grade-driven widening** above asks for `1.5 × Δh / overworld_pad_max_grade`.
2. **The neighbour cap** (`_neighbour_cap`) refuses more than *half the clear gap* to the nearest
   other pad, floored at the authored feather. Without it, the widening ran every band to the
   60 m ceiling on a map whose pads sit ~150 m apart, so every band overlapped its neighbours and
   the ground between two pads was a blend of two pad levels the whole way across — the entire
   height difference had to be paid in the narrow strip where the blend handed over. Roads that
   ran at worst 0.28 over open ground hit **0.67** with pads on. The widening was manufacturing
   the defect it exists to prevent.
3. **The radius shrink** (`_shrink_to_fit`) was the lever left when the cap refused the width: a
   smaller disc has less to give back (`Δh` ≈ terrain slope × radius). Bounded by
   `_MIN_RADIUS_SHARE`, and the **garage pad was exempt** — `overworld_garage.gd` (also deleted)
   clamped the building against the *configured* radius, so shrinking the pad would have left the
   building off the flattened ground.

The pad's **level** is the mean of the terrain over its own footprint (two rings plus the centre),
not the height at the single centre point: a pin on a local bump used to take its level from that
bump and pay the whole offset back across the feather.

**Overlapping pads blend their target.** The flatten *weight* is still the strongest pad's (a
pad's own footprint must read as fully flat), but the target height is
`Σ (w/(1−w))·level / Σ (w/(1−w))`, not the strongest pad's level taken outright. Outright, the
target jumps by `w·(levelA − levelB)` where two influences cross — metres tall on rough ground,
the very cliff the feather exists to prevent. That used to be rare (two pads had to sit within one
14 m band); with bands that widen it is common. `w/(1−w)` diverges as `w → 1`, so a sample inside
a pad outvotes every neighbour and the interior stays flat — this is not the honest average, which
would tilt both pads. (It replaced a `w⁸` weighting that did keep interiors flat but swung the
target almost entirely from one level to the other across the locus where two weights are equal.)

Consequences elsewhere: `influence_m()` reports the **widest built** feather (a caller inflating by
the authored width would miss a widened pad's outer skirt), `pads_in_rect` and `pad_at` use each
pad's own width, and `feather_m()` now means the authored minimum — ask `pad_feather(i)` for what
pad *i* actually uses.

No *extra* widening is done where a road enters, and none is needed: the road already arrives at
the pad's level, so there is no height difference for the two feathers' differing rates to expose.

## `stream_on_miss` — a correctness fallback, not the supply mechanism

Today a miss with a partially-filled cache deliberately spawns **nothing** (a hole, plus a
`push_error`) because a mid-drive build is a measured hitch. `stream_on_miss` builds instead.
It goes through `_stream_chunk`, which routes to `cache_chunk()` rather than the raw
`compute_chunk_data` on-demand branch, because that branch has two side effects that must not
be inherited:

1. It hands `TerrainChunk.apply_data` a dict with no `lod_meshes`, so the **node** builds all
   five LOD levels itself and never joins the lazy finest-LOD path — pinning level-0 VRAM
   until it first despawns. Via `cache_chunk` the levels are prebaked, `lazy_finest_lod` is
   honoured, the collision shape is built once and `DEAD_AFTER_PREBAKE` is dropped.
2. It reads the road/cliff bake fields that `free_load_only_data()` deletes. Bounded mode
   never frees them; a stage that turned this on after the free would get unflattened ground,
   so that case `push_error`s.

It **logs once per session** (`terrain stream-on-miss:`, `stream_on_miss_builds` counts them)
so an undersupplied window or a gap in the store is visible rather than silent — never per
coord and never per frame, since a boundary crossing re-visits the same coords every frame
until they are built.

## `chunk_source` — the duck-typed chunk store

**No producer ships** (same caveat as above — the producer was `OverworldCache`,
`scripts/overworld_cache.gd`, deleted with the overworld hub; tests exercise this with duck-typed
fakes). `chunk_source` is used **only** through `has_method`, never by class, exactly the way
`drivetrain.terrain` is duck-typed. The contract is three methods:

- `read(coord) -> Dictionary` — `{"heights": PackedFloat32Array, "l0_light": PackedByteArray,
  "surface": PackedFloat32Array}` (`surface` optional)
- `write(coord, heights, lights, surface := PackedFloat32Array()) -> bool`
- `has(coord) -> bool`

The store holds the two genuinely expensive **sampling** products (heights and baked light) plus
the three **derived surface channels**. Everything else is arithmetic over a fixed grid, so
`TerrainManager._rehydrate_chunk_data` reconstructs a full builder-shaped dict — mirroring
`TerrainLod.build_finest`'s derivation and reusing `_vertex_color_row`, so a rehydrated chunk is
the same surface a generated one produces.

### The stored surface channels — why a READ is cheap

Storing heights + light removed the height *generation* from a read and **nothing else**: the
rehydrate still ran `_apply_road_carve(out, false)` and `_apply_region_blend(out)`, and the carve
queries the road network **once per vertex** (`SAMPLES²` = 2,601 per chunk), each query allocating
a Dictionary. Measured, that made every chunk-boundary crossing a 3–4 frame cluster of 13–34 ms
spikes even with `overworld_chunk_build_budget` honoured and `stream_builds` at 0 — the cost was
pure rehydration.

So the three values those two passes produce are stored too, via
`TerrainManager.surface_channels_from(data)` — interleaved per vertex as
`(road_weight, tarmac_weight, region_rank)`, i.e. `(COLOR.a, UV2.x, UV2.y)`:

| Channel | Produced by | Consumed by |
|---|---|---|
| `COLOR.a` road weight | `_apply_road_carve` (colours arm) | `ps1_models.gdshader` `road_t` |
| `UV2.x` tarmac weight | `_apply_road_carve` (colours arm) | `ps1_models.gdshader` `tarmac_t` |
| `UV2.y` region rank | `_apply_region_blend` | the ground shaders' A→B remap |

When `_rehydrate_chunk_data` is given a correctly-sized `surface` it splices those values in and
**skips both passes entirely**; `_surface_uv2_row` is skipped with them. `_vertex_color_row` still
runs for the **RGB** (ground tint × baked light) — the light is stored, the tint is a runtime
field, so nothing about that path changes.

**Stored as raw f32, deliberately.** The cache's contract is an *exact* round trip, not an
approximate one (`test_overworld_cache` asserts bit-identical heights, `test_terrain_digest` is a
golden SHA-256 over generated terrain). Heights get away with int16 only because they are
**snapped at generation** (`height_quantum` / `snap_heights`), so cached and generated numbers are
literally equal. These three channels are snapped nowhere, so a quantised channel would make a
rehydrated chunk differ from a generated one — a shading seam wherever the cache boundary happens
to fall. f32 costs 12 bytes/vertex, ~31 KB raw per chunk before the record's zstd, which crushes
it: the road channels are exactly `0.0` across nearly every vertex of the map and the rank is
near-constant inside a region.

**Optional in both directions**, so the fast path is never a correctness dependency: a record
written without the section (no road/region source, or a record predating it), a mis-sized array,
or a caller that only has heights all fall back to recomputing the two passes exactly as before.
The deleted `OverworldCache.write` dropped a wrong-sized array with a warning rather than storing it — the same rule any future producer should follow.

`chunk_data_for(coord)` is the single seam: read from the store, else generate and offer the
result back. Stored heights are **already tapered** (they came out of `compute_chunk_data`),
so a round trip is idempotent and the taper is never re-applied. A store is always a pure
speed-up — no store, no record, or an unusable record all fall through to generation.

`capture_encoded_light` extends the `l0_light` retention (previously only under
`lazy_finest_lod`) to the open world, because `free_load_only_data()` erases the
full-precision `lights` and a `write` after that would persist a light-less record the
invalidation key could never discard. It stays **off** for stages: ~7.8 KB per chunk with no
reader.

## Cache eviction (`evict_to_cap`)

`_chunk_cache` was only ever cleared wholesale — the per-coord `erase` in `_reconcile` is on
the spawned-node dict, not the cache — so a large resident window grew without bound.
`evict_to_cap()` drops cached chunks farthest from the focus first until `cache_size_mb()` is
back under `cache_cap_mb`. It is called from `cache_chunk` and from the end of `_reconcile`,
and is a no-op with no cap (every stage: a stage's corridor cache is sized by the precompute
and losing an entry would leave a hole).

Three hard safety rules, each a real bug if broken:

1. **Never evict a coord whose `TerrainChunk` node is live.** `lod_meshes` and `shape` are
   handed straight to the node, so freeing the dict under it would pull the meshes and the
   collision heightfield out from beneath ground the player is driving on.
2. **Stay strictly outside the built window** — Chebyshev `> load_radius + 1` from the focus
   chunk, the `+1` being hysteresis so a coord the next reconcile is about to spawn is not
   thrown away a frame early. Eviction is *not* lossless: once a coord leaves the cache,
   `height_at` / `light_at` / `surface_at` fall back to pure noise, so the queried height
   would disagree with the mesh the player stands on. Outside the window nothing is standing
   on it.
3. **Free both products explicitly** — `lod_meshes` (the per-level `ArrayMesh` array, i.e.
   the VRAM) and any prebuilt `shape` (the `HeightMapShape3D` committed to the
   `PhysicsServer`) are erased before the dict is dropped, so the intent is visible rather
   than left to refcount coincidence.

`cache_size_mb()` (now factored over a `_chunk_bytes` helper) is the reporting hook. Note it
counts CPU-side packed arrays only, **not** `lod_meshes` — those are already-uploaded GPU
buffers; `_log_precompute_vram` covers that half.

Related: `build_initial()` now seats `_last_focus_coord` **before** reconciling rather than
after. Eviction measures distance from it, and the sentinel it starts at is ~2 billion chunks
away, which would make every cached chunk look evictable during the very first build.
`_reconcile` takes its centre as an argument, so the reorder changes nothing else.

## The reconcile queue's cost

The detail queue was sized for 49 chunks and is quadratic-ish at 441. The `O(n²)` half is
gone: membership is now an `O(1)` `_queued_for_detail` dictionary mirroring `_detail_queue`
(kept in step by `_drain_detail_queue`, which erases on every exit path) instead of a linear
`_detail_queue.has(coord)` inside a loop over every loaded chunk.

The per-reconcile **re-sort** is kept deliberately and was not rewritten. It is `O(n log n)`
on a queue that only ever holds chunks inside `detail_ring()` — 2 at the shipped tunables,
i.e. a 25-chunk cap regardless of `load_radius` — and it runs only when the focus *crosses*
a chunk boundary, not per frame. A heap or an incremental insert would be a risky rewrite of
the detail path for no measured gain. Revisit if `detail_ring()` is ever raised so the queue
holds hundreds of entries.

## `detail_ring()` and a larger radius

`detail_ring()` clamps to `load_radius` now, not the old `RADIUS` const, and that is a
decision rather than a mechanical substitution. The computed value depends only on
`lod_band_ends_m[0]` and `precompute_safety_slack_m` — **not** on the radius — so at the
shipped tunables it is 2 and the clamp does not bind at either radius: raising `load_radius`
to 10 leaves the result unchanged, so lazy-LOD behaviour on a stage is identical. The clamp
only binds when level 0's band plus the camera slack reaches *beyond* the loaded ring, and
there "every loaded chunk keeps its finest level" is the right answer at whatever the ring
actually is — clamping to 3 inside a 21×21 window would instead have *reduced* the detail
ring below what the bands ask for. Same reasoning for the empty-bands case: no bands means
one level, so the whole ring is finest.

## Spawning within the frame budget

`_reconcile` does **not** spawn a crossing's whole new ring row in one call when
`spawn_budget > 0` (the overworld sets it from `overworld_chunk_build_budget`): `_enqueue_spawns`
sorts the missing coords nearest-first and queues them, and `_drain_spawn_queue(spawn_budget)`
builds at most the budget per frame thereafter.

**The forced set is bounded to `collision_ring` exactly** — the band that carries live collision.
That set is never deferred, because the project chose *loud holes over generate-on-miss* and a
missing chunk under the car is a fall-through, not a cosmetic gap. It used to be
`collision_ring + 1`, which cost 5 immediate builds per crossing instead of 3 (a 3×3 crossing adds
one row of 3) — and immediate builds bypass the budget entirely, so they were the `update_focus`
half of the measured chunk-boundary spike. A chunk one ring beyond the collision band cannot be
touched until it has itself *become* the collision band, which is a whole chunk of travel (50 m,
well over a second at any speed the car reaches) and therefore many frames of budgeted draining.
The no-hole guarantee is unchanged: the band the car can stand on is complete before
`update_focus` returns.

**Ring membership is arithmetic, never `target_coords(...).has(coord)`.** `target_coords` is
exactly the Chebyshev ball of radius `load_radius`, so `maxi(absi(dx), absi(dy)) <= load_radius`
answers the same question with no allocation. Three places used the Array instead:
`_drain_spawn_queue` rebuilt the whole 441-entry Array **every frame** the queue was non-empty and
then linear-scanned it per drained coord; `_reconcile`'s despawn loop linear-scanned it per
resident chunk (441 × 441 ≈ 195k `Vector2i` comparisons per crossing at radius 10, straight into
the measured `update_focus` cost); and `_enqueue_spawns` built its forced set then `erase`d each
entry from the queue, which is quadratic in the forced set's size — it now partitions in one pass.

## Budget, not proven

A 21×21 window is ~441 spawned chunks, on the order of 2,600 `MeshInstance3D` and 441
heightfield shapes. That is a genuinely new budget — `overworld_load_radius` must be sized
from a **measurement on a real device**, not assumed. Note also that 7×7 is the *render*
ring; the collision ring is `collision_ring` (1, i.e. 3×3), which is unchanged by any of
this.
