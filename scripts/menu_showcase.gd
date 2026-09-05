class_name MenuShowcase
extends Node3D
# Docs: features/menu-showcase.md — update in the same change as this file.
# Tests: tests/headless/test_menu_showcase.gd, tests/headless/test_menu_showcase_geometry.gd
# — extend in the same change.
#
# Phase 2 of todo/menu-background-showcase.md: one fixed-seed track sliced into
# arc-length SEGMENTS, one per RegionLibrary region, each rendered by its OWN
# TerrainManager instance carrying that region's ground look (grass/gravel/tarmac).
# All six instances bake the SAME centerline with the SAME noise_seed/cliff params,
# so the underlying height field is byte-identical across every segment boundary —
# only the SURFACE MATERIAL differs, which is what keeps the ground seamless where
# two regions meet even though it's six separate TerrainManager objects.
#
# PHASE 4 (todo/menu-background-showcase.md, decision 3): each segment independently
# cycles, every now and then, through weather ids ELIGIBLE FOR ITS OWN REGION (never
# rain in the snow segment, never snow outside it — see _REGION_WEATHER_IDS) —
# snapping, not blending, reusing WeatherLibrary's existing discrete entries. Split
# into two halves for a reason found while implementing it:
#
#   - The GROUND half (road_tint on a segment's own material) is a live shader
#     uniform change — cheap, correct to apply on EVERY segment continuously,
#     regardless of which one the camera is looking at.
#   - The ENVIRONMENT half (sky/fog/background) is NOT: `world.gd::_apply_overcast_look`
#     also writes `TerrainManager.sun_color`/`sky_color`, which only take effect on
#     the next BAKE — chunks already spawned keep their baked-in vertex lighting
#     forever. Six already-built, never-rebuilt segments can't cheaply re-light like
#     a real stage does, so the sun/sky-tint-on-terrain half is DELIBERATELY DROPPED
#     here — only the shared WorldEnvironment's sky/fog/background is swapped, and
#     only for whichever segment the camera currently frames (there is exactly one
#     WorldEnvironment for the whole scene, so it can't show six skies at once
#     anyway). The swap happens exactly at a camera CUT, never mid-shot, so the
#     change is never seen happening.
#
# FOLIAGE (phase 2's remaining piece) and the MOBILE LOD-TIER CAP (decision 5) are
# both implemented too: trees/bushes are scattered ONCE over the whole track (same
# "compute once, split by segment" shape as the corridor above) via the same
# TreeScatter/Foliage machinery world.gd uses, then partitioned per segment by arc
# length and spawned using that segment's own RegionLibrary.tree_mix. Every segment's
# TerrainManager is forced to the lowest ("web touch") LOD/render-distance tier
# regardless of the device actually running it — this is decoration, not gameplay a
# player needs full LOD to read, and it caps six segments' worth of resident terrain
# at a known-affordable ceiling rather than the desktop tier six times over.
#
# KNOWN LIMITATION: the border-safety rule below only guards ADJACENT segments along
# the road's own arc length — it does not check whether a generated track loops back
# SPATIALLY close to a distant (non-adjacent) segment. A pathological seed could route
# two arc-far segments close enough in world space for a wide shot in one to see the
# other's ground. SHOWCASE_SEED should be eyeballed for this the way any authored
# look is eyeballed; it is not guarded automatically today.

const SHOWCASE_SEED := 8675309
# Long enough that six segments each comfortably clear 2×BORDER_MARGIN_M plus the
# shots' look-ahead distance. Picked by eye, like any other authored background —
# not a tunable balance value.
const TURN_COUNT := 20
const STRAIGHTNESS := 0.75

# How far past a segment's own chunks its TerrainManager instance's corridor reaches
# — enough for a shot's near/far frustum, no more (nothing drives here).
const _CORRIDOR_LEASH_M := 50.0

# How far a camera shot (both its own position AND its look-ahead point) must stay
# from every segment boundary, so neither the seam nor the next region's ground/
# texture is ever in frame. Hand-tuned; revisit if a wide establishing shot is later
# added that needs more clearance than the fixed offset here does.
const _BORDER_MARGIN_M := 60.0
const _SHOTS_PER_SEGMENT := 2
const _SHOT_AHEAD_M := 20.0
const _SHOT_OFFSET := Vector3(10.0, 9.0, 10.0)

