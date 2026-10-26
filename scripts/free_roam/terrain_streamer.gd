class_name TerrainStreamer
extends Node3D
# Docs: features/free-roam.md — update in the same change as this file.
# Tests: tests/headless/test_free_roam.gd — extend in the same change.
# Streams road-first terrain around the car under a strict per-frame time budget.
#
# Building a chunk is a resumable job split into small units of work: gather nearby roads,
# compute heights a few samples at a time, pack the mesh arrays, upload the mesh, attach it,
# build collision. Each frame the scheduler runs units until the budget is spent and never
# starts a unit that its measured cost says would not fit, so a job can stop between any two
# units and carry on next frame. The car sees this node as its terrain (height_at /
# surface_at), the same way it sees the stage Floor.

const UV_PER_M := 0.125
# How many vertices the array stage packs between clock checks (each is a few µs).
const CHECK_EVERY := 4

enum Stage { PREP, HEIGHTS, ARRAYS, UPLOAD, ATTACH, COLLIDE, PLANT, SPAWN, DONE }

enum Plant { TREE, BUSH, ROCK }
const TREE_SALT := 101
const BUSH_SALT := 202
const ROCK_SALT := 303
const ROADSIDE_SALT := 404

@export var settings: FreeRoamSettings
@export var material: Material

var network := RoadNetwork.new()
var terrain := RoadTerrain.new()
var sites := RoadSites.new()
var barriers := RoadBarriers.new()
var focus: Node3D
# Frame time not taken by anything but terrain (µs), smoothed over recent frames; set by the HUD side.
var spare_us := 2000.0

# Read by the HUD.
var stat_used_us := 0
var stat_total_us := 0
var stat_worst_us := 0
var stat_overruns := 0
var stat_frames := 0
var stat_us_per_sample := 0.0
var stat_build_ms := 0.0
# Over-budget frames by the kind of unit that ran last in them, and the total overshoot (µs).
var stat_overrun_by := {}
var stat_overshoot_us := 0
# Frames more than half as long again as the budget: real hitches rather than a sample's worth of
# overshoot, by the kind of unit that ran last.
var stat_spikes := 0
var stat_spike_by := {}
# Times collision under (or just ahead of) the car was missing and was built at once, over the
# budget (_rush_collision). Rare when streaming keeps up; each one is a hitch instead of a fall.
var stat_rushes := 0
var _last_kind := ""
var _plan_override: Variant = null  # a Vector2 to plan around instead of the focus (prefill_at)
# Whether rest stop `site` is lit (RestStops.is_lit), for its marker's colour. Unset: none are.
var rest_lit_query := Callable()
# The coin still lying at a site (LootDirector.loot_at → {"kind": "coin", ...} or {}). Unset: none.
var loot_query := Callable()
# A decaying peak of the cost of one unit in the sample-at-a-time stages (heights, arrays,
# plant), so the stop rule allows for the dear ones rather than the average.
var _peak_us := {"heights": 40.0, "arrays": 10.0, "plant": 40.0}
const PEAK_DECAY := 0.995

var _chunks := {}  # Vector2i -> ChunkState
var _queue: Array[ChunkJob] = []
var _est := {}  # atomic stage -> moving average of its cost, µs
var _indices := {}  # verts per side -> PackedInt32Array, grid plus skirts
var _plan_coord := Vector2i(1 << 30, 0)
var _plan_timer := 0.0
var _ran_this_frame := false
# The stage's fake sun and hemisphere ambient (GameConfig's Lighting group, the same values
# TerrainManager bakes into a stage's vertex colours via apply_terrain_light), read once when the
# streamer is made so every chunk of a session is baked under the same light.
var _sun: Vector3 = Config.data.sun_direction.normalized()
var _sun_color: Color = Config.data.sun_color
var _sky_color: Color = Config.data.sky_color
var _ground_color: Color = Config.data.ground_color
var _light_amount: float = Config.data.terrain_light_amount
var _forest: FastNoiseLite
var _ring_looks: Array[Dictionary] = []
var _ring_materials: Array[Material] = []
# Entry k - 1 is the ground for chunks on the border between rings k - 1 and k, fading one into
# the other per pixel.
var _pair_materials: Array[Material] = []


class ChunkState:
	var far_mesh: MeshInstance3D
	var near_mesh: MeshInstance3D
	var body: StaticBody3D
	var foliage: Node3D  # trees, bushes and rocks, which live and die with the near mesh
	var near_heights := PackedFloat32Array()  # halo grid kept for collision and height queries
	var far_heights := PackedFloat32Array()
	var near_road_d := PackedFloat32Array()  # distance to the road at each near vertex
	# The road segments that can be nearest anywhere in the chunk, gathered once and shared by
	# its far and near builds.
	var cands := PackedInt32Array()
	var has_cands := false
	var far_job: ChunkJob
	var near_job: ChunkJob
	var col_job: ChunkJob
	var plant_job: ChunkJob  # a near build back in the queue to plant, after its collision


class ChunkJob:
	var coord: Vector2i
	var near := false
	var with_collision := false
	var stride := 8.0
	var n := 9  # vertices per side
	var stage := Stage.PREP
	var cursor := 0
	var priority := 0.0
	var dist := 0.0  # distance from the car, in chunks, at the last plan
	var cancelled := false
	var cands := PackedInt32Array()
	# Near chunks sample a one-sample border so edge normals match their neighbours; far chunks
	# skip it and take one-sided slopes at their edges, which fog hides.
	var halo := 0
	var ring_lo := INF  # the lowest and highest RoadTerrain.ring_coord over the chunk's vertices
	var ring_hi := -INF
	var heights := PackedFloat32Array()  # (n + 2·halo)²
	var road_d := PackedFloat32Array()   # n²
	var road_info := PackedFloat32Array()  # 3·n²: signed distance, arc length, marking weight
	var verts := PackedVector3Array()
	var colors := PackedColorArray()
	var uvs := PackedVector2Array()
	var uv2s := PackedVector2Array()  # x = tarmac weight (the ground shader's UV2.x)
	var mesh: ArrayMesh
	var plants := false  # a near build also plants the chunk's trees, bushes and rocks
	var plant_pts := PackedVector2Array()
	var plant_kind := PackedInt32Array()
	var kept := [PackedVector2Array(), PackedVector2Array(), PackedVector2Array()]  # by Plant
	var spawns: Array[Callable] = []
	var spawn_kinds := PackedStringArray()  # each spawn's cost-estimate key (see _spawn_kind)
	var ground: PlantGround  # what the planting stands on (made when PLANT starts)


# The ground a chunk's planting stands on, handed to Foliage / BarrierField / Crowd in place of
# the streamer. Inside its own chunk it reads the chunk's own near grid (exactly the drawn
# surface). Outside it (spots near the +x/+z edge spill into the neighbour, rock outcrops and rest
# crowds spill either way) it uses the exact terrain height, never the neighbour's loaded mesh:
# that is whatever LOD happens to be there (often the 16 m far mesh, or nothing), so foliage
# floated or sank when the near mesh arrived (metres; tens of metres on a mountainside), and the
# water check depended on load order.
# Exact heights are cached per spot, so the PLANT stage's checks pay for them and the spawns reuse
# them.
class PlantGround:
	extends RefCounted
	var streamer: TerrainStreamer
	var coord: Vector2i
	var heights := PackedFloat32Array()  # the planting chunk's near grid (with its halo)
	var exact := {}  # Vector2 -> exact height, for points outside the chunk

	func height_at(x: float, z: float) -> float:
		return streamer.plant_height(self, x, z)

	func light_at(x: float, z: float) -> Color:
		return streamer._light_with(height_at, x, z)


func _ready() -> void:
	if settings == null:
		settings = FreeRoamSettings.new()
	var t0 := Time.get_ticks_msec()
	terrain.setup(settings, network)
	network.build(settings, terrain)
	sites.build(settings, network, terrain)
	terrain.sites = sites
	if Config.data.barriers_enabled:
		barriers.plan(settings, network, terrain, sites, barrier_params())
	stat_build_ms = Time.get_ticks_msec() - t0
	_forest = TreeScatter.make_forest_noise(settings.world_seed, Config.data.forest_wavelength_m)
	# Biome ring i wears region ring_regions[i]: its trees and rocks, and a ground material
	# carrying its grass / gravel textures and tarmac colour.
	for i in settings.ring_count:
		var look := RegionLibrary.look_of(BiomeDirector.region_of(settings, i))
		_ring_looks.append(look)
		_ring_materials.append(_material_for(look))
	for k in range(1, settings.ring_count):
		var pair := _pair_material(k)
		if pair != null:
			_pair_materials.append(pair)
	print("free roam: network %d nodes, %d links, %.0f km of road, %d rest stops, %d loot slots, %d dead ends, built in %d ms" % [
		network.node_x.size(), network.edges.size(), network.total_length_m / 1000.0,
		sites.of_kind(RoadSites.Kind.REST).size(), sites.of_kind(RoadSites.Kind.LOOT).size(),
		sites.of_kind(RoadSites.Kind.DEAD_END).size(), stat_build_ms])
	print("free roam: %d barrier modules" % barriers.modules.size())


