@tool
extends Node3D
class_name TerrainManager
# Docs: features/terrain.md — update in the same change as this file.
# Tests: tests/headless/test_terrain.gd, tests/headless/test_terrain_lod.gd, tests/headless/test_terrain_noise.gd — extend in the same change. These are the PRIMARY ones, not all of them: before you change behaviour here, `grep -rn 'TerrainManager' tests/headless/` and read the assertions that pin what you are about to change (5 test files touch this script).

# Owns the procedural terrain: noise state, height sampling, and the lifecycle
# of the TerrainChunk children loaded around the car. The terrain is precomputed
# over a bounded corridor (see _chunk_cache / precompute_corridor); the load_radius-ring
# of chunks around the focus is a render/physics window into that cache, not a
# generation stream.
#
# OPEN-WORLD MODE (the overworld, features/terrain.md → "Open-world mode") is a set of
# additive, off-by-default opt-ins on top of that: a settable `load_radius`, `stream_on_miss`
# to build a miss instead of leaving a hole, `cache_cap_mb` LRU eviction, a duck-typed
# `chunk_source` store, and `set_bounds()` — a rectangular world that REPLACES the track
# corridor as the bounds source and switches on the coastline edge taper. With every default
# left alone the behaviour is bit-identical to a stage.

const CHUNK_M := 50.0                        # chunk edge length in metres
const CELL_M := 1.0                          # grid cell size (PS1 low-poly terrain)
const SAMPLES := int(CHUNK_M / CELL_M) + 1   # 51 height vertices per edge
const RADIUS := 3                            # DEFAULT ring radius -> (2*RADIUS+1)^2 = 7x7
# Cliffs & drops (features/terrain.md). The cliff bake is a distance field: each band
# vertex finds its nearest centerline point via a segment spatial hash whose cells are
# CLIFF_GRID_M wide (a whole number of terrain cells). Bigger cells → fewer ring
# expansions per vertex but fatter segment lists to scan; smaller → the reverse.
# ~24 m measured fastest for typical fade radii (a couple of rings, modest lists).
const CLIFF_GRID_M := 24.0
# Salt mixed into track_seed for the camber noise, so the whole stage (track shape,
# surface split, cliffs) is one deterministic function of track_seed.
const CLIFF_SEED_SALT := 0x5C1FF

const ChunkScript := preload("res://scripts/terrain_chunk.gd")

# Mesh-source arrays TerrainChunkBuilder.data() produces that are DEAD once
# TerrainLod.build_all has turned them into GPU meshes. cache_chunk erases them from
# the cached dict; TerrainChunk.apply_data must never fall back to rebuilding meshes
# from a cached dict (it checks for `vertices` and errors loudly instead).
const DEAD_AFTER_PREBAKE := ["vertices", "uvs", "colors", "uv2s", "indices"]

@export var noise_seed: int = 1337:
	set(value):
		noise_seed = value
		_rebuild_loaded()

@export var layers: Array[TerrainLayer] = []:
	set(value):
		layers = value
		_connect_layer_signals()
		_rebuild_loaded()

@export var texture_tile_per_meter: float = 0.125:
	set(value):
		texture_tile_per_meter = value
		_rebuild_loaded()

# Material applied to every chunk mesh. Set in main.tscn to the shared floor
# material so it survives runtime mesh assignment (see test_smoke).
@export var chunk_material: Material

# Track overlay: global cell coords (Vector2i) painted as track. The road is
# rendered by cross-fading the ground texture to the road texture in the shader
# (ps1_models.gdshader); the blend weight per vertex is carried in the vertex
# colour's ALPHA channel (see vertex_colors). `default_cell_color` is a plain
# RGB ground tint (white = grass unmodified). Setting these does NOT regenerate
# terrain — see set_track().
var default_cell_color: Color = Color(1, 1, 1)
# Weighted road fields, built by bake_track(), read by compute_chunk_data() /
# vertex_colors(). All weights ramp 1 (on the road) -> 0 (outer edge of the
# transition band); entries with weight 0 are omitted. Empty = no track.
var road_heights: Dictionary = {}   # vertex index (Vector2i) -> nearest road Y
var road_blend: Dictionary = {}     # vertex index -> height blend weight [0,1]
var track_weights: Dictionary = {}  # cell index -> colour blend weight [0,1]
# Per-cell tarmac-ness in [0,1] at the cell's nearest centerline point: 0 = gravel,
# 1 = tarmac, feathered across the single surface switch (see TrackSurface). Keyed
# like track_weights (same road/band cells); read by surface_grip_at() and baked
# into the mesh UV2.x by surface_uv2()/compute_chunk_data so the shader fades the
# gravel texture to the flat tarmac colour the same way the road fades from grass.
var track_surface: Dictionary = {}

# Cliffs & drops (features/terrain.md). A signed per-vertex height offset added on
# top of the noise height (before the road flatten) by bake_track's cliff pass, so a
# stage can run along a ledge — a wall rising on one side, ground falling away on the
# other. Keyed in the same GLOBAL vertex-index space as road_heights (seam-safe by
# construction). Empty when cliff_enabled is off or the effective height is 0.
var cliff_offsets: Dictionary = {}   # global vertex index (Vector2i) -> signed offset (m)
# Cliff params, set from GameConfig.apply_cliffs before bake_track (like the Lighting
# group). cliff_amount is the runtime per-event scale on cliff_max_height_m (0..1),
# written by RallySession from the event's cliffiness; cliff_seed derives the camber
# noise from the stage's track_seed.
var cliff_enabled: bool = false
var cliff_wavelength_m: float = 60.0
var cliff_gain: float = 1.6
var cliff_max_height_m: float = 8.0
var cliff_run_m: float = 6.0
var cliff_fade_m: float = 6.0
# Radius (m) of the post-bake morphological "open" that knocks down thin tall cliff
# walls — e.g. the wall a hairpin's inner crook would otherwise leave. Walls narrower
# than ~2× this in either axis are removed; wider cliffs/drops survive. 0 disables.
var cliff_open_radius_m: float = 4.0
var cliff_amount: float = 1.0
var cliff_seed: int = 1

# Baked terrain lighting. The terrain and the sun never move, so the fake
# directional+hemisphere shading (mirroring shaders/ps1_models_lit.gdshader) is
# computed ONCE per vertex at generation time and folded into the vertex
# colour's RGB — which the flat terrain shader already multiplies into ALBEDO.
# So it costs nothing per frame (unlike the car, which rotates and must light in
# its shader). light_amount 0 = flat (the bake becomes a no-op white multiply).
# Set from GameConfig's Lighting group by world.gd before build_initial().
var light_amount: float = 0.0
var sun_dir: Vector3 = Vector3(0.4, 0.9, 0.35).normalized()
var sun_color: Color = Color(0.5, 0.5, 0.5)
var sky_color: Color = Color(0.5, 0.5, 0.5)
var ground_color: Color = Color(0.35, 0.35, 0.35)

# Terrain LOD (features/terrain.md). The display mesh is decimated by distance:
# each loaded chunk carries one MeshInstance per TerrainLod.LOD_STRIDES level, and
# the engine picks the level by real camera distance via visibility_range (a HARD
# cutoff — the dithered fade is a Forward+/Mobile feature the Compatibility renderer
# ignores, and the alpha-hash discard would defeat early-Z on our opaque terrain).
# `lod_band_ends_m` is the far cutoff (metres) for each level EXCEPT the last (the
# coarsest draws to the ring edge); size = levels - 1. `lod_skirt_m` is the downward
# seam skirt that hides the crack between neighbours at different levels. Set from
# GameConfig.apply_terrain_lod. Collision is a per-frame-free near-band cost: only
# chunks within `collision_ring` (Chebyshev, in chunks) of the focus get live
# collision — farther loaded chunks are render-only.
var lod_band_ends_m: PackedFloat32Array = PackedFloat32Array([20.0, 45.0, 80.0, 130.0])
var lod_skirt_m: float = 3.0
var collision_ring: int = 1
# When true, far corridor chunks skip the full-res grid and prebake only the LOD
# levels they can ever display (loading-screen precompute optimisation). Off = full
# precompute (every chunk full-res). Set from GameConfig.apply_terrain_lod.
var precompute_prune_enabled: bool = true
# Extra reach (m) added to a chunk's closest-possible camera distance when deciding
# which LOD levels to keep. Must exceed the largest replay-camera offset from the car
# (replay_camera.gd ROADSIDE/FLYBY shots ~40 m) so a replay shot never exposes a
# pruned level. Errs toward keeping one extra finer level. Set from GameConfig.
var precompute_safety_slack_m: float = 40.0
# When true, the precompute does NOT prebake the FINEST (stride 1) LOD level for full-res
# corridor chunks; each spawned chunk builds it on demand once it enters the detail ring
# (detail_ring / TerrainChunk.set_finest_detail) and drops it again on the way out.
#
# Why: ArrayMesh.add_surface_from_arrays uploads to the RenderingServer the instant the
# mesh is created, so a prebaked level is resident VRAM whether or not the chunk is one of
# the (2*RADIUS+1)^2 currently spawned. Level 0 is ~3/4 of a chunk's mesh bytes and only a
# couple of chunks can ever DISPLAY it, so prebaking it for the whole corridor is the
# single largest avoidable GPU allocation at load (todo/mobile-web-performance.md 3.6).
# The coarser levels stay prebaked: they are small, and they are what far chunks draw.
#
# DEFAULT FALSE (prebake every level) — an on-demand rebuild is a measured ~6.2 ms of
# mid-drive hitch, which costs more than the VRAM it saves. See
# GameConfig.terrain_lazy_finest_lod (the shipping value, applied via apply_terrain_lod)
# and features/terrain.md -> "Lazy finest LOD level". Kept as the escape hatch for a
# device that runs out of VRAM; this node-level default mirrors the config default so an
# editor preview or ad-hoc test behaves like the real game.
var lazy_finest_lod: bool = false

# --- Open-world / overworld support (features/terrain.md → "Open-world mode") ------------
# Everything in this block defaults to today's stage behaviour: an unset `world_bounds`
# means "no bounded world", `load_radius` starts at RADIUS, and every opt-in flag is off.
# The overworld seats them through apply_overworld_bounds().

# LIVE ring radius in chunks: (2*load_radius+1)^2 chunks are spawned around the focus.
# Was a bare `const RADIUS` read directly by target_coords / _corridor_margin / detail_ring;
# all three now read THIS, with RADIUS as the default so a stage is bit-identical. The
# overworld raises it (GameConfig.overworld_load_radius).
# (`_collision_band_chunks` was already live — it derives from `collision_ring`, not the
# render radius. 7x7 is the RENDER ring; the collision ring is 3x3.)
# NOTE the cost is quadratic: 3 -> 49 chunks, 10 -> 441 chunks and ~441 heightfield shapes.
var load_radius: int = RADIUS

# When true, a coord that is missing from the chunk cache is BUILT (or read from
# `chunk_source`) instead of being left as a hole. Off for stages, where a hole plus a loud
# error is deliberately preferred over a mid-drive build hitch (see _reconcile).
var stream_on_miss: bool = false

# Cap on the chunk cache in MB. <= 0 disables eviction entirely (the stage default: the
# corridor cache is sized by the precompute and must never lose an entry, since a stage
# reads heights/lights/surface back out of it for the whole run). Only the overworld, whose
# resident window is a moving sub-rectangle of a much larger map, sets a cap.
var cache_cap_mb: float = 0.0

# Duck-typed chunk store (an OverworldCache, but deliberately NOT referenced by class so
# this file has no dependency on it — the same shape as drivetrain.terrain). Used only via
# has_method: `read(coord) -> Dictionary`, `write(coord, heights, lights) -> bool`,
# `has(coord) -> bool`. null = no store, which is every stage.
var chunk_source: Object = null

# Duck-typed OVERWORLD ROAD NETWORK (an OverworldRoads, deliberately NOT referenced by class
# so this file keeps no dependency on it — same convention as `chunk_source`). Used only via
# has_method: `segments_in_rect(Rect2) -> Array`, `road_at(x, z) -> Dictionary`,
# `influence_m() -> float`. null = no network, which is EVERY STAGE: with it null the road
# carve in compute_chunk_data and the network branch of surface_at are both skipped, so stage
# output is byte-for-byte what it was before the carve existed. Seat it with set_road_source().
var road_source: Object = null

# Duck-typed REGION FIELD (an Overworld.RegionBlendSource, deliberately NOT referenced by class
# so this file keeps no dependency on OverworldRegion — same convention as `chunk_source` and
# `road_source`). Used only via has_method: `region_rank_at(x, z) -> float`, which answers a
# 0..1 CANONICAL REGION RANK at a world XZ (see _apply_region_blend for what the rank means).
# null = no region field, which is EVERY STAGE: with it null the UV2.y channel is never written
# and a stage chunk's bytes are exactly what they were before this existed. Seat it with
# set_region_source().
var region_source: Object = null

# Duck-typed FLAT PAD SET (an OverworldPads, deliberately NOT referenced by class so this file
# keeps no dependency on it — same convention as `chunk_source` / `road_source` /
# `region_source`). Used only via has_method: `pad_at(x, z) -> Vector2` (.x = flatten weight,
# .y = target height) and `pads_in_rect(Rect2) -> Array` (the per-chunk reject). null = no
# pads, which is EVERY STAGE: with it null `pad_height` is one bool read and the grid pass is
# one early return, so stage output is byte-for-byte what it was before pads existed. Seat it
# with set_pad_source(). See features/terrain.md -> "Flat pads".
var pad_source: Object = null

# Keep the RGB8-encoded baked light (`l0_light`) in the cached dict even when
# lazy_finest_lod is off. `free_load_only_data()` erases the full-precision `lights`, so a
# chunk generated mid-drive would otherwise have no light left to persist. Auto-enabled by
# apply_overworld_bounds / set_chunk_source; left FALSE for stages on purpose — it is ~7.8 KB
# per chunk of cache the stage path has no use for.
var capture_encoded_light: bool = false

# The bounded world (world-XZ Rect2), or an empty rect for "unbounded" — a stage. When set
# it REPLACES the track corridor as the answer to chunk_class / corridor_complete /
# corridor_bounds, and switches on the coastline edge taper. See set_bounds().
var world_bounds: Rect2 = Rect2()
# Coastline taper (D9). `edge_taper_m` is how far in from `world_bounds` the falloff starts;
# at the perimeter the height is driven to (water_level_m - edge_depth_m). 0 taper = off.
var edge_taper_m: float = 0.0
var edge_depth_m: float = 0.0
var water_level_m: float = 0.0
# Constant surface weights (road_weight, tarmac_weight) returned by surface_at inside a
# bounded world, where there is no bake_track to fill track_weights / track_surface.
# All-grass/gravel — slice 1 has no roads. Vector2(0, 0) is exactly what an unbaked stage
# returns too, so this is only a hook for slice 4 to override.
var bounds_surface: Vector2 = Vector2.ZERO
# True once stream_on_miss has actually fired, so the "the cache was mis-sized" warning is
# printed ONCE rather than per frame (a crossing re-visits the same coords every frame).
var _miss_stream_logged := false
var stream_on_miss_builds: int = 0
# How many chunks were satisfied by READING the attached store (the on-disk precompute) during
# reconcile. This is the healthy supply path in a bounded world — contrast
# `stream_on_miss_builds`, which counts chunks GENERATED because nothing had them.
var store_reads: int = 0
# Height lattice step in metres for generated chunks, 0 = off (every stage). Set by the overworld
# to the step its chunk store round-trips through. See _apply_height_quantum.
var height_quantum: float = 0.0
# Chunk SPAWNS permitted per frame beyond the collision band. 0 = off (spawn the whole ring row
# in one call, today's stage behaviour, byte-for-byte). Set by apply_overworld_bounds.
var spawn_budget: int = 0
# Coords wanted but not spawned yet, nearest-first. Drained by _drain_spawn_queue.
var _spawn_queue: Array[Vector2i] = []

# PER-STAGE TIMING, off by default. When true, _timed_process records how long each of its three
# stages took into the three fields below, for a host's frame-spike log to attribute.
#
# WHY THIS EXISTS: the overworld's spike log (Overworld._log_frame_spike) times its OWN per-frame
# stages and lumps everything else into `other` — and its comment says so, naming "the terrain's
# own chunk work inside update_focus" as invisible to it. That is the most likely place for a
# streaming hitch to live, so the one tool built to attribute spikes could not see the prime
# suspect. PerfLog does track this node, but it averages over a whole second, which is exactly
# how a 40 ms hitch disappears.
#
# Gated rather than always-on because three clock reads per frame on the shipping path is the
# same waste that was just removed from Overworld._process.
var stage_timing := false
## Microseconds the last timed frame spent resolving the focus + reconciling the ring.
var last_focus_us := 0
## Microseconds the last timed frame spent draining deferred chunk spawns.
var last_spawn_drain_us := 0
## Microseconds the last timed frame spent building finest-LOD levels.
var last_detail_drain_us := 0
# Debug chunk-border overlay (H toggle, debug builds). Lazily created on first use.
var _border_debug: ChunkBorderDebug = null

# Node whose position drives chunk loading (the car). Resolved lazily and then
# CACHED — _focus_node() runs every rendered frame, and re-walking the scene tree
# via get_node_or_null() per frame is the pattern this project bans on low-end
# mobile (see the same fix in engine_audio.gd's resolved-once car/engine refs).
# Assigning focus_path drops the cache so a retarget still resolves.
@export var focus_path: NodePath = NodePath("../Car"):
	set(value):
		focus_path = value
		_focus_cached = null
var _focus_cached: Node3D = null

# coord (Vector2i) -> TerrainChunk
var _chunks: Dictionary = {}
var _last_focus_coord: Vector2i = Vector2i(2147483647, 0)  # force first reconcile
# Loaded chunks inside the detail ring still waiting for their lazily-built finest LOD
# level, nearest first. Drained a FEW PER FRAME rather than all at once (_drain_detail_
# queue): a full-res level-0 rebuild is several ms of GDScript, and crossing a chunk
# boundary brings a whole new column into the ring at the same instant — building them
# together would be a visible stutter, which is exactly what the prebake existed to avoid.
# Deferring them a few frames costs nothing: a chunk only ENTERS the ring about a chunk's
# width outside level 0's visibility band, and until its level 0 lands the next coarser
# level covers the near distance (see TerrainChunk._apply_level_bands), so the worst case
# is a fraction of a second of slightly coarser ground, never a hole.
var _detail_queue: Array[Vector2i] = []
# O(1) membership mirror of _detail_queue (coord -> true). _reconcile used to test membership
# with a linear `_detail_queue.has(coord)` inside a loop over every loaded chunk — fine at 49
# chunks, quadratic at 441. Every mutation of _detail_queue must keep this in step.
var _queued_for_detail: Dictionary = {}
# Finest-level rebuilds allowed per rendered frame. 1 clears a boundary crossing's worth
# in a handful of frames, well before the car can reach them.
var detail_builds_per_frame: int = 1
# When true, _ready does NOT build the initial ring — a parent (world.gd) builds
# it via build_initial() after the track is applied, so flattening is baked in on
# the first build. The editor always previews terrain regardless of this flag.
@export var defer_initial_build: bool = false
# Armed by _ready when the build is deferred, cleared by build_initial(). While armed,
# _process must NOT reconcile the ring: the host is still generating (the corridor cache
# is empty and the road is not carved yet), so _reconcile would take its on-demand branch
# and build all (2*RADIUS+1)^2 chunks from raw noise — on the very frames the loading
# yields were meant to give to generation. Those chunks are then thrown away twice over
# (set_track re-setup()s every loaded chunk after the carve, and the precompute caches the
# same coords again), and because an on-demand chunk builds every LOD level itself it never
# joins the lazy finest-LOD path, so it pins level-0 VRAM until it first despawns.
# build_initial() owns the ring; nothing else may create it. See features/terrain.md ->
# "Who builds the initial ring".
var _initial_pending := false
# Total chunk nodes spawned (mesh + collision built on the main thread). Read by
# PerfOverlay to correlate frame-time spikes with terrain integration work.
var integrations_total: int = 0
# Of those, how many were built from raw noise by _reconcile's on-demand branch instead of
# coming out of the corridor cache. Legitimately non-zero for the editor preview and for
# tests that never precompute; on a real load it must stay 0 (the initial ring is cached).
var on_demand_builds: int = 0