# Which WeatherLibrary ids each region may cycle through — the showcase's own
# equivalent of RallyLibrary authoring "sandstorm" only onto region == "greece"
# events (test_rally_library.gd::test_sandstorm_only_authored_on_greece_events) and
# "snow" only onto region == "snow" ones. Every id used here must be a real
# WeatherLibrary entry (test_menu_showcase_geometry.gd asserts it), and every region
# must map to a non-empty list.
const _REGION_WEATHER_IDS := {
	"home": ["dry", "rain", "fog", "storm", "night"],
	"home_coast": ["dry", "rain", "fog", "storm", "night"],
	"taiga": ["dry", "rain", "fog", "storm", "night"],
	"greece": ["dry", "sandstorm", "night"],
	"greece_coast": ["dry", "sandstorm", "night"],
	"snow": ["dry", "snow", "night"],
}
# How long a segment holds a weather id before rolling the next one. Cosmetic
# timing, not physics — free to be non-deterministic (randf_range), the same
# allowance world.gd's own lightning-flash scheduler documents.
const _WEATHER_REROLL_MIN_S := 20.0
const _WEATHER_REROLL_MAX_S := 45.0

# Distinct seed offsets so the tree and bush scatters interleave rather than landing
# on the same grid points — mirrors world.gd's BUSH_SEED_OFFSET; the value itself is
# arbitrary, only its difference from SHOWCASE_SEED matters.
const _BUSH_SEED_OFFSET := 1013

@onready var _template_floor: TerrainManager = $Floor
@onready var _world_environment: WorldEnvironment = $WorldEnvironment

var _camera: MenuShowcaseCamera
var _segment_floors: Array[TerrainManager] = []
# Parallel arrays, indexed by segment i — kept as plain Arrays rather than a
# Dictionary-per-segment so _process's per-frame walk stays a flat loop.
var _segment_region_ids: Array[String] = []
var _segment_weather_ids: Array[String] = []
var _segment_reroll_timers: PackedFloat32Array = PackedFloat32Array()
var _segment_baseline_tarmac: Array[Color] = []
# shot index -> the segment it was built from, so the environment swap below can
# tell which region the camera just cut TO without assuming every segment
# contributed the same shot count.
var _shot_segments: Array[int] = []
var _viewed_shot := -1
var _baseline_env := {}
var _built := false


func _ready() -> void:
	await _build()


func is_built() -> bool:
	return _built


func camera() -> MenuShowcaseCamera:
	return _camera


func segment_floors() -> Array[TerrainManager]:
	return _segment_floors