func _material_for(look: Dictionary) -> Material:
	var sm := material as ShaderMaterial
	if sm == null:
		return material
	var m := sm.duplicate() as ShaderMaterial
	if look.has("grass_texture"):
		m.set_shader_parameter("albedo_texture", load(look["grass_texture"]))
	if look.has("gravel_texture"):
		m.set_shader_parameter("road_texture", load(look["gravel_texture"]))
	if look.has("tarmac_color"):
		m.set_shader_parameter("tarmac_color", look["tarmac_color"])
	# The road is painted per pixel from the distances _arrays bakes (see the comment there).
	m.set_shader_parameter("paint_road_per_pixel", true)
	m.set_shader_parameter("ground_uv_per_m", UV_PER_M)
	m.set_shader_parameter("road_paint_mid_m", terrain.paint_mid_m())
	m.set_shader_parameter("road_paint_half_m", terrain.paint_half_m())
	# Lane paint on tarmac, sized like the stage's RoadMarkings. A region whose look omits
	# road_marking_color still gets the default colour; its roads are gravel anyway, and the
	# shader only paints lines where the road is tarmac.
	var cfg := Config.data
	m.set_shader_parameter("road_marking_strength", 1.0 if cfg.road_markings_enabled else 0.0)
	m.set_shader_parameter("road_marking_color", look.get("road_marking_color", cfg.road_marking_color))
	m.set_shader_parameter("road_marking_width_m", cfg.road_marking_width_m)
	m.set_shader_parameter("road_marking_edge_m", settings.road_half_width_m - cfg.road_marking_edge_inset_m)
	m.set_shader_parameter("road_marking_dash_m", cfg.road_marking_center_dash_m)
	m.set_shader_parameter("road_marking_gap_m", cfg.road_marking_center_gap_m)
	return m


# Ring k - 1's ground with ring k's textures and colours in the shader's B slot.
func _pair_material(k: int) -> ShaderMaterial:
	var outer := _ring_materials[k] as ShaderMaterial
	if outer == null:
		return null
	var m := _ring_materials[k - 1].duplicate() as ShaderMaterial
	for p in ["albedo_texture", "road_texture", "tarmac_color", "road_marking_color"]:
		m.set_shader_parameter(p + "_b", outer.get_shader_parameter(p))
	m.set_shader_parameter("albedo_color_b", m.get_shader_parameter("albedo_color"))
	m.set_shader_parameter("fade_rings", true)
	m.set_shader_parameter("ring_border", float(k))
	m.set_shader_parameter("ring_half", _fade_half())
	m.set_shader_parameter("ring_scale_m", settings.inner_radius_m())
	m.set_shader_parameter("ring_count", float(settings.ring_count))
	m.set_shader_parameter("ring_seed", settings.world_seed + 3)
	return m


# Half the biome fade's width, in rings (RoadTerrain.ring_coord's units).
func _fade_half() -> float:
	return settings.biome_fade_m / settings.inner_radius_m() * settings.ring_count * 0.5


# Every ground material, single-ring and border (the BiomeDirector tints them for the weather).
func ring_materials() -> Array[ShaderMaterial]:
	var out: Array[ShaderMaterial] = []
	for m in _ring_materials + _pair_materials:
		if m is ShaderMaterial:
			out.append(m)
	return out


# The vertex tint baked under a point: its ring's region `terrain_tint`, white when it has none
# (the stage's default), so the region's own textures show true. Faded like the textures at a border.
func ring_tint_at(p: Vector2) -> Color:
	return _tint_at_ring(terrain.ring_coord(p.x, p.y))


func _tint_at_ring(v: float) -> Color:
	if _ring_looks.is_empty():
		return Color.WHITE
	var n := _ring_looks.size()
	var inside: Color = _ring_looks[clampi(floori(v), 0, n - 1)].get("terrain_tint", Color.WHITE)
	var k := roundi(v)
	var h := _fade_half()
	if k < 1 or k > n - 1 or absf(v - k) >= h:
		return inside
	var a: Color = _ring_looks[k - 1].get("terrain_tint", Color.WHITE)
	var b: Color = _ring_looks[k].get("terrain_tint", Color.WHITE)
	return a.lerp(b, smoothstep(-h, h, v - k))


# The ground a built chunk wears: the border material when the fade reaches into it, else its ring's.
func _ground_material(job: ChunkJob) -> Material:
	if _ring_materials.is_empty():
		return material
	var k := roundi((job.ring_lo + job.ring_hi) * 0.5)
	var h := _fade_half()
	if k >= 1 and k - 1 < _pair_materials.size() and job.ring_lo < k + h and job.ring_hi > k - h:
		return _pair_materials[k - 1]
	return _ring_materials[clampi(floori((job.ring_lo + job.ring_hi) * 0.5), 0, _ring_materials.size() - 1)]


func ring_material_at(coord: Vector2i) -> Material:
	if _ring_materials.is_empty():
		return material
	var cm := settings.chunk_m
	return _ring_materials[terrain.ring_index((coord.x + 0.5) * cm, (coord.y + 0.5) * cm)]


# --- what the car asks of its terrain ------------------------------------------------------

# Answered from the loaded chunk under the point when there is one: cheap, and exactly the
# surface that is drawn. Only falls back to the full terrain maths where nothing is loaded.
func height_at(x: float, z: float) -> float:
	var coord := _chunk_of(Vector2(x, z))
	var st: ChunkState = _chunks.get(coord)
	if st != null:
		if not st.near_heights.is_empty():
			return _mesh_height(st.near_heights, settings.near_stride_m, 1, coord, x, z)
		if not st.far_heights.is_empty():
			return _mesh_height(st.far_heights, settings.far_stride_m, 0, coord, x, z)
	return terrain.height(x, z, PackedInt32Array(), false)


# Height on a chunk's grid, interpolated across the same two triangles per cell the mesh uses.
func _mesh_height(heights: PackedFloat32Array, stride: float, halo: int, coord: Vector2i, x: float, z: float) -> float:
	var n := int(settings.chunk_m / stride) + 1
	var m := n + 2 * halo
	var lx := (x - coord.x * settings.chunk_m) / stride
	var lz := (z - coord.y * settings.chunk_m) / stride
	var gx := clampi(floori(lx), 0, n - 2)
	var gz := clampi(floori(lz), 0, n - 2)
	var u := clampf(lx - gx, 0.0, 1.0)
	var v := clampf(lz - gz, 0.0, 1.0)
	var i := (gz + halo) * m + gx + halo
	var ha := heights[i]
	var hb := heights[i + 1]
	var hc := heights[i + m]
	if u + v <= 1.0:
		return ha + (hb - ha) * u + (hc - ha) * v
	var hd := heights[i + m + 1]
	return hd + (hc - hd) * (1.0 - u) + (hb - hd) * (1.0 - v)


# Like height_at, answered from the loaded near chunk when there is one: the distance to the road
# was already worked out at every vertex while building it.
func surface_at(x: float, z: float) -> Vector2:
	var coord := _chunk_of(Vector2(x, z))
	var st: ChunkState = _chunks.get(coord)
	var road: float
	if st != null and not st.near_road_d.is_empty():
		road = terrain.road_weight(_mesh_height(st.near_road_d, settings.near_stride_m, 0, coord, x, z))
	else:
		terrain.height(x, z, PackedInt32Array(), false)
		road = terrain.road_weight(terrain.last_road_d)
	return Vector2(road, terrain.tarmac_weight(x, z) if road > 0.0 else 0.0)


# --- scheduling ----------------------------------------------------------------------------

func budget_us(frame_s: float) -> int:
	return maxi(int(frame_s * 1e6 * settings.budget_min_fraction), int(spare_us * settings.budget_fraction))


func _process(delta: float) -> void:
	if focus == null:
		return
	_plan_timer -= delta
	var cc := _chunk_of(_focus_xz())
	if cc != _plan_coord or _plan_timer <= 0.0:
		_plan()
	var budget := budget_us(delta)
	var start := Time.get_ticks_usec()
	_guard_collision()
	_run_queue(start + budget)
	var used := Time.get_ticks_usec() - start
	stat_used_us = used
	stat_total_us += used
	stat_frames += 1
	stat_worst_us = maxi(stat_worst_us, used)
	if used > budget:
		stat_overruns += 1
		stat_overshoot_us += used - budget
		stat_overrun_by[_last_kind] = int(stat_overrun_by.get(_last_kind, 0)) + 1
		if used > budget * 1.5:
			stat_spikes += 1
			stat_spike_by[_last_kind] = int(stat_spike_by.get(_last_kind, 0)) + 1


