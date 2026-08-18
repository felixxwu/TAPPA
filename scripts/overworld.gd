class_name Overworld
extends Node3D
# The OVERWORLD hub — a life-size drivable version of the world map (features/overworld.md,
# docs/superpowers/specs/2026-08-17-overworld-hq-design.md). Shaped like world.gd but with
# every stage-specific system removed: no StageManager, no start line, no pacenotes, and
# deliberately NO TrackProgress (it teleports a far-off-road car back to the road within
# seconds, which in a roadless open world would fight the player constantly).
#
# NOTHING HERE RUNS UNLESS `GameConfig.overworld_enabled` IS ON. The flag ships false and is
# read at boot by hq.gd's redirect and by Scenes.hub_path(); this scene is unreachable
# without it (the one way in is Settings → Dev → "Enter the Overworld HQ").
#
# ORDER OF OPERATIONS in _ready mirrors world.gd's and is load-bearing in the same places:
# region look → floor material → deep snow → terrain seed/layers → apply_terrain_light BEFORE
# the first chunk build (so the sun is folded into the first chunks' vertex colours) →
# apply_terrain_lod → bounds + chunk store → car fielding → controls_locked → precompute →
# build_initial → horizon → water → foliage → FPS cap → pause arming.


# The two borders, kept apart on purpose (spec, "Two different borders"):
#   COASTLINE  — the fixed perimeter of the map, built by TerrainManager's height taper.
#   FOG FRONTIER — the edge of what the player has revealed, a union of circles that GROWS.
# The coastline lives in the terrain; the frontier lives in _process below.

# How far outside the lit frontier the car is nudged back before we give up and teleport it to
# the last lit pose. A soft push (D4) rather than a collider, because the lit region is a union
# of circles and a scalloped invisible wall reads as a bug.
#
# A VISUAL WALL WAS ADDED LATER, AND A COLLIDER IS STILL REFUSED. `OverworldFogWall` stands a
# translucent curtain on the frontier so the player sees the edge before the veil and the shove
# explain it — the player's own request. It is a WARNING for this push, not a replacement: it has no
# collision shape and applies no force, and `_update_fog_boundary` below remains the ONLY thing that
# moves the car. The two are compatible precisely because D4 rejected a *collider*, not a picture of
# where the boundary is.
## Metres between the zone's trigger circle and where the car is parked on return from that rally.
## Enough that the car is clearly outside the dwell radius (so the zone's arm-on-exit latch is armed
## the moment the player lands) rather than balanced on its edge, where a nudge would re-open the
## card the player has just come back from.
const RETURN_SPAWN_MARGIN_M := 6.0

# What this boot's spawn stands outside of and faces — the rally just completed, or the garage on a
# cold start — plus how far outside. Recorded by `_resolve_spawn_pose` because the road snap that
# follows needs both, and the roads do not exist yet at the moment the pose is resolved.
var _spawn_face_target := Vector2.INF
var _spawn_gap_m := 0.0

const FOG_PUSH_ACCEL := 6.0          # m/s^2 of inward nudge while beyond the frontier
const FOG_HARD_MARGIN_M := 120.0     # beyond this, snap back to the last lit pose
const FOG_VEIL_ALPHA := 0.55         # how dark the screen goes at the hard margin
const FOG_VEIL_FADE := 2.5           # veil alpha units per second

# The GLOBAL shader uniforms the terrain shader must declare for the fog frontier to darken
# the ground (spec slice 3: "fed to the terrain shader as a global uniform"). Pushed only if
# they exist, see _push_fog_uniforms.
const FOG_GLOBAL_MASK := "ow_fog_mask"
const FOG_GLOBAL_SIZE := "ow_fog_size_m"
const FOG_GLOBAL_UNLIT := "ow_fog_unlit"
# The master switch. 0 makes the fog a bit-for-bit no-op, which is what every OTHER scene must
# see — these globals outlive a scene change and the same shaders draw every stage.
const FOG_GLOBAL_AMOUNT := "ow_fog_amount"

# The zone/dwell/marker/ghost-car layer, owned by a sibling module. Loaded by path and
# duck-typed so this file never hard-depends on it — see _build_zones.
const ZONES_SCRIPT := "res://scripts/overworld_zones.gd"

# The car body the zone layer clones for a car-unlock zone's ghost. Loaded on demand rather
# than preloaded: the scene already instances one Car of its own, and a preload here would
# pull the whole body in again during script parse, including headless test runs that build
# no zones at all.
const CAR_SCENE_PATH := "res://car.tscn"

# The reserved zone id for the garage. Not a rally id, and `_on_zone_activated` routes it to
# the garage BUILDING rather than to a rally pick, and it is what the map labels that destination
# with (OverworldMap.GARAGE_ID mirrors it). Kept distinct from any possible roster id.
const GARAGE_ZONE_ID := "garage"

# How far PAST the road's feathered shoulder to keep foliage. Wants promoting to GameConfig with
# the rest of the `overworld_road_*` knobs once the roads have been driven and tuned.
const ROAD_FOLIAGE_MARGIN_M := 3.0

# A frame longer than this is a SPIKE worth attributing. ~2x a 60 fps budget, so an ordinary
# frame never prints and a visible stutter always does. See _log_frame_spike.
const SPIKE_MS := 33.0

# How many chunks the whole map may have before it stops being held resident and the LRU takes
# over. A full-res chunk's retained arrays run ~0.12 MB, so ~800 is on the order of 100 MB —
# comfortably past what a stage keeps and the point where streaming has to earn its cost again.
# At the shipped 1 km the map is ~400 (plus the load-radius margin), so it stays resident.
const RESIDENT_MAP_CHUNK_LIMIT := 800

# Frame caps for the load window and after it — same reasoning (and same values) as
# world.gd's: a low cap paces every awaited frame the precompute performs.
const LOADING_MAX_FPS := 0
const LOADING_TOUCH_MAX_FPS := 60

# Chunks generated per awaited frame during the first-launch precompute. world.gd's corridor
# precompute uses 8; the overworld's pass is far longer, so it reports a count as it goes.
const PRECOMPUTE_BATCH := 8

# Terrain shader parameter the deep-snow ground raise uses; kept in step with world.gd.
const TERRAIN_BASE_SHADER := preload("res://shaders/ps1_models.gdshader")
const TERRAIN_SNOW_SHADER := preload("res://shaders/ps1_terrain_snow.gdshader")

# --- The cheap test path ------------------------------------------------------------------
#
# A life-size overworld that a test instantiates fully is over the suite's ~5 minute budget by
# construction. So the scene ships a cheap mode: a tiny world, no disk cache, no first-launch
# precompute, no foliage, no horizon backdrop and a 1-chunk load ring.
#
# HOW A TEST SELECTS IT: set the static BEFORE instancing overworld.tscn, e.g.
#
#     Overworld.load_mode = Overworld.LoadMode.CHEAP
#     var ow: Overworld = load("res://overworld.tscn").instantiate()
#     add_child(ow)                       # _ready runs synchronously under --headless
#
# AUTO (the default) resolves to CHEAP under --headless and FULL otherwise, so the whole test
# suite gets the cheap path for free and a test only touches this to opt a headless run INTO
# full generation. Statics, not exports, because the choice must be made before _ready and the
# scene is instanced from code in both hubs.
enum LoadMode { AUTO, CHEAP, FULL }
static var load_mode: int = LoadMode.AUTO
## World edge length used in CHEAP mode, in metres. Small enough that the coastline taper and
## the load ring are both a handful of chunks.
static var cheap_size_m := 300.0

# Every frame cap _ready applied, in order: [loading cap, post-load cap]. Recorded even under
# headless (where the Engine write is suppressed) so tests can assert the INTENT, exactly as
# world.gd's identically-named array does.
var applied_fps_caps: Array[int] = []

## Emitted once the world is built and playable. Fires on EVERY path including headless, so
## tests can await it (under headless generation is synchronous, so it has already fired by
## the time add_child returns).
signal world_ready

var _headless := false
var _cheap := false
# UNSET BY CONSTRUCTION, both of them — the same idiom as `_spawn_face_target` above. These used to
# carry plausible defaults (`_size_m := 4000.0`, four times the shipped 1000), which meant an early
# read answered successfully and the boot continued with a coherent but wrong world rather than
# failing. `size_m()` and `bounds()` are public, so that window was reachable from outside. Both are
# resolved in the `_ready` preamble; the accessors assert they have been.
var _size_m := 0.0
var _bounds := Rect2()
var _ready_done := false

var _floor_tm: TerrainManager = null
var _cache: OverworldCache = null
var _region: OverworldRegion = null
var _scatter: OverworldScatter = null
var _lake: LakeField = null
var _distant: DistantTerrain = null
var _zones: Object = null
# THE RALLY-DETAIL PANEL, shared with the HQ map table (`RallyDetail`). Driving into a zone opens
# this rather than starting anything — see _on_zone_activated.
var _detail_ui: RallyDetail = null
# The rally the open panel is showing, so Back knows which zone to cancel.
var _detail_rally_id := ""
# Did WE take the car's control lock when the panel opened? Same discipline as
# `_map_locked_controls` — see _lock_for_detail.
var _detail_locked_controls := false
# The translucent curtain standing on the fog frontier — the WARNING for the soft push, never a
# collider. See _build_fog_wall and scripts/overworld_fog_wall.gd.
var _fog_wall: OverworldFogWall = null
# THE DIEGETIC CAR PICKER (`OverworldPicker`): the camera swings in front of the parked car and a
# menu replaces it as the player browses. Rally picks and the STARTER pick both run through it.
var _picker: OverworldPicker = null
# Did WE take the car's control lock for the picker? Only the STARTER flow does — a rally pick is
# opened from the detail card, which is already holding it. See _lock_for_picker.
var _picker_locked_controls := false
# The concrete roadblocks standing across the roads that lead somewhere still dark. See
# _build_blocks and scripts/overworld_blocks.gd.
var _blocks: OverworldBlocks = null
# The garage BUILDING (scripts/overworld_garage.gd) — driven into, not dwelled on.
var _garage: OverworldGarage = null
# Where the garage stands this session — RallyLibrary.hq_map_pos(profile), resolved in _ready and
# then FIXED. See the note at the call site for why it cannot move while the world is alive.
# Vector2.INF rather than RallyLibrary.HQ_MAP_POS (the map centre): the centre is exactly the
# plausible-looking wrong answer that let the launch spawn resolve before this did, putting the car
# in the grass while the garage and roads were built beside the player's first-car rally.
var _hq_map_pos := Vector2.INF
# The road network between the rally pins. Built in _build_world, consumed by the terrain carve,
# the foliage clearance and (indirectly) the spawn, which starts on a road node.
var _roads: OverworldRoads = null
# The FLAT PADS baked under every rally zone and under the garage. Built in _ready right after
# the road network, consumed by the terrain flatten, the foliage clearance and the chunk cache
# key. See scripts/overworld_pads.gd.
var _pads: OverworldPads = null
# The sky cross-fade in flight, if any — colours AND panorama ride this ONE tween, so the haze
# and the sky can never disagree. See _fade_sky.
var _look_tween: Tween = null
# The minimap + the full-screen map (M). See _build_map.
var _map: OverworldMap = null
# The per-car visual effects ported from the stage — see _build_effects.
var _tire_marks: TireMarks = null
var _wheel_particles: WheelParticles = null
var _exhaust_flames: ExhaustFlames = null
# Whether the map overlay is the thing holding the car's controls locked, so closing it does
# not release a lock somebody else (the loading path) took.
var _map_locked_controls := false
# Whether to print frame-spike attribution. Resolved once in _ready — debug builds only, and
# OVERWORLD_SPIKE_LOG=0 mutes it.
var _spike_log := false

# Region the look is currently dressed for, so a crossing re-applies it exactly once.
var _look_region := ""

# Two ranks closer together than this count as the same region for blending purposes — a guard on
# the shader's inverse-lerp, which divides by their difference. Ranks are evenly spaced over 0..1
# across the roster's regions, so this is orders of magnitude below any real gap.
const REGION_RANK_EPSILON := 0.0001

# Length of the ground shaders' rank->look LUT arrays (`region_tint[8]` etc. in
# ps1_models.gdshader / ps1_terrain_snow.gdshader). A roster with more regions than this would
# have to drop the tail, so region_look_lut warns rather than silently mis-colouring; bump BOTH
# the shaders and this constant together if the roster ever grows past it.
const REGION_LUT_MAX := 8

# The canonical region-rank field baked into the terrain (UV2.y) and decoded by the ground
# shader. null when region blending is off (config) or in the cheap/test path, in which case the
# terrain never writes UV2.y and the shader keeps `blend_region` false — the ground then behaves
# exactly as it did before spatial blending existed.
var _region_blend: RegionBlendSource = null
# The all-regions rank->look LUT is static for the whole session (it depends only on the roster's
# region set and each region's authored look), so it is uploaded once and never touched again.
var _region_lut_pushed := false
# The scene's own ground textures, captured before any region overrides them. See
# _capture_ground_baseline.
var _ground_baseline_captured := false
var _base_grass_texture: Texture2D = null
var _base_gravel_texture: Texture2D = null

# --- Sky cross-fade state (see _fade_sky) -------------------------------------------------
# The scene's own panorama, captured before any region overrides it — the fallback for a region
# that authors none AND for a config with no default, same role as _base_grass_texture.
var _sky_baseline_captured := false
var _base_sky_texture: Texture2D = null
# The live blend weight between the two panorama slots. The fade alternates slots rather than
# copying B back into A, so the "collapse" after a fade is just this weight landing exactly on
# 1.0 or 0.0 — and which slot is on screen is derived from it (see sky_live_slot), never tracked
# separately, so the two can never drift apart.
var _sky_blend := 0.0


## The REGION FIELD the terrain bakes from — the duck-typed `region_source` TerrainManager calls
## (`region_rank_at`). Kept as a small object rather than as methods on Overworld so the rank
## maths can be tested without instancing the scene.
##
## THE RANK. Each region id in the live rally roster gets one fixed number in 0..1, assigned by
## SORTED id so the assignment is stable across launches (it must be: it is baked into the chunk
## cache). `region_rank_at` interpolates those numbers by OverworldRegion.region_weights_at, so
## the field is a pure, continuous function of position: exactly a region's own rank deep inside
## it, sliding between two ranks across a boundary. The ground shader recovers a 0..1 blend factor
## for whichever PAIR it currently has uploaded by inverse-lerping between their two ranks — which
## is what lets one baked, cacheable channel serve a pair chosen at runtime.
class RegionBlendSource extends RefCounted:
	var _lookup: OverworldRegion = null
	var _world_size_m := 0.0
	# region id -> rank, and the sorted id list it was derived from (also the cache stamp).
	var _ranks: Dictionary = {}
	var _ids: PackedStringArray = PackedStringArray()

	func _init(lookup: OverworldRegion, world_size_m: float) -> void:
		_lookup = lookup
		_world_size_m = world_size_m
		var seen: Dictionary = {}
		for rally in RallyLibrary.all():
			var region_id := String(rally.get("region", ""))
			if region_id != "":
				seen[region_id] = true
		var ids: Array[String] = []
		for key in seen:
			ids.append(String(key))
		ids.sort()
		_ids = PackedStringArray(ids)
		var last := maxi(ids.size() - 1, 1)
		for i in ids.size():
			_ranks[ids[i]] = float(i) / float(last)

	## The 0..1 canonical region rank at a world XZ. The one method TerrainManager calls.
	func region_rank_at(x: float, z: float) -> float:
		if _lookup == null:
			return 0.0
		var weights := _lookup.region_weights_at(
			Overworld.map_pos_of(Vector3(x, 0.0, z), _world_size_m))
		var out := 0.0
		for key in weights:
			out += float(weights[key]) * rank_of(String(key))
		return clampf(out, 0.0, 1.0)

	## The rank of one region id; 0.0 for an id the roster does not mention.
	func rank_of(region_id: String) -> float:
		return float(_ranks.get(region_id, 0.0))

	## Every ranked region id, in rank order (which is sorted-id order, by construction). The
	## ordering is what makes the shader's rank->look LUT a sorted table it can bracket-search.
	func ids() -> PackedStringArray:
		return _ids

	## Everything the baked rank field derives from — the region id SET and its ordering. Folded
	## into the chunk cache's invalidation key by Overworld._open_chunk_cache, because adding or
	## removing a region shifts every other region's rank and therefore every stored chunk's UV2.y.
	func stamp() -> int:
		# Joined into a String first: PackedStringArray has no hash() of its own, and the join
		# preserves ORDER, which is the whole point — a region's rank is its index, so a reordering
		# must invalidate even when the set is unchanged.
		return "|".join(_ids).hash()

# Foliage streaming: chunk coord -> the nodes that chunk owns, so a chunk leaving the ring
# frees its own props. Chunks are filled a few per frame from _process.
var _foliage: Dictionary = {}
var _foliage_radius := 4

# Fog frontier state.
var _fog_veil: ColorRect = null
var _veil_alpha := 0.0
var _last_lit_pose := Transform3D.IDENTITY
var _has_lit_pose := false