# Main-thread noise cache for height_at(): FastNoiseLite instances are expensive
# to build, and height_at used to rebuild all layers on every call (it is hit
# once per centerline sample in bake_track). The cache is invalidated by every
# terrain mutation path via _rebuild_loaded.
#
# CORRECTED: this used to say the cache is "NOT shared with the worker threads" because
# compute_chunk_data builds its own instances. There are no worker threads anywhere in the
# terrain path (see _build_noises), so this pair is simply THE noise set, and the generation
# passes should use it rather than minting their own — _apply_road_carve now does.
var _cached_noises: Array[FastNoiseLite] = []
var _cached_amplitudes: PackedFloat32Array = PackedFloat32Array()
var _noise_cache_valid := false

# Precomputed terrain: coord -> the data dict compute_chunk_data returns. Filled
# behind the loading screen (world.gd) for the whole reachable corridor — sized from
# the track-progress leash, so it covers every chunk the level realistically requests
# (see _reconcile for the rare excursion beyond it). Runtime chunk loads are then
# cache lookups (~0.2 ms node build), and height_at/light_at serve from it (the terrain
# the player actually sees: road flattening included, unlike the raw noise).
var _chunk_cache: Dictionary = {}

# Load-only data frees (see features/loading.md → the load_finished hook, and
# todo/mobile-web-performance.md 1.7 / 2.7). Both are SENTINELS as much as flags:
# the freed data is read through `.get(..., default)` accessors that would silently
# return a plausible-but-wrong value, so every post-free read must be loud.
var _lights_freed := false          # per-chunk baked light dropped from _chunk_cache
var _bake_fields_freed := false     # road_heights / road_blend / cliff_offsets dropped

# VRAM instrumentation for the corridor prebake (see _log_precompute_vram).
var _vram_at_corridor_mb := 0.0
var _vram_logged := false

# coord -> {"l_min": int, "full_res": bool}. Populated by corridor_coords, kept across
# set_corridor's cache clear so _rebuild_loaded reproduces the same near/far split.
var _corridor_class: Dictionary = {}
# coord -> true; a real-play cache miss is logged once (crossings re-visit per frame).
var _logged_misses: Dictionary = {}

# Resolution class for a corridor coord; safe full-res default for unknown coords
# (editor/tests/on-demand builds never lose detail or collision).
#
# In a BOUNDED world there is no corridor to classify against, and pruning is not merely
# unavailable but wrong: the car can reach anywhere, so no chunk can be called "far from the
# route". So every chunk is full-res and in the collision band — which is the same answer the
# unknown-coord default already gives, stated explicitly so it is not read as an accident.
func chunk_class(coord: Vector2i) -> Dictionary:
	if has_bounds():
		return {"l_min": 0, "full_res": true, "in_collision_band": true}
	return _corridor_class.get(coord, {"l_min": 0, "full_res": true})


# --- Bounded world (the overworld) --------------------------------------------------------

# Declare a rectangular world in world-XZ metres. This REPLACES the track corridor as the
# bounds source: chunk_class, corridor_complete() and corridor_bounds() all answer from it,
# surface_at returns `bounds_surface`, and the coastline taper switches on. Pass an empty
# Rect2 (or call clear_bounds) to go back to stage behaviour.
#
#  - `taper_m` / `depth_m` / `water_y` are GameConfig.overworld_edge_taper_m /
#    overworld_edge_depth_m / track_water_level_m. 0 taper leaves the taper off.
#
# Passed in rather than read off Config so this @tool script stays editor-safe and pure,
# the same convention as the light_* and cliff_* params.
func set_bounds(rect: Rect2, taper_m: float = 0.0, depth_m: float = 0.0,
		water_y: float = 0.0) -> void:
	world_bounds = rect.abs()
	edge_taper_m = maxf(0.0, taper_m)
	edge_depth_m = maxf(0.0, depth_m)
	water_level_m = water_y
	# A bounded world has no bake, so `lights` is the ONLY light source the cache will ever
	# carry — and its chunks are generated in play, not behind a one-shot loading screen.
	# Both frees below are corridor-shaped ideas that do not apply, so lift them.
	_lights_freed = false
	_bake_fields_freed = false


func clear_bounds() -> void:
	world_bounds = Rect2()
	edge_taper_m = 0.0
	edge_depth_m = 0.0


func has_bounds() -> bool:
	return world_bounds.size.x > 0.0 and world_bounds.size.y > 0.0


# Seat every overworld terrain knob from a GameConfig in ONE place, so the streaming
# radius, the build budget and the coastline can't be wired up half-way. `rect` is the world
# rectangle the caller derives from cfg.overworld_size_m (centred on the origin, matching the
# spec's world_xz(map_pos) convention).
func apply_overworld_bounds(cfg: GameConfig, rect: Rect2) -> void:
	load_radius = maxi(1, cfg.overworld_load_radius)
	detail_builds_per_frame = maxi(1, cfg.overworld_chunk_build_budget)
	# The same budget bounds CHUNK spawns, which is what actually caused the boundary hitch —
	# see the note in _reconcile. Stages leave this 0 and keep spawning a whole row per crossing.
	spawn_budget = maxi(1, cfg.overworld_chunk_build_budget)
	# NO GENERATE-ON-MISS. A miss leaves a visible HOLE and logs loudly instead.
	#
	# This was on, and it was the wrong call. The overworld precomputes its whole map, so a miss
	# means something is genuinely broken (an under-sized precompute, a stale cache, a window
	# reaching outside what was written) — and filling it silently converted a bug into a ~140 ms
	# frame hitch per boundary crossing, which reads as "the game stutters" rather than "the
	# cache is undersupplied". A hole is diagnosable at a glance; a hitch is not.
	#
	# Same reasoning the corridor path already uses for an in-corridor miss: prefer the hole.
	stream_on_miss = false
	capture_encoded_light = true
	set_bounds(rect, cfg.overworld_edge_taper_m, cfg.overworld_edge_depth_m,
		cfg.track_water_level_m)


# Attach the duck-typed chunk store (see `chunk_source`). Also arms the encoded-light
# capture, because a store that persists a light-less chunk would poison itself: the
# invalidation key can never tell a light-less record from a good one.
func set_chunk_source(source: Object) -> void:
	chunk_source = source
	if source != null:
		capture_encoded_light = true


# Attach (or clear, with null) the duck-typed road network (see `road_source`). Must be seated
# BEFORE any chunk is built or cached: the carve rewrites `heights`, so a chunk generated
# without a network and one generated with it are different terrain, and the chunk_source
# invalidation key is the only thing that can tell them apart (OverworldRoads.network_hash is
# what the overworld cache folds in for exactly this reason). Changing it later does NOT
# retro-carve already-cached chunks.
func set_road_source(source: Object) -> void:
	road_source = source
	_road_surf_valid = false


# Attach (or clear, with null) the duck-typed region field (see `region_source`). Must be seated
# BEFORE any chunk is built or cached, for exactly the reason set_road_source states: the baked
# UV2.y changes the stored bytes, so a chunk generated with a region field and one generated
# without it are different data and only the chunk_source invalidation key can tell them apart
# (Overworld._open_chunk_cache folds RegionBlendSource.stamp() in for that reason). Changing it
# later does NOT retro-bake already-cached chunks.
func set_region_source(source: Object) -> void:
	region_source = source


# Attach (or clear, with null) the duck-typed flat-pad set (see `pad_source`).
#
# TWO RULES, both load-bearing:
#
#  1. Seat it BEFORE any chunk is built or cached, for exactly the reason set_road_source
#     states: the flatten rewrites `heights`, so a chunk generated with pads and one without
#     are different terrain and only the chunk_source invalidation key can tell them apart
#     (Overworld._open_chunk_cache folds OverworldPads.stamp() in for that reason). Changing
#     it later does NOT retro-flatten already-cached chunks.
#  2. Seat it AFTER the pad set has resolved its own levels. Each pad's level is the terrain's
#     PURE generated height at the pad centre, sampled through `_noise_height_at` — and
#     `_noise_height_at` applies the pads (see `pad_height`). Attaching the source first and
#     sampling second would feed the pads their own output.
#
# A source missing `pad_at` is REJECTED here (stored as null) rather than guarded on every
# call: pad_height runs per vertex and per height query, and one has_method per vertex is a
# cost the null check already avoids.
func set_pad_source(source: Object) -> void:
	if source != null and not source.has_method("pad_at"):
		push_warning("terrain: pad source has no pad_at(x, z) — ignored")
		pad_source = null
		return
	pad_source = source


# The coastline falloff (D9). `h` is the generated height at world (x, z); the return value
# is that height driven toward (water_level_m - edge_depth_m) as the point approaches the
# perimeter of `world_bounds`. No-op unless a bounded world with a positive taper is set, so
# a stage never pays for it (one bool read).
#
# Applied INSIDE height generation — see _noise_height_at (the pure-noise fallback) and
# compute_chunk_data (the generated grid). Both call THIS one function, so the cached grid,
# the HeightMapShape3D built from it and the height_at query cannot disagree about where the
# ground is at the coast.
#
# Beyond the bounds the inward distance clamps at 0, so the sea floor is a hard flat shelf at
# full depth rather than continuing to fall — the "let the sea be the answer" option in the
# spec's "Beyond the edge" note.
func taper_height(h: float, x: float, z: float) -> float:
	if edge_taper_m <= 0.0 or not has_bounds():
		return h
	var inward: float = minf(
		minf(x - world_bounds.position.x, world_bounds.end.x - x),
		minf(z - world_bounds.position.y, world_bounds.end.y - z))
	var t := clampf(inward / edge_taper_m, 0.0, 1.0)
	if t >= 1.0:
		return h
	# Smoothstep so the shoreline meets the inland noise with no crease.
	return lerpf(water_level_m - edge_depth_m, h, t * t * (3.0 - 2.0 * t))


# The FLAT PAD flatten. `h` is the generated height at world (x, z); the return value is that
# height driven toward the level of whichever pad covers the point, feathered to nothing at
# the pad's outer edge. No-op (one null check) without a pad source, which is every stage.
#
# Applied INSIDE height generation, in BOTH places, exactly as taper_height is — the grid pass
# (_apply_pad_flatten) and the pure-noise fallback (_noise_height_at). That symmetry is the
# whole point and is deliberate:
#
#   the taper is in _noise_height_at; the ROAD CARVE IS NOT (a known latent bug — a foliage or
#   placement query near a road gets the uncarved height). A pad exists precisely so that
#   things PLACED on it — the garage building, a zone's tube and marker, a parked ghost car,
#   the default spawn, the foliage `dry` test — sit level. Every one of those goes through
#   height_at, which falls back to _noise_height_at for any coord the chunk cache has not
#   built yet. Leaving the pad out of the generator would therefore break the pad exactly
#   where it is used, so the pad follows the taper, not the carve.
#
# Pure function of position, so the cached grid, the HeightMapShape3D, height_at and the
# stored bytes cannot disagree about where the pad's ground is.
func pad_height(h: float, x: float, z: float) -> float:
	if pad_source == null:
		return h
	var hit: Vector2 = pad_source.call("pad_at", x, z)
	if hit.x <= 0.0:
		return h
	return lerpf(h, hit.y, hit.x)
# The coords the cache covers, kept so _rebuild_loaded can refill after a
# terrain-param change (seed/layers) instead of serving stale arrays.
var _corridor_coords: Array[Vector2i] = []

# Transient scratch for bake_track's unified nearest-segment search (_nearest_seg). Set
# up at the top of a bake and only valid for its duration — never read outside a bake.
# Per-segment: endpoint (ax,ay), delta (dx,dy), 1/len², arc length at start, unit tangent.
var _cv_ax: PackedFloat32Array
var _cv_ay: PackedFloat32Array
var _cv_dx: PackedFloat32Array
var _cv_dy: PackedFloat32Array
var _cv_inv: PackedFloat32Array
var _cv_len: PackedFloat32Array
var _cv_arc: PackedFloat32Array
var _cv_tx: PackedFloat32Array
var _cv_ty: PackedFloat32Array
var _cv_grid: Array           # spatial-hash cell (flat) -> PackedInt32Array of segment idx
var _cv_gw: int
var _cv_gh: int
var _cv_gx0: int
var _cv_gz0: int
var _cv_G: float
var _cv_R: int
# Out-params of _nearest_seg (avoids a per-call Array allocation in the hot path).
var _cv_best_t: float
var _cv_best_dsq: float
# Band radii + cliff parameters for one bake, so bake_track's per-block and cliff-emit steps can
# live in their own functions instead of nesting five deep inside it. Same lifetime rule as the
# rest of the _cv_* scratch: written at the top of a bake, never read outside one.
var _cv_f_inner: float        # road half-width — full flatten weight at/inside this
var _cv_f_outer: float        # outer edge of the flatten transition band
var _cv_f_outer_sq: float
var _cv_outer_sq: float       # search band (whichever of flatten/cliff reaches furthest), squared
var _cv_cliffs: bool
var _cv_eff_max: float
var _cv_c_inner: float
var _cv_c_rise: float
var _cv_c_outer: float
var _cv_camber_step: float
var _cv_camber_lut: PackedFloat32Array
var _cv_lut_n: int
# Vertex-grid geometry: origin in GLOBAL vertex indices, and the flat field's width/height.
var _cv_vx0: int
var _cv_vz0: int
var _cv_vw: int
var _cv_vh: int
var _cv_Gc: int               # terrain vertices per spatial-hash cell edge
# The flat cliff-offset field (only allocated when cliffs are active) and the bbox, in local
# vertex indices, of the part of it that was actually written. A MEMBER rather than a parameter
# on purpose: PackedFloat32Array is a copy-on-write value type, so passing it into the per-block
# function would copy the whole field on the first write of every block.
var _cv_off: PackedFloat32Array
var _cv_tvx0: int
var _cv_tvx1: int
var _cv_tvz0: int
var _cv_tvz1: int


func _connect_layer_signals() -> void:
	for layer in layers:
		if layer == null:
			continue
		if not layer.changed.is_connected(_rebuild_loaded):
			layer.changed.connect(_rebuild_loaded)


# A layerless manager: no noise, so height_at is a flat y = 0 everywhere. Used by
# the podium / HQ dressing to seat Foliage instances on level ground.
static func flat() -> TerrainManager:
	var tm := TerrainManager.new()
	tm.layers = [] as Array[TerrainLayer]
	return tm


func _default_layers() -> Array[TerrainLayer]:
	var result: Array[TerrainLayer] = []
	for params in [[60.0, 1.5], [15.0, 0.4], [3.0, 0.1]]:
		var layer := TerrainLayer.new()
		layer.wavelength_m = params[0]
		layer.amplitude_m = params[1]
		result.append(layer)
	return result


func _is_valid_layer(layer: TerrainLayer) -> bool:
	return layer != null and layer.wavelength_m > 0.0


func _make_noise(layer_index: int) -> FastNoiseLite:
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_PERLIN
	noise.fractal_type = FastNoiseLite.FRACTAL_NONE
	noise.seed = noise_seed + layer_index
	noise.frequency = 1.0 / layers[layer_index].wavelength_m
	return noise


# Build a matched (noises, amplitudes) pair, one entry per valid layer, as
# [Array[FastNoiseLite], PackedFloat32Array].
#
# CORRECTED: this used to say "worker threads call this so they get their own FastNoiseLite
# instances". THERE ARE NO WORKER THREADS in terrain generation — `WorkerThreadPool`, `Thread`
# and `Mutex` appear in exactly one file in scripts/ (cloud/google_sign_in.gd), and the target
# platforms include single-threaded ones (mobile web), so threading is not an escape hatch here
# either. Every caller runs on the main thread and should therefore go through
# `_ensure_noise_cache`, which builds this pair ONCE and hands the same instances out; building
# a fresh set per chunk was pure allocation on the hottest generation path. `TerrainChunkBuilder`
# (line ~48) still calls it per chunk on the same stale reasoning and should be switched to the
# cache too — left alone here only because that is the GENERATE path, not the read path this
# change is about.
func _build_noises() -> Array:
	var noises: Array[FastNoiseLite] = []
	var amplitudes: PackedFloat32Array = PackedFloat32Array()
	for i in layers.size():
		if not _is_valid_layer(layers[i]):
			continue
		noises.append(_make_noise(i))
		amplitudes.append(layers[i].amplitude_m)
	return [noises, amplitudes]


# Sum the layer noises at a world XZ into a height. noises/amplitudes are a
# matched pair from _build_noises (or the main-thread cache).
static func _sample_height(noises: Array, amplitudes: PackedFloat32Array, x: float, z: float) -> float:
	var h := 0.0
	for i in noises.size():
		h += noises[i].get_noise_2d(x, z) * amplitudes[i]
	return h


# Lazily (re)build the main-thread noise cache. Invalidated by _rebuild_loaded.
func _ensure_noise_cache() -> void:
	if _noise_cache_valid:
		return
	var pair := _build_noises()
	_cached_noises = pair[0]
	_cached_amplitudes = pair[1]
	_noise_cache_valid = true


# PURE noise height — the generator. bake_track and chunk building MUST use
# this (the flattening is derived from it; cache-first there would be circular).
func _noise_height_at(x: float, z: float) -> float:
	_ensure_noise_cache()
	# The coastline taper is part of GENERATION, not presentation, so it belongs here — this
	# is the path height_at falls back to for any uncached coord, and it must produce the same
	# number compute_chunk_data baked into the mesh and the collision heightfield. No-op
	# outside a bounded world (see taper_height).
	#
	# PAD THEN TAPER, the same order compute_chunk_data applies them in, so the generator and
	# the baked grid agree: a pad may not hold land up out of the sea at the map edge.
	var h := _sample_height(_cached_noises, _cached_amplitudes, x, z)
	return taper_height(pad_height(h, x, z), x, z)


# Public height query — CACHE-FIRST. The cached grid is the terrain the player
# actually sees and collides with (road flattening included); the noise is just
# the helper that created it. Outside the corridor (distant backdrop, editor,
# tests without precompute) this silently falls back to pure noise.
func height_at(x: float, z: float) -> float:
	var cached := _cached_height_at(x, z)
	if not is_nan(cached):
		return cached
	return _noise_height_at(x, z)