# Build everything the planner wants with no budget: used once at boot, behind the spawn.
func prefill() -> void:
	_plan()
	var start := Time.get_ticks_usec()
	_run_queue(start + 60_000_000)


# Prefill around a point the car is about to be moved to (a respawn or a rest-stop travel), so it
# lands on built ground with collision. The plan is made as if the car were already there and
# standing still.
func prefill_at(p: Vector2) -> void:
	_plan_override = p
	_plan()
	_run_queue(Time.get_ticks_usec() + 60_000_000)
	_plan_override = null


# Draw a speck of every ring's ground material in front of `camera` for a few frames, so each
# one's shader pipeline is compiled behind the boot load rather than in the first frame a new
# biome's chunk appears (a GPU stall the frame budget can't see).
func warm_up_materials(camera: Camera3D, frames := 3) -> void:
	if camera == null:
		return
	var specks: Array[MeshInstance3D] = []
	for m in _ring_materials + _pair_materials:
		var quad := QuadMesh.new()
		quad.size = Vector2(0.01, 0.01)
		var mi := MeshInstance3D.new()
		mi.mesh = quad
		mi.material_override = m
		camera.add_child(mi)
		mi.position = Vector3(0.0, 0.0, -0.5)
		specks.append(mi)
	for i in frames:
		await get_tree().process_frame
	for mi in specks:
		if is_instance_valid(mi):
			mi.queue_free()


# Draw one of every plant, rock, site marker and coin any ring can show, a few metres in front of
# `camera`, for a few frames: their shaders compile and textures upload now, behind the boot,
# rather than on the first chunk that holds one.
func warm_up_spawns(camera: Camera3D, frames := 3) -> void:
	if camera == null:
		return
	var cfg: GameConfig = Config.data
	var dist := cfg.tree_render_distance_m
	var fade := cfg.tree_render_fade_m
	var root := Node3D.new()
	root.name = "SpawnWarmUp"
	add_child(root)
	var ahead := camera.global_transform * Vector3(0.0, -1.5, -8.0)
	var g := FlatGround.new()
	g.y = ahead.y
	var at := PackedVector2Array([Vector2(ahead.x, ahead.z)])
	for look in _ring_looks:
		for entry in RegionLibrary.tree_mix(look):
			Foliage.spawn_trees(root, at, g, false, dist, fade, load(entry["texture"]),
				String(entry.get("profile", "home")) == "region", entry.get("size_scale", Vector2.ONE))
	Foliage.spawn_bushes(root, at, g, dist, fade)
	for i in Foliage.ROCK_SCENES.size():
		Foliage.spawn_rocks(root, at, g, i, false, dist, fade)
	var cabin := _site_marker(0)
	cabin.get_node("Body").free()  # only its look needs warming, not a wall in front of the car
	for marker: Node3D in [_coin_marker(0), cabin]:
		root.add_child(marker)
		marker.global_position = ahead
	for i in frames:
		await get_tree().process_frame
	root.queue_free()


# Level ground for warm_up_spawns: the spawners only ask for a height and a light.
class FlatGround:
	extends RefCounted
	var y := 0.0

	func height_at(_x: float, _z: float) -> float:
		return y

	func light_at(_x: float, _z: float) -> Color:
		return Color.WHITE


func queued() -> int:
	return _queue.size()


func chunk_counts() -> Vector3i:
	var c := Vector3i.ZERO
	for st: ChunkState in _chunks.values():
		c.x += int(st.near_mesh != null)
		c.y += int(st.far_mesh != null)
		c.z += int(st.body != null)
	return c


func has_collision_at(x: float, z: float) -> bool:
	var st: ChunkState = _chunks.get(_chunk_of(Vector2(x, z)))
	return st != null and st.body != null


func _run_queue(deadline: int) -> void:
	_ran_this_frame = false
	while not _queue.is_empty():
		var job := _queue[0]
		if job.cancelled or job.stage == Stage.DONE:
			_queue.pop_front()
			continue
		# A near build stops once its mesh and collision are in: its trees, bushes and rocks go
		# back in the queue behind every other chunk's collision and mesh. Running straight on
		# into the planting kept the next chunk's collision waiting behind this chunk's
		# foliage, which is how a fast car outran its collision and fell through the world.
		var planting := job.stage > Stage.COLLIDE
		if not _step(job, deadline, Stage.DONE if planting else Stage.PLANT):
			return
		if job.stage == Stage.DONE:
			_queue.pop_front()
		elif not planting and job.stage > Stage.COLLIDE:
			_queue.pop_front()
			_to_planting(job)
			_enqueue_sorted(job)
		if Time.get_ticks_usec() >= deadline:
			return


# Queue order, lowest first (d = distance from the car in chunks, at most far_radius + 0.5):
#   collision        d - 2000   (d - 3000 when rushed)
#   near + collision d - 1000
#   near mesh        d - 100
#   planting         d - 50                           (PLANT_PRIORITY)
#   far mesh, hole   d - 50 - far_lead_chunks         (no near mesh or near build: a gap in the horizon)
#   far mesh, hidden d                                (under a near mesh, or one on its way)
# So foliage never runs ahead of a collision or near-mesh build, but a far mesh that would fill a
# visible gap is interleaved with planting by distance: planting a chunk d away waits for horizon
# holes nearer than d + far_lead_chunks. Before, planting (d - 50) always beat far meshes (d), so
# at speed far jobs never ran and the horizon had gaps. A hole is never nearer than the near ring's
# edge, so with far_lead_chunks under 50 it stays behind every near-mesh build.
const PLANT_PRIORITY := -50.0


func _far_priority(st: ChunkState, d: float) -> float:
	if st.near_mesh != null or st.near_job != null:
		return d
	return d + PLANT_PRIORITY - settings.far_lead_chunks


func _to_planting(job: ChunkJob) -> void:
	job.priority = job.dist + PLANT_PRIORITY
	var st: ChunkState = _chunks.get(job.coord)
	if st != null:
		st.plant_job = job


func _enqueue_sorted(job: ChunkJob) -> void:
	var i := _queue.bsearch_custom(job, func(a: ChunkJob, b: ChunkJob) -> bool: return a.priority < b.priority, false)
	_queue.insert(i, job)


# The safety net under the car: if the chunk under it, or the one it will be over in
# `collision_rush_s`, has no collision yet, build that collision now, whatever the budget. The
# planner and the queue order are meant to keep this from ever firing; when the car outruns
# them anyway (a very fast car, a teleport, a stall), a one-off hitch beats a fall through the
# world.
func _guard_collision() -> void:
	if focus == null or _plan_override != null:
		return
	var here := _focus_xz()
	_rush_collision(_chunk_of(here))
	if focus is RigidBody3D:
		var v := (focus as RigidBody3D).linear_velocity
		_rush_collision(_chunk_of(here + Vector2(v.x, v.z) * settings.collision_rush_s))


# Build `coord`'s collision at once, with no budget, and only as far as the collision: its
# foliage is left to the queue. Returns true when it had to.
func _rush_collision(coord: Vector2i) -> bool:
	var st: ChunkState = _chunks.get(coord)
	if st == null:
		st = ChunkState.new()
		_chunks[coord] = st
	if st.body != null:
		return false
	var job: ChunkJob
	if st.near_mesh != null:
		if st.col_job == null:
			st.col_job = _new_job(coord, true, true)
			st.col_job.stage = Stage.COLLIDE
			st.col_job.plants = false
		job = st.col_job
	else:
		if st.near_job == null:
			st.near_job = _new_job(coord, true, true)
		job = st.near_job
		job.with_collision = true
	job.priority = -3000.0
	stat_rushes += 1
	var saved := _ran_this_frame
	_ran_this_frame = false
	_step(job, Time.get_ticks_usec() + 60_000_000, Stage.PLANT)
	_ran_this_frame = saved
	if job.stage > Stage.COLLIDE and job.stage != Stage.DONE:
		_to_planting(job)
	_queue.sort_custom(func(a: ChunkJob, b: ChunkJob) -> bool: return a.priority < b.priority)
	return true