# Pause-menu quit interception, see _process.
var _pause_was_open := false

# Frames between chunk-cache eviction sweeps (see _process).
const EVICT_INTERVAL := 30
var _evict_countdown := EVICT_INTERVAL

# Frames between region-look checks (see _process).
const REGION_INTERVAL := 20
var _region_countdown := REGION_INTERVAL


# ==========================================================================================
# Coordinates — the SINGLE SOURCE OF TRUTH for map_pos <-> world XZ.
# ==========================================================================================

## Normalised map position -> world XZ, at a world edge length of `size_m`. `map_pos.y` maps
## to world Z, matching the map table's convention at a different scale. Static so a test can
## exercise the round trip with no scene at all.
static func world_xz(map_pos: Vector2, size_m: float) -> Vector3:
	var p := (map_pos - Vector2(0.5, 0.5)) * size_m
	return Vector3(p.x, 0.0, p.y)


## The exact inverse of world_xz. Y is ignored.
static func map_pos_of(pos: Vector3, size_m: float) -> Vector2:
	if size_m == 0.0:
		return Vector2(0.5, 0.5)
	return Vector2(pos.x, pos.z) / size_m + Vector2(0.5, 0.5)


## The world rectangle for a map of `size_m` metres, centred on the origin — the same
## convention world_xz uses, so the map's corners are the rect's corners.
static func bounds_for(size_m: float) -> Rect2:
	return Rect2(Vector2(-size_m * 0.5, -size_m * 0.5), Vector2(size_m, size_m))


## The live world edge length in metres (`overworld_size_m`, or the cheap-mode size).
## Asserts the boot preamble has run: reading this early used to return a plausible 4000 and let the
## caller carry on with a world four times the shipped size. GDScript has no `final`, so an assert
## on the unset sentinel is the enforceable version of "resolved once, then read-only".
func size_m() -> float:
	assert(_size_m > 0.0, "Overworld.size_m() read before _ready resolved it")
	return _size_m


## The live world rectangle in world XZ metres. Guarded like size_m() — it is derived from it.
func bounds() -> Rect2:
	assert(_bounds.size.x > 0.0, "Overworld.bounds() read before _ready resolved it")
	return _bounds


## The live map position of the fielded car.
## The roadblock layer, or null (cheap mode / before the build). Read-only seam for tests and
## for anything that wants to ask which roads are currently closed.
func blocks() -> OverworldBlocks:
	return _blocks


func car_map_pos() -> Vector2:
	var car := get_node_or_null("Car") as Node3D
	if car == null:
		return Vector2(0.5, 0.5)
	return map_pos_of(car.global_position, _size_m)


# ==========================================================================================
# Boot
# ==========================================================================================

func _ready() -> void:
	_headless = Platform.is_headless()
	_cheap = _resolve_cheap()
	_drain_hub_one_shots()
	_spike_log = OS.is_debug_build() and not _headless \
		and OS.get_environment("OVERWORLD_SPIKE_LOG") != "0"
	var cfg: GameConfig = Config.data
	_size_m = cheap_size_m if _cheap else cfg.overworld_size_m
	_bounds = bounds_for(_size_m)

	# WHERE THE GARAGE STANDS, resolved ONCE per hub build and threaded from here. It is beside the
	# player's first-car rally (RallyLibrary.hq_map_pos), so it is profile-derived rather than a
	# constant — and it feeds the road network and the garage pad, both of which are folded into the
	# chunk cache key, so it must not change while this world is alive.
	#
	# RESOLVED IN THE PREAMBLE, with the other boot values, and that is the whole point: it used to
	# sit ~40 lines below, AFTER the spawn was resolved. `_default_spawn_map_pos` returns this and
	# `return_pose_for` offsets away from it, so while it still held its declared default (the map
	# centre) the launch spawn was the map centre while the garage and the entire road network were
	# built beside the player's first-car rally — the car landed in the grass, nowhere near either.
	# It never needed to be down there: the only inputs are Save.profile, _size_m and Config.data,
	# all of which exist by this line. Keep every boot value resolved in this one block, so a late
	# read has no window to slip into.
	_hq_map_pos = RallyLibrary.hq_map_pos(Save.profile, _size_m)

	_region = OverworldRegion.new()
	# Built HERE, before the first look is applied further down, so the opening frame already
	# shows the region pair rather than a one-region ground until the first _process tick.
	# Attached to the terrain in _build_world, alongside the road network.
	if cfg.overworld_region_blend_enabled:
		_region_blend = RegionBlendSource.new(_region, _size_m)

	# Cover the screen before any heavy generation, exactly as world.gd does. Freed at the end
	# of _build_world.
	var loading := LoadingScreen.new()
	add_child(loading)

	# Per-target render quality, resolved ONCE before any scatter or LOD application.
	var web := Platform.is_web()
	var touch := Platform.is_touch()
	cfg.tree_render_distance_m = cfg.tree_render_distance_for(web, touch)
	cfg.terrain_lod_bands_m = cfg.terrain_lod_bands_for(web, touch)

	var fps_cap := FpsSetting.resolve()
	_apply_fps_cap(LOADING_TOUCH_MAX_FPS if touch else LOADING_MAX_FPS)

	# Environment: fog + background, then the region look on top (which owns the sky panorama
	# and the background/fog colour).
	var env: Environment = ($WorldEnvironment as WorldEnvironment).environment
	env.fog_density = cfg.fog_density
	env.background_color = cfg.background_color
	env.fog_light_color = cfg.background_color
	env.fog_sky_affect = cfg.fog_sky_affect

	# The spawn decides which region dresses the world for the first frame, so resolve it
	# before the look. (The car is seated at this pose further down; _reset_pose is pure.)
	var spawn := _resolve_spawn_pose()
	_apply_region_look(map_pos_of(spawn.origin, _size_m))

	# Floor material + terrain field, in world.gd's order.
	var tm := _floor()
	if tm.texture_tile_per_meter != cfg.terrain_tile_per_meter:
		tm.texture_tile_per_meter = cfg.terrain_tile_per_meter
	var floor_mat := tm.chunk_material as ShaderMaterial
	if floor_mat != null:
		var road_uv_scale := 1.0
		if cfg.terrain_tile_per_meter > 0.0:
			road_uv_scale = cfg.road_tile_per_meter / cfg.terrain_tile_per_meter
		floor_mat.set_shader_parameter("road_uv_scale", road_uv_scale)
	# The ROAD NETWORK, built before the first chunk so the carve can see it. Attached duck-typed
	# (TerrainManager guards with has_method), so a build without roads is still drivable.
	#
	# Roads run between the rally pins along the reveal graph — the same pairing the HQ table
	# already draws dashed lines for — so the roads lead where progression leads. The network is
	# progress-INDEPENDENT on purpose: a road must not appear as the player explores, or the world
	# would rearrange itself behind them.
	_roads = OverworldRoads.from_config(cfg)
	_roads.build(_size_m, _hq_map_pos)
	# The spawn pose was resolved BEFORE the road network existed (it has to be: the region look
	# above is chosen from it). Now that the roads are built, put it back ON one — a car returning
	# from a rally should be standing on the road that serves that zone, not on the verge beside it.
	spawn = _snap_spawn_pose_to_road(spawn)
	if tm.has_method("set_road_source"):
		tm.call("set_road_source", _roads)
	# The REGION FIELD, attached for the same reason and under the same rule as the road network:
	# it is baked into every chunk at generation time (UV2.y), so it must be seated before the
	# first chunk is built and it is part of the chunk cache's invalidation key.
	if _region_blend != null and tm.has_method("set_region_source"):
		tm.call("set_region_source", _region_blend)
	elif "road_source" in tm:
		tm.set("road_source", _roads)
	else:
		# The carve is a sibling change; without it the network still drives wayfinding and
		# foliage clearance, the ground is just uncarved.
		push_warning("overworld: TerrainManager has no road source yet — roads are not carved")
	_apply_deep_snow_ground(cfg)
	# The hub's OWN height noise, not the stages' terrain_layer* / track_seed. A stage is a
	# narrow corridor where big relief reads as drama; the hub is a 1 km square crossed
	# constantly, where the same relief walls two rally zones off from each other. See
	# GameConfig's "Overworld terrain NOISE" block. Both of these are in the chunk cache's
	# invalidation key, so retuning either rebakes the map rather than serving stale ground.
	if tm.noise_seed != cfg.overworld_terrain_seed:
		tm.noise_seed = cfg.overworld_terrain_seed
	if not _layers_match(tm.layers, cfg.overworld_terrain_layers()):
		var layers: Array[TerrainLayer] = []
		for params in cfg.overworld_terrain_layers():
			var layer := TerrainLayer.new()
			layer.wavelength_m = params.x
			layer.amplitude_m = params.y
			layers.append(layer)
		tm.layers = layers
	# BEFORE the first chunk build, so the sun/ambient is folded into the first chunks'
	# vertex colours rather than applied to already-baked ones.
	# Arm the terrain's per-stage timing with the same switch as our own, so a spike frame can
	# name focus/spawn/detail instead of dumping them into `other`.
	tm.stage_timing = _spike_log
	cfg.apply_terrain_light(tm)
	cfg.apply_terrain_lod(tm)
	cfg.apply_cliffs(tm)

	# The bounded world: this REPLACES the track corridor as the bounds source and switches on
	# the coastline taper. Everything the overworld needs from the terrain manager (load
	# radius, build budget, generate-on-miss, encoded-light capture, the taper) is seated in
	# this one call, so it cannot be wired up half-way.
	tm.apply_overworld_bounds(cfg, _bounds)
	# Generate heights ON the lattice the chunk store round-trips through, so the resident grid and
	# a stored record are the same numbers and a cache round trip is exact. Set from the store's own
	# constant so the two can never drift apart.
	tm.height_quantum = 1.0 / OverworldCache.HEIGHT_SCALE
	# The FLAT PADS: a level circle of ground under every rally zone and under the garage, so the
	# tubes, markers, ghost cars and above all the garage BUILDING stand on flat ground instead of
	# straddling a slope. Attached duck-typed like the road network and, like it, part of the chunk
	# cache's invalidation key.
	#
	# WHY HERE, and not up beside the road network: a pad's LEVEL is the terrain's own generated
	# height at the pad centre, so the terrain has to be fully configured first — the seed, the
	# layers and (via apply_overworld_bounds) the coastline taper are all seated above this line,
	# and sampling before them would level the pads against a different world than the one that
	# gets built. Still comfortably before the first chunk exists (_build_world runs after _ready
	# returns), which is the hard requirement set_pad_source states.
	#
	# BUILD THEN ATTACH, in that order and never the reverse: `build` samples _noise_height_at,
	# which applies the pads. Attaching first would feed the pads their own output.
	_pads = OverworldPads.from_config(cfg)
	_pads.build(_size_m, Callable(self, "_zone_world_pos"), Callable(tm, "_noise_height_at"),
		_hq_map_pos)
	if tm.has_method("set_pad_source"):
		tm.call("set_pad_source", _pads)
	else:
		# A sibling change; without it the pads still keep foliage off the zones, the ground is
		# just not flattened.
		push_warning("overworld: TerrainManager has no pad source yet — zones are not flattened")
	# LRU cap for the resident chunk cache. There is no authored field for it (the design left
	# it "TBD by measurement"), so it is DERIVED from the load ring: the window is
	# (2*load_radius+1)^2 chunks and a full-res chunk's packed arrays run ~0.12 MB, so a cap
	# two rings wider than the built window can never evict something the player is standing on
	# (evict_to_cap enforces that independently) while still bounding a long drive.
	tm.cache_cap_mb = float((2 * tm.load_radius + 3) * (2 * tm.load_radius + 3)) * 0.15
	# ...UNLESS the whole map is small enough to stay resident, which at the shipped 1 km it is.
	#
	# The precompute now fills `_chunk_cache` for every chunk (see _write_chunk), so a crossing is
	# a pure cache pull like a stage's. An LRU sized to the load ring would immediately undo that:
	# it would evict the chunks just outside the window, and the next crossing would have to read
	# and rehydrate them again — reintroducing the very mesh build this removed.
	#
	# So: cap OFF while the map fits, and the derived ring cap applies only once it does not. A
	# stage holds ~200-350 chunks resident by exactly this reasoning; ~400 is the same order.
	# Counted from the BOUNDS, not from _map_chunk_coords(), which includes the disk-only margin.
	var span := maxf(_bounds.size.x, _bounds.size.y) / TerrainManager.CHUNK_M
	var map_chunks := int(ceil(span) * ceil(span))
	if map_chunks > 0 and map_chunks <= RESIDENT_MAP_CHUNK_LIMIT:
		tm.cache_cap_mb = 0.0
	if _cheap:
		# A 1-chunk ring and a handful of chunks total: enough to stand a car on ground and
		# assert on the coordinate mapping, cheap enough for the suite.
		tm.load_radius = 1
		tm.detail_builds_per_frame = 1
		tm.cache_cap_mb = 0.0

	# Post-process + car materials, as world.gd pushes them.
	cfg.apply_post_process(($PostProcess as SubViewportContainer).material as ShaderMaterial)
	var car := $Car as Node3D
	_push_car_materials(cfg, car)

	# Hold the car still for the whole boot: it is already in the tree and physics-processing,
	# so without this the player could drive off behind the loading screen.
	car.set("controls_locked", true)

	_field_car(car)
	($CameraManager as CameraManager).refresh_bonnet_offset()
	# Seat the car BEFORE build_initial, so the load ring is built around where the player
	# actually is rather than around the authored origin.
	_seat_car(car, spawn)

	await _build_world(cfg, loading)

	_apply_fps_cap(fps_cap)
	_ready_done = true
	world_ready.emit()


# CHEAP under --headless (the suite's default) or when a test asked for it explicitly.
func _resolve_cheap() -> bool:
	match load_mode:
		LoadMode.CHEAP:
			return true
		LoadMode.FULL:
			return false
		_:
			return _headless


# Apply a frame cap and record the intent. The Engine write is suppressed under --headless
# (nothing to pace, and it would throttle the frame-awaiting test runner).
func _apply_fps_cap(cap: int) -> void:
	applied_fps_caps.append(cap)
	if not _headless:
		Engine.max_fps = cap


# Yield a frame, collapsing to a no-op under headless so the whole build runs synchronously
# inside add_child() — the same contract world.gd's _yield_frame gives the test suite.
func _yield_frame() -> void:
	if not _headless:
		await get_tree().process_frame


func _build_world(cfg: GameConfig, loading: LoadingScreen) -> void:
	var tm := _floor()
	# Suspend the car's physics for the whole build: there is deliberately no terrain under it
	# until build_initial(), and frozen it simply waits at its spawn pose and drops onto real
	# ground when the ring exists.
	var body := $Car as RigidBody3D
	var was_frozen := body.freeze
	body.freeze = true

	_open_chunk_cache(cfg, tm)
	await _precompute_map(tm, loading)

	if not _headless:
		loading.set_step("Building terrain…")
	await _yield_frame()
	tm.build_initial()
	body.freeze = was_frozen

	await _build_horizon(cfg, tm, loading)
	_build_water(cfg, tm)

	# Foliage streams in per chunk from _process; prime the driver and fill the chunks the car
	# can already see before the loading cover drops.
	if _foliage_enabled(cfg):
		_scatter = OverworldScatter.new()
		_foliage_radius = clampi(tm.load_radius, 1, 4)
		if not _headless:
			loading.set_step("Scattering trees…")
			await _yield_frame()
			_stream_foliage(cfg, 64)

	# Diagnostic frame-profiler overlay (P), as world.gd builds it.
	var perf := PerfOverlay.new(tm)
	perf.measure_viewport = get_node_or_null("PostProcess/View") as Viewport
	perf.engine_audio = ($Car as Node).get_node_or_null("EngineAudio")
	add_child(perf)

	# The per-car surface/exhaust effects the stage builds in
	# world.gd::_build_persistent_managers. Each one self-gates on its own GameConfig flag, so
	# they are created unconditionally here exactly as the stage creates them.
	_build_effects(cfg, tm)

	_fog_veil = get_node_or_null("FogVeil/Tint") as ColorRect
	_push_fog_uniforms()

	# The zone/dwell/marker layer (sibling module). Built last so it can query finished
	# terrain for its marker heights.
	_build_zones(tm)
	_build_blocks(tm)
	_build_fog_wall(tm)
	_build_garage()
	_build_map()
	# LAST of the overlays, and that is load-bearing: `_unhandled_input` is delivered up the tree
	# from the LAST child first, so the panel's own MenuNav sees Esc before the authored PauseMenu
	# does (Esc is bound to BOTH `pause` and `menu_back`) and before the map. Backing out of the
	# panel must close the panel, not open the pause menu over it.
	_build_rally_detail()
	_build_picker()

	# Arm the pause menu now the world exists — it is default-inert so Esc cannot open it
	# during the awaited generation above, where pausing would freeze the tree mid-build.
	var pause := get_node_or_null("PauseMenu") as PauseMenu
	if pause != null:
		if not pause.reset_to_track_requested.is_connected(_on_reset_requested):
			pause.reset_to_track_requested.connect(_on_reset_requested)
		pause.set_input_enabled(true)

	# Compile the effect shaders while the cover is still up (see _warm_effect_shaders).
	if not _headless:
		loading.set_step("Warming shaders…")
	await _warm_effect_shaders()

	($Car as Node).set("controls_locked", false)
	loading.finish()

	# THE STARTER PICK, if this profile owns nothing — AFTER the boot unlock above, never before.
	# The loading path is another owner of `controls_locked`, and it releases unconditionally at the
	# end of the build; a picker that took the lock earlier would have it cleared out from under it
	# one line later and record itself as the owner of a lock nobody is holding. Opened last of all
	# for the good reason too: the world it stands in is finished, and the player's first sight of
	# the hub is their own car being chosen rather than a loaner they never asked for.
	_maybe_open_starter_pick()