func _build() -> void:
	var cfg: GameConfig = Config.data
	var env: Environment = _world_environment.environment
	_baseline_env = {
		"background_color": env.background_color,
		"fog_light_color": env.fog_light_color,
		"fog_density": env.fog_density,
		"fog_sky_affect": env.fog_sky_affect,
	}
	var params := TrackGenParams.new()
	params.seed = SHOWCASE_SEED
	params.turn_count = TURN_COUNT
	params.straightness = STRAIGHTNESS
	params.width = cfg.track_width
	params.clearance = cfg.track_clearance

	var result: Dictionary = await TrackGenerator.generate(params)
	var centerline := result["centerline"] as Curve2D
	var total_length := centerline.get_baked_length()

	var regions := RegionLibrary.ordered()
	var bounds := segment_bounds(total_length, regions.size())
	var bake_args := TerrainManager.bake_args(cfg)
	# One shared corridor over the WHOLE track (+leash), computed once; each segment's
	# TerrainManager only builds the slice of it that falls in its own arc-length range
	# (see _coords_in_range) — so six instances tile seamlessly rather than overlapping
	# or gapping.
	var full_corridor := _template_floor.corridor_coords(centerline, _CORRIDOR_LEASH_M)

	# Foliage, same "compute once over the whole track, split by segment" shape as the
	# corridor above — mirrors world.gd::_build_foliage's tree/bush scatter exactly
	# (same TreeScatter.scatter call, same road-rejection cells), just fed this
	# scene's own generated `result`/`centerline` instead of a driven stage's.
	var road_poly := centerline.tessellate()
	var road_cells := TrackGenerator.rasterize_cells(
		road_poly, cfg.track_width + 2.0 * cfg.tree_road_margin_m)
	var all_trees := TreeScatter.scatter(result["pieces"], road_cells, cfg.tree_params(),
		SHOWCASE_SEED, cfg.track_forestiness, cfg.forest_wavelength_m)
	# Bushes reject on a WIDER footprint than trees (the mesh's own xz radius on top
	# of the road margin — world.gd's bush_road_cells) and are NOT forest-gated
	# (default forestiness 1.0), same split as world.gd::_build_foliage.
	var bush_radius := TreeMeshField.xz_radius(Foliage.bush_mesh(), cfg.bush_height_m)
	var bush_road_cells := TrackGenerator.rasterize_cells(
		road_poly, cfg.track_width + 2.0 * (cfg.tree_road_margin_m + bush_radius))
	var all_bushes := TreeScatter.scatter(result["pieces"], bush_road_cells, cfg.tree_params(),
		SHOWCASE_SEED + _BUSH_SEED_OFFSET)
	# Lowest ("web touch") tier's render distance regardless of device — see decision
	# 5, and the class comment on why every segment is capped this way.
	var render_distance := cfg.tree_render_distance_web_touch_m

	var shots: Array = []
	for i in regions.size():
		var region_id := String(regions[i].get("id", ""))
		var lo: float = bounds[i]
		var hi: float = bounds[i + 1]
		var floor_tm := _floor_for_segment(i, region_id, cfg)
		floor_tm.noise_seed = SHOWCASE_SEED
		cfg.apply_cliffs(floor_tm)
		cfg.apply_terrain_lod(floor_tm)
		# Force the lowest tier's LOD bands specifically (apply_terrain_lod above
		# seats the AUTHORED baseline, i.e. whichever tier a real stage most
		# recently resolved into cfg.terrain_lod_bands_m — never mutate that shared
		# field, just override this segment's own band ends after the fact).
		floor_tm.lod_band_ends_m = cfg.terrain_lod_bands_web_touch_m
		await floor_tm.set_track(centerline, bake_args[0], bake_args[1], bake_args[2], bake_args[3], bake_args[4])
		var coords := _coords_in_range(full_corridor, centerline, lo, hi)
		floor_tm.set_corridor(coords)
		for coord in coords:
			floor_tm.cache_chunk(coord)
		_spawn_segment(floor_tm, coords)
		var segment_shots := _build_segment_shots(centerline, floor_tm, lo, hi)
		shots.append_array(segment_shots)
		for _s in segment_shots:
			_shot_segments.append(i)

		_segment_region_ids.append(region_id)
		_segment_baseline_tarmac.append(floor_tm.chunk_material.get_shader_parameter("tarmac_color"))
		_segment_weather_ids.append(WeatherLibrary.DEFAULT_ID)
		_segment_reroll_timers.append(0.0)
		_reroll_segment_weather(i)  # picks the initial id and sets the real reroll timer

		var look := RegionLibrary.look_of(region_id)
		_spawn_segment_trees(floor_tm, look, all_trees, centerline, lo, hi, render_distance, cfg)
		if RegionLibrary.spawns_bush_mesh(look):
			var segment_bushes := _points_in_range(all_bushes, centerline, lo, hi)
			Foliage.spawn_bushes(self, segment_bushes, floor_tm, render_distance, cfg.tree_render_fade_m)

	_camera = MenuShowcaseCamera.new()
	add_child(_camera)
	_camera.setup(shots)
	_camera.current = true
	if not _shot_segments.is_empty():
		_viewed_shot = 0
		_apply_segment_environment(_shot_segments[0])
	_built = true


func _process(delta: float) -> void:
	if not _built:
		return
	for i in _segment_reroll_timers.size():
		_segment_reroll_timers[i] -= delta
		if _segment_reroll_timers[i] <= 0.0:
			_reroll_segment_weather(i)
	var shot_idx := _camera.current_shot()
	if shot_idx != _viewed_shot and shot_idx < _shot_segments.size():
		_viewed_shot = shot_idx
		_apply_segment_environment(_shot_segments[shot_idx])