# Advance a job by as many units as fit before `deadline`, stopping at stage `stop_at`. Returns
# false when the next unit could not be started this frame.
func _step(job: ChunkJob, deadline: int, stop_at := Stage.DONE) -> bool:
	while job.stage != Stage.DONE and job.stage < stop_at:
		match job.stage:
			Stage.PREP:
				if not _atomic("prep", deadline, _prep.bind(job)):
					return false
			# A sample-at-a-time stage that stops short has run out of frame: report it, so the
			# queue stops too (returning true here spun the queue until the deadline).
			Stage.HEIGHTS:
				if not _heights(job, deadline):
					return false
			Stage.ARRAYS:
				if not _arrays(job, deadline):
					return false
			Stage.UPLOAD:
				if not _atomic("upload_%d" % job.n, deadline, _upload.bind(job)):
					return false
			Stage.ATTACH:
				if not _atomic("attach", deadline, _attach.bind(job)):
					return false
			Stage.COLLIDE:
				if not _atomic("collide", deadline, _collide.bind(job)):
					return false
			Stage.PLANT:
				if not _plant(job, deadline):
					return false
			Stage.SPAWN:
				var sk := job.spawn_kinds[job.cursor] if job.cursor < job.spawn_kinds.size() else "spawn"
				if not _atomic(sk, deadline, _spawn_next.bind(job)):
					return false
	return true


# Run one indivisible unit if its measured cost fits in what is left of the frame. The first
# unit of a frame always runs, so a unit dearer than the whole budget still makes progress
# (and shows up as an overrun rather than stalling the world).
func _atomic(kind: String, deadline: int, work: Callable) -> bool:
	var now := Time.get_ticks_usec()
	var est: float = _est.get(kind, 300.0)
	if _ran_this_frame and now + est > deadline:
		return false
	_last_kind = kind
	work.call()
	_est[kind] = lerpf(est, float(Time.get_ticks_usec() - now), 0.25)
	_ran_this_frame = true
	return true


func _prep(job: ChunkJob) -> void:
	var cm := settings.chunk_m
	job.halo = 1 if job.near else 0
	var m := job.n + 2 * job.halo
	job.heights.resize(m * m)
	job.road_d.resize(job.n * job.n)
	job.road_info.resize(3 * job.n * job.n)
	job.cursor = 0
	job.stage = Stage.HEIGHTS
	job.ring_lo = INF
	job.ring_hi = -INF
	# A chunk wholly beyond the furthest possible coastline is open sea: no sampling needed.
	var nx := clampf(0.0, job.coord.x * cm - job.stride, (job.coord.x + 1) * cm + job.stride)
	var ny := clampf(0.0, job.coord.y * cm - job.stride, (job.coord.y + 1) * cm + job.stride)
	if LabNoise.hyp(nx, ny) >= settings.island_radius_m:
		job.heights.fill(terrain.sea_floor())
		job.road_d.fill(INF)
		job.road_info.fill(0.0)
		for i in job.n * job.n:
			job.road_info[3 * i] = 1.0e4
		_start_arrays(job)
		return
	job.cands = _cands_of(job.coord)


# The road segments that can be nearest anywhere in chunk `coord`, gathered once and kept on its
# state when it has one. The margin covers the wider of the two strides, so one list serves both
# builds. Depends on nothing but the coord, so a query that uses it answers the same whatever is
# loaded.
func _cands_of(coord: Vector2i) -> PackedInt32Array:
	var st: ChunkState = _chunks.get(coord)
	if st != null and st.has_cands:
		return st.cands
	var cm := settings.chunk_m
	var half := cm * 0.5 + maxf(settings.near_stride_m, settings.far_stride_m)
	var cands := network.candidates_for((coord.x + 0.5) * cm, (coord.y + 0.5) * cm, half * sqrt(2.0), settings.mountain_dist_m)
	if st != null:
		st.cands = cands
		st.has_cands = true
	return cands


func _heights(job: ChunkJob, deadline: int) -> bool:
	var m := job.n + 2 * job.halo
	var total := m * m
	var ox := job.coord.x * settings.chunk_m
	var oy := job.coord.y * settings.chunk_m
	var t0 := Time.get_ticks_usec()
	var done := 0
	_last_kind = "heights"
	var peak: float = _peak_us["heights"]
	var t_prev := t0
	while job.cursor < total:
		# Never start a sample that would not fit, judged by the dearest recent sample.
		if (_ran_this_frame or done > 0) and t_prev + peak >= deadline:
			break
		var gx := job.cursor % m - job.halo
		@warning_ignore("integer_division")
		var gz := job.cursor / m - job.halo
		job.heights[job.cursor] = terrain.height(ox + gx * job.stride, oy + gz * job.stride, job.cands, true)
		if gx >= 0 and gz >= 0 and gx < job.n and gz < job.n:
			var vi := gz * job.n + gx
			job.road_d[vi] = minf(terrain.last_road_d, 1.0e4)  # finite, so it interpolates
			job.road_info[3 * vi] = clampf(terrain.last_road_sd, -1.0e4, 1.0e4)
			job.road_info[3 * vi + 1] = terrain.last_road_s
			job.road_info[3 * vi + 2] = terrain.last_road_mark
		job.cursor += 1
		done += 1
		var t_now := Time.get_ticks_usec()
		peak = maxf(float(t_now - t_prev), peak * PEAK_DECAY)
		t_prev = t_now
	_peak_us["heights"] = peak
	_ran_this_frame = _ran_this_frame or done > 0
	if done > 0:
		stat_us_per_sample = lerpf(stat_us_per_sample, float(Time.get_ticks_usec() - t0) / done, 0.1)
	if job.cursor < total:
		return false
	_start_arrays(job)
	return true


func _start_arrays(job: ChunkJob) -> void:
	job.cursor = 0
	var count := job.n * job.n + 4 * (job.n - 1)
	job.verts.resize(count)
	job.colors.resize(count)
	job.uvs.resize(count)
	job.uv2s = PackedVector2Array()
	job.uv2s.resize(count)
	job.stage = Stage.ARRAYS


func _arrays(job: ChunkJob, deadline: int) -> bool:
	var n := job.n
	var hl := job.halo
	var m := n + 2 * hl
	var lo := -hl
	var top := n - 1 + hl
	var s := job.stride
	var ox := job.coord.x * settings.chunk_m
	var oy := job.coord.y * settings.chunk_m
	var done := 0
	# how far the interpolated unsigned distance can overshoot the true one across a centreline
	var road_slack := 0.75 * s
	# a vertex within one triangle of painted road carries the tarmac weight the pixels blend with
	var paint_reach := terrain.paint_mid_m() + terrain.paint_half_m() + s
	_last_kind = "arrays"
	var peak: float = _peak_us["arrays"]
	var t_prev := Time.get_ticks_usec()
	while job.cursor < n * n:
		if done % CHECK_EVERY == 0:
			var t_now := Time.get_ticks_usec()
			if done > 0:
				peak = maxf(float(t_now - t_prev), peak * PEAK_DECAY)
			t_prev = t_now
			if (_ran_this_frame or done > 0) and t_now + peak >= deadline:
				break
		var i := job.cursor
		var gx := i % n
		@warning_ignore("integer_division")
		var gz := i / n
		var row := (gz + hl) * m
		var h := job.heights[row + gx + hl]
		# central differences, falling back to one-sided at an edge with no border sample
		var xl := maxi(gx - 1, lo)
		var xr := mini(gx + 1, top)
		var zd := maxi(gz - 1, lo)
		var zu := mini(gz + 1, top)
		var dhx := (job.heights[row + xr + hl] - job.heights[row + xl + hl]) / ((xr - xl) * s)
		var dhz := (job.heights[(zu + hl) * m + gx + hl] - job.heights[(zd + hl) * m + gx + hl]) / ((zu - zd) * s)
		var normal := Vector3(-dhx, 1.0, -dhz).normalized()
		var px := ox + gx * s
		var pz := oy + gz * s
		var ring := terrain.ring_coord(px, pz)
		job.ring_lo = minf(job.ring_lo, ring)
		job.ring_hi = maxf(job.ring_hi, ring)
		var col := _tint_at_ring(ring) * ground_light(normal)
		# The ground shader paints the road per pixel (ps1_models.gdshader, paint_road_per_pixel)
		# from what the vertices carry here, never from a per-vertex weight, so the road's edge
		# stays smooth however coarse the mesh. The ground texture is placed from the world
		# position in that mode, which frees UV to carry the distances:
		#   UV.x   distance to the road, signed by side. It is linear across the centreline, so it
		#          interpolates exactly over a triangle that straddles the road;
		#   UV.y   unsigned distance less road_slack. Where the side flips between two roads (in a
		#          junction, or midway between parallel roads) UV.x interpolates through a false
		#          zero and UV.y does not; the shader takes max(|UV.x|, UV.y). road_slack covers
		#          how far UV.y overshoots across a real centreline, so there it never wins;
		#   UV2    x tarmac weight, y arc length along the road (dashes);
		#   COLOR.a  lane-marking weight (0 on rest-stop pads and in junctions).
		col.a = job.road_info[3 * i + 2]
		var tarmac := 0.0
		if job.road_d[i] < paint_reach:
			tarmac = terrain.tarmac_weight(px, pz)
		job.uv2s[i] = Vector2(tarmac, job.road_info[3 * i + 1])
		job.verts[i] = Vector3(gx * s, h, gz * s)
		job.colors[i] = col
		job.uvs[i] = Vector2(job.road_info[3 * i], job.road_d[i] - road_slack)
		job.cursor += 1
		done += 1
	_peak_us["arrays"] = peak
	_ran_this_frame = _ran_this_frame or done > 0
	if job.cursor < n * n:
		return false
	# Skirts: a strip hanging below the edge, so neighbouring chunks at different detail never
	# show a crack between them.
	var drop := 3.0 if job.near else 12.0
	var perim := _perimeter(n)
	for k in perim.size():
		var src := perim[k]
		job.verts[n * n + k] = job.verts[src] - Vector3(0.0, drop, 0.0)
		job.colors[n * n + k] = job.colors[src]
		job.uvs[n * n + k] = job.uvs[src]
		job.uv2s[n * n + k] = job.uv2s[src]
	job.stage = Stage.UPLOAD
	return true