# ==========================================================================================
# The chunk store and the first-launch precompute
# ==========================================================================================

# Attach the on-disk chunk store, but ONLY where it is allowed: the authored
# `overworld_cache_enabled`, not web (user:// is IndexedDB there and the cache is ~83 MB), not
# in the cheap test path, and not under headless — the test suite must never write ~83 MB into
# the user data directory, and a cache failure must never touch the save.
func _open_chunk_cache(cfg: GameConfig, tm: TerrainManager) -> void:
	if _cheap or _headless:
		return
	if not cfg.overworld_cache_active_for(Platform.is_web(), Platform.is_touch()):
		return
	var cache := OverworldCache.new()
	var key := OverworldCache.invalidation_key(cfg, tm.texture_tile_per_meter)
	# Fold in the ROAD NETWORK. The roads are carved into the cached heights and surface weights,
	# so moving a pin — or retuning a width, the curve seed or the pruning — changes the stored
	# bytes and MUST invalidate them, or the player drives yesterday's roads. Combined here rather
	# than inside invalidation_key so that helper stays a pure function of the config and does not
	# grow a dependency on the network.
	if _roads != null:
		key = hash([key, _roads.network_hash()])
	# Fold in the REGION FIELD, for exactly the reason the roads are folded in: the canonical
	# region rank is baked into every chunk's UV2.y, so adding/removing/renaming a region (which
	# re-spaces every rank) — or turning region blending off entirely — changes the stored bytes.
	# A stale record would decode against the wrong ranks and paint the boundary in the wrong
	# place. Note this forces a ONE-TIME re-warm of the existing cache on first launch after this
	# change, since no shipped record carries a baked rank.
	key = hash([key, _region_blend.stamp() if _region_blend != null else 0])
	# Fold in the FLAT PADS, for the same reason again: the pad flatten rewrites the cached
	# HEIGHTS, so moving a pin, retuning a radius or the feather, or removing the pads entirely
	# changes the stored bytes and a stale record would hand the player unflattened ground under a
	# garage that was placed on the flattened one. Forces a ONE-TIME re-warm of an existing cache
	# on the first launch after this change, since no shipped record carries a pad.
	key = hash([key, _pads.stamp() if _pads != null else 0])
	if not cache.open(key):
		push_warning("overworld: chunk cache unavailable; generating on demand this session")
		return
	_cache = cache
	tm.set_chunk_source(cache)


# All chunk coords the map covers, in a spiral-ish row order from the car outward — nearest
# first, so an interrupted first launch leaves the player's own surroundings warm.
func _map_chunk_coords() -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var c := TerrainManager.CHUNK_M
	# GROW BY THE LOAD RADIUS. The resident window is a (2*load_radius+1)² ring around the car,
	# so a car anywhere near the map edge has a window that hangs OUTSIDE the bounds. Those
	# coords are real — the terrain answers for them (a flat deep shelf below the taper's
	# waterline) — and if the precompute skips them, every one is a cache MISS that gets
	# generated on the main thread, forever, on every boundary crossing.
	#
	# This was measured, not theorised: at a 1 km map with the shipped radius the very first
	# `stream_on_miss_builds` reading was 441 — exactly the window size, i.e. the entire window
	# generated live — and it climbed by 21 (one ring row) per crossing, each costing ~140 ms.
	var margin := maxi(_floor().load_radius, 0) + 1
	var x0 := floori(_bounds.position.x / c) - margin
	var z0 := floori(_bounds.position.y / c) - margin
	var x1 := ceili(_bounds.end.x / c) - 1 + margin
	var z1 := ceili(_bounds.end.y / c) - 1 + margin
	for z in range(z0, z1 + 1):
		for x in range(x0, x1 + 1):
			out.append(Vector2i(x, z))
	var centre := _floor().chunk_coord_for(($Car as Node3D).global_position)
	out.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return (a - centre).length_squared() < (b - centre).length_squared())
	return out


# The coords worth holding RESIDENT on entry: the load ring around where the car starts, plus one.
# Kept as a Dictionary because the precompute asks it once per map coord.
func _window_coords(tm: TerrainManager) -> Dictionary:
	var out: Dictionary = {}
	var centre := tm.chunk_coord_for(($Car as Node3D).global_position)
	var ring := tm.load_radius + 1
	for dz in range(-ring, ring + 1):
		for dx in range(-ring, ring + 1):
			out[centre + Vector2i(dx, dz)] = true
	return out


# D6's mechanism: the first time the overworld is entered with a cache that does not already
# hold the map, generate EVERY chunk and write it through. At 4 km / 50 m that is 80x80 =
# 6,400 chunks, so it runs in batches per awaited frame behind the loading screen and reports
# a COUNT (this is long enough to need one).
#
# RESUMABILITY IS FREE: the store is write-through and a missing chunk is simply regenerated,
# so an interrupted first launch fills its gaps on the next run. There is no resume state to
# corrupt — we only skip coords the cache already has.
#
# Skipped entirely when there is no cache: with no store to fill, the pass would be pure cost.
func _precompute_map(tm: TerrainManager, loading: LoadingScreen) -> void:
	if _cache == null or not _cache.active():
		return
	# EVERY coord, every launch — not just the ones missing from disk.
	#
	# This used to skip coords the disk cache already held, which quietly broke the whole point on
	# the SECOND launch: `cache_chunk` is what fills the in-memory `_chunk_cache` with prebaked LOD
	# meshes, and it only runs from here. With a warm disk cache the loop had nothing to do, so
	# `_chunk_cache` started EMPTY and every chunk went back to the read-and-re-mesh route that
	# caused the boundary hitch in the first place. "The disk already has it" is not a reason to
	# skip filling memory — they are different caches answering different questions.
	#
	# `_write_chunk` is cheap on a warm coord (a seek and a read instead of noise + light
	# sampling), so a warm launch pays mesh prebaking only, which is the cost that has to be paid
	# behind a loading screen rather than mid-drive.
	# Skip coords that are ALREADY STORED and outside the entry window. There is nothing to do for
	# them: the record is on disk for when the player drives that way, and they are too far to be
	# worth prebaking into memory now.
	#
	# Without this, a warm launch still walked all ~900 coords doing one disk read each — 900 reads
	# in ~6.8 s, every single launch, to produce data it then threw away. The log said "0 generated"
	# and it was telling the truth; the cost was pure re-reading. A warm launch now touches only the
	# window (~81 chunks), and a cold one still generates everything exactly once.
	#
	# AND ONLY WHAT THE PLAYER CAN CURRENTLY REACH. See `_reach_sources` — a cold launch used to
	# generate the WHOLE map before the player could drive around the garage, which is a long wait
	# for ground that progression will not open for hours. The far chunks are now left for the
	# launch that first brings them within reach, which is a loading screen the player is already
	# watching (returning from a rally is a scene load), so the cost is split over the career.
	var window := _window_coords(tm)
	var reach := _reach_sources(tm)
	var todo: Array[Vector2i] = []
	var deferred := 0
	for coord in _map_chunk_coords():
		if window.has(coord):
			todo.append(coord)     # the entry window is prebaked into MEMORY every launch
			continue
		if not chunk_in_reach(coord, reach, _size_m):
			deferred += 1
			continue
		if not _cache.has(coord):
			todo.append(coord)
	if todo.is_empty():
		if deferred > 0:
			print("overworld precompute: nothing to do — %d chunks deferred as out of reach"
				% deferred)
		return
	var total := todo.size()
	var t0 := Time.get_ticks_msec()
	# Reads vs generates. The precompute runs EVERY launch now (it is what fills the resident
	# cache), so "400/400" on its own reads as "it regenerated everything" when a warm launch is
	# almost entirely cheap disk reads. Report the split so the two are never confused again.
	var reads0 := tm.store_reads
	var had := 0
	for coord in todo:
		if _cache.has(coord):
			had += 1
	var done := 0
	var written := 0
	# Show the SAME visualisation a stage load shows, because the same thing is happening: a road
	# network being carved and chunks being built. `LoadingScreen` already owns the widget — the
	# roads go in once as a network (one polyline per road; the stage path's single-polyline
	# `update_track_preview` would draw a line joining unrelated road ends), then each finished
	# chunk's corner is appended so the grid visibly fills in behind them.
	var drawn := PackedVector2Array()
	if not _headless:
		loading.set_chunk_size(TerrainManager.CHUNK_M)
		loading.update_road_network(_road_polylines())
	# BATCH THE INDEX. `OverworldCache.write` otherwise rewrites the whole index per chunk, which
	# is quadratic across a pass; inside a batch it is one flush per awaited frame instead. The
	# DATA record is still appended and flushed per chunk, so an interrupted pass loses at most the
	# naming of the last few records — which reads as a miss and is regenerated, exactly as before.
	if _cache.has_method("begin_batch"):
		_cache.begin_batch()
	for coord in todo:
		if _write_chunk(tm, coord):
			written += 1
		done += 1
		if not _headless:
			drawn.append(Vector2(coord) * TerrainManager.CHUNK_M)
		if done % PRECOMPUTE_BATCH == 0:
			if _cache.has_method("flush_index"):
				_cache.flush_index()
			if not _headless:
				loading.set_step("Preparing the world… %d / %d" % [done, total])
				loading.update_loaded_chunks(drawn)
			await _yield_frame()
	if _cache.has_method("end_batch"):
		_cache.end_batch()
	if not _headless:
		loading.set_step("Preparing the world… %d / %d" % [total, total])
		loading.update_loaded_chunks(drawn)
		# COST IS MEASURED AND REPORTED, never asserted (it is derived from tunables).
		var generated := total - had
		print(("overworld precompute: %d chunks in %d ms — %d read from disk, %d generated,"
			+ " %d deferred as out of reach (%.1f MB on disk). Generated > 0 on a warm launch"
			+ " means the invalidation key changed, or progression brought new ground in reach.")
			% [total, Time.get_ticks_msec() - t0, had, generated, deferred,
				_cache.size_bytes() / 1048576.0])


# WHAT THE PLAYER CAN REACH RIGHT NOW, as dilated map-space circles
# `[centre (Vector2 map pos), radius (map units)]` — the input to `_in_reach`, and the whole
# basis of the progressive precompute.
#
# The base is `RallyLibrary.lit_sources(Save.profile)`: the SAME union of reveal circles the
# pins, the zones, the fog mask, the map's road filter and the roadblocks all derive from. No
# lookalike test — if the player can enter it, it is lit, and if it is lit its ground is baked.
#
# WHY IT IS DILATED, and by how much. The frontier is a SOFT push, not a wall
# (`_update_fog_boundary`): a car beyond it is nudged inward and only TELEPORTED once it is
# FOG_HARD_MARGIN_M past the last lit pose, so the car can legitimately stand that far outside
# the lit region. The terrain then streams a `load_radius` ring of chunks around wherever the car
# is, and every chunk in that ring must already exist — this project deliberately chose loud
# holes over generate-on-miss, so a missing chunk is a visible hole and a fall-through under a
# moving car, never a silent slowdown. Hence:
#
#     FOG_HARD_MARGIN_M + (load_radius + 2) * CHUNK_M
#
# i.e. everywhere the push permits, plus the whole streaming ring around such a point, plus one
# spare ring — which also absorbs testing a chunk by its CENTRE rather than its corners, and any
# single-frame overshoot before the teleport check fires.
#
# TWO SOURCES THAT ARE NOT IN `lit_sources`:
#   * HQ / the garage, which is fog-EXEMPT rather than lit (`OverworldZone.always_revealed`) and
#     ships with `map_hq_reveal_radius` at 0. Driving around your own garage must never hole,
#     and that is precisely the wait the player asked us to remove.
#   * THE SPAWN, wherever the car actually is — the return pose from a rally is persisted and
#     need not sit inside any circle.
# Both go in with a zero base radius, so they contribute the margin and nothing more.
# The live sources: the profile's lit set, plus the garage and the car's own position. STATIC
# below, so the whole rule is testable with no scene, no terrain and no car.
func _reach_sources(tm: TerrainManager) -> Array:
	var extra: Array[Vector2] = [_hq_map_pos]
	var car := get_node_or_null("Car") as Node3D
	if car != null:
		extra.append(map_pos_of(car.global_position, _size_m))
	return reach_sources(Save.profile, _size_m, tm.load_radius, extra)


## How far outside the lit region the precompute must still bake, in NORMALISED map units. See
## `_reach_sources`' header for the derivation; exposed so a test can assert the safety property
## (everywhere the fog push permits is baked) without hardcoding the bound.
static func reach_margin_map(size_m: float, load_radius: int) -> float:
	return (FOG_HARD_MARGIN_M + float(maxi(load_radius, 0) + 2) * TerrainManager.CHUNK_M) \
		/ maxf(size_m, 1.0)


## The reach circles for `profile`, as `[centre (map pos), radius (map units)]`, every one of them
## dilated by `reach_margin_map`. `extra_map` are additional centres with a ZERO base radius —
## the garage and the spawn, which are reachable without being lit.
static func reach_sources(profile: Dictionary, size_m: float, load_radius: int,
		extra_map: Array[Vector2] = []) -> Array:
	var margin := reach_margin_map(size_m, load_radius)
	var out: Array = []
	for src in RallyLibrary.lit_sources(profile):
		out.append([src[0] as Vector2, float(src[1]) + margin])
	for pos in extra_map:
		out.append([pos, margin])
	return out


## Is this chunk inside any reach circle? Tested at the chunk CENTRE (the extra ring in the
## margin covers the corners), squared, so the sweep over every map coord neither allocates nor
## takes a square root.
static func chunk_in_reach(coord: Vector2i, sources: Array, size_m: float) -> bool:
	var centre := (Vector2(coord) + Vector2(0.5, 0.5)) * TerrainManager.CHUNK_M
	var map_pos := map_pos_of(Vector3(centre.x, 0.0, centre.y), size_m)
	for src in sources:
		var pos: Vector2 = src[0]
		var r: float = src[1]
		if map_pos.distance_squared_to(pos) <= r * r:
			return true
	return false


# Generate one chunk and store it, QUANTISED AT GENERATION TIME so a cache round trip is
# exact rather than approximate: the stored grid, the collision heightfield and the bilinear
# height query all derive from the same numbers.
#
# Goes through compute_chunk_data (not chunk_data_for) on purpose — we have already proven the
# coord is a miss, so a read attempt would be wasted, and we want the snap to land BEFORE the
# write rather than inside it.
# The road network as one polyline per road, for the loading screen's preview. Empty when the
# network has not been built yet, in which case the preview just shows the chunk grid.
func _road_polylines() -> Array[PackedVector2Array]:
	var out: Array[PackedVector2Array] = []
	if _roads == null:
		return out
	for edge in _roads.edges():
		var points: PackedVector2Array = edge.get("points", PackedVector2Array())
		if points.size() >= 2:
			out.append(points)
	return out


func _write_chunk(tm: TerrainManager, coord: Vector2i) -> bool:
	# ONE call does both caches. `cache_chunk` goes through `chunk_data_for`, which reads the store
	# when it has the coord and otherwise generates and writes it back — so the disk record is
	# produced inside the terrain, not here. It then prebakes the five LOD display meshes and the
	# collision shape into the resident `_chunk_cache`, which is what makes a boundary crossing a
	# cheap node build rather than a mesh build (the stage model, and the whole point of this pass).
	#
	# It used to call `cache_chunk` AND `chunk_data_for` AND `_cache.write`, which generated every
	# chunk twice and wrote the store twice — and worse, snapped a SEPARATE copy of the heights on
	# the way to disk, leaving the resident grid off-lattice. Quantisation now happens inside
	# generation (`TerrainManager._apply_height_quantum`, after the carve and the taper), so the
	# resident grid, the collision heightfield and the stored record are the same numbers by
	# construction rather than by a convention someone has to remember.
	#
	# Only IN-BOUNDS coords go resident. The enumeration is grown by the load radius so the window
	# can never reach past what was written, but those margin coords are the flat sea shelf beyond
	# the coast — reached only at the very edge of the map — and holding them too would put ~900
	# chunks in memory instead of ~400. They are generated and stored, just not kept.
	# RESIDENT only near where the player will actually start; everything else is disk-only.
	#
	# Prebaking the WHOLE map into `_chunk_cache` was wrong for a scene that RELOADS. The overworld
	# is re-entered every time the player returns from a rally, and a fresh scene means a fresh
	# TerrainManager with an empty cache — so "prebake all 400" meant paying 400 disk reads and 400
	# LOD prebakes on every single return trip. That is the opposite of the fast recall the disk
	# cache exists for, and it is what "the chunks recompute even in the same session" was.
	#
	# So the split is: the disk record for EVERY coord (cheap, written once, reused across launches
	# and across trips), and mesh prebaking only for the window the player opens inside. The rest
	# arrives as they drive — one disk read plus a mesh build per chunk, spread by the spawn budget
	# and never regenerated.
	var resident := tm.chunk_coord_for(($Car as Node3D).global_position)
	var ring := tm.load_radius + 1
	var near := maxi(absi(coord.x - resident.x), absi(coord.y - resident.y)) <= ring
	if near and _bounds.has_point(_chunk_centre(coord)):
		tm.cache_chunk(coord)
		return true
	return not tm.chunk_data_for(coord).is_empty()


