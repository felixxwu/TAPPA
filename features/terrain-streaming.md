# Terrain — Streaming Opt-ins

**Source:** `scripts/terrain_manager.gd` — the streamed-world seam (`load_radius`,
`stream_on_miss`, `evict_to_cap`); see
[terrain.md](terrain.md) for the base chunked-terrain system this extends.

**Tests:** `tests/headless/test_terrain_manager_streaming.gd`

**This file documents a producer-less consumer.** `TerrainManager` kept a few opt-ins from
the deleted overworld hub. Nothing in production feeds them: free roam streams through its own
`TerrainStreamer` ([free-roam.md](free-roam.md)), and the road carve, spawn budget and height
quantum are deleted. The bounded-world mode (`set_bounds`, the coastline taper, the `chunk_source` store, flat pads and
the region blend) has been deleted. All opt-ins are off by default, so behaviour is
bit-identical to a stage.

| Field / method | Default | What it does |
|---|---|---|
| `load_radius: int` | `RADIUS` (3) | Live ring radius. |
| `stream_on_miss: bool` | `false` | A cache miss **builds** instead of leaving a hole. |
| `cache_cap_mb: float` | `0.0` (off) | Cap on `cache_size_mb()`; over it, `evict_to_cap()` drops chunks. |

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

## Budget, not proven

A 21×21 window is ~441 spawned chunks, on the order of 2,600 `MeshInstance3D` and 441
heightfield shapes. That is a genuinely new budget — `load_radius` must be sized
from a **measurement on a real device**, not assumed. Note also that 7×7 is the *render*
ring; the collision ring is `collision_ring` (1, i.e. 3×3), which is unchanged by any of
this.