func _upload(job: ChunkJob) -> void:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = job.verts
	arrays[Mesh.ARRAY_COLOR] = job.colors
	arrays[Mesh.ARRAY_TEX_UV] = job.uvs
	arrays[Mesh.ARRAY_TEX_UV2] = job.uv2s
	arrays[Mesh.ARRAY_INDEX] = _indices_for(job.n)
	job.mesh = ArrayMesh.new()
	job.mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	job.stage = Stage.ATTACH


func _attach(job: ChunkJob) -> void:
	var st: ChunkState = _chunks.get(job.coord)
	if st == null:
		job.stage = Stage.DONE
		return
	var mi := MeshInstance3D.new()
	mi.mesh = job.mesh
	mi.material_override = _ground_material(job)
	mi.position = Vector3(job.coord.x * settings.chunk_m, 0.0, job.coord.y * settings.chunk_m)
	add_child(mi)
	if job.near:
		st.near_mesh = mi
		st.near_heights = job.heights
		st.near_road_d = job.road_d
		st.near_job = null
		if st.far_mesh != null:
			st.far_mesh.visible = false
	else:
		st.far_mesh = mi
		st.far_heights = job.heights
		st.far_job = null
		mi.visible = st.near_mesh == null
	job.verts = PackedVector3Array(); job.colors = PackedColorArray(); job.uvs = PackedVector2Array()
	job.uv2s = PackedVector2Array()
	job.stage = Stage.COLLIDE if job.with_collision else _after_collide(job)


func _after_collide(job: ChunkJob) -> Stage:
	if not job.plants:
		return Stage.DONE
	job.cursor = -1
	return Stage.PLANT


func _collide(job: ChunkJob) -> void:
	var st: ChunkState = _chunks.get(job.coord)
	job.stage = _after_collide(job)
	if st == null or st.body != null or st.near_heights.is_empty():
		if st != null:
			st.col_job = null
		return
	var n := int(settings.chunk_m / settings.near_stride_m) + 1
	var m := n + 2
	var data := PackedFloat32Array()
	data.resize(n * n)
	for gz in n:
		for gx in n:
			data[gz * n + gx] = st.near_heights[(gz + 1) * m + gx + 1]
	var shape := HeightMapShape3D.new()
	shape.map_width = n
	shape.map_depth = n
	shape.map_data = data
	var cs := CollisionShape3D.new()
	cs.shape = shape
	# HeightMapShape3D has unit cells, so the shape is scaled to the vertex spacing.
	cs.scale = Vector3(settings.near_stride_m, 1.0, settings.near_stride_m)
	var body := StaticBody3D.new()
	var half := settings.chunk_m * 0.5
	body.position = Vector3(job.coord.x * settings.chunk_m + half, 0.0, job.coord.y * settings.chunk_m + half)
	body.add_child(cs)
	add_child(body)
	st.body = body
	st.col_job = null


# The baked light on ground with unit normal `n`: the stage terrain's fake shading (hemisphere
# ambient + one low sun aligned with the skybox, TerrainManager.light_for_normal) under the
# GameConfig light. Baked into every chunk vertex during the ARRAYS stage, so it costs nothing
# per frame; slopes facing the sun read bright and slopes facing away dark, as on a stage.
func ground_light(n: Vector3) -> Color:
	if _light_amount <= 0.0:
		return Color.WHITE
	return TerrainManager.light_for_normal(n, _sun, _sun_color, _sky_color, _ground_color, _light_amount)


# Baked ground light for foliage that wants to match the ground it stands on (the bushes):
# the same tint-times-light shading the chunk vertices get.
func light_at(x: float, z: float) -> Color:
	return _light_with(height_at, x, z)


func _light_with(h: Callable, x: float, z: float) -> Color:
	var n := Vector3(h.call(x - 1.0, z) - h.call(x + 1.0, z), 2.0, h.call(x, z - 1.0) - h.call(x, z + 1.0)).normalized()
	var c := ring_tint_at(Vector2(x, z)) * ground_light(n)
	c.a = 1.0
	return c


# The height planting uses at a point (PlantGround): the planting chunk's own near grid inside it,
# the exact terrain height (cached) outside it. Never depends on what else is loaded, so a chunk
# plants the same spots at the same heights whatever order its neighbours streamed in.
func plant_height(g: PlantGround, x: float, z: float) -> float:
	var cm := settings.chunk_m
	var lx := x - g.coord.x * cm
	var lz := z - g.coord.y * cm
	if lx >= 0.0 and lz >= 0.0 and lx <= cm and lz <= cm and not g.heights.is_empty():
		return _mesh_height(g.heights, settings.near_stride_m, 1, g.coord, x, z)
	var key := Vector2(x, z)
	var h: Variant = g.exact.get(key)
	if h == null:
		h = terrain.height(x, z, _cands_of(_chunk_of(key)), true)
		g.exact[key] = h
	return h


func _ground_for(coord: Vector2i, st: ChunkState) -> PlantGround:
	var g := PlantGround.new()
	g.streamer = self
	g.coord = coord
	g.heights = st.near_heights
	return g


# --- planting: trees, bushes and rocks for a near chunk ---------------------------------------
#
# Spots come from a jittered grid in WORLD space (each cell belongs to whichever chunk holds its
# corner), so a chunk always plants the same things in the same places. The PLANT stage checks
# each spot against water and the road a few at a time; SPAWN then builds one foliage field per
# species, each as its own unit of work.

func _plant(job: ChunkJob, deadline: int) -> bool:
	var st: ChunkState = _chunks.get(job.coord)
	if st == null:
		job.stage = Stage.DONE
		return true
	if job.cursor < 0:
		job.ground = _ground_for(job.coord, st)
		_plant_candidates(job)
		job.cursor = 0
	var cfg: GameConfig = Config.data
	var water := settings.water_level_m
	var road := settings.road_half_width_m + cfg.tree_road_margin_m
	var radius := [0.5, TreeMeshField.xz_radius(Foliage.bush_mesh(), cfg.bush_height_m), _widest_rock()]
	var done := 0
	_last_kind = "plant"
	var peak: float = _peak_us["plant"]
	var t_prev := Time.get_ticks_usec()
	while job.cursor < job.plant_pts.size():
		if (_ran_this_frame or done > 0) and t_prev + peak >= deadline:
			break
		var p := job.plant_pts[job.cursor]
		var kind := job.plant_kind[job.cursor]
		job.cursor += 1
		done += 1
		if _spot_is_clear(job.ground, p, water, road + radius[kind]) and _roadside_keep(p, kind, road + radius[kind]):
			var kept: PackedVector2Array = job.kept[kind]  # a copy: packed arrays are values
			kept.append(p)
			job.kept[kind] = kept
			if kind == Plant.BUSH:
				# A bush's baked light samples the ground a metre round it: pay for any exact
				# heights that needs here, a spot at a time, not inside the atomic bush spawn.
				job.ground.light_at(p.x, p.y)
		var t_now := Time.get_ticks_usec()
		peak = maxf(float(t_now - t_prev), peak * PEAK_DECAY)
		t_prev = t_now
	_peak_us["plant"] = peak
	_ran_this_frame = _ran_this_frame or done > 0
	if job.cursor < job.plant_pts.size():
		return false
	_queue_spawns(job, water, road + radius[Plant.ROCK])
	job.cursor = 0
	job.stage = Stage.SPAWN
	return true


# Water and road are judged from the spot's own chunk (its height via the planting ground, its
# road candidates via _cands_of), so a spot spilling into a neighbour is judged exactly as one inside.
func _spot_is_clear(g: PlantGround, p: Vector2, water: float, clearance: float) -> bool:
	if g.height_at(p.x, p.y) < water + 0.3 or terrain.is_lake(p.x, p.y):
		return false
	var near_road := network.nearest_in(p.x, p.y, _cands_of(_chunk_of(p)), clearance)
	return not near_road and sites.is_clear(p, 2.0)