# ==========================================================================================
# Horizon and water
# ==========================================================================================

# Static coarse backdrop, so the reduced fog reveals a horizon instead of the load ring's
# edge. `distant_terrain_enabled` ships false and an open world needs a backdrop, so this is
# built from the EXPLICIT map bounds — NOT corridor_bounds(), which a bounded world answers
# from the same rect but which would silently build nothing if the bounds were ever cleared.
#
# It is ~324 tiles and ~220k synchronous height+light samples at 4 km, so it gets its own
# yielded load stage and is skipped outright in the cheap test path.
func _build_horizon(cfg: GameConfig, tm: TerrainManager, loading: LoadingScreen) -> void:
	if _cheap or not cfg.distant_terrain_enabled or _distant != null:
		return
	if not _headless:
		loading.set_step("Drawing the horizon…")
	await _yield_frame()
	_distant = DistantTerrain.new()
	_distant.name = "DistantTerrain"
	_distant.cell_m = cfg.distant_terrain_cell_m
	_distant.sink_m = cfg.distant_terrain_sink_m
	add_child(_distant)
	_distant.build_static(tm, _bounds.grow(cfg.distant_terrain_radius_m))
	await _yield_frame()


# The sea. LakeField's plane already spans 10 km, so it covers a 4 km map with room to spare,
# and it is what puts water in the coastline the terrain taper carves (D5/D9). ONE level for
# the whole plane — the taper in TerrainManager is driven from the same
# `track_water_level_m`, so a per-region waterline here would leave the shore dry or drowned.
func _build_water(cfg: GameConfig, tm: TerrainManager) -> void:
	if _cheap or not cfg.water_enabled or _lake != null:
		return
	_lake = LakeField.new()
	_lake.name = "LakeField"
	add_child(_lake)
	_lake.build(cfg.track_water_level_m, cfg)
	var wl := cfg.track_water_level_m
	# NOT wired when the water is FROZEN, matching world.gd::_build_lakes. The query exists to
	# apply water_drag, and a car sliding across ice is not wading through anything — the ice is
	# a solid surface with its own very low grip instead (LakeField._add_ice_collider,
	# Drivetrain.surface_tire_params). Leaving it wired drags the car down on a surface it is
	# meant to slide across, which is the opposite of the feature. The overworld wired it
	# unconditionally and so applied water drag on ice; the stage had the guard, the hub did not.
	if cfg.frozen_water_grip > 0.0:
		($Car as Node).call("set_water_query", Callable())
	else:
		($Car as Node).call("set_water_query",
			func(p: Vector3) -> bool: return tm.height_at(p.x, p.z) < wl)


# ==========================================================================================
# Look — region at a position
# ==========================================================================================

# Dress the world for the region at `map_pos`. Same fields world.gd::_apply_region_look sets
# (floor textures, sky panorama, tarmac colour, background/fog colour, ground tint), resolved
# POSITIONALLY through OverworldRegion instead of once per stage.
#
# The three parts transition differently, on purpose:
#   - the GROUND blends SPATIALLY, at the fixed region boundary, from the rank baked into every
#     vertex — the change arrives on the ground ahead of the car and never restyles ground behind
#     it. See _push_region_pair;
#   - the sky-side COLOURS (background + fog) AND the sky PANORAMA cross-fade over time, on one
#     shared tween so they can never disagree — see _fade_sky. The panorama fade needs the
#     overworld's own two-sampler sky shader (shaders/overworld_sky.gdshader), because a
#     PanoramaSkyMaterial holds exactly one texture and so can only snap.
func _apply_region_look(map_pos: Vector2) -> void:
	var region_id := _region.region_at(map_pos)
	var look := RegionLibrary.look_of(region_id)
	var cfg: GameConfig = Config.data
	var tm := _floor()
	var floor_mat := tm.chunk_material as ShaderMaterial
	if floor_mat != null:
		_capture_ground_baseline(floor_mat)
		# The GROUND does not fade over time and does not snap: it blends SPATIALLY, at the fixed
		# region boundary, from a per-vertex rank baked into the chunk (see "Region blending" in
		# features/overworld.md). So the ground parameters pushed here are the region PAIR the
		# shader blends between, not a global repaint — crossing a line must not restyle ground the
		# player can still see behind them.
		#
		# Pushed on EVERY check, not only on a crossing, and that is load-bearing: slot B is the
		# nearest OTHER region, which changes while the car is still deep inside slot A (that is
		# precisely the region it is driving TOWARDS). Gating this on the early return below would
		# leave the approaching region's ground stuck on whatever was uploaded last.
		_push_region_pair(floor_mat, map_pos, look, cfg)
	if region_id == _look_region:
		return
	_look_region = region_id
	if floor_mat != null:
		# Slot A's ground textures. Assigned UNCONDITIONALLY, falling back to the scene's own
		# baseline, for the same reason the sky panorama is: a conditional assign would let the
		# previous region's ground follow the car into a region that authors none of its own.
		floor_mat.set_shader_parameter("albedo_texture",
			_look_texture(look, "grass_texture", _base_grass_texture))
		floor_mat.set_shader_parameter("road_texture",
			_look_texture(look, "gravel_texture", _base_gravel_texture))
	var env: Environment = ($WorldEnvironment as WorldEnvironment).environment
	var sky_mat := env.sky.sky_material as ShaderMaterial
	if sky_mat != null:
		_capture_sky_baseline(sky_mat)
	# The haze the sky sits in fades WITH the sky panorama, over time and on ONE tween — not with
	# the ground, which blends spatially. See _fade_sky.
	_fade_sky(env, sky_mat, _sky_texture_for(look, cfg),
		look.get("background_color", cfg.background_color))
	# The wheel-spray grass look is per REGION, and in an open world the region changes as the
	# player drives — so unlike the stage (one region, set once at build) the overrides are
	# re-issued on every crossing. The pool is null before _build_effects runs, which is why the
	# build also pushes them once for the spawn region.
	_push_grass_overrides(look)


## The panorama a region look resolves to: its own `sky_panorama`, else the configured
## `default_sky_panorama`, else the texture the SCENE ships with.
##
## Resolved UNCONDITIONALLY, never `if look.has(...)`: the sky material outlives any one region,
## so a conditional assign lets one region's sky follow the player everywhere (the bug
## features/regions.md documents). "Authors nothing" must mean "back to the default", not
## "keep the last region's".
func _sky_texture_for(look: Dictionary, cfg: GameConfig) -> Texture2D:
	var path := sky_panorama_path(look, cfg.default_sky_panorama)
	if path == "":
		return _base_sky_texture
	var tex := load(path) as Texture2D
	return tex if tex != null else _base_sky_texture


## The panorama PATH half of _sky_texture_for, split out static and pure so the
## "authors none -> the configured default" rule is testable without a scene or a renderer.
## An empty string means "neither the region nor the config names one" — the caller falls back
## to the scene's shipped texture.
static func sky_panorama_path(look: Dictionary, default_path: String) -> String:
	var path := String(look.get("sky_panorama", default_path))
	return path if path != "" else default_path


## Which sampler slot is the one actually on screen at `blend`. After a completed fade the weight
## is exactly 0.0 or 1.0, so this names the slot holding the region the player is now in.
static func sky_live_slot(blend: float) -> String:
	return "b" if blend > 0.5 else "a"


# Remember the panorama the SCENE ships with, once, before any region overwrites it — same role
# and same reason as _capture_ground_baseline.
func _capture_sky_baseline(sky_mat: ShaderMaterial) -> void:
	if _sky_baseline_captured:
		return
	_sky_baseline_captured = true
	_base_sky_texture = sky_mat.get_shader_parameter("panorama_a") as Texture2D


## Which sampler slot the INCOMING panorama goes into, and the weight sweep that reveals it.
##
## THE MID-FADE CROSSING. Two samplers cannot hold three skies, so a crossing that arrives while
## a fade is in flight cannot be perfectly continuous: one of the two live textures has to be
## replaced under the player. The rule here is "overwrite the slot that is currently LEAST
## visible, and sweep towards it" — with `blend` at or below 0.5 slot A dominates, so B takes the
## incoming sky and the weight runs (blend -> 1); above 0.5 the roles mirror and the weight runs
## (blend -> 0). The alternative — collapsing B into A and restarting from 0 — throws away the
## whole in-flight blend and pops by up to a full unit of weight; this caps the visible step at
## half a unit and, crucially, the weight moves CONTINUOUSLY from where it already is rather than
## being reset. It also makes the post-fade "collapse" free: the destination slot simply IS the
## current region once the weight lands on 1.0 or 0.0, with no texture copy to get wrong.
##
## Static and pure so the rule can be tested with no scene, no renderer and no tween. Returns
## `{"target_b": bool, "from": float, "to": float}` — the slot the incoming panorama goes into,
## and the weight sweep that reveals it.
static func sky_fade_plan(blend: float) -> Dictionary:
	var b_is_target := blend <= 0.5
	return {
		"target_b": b_is_target,
		"from": clampf(blend, 0.0, 1.0),
		"to": 1.0 if b_is_target else 0.0,
	}


# Cross-fade the SKY — background/fog colour AND the panorama — over `overworld_region_fade_s`,
# on a SINGLE tween so the haze and the sky always agree. Sky only, deliberately: the sky is one
# environment and cannot be spatial, so a temporal fade is the honest treatment, and it matches
# how a distant haze actually changes as you travel. The GROUND is handled the opposite way,
# spatially at the boundary, by _push_region_pair.
func _fade_sky(env: Environment, sky_mat: ShaderMaterial, sky_tex: Texture2D, bg: Color) -> void:
	var from_bg := env.background_color
	var secs: float = maxf(Config.data.overworld_region_fade_s, 0.0)
	if _look_tween != null and _look_tween.is_valid():
		_look_tween.kill()
	if secs <= 0.0 or _headless:
		env.background_color = bg
		env.fog_light_color = bg
		# No fade to run: park BOTH slots on the incoming sky and the weight at 0, which is the
		# same state a completed fade leaves behind — the next crossing starts clean either way.
		_sky_blend = 0.0
		if sky_mat != null:
			sky_mat.set_shader_parameter("panorama_a", sky_tex)
			sky_mat.set_shader_parameter("panorama_b", sky_tex)
			sky_mat.set_shader_parameter("sky_blend", 0.0)
		return
	var plan := sky_fade_plan(_sky_blend)
	var target_b: bool = plan["target_b"]
	var from_w: float = plan["from"]
	var to_w: float = plan["to"]
	if sky_mat != null:
		sky_mat.set_shader_parameter("panorama_b" if target_b else "panorama_a", sky_tex)
		sky_mat.set_shader_parameter("sky_blend", from_w)
	_sky_blend = from_w
	# From whatever is on screen NOW, so a crossing mid-fade continues smoothly rather than
	# snapping back to the region it was leaving.
	_look_tween = create_tween()
	_look_tween.tween_method(
		func(t: float) -> void:
			var c := from_bg.lerp(bg, t)
			env.background_color = c
			env.fog_light_color = c
			_sky_blend = lerpf(from_w, to_w, t)
			if sky_mat != null:
				sky_mat.set_shader_parameter("sky_blend", _sky_blend),
		0.0, 1.0, secs)
	# The collapse: once the weight has landed on 1.0 or 0.0, the destination slot alone is on
	# screen, so recording it as the live slot is the whole of it. No texture copy, nothing to
	# leak, and the next crossing reads a clean 0-or-1 weight.
	_look_tween.finished.connect(func() -> void:
		_sky_blend = to_w
		if sky_mat != null:
			sky_mat.set_shader_parameter("sky_blend", to_w))


# The GROUND's region parameters: the PAIR of regions the ground shader cross-fades between, and
# the two ranks that let it decode the rank baked into every vertex (UV2.y) into a 0..1 A->B
# factor. See features/overworld.md -> "Region blending" and
# TerrainManager._apply_region_blend for why the bake is a rank rather than a weight.
#
# Slot A is the region the car is IN; slot B is the strongest OTHER region at the car's position —
# i.e. the one it is approaching, because region_weights_at's falloff only lets a neighbour weigh
# anything once the car is near its frontier.
#
# THE THREE-REGION PROBLEM, and why COLOUR no longer goes through the pair. A visible chunk can
# belong to ANY region — the horizon is kilometres away and regions meet three-at-a-point — but the
# ranks are assigned by sorted id, so they bear no relation to geography. Decoding colour against
# the pair therefore clamped every third region onto whichever of the two happened to be nearer in
# RANK, and the mis-assignment changed as the pair followed the car: distant ground painted as a
# region it was not, and changed colour as you drove. So the ground TINT and the TARMAC colour now
# come from the all-regions LUT (_push_region_lut), which is correct for every region at once.
#
# The PAIR still owns the ground TEXTURE cross-fade, because a sampler cannot go in a uniform
# array; a chunk of a third region wears a near region's grass under its OWN tint, which is the
# accepted limitation (tint carries almost all of the read at distance, and the two paths agree
# exactly at each region's own rank). The pair is chosen by weight ORDER, ties broken by region id,
# so it is deterministic and cannot oscillate between two equal candidates frame to frame.
func _push_region_pair(floor_mat: ShaderMaterial, map_pos: Vector2, look: Dictionary,
		cfg: GameConfig) -> void:
	# Slot A, re-seeded from the authored baseline every time, exactly as world.gd does, so a
	# region's tint can never compound across crossings. It is also the colour the shader uses
	# whenever the LUT is not active (a roster with a single region, or blending off).
	floor_mat.set_shader_parameter("tarmac_color", look.get("tarmac_color", cfg.tarmac_color))
	floor_mat.set_shader_parameter("albedo_color", look.get("terrain_tint", cfg.terrain_tint))
	floor_mat.set_shader_parameter("region_blend_width", cfg.overworld_region_blend_width)
	if _region_blend == null:
		floor_mat.set_shader_parameter("blend_region", false)
		return
	_push_region_lut(floor_mat, cfg)
	var pair := region_pair_of(_region.region_weights_at(map_pos))
	var id_b := String(pair.get("b", ""))
	var rank_a := _region_blend.rank_of(String(pair.get("a", "")))
	var rank_b := _region_blend.rank_of(id_b)
	# No second region (deep inside one region), or two regions the ranking cannot separate: there
	# is nothing to blend the TEXTURE to, so slot A's texture paints everything. Parking rank B on
	# rank A (rather than switching the whole feature off) leaves the decoded texture factor at 0
	# while keeping `blend_region` true, which is what keeps the all-regions LUT — and therefore
	# distant ground's colours — live even while the car sits deep inside one region.
	if id_b == "" or absf(rank_b - rank_a) <= REGION_RANK_EPSILON:
		floor_mat.set_shader_parameter("region_rank_a", rank_a)
		floor_mat.set_shader_parameter("region_rank_b", rank_a)
		floor_mat.set_shader_parameter("blend_region", true)
		return
	var look_b := RegionLibrary.look_of(id_b)
	floor_mat.set_shader_parameter("albedo_texture_b",
		_look_texture(look_b, "grass_texture", _base_grass_texture))
	floor_mat.set_shader_parameter("tarmac_color_b", look_b.get("tarmac_color", cfg.tarmac_color))
	floor_mat.set_shader_parameter("albedo_color_b", look_b.get("terrain_tint", cfg.terrain_tint))
	floor_mat.set_shader_parameter("region_rank_a", rank_a)
	floor_mat.set_shader_parameter("region_rank_b", rank_b)
	floor_mat.set_shader_parameter("blend_region", true)


# Upload the rank->look LUT once. It depends only on the roster's region set and each region's
# authored look, neither of which changes while the overworld is loaded, so re-uploading it per
# region check would be pure waste. The shader arrays are fixed-length, so the tail is padded with
# the last real entry — ranks above the last one clamp to it anyway, so the padding is inert.
func _push_region_lut(floor_mat: ShaderMaterial, cfg: GameConfig) -> void:
	if _region_lut_pushed:
		return
	_region_lut_pushed = true
	var lut := region_look_lut(_region_blend, cfg)
	var count := int(lut.get("count", 0))
	floor_mat.set_shader_parameter("region_count", count)
	if count <= 0:
		return
	var ranks: PackedFloat32Array = lut["ranks"]
	var tints: PackedColorArray = lut["tints"]
	var tarmacs: PackedColorArray = lut["tarmacs"]
	while ranks.size() < REGION_LUT_MAX:
		ranks.append(ranks[ranks.size() - 1])
		tints.append(tints[tints.size() - 1])
		tarmacs.append(tarmacs[tarmacs.size() - 1])
	floor_mat.set_shader_parameter("region_rank", ranks)
	floor_mat.set_shader_parameter("region_tint", tints)
	floor_mat.set_shader_parameter("region_tarmac", tarmacs)