# Baked height WITHOUT needing the chunk cache: noise + cliff offset + road flatten,
# read straight from the bake fields at the nearest L0 vertex. Reproduces what
# TerrainChunkBuilder._sampled_height / _vertex_row_* produce, so it agrees with the
# terrain the player gets — but it is available as soon as bake_track has run, where
# height_at would still be falling back to pure noise (empty chunk cache).
#
# Exists for the loading screen's water preview, which wants the real (cliff-dropped)
# waterline painted BEFORE the chunk precompute — the longest stage — rather than
# after it. Vertex-nearest, not bilinear: the preview samples on a coarse lattice
# anyway, so sub-cell accuracy would be wasted work.
#
# Falls back to height_at once free_load_only_data() has dropped the bake fields
# (they only live through loading), so a late caller degrades rather than lying.
func baked_height_at(x: float, z: float) -> float:
	if _bake_fields_freed:
		return height_at(x, z)
	var h := _noise_height_at(x, z)
	var gv := Vector2i(roundi(x / CELL_M), roundi(z / CELL_M))
	h += float(cliff_offsets.get(gv, 0.0))
	if road_blend.has(gv):
		h = lerpf(h, float(road_heights[gv]), float(road_blend[gv]))
	return h


# Scratch outputs for _resolve_bilinear — reused across calls instead of returning
# a Dictionary, so the cache-first accessors below (called per physics frame via
# height_at) stay allocation-free. Value types (Vector2i / int / float) live inline
# in the fields, no heap churn. Safe as bare instance state: these accessors run one
# at a time on the main thread — which is the ONLY thread: there is no threaded chunk build (see
# _build_noises), so this is about not nesting two reads, not about concurrency.
var _bl_coord: Vector2i
var _bl_xi: int
var _bl_zi: int
var _bl_fx: float
var _bl_fz: float


# Resolves the cached-grid chunk + bilinear cell indices/fractions for world XZ into
# the _bl_* scratch fields. Returns false when the point isn't covered (empty cache
# or the owning chunk isn't loaded) so callers fall back. No allocation.
func _resolve_bilinear(x: float, z: float) -> bool:
	if _chunk_cache.is_empty():
		return false
	var coord := chunk_coord_for(Vector3(x, 0.0, z))
	if not _chunk_cache.has(coord):
		return false
	# Coarse chunks carry no full-res grid — treat as "not covered" so height_at /
	# light_at fall through to the live noise path (visually identical out there: no
	# road/cliff bake happens in coarse regions, so the cached value would equal noise).
	var grid: PackedFloat32Array = _chunk_cache[coord].get("heights", PackedFloat32Array())
	if grid.size() != SAMPLES * SAMPLES:
		return false
	var lx := (x - coord.x * CHUNK_M) / CELL_M
	var lz := (z - coord.y * CHUNK_M) / CELL_M
	_bl_coord = coord
	_bl_xi = clampi(floori(lx), 0, SAMPLES - 2)
	_bl_zi = clampi(floori(lz), 0, SAMPLES - 2)
	_bl_fx = clampf(lx - _bl_xi, 0.0, 1.0)
	_bl_fz = clampf(lz - _bl_zi, 0.0, 1.0)
	return true


# Bilinear height from the cached chunk grid; NAN when the point isn't covered.
func _cached_height_at(x: float, z: float) -> float:
	if not _resolve_bilinear(x, z):
		return NAN
	var heights: PackedFloat32Array = _chunk_cache[_bl_coord]["heights"]
	var xi := _bl_xi
	var zi := _bl_zi
	var a := heights[zi * SAMPLES + xi]
	var b := heights[zi * SAMPLES + xi + 1]
	var c := heights[(zi + 1) * SAMPLES + xi]
	var d := heights[(zi + 1) * SAMPLES + xi + 1]
	return lerpf(lerpf(a, b, _bl_fx), lerpf(c, d, _bl_fx), _bl_fz)


# Baked light tint at a world XZ (main thread), mirroring the per-vertex bake in
# compute_chunk_data so the distant backdrop (DistantTerrain) shades identically
# to the near chunks. White (a no-op) when light_amount is 0. CACHE-FIRST like
# height_at; falls back to a fresh noise-based bake when uncovered or unlit.
func light_at(x: float, z: float) -> Color:
	if light_amount <= 0.0:
		return Color(1, 1, 1)
	var cached := _cached_light_at(x, z)
	if cached.a >= 0.0:
		return cached
	_ensure_noise_cache()
	return _bake_light(_cached_noises, _cached_amplitudes, x, z)


# Bilinear baked light from the cache; alpha -1 signals "not covered" (Color has
# no NAN sentinel). Falls through when the chunk is unlit (empty lights array).
func _cached_light_at(x: float, z: float) -> Color:
	if not _resolve_bilinear(x, z):
		return Color(0, 0, 0, -1.0)
	if _lights_freed and has_bounds():
		# Belt-and-braces: free_load_only_data never latches the sentinel in a bounded world, so
		# reaching here means something else set it (a stage that later declared bounds). Fall
		# through to the live re-bake silently — in an open world light_at IS a repeated query,
		# so the error below would be per-frame spam rather than a signal.
		return Color(0, 0, 0, -1.0)
	if _lights_freed:
		# LOUD on purpose: the baked light is gone, so this call is about to fall back
		# to a fresh live-noise bake — a plausible but subtly different colour, with no
		# other symptom. Every shipped light_at caller is a one-shot build that runs
		# BEFORE load_finished; a caller landing here is a real bug (see free_load_only_data).
		push_error("light_at called after the baked terrain light was freed at load_finished "
			+ "— the value is a live-noise re-bake, not the baked one")
		return Color(0, 0, 0, -1.0)
	var lights: PackedColorArray = _chunk_cache[_bl_coord].get("lights", PackedColorArray())
	if lights.is_empty():
		return Color(0, 0, 0, -1.0)
	var xi := _bl_xi
	var zi := _bl_zi
	var a := lights[zi * SAMPLES + xi]
	var b := lights[zi * SAMPLES + xi + 1]
	var c := lights[(zi + 1) * SAMPLES + xi]
	var d := lights[(zi + 1) * SAMPLES + xi + 1]
	var out := a.lerp(b, _bl_fx).lerp(c.lerp(d, _bl_fx), _bl_fz)
	out.a = 1.0
	return out



# Pure CPU work for one chunk: heights + mesh arrays. Reads only the
# (runtime-static) noise params. The row-by-row work itself lives in
# TerrainChunkBuilder (kept out of this file for size).
func compute_chunk_data(coord: Vector2i) -> Dictionary:
	var builder := TerrainChunkBuilder.new(self, coord)
	builder.build()
	var data := builder.data()
	# ORDER IS LOAD-BEARING: carve the road FIRST, taper the coast SECOND, so the taper WINS.
	# A road that runs down to the shore must not lift the beach back out of the sea — see
	# _apply_road_carve.
	_apply_road_carve(data, true)
	# The FLAT PADS, between the carve and the taper. See _apply_pad_flatten for the full
	# argument; in one line each: AFTER the carve, because a pad must win over a road inside
	# it (the forecourt is level and the road merely paints across it) and because the carve's
	# own roadbed target is already pulled toward the pad level so the two meet without a step;
	# BEFORE the taper, because the taper must still win at the coast.
	_apply_pad_flatten(data)
	_apply_edge_taper(data)
	# Region rank into UV2.y. Touches no height, so its position relative to the carve and the
	# taper is free; it sits here — after both, before the quantum — so the "quantum is LAST"
	# rule below stays the single ordering statement anyone has to remember.
	_apply_region_blend(data)
	# LAST, after the carve and the taper have both had their say: snap heights onto the lattice
	# the chunk store round-trips through, so the resident grid and the stored record are the SAME
	# numbers. Doing it here rather than in the host is what makes that true — the host used to
	# snap a separate copy on its way to disk, leaving the resident grid (and therefore the mesh,
	# the HeightMapShape3D and every height_at read) off-lattice, so the terrain you drove on one
	# launch differed from the next by up to half a step.
	_apply_height_quantum(data)
	return data


# --- The shared preamble of the five _apply_* chunk modifiers -------------------------------
#
# Every one of them starts by unpacking the same arrays out of the chunk dict, early-outing on a
# size mismatch, and (three of them) re-deriving the chunk's world rect from `center` and CHUNK_M.
# `_chunk_view` is that preamble, ONCE. Each modifier still owns its own SOURCE guard (a null
# `pad_source`, `height_quantum <= 0.0`, …) at the call site — those are about whether the pass is
# configured at all, not about whether the chunk is usable.
#
# WHICH ARRAYS/GUARDS a modifier wants is passed in as a `needs` bitmask, because the five are NOT
# identical and flattening the differences would silently change which chunks get skipped:
#
#   * _apply_edge_taper and _apply_height_quantum have NO stride guard — a coarse (stride > 1)
#     chunk still gets tapered and still gets quantised, and must keep doing so. Only the three
#     passes with the "full-res grids only" LOD note pass VIEW_FULL_RES.
#   * _apply_region_blend sizes itself against `uv2s`, not `heights` — it never reads a height, so
#     it must run on a chunk whose `heights` are absent/short as long as uv2s and vertices agree.
#     Hence VIEW_UV2S without VIEW_HEIGHTS makes uv2s the primary array.
#   * only _apply_road_carve additionally requires `colors` and `uv2s` to match `heights`.
#
# ALLOCATION: the result lands in reused `_cvw_*` scratch fields and the function returns a plain
# bool, so a per-chunk pass allocates nothing the old inline preambles did not (the Rect2/Vector3
# are value types). This matters: on web these modifiers run per chunk through the frame-budgeted
# main-thread build queue, and the project targets old phones — a Dictionary per chunk here would
# be chunk-rate garbage. The packed arrays are handed out by reference-count exactly as a local
# `var` did, so the caller's first write still triggers the same single copy-on-write; at most one
# chunk's arrays stay pinned in the scratch until the next call overwrites them.
const VIEW_HEIGHTS := 1
const VIEW_COLORS := 2
const VIEW_UV2S := 4
const VIEW_FULL_RES := 8

var _cvw_heights: PackedFloat32Array
var _cvw_verts: PackedVector3Array
var _cvw_colors: PackedColorArray
var _cvw_uv2s: PackedVector2Array
var _cvw_center: Vector3
var _cvw_half: float
var _cvw_rect: Rect2


# Unpack one chunk dict into the _cvw_* scratch. Returns false — and leaves the scratch in an
# unspecified state — when the chunk should be SKIPPED by the requested pass.
func _chunk_view(data: Dictionary, needs: int) -> bool:
	_cvw_verts = data.get("vertices", PackedVector3Array())
	# The "primary" array whose length every other array is checked against: `heights` when the
	# pass reads heights, otherwise `uv2s` (the region blend).
	var n := 0
	if (needs & VIEW_HEIGHTS) != 0:
		_cvw_heights = data.get("heights", PackedFloat32Array())
		if _cvw_heights.is_empty() or _cvw_verts.size() != _cvw_heights.size():
			return false
		n = _cvw_heights.size()
	if (needs & VIEW_UV2S) != 0:
		_cvw_uv2s = data.get("uv2s", PackedVector2Array())
		if n > 0:
			if _cvw_uv2s.size() != n:
				return false
		else:
			if _cvw_uv2s.is_empty() or _cvw_verts.size() != _cvw_uv2s.size():
				return false
			n = _cvw_uv2s.size()
	if (needs & VIEW_COLORS) != 0:
		# Only ever requested together with VIEW_HEIGHTS (the road carve), so `n` is set.
		_cvw_colors = data.get("colors", PackedColorArray())
		if _cvw_colors.size() != n:
			return false
	if (needs & VIEW_FULL_RES) != 0 and int(data.get("stride", 1)) != 1:
		return false
	# vertices carry CHUNK-LOCAL x/z; `center` puts them back into the world space the builder
	# sampled at — the conversion the carve, the taper, the pad pass and the region blend all do.
	_cvw_center = data.get("center", Vector3.ZERO)
	_cvw_half = CHUNK_M / 2.0
	_cvw_rect = Rect2(_cvw_center.x - _cvw_half, _cvw_center.z - _cvw_half, CHUNK_M, CHUNK_M)
	return true


# Fold the coastline taper into a freshly generated chunk's grid, in lockstep across BOTH
# height representations the dict carries:
#
#   `heights`  — what the HeightMapShape3D collision, height_at and TerrainLod.build_finest
#                all read, and what the on-disk cache stores;
#   `vertices` — what TerrainLod.build_all turns into the displayed meshes.
#
# Done here, in the manager, rather than inside TerrainChunkBuilder: the builder's height path
# is the static TerrainManager._sample_height, which has no instance and so cannot see the
# bounds. Doing it as a grid pass immediately after build() is still "inside generation,
# before quantisation and before caching" — nothing has looked at the arrays yet — and it
# guarantees the mesh, the collision, the cache and the query all derive from one number.
#
# Runs before the caller ever sees the dict, and is a no-op (one early return) unless a
# bounded world with a positive taper is set, so a stage pays nothing.
#
# Known limitation, accepted: the per-vertex BAKED LIGHT is computed inside the builder from
# the pure (untapered) height field, so the taper slope shades as the inland noise would. It
# is a shading-only difference on the beach — geometry, collision and queries all agree — and
# fixing it properly means giving the builder the bounds, which is out of this change's scope.
func _apply_edge_taper(data: Dictionary) -> void:
	if edge_taper_m <= 0.0 or not has_bounds():
		return
	# No stride guard: a coarse chunk is tapered too (see _chunk_view's `needs` note).
	if not _chunk_view(data, VIEW_HEIGHTS):
		return
	var heights := _cvw_heights
	var verts := _cvw_verts
	var center := _cvw_center
	for i in heights.size():
		var v := verts[i]
		var h := taper_height(heights[i], center.x + v.x, center.z + v.z)
		heights[i] = h
		v.y = h
		verts[i] = v
	data["heights"] = heights
	data["vertices"] = verts


# Bake the FLAT PADS into one freshly generated chunk's grid — a level circle of ground under
# every rally zone and under the garage, so the zone's light tube, its floating marker, its
# ghost car and (the case that actually broke) the GARAGE BUILDING stand on level ground
# instead of straddling a slope. See features/terrain.md -> "Flat pads".
#
# Rewrites `heights` and `vertices` in LOCKSTEP, exactly as _apply_edge_taper does, so the
# mesh, the HeightMapShape3D, height_at and the cached bytes all derive from one number. The
# per-point maths is `pad_height`, the SAME function _noise_height_at calls — which is what
# makes the pure-noise fallback agree with the baked grid (see pad_height's header for why the
# pad, unlike the road carve, belongs in the generator).
#
# ORDERING — three rules, all load-bearing (compute_chunk_data is where they are enforced):
#
#  1. AFTER _apply_road_carve. A pad must WIN over a road inside it: the garage forecourt is
#     level ground the road paints across, not a ribbon that re-tilts the yard. The carve
#     writes only COLOR.a / UV2.x besides the height, and this pass touches neither, so the
#     road still reads as road across the pad — it is just flat. The two heights cannot fight
#     at the join either, because the carve's own roadbed target is already pulled toward the
#     pad level at the foot (see the JUNCTION note in _apply_road_carve).
#  2. BEFORE _apply_edge_taper. THE COASTLINE STILL WINS. The taper is a plain function of
#     (h, x, z) that re-derives the shoreline from scratch, so a pad placed near the map edge
#     is pulled down to the sea floor with everything else rather than standing as an island
#     on a plinth out of the water. Same argument, and the same order, as the road carve.
#  3. BEFORE _apply_height_quantum, which stays LAST so the resident grid and the stored
#     record are the same numbers.
#
# The per-chunk REJECT: `pads_in_rect` on the chunk rect. There are a few dozen pads on a
# ~1,600-chunk map, so nearly every chunk exits on that one query and never runs the loop.
#
# No-op (one null check) without a pad source, which is EVERY STAGE.
#
# LOD note: full-res grids only, exactly as the carve and the region blend — chunk_class
# returns full_res for every chunk in a bounded world, so the coarse branch is unreachable
# there.
func _apply_pad_flatten(data: Dictionary) -> void:
	if pad_source == null:
		return
	if not pad_source.has_method("pads_in_rect"):
		return
	# VIEW_FULL_RES: coarse grids are skipped — unreachable in a bounded world (see the LOD note).
	if not _chunk_view(data, VIEW_HEIGHTS | VIEW_FULL_RES):
		return
	var heights := _cvw_heights
	var verts := _cvw_verts
	var center := _cvw_center
	var near: Array = pad_source.call("pads_in_rect", _cvw_rect)
	if near.is_empty():
		return
	for i in heights.size():
		var v := verts[i]
		var h := pad_height(heights[i], center.x + v.x, center.z + v.z)
		heights[i] = h
		v.y = h
		verts[i] = v
	data["heights"] = heights
	data["vertices"] = verts


# Snap a freshly generated chunk's heights onto a fixed lattice, in lockstep across `heights`
# and `vertices` exactly as the taper does.
#
# `height_quantum` is the step in metres (0 = off, which is every stage). The overworld sets it to
# the step its chunk store round-trips through, so a stored record decodes to bit-identical
# numbers and a cache round trip is EXACT rather than approximate. Idempotent by construction, so
# a re-run (a rehydrated chunk passing through again) changes nothing.
func _apply_height_quantum(data: Dictionary) -> void:
	if height_quantum <= 0.0:
		return
	# No stride guard: a coarse chunk is quantised too (see _chunk_view's `needs` note).
	if not _chunk_view(data, VIEW_HEIGHTS):
		return
	var heights := _cvw_heights
	var verts := _cvw_verts
	var inv := 1.0 / height_quantum
	for i in heights.size():
		var h: float = roundf(heights[i] * inv) / inv
		heights[i] = h
		var v := verts[i]
		v.y = h
		verts[i] = v
	data["heights"] = heights
	data["vertices"] = verts


# Bake the REGION FIELD into one freshly generated chunk's UV2.y (features/overworld.md ->
# "Region blending"). The ground's region look changes SPATIALLY, at the fixed boundary between
# two regions, rather than repainting the whole world the moment the player crosses a line — so
# the change has to arrive per-vertex, from data, and it caches exactly like the road carve
# because the region is a pure function of position.
#
# WHY A RANK AND NOT A BLEND WEIGHT. The shader can only cross-fade between the TWO region
# parameter sets that are actually uploaded (slot A and slot B), and which two those are is a
# runtime decision that follows the car (Overworld._push_region_pair). A baked "weight from A to
# B" would therefore be pair-dependent, and a pair-dependent value cannot be cached — the stored
# bytes would mean something different the moment the player's pair changed. So what is baked is
# pair-INDEPENDENT: a canonical 0..1 RANK, one fixed number per region id (RegionBlendSource
# assigns them by sorting the roster's region ids), interpolated by the positional region weights
# (OverworldRegion.region_weights_at). Deep inside a region the value is exactly that region's
# rank; across a boundary it slides between the two ranks. The shader decodes it back into a
# 0..1 A->B factor by inverse-lerping between the two uploaded ranks, which is a pure fragment-side
# remap and needs no re-bake when the pair changes.
#
# CORNER SAMPLING, not per vertex: region_weights_at is linear in the rally roster and allocates a
# Dictionary, and there are SAMPLES² (2,601) vertices per chunk. The region field varies over
# KILOMETRES and a chunk is 50 m, so the rank is sampled at the chunk's four corners and bilinearly
# interpolated across the grid — four queries per chunk instead of 2,601, for a difference no
# fragment can show. Deep inside a region all four corners are equal and the interpolation is a
# constant.
#
# No-op (one null check) without a region source, which is EVERY STAGE — a stage never writes
# UV2.y, and `blend_region` on the ground shaders ships false, so stage rendering is bit-for-bit
# unchanged.
#
# LOD note: full-res grids only, exactly as the carve — chunk_class returns full_res for every
# chunk in a bounded world, so the coarse branch is unreachable there.
func _apply_region_blend(data: Dictionary) -> void:
	if region_source == null:
		return
	if not region_source.has_method("region_rank_at"):
		return
	# VIEW_UV2S WITHOUT VIEW_HEIGHTS: this pass never reads a height, so it sizes itself against
	# `uv2s` and must not be gated on `heights` being present (see _chunk_view's `needs` note).
	if not _chunk_view(data, VIEW_UV2S | VIEW_FULL_RES):
		return
	var uv2s := _cvw_uv2s
	var verts := _cvw_verts
	var center := _cvw_center
	var half := _cvw_half
	var r00: float = region_source.call("region_rank_at", center.x - half, center.z - half)
	var r10: float = region_source.call("region_rank_at", center.x + half, center.z - half)
	var r01: float = region_source.call("region_rank_at", center.x - half, center.z + half)
	var r11: float = region_source.call("region_rank_at", center.x + half, center.z + half)
	for i in uv2s.size():
		var v := verts[i]
		var fx := clampf((v.x + half) / CHUNK_M, 0.0, 1.0)
		var fz := clampf((v.z + half) / CHUNK_M, 0.0, 1.0)
		var rank := lerpf(lerpf(r00, r10, fx), lerpf(r01, r11, fx), fz)
		var t := uv2s[i]
		t.y = clampf(rank, 0.0, 1.0)
		uv2s[i] = t
	data["uv2s"] = uv2s