# Whether a clear spot grows: everything right by the road, thinning to the far density over
# roadside_falloff_m (trees also need the forest noise, which only gaps the forest away from the
# road). Reads the road distance that _spot_is_clear just left in network.hit_d.
func _roadside_keep(p: Vector2, kind: int, tree_line: float) -> bool:
	if kind == Plant.ROCK:
		return true
	var near := 1.0 - smoothstep(0.0, settings.roadside_falloff_m, network.hit_d - tree_line)
	var far := settings.far_tree_density if kind == Plant.TREE else settings.far_bush_density
	if ScatterMath.hash01(int(p.x * 8.0), int(p.y * 8.0), settings.world_seed, ROADSIDE_SALT + kind) >= lerpf(far, 1.0, near):
		return false
	return kind != Plant.TREE or TreeScatter.forest_density(_forest, p) > (1.0 - settings.forestiness) * (1.0 - near)


func _plant_candidates(job: ChunkJob) -> void:
	var cfg: GameConfig = Config.data
	if not cfg.vegetation_enabled:
		return
	var look := _look_at_chunk(job.coord)
	var sd := settings.world_seed
	var cm := settings.chunk_m
	for spec in [[Plant.TREE, settings.tree_cell_m, TREE_SALT], [Plant.BUSH, settings.bush_cell_m, BUSH_SALT],
			[Plant.ROCK, settings.rock_cell_m, ROCK_SALT]]:
		var kind: int = spec[0]
		var cell: float = spec[1]
		var salt: int = spec[2]
		if kind == Plant.BUSH and not RegionLibrary.spawns_bush_mesh(look):
			continue
		var rock_keep := settings.rock_group_chance * RegionLibrary.rock_density(look)
		if kind == Plant.ROCK and (not cfg.rocks_enabled or rock_keep <= 0.0):
			continue
		for gx in range(ceili(job.coord.x * cm / cell), ceili((job.coord.x + 1) * cm / cell)):
			for gz in range(ceili(job.coord.y * cm / cell), ceili((job.coord.y + 1) * cm / cell)):
				if kind == Plant.ROCK and ScatterMath.hash01(gx, gz, sd, salt + 9) >= rock_keep:
					continue
				var p := Vector2((gx + 0.15 + 0.7 * ScatterMath.hash01(gx, gz, sd, salt)) * cell,
					(gz + 0.15 + 0.7 * ScatterMath.hash01(gx, gz, sd, salt + 1)) * cell)
				job.plant_pts.append(p)
				job.plant_kind.append(kind)


func _queue_spawns(job: ChunkJob, water: float, rock_clearance: float) -> void:
	var cfg: GameConfig = Config.data
	var g := job.ground
	var look := _look_at_chunk(job.coord)
	var dist := cfg.tree_render_distance_m
	var fade := cfg.tree_render_fade_m
	var sd := settings.world_seed
	var trees: PackedVector2Array = job.kept[Plant.TREE]
	if not trees.is_empty():
		var mix := RegionLibrary.tree_mix(look)
		var weights: Array = []
		for entry in mix:
			weights.append(entry.get("weight", 1.0))
		var groups := TreeScatter.partition_by_weight(trees, weights, sd)
		for i in mix.size():
			var pts: PackedVector2Array = groups[i]
			var entry: Dictionary = mix[i]
			if not pts.is_empty():
				_add_spawn(job, _spawn_kind("tree", pts.size()), func(parent: Node3D) -> void:
					Foliage.spawn_trees(parent, pts, g, true, dist, fade, load(entry["texture"]),
						String(entry.get("profile", "home")) == "region", entry.get("size_scale", Vector2.ONE)))
	var bushes: PackedVector2Array = job.kept[Plant.BUSH]
	if not bushes.is_empty():
		_add_spawn(job, _spawn_kind("bush", bushes.size()), func(parent: Node3D) -> void:
			Foliage.spawn_bushes(parent, bushes, g, dist, fade)
			# Bushes have no collider: a proximity field makes brushing one cost HP and drag,
			# exactly as on the stage (world.gd._build_foliage).
			if focus != null:
				var touch := BushField.new()
				touch.name = "BushInteraction"
				parent.add_child(touch)
				touch.setup(bushes, focus, TreeMeshField.xz_radius(Foliage.bush_mesh(), cfg.bush_height_m) * cfg.bush_hit_radius_frac,
					cfg.bush_drag_strength, cfg.bush_drag_torque, cfg.bush_min_speed_kmh / DamageModel.MPS_TO_KMH))
	var anchors: PackedVector2Array = job.kept[Plant.ROCK]
	if not anchors.is_empty():
		# Each anchor fans out into an outcrop; the companions are checked like any other spot.
		var rocks := PackedVector2Array()
		for p in TreeScatter.cluster(anchors, cfg.rock_group_min, cfg.rock_group_max, cfg.rock_group_radius_m, sd + ROCK_SALT):
			if _spot_is_clear(g, p, water, rock_clearance):
				rocks.append(p)
		var weights: Array = []
		weights.resize(Foliage.ROCK_SCENES.size())
		weights.fill(1.0)
		var groups := TreeScatter.partition_by_weight(rocks, weights, sd + ROCK_SALT)
		for i in Foliage.ROCK_SCENES.size():
			var pts: PackedVector2Array = groups[i]
			if not pts.is_empty():
				_add_spawn(job, _spawn_kind("rock", pts.size()), func(parent: Node3D) -> void: Foliage.spawn_rocks(parent, pts, g, i, true, dist, fade))
	_queue_site_markers(job, g)
	_queue_barriers(job, g)


# The stage's barrier modules and collision, fed the free-roam layout and this road's width.
func barrier_params() -> Dictionary:
	var params := Config.data.barrier_render_params()
	params["track_width"] = settings.road_half_width_m * 2.0
	return params


func _queue_barriers(job: ChunkJob, g: PlantGround) -> void:
	var layout := barriers.in_chunk(job.coord)
	if layout.is_empty():
		return
	_add_spawn(job, _spawn_kind("barrier", layout.size()), func(parent: Node3D) -> void:
		var field := BarrierField.new()
		field.name = "Barriers"
		parent.add_child(field)
		field.build(layout, barrier_params(), func(p: Vector2) -> float: return g.height_at(p.x, p.y)))


# The chunk's site dressing. A rest stop gets a log cabin with a live crowd gathered at its door
# (decision 9: spectators gather at rest stops); the doorway glows once the stop is lit.
# Loot slots and dead ends show a coin until it is picked up.
func _queue_site_markers(job: ChunkJob, _g: PlantGround) -> void:
	var cm := settings.chunk_m
	var ids := sites.in_box(job.coord.x * cm, job.coord.y * cm, (job.coord.x + 1) * cm, (job.coord.y + 1) * cm)
	var mine := PackedInt32Array()
	for i in ids:
		if _chunk_of(sites.pos[i]) == job.coord:  # each site belongs to the chunk holding its centre
			mine.append(i)
	if mine.is_empty():
		return
	_add_spawn(job, "spawn_markers", func(parent: Node3D) -> void:
		for i in mine:
			if sites.kind[i] == RoadSites.Kind.REST:
				_rest_crowd(i, parent)
				_remove_site_markers(parent, i)
				parent.add_child(_site_marker(i))
			else:
				_place_loot_site_marker(parent, i))


const BEACON_LIT := Color(1.0, 0.55, 0.1)
const COIN := preload("res://shaders/coin.gdshader")
const LOG_CABIN := preload("res://models/cabin/log_cabin.glb")
# The cabin's log walls in its own space (the roof and the porch logs overhang them), for its
# collision box.
const CABIN_WALLS := AABB(Vector3(-3.7, 0.0, -4.7), Vector3(7.4, 3.5, 7.5))


# A rest stop's log cabin ("Lowpoly simple Log Cabin" by tamminen, CC-BY-4.0, see
# models/cabin/README.md): set back from the pad's centre towards its far side by
# rest_stop_cabin_back_m, door facing the road, inside the crowd's arc. Solid, and in the damage
# obstacle group like a barrier. Lit, a lamp inside glows BEACON_LIT through its doorway (refresh_site_marker).
func _site_marker(i: int) -> Node3D:
	var cabin: Node3D = LOG_CABIN.instantiate()
	cabin.name = "Site%d" % i
	var c := sites.pos[i]
	var away := sites.back(i)
	var at := c + away * Config.data.rest_stop_cabin_back_m
	cabin.position = Vector3(at.x, sites.pad_h[i], at.y)
	cabin.rotation.y = atan2(-away.x, -away.y)  # the model's door is on its +z side
	var body := StaticBody3D.new()
	body.name = "Body"
	body.add_to_group(DamageModel.OBSTACLE_GROUP)
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = CABIN_WALLS.size
	shape.shape = box
	shape.position = CABIN_WALLS.get_center()
	body.add_child(shape)
	cabin.add_child(body)
	_light_cabin(cabin, rest_lit_query.is_valid() and rest_lit_query.call(i))
	return cabin