## The ground shaders' rank->look LUT: every ranked region's tint and tarmac colour, in ASCENDING
## rank order (which the shader's bracket search relies on), as
## `{"count", "ranks", "tints", "tarmacs"}`. A region that authors neither key falls back to the
## config baseline, exactly as slot A does. Static and pure so it can be tested without a scene.
static func region_look_lut(blend: RegionBlendSource, cfg: GameConfig) -> Dictionary:
	var ranks := PackedFloat32Array()
	var tints := PackedColorArray()
	var tarmacs := PackedColorArray()
	if blend != null and cfg != null:
		var ids := blend.ids()
		if ids.size() > REGION_LUT_MAX:
			push_warning("Overworld: %d regions but the ground LUT holds %d — the tail will paint "
				% [ids.size(), REGION_LUT_MAX]
				+ "as the last entry. Grow region_tint[]/region_tarmac[]/region_rank[] in "
				+ "ps1_models.gdshader and ps1_terrain_snow.gdshader, and REGION_LUT_MAX here.")
		for region_id in ids:
			if ranks.size() >= REGION_LUT_MAX:
				break
			var look := RegionLibrary.look_of(String(region_id))
			var tint: Color = look.get("terrain_tint", cfg.terrain_tint)
			var tarmac: Color = look.get("tarmac_color", cfg.tarmac_color)
			ranks.append(blend.rank_of(String(region_id)))
			tints.append(tint)
			tarmacs.append(tarmac)
	return {"count": ranks.size(), "ranks": ranks, "tints": tints, "tarmacs": tarmacs}


## The two strongest regions in a `region_weights_at` result, as
## `{"a", "weight_a", "b", "weight_b"}` — `b` is "" when only one region contributes. Static and
## pure so it can be tested without a scene. Candidates are visited in sorted id order, so equal
## weights resolve to the same pair every call rather than following dictionary insertion order.
static func region_pair_of(weights: Dictionary) -> Dictionary:
	var ids: Array[String] = []
	for key in weights:
		ids.append(String(key))
	ids.sort()
	var id_a := ""
	var id_b := ""
	var w_a := -1.0
	var w_b := -1.0
	for region_id in ids:
		var w := float(weights[region_id])
		if w > w_a:
			id_b = id_a
			w_b = w_a
			id_a = region_id
			w_a = w
		elif w > w_b:
			id_b = region_id
			w_b = w
	return {
		"a": id_a, "weight_a": maxf(w_a, 0.0),
		"b": id_b, "weight_b": maxf(w_b, 0.0) if id_b != "" else 0.0,
	}


# Remember the ground textures the SCENE ships with, once, before any region overwrites them.
# They are the fallback for a region that authors none — without them "no override" would mean
# "keep the previous region's texture", which is the bug the sky panorama already documents.
func _capture_ground_baseline(floor_mat: ShaderMaterial) -> void:
	if _ground_baseline_captured:
		return
	_ground_baseline_captured = true
	_base_grass_texture = floor_mat.get_shader_parameter("albedo_texture") as Texture2D
	_base_gravel_texture = floor_mat.get_shader_parameter("road_texture") as Texture2D


# One look key resolved to a texture, or `fallback` where the region authors none.
func _look_texture(look: Dictionary, key: String, fallback: Texture2D) -> Texture2D:
	var path := String(look.get(key, ""))
	if path == "":
		return fallback
	return load(path) as Texture2D


# Deep snow draws the ground ABOVE the collision surface off-road. Called unconditionally,
# and that is load-bearing: without the else-branch a snow stage would leave every later
# world's ground floating in mid-air (the shader lives on a shared sub-resource).
func _apply_deep_snow_ground(cfg: GameConfig) -> void:
	var floor_mat := _floor().chunk_material as ShaderMaterial
	if floor_mat == null:
		return
	if cfg.deep_snow_depth_m > 0.0:
		if floor_mat.shader != TERRAIN_SNOW_SHADER:
			floor_mat.shader = TERRAIN_SNOW_SHADER
		floor_mat.set_shader_parameter("snow_depth", cfg.deep_snow_depth_m)
	elif floor_mat.shader != TERRAIN_BASE_SHADER:
		floor_mat.shader = TERRAIN_BASE_SHADER


# ==========================================================================================
# Foliage — streamed per chunk
# ==========================================================================================

func _foliage_enabled(cfg: GameConfig) -> bool:
	return not _cheap and cfg.vegetation_enabled


# Fill up to `budget` un-scattered chunks inside the foliage ring, and free the props of any
# chunk that has fallen outside it. Called from _process with the per-frame budget, and once
# with a bigger budget behind the loading cover so the opening view is not bare.
func _stream_foliage(cfg: GameConfig, budget: int) -> void:
	if _scatter == null:
		return
	var tm := _floor()
	var centre := tm.chunk_coord_for(($Car as Node3D).global_position)
	# Evict first, so a long drive cannot grow the prop count without bound.
	var drop: Array = []
	for key in _foliage:
		var coord: Vector2i = key
		if absi(coord.x - centre.x) > _foliage_radius + 1 \
				or absi(coord.y - centre.y) > _foliage_radius + 1:
			drop.append(coord)
	for dropped in drop:
		for node in _foliage[dropped] as Array:
			var n := node as Node
			if is_instance_valid(n):
				n.queue_free()
		_foliage.erase(dropped)
	var spawned := 0
	for dz in range(-_foliage_radius, _foliage_radius + 1):
		for dx in range(-_foliage_radius, _foliage_radius + 1):
			if spawned >= budget:
				return
			var coord := centre + Vector2i(dx, dz)
			if _foliage.has(coord) or not _bounds.has_point(_chunk_centre(coord)):
				continue
			_scatter_chunk(cfg, tm, coord)
			spawned += 1


# A scatter-params copy thinned by `overworld_foliage_density`.
#
# Scales `points_per_turn`, which is what `TreeScatter.grid_cell_size` derives the lattice from
# (`radius * sqrt(PI / per_turn)`), so a density of 0.35 widens the cell by 1/sqrt(0.35) ≈ 1.7x —
# from ~6.3 m to ~10.6 m at the shipped values. Scaling the COUNT rather than the cell keeps the
# relationship the stage scatter already documents, so the two cannot drift apart.
#
# `tree_params()` / `rock_params()` build a fresh Dictionary per call, so mutating the copy is safe.
func _thinned(params: Dictionary, cfg: GameConfig) -> Dictionary:
	var density: float = clampf(cfg.overworld_foliage_density, 0.0, 1.0)
	if density >= 1.0:
		return params
	params["points_per_turn"] = float(params.get("points_per_turn", 0.0)) * density
	return params


func _chunk_centre(coord: Vector2i) -> Vector2:
	return (Vector2(coord) + Vector2(0.5, 0.5)) * TerrainManager.CHUNK_M


# One chunk's trees, bushes and rocks, dressed by the region under that chunk. Every pass gets
# the SUBMERGED-CULLING predicate, so nothing grows in the sea the coastline taper creates.
func _scatter_chunk(cfg: GameConfig, tm: TerrainManager, coord: Vector2i) -> void:
	var owned: Array = []
	_foliage[coord] = owned
	var look := _region.look_at(map_pos_of(
		Vector3(_chunk_centre(coord).x, 0.0, _chunk_centre(coord).y), _size_m))
	var wl := cfg.track_water_level_m
	# The ONE gate every pass shares: nothing grows in the sea the coastline taper creates, and
	# nothing grows on a road. The road clearance is not cosmetic — a tree in the carriageway is a
	# collider in the driving line, and `Foliage.spawn_trees` gives billboards real collision.
	# A margin past `influence_m()` keeps trunks off the shoulder rather than flush against it.
	var roads := _roads
	var clear_m := 0.0
	if roads != null:
		clear_m = roads.influence_m() + ROAD_FOLIAGE_MARGIN_M
	# ...and nothing grows on a FLAT PAD. A tree in the middle of a flattened zone circle — or
	# through the garage — defeats the point of levelling the ground in the first place. The test
	# is the pad's own influence (weight > 0), so the feather band is kept clear too rather than
	# leaving a ring of trunks around the lip.
	var pads := _pads
	var dry := func(p: Vector2) -> bool:
		if tm.height_at(p.x, p.y) <= wl:
			return false
		if roads != null and roads.distance_to_road_m(p.x, p.y) <= clear_m:
			return false
		if pads != null and pads.pad_at(p.x, p.y).x > 0.0:
			return false
		return true

	var tree_params := _thinned(cfg.tree_params(), cfg)
	var trees := _scatter.trees_in_chunk(coord, TerrainManager.CHUNK_M, tree_params,
		cfg.track_seed, cfg.track_forestiness, cfg.forest_wavelength_m, dry)
	if not trees.is_empty():
		var mix := RegionLibrary.tree_mix(look)
		var weights: Array = []
		for entry in mix:
			weights.append(entry.get("weight", 1.0))
		var groups := OverworldScatter.species_groups(trees, weights, cfg.track_seed)
		for i in range(mix.size()):
			var group: PackedVector2Array = groups[i]
			if group.is_empty():
				continue
			var entry: Dictionary = mix[i]
			owned.append(Foliage.spawn_trees(self, group, tm, true,
				cfg.tree_render_distance_m, cfg.tree_render_fade_m,
				load(entry["texture"]), String(entry.get("profile", "home")) == "region",
				entry.get("size_scale", Vector2.ONE)))

	if RegionLibrary.spawns_bush_mesh(look):
		# Bushes are NOT forestiness-gated (they cover everything a stage), so without thinning
		# they are the densest layer out here — the one that fills every clearing back in.
		var bushes := _scatter.bushes_in_chunk(coord, TerrainManager.CHUNK_M,
			tree_params, cfg.track_seed, dry)
		if not bushes.is_empty():
			owned.append(Foliage.spawn_bushes(self, bushes, tm,
				cfg.tree_render_distance_m, cfg.tree_render_fade_m))

	var density := RegionLibrary.rock_density(look)
	if cfg.rocks_enabled and density > 0.0 and cfg.rock_groups_per_turn > 0.0:
		var rocks := _scatter.rocks_in_chunk(coord, TerrainManager.CHUNK_M,
			_thinned(cfg.rock_params(density), cfg), cfg.track_seed, cfg.rock_group_min,
			cfg.rock_group_max, cfg.rock_group_radius_m, dry)
		if not rocks.is_empty():
			# ONE species per chunk, picked deterministically from the coord, rather than one
			# field per species: the stage world affords three fields because it builds them
			# once, whereas out here every chunk in the ring would pay for three. Variety comes
			# from neighbouring chunks drawing different species.
			var species := absi(coord.x * 73856093 ^ coord.y * 19349663) % Foliage.ROCK_SCENES.size()
			owned.append(Foliage.spawn_rocks(self, rocks, tm, species, true,
				cfg.tree_render_distance_m, cfg.tree_render_fade_m))


# ==========================================================================================
# The fog frontier (slice 3)
# ==========================================================================================

# Feed the 64x64 R8 reveal mask to the terrain shader as a global uniform, so unrevealed
# ground renders unlit. The mask itself is the shared builder (`MapFog.build`), which
# rasterises RallyLibrary.lit_sources — the SAME derivation that gates entry — so what looks
# lit and what is enterable can never disagree.
#
# The shader half is LANDED: `shaders/overworld_fog.gdshaderinc` declares these globals and is
# included by both ground shaders (`ps1_models`, `ps1_terrain_snow`), with the names registered
# in project.godot's [shader_globals]. The `declared` guard below stays anyway — it costs one
# list lookup at load and it keeps this file from erroring on a build whose shader globals have
# been stripped or renamed, which is exactly the shape of breakage a missing uniform causes.
#
# Kept in step with the include: the mask is sampled at `world_xz / ow_fog_size_m + 0.5`, the
# inverse of world_xz(). If one side changes the fog slides off the pins it is drawn around.
func _push_fog_uniforms() -> void:
	if _headless:
		return
	var declared := RenderingServer.global_shader_parameter_get_list()
	if not declared.has(StringName(FOG_GLOBAL_MASK)):
		return
	RenderingServer.global_shader_parameter_set(FOG_GLOBAL_MASK,
		MapFog.build(Save.profile))
	if declared.has(StringName(FOG_GLOBAL_SIZE)):
		RenderingServer.global_shader_parameter_set(FOG_GLOBAL_SIZE, _size_m)
	if declared.has(StringName(FOG_GLOBAL_UNLIT)):
		RenderingServer.global_shader_parameter_set(FOG_GLOBAL_UNLIT,
			Config.data.map_fog_unlit_brightness)
	# Arm it LAST, so no frame can sample a mask/size pair that is only half-written.
	if declared.has(StringName(FOG_GLOBAL_AMOUNT)):
		RenderingServer.global_shader_parameter_set(FOG_GLOBAL_AMOUNT, 1.0)


# Is `map_pos` inside the revealed frontier? The EXACT predicate that gates rally entry.
func position_revealed(map_pos: Vector2) -> bool:
	return RallyLibrary.position_revealed(map_pos, Save.profile)


# Soft turn-back (D4): while the car is beyond the frontier, darken the screen and push it
# back toward the last lit pose — not a collider, because the lit region is a union of circles
# and a scalloped invisible wall reads as a bug. Only a car that has driven a long way out
# (FOG_HARD_MARGIN_M) is teleported, and then only back to ground it has actually stood on.
func _update_fog_boundary(delta: float) -> void:
	var car := $Car as RigidBody3D
	var lit := position_revealed(car_map_pos())
	if lit:
		_veil_alpha = maxf(0.0, _veil_alpha - FOG_VEIL_FADE * delta)
		_last_lit_pose = car.global_transform
		_has_lit_pose = true
	else:
		_veil_alpha = minf(FOG_VEIL_ALPHA, _veil_alpha + FOG_VEIL_FADE * delta)
		if _has_lit_pose:
			var back := _last_lit_pose.origin - car.global_position
			var dist := Vector2(back.x, back.z).length()
			if dist > FOG_HARD_MARGIN_M:
				car.call("reset_to", _last_lit_pose)
				_veil_alpha = FOG_VEIL_ALPHA
			elif dist > 0.5:
				var dir := Vector3(back.x, 0.0, back.z).normalized()
				car.apply_central_force(dir * car.mass * FOG_PUSH_ACCEL)
	if _fog_veil != null:
		var col := _fog_veil.color
		col.a = _veil_alpha
		_fog_veil.color = col


# ==========================================================================================
# Zones — the sibling integration point
# ==========================================================================================

# Signal names the zone layer may use for "the player activated this zone". Checked against
# the object's real signal list so a mismatch is a loud TODO rather than a silent no-op.
const ZONE_SIGNALS := ["zone_activated", "rally_activated", "activated"]

# Build the zone/dwell/marker/ghost-car layer. DUCK-TYPED AND OPTIONAL on purpose: that layer
# is a separate module, and this file must not grow a parallel implementation of it.
func _build_zones(tm: TerrainManager) -> void:
	if _cheap:
		return
	if not ResourceLoader.exists(ZONES_SCRIPT):
		# TODO: expected `res://scripts/overworld_zones.gd` — the zone manager, constructed as
		# `setup(host, terrain, car)`, updated once a frame, emitting one of ZONE_SIGNALS with
		# the activated rally id. Until it lands the overworld is drivable but has no
		# destinations.
		push_warning("overworld: %s is missing; no zones this session" % ZONES_SCRIPT)
		return
	var zone_script: GDScript = load(ZONES_SCRIPT)
	if zone_script == null:
		push_warning("overworld: %s failed to load" % ZONES_SCRIPT)
		return
	var zones: Object = zone_script.new()
	if not zones.has_method("setup"):
		push_warning("overworld: %s has no setup(opts)" % ZONES_SCRIPT)
		return
	# Parent BEFORE setup: the manager builds its zone/marker nodes inside setup, and a
	# Node3D that is not yet in the tree has no global transform for them to sit on.
	if zones is Node:
		add_child(zones as Node)
	# `setup` takes ONE options dictionary, not (host, terrain, car). The coordinate mapping
	# and the ground query are passed as Callables so this file stays the single source of
	# truth for both — the zone layer deliberately never re-derives either.
	zones.call("setup", {
		"to_world": Callable(self, "_zone_world_pos"),
		# Bound so the ground query uses the terrain this build already resolved rather than
		# re-walking the tree per zone. Bound args arrive AFTER the hook's own.
		"ground_at": Callable(self, "_zone_ground_on").bind(tm),
		"car": get_node_or_null("Car"),
		"car_scene": load(CAR_SCENE_PATH) as PackedScene,
		"visuals": not _cheap,
	})
	_zones = zones
	_connect_zone_signal(zones)