# Which WeatherLibrary ids `region_id` may cycle through. Pure lookup, testable
# without building any terrain; falls back to dry-only for an unmapped id (there
# should never be one — see the compatibility test) rather than crashing.
static func eligible_weather_ids(region_id: String) -> Array:
	return _REGION_WEATHER_IDS.get(region_id, [WeatherLibrary.DEFAULT_ID])


func _reroll_segment_weather(i: int) -> void:
	var eligible := eligible_weather_ids(_segment_region_ids[i])
	_segment_weather_ids[i] = eligible[randi() % eligible.size()]
	_segment_reroll_timers[i] = randf_range(_WEATHER_REROLL_MIN_S, _WEATHER_REROLL_MAX_S)
	_apply_segment_road_tint(i)


# The GROUND half of the weather look (see the class comment for why it's split from
# the environment half): re-seed the segment's material to its region baseline, then
# apply the current condition's road_tint if it has one — the exact read-modify-write
# world.gd::_tint_road does, just against this segment's own (never-shared) material
# instead of the one `$Floor.chunk_material` every stage repaints in place.
func _apply_segment_road_tint(i: int) -> void:
	var mat := _segment_floors[i].chunk_material as ShaderMaterial
	mat.set_shader_parameter("albedo_color", Color(1.0, 1.0, 1.0, 1.0))
	mat.set_shader_parameter("tarmac_color", _segment_baseline_tarmac[i])
	var entry := WeatherLibrary.by_id(_segment_weather_ids[i])
	var road_tint: Dictionary = entry.get("road_tint", {})
	if road_tint.is_empty():
		return
	var cfg: GameConfig = Config.data
	var amount := float(cfg.get(String(road_tint["amount"])))
	var color_field := String(road_tint.get("color", ""))
	var blend := color_field != ""
	var toward: Color = cfg.get(color_field) if blend else Color.BLACK
	for param in ["albedo_color", "tarmac_color"]:
		var col: Color = mat.get_shader_parameter(param)
		var out: Color
		if blend:
			out = col.lerp(Color(toward.r, toward.g, toward.b, col.a), amount)
		else:
			out = Color(col.r * amount, col.g * amount, col.b * amount, col.a)
		mat.set_shader_parameter(param, out)


# The ENVIRONMENT half: swap the one shared WorldEnvironment's sky/fog/background to
# match segment `i`'s CURRENT weather id, exactly at the moment the camera cuts to
# it. Deliberately does not touch TerrainManager.sun_color/sky_color — see the class
# comment on why that half is dropped rather than done wrong.
func _apply_segment_environment(i: int) -> void:
	var cfg: GameConfig = Config.data
	var entry := WeatherLibrary.by_id(_segment_weather_ids[i])
	var env: Environment = _world_environment.environment
	var look: Dictionary = entry.get("look", {})
	if look.is_empty():
		env.background_color = _baseline_env["background_color"]
		env.fog_light_color = _baseline_env["fog_light_color"]
		env.fog_density = _baseline_env["fog_density"]
		env.fog_sky_affect = _baseline_env["fog_sky_affect"]
	else:
		var background: Color = cfg.get(String(look["background_color"]))
		env.background_color = background
		env.fog_light_color = background
		env.fog_density = _baseline_env["fog_density"] * float(cfg.get(String(look["fog_density_mult"])))
		env.fog_sky_affect = float(cfg.get(String(look["fog_sky_affect"])))
	var sky_mat := env.sky.sky_material as PanoramaSkyMaterial
	if sky_mat:
		var sky_field := String(entry.get("sky_panorama", ""))
		var sky_path := String(cfg.get(sky_field)) if sky_field != "" else cfg.default_sky_panorama
		if sky_path != "":
			sky_mat.panorama = load(sky_path)


