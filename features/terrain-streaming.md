# Terrain — Streaming Opt-ins

**Source:** `scripts/terrain_manager.gd` — the streamed-world seam (`load_radius`,
`stream_on_miss`, `road_source`, `spawn_budget`, `evict_to_cap`); see
[terrain.md](terrain.md) for the base chunked-terrain system this extends.

**Tests:** `tests/headless/test_terrain_manager_streaming.gd`

**This file documents a producer-less consumer.** `TerrainManager` kept a few opt-ins from
the deleted overworld hub. Nothing in production feeds them: free roam streams through its own
`TerrainStreamer` ([free-roam.md](free-roam.md)), and only tests assign `road_source`. The
bounded-world mode (`set_bounds`, the coastline taper, the `chunk_source` store, flat pads and
the region blend) has been deleted. All opt-ins are off by default, so behaviour is
bit-identical to a stage.

| Field / method | Default | What it does |
|---|---|---|
| `load_radius: int` | `RADIUS` (3) | Live ring radius. |
| `stream_on_miss: bool` | `false` | A cache miss **builds** instead of leaving a hole. |
| `cache_cap_mb: float` | `0.0` (off) | Cap on `cache_size_mb()`; over it, `evict_to_cap()` drops chunks. |
| `spawn_budget: int` | `0` (off) | Chunk spawns allowed per frame beyond the collision band. |
| `road_source: Object` | `null` | Duck-typed road network — the per-chunk road carve. Seat it **before** any chunk is built or cached. |

## The road carve (per chunk, not a global bake)

**No producer ships.** This section describes the contract a `road_source` object had to meet
when one existed (`OverworldRoads`, `scripts/overworld_roads.gd`, deleted with the overworld
hub) — a deterministic network over the rally pins plus the garage, queried per point by
`road_at`. `TerrainManager` consumes it through the duck-typed `road_source` (assigned directly),
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

The roadbed height is the terrain's own **pure noise** at `hit.foot` (the nearest point on the
centreline), blended in by `hit.road_weight` — exactly `bake_track`'s
`road_heights`/`road_blend` pairing. `road_weight` doubles as the flatten weight rather than a
second `height_bias_at` call, because the two are equal today and this is a per-vertex hot
loop; `OverworldRoads.height_bias_at` exists so the flatten band and the colour band *may*
diverge later, and the carve carries a comment saying what to change if they ever do. Noise
instances are built locally (`_build_noises`), not taken from the main-thread cache, because
`compute_chunk_data` runs on worker threads.

**Ordering:** it runs **inside generation** — after `builder.build()`, before quantisation and
before any cache write — so the mesh, the collision heightfield, `height_at` and the cached
bytes all derive from one number.

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

A chunk with no road still pays exactly one rect query and returns. Only the full-res grid is carved.

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
`spawn_budget > 0`: `_enqueue_spawns`
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
heightfield shapes. That is a genuinely new budget — `load_radius` must be sized
from a **measurement on a real device**, not assumed. Note also that 7×7 is the *render*
ring; the collision ring is `collision_ring` (1, i.e. 3×3), which is unchanged by any of
this.