# The ROADBLOCKS: concrete barriers across the roads whose far end is still dark, so the world
# agrees with the map about where the player may go (OverworldBlocks; features/overworld.md).
# Built AFTER the terrain so the runs can be dropped onto finished ground, and given the same
# `ground_at` hook the zone layer uses so neither re-derives the height query.
#
# Not built in cheap mode: it needs the road network, and the cheap world is a bare tile.
func _build_blocks(tm: TerrainManager) -> void:
	if _cheap or _roads == null or not _roads.is_built():
		return
	_blocks = OverworldBlocks.new()
	_blocks.name = "Roadblocks"
	add_child(_blocks)
	_blocks.setup({
		"roads": _roads,
		"ground_at": Callable(self, "_zone_ground_on").bind(tm),
		"params": Config.data.barrier_render_params(),
		"visuals": not _cheap,
	})


# The FRONTIER WALL: a translucent curtain on the edge of the revealed region, so the player can see
# the boundary coming instead of learning about it from the veil and the shove
# (features/overworld.md → "The frontier wall"). Given the same `ground_at` hook the zones and the
# roadblocks use, so nothing re-derives the height query.
#
# NOT a collider and NOT a second push — see `_update_fog_boundary`, which stays the only thing that
# moves the car.
func _build_fog_wall(tm: TerrainManager) -> void:
	_fog_wall = OverworldFogWall.new()
	_fog_wall.name = "FrontierWall"
	add_child(_fog_wall)
	_fog_wall.setup({
		"size_m": size_m(),
		"ground_at": Callable(self, "_zone_ground_on").bind(tm),
		"visuals": not _cheap,
	})


## The frontier wall layer, or null before the build. Read-only seam for tests.
func fog_wall() -> OverworldFogWall:
	return _fog_wall


# Consume the hub one-shots that hq.gd's `_build_hq` would normally clear.
#
# This matters because `Scenes.hub_path()` now sends every post-rally transition HERE when the
# flag is on, and `hq._build_hq` is the ONLY code that clears these. Left set, they leak into
# the next genuine hq.tscn entry — which is the garage zone — and misroute it: winning a prize
# car sets `pending_car_reveal_instance_id`, so the player would drive into their garage and be
# shown the present box instead. `return_to_map` (the opening rally's arrival parade) would
# likewise open the map table the overworld exists to replace.
#
# Neither beat has an overworld equivalent yet, so this DROPS them rather than pretending to
# honour them, and says so once in the log. Reinstating them as overworld moments — a reveal
# flourish on the newly-lit zones, and the present box on arrival — is tracked in
# features/overworld.md under "Not done yet".
func _drain_hub_one_shots() -> void:
	if RallySession.return_to_map:
		RallySession.return_to_map = false
		print("overworld: dropped a pending map reveal parade — no overworld equivalent yet")
	if RallySession.pending_car_reveal_instance_id >= 0:
		RallySession.pending_car_reveal_instance_id = -1
		print("overworld: dropped a pending car reveal — no overworld present box yet")


# The wayfinding strip. Without it the map is unnavigable — this is the direct answer to
# "spawned in the middle of the forest and I have no idea where anything is". It is a passive
# readout (no input), showing only REVEALED destinations plus the garage, so it cannot leak the
# shape of a roster the player has not explored.
# The MINIMAP (always-on, top-left) and the FULL MAP (M / gamepad Back). The compass answers
# "which way to X"; the map answers "where do the roads go" — the layout question a bearing
# cannot. Schematic, drawn from the road network, the revealed pins and the shared fog mask; see
# overworld_map.gd's header for why the photographic map texture must NOT be used out here.
func _build_map() -> void:
	if _cheap:
		return
	var map := OverworldMap.new()
	map.name = "Map"
	add_child(map)
	var garage_pos := Vector3.ZERO
	if _garage != null:
		garage_pos = _garage.global_position
	map.setup({
		"size_m": size_m(),
		"to_world": Callable(self, "_zone_world_pos"),
		"zones": Callable(_zones, "zones") if _zones != null else Callable(),
		"garage_pos": garage_pos,
		"roads": _roads,
		"can_toggle": Callable(self, "_map_toggle_allowed"),
		"visuals": not _cheap,
	})
	map.map_toggled.connect(_on_map_toggled)
	_map = map


# The map's veto hook: M must not open a map over an open pause screen (and the pause menu owns
# get_tree().paused, which is why the map never touches it).
func _map_toggle_allowed() -> bool:
	# ...and not over the rally card either: both are modal screen claimers, and the card has the
	# car's control lock, which a map close would otherwise release on its behalf.
	if rally_detail_open() or picker_open():
		return false
	var pause := get_node_or_null("PauseMenu") as PauseMenu
	return pause == null or not pause.is_open()


# While the full map is up the car must not drive off unattended. We LOCK ITS CONTROLS rather
# than pausing the tree: the tree pause belongs to pause_menu.gd (two owners of that flag means
# one clears the other's pause), and pausing would also freeze this scene's chunk streaming,
# foliage streaming and cache eviction — the world builder the player is reading the map to
# drive into. Same gate the loading path and the start line use.
func _on_map_toggled(opened: bool) -> void:
	var car := get_node_or_null("Car")
	if car == null:
		return
	if opened:
		_map_locked_controls = not bool(car.get("controls_locked"))
		car.set("controls_locked", true)
	elif _map_locked_controls:
		_map_locked_controls = false
		car.set("controls_locked", false)


# The zone layer's `to_world` hook: a rally's normalised map_pos to a world position. Wraps
# the static conversion so the live `overworld_size_m` is applied and nothing downstream has
# to know about it.
func _zone_world_pos(map_pos: Vector2) -> Vector3:
	return world_xz(map_pos, size_m())


# The zone layer's `ground_at` hook: drop a world position onto the terrain. Returns the
# input's own y when there is no terrain (cheap mode), so a zone still lands somewhere finite.
func _zone_ground_on(pos: Vector3, tm: TerrainManager) -> float:
	if tm == null:
		return pos.y
	return tm.height_at(pos.x, pos.z)


func _connect_zone_signal(zones: Object) -> void:
	for entry in zones.get_signal_list():
		var sig: String = String(entry.get("name", ""))
		if not ZONE_SIGNALS.has(sig):
			continue
		var args: Array = entry.get("args", [])
		if args.size() == 1:
			zones.connect(sig, _on_zone_activated)
			return
		push_warning("overworld: zone signal '%s' takes %d args, expected 1" % [sig, args.size()])
	# TODO: expected one of ZONE_SIGNALS with a single argument (the activated rally id, or a
	# dictionary carrying "rally_id" / "kind"). Nothing matched, so activation is unwired.
	push_warning("overworld: no zone activation signal found on %s" % ZONES_SCRIPT)


# A zone activated. `payload` is either the rally id, or a dictionary naming it — both shapes
# are accepted so the zone layer can carry more later without breaking this seam.
#
# A RALLY sets the one-shot `pending_rally_pick_id` and loads hq.tscn, which boots straight
# into the car picker for that rally (D3: the car you drove here is not necessarily the car
# you want to race). The GARAGE zone sets `return_to_garage`, which hq.gd consumes as "the
# player asked for the hub" and therefore does NOT redirect back — that is the infinite-loop
# guard, and it is what makes one zone restore the whole shipped hub (D2).
func _on_zone_activated(payload: Variant) -> void:
	var rally_id := ""
	var kind := ""
	if payload is Dictionary:
		var d: Dictionary = payload
		rally_id = String(d.get("rally_id", d.get("id", "")))
		kind = String(d.get("kind", ""))
	else:
		rally_id = String(payload)
	if rally_id == "":
		return
	# A DESTINATION THAT IS NOT A RALLY keeps the old direct route. Nothing reaches here that way
	# today — the garage became a BUILDING you drive into (`_build_garage`), and the zone manager
	# only ever builds one zone per ROSTER ENTRY — but the payload shape still admits a `kind`, and
	# filling a rally card from a non-rally would show an empty panel with a dead Enter button.
	var rally := RallyLibrary.by_id(rally_id)
	if kind == "garage" or rally_id == GARAGE_ZONE_ID or rally.is_empty():
		_start_rally_pick(rally_id)
		return
	_open_rally_detail(rally_id, rally)


# ==========================================================================================
# The rally-detail panel — the confirmation step between arriving and racing
# ==========================================================================================

# Driving into a zone does NOT start a rally. It opens the SAME detail card the HQ map table
# opens (`RallyDetail`, extracted precisely so both hubs share one panel), and the player starts
# the rally from there. Arriving somewhere and being thrown into a load screen is the thing this
# fixes: the dwell is a navigation gesture, not a commitment.
#
# The panel is built ONCE, hidden, and re-filled per zone — `fill()` rewrites every widget, which
# is how the HQ drives it too.
#
# NAVIGATION: `MenuNav.attach` on the panel's page. That is what makes the card keyboard- and
# gamepad-navigable (left/right between the two footer buttons, Enter/A to press, Esc/B to back
# out) — `MenuNav._enable` flips the panel's deliberately FOCUS_NONE buttons to FOCUS_ALL for THIS
# instance only, so the HQ's own instance (which has no MenuNav and drives the card from
# hq_table.gd's input handler) is untouched. Attaching also solves the focus-death trap for free:
# the panel is built while HIDDEN, and MenuNav re-grabs focus on `visibility_changed`, so the
# cursor lands when the card is actually on screen rather than dying at build time.
#
# No DEV win button here: that callback is the HQ's cheat, and `RallyDetail.build` takes an empty
# Callable to mean "build no dev button at all".
func _build_rally_detail() -> void:
	_detail_ui = RallyDetail.new()
	_detail_ui.build(self, _close_rally_detail, _enter_rally_from_detail, Callable())
	_detail_ui.open = false
	if _detail_ui.layer != null:
		_detail_ui.layer.visible = false
	# "< Map" is the HQ's wording — this card was opened by DRIVING somewhere, and the map table it
	# refers to is a screen this player never saw.
	if _detail_ui.back_button != null:
		_detail_ui.back_button.text = "< Back"

	MenuNav.attach(_detail_ui.page, {
		"on_back": _close_rally_detail,
		"first": _detail_ui.enter_button,
		# Do NOT grab focus at build time: the page is hidden and a Control inside a hidden
		# CanvasLayer still reports is_visible_in_tree(), so an unguarded grab would yank the
		# cursor off whatever is on screen. The visibility hook grabs it when the card opens.
		"grab": false,
	})


## Is the rally card up? Public so a test (and `_map_toggle_allowed`) can ask.
func rally_detail_open() -> bool:
	return _detail_ui != null and _detail_ui.open


## The rally the open card is showing, or "".
func rally_detail_id() -> String:
	return _detail_rally_id if rally_detail_open() else ""


func _open_rally_detail(rally_id: String, rally: Dictionary) -> void:
	if _detail_ui == null:
		_start_rally_pick(rally_id)   # no panel (nothing built) — never swallow the activation
		return
	# ALREADY OPEN wins. Two zone circles can overlap, and the car is parked and stationary while
	# the card is up, so a second zone could complete its dwell underneath and silently swap the
	# card out from under the player's cursor.
	if _detail_ui.open:
		return
	_detail_rally_id = rally_id
	_detail_ui.fill(rally, Save.profile, rally_id)
	_detail_ui.layer.visible = true
	_lock_for_detail(true)


# Back / Esc / gamepad B: put the player back behind the wheel, having started nothing.
#
# The zone that opened this card is CANCELLED rather than left latched — see
# `OverworldZone.cancel_dwell`. Leaving the latch alone would re-open the card the moment the
# player nudged the car while still inside the circle; clearing the dwell outright would re-open
# it a few seconds later without the player touching anything. Cancelling disarms the zone, so it
# can only fire again once the car has driven OUT of the circle and come back — which is what
# backing out should mean, and it can never be permanent.
func _close_rally_detail() -> void:
	if _detail_ui == null or not _detail_ui.open:
		return
	_detail_ui.open = false
	if _detail_ui.layer != null:
		_detail_ui.layer.visible = false
	if _zones != null and _zones.has_method("cancel_dwell"):
		_zones.call("cancel_dwell", _detail_rally_id)
	_detail_rally_id = ""
	_lock_for_detail(false)


# "Enter Rally — choose car": exactly what activating a zone used to do on its own. Design
# decision D3 stands — the CAR is still picked in the HQ car park, because the car you happened
# to drive here is not necessarily the car you want to race. The panel is an added confirmation
# step in the hub, not a replacement for the picker.
# "Enter Rally — choose car" — and the choosing now happens HERE, in front of the car the player
# parked, rather than by loading hq.tscn's car park (features/overworld.md → "Picking a car in
# place"). Design decision D3 is intact in intent: there is still a pick, because the car you drove
# here is not necessarily the car you want to race. Only its venue moved.
#
# The card is HIDDEN rather than closed: its `open` flag stays true, so the zone's dwell latch, the
# map veto and the control lock all stay exactly as they were, and cancelling the picker puts the
# same card back up with nothing else disturbed.
func _enter_rally_from_detail() -> void:
	if not rally_detail_open():
		return
	if _picker == null:
		return
	if not _picker.open_for_rally(RallyLibrary.by_id(_detail_rally_id)):
		# Nothing owned can ever enter this rally. The card already says so in its eligibility
		# read-out, so the honest response is to leave it up rather than open an empty showroom.
		return
	if _detail_ui != null and _detail_ui.layer != null:
		_detail_ui.layer.visible = false


func _start_rally_pick(rally_id: String) -> void:
	RallySession.pending_rally_pick_id = rally_id
	# Scenes.HQ deliberately, NOT Scenes.hub_path(): the pick screen lives in the shipped HQ,
	# and hub_path() would send us straight back to the overworld we are leaving. Routed
	# through Scenes.change_to like every other transition so the run-scoped suppression
	# covers it — a test that activates a zone would otherwise park a live hq.tscn under
	# /root, which is the exact leak that seam exists to close.
	Scenes.change_to(get_tree(), Scenes.HQ)


# The car's control lock has THREE independent owners in this hub (the loading path, the full map,
# and now this panel), and the garage releases it unconditionally. So each owner tracks whether IT
# was the one that took the lock and only ever releases its own — otherwise closing the card would
# hand control back to a player who is supposed to be reading the map, or worse, mid-load.
# Deliberately the same shape as `_on_map_toggled`.
func _lock_for_detail(locked: bool) -> void:
	var car := get_node_or_null("Car")
	if car == null:
		return
	if locked:
		_detail_locked_controls = not bool(car.get("controls_locked"))
		car.set("controls_locked", true)
	elif _detail_locked_controls:
		_detail_locked_controls = false
		car.set("controls_locked", false)


# ==========================================================================================
# The diegetic car picker
# ==========================================================================================

# Built once, hidden, and shared by both flows (rally pick and starter pick) so the diegetic look
# cannot drift between them. Parented BEFORE `setup`, like the garage, because it builds nodes that
# need a global transform to sit on.
func _build_picker() -> void:
	_picker = OverworldPicker.new()
	_picker.name = "CarPicker"
	add_child(_picker)
	_picker.setup({
		"car": get_node_or_null("Car"),
		# Clear the world's zone visuals while the showroom shot is up — the player is parked ON a
		# zone by definition, so its tube, marker and ghost car are all between camera and car.
		"hide_zones": Callable(self, "_set_zone_visuals_hidden"),
		# GROUND HEIGHT, so the showroom prop stands on the terrain rather than on an assumption
		# about the real car. Deriving the contact plane from the car's own pose put every prop
		# `spawn_clearance` (2.5 m) in the air during the STARTER pick, which opens on boot before
		# the car has fallen that clearance — the reference was wrong, not the arithmetic.
		"ground_at": Callable(self, "_zone_ground_on").bind(_floor()),
		# NOT loaded in the cheap path: with visuals off no prop is ever built, and `load` here
		# would pull car.tscn (nine embedded car glbs, and their textures) into every headless test
		# that boots this hub for something else entirely.
		"car_scene": load(CAR_SCENE_PATH) as PackedScene if not _cheap else null,
		"visuals": not _cheap,
	})
	_picker.closed.connect(_on_picker_closed)
	_picker.started.connect(_on_picker_started)
	_picker.granted.connect(_on_picker_granted)


# Hide (or restore) the ZONE LAYER's visuals — the light tubes, the floating markers with their star
# rows, and the parked ghost cars. One call on the manager node, so this is a single `visible` flip on
# the parent of all of them rather than a walk over 38 zones.
#
# It does NOT fight the reveal gating: hiding the PARENT leaves every tube's own
# `_tube_root.visible` exactly as `_push_progress` set it, so un-hiding restores the revealed/dark
# distinction rather than lighting up a dark zone. And it does not touch the dwell logic — visibility
# is not state; `update_with` goes on ticking, and the zone that opened the card stays latched.
#
# Deliberately NOT hidden: the ROADBLOCKS and the FRONTIER WALL. Neither is a rally zone (the user
# asked for the zones), and neither stands where the car is parked — a roadblock sits at a frontier
# crossing on a road, the wall on the edge of the revealed region. If a zone near the frontier ever
# does put the wall behind the car, hiding it is one more line here.
func _set_zone_visuals_hidden(hidden: bool) -> void:
	if _zones != null and _zones.has_method("set_visuals_hidden"):
		_zones.call("set_visuals_hidden", hidden)