# Carve the OVERWORLD ROAD NETWORK into one freshly generated chunk (D-slice 4). The open-world
# equivalent of bake_track — but PER CHUNK, local and deterministic, never a global bake:
#
#  - bake_track derives a corridor from one Curve2D and fills MAP-WIDE per-cell dictionaries
#    (road_heights / road_blend / track_weights / track_surface). The overworld is a network
#    over ~1,600 chunks, so those dictionaries would hold millions of cells;
#  - free_load_only_data() deliberately drops road_heights / road_blend after load, so any
#    chunk generated later in play (and in the overworld every chunk is) would silently lose
#    its flatten.
#
# Writes, in ONE pass over the grid, the same four things bake_track expresses per cell:
#   `heights` + `vertices`  — the roadbed flatten (lockstep, exactly as _apply_edge_taper does,
#                             so the mesh, the HeightMapShape3D, height_at and the cached bytes
#                             all derive from one number);
#   colour ALPHA            — road weight (COLOR.a in ps1_models.gdshader, i.e. the channel
#                             _vertex_color_row fills from track_weights);
#   UV2.x                   — tarmac weight (the channel _surface_uv2_row fills from
#                             track_surface; UV2.y is the region rank and is left to
#                             _apply_region_blend).
#
# ORDERING — the two rules that make this correct:
#
#  1. It runs INSIDE generation: after builder.build(), before quantisation and before any
#     cache write, so nothing has looked at the arrays yet. Same reason the coastline taper is
#     a grid pass here rather than something applied to the mesh later.
#  2. THE COASTLINE TAPER WINS. compute_chunk_data calls this BEFORE _apply_edge_taper, so a
#     road running to the shore gets flattened onto the noise ground first and is then pulled
#     down to the sea floor with everything else. The alternative (taper first, then clamp the
#     flatten so it can never raise tapered ground) needs a second rule the flatten has to
#     remember; "carve then taper" needs none, because the taper is a plain function of (h, x, z)
#     that re-derives the shoreline from scratch. A road therefore disappears into the water at
#     the map edge instead of standing on a causeway out to sea, which is the intended read.
#
# `carve_heights` false does the COLOURS ONLY — for _rehydrate_chunk_data, whose `heights` came
# out of a previous compute_chunk_data and are already carved (re-flattening them would compound
# the lerp), but whose colour/uv2 rows are recomputed from the (empty, in a bounded world)
# track_weights / track_surface dictionaries and so would otherwise come back road-less.
#
# No-op (one null check) without a road source, which is every stage.
#
# LOD note: only the full-res grid is carved. `chunk_class` returns full_res for EVERY chunk in
# a bounded world, so the coarse (stride > 1) build is unreachable there and the guard below is
# a statement of that, not a silent gap — same as the taper's known-limitation note.
func _apply_road_carve(data: Dictionary, carve_heights: bool) -> void:
	if road_source == null:
		return
	if not road_source.has_method("road_at") or not road_source.has_method("segments_in_rect"):
		return
	# The only pass that also needs `colors` and `uv2s` to match `heights`. VIEW_FULL_RES: coarse
	# grids are skipped — unreachable in a bounded world (see the LOD note above).
	if not _chunk_view(data, VIEW_HEIGHTS | VIEW_COLORS | VIEW_UV2S | VIEW_FULL_RES):
		return
	var heights := _cvw_heights
	var verts := _cvw_verts
	var colors := _cvw_colors
	var uv2s := _cvw_uv2s
	var center := _cvw_center
	var rect := _cvw_rect
	# One grid query buys the whole chunk: a road-free chunk (the vast majority of ~1,600) pays
	# exactly this and nothing else. The query already inflates by influence_m().
	#
	# Only ever an is_empty() TEST, so prefer `has_segments_in_rect` when the source has it:
	# `segments_in_rect` builds an Array of freshly allocated per-segment Dictionaries that this
	# function then throws away, and it is the common path (nearly every chunk). Fall back to the
	# list for a source that predates the predicate (the duck-typed fakes in the tests).
	if road_source.has_method("has_segments_in_rect"):
		if not bool(road_source.call("has_segments_in_rect", rect)):
			return
	else:
		var segs: Array = road_source.call("segments_in_rect", rect)
		if segs.is_empty():
			return
	# THE SHARED main-thread noise set, not a fresh one. This used to call `_build_noises()` per
	# carved chunk — 3-4 brand-new FastNoiseLite objects each time — justified by a comment
	# claiming compute_chunk_data runs on worker threads. IT DOES NOT: terrain generation is
	# entirely single-threaded in this project (`WorkerThreadPool`, `Thread` and `Mutex` appear
	# only in scripts/cloud/google_sign_in.gd), and the platforms that matter most for frame
	# budget are single-threaded anyway (mobile web). `_ensure_noise_cache` builds the identical
	# pair — same seeds, same frequencies, from the same `layers` — and the carve only READS it
	# via get_noise_2d, so the sampled heights are unchanged; `_rebuild_loaded` invalidates the
	# cache whenever the seed or the layers move.
	var noises: Array = []
	var amps := PackedFloat32Array()
	if carve_heights:
		_ensure_noise_cache()
		noises = _cached_noises
		amps = _cached_amplitudes
	# THE PER-VERTEX QUERY, allocation-free where the source allows it. `road_at` returns a fresh
	# 4-key Dictionary (plus a Vector2) per call and this loop runs SAMPLES² = 2,601 times per
	# carved chunk, so those allocations dominated the cost of the pass. `road_at_into` writes into
	# this ONE caller-owned scratch Array instead (see OverworldRoads.road_at_into for why an
	# out-param rather than a scratch field on the source — it is about the caller's hazard, NOT
	# about threads; nothing here is threaded). A source without the variant keeps the dictionary
	# path, which is what the duck-typed fakes in the tests use.
	#
	# Slots, in the source's own PROBE_* order: 0 road_weight, 1 tarmac_weight, 2 distance_m,
	# 3 foot.x, 4 foot.y. Indexed by literal rather than by `OverworldRoads.PROBE_*` on purpose —
	# `road_source` is duck-typed here and this file must not name that class (overworld_roads.gd
	# already calls into TerrainManager, so a back-reference would be a cycle).
	var probe: Array = [0.0, 0.0, 0.0, 0.0, 0.0]
	var lean := road_source.has_method("road_at_into")
	for i in heights.size():
		var v := verts[i]
		var wx := center.x + v.x
		var wz := center.z + v.z
		var hit: Dictionary = {}
		var w := 0.0
		if lean:
			road_source.call("road_at_into", wx, wz, probe)
			w = float(probe[0])
		else:
			hit = road_source.call("road_at", wx, wz)
			w = float(hit["road_weight"])
		# The off-road EXIT, before anything else is read: on a carved chunk most vertices are
		# still off the road, so nothing but the weight should be touched for them.
		if w <= 0.0:
			continue
		var tarmac: float = float(probe[1]) if lean else float(hit["tarmac_weight"])
		var foot: Vector2 = (Vector2(float(probe[3]), float(probe[4])) if lean
			else Vector2(hit["foot"]))
		if carve_heights:
			# The roadbed: the terrain's own PURE height at the nearest point ON the centreline,
			# so the road reads as a level ribbon following the ground rather than as noise.
			# This is exactly the pairing bake_track stores as road_heights (the height at the
			# perpendicular foot) + road_blend (the feathered weight).
			#
			# `w` doubles as the flatten weight instead of a second road_source.height_bias_at()
			# call: the two are EQUAL today, and this is the hot loop (SAMPLES² vertices per
			# chunk). OverworldRoads keeps height_bias_at separate so the flatten band and the
			# colour band may diverge later — if that ever happens, this line must go back to
			# calling it (guarded by has_method) or the flatten will silently follow the colour.
			var road_h := _sample_height(noises, amps, foot.x, foot.y)
			# THE JUNCTION. Every pad centre is a road NODE (OverworldRoads builds its graph
			# from the rally pins and the garage), so 3-5 edges typically END at a pad centre.
			# Left alone, the roadbed target (noise along the centreline) and the pad's level
			# agree only exactly AT the pin and drift apart outward, leaving a step or a crease
			# in a ring around the pad — the single most-looked-at spot on the map, the one the
			# player drives in through and where the marker and ghost car stand.
			#
			# The fix is to make the ROAD ARRIVE LEVEL: the roadbed target is itself flattened
			# by the pad, evaluated AT THE FOOT (the point on the centreline), so over the last
			# stretch the road ramps onto the pad's plane the way a real road eases into a yard.
			# Inside the pad the target IS the pad level, so the pad pass that follows changes
			# nothing the carve did not already do and the two cannot fight; outside, both
			# influences decay smoothly, so the meeting is continuous by construction rather
			# than by luck.
			#
			# Read at the FOOT, not at the vertex — the pad's own pass handles the vertex.
			# No-op without a pad source, so the stage path (and the golden terrain digest) is
			# untouched.
			road_h = pad_height(road_h, foot.x, foot.y)
			var h := lerpf(heights[i], road_h, w)
			heights[i] = h
			v.y = h
			verts[i] = v
		# COLOR.a = road weight, UV2.x = tarmac weight — the channels the `blend_road` branch of
		# ps1_models.gdshader reads (road_t = COLOR.a, tarmac_t = UV2.x), and the same channels
		# _vertex_color_row / _surface_uv2_row fill on the staged path. RGB (ground tint × baked
		# light) and UV2.y are left exactly as the builder wrote them.
		var c := colors[i]
		c.a = w
		colors[i] = c
		var t := uv2s[i]
		t.x = tarmac
		uv2s[i] = t
	if carve_heights:
		data["heights"] = heights
		data["vertices"] = verts
	data["colors"] = colors
	data["uv2s"] = uv2s


# Per-vertex colours for one chunk's indexed mesh. RGB carries default_cell_color
# (a flat ground tint); ALPHA carries the road blend weight — the average of the
# (up to 4) cell weights around each grid vertex — which the shader uses to fade
# the ground texture toward the road texture. track_weights is keyed by GLOBAL
# cell coords, so a shared edge vertex averages the same four global cells from
# either chunk -> weights match exactly across seams (no stitching). Smoothly
# ramped rather than stepped.
func vertex_colors(coord: Vector2i, lights: PackedColorArray = PackedColorArray()) -> PackedColorArray:
	var colors := PackedColorArray()
	colors.resize(SAMPLES * SAMPLES)
	for zi in SAMPLES:
		_vertex_color_row(coord, zi, lights, colors)
	return colors


# Scratch keys for _vertex_cells — the four global cells meeting at one grid vertex,
# reused by _vertex_color_row / _surface_uv2_row instead of a per-vertex Array (which
# would be ~800k allocs across the corridor). Value-type Vector2i fields, no heap churn;
# both callers run on the main thread and consume the keys inline before the next vertex.
var _vc0: Vector2i
var _vc1: Vector2i
var _vc2: Vector2i
var _vc3: Vector2i


# Fills _vc0.._vc3 with the four global cells meeting at grid vertex (gx, gz).
func _vertex_cells(gx: int, gz: int) -> void:
	_vc0 = Vector2i(gx - 1, gz - 1)
	_vc1 = Vector2i(gx, gz - 1)
	_vc2 = Vector2i(gx - 1, gz)
	_vc3 = Vector2i(gx, gz)


# One row of vertex_colors, written into `out` (shared so the incremental
# TerrainChunkBuilder can fill the colour array a row per frame).
func _vertex_color_row(coord: Vector2i, zi: int, lights: PackedColorArray,
		out: PackedColorArray, n: int = SAMPLES, stride: int = 1) -> void:
	var full_edge := SAMPLES - 1
	var has_light := not lights.is_empty()
	for xi in n:
		_vertex_cells(coord.x * full_edge + xi * stride, coord.y * full_edge + zi * stride)
		# Average of the four cells meeting at this vertex.
		var w: float = (
			track_weights.get(_vc0, 0.0)
			+ track_weights.get(_vc1, 0.0)
			+ track_weights.get(_vc2, 0.0)
			+ track_weights.get(_vc3, 0.0)
		) / 4.0
		# RGB = ground tint × baked light; ALPHA = road blend weight.
		var idx := zi * n + xi
		var lgt := lights[idx] if has_light else Color(1, 1, 1)
		out[idx] = Color(
			default_cell_color.r * lgt.r,
			default_cell_color.g * lgt.g,
			default_cell_color.b * lgt.b,
			w)


# Per-vertex tarmac weight for one chunk's mesh, carried in UV2.x (the shader
# mixes the gravel texture toward the flat tarmac colour by it). Like
# vertex_colors' alpha, each vertex averages the (up to 4) surrounding cells'
# track_surface values — but only over the cells that ARE road/band cells (present
# in track_surface), so the gravel/tarmac split isn't dragged toward gravel by the
# bare grass cells off the road edge. UV2.y is left 0 here and filled later, in the overworld
# only, by _apply_region_blend (the region rank). Keyed by GLOBAL cell
# coords, so a shared edge vertex averages the same cells from either chunk (seam-safe).
func surface_uv2(coord: Vector2i) -> PackedVector2Array:
	var uv2s := PackedVector2Array()
	uv2s.resize(SAMPLES * SAMPLES)
	for zi in SAMPLES:
		_surface_uv2_row(coord, zi, uv2s)
	return uv2s


# One row of surface_uv2, written into `out` (shared so the incremental
# TerrainChunkBuilder can fill the tarmac-weight array a row per frame).
func _surface_uv2_row(coord: Vector2i, zi: int, out: PackedVector2Array,
		n: int = SAMPLES, stride: int = 1) -> void:
	var full_edge := SAMPLES - 1
	for xi in n:
		_vertex_cells(coord.x * full_edge + xi * stride, coord.y * full_edge + zi * stride)
		# The four cells meeting at this vertex, averaged over only those that are
		# road/band cells (present in track_surface). Explicit lookups against the
		# _vc* scratch keys — NOT a `for cell in [...]` literal, which would allocate
		# an Array + 4 Vector2i per vertex (~800k allocations across the corridor).
		var sum := 0.0
		var cell_n := 0
		if track_surface.has(_vc0):
			sum += track_surface[_vc0]; cell_n += 1
		if track_surface.has(_vc1):
			sum += track_surface[_vc1]; cell_n += 1
		if track_surface.has(_vc2):
			sum += track_surface[_vc2]; cell_n += 1
		if track_surface.has(_vc3):
			sum += track_surface[_vc3]; cell_n += 1
		var tarmac := sum / float(cell_n) if cell_n > 0 else 0.0
		out[zi * n + xi] = Vector2(tarmac, 0.0)


# The surface at a world XZ as (road_weight, tarmac_weight), each in [0,1]:
#   road_weight   — 0 = bare grass (off the road), 1 = full road, ramped across
#                   the perpendicular grass↔road feather band.
#   tarmac_weight — 0 = gravel, 1 = tarmac, ramped across the lengthwise switch.
# Off any track both are 0 (grass / gravel defaults). Pure (no Config), so this
# @tool script stays editor-safe; the drivetrain turns it into a grip multiplier
# (Drivetrain.surface_grip) using the configured per-surface μ scales.
func surface_at(x: float, z: float) -> Vector2:
	if has_bounds():
		# A bounded world has no bake_track, so track_weights / track_surface are empty and
		# the dictionary reads below would answer 0 by accident rather than by decision.
		# With a road network attached, ASK IT — otherwise the tyre model, grip, deep-snow drag
		# and reset logic would all see one flat surface and a carved road would have no grip
		# difference at all. Without one, answer from the declared constant (all grass/gravel).
		if road_source != null and road_source.has_method("road_at"):
			return _road_surface_at(x, z)
		return bounds_surface
	var cell := Vector2i(floori(x / CELL_M), floori(z / CELL_M))
	return Vector2(track_weights.get(cell, 0.0), track_surface.get(cell, 0.0))


# One-entry memo for the road-network surface query. surface_at is called PER WHEEL CONTACT PER
# TICK, and several consumers ask about the same contact point in the same tick (grip, the tyre
# params in Drivetrain.surface_tire_params — which is itself written to allocate nothing via
# _surf_scratch — and the deep-snow drag), so a repeat is the common case. OverworldRoads.road_at
# returns a Dictionary, i.e. one allocation per MISS; the memo removes the repeats without a lean
# scalar variant, which would mean editing overworld_roads.gd. Quantised to a quarter of a cell
# so floating-point jitter in an otherwise identical contact point still hits.
var _road_surf_key: Vector2i = Vector2i(2147483647, 2147483647)
var _road_surf_val: Vector2 = Vector2.ZERO
var _road_surf_valid := false


func _road_surface_at(x: float, z: float) -> Vector2:
	var quant := CELL_M * 0.25
	var key := Vector2i(roundi(x / quant), roundi(z / quant))
	if _road_surf_valid and key == _road_surf_key:
		return _road_surf_val
	var hit: Dictionary = road_source.call("road_at", x, z)
	# The SAME pair the dictionary path returns: (road_weight, tarmac_weight). Off the network
	# the answer is `bounds_surface`, not a hard zero, so declaring a base surface for the open
	# ground still works — the road only overrides it where there IS road.
	# On the network the pair is passed through UNSCALED — road_weight is already the feathered
	# ramp, and tarmac_weight is the gravel/tarmac split of the road itself, exactly as the mesh
	# carries them in COLOR.a / UV2.x. Only fully off it does the constant answer.
	var w := float(hit["road_weight"])
	_road_surf_val = bounds_surface if w <= 0.0 else Vector2(w, float(hit["tarmac_weight"]))
	_road_surf_key = key
	_road_surf_valid = true
	return _road_surf_val


# Bake the static terrain shading for one vertex into a light tint. Mirrors the
# math in shaders/ps1_models_lit.gdshader (hemisphere ambient + one directional
# sun), but on the CPU at generation time using a normal taken from the noise
# height field via central differences — continuous across world coords, so it
# matches at chunk seams with no stitching. Returns white when light_amount is 0
# (a no-op multiply). The road-flattened heights are ignored for the normal: the
# road is near-flat anyway and sampling the pure field keeps seams consistent.
func _bake_light(noises: Array, amplitudes: PackedFloat32Array, wx: float, wz: float) -> Color:
	if light_amount <= 0.0:
		return Color(1, 1, 1)
	var hl := _sample_height(noises, amplitudes, wx - CELL_M, wz)
	var hr := _sample_height(noises, amplitudes, wx + CELL_M, wz)
	var hd := _sample_height(noises, amplitudes, wx, wz - CELL_M)
	var hu := _sample_height(noises, amplitudes, wx, wz + CELL_M)
	return _light_from_neighbours(hl, hr, hd, hu)