# Spawn EVERY coord in a segment's own corridor slice directly, instead of
# `build_initial()`/`_reconcile` — those build only a RING (`target_coords`, radius
# `load_radius`) around ONE focus point, meant for a focus that keeps moving and
# streams the rest in over time (a real stage's car). Nothing here ever moves, and a
# segment's corridor is a curving BAND along its stretch of road, not a disc around
# one point, so a single ring would leave real, camera-visible holes wherever the
# road bends away from whatever point was chosen as the anchor (this is exactly the
# "corridor region invariant broke" failure this replaced during development — every
# segment except the one containing world-origin (0,0,0), which is what
# `build_initial()` defaults its focus to with no `focus_path`, came up with holes).
# `_spawn_one` is the one shared "read from `_chunk_cache`, else …" ladder
# `_reconcile` itself calls per coord — reusing it directly, once per coord, with no
# focus/eviction logic at all, is the correct one-shot equivalent for a scene that
# never streams.
func _spawn_segment(floor_tm: TerrainManager, coords: Array[Vector2i]) -> void:
	floor_tm._initial_pending = false
	for coord in coords:
		floor_tm._spawn_one(coord)
	floor_tm.flush_detail_queue()


# Segment i (0-based) gets its own TerrainManager. Segment 0 reuses the scene's own
# authored $Floor NODE (already wired with the baseline layers) rather than
# allocating a sixth node for no reason; every segment — including 0 — gets its own
# DUPLICATED material, never the template's own `chunk_material` resource directly.
#
# That duplication is not optional even for a region (like home) that authors no
# override today: `menu_showcase.tscn` embeds `chunk_material` as a plain sub-
# resource with no `resource_local_to_scene`, so — exactly like main.tscn's
# PanoramaSkyMaterial (see regions.md → "The sky no longer leaks between stages") —
# it is the SAME object across every instantiation of this scene in one process.
# Mutating it in place would leak whichever region happened to occupy segment 0
# into every later hub open, the same class of bug that fix documents.
func _floor_for_segment(i: int, region_id: String, cfg: GameConfig) -> TerrainManager:
	var floor_tm: TerrainManager
	if i == 0:
		floor_tm = _template_floor
	else:
		floor_tm = TerrainManager.new()
		floor_tm.layers = _template_floor.layers
		floor_tm.defer_initial_build = true
		floor_tm.focus_path = NodePath("")
		add_child(floor_tm)
	floor_tm.chunk_material = (_template_floor.chunk_material as Material).duplicate()
	_segment_floors.append(floor_tm)
	_apply_region_ground_look(floor_tm, region_id, cfg)
	return floor_tm


# Mirrors world.gd::_apply_region_look's ground/tarmac handling (apply only the keys
# the region actually overrides; home authors none, so its segment keeps the
# template's baseline grass/gravel/tarmac untouched) — deliberately NOT the sky/fog
# half of that function, which stays deferred to a later phase (one shared
# WorldEnvironment can't show six different skies at once; see the spec).
func _apply_region_ground_look(floor_tm: TerrainManager, region_id: String, cfg: GameConfig) -> void:
	var look := RegionLibrary.look_of(region_id)
	var mat := floor_tm.chunk_material as ShaderMaterial
	if look.has("grass_texture"):
		mat.set_shader_parameter("albedo_texture", load(look["grass_texture"]))
	if look.has("gravel_texture"):
		mat.set_shader_parameter("road_texture", load(look["gravel_texture"]))
	mat.set_shader_parameter("tarmac_color", look.get("tarmac_color", cfg.tarmac_color))


# `segment_count` evenly spaced arc-length boundaries over [0, total_length] —
# segment i spans [bounds[i], bounds[i+1]). A pure function of the two lengths so it
# can be tested without building any terrain.
static func segment_bounds(total_length: float, segment_count: int) -> PackedFloat32Array:
	var bounds := PackedFloat32Array()
	for i in segment_count + 1:
		bounds.append(total_length * float(i) / float(segment_count))
	return bounds