## Is the car picker up? Public so `_map_toggle_allowed` and a test can ask.
func picker_open() -> bool:
	return _picker != null and _picker.is_open()


# A fresh profile owns nothing, so the hub fields a stand-in catalogue car (`_field_car`) and the
# player picks their real one here — the pick that used to live behind hq.tscn's title screen.
#
# IMMEDIATELY ON BOOT, not on first driving somewhere: letting the player drive a loaner around the
# map would invite "whose car is this?", and every rally they drove to would refuse them. The
# picker takes the control lock itself in this flow (there is no detail card holding it), so the
# car cannot be driven out from under the showroom shot.
func _maybe_open_starter_pick() -> bool:
	if _picker == null or Save.selected_instance_id() >= 0:
		return false
	if not _picker.open_for_starter():
		return false   # an empty starter pool (a synthetic roster) — better a loaner than a trap
	_lock_for_picker(true)
	return true


# Cancelled (rally mode only — the starter flow installs no back action). Put the card back up
# exactly as it was; the zone stays latched, so nothing re-fires and `_close_rally_detail` remains
# the single place that cancels a dwell.
func _on_picker_closed() -> void:
	_lock_for_picker(false)
	if rally_detail_open() and _detail_ui != null and _detail_ui.layer != null:
		_detail_ui.layer.visible = true


# The player confirmed a car for this rally. Everything the HQ's start path does that MATTERS
# off-scene, and nothing that does not:
#
#   * re-resolve the owned car and the rally, and abort if either is gone (the HQ's own guard);
#   * `Save.set_selected_car`, so the car they raced is the one the hub fields when they return
#     and the one the garage lift shows;
#   * a LOADING COVER plus two awaited frames before `start_rally`, because that call generates a
#     track per event on the main thread and then changes scene — one frame is documented as not
#     being enough for the cover to actually paint;
#   * `RallySession.start_rally(rally, owned)`, the single start entry point, which retires
#     `pending_rally_pick_id` and settles the detune bookkeeping itself.
#
# DELIBERATELY NOT ported: the car park's over-limit / "detune to enter" prompt (dead code — its
# `_detune_needed` is only ever cleared, and `register_detune_revert` has no production caller at
# all), any upgrade auto-application or drivetrain auto-switch (an explicit non-goal there too),
# HP or repair gating (advisory only), and `pending_rally_pick_id` — setting that would make
# `hq.gd::_maybe_redirect_to_overworld` refuse to come back here.
#
# THE MOBILE CONTROL SCHEME is the one platform gate the HQ has that this replaces rather than
# reuses: it stashes the start and opens its own settings overlay. Here, a touch player who has
# never chosen a scheme gets `MobileControls.DEFAULT_SCHEME` written for them — which is exactly
# what the HQ's own flow settles on if they dismiss that page without choosing — and they can
# change it in Settings. A whole overlay flow to ask a question with a known good default is not
# worth building a second time.
func _on_picker_started(rally_id: String, instance_id: int) -> void:
	var owned := Save.get_car(instance_id)
	var rally := RallyLibrary.by_id(rally_id)
	if owned.is_empty() or rally.is_empty():
		return
	if Platform.is_touch() and Save.get_setting(MobileControls.SETTING_KEY, null) == null:
		Save.set_setting(MobileControls.SETTING_KEY, MobileControls.DEFAULT_SCHEME)
	Save.set_selected_car(instance_id)
	_begin_rally_start(rally, owned)


func _begin_rally_start(rally: Dictionary, owned: Dictionary) -> void:
	var loading := LoadingScreen.new()
	loading.set_step("Preparing rally…")
	add_child(loading)
	# TWO frames: the cover has to be laid out AND drawn before `start_rally` blocks the main
	# thread generating tracks. This mirrors `hq.gd::_begin_rally_start`, whose own comment says one
	# is not enough.
	await get_tree().process_frame
	await get_tree().process_frame
	await RallySession.start_rally(rally, owned)


# The starter pick was confirmed and the car has been GRANTED (the picker owns that, through
# `Save.grant_car`). WHAT FOLLOWS IS THE OPENING RALLY, IMMEDIATELY — the way the old HQ does it
# (`hq.gd::_confirm_starter`): a player who has just chosen their first car is dropped straight into
# the event that awards it, rather than being left parked in a hub with nothing behind them.
#
# `RallyLibrary.opening_rally_id_for(model_id)` names that rally — the event whose prize IS this car —
# and it is the same lookup `lit_sources` uses to light that corner of the map from
# `starter_model_id`, which the grant wrote.
#
# It goes through `_on_picker_started`, THE SHARED START PATH, exactly as the HQ routes its opening
# run through `_proceed_with_start` rather than a private handoff — so the opening run gets the same
# selection write, the same loading cover and the same two awaited frames as every other start. This
# is the first drive a player ever takes; it is the last place to invent a second code path.
#
# THE PICKER IS CLOSED FIRST, even though the scene is about to be torn down. It restores the zone
# visuals, the camera and the car's freeze — and if the scene change is ever blocked (it is, under
# the test runner) or fails, the alternative is a hub left with its zones hidden and its camera
# pointed at a showroom for the rest of the session.
func _on_picker_granted(instance_id: int) -> void:
	var owned := Save.get_car(instance_id)
	var opening_id := RallyLibrary.opening_rally_id_for(String(owned.get("model_id", "")))
	if _picker != null:
		_picker.close()
	if opening_id != "":
		_on_picker_started(opening_id, instance_id)
		return
	# NO OPENING RALLY — the roster awards this model nowhere, which a synthetic roster can produce
	# and a content edit could. The HQ falls back to its garage view; the hub's equivalent is simply
	# STAYING HERE, which is already a place: so the loaner the world was fielded with becomes the
	# car the player just chose, and they drive off to find a rally themselves.
	#
	# This is the only path that reshapes the live car in place (`refield_live_car`) — the normal one
	# leaves for the stage scene, which fields the chosen car itself.
	if not owned.is_empty() and _picker != null:
		_picker.refield_live_car(owned)
	($CameraManager as CameraManager).refresh_bonnet_offset()
	# The zone markers and the card's eligibility read-out both key off what the player owns, so they
	# are stale the instant a first car exists.
	if _zones != null and _zones.has_method("refresh"):
		_zones.call("refresh", Save.profile)


# The picker's own control lock, tracked exactly like the card's and the map's: take it only if it
# was free, release it only if we took it. Four owners now share this flag in the hub (the loading
# path, the map, the card, the picker) and the garage releases it unconditionally, so an owner that
# released blindly would hand a locked car back to nobody — or take control away mid-load.
func _lock_for_picker(locked: bool) -> void:
	var car := get_node_or_null("Car")
	if car == null:
		return
	if locked:
		_picker_locked_controls = not bool(car.get("controls_locked"))
		car.set("controls_locked", true)
	elif _picker_locked_controls:
		_picker_locked_controls = false
		car.set("controls_locked", false)


# ==========================================================================================
# Car fielding, spawn and the persisted return pose
# ==========================================================================================

# The profile's SELECTED car, with no session active — the shape Free Roam already uses.
#
# A STARTER-LESS PROFILE NOW GETS HERE ON PURPOSE. The starter pick moved into this hub
# (`_maybe_open_starter_pick`), so the entry gates no longer require an owned car, and the
# catalogue fallback below is what the world is fielded with for the few seconds before the player
# chooses: a fully drivable stock car with no instance id, no upgrades and no saved HP — none of
# which matters, because the picker replaces it in place the moment they confirm and damage is off
# in the hub regardless.
func _field_car(car: Node3D) -> void:
	var owned: Dictionary = Save.selected_car()
	if owned.is_empty():
		car.call("apply_car", 0)
	else:
		car.call("apply_owned", owned)
	# NO DAMAGE IN THE HUB. Driving between rallies is navigation, not competition — clipping a
	# tree on the way to an event should not cost HP the player then pays stars to repair, and a
	# long drive home should not be able to WRECK the car outright.
	#
	# Set AFTER fielding: apply_owned/apply_car rebuild the model (`damage.field(...)`), so an
	# earlier assignment would be overwritten. Gated at DamageModel.enabled rather than by
	# suppressing impacts here, so both entry points are covered and `wrecked` can never fire.
	var model = car.get("damage")
	if model != null:
		model.enabled = false


func _push_car_materials(cfg: GameConfig, car: Node3D) -> void:
	var chassis := car.get_node_or_null("Chassis") as MeshInstance3D
	var cabin := car.get_node_or_null("Cabin") as MeshInstance3D
	var tire := car.get_node_or_null("WheelFL/Visual/Tire") as MeshInstance3D
	for pair in [[chassis, cfg.chassis_color], [cabin, cfg.cabin_color], [tire, cfg.wheel_color]]:
		var mesh := pair[0] as MeshInstance3D
		if mesh == null:
			continue
		var mat := mesh.get_surface_override_material(0) as ShaderMaterial
		if mat == null:
			continue
		mat.set_shader_parameter("albedo_color", pair[1])
		cfg.apply_car_light(mat)


# Where the car starts. Two cases, and only two:
#
#   * RETURNING FROM A RALLY -> that rally's zone. You drove there, you raced, you come back
#     out where you left the car. RallySession.overworld_return_rally_id carries which one
#     (set for finish, wreck and abandon alike); it is a ONE-SHOT, cleared here, so a later
#     boot that is not a return falls through to the garage.
#   * OTHERWISE (a cold game start) -> the GARAGE. See _default_spawn_map_pos.
#
# This REPLACED a persisted free-roam pose (design doc D8, "park where you left"). That key
# is gone rather than merely unread: the rule above covers both arrival routes, so keeping a
# saved pose would have meant writing profile state on every exit that nothing consumed.
#
# An unknown or stale id (a rally removed from the roster since, or a profile from another
# build) is treated as "not a return" rather than as an error — the fallback is the garage,
# which is always a safe, lit, on-road place to be.
func _resolve_spawn_pose() -> Transform3D:
	var return_id := RallySession.overworld_return_rally_id
	RallySession.overworld_return_rally_id = ""
	var cfg: GameConfig = Config.data
	if return_id != "":
		var rally := RallyLibrary.by_id(return_id)
		if not rally.is_empty():
			_spawn_face_target = RallyLibrary.map_pos_of(rally)
			_spawn_gap_m = (cfg.overworld_zone_radius_m if cfg != null else 12.0) \
				+ RETURN_SPAWN_MARGIN_M
			return return_pose_for(_spawn_face_target, _hq_map_pos, _size_m, _spawn_gap_m)
	# THE GARAGE, on the same principle: stand outside it and look at it, rather than materialising
	# on top of it pointing at nothing. The gap is the GARAGE pad's radius (bigger than a zone's, and
	# it is the footprint the building actually occupies) plus the same margin. `away` is degenerate
	# here — the destination IS the garage — so `return_pose_for` falls back to +X and the road walk
	# below then puts the car on the road proper.
	_spawn_face_target = _default_spawn_map_pos()
	_spawn_gap_m = (cfg.overworld_pad_garage_radius_m if cfg != null else 21.0) \
		+ RETURN_SPAWN_MARGIN_M
	return return_pose_for(_spawn_face_target, _hq_map_pos, _size_m, _spawn_gap_m)


## Where the car stands when it comes back from a rally: JUST OUTSIDE that rally's zone, FACING it.
##
## It used to land ON the pin with an arbitrary heading, which read as being teleported into the
## middle of the thing you had just finished. Outside-and-facing reads as having pulled up to it —
## and it restores the intent of the original design decision (D8 asked for outside the zone), with
## the heading turned to face it rather than away, as the user asked.
##
## OFFSET DIRECTION is toward the GARAGE, deterministically. Two reasons: it is the direction home,
## so the car is parked between the zone and where it is going next; and it is the convention this
## project already uses for "which way does a pin face" (`hq.gd`'s pin derivation and
## `OverworldZones._ghost_yaw` both orient toward HQ). A rally sitting exactly on the garage falls
## back to +X so the offset is never zero-length.
##
## DISTANCE is the live trigger radius plus a margin, so the car starts OUTSIDE the dwell circle.
## That matters beyond framing: a zone will not fire until the car has left it once
## (OverworldZone's arm-on-exit latch), so spawning inside would leave the zone disarmed until the
## player drove out. Starting outside means it is armed immediately — which is also why the car is
## pointed AT the zone rather than into it from within: driving forward re-enters deliberately.
##
## Move a spawn pose onto the nearest ROAD, keeping it clear of its destination and still facing it.
## Serves both spawns: the rally just completed, and the garage on a cold start.
##
## `return_pose_for` picks the spot geometrically — trigger radius plus a margin, in the direction of
## the garage — which is the right DISTANCE but lands wherever that happens to be, verge included.
## The roads exist to be driven, and a car handed back on the grass has to find its way onto one
## before it can go anywhere, so the pose is walked onto the network here.
##
## HOW: walk the road that serves this zone outward FROM the pin, accumulating length, and stop at
## the first point past the gap. That gives a point which is on the centreline AND outside the dwell
## circle by construction — a plain "snap to nearest road point" cannot promise the second, because
## the nearest point to a spot beside the zone is often back inside it.
##
## Falls back to the geometric pose when there is no usable road (no network yet, or an isolated
## pin), so the return still works; it is just not guaranteed to be on tarmac.
func _snap_spawn_pose_to_road(pose: Transform3D) -> Transform3D:
	var pin_id := _spawn_face_target
	if pin_id == Vector2.INF:
		return pose   # no destination recorded — nothing to stand outside of
	var pin := world_xz(pin_id, _size_m)
	var pin_xz := Vector2(pin.x, pin.z)
	var gap := _spawn_gap_m
	var best := Vector2.INF
	var best_end := INF
	for points in _road_polylines():
		# Which end of this polyline meets the pin? Only an edge that actually touches the zone
		# leads anywhere useful; the far end of some unrelated road would put the car across the map.
		for from_start in [true, false]:
			var first: Vector2 = points[0] if from_start else points[points.size() - 1]
			var d0 := first.distance_to(pin_xz)
			if d0 >= best_end:
				continue
			var walked := _walk_polyline(points, from_start, gap)
			if walked == Vector2.INF:
				continue
			best_end = d0
			best = walked
	if best == Vector2.INF or best.distance_to(pin_xz) <= gap * 0.5:
		return pose
	var here := Vector3(best.x, 0.0, best.y)
	var yaw := OverworldZones.facing_yaw(here, pin) + HqController.PRIZE_CAR_FACING_TURN
	return Transform3D(Basis(Vector3.UP, yaw), here)


## Walk `points` from one end, returning the first point at least `dist` along it (INF if the whole
## polyline is shorter than that — an edge too short to stand clear of the zone on).
static func _walk_polyline(points: PackedVector2Array, from_start: bool, dist: float) -> Vector2:
	var travelled := 0.0
	var n := points.size()
	for i in n - 1:
		var a: Vector2 = points[i] if from_start else points[n - 1 - i]
		var b: Vector2 = points[i + 1] if from_start else points[n - 2 - i]
		var seg := a.distance_to(b)
		if seg <= 0.0:
			continue
		if travelled + seg >= dist:
			return a.lerp(b, (dist - travelled) / seg)
		travelled += seg
	return Vector2.INF


## STATIC and pure, so the geometry is testable with no scene, no terrain and no car.
static func return_pose_for(pin: Vector2, hq: Vector2, size_m: float, gap_m: float) -> Transform3D:
	var away := hq - pin
	var dir := away.normalized() if not away.is_zero_approx() else Vector2.RIGHT
	var stand := pin + dir * (gap_m / maxf(size_m, 1.0))
	var here := world_xz(stand, size_m)
	# Face the pin. `OverworldZones.facing_yaw` turns +Z onto the target, and car.tscn faces -Z, so
	# it takes the same half-turn correction the prize-car markers use — one convention, not a
	# fourth one invented here.
	var yaw := OverworldZones.facing_yaw(here, world_xz(pin, size_m)) \
		+ HqController.PRIZE_CAR_FACING_TURN
	return Transform3D(Basis(Vector3.UP, yaw), here)


# Where a game START puts the player: THE GARAGE (RallyLibrary.HQ_MAP_POS).
#
# This used to walk the roster and spawn at the first COMPLETED rally's pin, falling back to the
# map centre. Both halves were wrong:
#
#   * "first completed" is `RallyLibrary.RALLIES` ARRAY order, and that file's own header says
#     the table is grouped by authoring order and "array order carries no meaning" — so which of
#     your completed rallies you woke up at was arbitrary rather than the most recent or the
#     nearest home.
#   * the fallback dropped the player at the map centre, which HQ does NOT light
#     (`map_hq_reveal_radius` ships 0.0), so a player who had picked a starter but completed
#     nothing spawned in the fog and was immediately shoved by the soft turn-back.
#
# The garage is the right answer on every count: it is a road NODE, so you start ON the network
# with somewhere to drive rather than in trackless forest; it is a fixed, learnable place; and
# its zone is exempt from the fog gate, so it is never dark. Being parked in the garage zone at
# spawn is harmless because a zone will not fire until the car has left it once (see
# OverworldZone's arm-on-exit latch) — that latch exists precisely because of this overlap.
func _default_spawn_map_pos() -> Vector2:
	return _hq_map_pos