# The cabin's interior floor (the model ships it as a flat black plane) is plain planks, and once
# its rest stop is lit a warm lamp hangs inside, so the doorway glows BEACON_LIT. The floor itself
# never glows: painted unshaded it read as a flat yellow square through the door.
const CABIN_FLOOR_COLOR := Color(0.28, 0.18, 0.1)
const CABIN_LAMP_AT := Vector3(0.0, 2.6, -1.0)  # under the roof, over the interior floor
const CABIN_LAMP_RANGE_M := 6.0
const CABIN_LAMP_ENERGY := 3.0
static var _cabin_floor: StandardMaterial3D


static func _light_cabin(cabin: Node3D, lit: bool) -> void:
	var inside := cabin.find_child("Interior", true, false) as MeshInstance3D
	if inside == null:
		return
	if _cabin_floor == null:
		_cabin_floor = StandardMaterial3D.new()
		_cabin_floor.albedo_color = CABIN_FLOOR_COLOR
		_cabin_floor.roughness = 1.0
	inside.material_override = _cabin_floor
	var lamp := cabin.get_node_or_null("Lamp") as OmniLight3D
	if not lit:
		if lamp != null:
			lamp.free()
		return
	if lamp != null:
		return
	lamp = OmniLight3D.new()
	lamp.name = "Lamp"
	lamp.position = CABIN_LAMP_AT
	lamp.light_color = BEACON_LIT
	lamp.light_energy = CABIN_LAMP_ENERGY
	lamp.omni_range = CABIN_LAMP_RANGE_M
	lamp.shadow_enabled = false
	cabin.add_child(lamp)


# A coin floating over its spot on the road, spinning (coin.gdshader).
func _coin_marker(i: int) -> Node3D:
	var mesh := CylinderMesh.new()
	mesh.top_radius = 0.45
	mesh.bottom_radius = 0.45
	mesh.height = 0.1
	mesh.radial_segments = 14
	mesh.rings = 1
	var mat := ShaderMaterial.new()
	mat.shader = COIN
	mat.set_shader_parameter("phase", ScatterMath.hash01(i, 1, settings.world_seed, 91) * 10.0)
	mesh.material = mat
	var mi := MeshInstance3D.new()
	mi.name = "Loot%d" % i
	mi.mesh = mesh
	mi.extra_cull_margin = 1.0  # the shader stands the flat disc up and bobs it
	var c := sites.pos[i]
	mi.position = Vector3(c.x, sites.pad_h[i] + 1.1, c.y)
	return mi


# Redraw every loaded loot site's marker from loot_query (a coin was picked up, or they all came back).
func refresh_loot_markers() -> void:
	for coord: Vector2i in _chunks:
		var st: ChunkState = _chunks[coord]
		if st.foliage == null:
			continue
		var cm := settings.chunk_m
		for i in sites.in_box(coord.x * cm, coord.y * cm, (coord.x + 1) * cm, (coord.y + 1) * cm):
			if sites.kind[i] == RoadSites.Kind.REST or _chunk_of(sites.pos[i]) != coord:
				continue
			_place_loot_site_marker(st.foliage, i)


# Just loot site `i`'s marker (a coin was picked up there), without walking every loaded chunk.
func refresh_loot_marker(i: int) -> void:
	var st: ChunkState = _chunks.get(_chunk_of(sites.pos[i]))
	if st != null and st.foliage != null:
		_place_loot_site_marker(st.foliage, i)


# Put loot site `i`'s marker under `parent` as loot_query has it now: a coin if one lies there,
# else nothing. Whatever marker it had goes first, so the queued planting
# spawn and a refresh_loot_markers that both reach a chunk (it has foliage, but its marker spawn
# is still queued) leave exactly one: adding a second "Loot%d" had Godot rename it "@Loot%d@N",
# which no later refresh removed, so a coin stayed after its pickup.
func _place_loot_site_marker(parent: Node3D, i: int) -> void:
	_remove_site_markers(parent, i)
	var item: Dictionary = loot_query.call(i) if loot_query.is_valid() else {}
	if not item.is_empty():
		parent.add_child(_coin_marker(i))


func _remove_site_markers(parent: Node3D, i: int) -> void:
	for n in ["Loot%d" % i, "Site%d" % i]:
		var old := parent.get_node_or_null(n)
		if old != null:
			parent.remove_child(old)
			old.queue_free()


# Light a loaded rest stop's cabin (it was just lit).
func refresh_site_marker(i: int) -> void:
	var st: ChunkState = _chunks.get(_chunk_of(sites.pos[i]))
	if st == null or st.foliage == null:
		return
	var cabin := st.foliage.get_node_or_null("Site%d" % i) as Node3D
	if cabin == null:
		return
	_light_cabin(cabin, rest_lit_query.is_valid() and rest_lit_query.call(i))


# A live crowd (SpectatorGroup, as on the old stages) added under `parent`, gathered in front of
# rest stop `i`'s cabin between its door and the road: they keep apart, scatter from the car and drift back, keep off
# the road and out of the cabin, and are knocked over if hit. The road is rasterised around the
# crowd only, and the cabin's walls stand in for the "trees" the group steers around. Steering
# only runs while the car is within spectator_active_radius_m; ragdolls are built on a knock, not
# up front (no pool), so a crowd costs a streamed chunk next to nothing.
func _rest_crowd(i: int, parent: Node3D) -> SpectatorGroup:
	var cfg: GameConfig = Config.data
	var n := cfg.rest_stop_crowd_size
	if n <= 0 or not cfg.spectators_enabled:
		return null
	var c := sites.pos[i]
	var away := sites.back(i)
	var along := Vector2(-away.y, away.x)
	var cabin := c + away * cfg.rest_stop_cabin_back_m
	var front := cabin - away * (CABIN_WALLS.end.z + REST_CROWD_HALF_DEPTH_M + 1.0)
	var p := cfg.spectator_params()
	p["seed"] = int(ScatterMath.hash01(i, 0, settings.world_seed, 63) * 1_000_000.0)
	p["ragdoll_pool_size"] = 0
	var road := _road_cells_near(front, REST_CROWD_HALF_LEN_M + p["road_probe_m"] + 2.0)
	var walls := _cabin_wall_points(cabin, away)
	var wall_grid := SpectatorScatter.build_point_grid(walls, p["tree_cell_m"])
	var members := SpectatorScatter.members(front, along, REST_CROWD_HALF_LEN_M, REST_CROWD_HALF_DEPTH_M,
		n, cfg.spectator_separation_m, road, wall_grid, p["tree_cell_m"], p["tree_avoid_m"], p["seed"])
	if members.is_empty():
		return null
	var group := SpectatorGroup.new()
	group.name = "Crowd%d" % i
	parent.add_child(group)
	group.setup(members, focus, self, road, wall_grid, p)
	return group


const REST_CROWD_HALF_LEN_M := 6.0    # along the road
const REST_CROWD_HALF_DEPTH_M := 3.0  # towards the road and back


# Road cells (ScatterMath's raster) within `reach` of `centre`: each nearby road segment is walked
# a cell at a time and stamped across its width, clipped to the box, so only the patch a rest
# stop's crowd can reach is rasterised.
func _road_cells_near(centre: Vector2, reach: float) -> Dictionary:
	var cells := {}
	var half := settings.road_half_width_m + settings.road_shoulder_m
	var step := ScatterMath.CELL_M
	for si in network.candidates_for(centre.x, centre.y, reach, reach + half):
		var a := Vector2(network.seg_ax[si], network.seg_ay[si])
		var b := Vector2(network.seg_bx[si], network.seg_by[si])
		var d := b - a
		var l := d.length()
		if l < 1e-4:
			continue
		var t := d / l
		var nrm := Vector2(-t.y, t.x)
		for k in int(l / step) + 1:
			var on := a + t * (k * step)
			if absf(on.x - centre.x) > reach + half or absf(on.y - centre.y) > reach + half:
				continue
			for w in range(-int(half / step), int(half / step) + 1):
				cells[ScatterMath.cell_of(on + nrm * (w * step))] = true
	return cells


# Points every metre round the cabin's walls in world XZ (its door faces -away).
func _cabin_wall_points(cabin: Vector2, away: Vector2) -> PackedVector2Array:
	var x_axis := Vector2(-away.y, away.x)  # the cabin's local +x
	var z_axis := -away                      # its local +z, the door side
	var lo := CABIN_WALLS.position
	var hi := CABIN_WALLS.end
	var pts := PackedVector2Array()
	for k in int(CABIN_WALLS.size.x) + 1:
		var x := lo.x + k * CABIN_WALLS.size.x / ceilf(CABIN_WALLS.size.x)
		for z in [lo.z, hi.z]:
			pts.append(cabin + x_axis * x + z_axis * z)
	for k in int(CABIN_WALLS.size.z) + 1:
		var z := lo.z + k * CABIN_WALLS.size.z / ceilf(CABIN_WALLS.size.z)
		for x in [lo.x, hi.x]:
			pts.append(cabin + x_axis * x + z_axis * z)
	return pts