# The lighting core: turn the four 1-cell-spaced neighbour heights of a vertex
# into a baked light tint (hemisphere ambient + one directional sun). Split out
# of _bake_light so compute_chunk_data can feed it neighbours read from a shared
# pure-height halo (no per-vertex re-sampling) while light_at still samples them
# directly. White (a no-op) when light_amount is 0. The neighbours must be the
# PURE (pre-flatten) field for seam consistency — see _bake_light's note.
func _light_from_neighbours(hl: float, hr: float, hd: float, hu: float) -> Color:
	if light_amount <= 0.0:
		return Color(1, 1, 1)
	var n := Vector3(hl - hr, 2.0 * CELL_M, hd - hu).normalized()
	var hemi := n.y * 0.5 + 0.5
	var ambient := ground_color.lerp(sky_color, hemi)
	var ndl: float = maxf(n.dot(sun_dir), 0.0)
	var lit := Color(
		ambient.r + sun_color.r * ndl,
		ambient.g + sun_color.g * ndl,
		ambient.b + sun_color.b * ndl)
	return Color(1, 1, 1).lerp(lit, light_amount)


# Chunk coordinate (integer grid) containing a world position.
func chunk_coord_for(pos: Vector3) -> Vector2i:
	return Vector2i(floori(pos.x / CHUNK_M), floori(pos.z / CHUNK_M))


# The (2*load_radius+1)^2 coords that should be loaded around a centre coord.
func target_coords(center: Vector2i) -> Array:
	var result: Array = []
	var r := load_radius
	for dz in range(-r, r + 1):
		for dx in range(-r, r + 1):
			result.append(center + Vector2i(dx, dz))
	return result


# Every chunk coord the runtime ring can request while the car stays within
# `leash_m` of the centerline (callers pass the track-progress leash) — plus one
# chunk of margin. The margin is derived from the LIVE leash value, never
# hard-coded: the region this guarantees depends on that tunable. Straight spans
# tessellate to just their endpoints, so each polyline segment is sub-sampled
# at half a chunk so no interior chunk is skipped.
# The corridor dilation margin (chunks) — RADIUS render ring + leash overshoot + 1
# frame-safety buffer. Collision band mirrors it so the two can't drift (see below).
func _corridor_margin(leash_m: float) -> int:
	return load_radius + int(ceil(leash_m / CHUNK_M)) + 1

# Chebyshev chunk radius from the centerline within which a chunk can ever enter
# collision_ring of the focus (car). Same +1 leash-overshoot slop as the corridor
# margin — any chunk inside this band MUST be full-res (it may carry collision).
func _collision_band_chunks(leash_m: float) -> int:
	return collision_ring + int(ceil(leash_m / CHUNK_M)) + 1

# Classify one chunk by its nearest distance to the centerline. `l_min` is the finest
# LOD level index the chunk's closest-possible camera distance can ever select
# (count of band-ends <= that distance). `full_res` is true when the chunk is inside
# the collision band OR can display the finest level (l_min == 0). The collision
# decision is passed in as `in_collision_band` (callers compute it via
# `_collision_band_chunks`; this function doesn't need the chunk radius itself).
func _classify_chunk(min_dist_m: float, leash_m: float, in_collision_band: bool) -> Dictionary:
	var closest_cam := maxf(0.0, min_dist_m - leash_m - precompute_safety_slack_m)
	var l_min := 0
	for e in lod_band_ends_m:
		if e <= closest_cam:
			l_min += 1
	var full_res := in_collision_band or l_min == 0
	return {"l_min": l_min, "full_res": full_res, "in_collision_band": in_collision_band}


func corridor_coords(centerline: Curve2D, leash_m: float) -> Array[Vector2i]:
	var margin := _corridor_margin(leash_m)
	var band_chunks := _collision_band_chunks(leash_m)
	var seen: Dictionary = {}
	var out: Array[Vector2i] = []
	var min_dist: Dictionary = {}        # coord -> nearest centerline-sample distance (m)
	var centre_chunks: Dictionary = {}   # coord -> true for a chunk a sample sits in
	var poly := centerline.tessellate()
	for i in range(1, poly.size()):
		var a := poly[i - 1]
		var b := poly[i]
		var steps := int(ceil(a.distance_to(b) / (CHUNK_M / 2.0))) + 1
		for s in steps + 1:
			var t := float(s) / float(steps) if steps > 0 else 0.0
			var p := a.lerp(b, t)
			var c := chunk_coord_for(Vector3(p.x, 0.0, p.y))
			centre_chunks[c] = true
			for dz in range(-margin, margin + 1):
				for dx in range(-margin, margin + 1):
					var cc := c + Vector2i(dx, dz)
					if not seen.has(cc):
						seen[cc] = true
						out.append(cc)
					# Nearest distance from this chunk's CENTRE to the sample p.
					var centre := Vector2((cc.x + 0.5) * CHUNK_M, (cc.y + 0.5) * CHUNK_M)
					var d := centre.distance_to(p)
					if not min_dist.has(cc) or d < min_dist[cc]:
						min_dist[cc] = d
	# Classify: subtract the chunk half-diagonal to get a conservative nearest-point
	# distance; a chunk is in the collision band if it's within band_chunks (Chebyshev)
	# of any chunk a centerline sample sits in.
	var half_diag := CHUNK_M * sqrt(2.0) / 2.0
	_corridor_class = {}
	for cc in out:
		var near_pt := maxf(0.0, min_dist[cc] - half_diag)
		var in_coll := false
		for centre_c in centre_chunks:
			if maxi(absi(cc.x - centre_c.x), absi(cc.y - centre_c.y)) <= band_chunks:
				in_coll = true
				break
		_corridor_class[cc] = _classify_chunk(near_pt, leash_m, in_coll)
	return out


# Store the corridor and reset the cache; cache_chunk() fills it (world.gd
# batches the fills with frame awaits so the loading bar paints).
func set_corridor(coords: Array[Vector2i]) -> void:
	_corridor_coords = coords
	# _corridor_class is owned by corridor_coords and intentionally NOT cleared here:
	# it must survive the cache clear so _rebuild_loaded reproduces the near/far split.
	_chunk_cache.clear()
	_logged_misses.clear()
	_miss_stream_logged = false   # a fresh supply deserves a fresh undersupply warning
	_vram_at_corridor_mb = video_mem_mb()
	_vram_logged = false
	# A new corridor means the whole cache is about to be rebuilt, baked light and
	# all — so the "lights were freed" sentinel no longer applies. This is what keeps
	# a REGENERATION (world.gd::_generate_track run a second time, e.g. entering a
	# rally event on an already-booted world) correct: load_finished has latched and
	# will not re-fire, but the freshly cached chunks really do carry their light again.
	_lights_freed = false


# The coords the current corridor covers (empty when no precompute has run).
func corridor() -> Array[Vector2i]:
	return _corridor_coords


# Chebyshev chunk radius (around the focus chunk) within which a loaded chunk keeps a
# built FINEST LOD level. Derived from the live tunables, never hard-coded: a chunk at
# Chebyshev distance d has no point closer than (d-1)*CHUNK_M to the focus (the focus can
# sit anywhere inside its own chunk), and the camera can be up to
# precompute_safety_slack_m from the focus, so a chunk can only ever fall inside level 0's
# band when (d-1)*CHUNK_M <= lod_band_ends_m[0] + slack. Clamped to the loaded ring — and
# even if this were somehow too tight, an unbuilt level 0 is not a hole: TerrainChunk
# extends level 1's band down to cover it.
#
# The clamp now uses the LIVE load_radius, and that is a deliberate decision rather than a
# mechanical substitution. The computed value depends only on lod_band_ends_m[0] and
# precompute_safety_slack_m — NOT on the radius — so at the shipped tunables it is 2 and the
# clamp does not bind at either radius: raising load_radius to 10 leaves the returned value
# unchanged, and stage behaviour is therefore identical. The clamp only ever binds when
# level 0's band plus the camera slack reaches BEYOND the loaded ring, and in that case
# "every loaded chunk keeps its finest level" is the correct answer at whatever the ring
# actually is — clamping to the old const 3 inside a 21x21 window would instead have
# *reduced* the detail ring below what the bands ask for. Same reasoning for the empty-bands
# case: no bands means one level, so the whole ring is finest.
func detail_ring() -> int:
	if lod_band_ends_m.is_empty():
		return load_radius
	var reach: float = lod_band_ends_m[0] + precompute_safety_slack_m
	return clampi(int(floor(reach / CHUNK_M)) + 1, 1, load_radius)


# The per-level far-cutoff distances (metres). Read by TerrainChunk to configure
# each level MeshInstance's visibility_range band.
func lod_band_ends() -> PackedFloat32Array:
	return lod_band_ends_m


# --- Chunk source (the duck-typed store; see `chunk_source`) ------------------------------

# Chunk data for `coord`, preferring the attached store over generation. Falls straight
# through to compute_chunk_data when there is no store, the store has no record, or the
# record is unusable — so a store is always a pure speed-up and never a correctness
# dependency.
#
# On a generate, the result is offered BACK to the store. Heights are already tapered
# (compute_chunk_data), so a round trip is idempotent — the taper must never be re-applied to
# a value read out of the store.
func chunk_data_for(coord: Vector2i) -> Dictionary:
	var stored := _read_chunk_source(coord)
	if not stored.is_empty():
		return stored
	var data := compute_chunk_data(coord)
	_write_chunk_source(coord, data)
	return data


# Ask the store for `coord` and rehydrate a full chunk-data dict from it. Everything except
# the two expensive SAMPLING products (heights and baked light) is cheap arithmetic over a
# fixed grid, so the store only has to hold those two. Empty dict = miss.
func _read_chunk_source(coord: Vector2i) -> Dictionary:
	if chunk_source == null or not chunk_source.has_method("read"):
		return {}
	var rec: Dictionary = chunk_source.call("read", coord)
	if rec.is_empty():
		return {}
	var heights: PackedFloat32Array = rec.get("heights", PackedFloat32Array())
	if heights.size() != SAMPLES * SAMPLES:
		return {}
	# The store holds light in the SAME RGB8 encoding TerrainLod already uses (`l0_light`),
	# not as a PackedColorArray: three bytes a vertex rather than a full Color, which is the
	# whole reason `encode_lights` exists. Decode it back to the builder's shape here, so
	# `_rehydrate_chunk_data` sees exactly what a fresh build would have handed it.
	var encoded: PackedByteArray = rec.get("l0_light", PackedByteArray())
	var lights: PackedColorArray = TerrainLod.decode_lights(encoded)
	# The DERIVED surface channels, when the record carries them — see
	# `surface_channels_from`. Optional by design: an absent (or wrong-sized) section just means
	# `_rehydrate_chunk_data` recomputes them, which is what it always did.
	var surface: PackedFloat32Array = rec.get("surface", PackedFloat32Array())
	return _rehydrate_chunk_data(coord, heights, lights, surface)


# Offer a freshly generated chunk to the store. Duck-typed and best-effort: a store that
# refuses (a write failure, an empty light) is not an error here — it just means the next
# visit regenerates.
func _write_chunk_source(coord: Vector2i, data: Dictionary) -> void:
	if chunk_source == null or not chunk_source.has_method("write"):
		return
	var heights: PackedFloat32Array = data.get("heights", PackedFloat32Array())
	if heights.size() != SAMPLES * SAMPLES:
		return
	# Hand over the RGB8 encoding, never the PackedColorArray — that is the store's contract
	# and it is what lands on disk. `l0_light` is already encoded when capture is armed (which
	# set_chunk_source does), so prefer it and only encode as a fallback; encoding twice would
	# be ~2600 clamped divisions per chunk for nothing.
	var encoded: PackedByteArray = data.get("l0_light", PackedByteArray())
	if encoded.is_empty():
		encoded = TerrainLod.encode_lights(data.get("lights", PackedColorArray()))
	chunk_source.call("write", coord, heights, encoded, surface_channels_from(data))


## The three DERIVED per-vertex surface channels of a generated chunk, interleaved as
## (road_weight, tarmac_weight, region_rank) — i.e. (COLOR.a, UV2.x, UV2.y) — for a store to
## keep alongside the heights and the light.
##
## WHY A STORE SHOULD KEEP THEM. Those three are the entire output of `_apply_road_carve`
## (colours only) and `_apply_region_blend`, and re-deriving them on a READ costs ~10-15 ms a
## chunk: the carve queries the road network once PER VERTEX (2,601 per chunk). Storing them
## turns rehydration into pure array copies. They are handed over as raw f32 so the round trip is
## EXACT — see OverworldCache._encode_payload for why an approximate channel is not acceptable
## here.
##
## Empty when the dict has no full-res colour/uv2 arrays (a coarse grid, or a partial dict), so a
## store simply records nothing extra rather than something wrong.
static func surface_channels_from(data: Dictionary) -> PackedFloat32Array:
	var colors: PackedColorArray = data.get("colors", PackedColorArray())
	var uv2s: PackedVector2Array = data.get("uv2s", PackedVector2Array())
	var count := colors.size()
	if count == 0 or uv2s.size() != count:
		return PackedFloat32Array()
	var out := PackedFloat32Array()
	out.resize(count * 3)
	for i in count:
		var t := uv2s[i]
		var at := i * 3
		out[at] = colors[i].a
		out[at + 1] = t.x
		out[at + 2] = t.y
	return out


# Whether the store already holds `coord` (used to decide whether a miss is cheap). Duck-typed
# and optimistic: no store, or no `has`, means "no".
func chunk_source_has(coord: Vector2i) -> bool:
	if chunk_source == null or not chunk_source.has_method("has"):
		return false
	return bool(chunk_source.call("has", coord))


# Rebuild a full-res chunk-data dict from just `heights` + `lights`, in exactly the shape
# TerrainChunkBuilder.data() returns. Mirrors TerrainLod.build_finest's derivation (local
# vertex positions from the height grid, UVs from world XZ x texture_tile_per_meter, indices
# from arithmetic) and reuses the manager's own colour/uv2 row fillers, so a rehydrated chunk
# is the same surface a generated one produces.
#
# `heights` must ALREADY carry the coastline taper (they came out of compute_chunk_data), so
# no taper is applied here.
#
# `surface` is the OPTIONAL fast path (see `surface_channels_from`): SAMPLES² x 3 f32s carrying
# the three DERIVED channels — COLOR.a (road weight), UV2.x (tarmac weight), UV2.y (region rank).
# When it is the right size those values are spliced straight in and BOTH derivation passes are
# skipped; the stored numbers are the generated ones bit-for-bit, so this is not an approximation
# of the slow path, it IS the slow path's answer. Passing nothing (an older record, a store that
# does not keep them, or a caller like a test that only has heights) recomputes exactly as before,
# so the fast path can never be a correctness dependency.
func _rehydrate_chunk_data(coord: Vector2i, heights: PackedFloat32Array,
		lights: PackedColorArray,
		surface: PackedFloat32Array = PackedFloat32Array()) -> Dictionary:
	var n := SAMPLES
	var count := n * n
	var center := Vector3((coord.x + 0.5) * CHUNK_M, 0.0, (coord.y + 0.5) * CHUNK_M)
	var half := CHUNK_M / 2.0
	var verts := PackedVector3Array(); verts.resize(count)
	var uvs := PackedVector2Array(); uvs.resize(count)
	for zi in n:
		var lz := -half + zi * CELL_M
		var wz := center.z + lz
		for xi in n:
			var lx := -half + xi * CELL_M
			var idx := zi * n + xi
			verts[idx] = Vector3(lx, heights[idx], lz)
			uvs[idx] = Vector2(center.x + lx, wz) * texture_tile_per_meter
	var colors := PackedColorArray(); colors.resize(count)
	var uv2s := PackedVector2Array(); uv2s.resize(count)
	var stored := surface.size() == count * 3
	for zi in n:
		# RGB (ground tint x baked light) always comes from here — the light IS stored, and the
		# tint is a runtime field, so nothing about the RGB path changes.
		_vertex_color_row(coord, zi, lights, colors)
		if not stored:
			_surface_uv2_row(coord, zi, uv2s)
	if stored:
		for i in count:
			var at := i * 3
			var c := colors[i]
			c.a = surface[at]
			colors[i] = c
			uv2s[i] = Vector2(surface[at + 1], surface[at + 2])
	var out := {
		"center": center,
		"heights": heights,
		"vertices": verts,
		"uvs": uvs,
		"colors": colors,
		"uv2s": uv2s,
		"indices": TerrainLod.build_grid_indices(n),
		"lights": lights,
		"grid_n": n,
		"stride": 1,
	}
	if stored:
		# BOTH passes skipped: their entire output is the three channels just spliced in, and those
		# came off disk as the exact f32s a generate produced. This is the whole point of the
		# stored section — the carve alone was ~2,601 road-network queries per chunk, which is what
		# made every chunk-boundary crossing a multi-frame spike even though nothing was
		# generating.
		return out
	# Colours ONLY: the stored heights already carry the road carve (they came out of
	# compute_chunk_data), but the colour/uv2 rows above were rebuilt from track_weights /
	# track_surface, which a bounded world never fills. No-op without a road source.
	_apply_road_carve(out, false)
	# UV2.y likewise: the row builders above rebuilt uv2s from scratch (UV2.y = 0), so a
	# rehydrated chunk would come back region-less and render as slot A everywhere. The rank is a
	# pure function of position, so re-deriving it here reproduces the generated value exactly.
	_apply_region_blend(out)
	return out