# Seat the car at `pose`, lifted onto the terrain. reset_to is the ONLY safe teleport (a bare
# global_transform write is discarded by the physics server outside the step).
func _seat_car(car: Node3D, pose: Transform3D) -> void:
	var tm := _floor()
	var p := pose.origin
	p.y = tm.height_at(p.x, p.z) + Config.data.spawn_clearance
	var seated := Transform3D(pose.basis, p)
	car.call("reset_to", seated)
	_last_lit_pose = seated
	_has_lit_pose = position_revealed(map_pos_of(p, _size_m))
	tm.update_focus(p)


# ==========================================================================================
# Per-frame
# ==========================================================================================

func _process(delta: float) -> void:
	if not _ready_done:
		return
	var cfg: GameConfig = Config.data
	# Region look follows the car; the GROUND blends spatially at the boundary, the sky colours
	# fade over time and only the sky panorama snaps (see _apply_region_look). Checked
	# every REGION_INTERVAL frames, not every frame: the lookup re-hashes the rally roster to
	# invalidate its Voronoi sites, and a region is hundreds of metres across, so a third of a
	# second of latency on the crossing is invisible.
	# The six Time.get_ticks_usec() reads below feed _log_frame_spike, a DEBUG-ONLY diagnostic
	# that returns immediately when _spike_log is false. Gathering them unconditionally cost six
	# clock reads every frame (~360/s) on the shipping path to feed a function that discards
	# them, so the timed version is now chosen once per frame rather than paid for always.
	if not _spike_log:
		_process_stages(cfg, delta)
		_track_pause_menu()
		return
	var t_region := Time.get_ticks_usec()
	_region_countdown -= 1
	if _region_countdown <= 0:
		_region_countdown = REGION_INTERVAL
		_apply_region_look(car_map_pos())
	var t_fog := Time.get_ticks_usec()
	_update_fog_boundary(delta)
	var t_foliage := Time.get_ticks_usec()
	if _scatter != null:
		_stream_foliage(cfg, maxi(1, cfg.overworld_chunk_build_budget))
	# Evict cached chunk data beyond the resident window, so a long drive across 16 km² cannot
	# grow the terrain cache without bound. Every EVICT_INTERVAL frames rather than every
	# frame: the sweep sums every cached chunk's byte size, and the cache cannot cross the cap
	# in a handful of frames when the build budget is a couple of chunks.
	var t_evict := Time.get_ticks_usec()
	_evict_countdown -= 1
	if _evict_countdown <= 0:
		_evict_countdown = EVICT_INTERVAL
		_floor().evict_to_cap()
	var t_zones := Time.get_ticks_usec()
	_update_zones(delta)
	var t_end := Time.get_ticks_usec()
	_log_frame_spike(delta, t_region, t_fog, t_foliage, t_evict, t_zones, t_end)
	_track_pause_menu()


# The per-frame work, untimed. EXACTLY the same sequence and the same conditions as the timed
# path in _process — if you add a stage to one, add it to the other. Kept as a straight copy
# rather than a Callable-per-stage loop because this runs every frame and the ordering comments
# belong next to the calls they explain.
func _process_stages(cfg: GameConfig, delta: float) -> void:
	_region_countdown -= 1
	if _region_countdown <= 0:
		_region_countdown = REGION_INTERVAL
		_apply_region_look(car_map_pos())
	_update_fog_boundary(delta)
	if _scatter != null:
		_stream_foliage(cfg, maxi(1, cfg.overworld_chunk_build_budget))
	_evict_countdown -= 1
	if _evict_countdown <= 0:
		_evict_countdown = EVICT_INTERVAL
		_floor().evict_to_cap()
	_update_zones(delta)


# Frame-spike attribution. `PerfLog` prints once a SECOND, which averages a 40 ms hitch away to
# nothing — useless for finding a stutter. This prints only on frames that actually blew out, and
# names which per-frame stage ate the time, so a spike is attributed rather than guessed at.
#
# Debug builds only, and it prints nothing on a healthy frame, so it costs one clock read per
# stage. Mute with OVERWORLD_SPIKE_LOG=0. TEMPORARY: delete once the streaming budgets are tuned.
func _log_frame_spike(delta: float, t_region: int, t_fog: int, t_foliage: int, t_evict: int,
		t_zones: int, t_end: int) -> void:
	if not _spike_log:
		return
	var frame_ms := delta * 1000.0
	if frame_ms < SPIKE_MS:
		return
	# Stage costs, in the order they ran. The terrain's own three stages come from
	# TerrainManager.stage_timing (armed below in _ready alongside _spike_log): they used to fall
	# into `other`, which meant the one tool built to attribute spikes was blind to the most
	# likely cause of them. `other` is now only what neither node can see — physics and rendering.
	var region_ms := float(t_fog - t_region) / 1000.0
	var fog_ms := float(t_foliage - t_fog) / 1000.0
	var foliage_ms := float(t_evict - t_foliage) / 1000.0
	var evict_ms := float(t_zones - t_evict) / 1000.0
	var zones_ms := float(t_end - t_zones) / 1000.0
	var tm := _floor()
	var focus_ms := 0.0
	var spawn_ms := 0.0
	var detail_ms := 0.0
	if tm != null:
		focus_ms = float(tm.last_focus_us) / 1000.0
		spawn_ms = float(tm.last_spawn_drain_us) / 1000.0
		detail_ms = float(tm.last_detail_drain_us) / 1000.0
	var mine_ms := region_ms + fog_ms + foliage_ms + evict_ms + zones_ms \
		+ focus_ms + spawn_ms + detail_ms
	# `store_reads` vs `stream_builds` is the important pair: reads are the healthy path (one seek
	# off the precompute), builds mean something generated a chunk live and should be ZERO.
	print("[ow-spike] frame=%.1fms | focus=%.2f spawn=%.2f detail=%.2f region=%.2f fog=%.2f foliage=%.2f evict=%.2f zones=%.2f = %.2f | other=%.1f | foliage_chunks=%d resident=%.1fMB store_reads=%d stream_builds=%d"
		% [frame_ms, focus_ms, spawn_ms, detail_ms,
			region_ms, fog_ms, foliage_ms, evict_ms, zones_ms, mine_ms,
			maxf(frame_ms - mine_ms, 0.0), _foliage.size(),
			tm.cache_size_mb() if tm != null else 0.0,
			tm.store_reads if tm != null else 0,
			tm.stream_on_miss_builds if tm != null else 0])


func _update_zones(delta: float) -> void:
	if _picker != null:
		_picker.update(delta)
	if _zones != null and _zones.has_method("update"):
		_zones.call("update", delta)
	_update_garage(delta)
	if _map == null:
		return
	var car := get_node_or_null("Car") as Node3D
	if car == null or not car.is_inside_tree():
		return
	if _map != null:
		_map.update(delta, car.global_position, car.global_basis)


# The GARAGE zone. Built here rather than by the zone manager because the manager builds one
# zone per ROSTER ENTRY, and the garage is not a rally — it has no id, no map_pos and no reveal
# state, so it would never appear there. Driving into it is how the player reaches the garage
# at all (the spec's D2), so it cannot be optional.
#
# It sits AT THE SIDE OF THE ROAD at RallyLibrary.HQ_MAP_POS — the map's own notion of where home
# is, which the table already uses and deliberately does NOT draw a pin for.
# THE GARAGE, as a building you drive into.
#
# It replaced a dwell ZONE that teleported the player to hq.tscn. That was always a stand-in: the
# garage is a place, and "park near it for three seconds and the screen changes" is a menu wearing
# a location's clothes. Now the car drives in through the opening, goes up on the lift, and the
# tuning/upgrade pages open WITHOUT leaving this scene.
#
# The old zone is gone rather than kept alongside: a light tube at the door that teleported you to
# the old HQ as you approached would actively fight the building.
func _build_garage() -> void:
	if _cheap:
		return
	var tm := _floor()
	_garage = OverworldGarage.new()
	# WHERE it stands is derived from the ROADS, not authored: the HQ pin is a junction, so a
	# building centred on it takes every approach road into a wall. `placement_from_config` steps
	# it off to the side of the road axis and yaws it to face back at the road, so any approach
	# ends in a straight run into the opening. Pure and deterministic — the same network always
	# gives the same pose, which the chunk-cache stamp relies on.
	var dirs: Array[Vector2] = []
	if _roads != null and _roads.is_built():
		dirs = _roads.approach_dirs(_roads.hq_index())
	var place := OverworldGarage.placement_from_config(dirs)
	# Parented BEFORE setup: it builds its walls and pad as children and needs a global transform.
	add_child(_garage)
	_garage.setup({
		"to_world": Callable(self, "_zone_world_pos"),
		"map_pos": _hq_map_pos,
		"offset_xz": place["offset"],
		"yaw": place["yaw"],
		"ground_at": Callable(self, "_zone_ground_on").bind(tm),
		"car": get_node_or_null("Car"),
		"visuals": not _cheap,
	})


func _update_garage(delta: float) -> void:
	if _garage != null:
		_garage.update(delta)


# The overworld IS the hub, so the pause menu's "Quit to HQ" has nowhere of its own to go —
# left alone it calls Scenes.hub_path(), which with the flag on is THIS scene, i.e. a reload.
#
# pause_menu.gd is not ours to change and exposes no "quit pressed" signal, so we redirect it
# by consent: while the pause menu is OPEN, raise `return_to_garage`. Quitting then lands in
# hq.tscn at its GARAGE view — the same destination the garage zone uses, and the one that
# hq.gd deliberately does NOT redirect back out of (the infinite-loop guard). Resuming clears
# the flag again, so an ordinary pause leaves no trace.
func _track_pause_menu() -> void:
	var pause := get_node_or_null("PauseMenu") as PauseMenu
	if pause == null:
		return
	var open := pause.is_open()
	if open == _pause_was_open:
		return
	_pause_was_open = open
	if open:
		RallySession.return_to_garage = true
	else:
		RallySession.return_to_garage = false


# The pause menu's "Reset to track" has no track out here; put the car back on its wheels at
# the last ground it stood on inside the frontier.
func _on_reset_requested() -> void:
	var car := $Car as Node3D
	var pose := _last_lit_pose if _has_lit_pose else _resolve_spawn_pose()
	_seat_car(car, pose)


func _exit_tree() -> void:
	if _cache != null:
		_cache.close()
		_cache = null
	# Global shader parameters PERSIST ACROSS SCENE CHANGES and the HQ draws ground with the
	# same shaders, so a fog mask pushed here must be cleared on the way out.
	# NOT gated on _headless, deliberately. Setting a global shader parameter is harmless with no
	# renderer, and gating it would mean the anti-leak path — the thing most worth having a test
	# for — is the one path a headless test can never execute, so the guard would pass vacuously.
	# This is features/testing.md's rule that a headless gate may skip the animation but never
	# the final state.
	var declared := RenderingServer.global_shader_parameter_get_list()
	# Disarming `amount` is what actually makes the fog inert everywhere else — it is the one
	# uniform the shader early-outs on, so clearing it alone is sufficient and cannot be defeated
	# by a stale mask or size left in place.
	if declared.has(StringName(FOG_GLOBAL_AMOUNT)):
		RenderingServer.global_shader_parameter_set(FOG_GLOBAL_AMOUNT, 0.0)
	if declared.has(StringName(FOG_GLOBAL_UNLIT)):
		RenderingServer.global_shader_parameter_set(FOG_GLOBAL_UNLIT, 1.0)
	# ...and SIZE, which closes the known partial-disarm gap in the way that is actually safe.
	#
	# `overworld_fog_at` early-outs on `ow_fog_amount <= 0.0 || ow_fog_size_m <= 0.0`, so zeroing the
	# size is a SECOND, INDEPENDENT no-op guarantee: a future shader (or a future edit) that forgot
	# the amount check would still read no fog from this scene. Cheap insurance on a leak class that
	# has already bitten this project once.
	#
	# The MASK is deliberately LEFT: it is a `sampler2D` global, and there is no null-shaped value to
	# write into a texture slot — attempting one risks a runtime error on the way out of the scene,
	# which is a worse trade than what it would buy. All it holds is a reference to a 64x64 R8
	# texture (a few KB), and with both scalars disarmed nothing can sample it.
	if declared.has(StringName(FOG_GLOBAL_SIZE)):
		RenderingServer.global_shader_parameter_set(FOG_GLOBAL_SIZE, 0.0)


# ==========================================================================================
# Per-car visual effects (the stage's _build_persistent_managers, minus the stage-only parts)
# ==========================================================================================

# Ported from world.gd::_build_persistent_managers. Deliberately NOT ported:
#   - TrackProgress / StageManager / ReplayRecorder — stage-only systems (and TrackProgress
#     would teleport an off-road car back to a road that mostly isn't there);
#   - EngineSmoke — its only trigger is an engine misfire, which needs damage, and damage is
#     deliberately off in the hub (_field_car), so it would be permanently silent;
#   - RoadMarkings — needs a per-polyline loop over the road NETWORK; out of scope for now.
# Every effect below self-gates on its own GameConfig flag (`tire_marks_enabled`,
# `wheel_particles_enabled`, `exhaust_flames_enabled`), so they are created unconditionally
# exactly as the stage creates them.
func _build_effects(cfg: GameConfig, tm: TerrainManager) -> void:
	var car := $Car as Node
	# Tyre marks, in the UNGATED mode: the hub has a road NETWORK, not a single centerline, so
	# there is no corridor to test against and the terrain's own surface weights (the roads are
	# carved into them) decide where a mark can be laid. See tire_marks.gd -> _ungated.
	_tire_marks = TireMarks.new()
	_tire_marks.name = "TireMarks"
	add_child(_tire_marks)
	_tire_marks.setup(null, car, tm, cfg.track_width * 0.5)

	# Wheel spray. Child of the ROOT (it is a pooled MultiMesh that positions its own puffs).
	_wheel_particles = WheelParticles.new()
	_wheel_particles.name = "WheelParticles"
	add_child(_wheel_particles)
	_wheel_particles.setup(car)
	_push_grass_overrides(RegionLibrary.look_of(_look_region))

	# Exhaust backfire flames. Also a child of the root, never of the car: setup() sets
	# `_follow_car` and drives its own transform from the car's.
	_exhaust_flames = ExhaustFlames.new()
	_exhaust_flames.name = "ExhaustFlames"
	add_child(_exhaust_flames)
	_exhaust_flames.setup(car)


# Push the region's grass-spray look onto the wheel pool. Called from the build AND from every
# region crossing (_apply_region_look) — a stage sets these once because it has one region; the
# hub's region changes under the player.
func _push_grass_overrides(look: Dictionary) -> void:
	if _wheel_particles == null or not is_instance_valid(_wheel_particles):
		return
	_wheel_particles.set_grass_color_override(
		look.get("grass_particle_color", Color(0, 0, 0, 0)))
	_wheel_particles.set_grass_square_override(
		bool(look.get("grass_particle_square", false)))


# Prime the surface-effect shaders while the loading overlay still covers the view, exactly as
# world.gd does after its track build: under gl_compatibility a material's shader variant
# compiles on its first VISIBLE draw, and these pools are off-screen (or empty) until first
# used, so without this the first skid or backfire pays a one-frame compile hitch. Auto-
# discovers the warm_up()/clear_warm_up() contract rather than naming nodes, so a later effect
# is primed for free. See features/rendering.md -> "Shader pre-warm".
func _warm_effect_shaders() -> void:
	if _headless:
		return
	var warmers := find_children("*", "Node", true, false).filter(
		func(n: Node) -> bool: return n.has_method("warm_up") and n.has_method("clear_warm_up"))
	if warmers.is_empty():
		return
	var point := _warm_up_point()
	for n in warmers:
		n.call("warm_up", point)
	await get_tree().process_frame
	for n in warmers:
		n.call("clear_warm_up")


# A point ~2 m in front of the active camera — where a warm-up instance is guaranteed to sit
# inside the frustum (so it actually draws and compiles). Falls back to the car. Mirrors
# world.gd::_warm_up_point.
func _warm_up_point() -> Vector3:
	var cam := get_viewport().get_camera_3d()
	if cam != null:
		return cam.global_position - cam.global_transform.basis.z * 2.0
	var car := get_node_or_null("Car") as Node3D
	return car.global_position if car != null else Vector3.ZERO


# ==========================================================================================
# Small helpers
# ==========================================================================================

func _floor() -> TerrainManager:
	if _floor_tm == null:
		_floor_tm = get_node_or_null("Floor") as TerrainManager
	return _floor_tm


func _layers_match(layers: Array[TerrainLayer], params: Array[Vector2]) -> bool:
	if layers.size() != params.size():
		return false
	for i in layers.size():
		if layers[i] == null or layers[i].wavelength_m != params[i].x \
				or layers[i].amplitude_m != params[i].y:
			return false
	return true