# Arc-length positions for shots inside one segment, kept AT LEAST _BORDER_MARGIN_M
# from both boundaries — and far enough from the far one that the look-ahead point
# (ahead_m past the shot) clears it too. Empty if the segment is too short for the
# margin/ahead/count combination (a segment that can't be shot safely gets no shots
# rather than an unsafe one). Pure function, testable without any terrain.
static func safe_shot_arcs(lo: float, hi: float, margin_m: float, ahead_m: float,
		count: int) -> PackedFloat32Array:
	var safe_lo := lo + margin_m
	var safe_hi := hi - margin_m - ahead_m
	var arcs := PackedFloat32Array()
	if safe_hi <= safe_lo or count <= 0:
		return arcs
	if count == 1:
		arcs.append((safe_lo + safe_hi) * 0.5)
		return arcs
	for i in count:
		arcs.append(lerpf(safe_lo, safe_hi, float(i) / float(count - 1)))
	return arcs


func _build_segment_shots(centerline: Curve2D, floor_tm: TerrainManager,
		lo: float, hi: float) -> Array:
	var shots: Array = []
	for s in safe_shot_arcs(lo, hi, _BORDER_MARGIN_M, _SHOT_AHEAD_M, _SHOTS_PER_SEGMENT):
		var here := centerline.sample_baked(s)
		var ahead := centerline.sample_baked(s + _SHOT_AHEAD_M)
		var pos := Vector3(here.x, floor_tm.height_at(here.x, here.y), here.y) + _SHOT_OFFSET
		var look := Vector3(ahead.x, floor_tm.height_at(ahead.x, ahead.y), ahead.y)
		shots.append({"pos": pos, "look_at": look})
	return shots


# Corridor coords (from a full-track corridor list) whose chunk CENTRE's arc-length
# position — via Curve2D.get_closest_offset, the same "nearest point on the curve"
# query the road-surface/progress code uses elsewhere — falls in [lo, hi). Splitting
# the one shared corridor this way (rather than each segment computing its own) is
# what guarantees the six segments tile without gaps or overlaps: every coord is
# classified exactly once, by the same rule, off the same centerline.
static func _coords_in_range(corridor: Array, centerline: Curve2D, lo: float, hi: float) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for coord in corridor:
		var c: Vector2i = coord
		var center := Vector2(c.x, c.y) * TerrainManager.CHUNK_M + Vector2.ONE * (TerrainManager.CHUNK_M * 0.5)
		var s := centerline.get_closest_offset(center)
		# Inclusive on both ends: a chunk landing exactly on a shared boundary gets
		# built into BOTH neighbouring segments rather than neither — a harmless
		# duplicate (heights agree everywhere, see the class comment) that trades a
		# few doubly-built chunks at each seam for never leaving one un-built.
		if s >= lo and s <= hi:
			out.append(c)
	return out


# The same arc-length split as _coords_in_range, for scatter POINTS instead of chunk
# coords — used to divide one whole-track tree/bush scatter across the six segments
# rather than re-scattering per segment (which would double-count trees near a
# boundary and, worse, use a different RNG draw per segment for the same physical
# ground). Inclusive on both ends for the same harmless-duplicate reason.
static func _points_in_range(points: PackedVector2Array, centerline: Curve2D,
		lo: float, hi: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	for p in points:
		var s := centerline.get_closest_offset(p)
		if s >= lo and s <= hi:
			out.append(p)
	return out


# Split segment `region_id`'s own slice of the whole-track tree scatter by species
# (RegionLibrary.tree_mix) and spawn one Foliage.spawn_trees billboard field per
# species, exactly as world.gd::_build_foliage does per stage — just fed this
# segment's own filtered points and TerrainManager instead of a driven stage's.
func _spawn_segment_trees(floor_tm: TerrainManager, look: Dictionary, all_trees: PackedVector2Array,
		centerline: Curve2D, lo: float, hi: float, render_distance: float, cfg: GameConfig) -> void:
	var segment_trees := _points_in_range(all_trees, centerline, lo, hi)
	var mix := RegionLibrary.tree_mix(look)
	var weights: Array = []
	for entry in mix:
		weights.append(entry.get("weight", 1.0))
	var groups := TreeScatter.partition_by_weight(segment_trees, weights, SHOWCASE_SEED)
	for i in mix.size():
		var entry: Dictionary = mix[i]
		Foliage.spawn_trees(self, groups[i], floor_tm, false,
			render_distance, cfg.tree_render_fade_m,
			load(entry["texture"]), String(entry.get("profile", "home")) == "region",
			entry.get("size_scale", Vector2.ONE))