func cache_chunk(coord: Vector2i) -> void:
	var cls := chunk_class(coord)
	if precompute_prune_enabled and not cls["full_res"]:
		# Coarse: build only the LOD levels this chunk can ever display, each sampled
		# directly at its own stride. No full-res grid, no collision, no cache-backed
		# height/light queries (those fall through to noise for this coord).
		_chunk_cache[coord] = {
			"center": Vector3((coord.x + 0.5) * CHUNK_M, 0.0, (coord.y + 0.5) * CHUNK_M),
			"lod_meshes": TerrainLod.build_levels_from(self, coord, cls["l_min"], lod_skirt_m),
			"coarse": true,
		}
		_log_precompute_vram()
		return
	var data := chunk_data_for(coord)
	# Prebake the decimated LOD display meshes at load (behind the loading screen),
	# so runtime chunk spawns are a cheap node build + mesh assign, not a mesh build.
	# The FINEST level is skipped under lazy_finest_lod (see that field) and rebuilt on
	# demand from `heights` + `l0_light` + the live track fields.
	data["lod_meshes"] = TerrainLod.build_all(data, lod_skirt_m, 1 if lazy_finest_lod else 0)
	data["coarse"] = false
	if lazy_finest_lod or capture_encoded_light:
		# The one finest-level input that is NOT derivable from what the cache retains:
		# the baked per-vertex light. Quantised to RGB8 (~1/5 the bytes of the
		# PackedColorArray) and kept deliberately past free_load_only_data, which drops the
		# full-precision `lights`. This is a LIVE need, not load-only — do not fold it into
		# the frees there.
		# `capture_encoded_light` extends the same retention to the open world, where chunks are
		# generated in PLAY rather than behind a one-shot loading screen: free_load_only_data
		# erases the full-precision `lights` and latches its sentinel, after which a chunk_source
		# write would persist a light-less record the invalidation key could never discard.
		# Stage default stays off — it is ~7.8 KB per chunk a stage has no reader for.
		data["l0_light"] = TerrainLod.encode_lights(data.get("lights", PackedColorArray()))
	# build_all has consumed the CPU-side mesh source arrays into GPU meshes, and
	# nothing reads them again: apply_data only needs center/lod_meshes/heights/coarse,
	# and the strided coarse path builds off its own local TerrainChunkBuilder. Drop
	# them — they are ~5/6 of the cache's bytes (see cache_size_mb / features/terrain.md).
	# `heights` stays (collision + height_at); `lights` is freed later, on load_finished.
	for dead_key in DEAD_AFTER_PREBAKE:
		data.erase(dead_key)
	# Pre-build the PhysicsServer collision shape now, behind the loading screen, for
	# every chunk that could EVER carry live collision — the leash-bounded band
	# (`in_collision_band`, sized off the leash passed into precompute_corridor,
	# never a hardcoded distance). This is the actual expensive
	# step (PhysicsServer3D committing a full SAMPLES x SAMPLES heightfield), previously
	# paid on the main thread the first time a chunk crossed into the live ring
	# (TerrainChunk.apply_data). Doing it here means a crossing later just hands the
	# chunk this already-built shape (or flips it enabled/disabled) instead of building
	# one from scratch. Chunks outside the band never get a shape at all — no extra
	# broadphase cost, since an unattached Shape3D resource isn't part of any collision
	# object until a CollisionShape3D.shape points at it.
	var heights: PackedFloat32Array = data.get("heights", PackedFloat32Array())
	if cls.get("in_collision_band", false) and heights.size() == SAMPLES * SAMPLES:
		var shape := HeightMapShape3D.new()
		shape.map_width = SAMPLES
		shape.map_depth = SAMPLES
		shape.map_data = heights
		data["shape"] = shape
	_chunk_cache[coord] = data
	_log_precompute_vram()
	evict_to_cap()


# One-shot log of the GPU-side cost of the corridor prebake, printed the moment the last
# corridor chunk is cached. This is the half cache_size_mb() CANNOT see: it sums
# Packed*Array values only, while `lod_meshes` is an Array of ArrayMesh whose buffers were
# uploaded to the RenderingServer on creation. Same greppable style as world.gd's
# "terrain precompute:" line. Reads 0 in a headless run (no rendering device).
func _log_precompute_vram() -> void:
	if _vram_logged or _corridor_coords.is_empty():
		return
	if _chunk_cache.size() < _corridor_coords.size() or not corridor_complete():
		return
	_vram_logged = true
	var now := video_mem_mb()
	print("terrain precompute vram: %.1f MB total, %.1f MB added by the prebake (%d chunks, lazy_finest=%s)"
		% [now, now - _vram_at_corridor_mb, _corridor_coords.size(), lazy_finest_lod])


# Video memory currently reported in use by the RenderingServer, in MB. 0 headless.
func video_mem_mb() -> float:
	return Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1.0e6


# Synchronous convenience: compute + cache the whole corridor in one call.
func precompute_corridor(centerline: Curve2D, leash_m: float) -> void:
	set_corridor(corridor_coords(centerline, leash_m))
	for coord in _corridor_coords:
		cache_chunk(coord)


# World-XZ AABB of the precomputed corridor (zero rect when no corridor is set).
# world.gd dilates this by the backdrop margin for the static DistantTerrain.
func corridor_bounds() -> Rect2:
	# A declared bounded world IS the bounds — and it is the only answer available, since an
	# open world has no corridor. Without this DistantTerrain.build_static gets an empty Rect2
	# and builds no horizon at all, which is worst exactly where a coastline needs it most.
	if has_bounds():
		return world_bounds
	if _corridor_coords.is_empty():
		return Rect2()
	var lo := _corridor_coords[0]
	var hi := _corridor_coords[0]
	for c in _corridor_coords:
		lo = Vector2i(mini(lo.x, c.x), mini(lo.y, c.y))
		hi = Vector2i(maxi(hi.x, c.x), maxi(hi.y, c.y))
	return Rect2(lo.x * CHUNK_M, lo.y * CHUNK_M,
		(hi.x - lo.x + 1) * CHUNK_M, (hi.y - lo.y + 1) * CHUNK_M)


# True once every corridor coord has been cached — i.e. TerrainChunkBuilder can no
# longer be asked to build a corridor chunk, so the road/cliff bake fields it reads
# are dead. False for the editor / on-demand test path (no corridor), which keeps
# rebuilding chunks from those fields and must never have them freed.
func corridor_complete() -> bool:
	# A bounded world has no corridor and no bake, so "can a chunk still be asked to read the
	# road/cliff bake fields?" is answered by construction: no, there are none. Reporting true
	# is what lets free_load_only_data drop those (already empty) dictionaries instead of
	# leaving the flag permanently false. It does NOT mean every map chunk is cached — the
	# overworld's cache is a moving window over a larger map, so a per-coord test would be
	# false forever, which is the degradation this replaces.
	if has_bounds():
		return true
	if _corridor_coords.is_empty():
		return false
	for coord in _corridor_coords:
		if not _chunk_cache.has(coord):
			return false
	return true


# Drop everything the LOAD needed but the running game does not. Wired to world.gd's
# `load_finished` signal (features/loading.md); safe to call directly in tests.
#
#  - the per-chunk baked `lights` arrays: every light_at caller (tree_mesh_field,
#    distant_terrain, road_markings) is a one-shot build that has already run by now,
#    and the value is folded into the mesh vertex colours anyway. _cached_light_at
#    push_errors afterwards so a future per-frame caller can't fail silently.
#  - road_heights / road_blend / cliff_offsets: read ONLY by TerrainChunkBuilder, and
#    the corridor is fully cached, so no chunk will ever be built again in play.
#    track_weights / track_surface are KEPT — surface_at() drives per-tick grip.
func free_load_only_data() -> void:
	# A bounded world keeps its baked light. Both premises of the free fail there: chunks are
	# generated in PLAY (not once behind a loading screen), so `lights` is a live input to
	# every future chunk_source write; and light_at is not a one-shot build any more, so
	# latching the sentinel would make _cached_light_at push_error on every query — the exact
	# per-frame spam the sentinel exists to catch. The bake fields are already empty (no
	# bake_track), so there is nothing else here to free.
	if has_bounds():
		_bake_fields_freed = false
		return
	if not _lights_freed:
		_lights_freed = true
		for data in _chunk_cache.values():
			data.erase("lights")
	# Gated: the editor / on-demand rebuild path (no corridor, or a partial one) still
	# needs the bake fields to produce flattened chunks.
	if corridor_complete() and not _bake_fields_freed:
		_bake_fields_freed = true
		road_heights = {}
		road_blend = {}
		cliff_offsets = {}


func has_cached(coord: Vector2i) -> bool:
	return _chunk_cache.has(coord)


# Total cached bytes across all chunks' packed arrays, in MB — logged at load so
# memory regressions are visible. Also the reporting hook eviction is driven from
# (cache_cap_mb). Does NOT see `lod_meshes` — those are ArrayMesh buffers already uploaded to
# the RenderingServer; see _log_precompute_vram for that half.
func cache_size_mb() -> float:
	var total := 0
	for data in _chunk_cache.values():
		total += _chunk_bytes(data)
	return total / 1.0e6


# CPU-side packed-array bytes held by one cached chunk dict.
func _chunk_bytes(data: Dictionary) -> int:
	var total := 0
	for value in data.values():
		if value is PackedByteArray:
			total += value.size()
		elif value is PackedFloat32Array or value is PackedInt32Array:
			total += value.size() * 4
		elif value is PackedVector2Array:
			total += value.size() * 8
		elif value is PackedVector3Array:
			total += value.size() * 12
		elif value is PackedColorArray:
			total += value.size() * 16
	return total


# Drop cached chunks, farthest from the focus first, until the cache is back under
# `cache_cap_mb`. No-op when no cap is set — which is every stage, where the corridor cache is
# sized by the precompute and losing an entry would leave a hole (see _reconcile).
#
# Three hard safety rules, each of which is a real bug if broken:
#
#  1. A coord whose TerrainChunk NODE is still live is never a candidate. `lod_meshes` and
#     `shape` are handed straight to the node, so freeing the dict under it would pull the
#     meshes and the collision heightfield out from beneath a chunk the player can see and
#     drive on.
#  2. Eviction stays strictly OUTSIDE the built window — Chebyshev > load_radius + 1 from the
#     focus chunk, the +1 being hysteresis so a coord the very next reconcile is about to spawn
#     is not thrown away a frame early. This matters because eviction is not lossless: once a
#     coord leaves the cache, height_at / light_at / surface_at fall back to pure noise, which
#     for a bounded world means the taper-only height rather than the cached grid. Outside the
#     window nothing is standing on it, so the disagreement is unobservable.
#  3. Both heap-ish products are released explicitly: `lod_meshes` (the per-level ArrayMesh
#     array, i.e. the VRAM) and any prebuilt `shape` (the HeightMapShape3D committed to the
#     PhysicsServer). Erasing them before dropping the dict makes the intent visible rather
#     than leaving it to refcount coincidence.
#
# Returns the number of chunks evicted.
func evict_to_cap() -> int:
	if cache_cap_mb <= 0.0 or _chunk_cache.is_empty():
		return 0
	var total := 0
	for data in _chunk_cache.values():
		total += _chunk_bytes(data)
	var cap_bytes := int(cache_cap_mb * 1.0e6)
	if total <= cap_bytes:
		return 0
	var keep := load_radius + 1
	var focus := _last_focus_coord
	var candidates: Array[Vector2i] = []
	for key in _chunk_cache:
		var coord: Vector2i = key
		if _chunks.has(coord):
			continue                                    # rule 1: node is live
		if maxi(absi(coord.x - focus.x), absi(coord.y - focus.y)) <= keep:
			continue                                    # rule 2: inside the built window
		candidates.append(coord)
	if candidates.is_empty():
		return 0
	# Farthest first — the least likely to be wanted next.
	candidates.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return maxi(absi(a.x - focus.x), absi(a.y - focus.y)) \
			> maxi(absi(b.x - focus.x), absi(b.y - focus.y)))
	var evicted := 0
	for coord in candidates:
		if total <= cap_bytes:
			break
		var data: Dictionary = _chunk_cache[coord]
		total -= _chunk_bytes(data)
		data.erase("lod_meshes")                        # rule 3: GPU meshes
		data.erase("shape")                             # rule 3: PhysicsServer heightfield
		_chunk_cache.erase(coord)
		evicted += 1
	return evicted


func loaded_coords() -> Array:
	return _chunks.keys()


# Blend weight for a feature `d` metres from the road centerline: 1 at/inside
# `inner` (= width/2), 0 at/beyond `outer` (= inner + transition), smoothstep
# between. Pure/static for easy testing.
static func smooth_ramp(d: float, inner: float, outer: float) -> float:
	if d <= inner:
		return 1.0
	if d >= outer:
		return 0.0
	var raw := (outer - d) / (outer - inner)
	return raw * raw * (3.0 - 2.0 * raw)


# Bake the weighted road + cliff fields from the centerline in ONE distance-field pass.
# The road flatten and the cliff offset are BOTH functions of a vertex's nearest point on
# the centerline, so we find that nearest point ONCE per band vertex (via a segment spatial
# hash + early-terminated ring search) and derive everything from it:
#   road_heights[v]  = noise height at the vertex's EXACT perpendicular foot on the centerline
#   road_blend[v]    = height blend weight (1 on road -> 0 at the outer transition edge)
#   track_weights[c] = colour blend weight per CELL (same ramp, at the cell centre)
#   track_surface[c] = tarmac weight per CELL at its nearest centerline arc-length
#   cliff_offsets[v] = signed cliff/drop offset (0 under the road + transition band)
# Because the height is taken at the TRUE nearest foot (not a discrete along-arc sample),
# the road cross-section is laterally flat regardless of tessellation density — there is no
# sampling-step knob to tune. All fields are keyed by GLOBAL grid index so adjacent chunks
# agree on shared edges with no stitching. `transition_m` is the band width OUTSIDE width/2.
func bake_track(centerline: Curve2D, width: float, transition_m: float, tarmac_fraction: float = 0.0, tarmac_first: bool = false, surface_feather_m: float = 6.0, should_yield: bool = false, on_progress: Callable = Callable()) -> void:
	road_heights = {}
	road_blend = {}
	track_weights = {}
	track_surface = {}
	cliff_offsets = {}
	_bake_fields_freed = false  # a fresh bake restores what free_load_only_data dropped
	var poly := centerline.tessellate()
	if poly.size() < 2:
		return

	# Band radii. Flatten: road half-width (inner, full weight) -> outer transition edge.
	# Cliff (if active): starts at the transition edge, rises over cliff_run to full ±1,
	# fades over cliff_fade back to natural grade. The search band covers whichever reaches
	# furthest so a single sweep feeds both.
	_cv_f_inner = width / 2.0
	_cv_f_outer = _cv_f_inner + transition_m
	var cliffs := _cliffs_active()
	_cv_cliffs = cliffs
	_cv_eff_max = (cliff_max_height_m * clampf(cliff_amount, 0.0, 1.0)) if cliffs else 0.0
	_cv_c_inner = _cv_f_outer
	_cv_c_rise = _cv_c_inner + cliff_run_m
	_cv_c_outer = _cv_c_rise + cliff_fade_m
	var outer := maxf(_cv_f_outer, _cv_c_outer) if cliffs else _cv_f_outer
	_cv_f_outer_sq = _cv_f_outer * _cv_f_outer
	_cv_outer_sq = outer * outer

	# --- Segments: endpoint, delta, 1/len², arc length at start, unit tangent, total length
	# (the last for the gravel/tarmac split). Stored in the _cv_* scratch for _nearest_seg. ---
	var n_seg := poly.size() - 1
	_cv_ax = PackedFloat32Array(); _cv_ax.resize(n_seg)
	_cv_ay = PackedFloat32Array(); _cv_ay.resize(n_seg)
	_cv_dx = PackedFloat32Array(); _cv_dx.resize(n_seg)
	_cv_dy = PackedFloat32Array(); _cv_dy.resize(n_seg)
	_cv_inv = PackedFloat32Array(); _cv_inv.resize(n_seg)
	_cv_len = PackedFloat32Array(); _cv_len.resize(n_seg)
	_cv_tx = PackedFloat32Array(); _cv_tx.resize(n_seg)
	_cv_ty = PackedFloat32Array(); _cv_ty.resize(n_seg)
	_cv_arc = PackedFloat32Array(); _cv_arc.resize(n_seg)
	var total_m := 0.0
	for i in n_seg:
		var a := poly[i]
		var b := poly[i + 1]
		var dx := b.x - a.x
		var dy := b.y - a.y
		var l2 := dx * dx + dy * dy
		var l := sqrt(l2)
		_cv_ax[i] = a.x; _cv_ay[i] = a.y; _cv_dx[i] = dx; _cv_dy[i] = dy
		_cv_inv[i] = (1.0 / l2) if l2 > 0.0 else 0.0
		_cv_len[i] = l
		_cv_tx[i] = (dx / l) if l > 0.0 else 0.0
		_cv_ty[i] = (dy / l) if l > 0.0 else 0.0
		_cv_arc[i] = total_m
		total_m += l

	# --- Camber LUT (cliffs only). Camber is a smooth 1-D function of arc length
	# (wavelength ≫ a metre), so sample it once every camber_step and lerp per vertex. ---
	_cv_camber_step = 0.5
	_cv_camber_lut = PackedFloat32Array()
	_cv_lut_n = 0
	if cliffs:
		var camber_noise := _make_camber_noise()
		_cv_lut_n = int(ceil(total_m / _cv_camber_step)) + 2
		_cv_camber_lut.resize(_cv_lut_n)
		for k in _cv_lut_n:
			_cv_camber_lut[k] = _camber(camber_noise, float(k) * _cv_camber_step)

	# --- Segment spatial hash: grid of CLIFF_GRID_M cells -> the segments crossing them.
	# A query only checks segments in the (2R+1)² block of cells around it. G is a whole
	# number of terrain cells so each grid cell holds an exact Gc×Gc block of vertices. ---
	var G := CLIFF_GRID_M
	var Gc := int(G / CELL_M)
	_cv_Gc = Gc
	var R := int(ceil(outer / G))
	var min_gx := 0x7fffffff
	var min_gz := 0x7fffffff
	var max_gx := -0x7fffffff
	var max_gz := -0x7fffffff
	for pt in poly:
		var cgx := floori(pt.x / G)
		var cgz := floori(pt.y / G)
		min_gx = mini(min_gx, cgx); max_gx = maxi(max_gx, cgx)
		min_gz = mini(min_gz, cgz); max_gz = maxi(max_gz, cgz)
	_cv_gx0 = min_gx - R - 1
	_cv_gz0 = min_gz - R - 1
	_cv_gw = (max_gx - min_gx) + 2 * (R + 1) + 1
	_cv_gh = (max_gz - min_gz) + 2 * (R + 1) + 1
	_cv_G = G
	_cv_R = R
	var gw := _cv_gw
	var gh := _cv_gh
	_cv_grid = []
	_cv_grid.resize(gw * gh)
	var occupied := PackedInt32Array()
	for i in n_seg:
		var l := _cv_len[i]
		var walk_steps := maxi(1, int(ceil(l / (G * 0.5))))
		var last_cell := -1
		for w in walk_steps + 1:
			var tt := float(w) / float(walk_steps)
			var px := _cv_ax[i] + _cv_dx[i] * tt
			var pz := _cv_ay[i] + _cv_dy[i] * tt
			var cell := (floori(pz / G) - _cv_gz0) * gw + (floori(px / G) - _cv_gx0)
			if cell == last_cell:
				continue
			last_cell = cell
			var segs = _cv_grid[cell]
			if segs == null:
				segs = PackedInt32Array()
				occupied.append(cell)
			segs.append(i)
			_cv_grid[cell] = segs

	# --- Candidate cells: only cells within R of an occupied cell can hold band vertices. ---
	var vx0 := _cv_gx0 * Gc
	var vz0 := _cv_gz0 * Gc
	var vw := gw * Gc
	var vh := gh * Gc
	_cv_vx0 = vx0
	_cv_vz0 = vz0
	_cv_vw = vw
	_cv_vh = vh
	var cand := PackedByteArray()
	cand.resize(gw * gh)
	for oc in occupied:
		var ocx := oc % gw
		var ocz := oc / gw
		for rz in range(-R, R + 1):
			var cz := ocz + rz
			if cz < 0 or cz >= gh:
				continue
			for rx in range(-R, R + 1):
				var cxg := ocx + rx
				if cxg >= 0 and cxg < gw:
					cand[cz * gw + cxg] = 1
	var cand_total := 0
	for c in cand:
		cand_total += c
	var progress_stride := maxi(1, cand_total / 40)

	# --- Cliff offset field (flat, only allocated when cliffs are active) + its band bbox. ---
	_cv_off = PackedFloat32Array()
	if cliffs:
		_cv_off.resize(vw * vh)
	_cv_tvx0 = 0x7fffffff
	_cv_tvx1 = -0x7fffffff
	_cv_tvz0 = 0x7fffffff
	_cv_tvz1 = -0x7fffffff

	# --- Vertex sweep: per candidate vertex, find the nearest centerline point ONCE, then
	# emit the flatten fields (road band) and the cliff offset (cliff band) from it. The
	# per-vertex work lives in _bake_vertex_block, one spatial-hash cell at a time; only the
	# candidate test, the progress report and the frame yield stay here (the yield is why: an
	# `await` inside the extracted function would turn it into a coroutine per block). ---
	var cand_seen := 0
	for cgz in gh:
		for cgx in gw:
			if cand[cgz * gw + cgx] == 0:
				continue
			cand_seen += 1
			if cand_seen % progress_stride == 0:
				if on_progress.is_valid():
					on_progress.call(float(cand_seen) / maxf(float(cand_total), 1.0))
				if should_yield:
					await get_tree().process_frame
			_bake_vertex_block(cgx, cgz)

	# --- Cell sweep: colour blend + tarmac weight per CELL (cells sit half a cell off the
	# vertex grid and drive the texture fade, keyed by global cell coord). Only cells that
	# TOUCH a flattened road vertex can fall in the road band, so we drive this off the
	# road_blend keys (a few thousand band vertices) and search each candidate cell centre
	# once — far cheaper than a second full ring-search sweep over every grid vertex. Each
	# vertex touches its 4 surrounding cells; `seen` dedups the overlap. ---
	var seen: Dictionary = {}
	for gv in road_blend:
		var vgx: int = gv.x
		var vgz: int = gv.y
		for cell in [
				Vector2i(vgx - 1, vgz - 1), Vector2i(vgx, vgz - 1),
				Vector2i(vgx - 1, vgz), Vector2i(vgx, vgz)]:
			if seen.has(cell):
				continue
			seen[cell] = true
			var qx := (float(cell.x) + 0.5) * CELL_M
			var qz := (float(cell.y) + 0.5) * CELL_M
			var seg := _nearest_seg(qx, qz, -1)
			if seg < 0 or _cv_best_dsq >= _cv_f_outer_sq:
				continue
			var t := _cv_best_t
			var d := sqrt(_cv_best_dsq)
			var s := _cv_arc[seg] + t * _cv_len[seg]
			track_weights[cell] = smooth_ramp(d, _cv_f_inner, _cv_f_outer)
			track_surface[cell] = TrackSurface.tarmac_weight(
				s, total_m, tarmac_fraction, tarmac_first, surface_feather_m)

	# --- Cliffs: knock down thin tall walls (morphological open over the band ribbon), then
	# emit the sparse offset dict in the shared GLOBAL vertex-index space. ---
	if cliffs and _cv_tvx1 >= _cv_tvx0:
		_emit_cliff_offsets()

	# Release the scratch (large packed arrays + the grid) — it's only valid during a bake.
	_cv_grid = []
	_cv_off = PackedFloat32Array()
	_cv_camber_lut = PackedFloat32Array()

	# These five Vector2i->float Dictionaries are the least-measured memory line in
	# todo/mobile-web-performance.md (2.7): a Godot HashMap entry costs ~60-90 bytes vs
	# 4 in a flat array, and the cliff band is a wide ribbon at 1 m resolution. Log the
	# entry counts so the estimate can be checked from any real stage load.
	print("track bake fields: road_heights=%d road_blend=%d track_weights=%d track_surface=%d cliff_offsets=%d"
		% [road_heights.size(), road_blend.size(), track_weights.size(),
			track_surface.size(), cliff_offsets.size()])