func _add_spawn(job: ChunkJob, kind: String, work: Callable) -> void:
	job.spawns.append(work)
	job.spawn_kinds.append(kind)


# Spawns are measured per species and per size: a field of 40 trees costs far more than one of 4,
# and a single shared estimate is how big fields used to overrun the frame.
static func _spawn_kind(species: String, count: int) -> String:
	return "spawn_%s_%d" % [species, nearest_po2(maxi(count, 1))]


func _spawn_next(job: ChunkJob) -> void:
	var st: ChunkState = _chunks.get(job.coord)
	if st == null or st.near_mesh == null or job.cursor >= job.spawns.size():
		job.stage = Stage.DONE
		return
	if st.foliage == null:
		st.foliage = Node3D.new()
		add_child(st.foliage)
	job.spawns[job.cursor].call(st.foliage)
	job.cursor += 1
	if job.cursor >= job.spawns.size():
		job.stage = Stage.DONE


func _look_at_chunk(coord: Vector2i) -> Dictionary:
	var cm := settings.chunk_m
	return _ring_looks[terrain.ring_index((coord.x + 0.5) * cm, (coord.y + 0.5) * cm)]


var _widest_rock_r := -1.0
func _widest_rock() -> float:
	if _widest_rock_r < 0.0:
		_widest_rock_r = 0.0
		for i in Foliage.ROCK_SCENES.size():
			_widest_rock_r = maxf(_widest_rock_r, TreeMeshField.xz_radius(Foliage.rock_mesh(i), Foliage.rock_height(i)))
	return _widest_rock_r


# --- planning ------------------------------------------------------------------------------

func _focus_xz() -> Vector2:
	if _plan_override != null:
		return _plan_override
	return Vector2(focus.global_position.x, focus.global_position.z)


func _chunk_of(p: Vector2) -> Vector2i:
	return Vector2i(floori(p.x / settings.chunk_m), floori(p.y / settings.chunk_m))


# Decide what should exist around the car and queue jobs for what is missing, nearest first.
# Distance is measured from both the car and where it will be in a second and a half, so the
# road ahead fills before the road behind.
func _plan() -> void:
	_plan_timer = 0.25
	var here := _focus_xz()
	var ahead := here
	if focus is RigidBody3D and _plan_override == null:
		var v := (focus as RigidBody3D).linear_velocity
		ahead += Vector2(v.x, v.z) * 1.5
	_plan_coord = _chunk_of(here)
	var cm := settings.chunk_m
	var far_r := settings.far_radius
	for coord: Vector2i in _chunks.keys():
		var off := coord - _plan_coord
		if maxi(absi(off.x), absi(off.y)) > far_r + 2:
			_drop_chunk(coord, _chunks[coord])
	for dz in range(-far_r - 2, far_r + 3):
		for dx in range(-far_r - 2, far_r + 3):
			var coord := _plan_coord + Vector2i(dx, dz)
			var center := (Vector2(coord) + Vector2(0.5, 0.5)) * cm
			var d := minf(center.distance_to(here), center.distance_to(ahead)) / cm
			var st: ChunkState = _chunks.get(coord)
			# Shed full detail and collision first, before the horizon test below: a chunk can be
			# past the horizon yet still inside the drop square (a jump of a few hundred metres:
			# a respawn or a rest-stop travel), and it must not keep its near mesh, foliage,
			# collision or queued near / plant / collision jobs at their old priorities (which a
			# prefill_at would then run, lengthening the travel hitch).
			if st != null:
				if d > settings.near_radius + 1.5:
					_drop_near(st)
				if d > settings.collision_radius + 1.5:
					_drop_collision(st)
			if d > far_r + 0.5:
				if st != null and st.far_job != null:
					if d > far_r + 1.5:
						st.far_job.cancelled = true
						st.far_job = null
					else:
						st.far_job.priority = d
						st.far_job.dist = d
				continue
			if st == null:
				st = ChunkState.new()
				_chunks[coord] = st
			var want_near := d <= settings.near_radius + 0.75
			var want_col := d <= settings.collision_radius + 0.75
			if st.far_mesh == null and st.far_job == null:
				st.far_job = _new_job(coord, false, false)
			if want_near:
				if st.near_mesh == null and st.near_job == null:
					st.near_job = _new_job(coord, true, want_col)
				if st.near_job != null:
					st.near_job.with_collision = st.near_job.with_collision or want_col
					st.near_job.priority = d - (1000.0 if want_col else 100.0)
					st.near_job.dist = d
			elif st.near_job != null:
				# In the hysteresis band (no longer wanted, not yet dropped): an unfinished near
				# build drops to the near-mesh tier rather than keeping a collision-tier priority.
				st.near_job.priority = d - 100.0
				st.near_job.dist = d
			if st.far_job != null:
				st.far_job.priority = _far_priority(st, d)
				st.far_job.dist = d
			if want_col and st.body == null and st.near_mesh != null and st.col_job == null:
				st.col_job = _new_job(coord, true, true)
				st.col_job.stage = Stage.COLLIDE
				st.col_job.plants = false
			if st.plant_job != null and st.plant_job.stage != Stage.DONE:
				st.plant_job.dist = d
				st.plant_job.priority = d + PLANT_PRIORITY
			if st.col_job != null:
				st.col_job.priority = d - 2000.0
	# Cancelled and finished jobs leave now rather than when they reach the head: a queue that
	# never drains (a car outdriving the far ring) would otherwise carry them for ever.
	var live: Array[ChunkJob] = []
	for job in _queue:
		if not job.cancelled and job.stage != Stage.DONE:
			live.append(job)
	_queue = live
	_queue.sort_custom(func(a: ChunkJob, b: ChunkJob) -> bool: return a.priority < b.priority)


func _new_job(coord: Vector2i, near: bool, with_collision: bool) -> ChunkJob:
	var job := ChunkJob.new()
	job.coord = coord
	job.near = near
	job.with_collision = with_collision
	job.stride = settings.near_stride_m if near else settings.far_stride_m
	job.n = int(settings.chunk_m / job.stride) + 1
	# Every near build runs the planting stages: they also spawn the chunk's barriers (with
	# collision), rest-stop crowds, site posts and coins. vegetation_enabled only thins the
	# trees, bushes and rocks out of it (_plant_candidates).
	job.plants = near
	_queue.append(job)
	return job


func _drop_near(st: ChunkState) -> void:
	for job in [st.near_job, st.plant_job]:
		if job != null:
			(job as ChunkJob).cancelled = true
	st.near_job = null
	st.plant_job = null
	if st.near_mesh != null:
		st.near_mesh.queue_free()
		st.near_mesh = null
		st.near_heights = PackedFloat32Array()
		st.near_road_d = PackedFloat32Array()
		if st.foliage != null:
			st.foliage.queue_free()
			st.foliage = null
		if st.far_mesh != null:
			st.far_mesh.visible = true


# The chunk's collision and any queued collision build go (it left the collision ring).
func _drop_collision(st: ChunkState) -> void:
	if st.col_job != null:
		st.col_job.cancelled = true
		st.col_job = null
	if st.near_job != null:
		st.near_job.with_collision = false
	if st.body != null:
		st.body.queue_free()
		st.body = null


func _drop_chunk(coord: Vector2i, st: ChunkState) -> void:
	_drop_near(st)
	_drop_collision(st)
	if st.far_job != null:
		st.far_job.cancelled = true
	if st.far_mesh != null:
		st.far_mesh.queue_free()
	_chunks.erase(coord)


# --- shared mesh buffers -------------------------------------------------------------------

func _perimeter(n: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	for x in n: out.append(x)
	for z in range(1, n): out.append(z * n + n - 1)
	for x in range(n - 2, -1, -1): out.append((n - 1) * n + x)
	for z in range(n - 2, 0, -1): out.append(z * n)
	return out


func _indices_for(n: int) -> PackedInt32Array:
	if _indices.has(n):
		return _indices[n]
	var idx := PackedInt32Array()
	for zi in n - 1:
		for xi in n - 1:
			var a := zi * n + xi
			idx.append_array([a, a + 1, a + n, a + 1, a + n + 1, a + n])
	var perim := _perimeter(n)
	var p := perim.size()
	for k in p:
		var t0 := perim[k]
		var t1 := perim[(k + 1) % p]
		var s0 := n * n + k
		var s1 := n * n + (k + 1) % p
		idx.append_array([t0, t1, s0, t1, s1, s0, t0, s0, t1, t1, s0, s1])  # both faces
	_indices[n] = idx
	return idx