# One spatial-hash cell's worth of bake_track's vertex sweep: the Gc×Gc block of terrain vertices
# at hash cell (cgx, cgz). Lifted out of bake_track, which used to hold this body five and six
# indent levels deep. Reads the band radii and the vertex-grid geometry from the _cv_* bake
# scratch and writes road_heights / road_blend plus (cliffs only) _cv_off and its bbox — so it is
# only meaningful while a bake is in flight, exactly like _nearest_seg.
#
# Allocation-free per vertex: `_cv_off` is a member rather than a parameter precisely so the
# copy-on-write field is not duplicated per block, and _nearest_seg reports through out-params.
func _bake_vertex_block(cgx: int, cgz: int) -> void:
	var Gc := _cv_Gc
	var vw := _cv_vw
	# Seed each grid cell's search from -1; adjacent vertices reuse the winner.
	var seed_seg := -1
	for lz in Gc:
		var vz := cgz * Gc + lz
		var qz := float(_cv_vz0 + vz) * CELL_M
		for lx in Gc:
			var vx := cgx * Gc + lx
			var qx := float(_cv_vx0 + vx) * CELL_M
			var seg := _nearest_seg(qx, qz, seed_seg)
			if seg < 0 or _cv_best_dsq > _cv_outer_sq:
				continue
			seed_seg = seg
			var t := _cv_best_t
			var footx := _cv_ax[seg] + _cv_dx[seg] * t
			var footz := _cv_ay[seg] + _cv_dy[seg] * t
			var d := sqrt(_cv_best_dsq)
			# Flatten: pull road-band vertices to the noise height at their exact foot.
			if _cv_best_dsq < _cv_f_outer_sq:
				var gv := Vector2i(_cv_vx0 + vx, _cv_vz0 + vz)
				road_heights[gv] = _noise_height_at(footx, footz)
				road_blend[gv] = smooth_ramp(d, _cv_f_inner, _cv_f_outer)
			if not _cv_cliffs:
				continue
			# Cliff offset: side · camber(arc) · profile(d) · eff_max.
			var s := _cv_arc[seg] + t * _cv_len[seg]
			var sc := s / _cv_camber_step
			var k0 := clampi(int(sc), 0, _cv_lut_n - 2)
			var camber := lerpf(_cv_camber_lut[k0], _cv_camber_lut[k0 + 1], sc - float(k0))
			var cross := _cv_tx[seg] * (qz - footz) - _cv_ty[seg] * (qx - footx)
			var val := signf(cross) * camber * _cliff_profile(d, _cv_c_inner, _cv_c_rise, _cv_c_outer) * _cv_eff_max
			if val == 0.0:
				continue
			_cv_off[vz * vw + vx] = val
			_cv_tvx0 = mini(_cv_tvx0, vx); _cv_tvx1 = maxi(_cv_tvx1, vx)
			_cv_tvz0 = mini(_cv_tvz0, vz); _cv_tvz1 = maxi(_cv_tvz1, vz)


# bake_track's cliff post-pass, lifted out of it: knock down thin tall walls (a morphological
# open over the band ribbon that _bake_vertex_block wrote into _cv_off), then emit the surviving
# values as the sparse cliff_offsets dict in the shared GLOBAL vertex-index space. Only called
# when cliffs are active AND the bbox is non-empty, so `_cv_off` is allocated and written here.
func _emit_cliff_offsets() -> void:
	var vw := _cv_vw
	var r := int(round(cliff_open_radius_m / CELL_M))
	var ex0 := maxi(0, _cv_tvx0 - r)
	var ex1 := mini(vw - 1, _cv_tvx1 + r)
	var ez0 := maxi(0, _cv_tvz0 - r)
	var ez1 := mini(_cv_vh - 1, _cv_tvz1 + r)
	var sw := ex1 - ex0 + 1
	var sh := ez1 - ez0 + 1
	if r > 0:
		var sub := PackedFloat32Array()
		sub.resize(sw * sh)
		for z in sh:
			for x in sw:
				sub[z * sw + x] = _cv_off[(ez0 + z) * vw + (ex0 + x)]
		_open_thin_offsets(sub, sw, sh, cliff_open_radius_m)
		for z in sh:
			for x in sw:
				_cv_off[(ez0 + z) * vw + (ex0 + x)] = sub[z * sw + x]
	for z in range(ez0, ez1 + 1):
		var world_z := _cv_vz0 + z
		for x in range(ex0, ex1 + 1):
			var val := _cv_off[z * vw + x]
			if absf(val) > 0.0001:
				cliff_offsets[Vector2i(_cv_vx0 + x, world_z)] = val


# Nearest centerline segment to world point (qx, qz), via the _cv_* spatial hash: an
# early-terminated ring search over the (2R+1)² block of grid cells, culling any cell whose
# nearest point is already beyond the best distance. `seed_seg` (the previous query's winner,
# or -1) is projected first to tighten the initial bound — adjacent queries almost always
# share a nearest segment. Returns the segment index (-1 if none) and writes the clamped
# projection parameter + squared distance to _cv_best_t / _cv_best_dsq (out-params, so the
# 155k-call hot path allocates nothing). while-loops avoid per-ring range() allocations.
func _nearest_seg(qx: float, qz: float, seed_seg: int) -> int:
	var gw := _cv_gw
	var gh := _cv_gh
	var G := _cv_G
	var R := _cv_R
	var cgx := clampi(floori(qx / G) - _cv_gx0, 0, gw - 1)
	var cgz := clampi(floori(qz / G) - _cv_gz0, 0, gh - 1)
	var best_dsq := INF
	var best_seg := -1
	var best_t := 0.0
	if seed_seg >= 0:
		var swx := qx - _cv_ax[seed_seg]
		var swz := qz - _cv_ay[seed_seg]
		var st := clampf((swx * _cv_dx[seed_seg] + swz * _cv_dy[seed_seg]) * _cv_inv[seed_seg], 0.0, 1.0)
		var sex := swx - _cv_dx[seed_seg] * st
		var sez := swz - _cv_dy[seed_seg] * st
		best_dsq = sex * sex + sez * sez
		best_seg = seed_seg
		best_t = st
	var ring := 0
	while ring <= R:
		var lo_z := cgz - ring
		var hi_z := cgz + ring
		var lo_x := cgx - ring
		var hi_x := cgx + ring
		var zhi := mini(gh - 1, hi_z)
		var xhi := mini(gw - 1, hi_x)
		var ccz := maxi(0, lo_z)
		while ccz <= zhi:
			var edge_row := ccz == lo_z or ccz == hi_z
			var ccx := maxi(0, lo_x)
			while ccx <= xhi:
				if edge_row or ccx == lo_x or ccx == hi_x:
					var segs = _cv_grid[ccz * gw + ccx]
					if segs != null:
						var cwx0 := float(_cv_gx0 + ccx) * G
						var cwz0 := float(_cv_gz0 + ccz) * G
						var ddx := maxf(0.0, maxf(cwx0 - qx, qx - cwx0 - G))
						var ddz := maxf(0.0, maxf(cwz0 - qz, qz - cwz0 - G))
						if ddx * ddx + ddz * ddz < best_dsq:
							for si in segs:
								var wx := qx - _cv_ax[si]
								var wz := qz - _cv_ay[si]
								var tproj := clampf((wx * _cv_dx[si] + wz * _cv_dy[si]) * _cv_inv[si], 0.0, 1.0)
								var ex := wx - _cv_dx[si] * tproj
								var ez := wz - _cv_dy[si] * tproj
								var dsq := ex * ex + ez * ez
								if dsq < best_dsq:
									best_dsq = dsq
									best_seg = si
									best_t = tproj
				ccx += 1
			ccz += 1
		if best_seg >= 0 and best_dsq <= float(ring * G) * float(ring * G):
			break
		ring += 1
	_cv_best_t = best_t
	_cv_best_dsq = best_dsq
	return best_seg


# The camber signal's FastNoiseLite: a 1-D value along the track's arc length,
# analogous to TrackSurface.tarmac_weight being a pure function of distance. Seeded
# off track_seed so the whole stage is deterministic.
func _make_camber_noise() -> FastNoiseLite:
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_PERLIN
	noise.fractal_type = FastNoiseLite.FRACTAL_NONE
	noise.seed = cliff_seed ^ CLIFF_SEED_SALT
	noise.frequency = 1.0 / maxf(cliff_wavelength_m, 0.001)
	return noise


# The camber value in [-1, 1] at arc length `s`: raw 1-D noise scaled by cliff_gain
# then clamped. Higher gain → the signal spends more time saturated at ±1 (frequent
# full-height cliffs); the clamp makes ±1 a hard ceiling. Carries the sign, so as it
# slides through 0 a left-cliff/right-drop becomes level becomes a right-cliff.
func _camber(noise: FastNoiseLite, s: float) -> float:
	return clampf(noise.get_noise_1d(s) * cliff_gain, -1.0, 1.0)


# The cross-section shape as a function of perpendicular distance |d| from the
# centerline: 0 under the road AND across the full feathered transition band (so the
# shoulder isn't tilted and the cliff only begins where the road has met the grass),
# rising 0→1 over cliff_run_m, then falling 1→0 over cliff_fade_m back to natural grade
# (a localized berm/ditch, not an infinite shelf). 0 again past the influence radius R.
static func _cliff_profile(d: float, inner: float, rise: float, outer: float) -> float:
	if d <= inner or d >= outer:
		return 0.0
	if d < rise:
		return smoothstep(inner, rise, d)
	return 1.0 - smoothstep(rise, outer, d)


# Whether the cliff pass will actually stamp offsets (used by bake_track to decide
# whether the flatten pass owns the whole carve bar or just its first half).
func _cliffs_active() -> bool:
	return cliff_enabled and cliff_max_height_m * clampf(cliff_amount, 0.0, 1.0) > 0.0


# Morphological grayscale OPENING (erosion then dilation) on the signed offset field,
# applied to |offset| with the sign restored, using a square structuring element of
# radius `radius_m`. Opening is anti-extensive (never raises |offset|, never creates an
# offset where there was none), so it only knocks DOWN features narrower than 2·radius
# in either axis — the thin walls a hairpin crook would otherwise leave — while wide
# cliffs and drops are preserved. Acting on the magnitude keeps walls and drops
# symmetric. A separable square element makes each pass a pair of 1-D min/max sweeps.
func _open_thin_offsets(off: PackedFloat32Array, w: int, h: int, radius_m: float) -> void:
	var r := int(round(radius_m / CELL_M))
	if r <= 0 or off.is_empty():
		return
	var mag := PackedFloat32Array()
	mag.resize(off.size())
	for i in off.size():
		mag[i] = absf(off[i])
	var eroded := _sep_window(mag, w, h, r, true)    # erosion = window minimum
	var opened := _sep_window(eroded, w, h, r, false) # dilation = window maximum
	for i in off.size():
		off[i] = signf(off[i]) * opened[i]


# Separable 1-D min (is_min) / max sliding-window over a w×h grid, horizontal then
# vertical, window half-width r. Edges clamp to the valid range (the band never reaches
# the padded border, so clamping only ever touches zeros).
func _sep_window(src: PackedFloat32Array, w: int, h: int, r: int, is_min: bool) -> PackedFloat32Array:
	var tmp := PackedFloat32Array()
	tmp.resize(src.size())
	for y in h:
		var base := y * w
		for x in w:
			var acc := src[base + x]
			for k in range(maxi(0, x - r), mini(w - 1, x + r) + 1):
				var v := src[base + k]
				acc = minf(acc, v) if is_min else maxf(acc, v)
			tmp[base + x] = acc
	var out := PackedFloat32Array()
	out.resize(src.size())
	for x in w:
		for y in h:
			var acc := tmp[y * w + x]
			for k in range(maxi(0, y - r), mini(h - 1, y + r) + 1):
				var v := tmp[k * w + x]
				acc = minf(acc, v) if is_min else maxf(acc, v)
			out[y * w + x] = acc
	return out


# Apply a track: bake the weighted height + road-blend fields from the centerline,
# then rebuild any currently-loaded chunks (mesh + collision) so the texture fade
# takes effect. At startup the ring is deferred (see build_initial), so _chunks is
# empty here and nothing rebuilds; chunks loaded later read the baked fields in
# compute_chunk_data / vertex_colors at build time.
# `should_yield` (true only on the interactive staged load, never headless) makes the
# heavy bake release the main thread periodically so the loading overlay keeps painting
# instead of freezing. It never changes the baked RESULT — only the pacing — but because
# the bake then contains `await`, set_track/bake_track are always coroutines: call them
# with `await` (with should_yield=false they never actually suspend, completing same-frame).
func set_track(centerline: Curve2D, width: float, transition_m: float, tarmac_fraction: float = 0.0, tarmac_first: bool = false, surface_feather_m: float = 6.0, should_yield: bool = false, on_progress: Callable = Callable()) -> void:
	await bake_track(centerline, width, transition_m, tarmac_fraction, tarmac_first, surface_feather_m, should_yield, on_progress)
	for coord in _chunks:
		_chunks[coord].setup(self, coord)


# The shape arguments bake_track/set_track take, derived from a GameConfig in ONE
# place. Every baker (the run scene's real terrain, the Seed Lab's throwaway preview
# terrain) goes through this, so a change to how the road band or surface split is
# derived can't land in one baker and not the other — which is exactly how the
# loading preview came to disagree with the driven world.
# Returns [width, transition_m, tarmac_fraction, tarmac_first, surface_feather_m].
static func bake_args(cfg: GameConfig) -> Array:
	return [
		cfg.track_width,
		cfg.track_transition_cells * CELL_M,
		cfg.track_tarmac_fraction,
		TrackSurface.orientation_tarmac_first(cfg.track_seed),
		cfg.track_surface_transition_m,
	]


# The config's terrain layers as TerrainLayer resources, in layer order — the same
# wavelengths/amplitudes the run scene uses (world.gd seats $Floor.layers the same
# way), so an off-tree sampler agrees with the terrain the player drives.
#
# This builds NODE STATE. For a pure height
# SAMPLER with no node at all, use TerrainNoise.make_sampler(seed, cfg.terrain_layers())
# instead — that is the headless path.
static func layers_from_config(cfg: GameConfig) -> Array[TerrainLayer]:
	var built: Array[TerrainLayer] = []
	for params in cfg.terrain_layers():
		var layer := TerrainLayer.new()
		layer.wavelength_m = params.x
		layer.amplitude_m = params.y
		built.append(layer)
	return built


# A bare, off-tree TerrainManager baked for `centerline` under `cfg` — noise layers,
# seed and cliff params all seated from the config, then bake_track run so
# `baked_height_at` answers with road flatten + cliff offsets included.
#
# For PREVIEWS (the Seed Lab) that have no run scene: it deliberately builds no
# chunks, no meshes and is never added to the tree, so it costs the distance-field
# pass and nothing else. Cliff offsets are the whole point — a preview sampled from
# pure noise shows far less water than the stage really has, because cliff drops are
# signed and several metres deep.
static func baked_preview(cfg: GameConfig, centerline: Curve2D) -> TerrainManager:
	var tm := TerrainManager.new()
	tm.defer_initial_build = true  # never build a ring; this is a sampler, not a scene
	tm.noise_seed = cfg.track_seed
	tm.layers = layers_from_config(cfg)
	cfg.apply_cliffs(tm)
	var a := bake_args(cfg)
	await tm.bake_track(centerline, a[0], a[1], a[2], a[3], a[4])
	return tm


func _ready() -> void:
	if layers.is_empty():
		layers = _default_layers()
	else:
		_connect_layer_signals()
	# Build the initial ring now unless a parent will drive it (defer). The editor
	# always previews, so it builds regardless of the flag.
	if Engine.is_editor_hint() or not defer_initial_build:
		build_initial()
	else:
		_initial_pending = true
	# Hang the load-only frees off the host's shared "load finished" hook (world.gd;
	# see features/loading.md). Duck-typed so the manager still works standalone —
	# the editor preview, the HQ/podium `flat()` dressing and headless tests have no
	# such host and simply never free.
	if not Engine.is_editor_hint():
		var host := get_parent()
		if host != null and host.has_signal("load_finished") \
				and not host.is_connected("load_finished", free_load_only_data):
			host.connect("load_finished", free_load_only_data)


# Build the initial 3x3 ring synchronously around the focus (the car), so there
# is always ground under the car at spawn.
func build_initial() -> void:
	_initial_pending = false
	var focus := _focus_node()
	var origin: Vector3 = focus.global_position if focus != null else Vector3.ZERO
	# Seat the focus BEFORE reconciling, not after: eviction (evict_to_cap, called from
	# cache_chunk / _reconcile) measures distance from _last_focus_coord, and the sentinel it
	# starts at is ~2 billion chunks away, which would make every cached chunk look evictable
	# during the very first build. _reconcile takes its centre as an argument, so this reorder
	# changes nothing else.
	_last_focus_coord = chunk_coord_for(origin)
	_reconcile(chunk_coord_for(origin))
	# The initial ring is built behind the loading screen, so pay for its finest levels
	# now rather than trickling them in over the player's first seconds of driving.
	flush_detail_queue()


func _process(delta: float) -> void:
	var __t := Time.get_ticks_usec()
	_timed_process(delta)
	PerfLog.track(&"terrain_manager", Time.get_ticks_usec() - __t)


func _timed_process(_delta: float) -> void:
	# Deferred ring not built yet: the host is mid-generation, so stay out of its way
	# entirely (see _initial_pending).
	if _initial_pending:
		return
	# H (`toggle_debug_arrows`, the shared debug key) toggles the chunk-border
	# overlay whenever SettingsMenu.dev_tools_enabled() — lazily created so it
	# pays nothing while hidden.
	if SettingsMenu.dev_tools_enabled() and not Engine.is_editor_hint() \
			and Input.is_action_just_pressed("toggle_debug_arrows"):
		_toggle_chunk_borders()
	if not stage_timing:
		var focus_untimed := _focus_node()
		if focus_untimed != null:
			update_focus(focus_untimed.global_position)
		# Drain deferred chunk spawns BEFORE the detail queue: a missing chunk is a hole in the
		# world, a missing finest LOD is only a blurrier one, so the chunk wins the frame's
		# budget.
		_drain_spawn_queue(spawn_budget)
		_drain_detail_queue(detail_builds_per_frame)
		return
	# Same three stages, individually timed. See `stage_timing`.
	var t0 := Time.get_ticks_usec()
	var focus := _focus_node()
	if focus != null:
		update_focus(focus.global_position)
	var t1 := Time.get_ticks_usec()
	_drain_spawn_queue(spawn_budget)
	var t2 := Time.get_ticks_usec()
	_drain_detail_queue(detail_builds_per_frame)
	var t3 := Time.get_ticks_usec()
	last_focus_us = t1 - t0
	last_spawn_drain_us = t2 - t1
	last_detail_drain_us = t3 - t2


# Build up to `limit` queued finest LOD levels (negative = all of them). Entries are
# re-validated on the way out: a chunk can be despawned or leave the detail ring between
# being queued and being reached, and those are simply dropped.
func _drain_detail_queue(limit: int) -> void:
	if _detail_queue.is_empty():
		return
	var detail := detail_ring()
	var built := 0
	while not _detail_queue.is_empty() and (limit < 0 or built < limit):
		var coord: Vector2i = _detail_queue.pop_front()
		_queued_for_detail.erase(coord)   # every exit path below leaves the queue, so erase once
		var chunk: TerrainChunk = _chunks.get(coord)
		if chunk == null:
			continue
		var d := maxi(absi(coord.x - _last_focus_coord.x), absi(coord.y - _last_focus_coord.y))
		if d > detail:
			continue
		chunk.set_finest_detail(self, _chunk_cache.get(coord, {}), true)
		built += 1


# Build every queued finest LOD level right now. Used behind the loading screen (and by
# tests) where a synchronous cost is free and a partially-detailed ring would show.
func flush_detail_queue() -> void:
	_drain_detail_queue(-1)


# Create-on-first-use, then flip visibility; rebuild when turning on.
func _toggle_chunk_borders() -> void:
	if _border_debug == null:
		_border_debug = ChunkBorderDebug.new()
		_border_debug.name = "ChunkBorderDebug"
		add_child(_border_debug)
	_border_debug.visible = not _border_debug.visible
	_border_debug.rebuild(self, _chunks.keys(), _last_focus_coord)


func _focus_node() -> Node3D:
	if _focus_cached != null and is_instance_valid(_focus_cached):
		return _focus_cached
	_focus_cached = null
	if focus_path.is_empty():
		return null
	_focus_cached = get_node_or_null(focus_path) as Node3D
	return _focus_cached


# Reconcile the loaded 3x3 set to be centred on `pos`. Cheap to call every
# frame: only does work when the focus crosses into a new chunk.
func update_focus(pos: Vector3) -> void:
	var center := chunk_coord_for(pos)
	if center == _last_focus_coord and not _chunks.is_empty():
		return
	_last_focus_coord = center
	_reconcile(center)


func _reconcile(center: Vector2i) -> void:
	var wanted := target_coords(center)
	# The despawn test is PURE ARITHMETIC, not `wanted.has(coord)`. `target_coords` is exactly the
	# Chebyshev ball of radius `load_radius`, so membership is one maxi/absi — whereas the Array
	# `has` is a linear scan, i.e. 441 x 441 ≈ 195k Vector2i comparisons per crossing at
	# load_radius 10. That showed up directly in the measured `update_focus` spike.
	for coord in _chunks.keys():
		var c: Vector2i = coord
		if maxi(absi(c.x - center.x), absi(c.y - center.y)) > load_radius:
			_chunks[coord].queue_free()
			_chunks.erase(coord)
	# SPREAD THE SPAWNS when a budget is set. A crossing pulls in a whole ring ROW at once —
	# 9 coords at load_radius 4, 21 at radius 10 — and spawning them all in this one call means
	# that many mesh + HeightMapShape3D builds in a single frame. Measured at ~140 ms, i.e. the
	# chunk-boundary hitch. Note `detail_builds_per_frame` governed only the finest-LOD queue
	# (_drain_detail_queue) and never chunk spawning, so the configured build budget was not
	# actually bounding this.
	#
	# Nearest-first, and only the FAR entries defer: `collision_ring` is 1 (a 3x3 band), so what
	# the car can physically reach is always spawned this frame, and a deferred coord is a couple
	# of hundred metres away — many frames of driving before it is needed.
	if spawn_budget > 0:
		_enqueue_spawns(wanted, center)
		return
	# ONE supply ladder, in `_spawn_one`. This loop used to carry its own near-duplicate copy of
	# it, and the two had already diverged: different error text, and only one of them had the
	# corridor arm. That is the same "two parallel implementations of one rule" shape that produced
	# most of the open-world bugs, so there is now exactly one.
	for coord in wanted:
		if _chunks.has(coord):
			continue
		_spawn_one(coord)
	# Collision only on the near band: chunks within `collision_ring` of the focus
	# carry live collision, farther loaded (render-only) chunks disable theirs. The
	# detail ring does the same for the lazily-built finest LOD level (a no-op on
	# chunks whose level 0 was prebaked or pruned).
	var detail := detail_ring()
	for coord in _chunks:
		var d := maxi(absi(coord.x - center.x), absi(coord.y - center.y))
		var chunk: TerrainChunk = _chunks[coord]
		chunk.set_collision_enabled(d <= collision_ring)
		if not chunk.is_finest_deferred():
			continue
		if d > detail:
			chunk.set_finest_detail(self, {}, false)   # dropping reads no data
		elif not chunk.has_finest_mesh() and not _queued_for_detail.has(coord):
			_queued_for_detail[coord] = true
			_detail_queue.append(coord)
	# Nearest first: if the player is about to see one of these at full detail, it is the
	# closest one.
	#
	# COST NOTE (spec item 5). This loop plus the sort was sized for a 7x7 = 49-chunk ring and
	# is quadratic-ish at 21x21 = 441. The `_detail_queue.has(coord)` linear scan — the O(n^2)
	# half — is gone: membership is now an O(1) `_queued_for_detail` dictionary kept in step
	# with the array (see _drain_detail_queue, which erases on every exit path). The re-sort per
	# reconcile is KEPT deliberately and not rewritten: it is O(n log n) on a queue that only
	# ever holds chunks inside `detail_ring()` (2 at the shipped tunables, i.e. a 5x5 = 25-chunk
	# cap regardless of load_radius), and it runs only when the focus CROSSES a chunk boundary,
	# not per frame. A heap or an incremental insert would be a risky rewrite of the detail path
	# for no measured gain. If detail_ring() is ever raised so the queue holds hundreds of
	# entries, revisit it then.
	_detail_queue.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return maxi(absi(a.x - center.x), absi(a.y - center.y)) \
			< maxi(absi(b.x - center.x), absi(b.y - center.y)))
	# Trim the cache to its cap now the window has moved (no-op without a cap — every stage).
	evict_to_cap()
	# Keep the debug overlay in sync when the loaded set changes (crossing).
	if _border_debug != null and _border_debug.visible:
		_border_debug.rebuild(self, _chunks.keys(), center)


# Fill a cache miss in `stream_on_miss` mode, then spawn from the cache.
#
# This is a CORRECTNESS FALLBACK, not the supply mechanism. The design's whole point is that
# the chunk store (or a precompute) runs well ahead of the car; reaching here means the
# resident window is mis-sized or the store has a gap, and it costs a mid-drive build hitch —
# so it LOGS, once. Once, not per coord and not per frame: a boundary crossing re-visits the
# same coords every frame until they are built, and per-coord logging across a 441-chunk
# window would itself be the frame cost.
#
# It routes through cache_chunk() rather than `_spawn_chunk(coord, compute_chunk_data(coord))`,
# and that is the point of the function. The raw on-demand branch has two side effects that
# must not be inherited:
#
#  1. It hands TerrainChunk.apply_data a dict with no `lod_meshes`, so the NODE builds all five
#     LOD levels itself. Such a chunk never joins the lazy finest-LOD path (`_lazy_finest`
#     stays false), so it pins level-0 VRAM until it first despawns — 441 of those is exactly
#     the allocation lazy_finest_lod exists to avoid. Going through cache_chunk instead
#     prebakes the levels the same way the precompute does, honours lazy_finest_lod, builds the
#     collision shape once, and drops DEAD_AFTER_PREBAKE.
#  2. It reads the road/cliff bake fields, which free_load_only_data() deletes. A bounded world
#     never frees them (see free_load_only_data), so the intended caller is safe; a stage that
#     turned this on after the free would get UNFLATTENED ground, so say so loudly rather than
#     silently shipping wrong geometry.
func _stream_chunk(coord: Vector2i) -> void:
	if not _miss_stream_logged:
		_miss_stream_logged = true
		print("terrain stream-on-miss: built %s on demand — the resident chunk window or the "
			% coord + "chunk store is undersupplied for the focus (this is a fallback, and it "
			+ "costs a build hitch). Logged once per session.")
		if _bake_fields_freed:
			push_error("terrain stream-on-miss after the road/cliff bake fields were freed "
				+ "— streamed chunks will be built unflattened")
	stream_on_miss_builds += 1
	cache_chunk(coord)
	if _chunk_cache.has(coord):
		_spawn_chunk(coord, _chunk_cache[coord])


# Try to satisfy `coord` from the attached chunk store (the on-disk precompute) and spawn it.
# Returns true if it spawned. NOT a generate: on a store miss, or a record that fails its CRC,
# this answers false and the caller leaves a loud hole.
#
# The rehydrated data is inserted into `_chunk_cache` so a boundary crossing that re-visits the
# same coord does not re-read the file every time — the LRU is what bounds it again.
# Queue the coords `wanted` needs that are not spawned yet, nearest to `center` first, and
# spawn immediately only what is close enough to matter this frame. `_drain_spawn_queue` does
# the rest over the following frames.
func _enqueue_spawns(wanted: Array, center: Vector2i) -> void:
	var pending: Array[Vector2i] = []
	for coord in wanted:
		if _chunks.has(coord):
			continue
		pending.append(coord)
	if pending.is_empty():
		_spawn_queue.clear()
		return
	pending.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return (a - center).length_squared() < (b - center).length_squared())
	# Anything inside the COLLISION BAND is spawned NOW regardless of budget — that is ground the
	# car can touch, and a hole there is a fall-through, not a cosmetic gap. The project chose loud
	# holes over generate-on-miss, so this set is the one place a hole is not an option.
	#
	# The bound is `collision_ring` EXACTLY, not `collision_ring + 1`. The forced set is what must
	# exist before the queue gets another frame, and `collision_ring` is by definition the band that
	# carries live collision (see the set_collision_enabled loop below) — a chunk one ring further
	# out cannot be touched by the car until it has itself become part of the collision band, which
	# takes a whole chunk of travel (50 m, i.e. well over a second at any speed the car reaches) and
	# therefore many frames of budgeted draining. The extra ring was costing 5 immediate builds per
	# crossing instead of 3 — a 3x3 crossing adds one ROW of 3 — and immediate builds are exactly
	# the `update_focus` half of the measured chunk-boundary spike. Nothing about the no-hole
	# guarantee weakens: the band the car can stand on is still complete before this call returns.
	var forced := collision_ring
	var deferred: Array[Vector2i] = []
	for coord in pending:
		if maxi(absi(coord.x - center.x), absi(coord.y - center.y)) <= forced:
			_spawn_one(coord)
		else:
			deferred.append(coord)
	# Partitioned in ONE pass rather than built-then-`erase`d: Array.erase is a linear scan plus a
	# shift, so the old shape was quadratic in the size of the forced set.
	_spawn_queue = deferred
	_drain_spawn_queue(spawn_budget)


# Spawn up to `limit` queued chunks (negative = all). Entries are re-validated on the way out:
# the car can turn around between a coord being queued and being reached, and those are dropped
# rather than spawned into a window that no longer wants them.
func _drain_spawn_queue(limit: int) -> void:
	if _spawn_queue.is_empty():
		return
	# The ring test below is PURE ARITHMETIC. This used to rebuild `target_coords` — a fresh
	# 441-entry Array — EVERY FRAME the queue was non-empty, and then ask it `wanted.has(coord)`,
	# a linear scan, once per drained coord. `target_coords` is exactly the Chebyshev ball of
	# radius `load_radius`, so one maxi/absi answers the same question with no allocation at all.
	var center := _last_focus_coord
	var built := 0
	# `limit <= 0` is UNLIMITED here, matching spawn_budget's documented "0 = off, spawn
	# the whole row in one call". It used to read `limit < 0`, which meant a budget of 0
	# drained exactly zero entries per frame and stranded anything already queued
	# forever — a hole in the world that never fills. Inert in practice, because
	# _reconcile only queues behind its `spawn_budget > 0` branch, but the two readings
	# of the same field disagreed and only the queue-filling side knew it.
	# NOTE the deliberate asymmetry with _drain_detail_queue, which keeps `limit < 0`:
	# there 0 legitimately means "build no finest LODs this frame" (a blurrier chunk,
	# not a missing one), so zero is a real setting rather than a disabled budget.
	while not _spawn_queue.is_empty() and (limit <= 0 or built < limit):
		var coord: Vector2i = _spawn_queue.pop_front()
		if _chunks.has(coord):
			continue
		if maxi(absi(coord.x - center.x), absi(coord.y - center.y)) > load_radius:
			continue
		_spawn_one(coord)
		built += 1


# One chunk, from whichever supply the mode allows. Factored out of _reconcile so the immediate
# path and the queued path cannot diverge.
func _spawn_one(coord: Vector2i) -> void:
	# ORDER IS LOAD-BEARING. The store read must come BEFORE the on-demand build, not after: the
	# on-demand arm fires whenever `_chunk_cache` is empty, so with the store arm below it an
	# attached store was unreachable in exactly the case it exists for — an empty resident cache —
	# and every coord took the raw `compute_chunk_data` route instead. That route is the one dict
	# shape with no prebaked `lod_meshes`, no `l0_light` and no prebuilt `shape`, i.e. precisely the
	# divergence `_stream_chunk`'s docstring says must not be inherited.
	if _chunk_cache.has(coord):
		_spawn_chunk(coord, _chunk_cache[coord])
	elif stream_on_miss:
		_stream_chunk(coord)
	elif _read_from_store(coord):
		# The healthy path when a store is attached: one seek and one read off the precompute,
		# then post-processed and made resident by cache_chunk. Not a generate.
		pass
	elif _chunk_cache.is_empty():
		# Editor / tests with no store: silent on-demand build.
		on_demand_builds += 1
		_spawn_chunk(coord, compute_chunk_data(coord))
	elif (has_bounds() or _corridor_class.has(coord)) and not _logged_misses.has(coord):
		# Prefer a HOLE over a mid-drive build hitch, and log once per coord.
		#
		# The `_corridor_class` half is load-bearing for STAGES and must not be dropped: since the
		# off-track reset went timed the car is no longer leashed inside the corridor, so a big
		# enough launch can simply leave it. That is expected, not a bug, and an OUT-of-corridor
		# miss must stay SILENT (test_terrain: "an excursion beyond the corridor logs nothing").
		# Only an in-corridor miss breaks an invariant.
		#
		# In a BOUNDED world every in-bounds coord is precomputed and the enumeration is grown by
		# the load radius, so there is no legitimate excursion — every miss is a bug.
		_logged_misses[coord] = true
		if has_bounds():
			push_error(("terrain cache miss at %s in a BOUNDED world (leaving a hole) — the "
				+ "precompute did not cover this coord, or the cache is stale/undersupplied. "
				+ "Check the load radius against the precomputed margin.") % coord)
		else:
			push_error("terrain cache miss at %s — corridor region invariant broke (leaving a hole)"
				% coord)


func _read_from_store(coord: Vector2i) -> bool:
	if chunk_source == null or not chunk_source_has(coord):
		return false
	# `cache_chunk` is the right vehicle rather than a hand-rolled read: it routes through
	# `chunk_data_for` (which prefers the store), then does the post-processing a spawnable chunk
	# needs — the prebaked LOD meshes, the encoded light, the collision shape for a banded chunk —
	# so this path cannot drift from the precompute's.
	#
	# Caveat, stated rather than hidden: if the record is on disk but fails its CRC,
	# `chunk_data_for` falls through and REGENERATES that one chunk. That is a corruption
	# fallback, not the every-crossing generate this replaced, and `store_reads` vs
	# `stream_on_miss_builds` is how you tell them apart.
	cache_chunk(coord)
	if not _chunk_cache.has(coord):
		return false
	store_reads += 1
	_spawn_chunk(coord, _chunk_cache[coord])
	return true


func _spawn_chunk(coord: Vector2i, data: Dictionary) -> void:
	var chunk: TerrainChunk = ChunkScript.new()
	add_child(chunk)
	chunk.apply_data(self, coord, data)
	_chunks[coord] = chunk
	integrations_total += 1


func _rebuild_loaded() -> void:
	_noise_cache_valid = false  # seed / layers / wavelength changed
	if _bake_fields_freed:
		# The road/cliff bake fields were dropped at load_finished, so a refill here
		# would rebuild the corridor UNFLATTENED (and cliff-less) — geometry that no
		# longer matches the track. Loud, because the symptom is purely visual/physical.
		push_error("terrain params changed after the road/cliff bake fields were freed "
			+ "— rebuilt chunks would lose the road flatten; re-bake the track first")
	# Refilling repopulates the per-chunk baked light, so the freed sentinel lifts.
	_lights_freed = false
	# Stale cached arrays must never survive a terrain-param change; refill for
	# the stored corridor (dev-time synchronous hitch is fine — this only fires
	# from the inspector / tests).
	_chunk_cache.clear()
	for coord in _corridor_coords:
		cache_chunk(coord)
	for chunk in _chunks.values():
		chunk.setup(self, chunk.coord)
