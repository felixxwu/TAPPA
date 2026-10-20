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

const SUN := Vector3(-0.45, 0.8, -0.4)
const UV_PER_M := 0.125
# How many vertices the array stage packs between clock checks (each is a few µs).
const CHECK_EVERY := 4

enum Stage { PREP, HEIGHTS, ARRAYS, UPLOAD, ATTACH, COLLIDE, PLANT, SPAWN, DONE }

enum Plant { TREE, BUSH, ROCK }
const TREE_SALT := 101
const BUSH_SALT := 202
const ROCK_SALT := 303

@export var settings: FreeRoamSettings
@export var material: Material

var network := RoadNetwork.new()
var terrain := RoadTerrain.new()
var sites := RoadSites.new()
var barriers := RoadBarriers.new()
var focus: Node3D

# Read by the HUD.
var stat_used_us := 0
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
var _last_kind := ""
# A decaying peak of the cost of one unit in the sample-at-a-time stages (heights, arrays,
# plant), so the stop rule allows for the dear ones rather than the average.
var _peak_us := {"heights": 40.0, "arrays": 10.0, "plant": 40.0}
const PEAK_DECAY := 0.995

var _chunks := {}  # Vector2i -> ChunkState
var _queue: Array[ChunkJob] = []
var _est := {}  # atomic stage -> moving average of its cost, µs
var _indices := {}  # verts per side -> PackedInt32Array, grid plus skirts
var _zero_uv2 := {}  # verts per side -> PackedVector2Array
var _plan_coord := Vector2i(1 << 30, 0)
var _plan_timer := 0.0
var _ran_this_frame := false
var _sun := SUN.normalized()
var _forest: FastNoiseLite
var _ring_looks: Array[Dictionary] = []
var _ring_materials: Array[Material] = []


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


class ChunkJob:
	var coord: Vector2i
	var near := false
	var with_collision := false
	var stride := 8.0
	var n := 9  # vertices per side
	var stage := Stage.PREP
	var cursor := 0
	var priority := 0.0
	var cancelled := false
	var cands := PackedInt32Array()
	# Near chunks sample a one-sample border so edge normals match their neighbours; far chunks
	# skip it and take one-sided slopes at their edges, which fog hides.
	var halo := 0
	var tint := Color.WHITE
	var heights := PackedFloat32Array()  # (n + 2·halo)²
	var road_d := PackedFloat32Array()   # n²
	var verts := PackedVector3Array()
	var colors := PackedColorArray()
	var uvs := PackedVector2Array()
	var mesh: ArrayMesh
	var plants := false  # a near build also plants the chunk's trees, bushes and rocks
	var plant_pts := PackedVector2Array()
	var plant_kind := PackedInt32Array()
	var kept := [PackedVector2Array(), PackedVector2Array(), PackedVector2Array()]  # by Plant
	var spawns: Array[Callable] = []
	var spawn_kinds := PackedStringArray()  # each spawn's cost-estimate key (see _spawn_kind)


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
	return m


# Every ring's ground material (the BiomeDirector tints them for the weather).
func ring_materials() -> Array[ShaderMaterial]:
	var out: Array[ShaderMaterial] = []
	for m in _ring_materials:
		if m is ShaderMaterial:
			out.append(m)
	return out


# The vertex tint baked under a point: its ring's region `terrain_tint`, white when it has none
# (the stage's default), so the region's own textures show true.
func ring_tint_at(p: Vector2) -> Color:
	if _ring_looks.is_empty():
		return Color.WHITE
	return _ring_looks[terrain.ring_index(p.x, p.y)].get("terrain_tint", Color.WHITE)


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
	if st != null and not st.near_road_d.is_empty():
		return Vector2(terrain.road_weight(_mesh_height(st.near_road_d, settings.near_stride_m, 0, coord, x, z)), 0.0)
	terrain.height(x, z, PackedInt32Array(), false)
	return Vector2(terrain.road_weight(terrain.last_road_d), 0.0)


# --- scheduling ----------------------------------------------------------------------------

func _process(delta: float) -> void:
	if focus == null:
		return
	_plan_timer -= delta
	var cc := _chunk_of(_focus_xz())
	if cc != _plan_coord or _plan_timer <= 0.0:
		_plan()
	var start := Time.get_ticks_usec()
	_run_queue(start + settings.budget_us)
	var used := Time.get_ticks_usec() - start
	stat_used_us = used
	stat_frames += 1
	stat_worst_us = maxi(stat_worst_us, used)
	if used > settings.budget_us:
		stat_overruns += 1
		stat_overshoot_us += used - settings.budget_us
		stat_overrun_by[_last_kind] = int(stat_overrun_by.get(_last_kind, 0)) + 1
		if used > settings.budget_us * 3 / 2:
			stat_spikes += 1
			stat_spike_by[_last_kind] = int(stat_spike_by.get(_last_kind, 0)) + 1


# Build everything the planner wants with no budget: used once at boot, behind the spawn.
func prefill() -> void:
	_plan()
	var start := Time.get_ticks_usec()
	_run_queue(start + 60_000_000)


# Draw a speck of every ring's ground material in front of `camera` for a few frames, so each
# one's shader pipeline is compiled behind the boot load rather than in the first frame a new
# biome's chunk appears (a GPU stall the frame budget can't see).
func warm_up_materials(camera: Camera3D, frames := 3) -> void:
	if camera == null:
		return
	var specks: Array[MeshInstance3D] = []
	for m in _ring_materials:
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
		if not _step(job, deadline):
			return
		if job.stage == Stage.DONE:
			_queue.pop_front()
		if Time.get_ticks_usec() >= deadline:
			return


# Advance a job by as many units as fit before `deadline`. Returns false when the next unit
# could not be started this frame.
func _step(job: ChunkJob, deadline: int) -> bool:
	while job.stage != Stage.DONE:
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
	job.cursor = 0
	job.stage = Stage.HEIGHTS
	job.tint = ring_tint_at(Vector2((job.coord.x + 0.5) * cm, (job.coord.y + 0.5) * cm))
	# A chunk wholly beyond the furthest possible coastline is open sea: no sampling needed.
	var nx := clampf(0.0, job.coord.x * cm - job.stride, (job.coord.x + 1) * cm + job.stride)
	var ny := clampf(0.0, job.coord.y * cm - job.stride, (job.coord.y + 1) * cm + job.stride)
	if LabNoise.hyp(nx, ny) >= settings.island_radius_m:
		job.heights.fill(terrain.sea_floor())
		job.road_d.fill(INF)
		_start_arrays(job)
		return
	var st: ChunkState = _chunks.get(job.coord)
	if st != null and st.has_cands:
		job.cands = st.cands
		return
	# The margin covers the wider of the two strides, so one list serves both builds.
	var half := cm * 0.5 + maxf(settings.near_stride_m, settings.far_stride_m)
	job.cands = network.candidates_for((job.coord.x + 0.5) * cm, (job.coord.y + 0.5) * cm, half * sqrt(2.0), settings.mountain_dist_m)
	if st != null:
		st.cands = job.cands
		st.has_cands = true


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
			job.road_d[gz * job.n + gx] = minf(terrain.last_road_d, 1.0e4)  # finite, so it interpolates
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
		var light := 0.55 + 0.5 * maxf(0.0, normal.dot(_sun))
		var px := ox + gx * s
		var pz := oy + gz * s
		var col := job.tint * light
		col.a = terrain.road_weight(job.road_d[i])
		job.verts[i] = Vector3(gx * s, h, gz * s)
		job.colors[i] = col
		job.uvs[i] = Vector2(px, pz) * UV_PER_M
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
	job.stage = Stage.UPLOAD
	return true


func _upload(job: ChunkJob) -> void:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = job.verts
	arrays[Mesh.ARRAY_COLOR] = job.colors
	arrays[Mesh.ARRAY_TEX_UV] = job.uvs
	arrays[Mesh.ARRAY_TEX_UV2] = _uv2_for(job.n)
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
	mi.material_override = ring_material_at(job.coord)
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


# Baked ground light for foliage that wants to match the ground it stands on (the bushes):
# the same tint-times-sun shading the chunk vertices get.
func light_at(x: float, z: float) -> Color:
	var n := Vector3(height_at(x - 1.0, z) - height_at(x + 1.0, z), 2.0, height_at(x, z - 1.0) - height_at(x, z + 1.0)).normalized()
	var c := ring_tint_at(Vector2(x, z)) * (0.55 + 0.5 * maxf(0.0, n.dot(_sun)))
	c.a = 1.0
	return c


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
		_plant_candidates(job)
		job.cursor = 0
	var cfg: GameConfig = Config.data
	var water := settings.water_level_m
	var road := settings.road_half_width_m + settings.road_shoulder_m + cfg.tree_road_margin_m
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
		if _spot_is_clear(st, p, water, road + radius[kind]):
			var kept: PackedVector2Array = job.kept[kind]  # a copy: packed arrays are values
			kept.append(p)
			job.kept[kind] = kept
		var t_now := Time.get_ticks_usec()
		peak = maxf(float(t_now - t_prev), peak * PEAK_DECAY)
		t_prev = t_now
	_peak_us["plant"] = peak
	_ran_this_frame = _ran_this_frame or done > 0
	if job.cursor < job.plant_pts.size():
		return false
	_queue_spawns(job, st, water, road + radius[Plant.ROCK])
	job.cursor = 0
	job.stage = Stage.SPAWN
	return true


func _spot_is_clear(st: ChunkState, p: Vector2, water: float, clearance: float) -> bool:
	if height_at(p.x, p.y) < water + 0.3 or terrain.is_lake(p.x, p.y):
		return false
	var near_road := network.nearest_in(p.x, p.y, st.cands, clearance) if st.has_cands else network.nearest(p.x, p.y, clearance)
	return not near_road and sites.is_clear(p, 2.0)


func _plant_candidates(job: ChunkJob) -> void:
	var cfg: GameConfig = Config.data
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
				if kind == Plant.TREE and TreeScatter.forest_density(_forest, p) <= 1.0 - settings.forestiness:
					continue
				job.plant_pts.append(p)
				job.plant_kind.append(kind)


func _queue_spawns(job: ChunkJob, st: ChunkState, water: float, rock_clearance: float) -> void:
	var cfg: GameConfig = Config.data
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
					Foliage.spawn_trees(parent, pts, self, true, dist, fade, load(entry["texture"]),
						String(entry.get("profile", "home")) == "region", entry.get("size_scale", Vector2.ONE)))
	var bushes: PackedVector2Array = job.kept[Plant.BUSH]
	if not bushes.is_empty():
		_add_spawn(job, _spawn_kind("bush", bushes.size()), func(parent: Node3D) -> void:
			Foliage.spawn_bushes(parent, bushes, self, dist, fade)
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
			if _spot_is_clear(st, p, water, rock_clearance):
				rocks.append(p)
		var weights: Array = []
		weights.resize(Foliage.ROCK_SCENES.size())
		weights.fill(1.0)
		var groups := TreeScatter.partition_by_weight(rocks, weights, sd + ROCK_SALT)
		for i in Foliage.ROCK_SCENES.size():
			var pts: PackedVector2Array = groups[i]
			if not pts.is_empty():
				_add_spawn(job, _spawn_kind("rock", pts.size()), func(parent: Node3D) -> void: Foliage.spawn_rocks(parent, pts, self, i, true, dist, fade))
	_queue_site_markers(job)
	_queue_barriers(job)


# The stage's barrier modules and collision, fed the free-roam layout and this road's width.
func barrier_params() -> Dictionary:
	var params := Config.data.barrier_render_params()
	params["track_width"] = settings.road_half_width_m * 2.0
	return params


func _queue_barriers(job: ChunkJob) -> void:
	var layout := barriers.in_chunk(job.coord)
	if layout.is_empty():
		return
	_add_spawn(job, _spawn_kind("barrier", layout.size()), func(parent: Node3D) -> void:
		var field := BarrierField.new()
		field.name = "Barriers"
		parent.add_child(field)
		field.build(layout, barrier_params(), func(p: Vector2) -> float: return height_at(p.x, p.y)))


# Placeholder posts at the chunk's sites, until rest stops and loot get real models: tall
# orange for a rest stop, short blue for a loot slot, purple for a dead end.
func _queue_site_markers(job: ChunkJob) -> void:
	if not settings.site_markers:
		return
	var cm := settings.chunk_m
	var ids := sites.in_box(job.coord.x * cm, job.coord.y * cm, (job.coord.x + 1) * cm, (job.coord.y + 1) * cm)
	var mine := PackedInt32Array()
	for i in ids:
		if _chunk_of(sites.pos[i]) == job.coord:  # each marker belongs to the chunk holding its centre
			mine.append(i)
	if mine.is_empty():
		return
	_add_spawn(job, "spawn_markers", func(parent: Node3D) -> void:
		for i in mine:
			parent.add_child(_site_marker(i)))


func _site_marker(i: int) -> MeshInstance3D:
	var looks := {RoadSites.Kind.REST: [Color(1.0, 0.55, 0.1), 5.0], RoadSites.Kind.LOOT: [Color(0.2, 0.55, 1.0), 1.6],
		RoadSites.Kind.DEAD_END: [Color(0.65, 0.3, 0.9), 3.0]}
	var look: Array = looks[sites.kind[i]]
	var mesh := CylinderMesh.new()
	mesh.top_radius = 0.25
	mesh.bottom_radius = 0.25
	mesh.height = look[1]
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = look[0]
	mesh.material = mat
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.name = "Site%d" % i
	var c := sites.pos[i]
	mi.position = Vector3(c.x, sites.pad_h[i] + look[1] * 0.5, c.y)
	return mi


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
	if focus is RigidBody3D:
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
			if d > far_r + 0.5:
				continue
			if st == null:
				st = ChunkState.new()
				_chunks[coord] = st
			var want_near := d <= settings.near_radius + 0.75
			var want_col := d <= settings.collision_radius + 0.75
			if st.far_mesh == null and st.far_job == null:
				st.far_job = _new_job(coord, false, false)
			if st.far_job != null:
				st.far_job.priority = d
			if want_near:
				if st.near_mesh == null and st.near_job == null:
					st.near_job = _new_job(coord, true, want_col)
				if st.near_job != null:
					st.near_job.with_collision = st.near_job.with_collision or want_col
					st.near_job.priority = d - (1000.0 if want_col else 100.0)
			elif d > settings.near_radius + 1.5:
				_drop_near(st)
			if want_col and st.body == null and st.near_mesh != null and st.col_job == null:
				st.col_job = _new_job(coord, true, true)
				st.col_job.stage = Stage.COLLIDE
				st.col_job.plants = false
			if st.col_job != null:
				st.col_job.priority = d - 2000.0
			if d > settings.collision_radius + 1.5 and st.body != null:
				st.body.queue_free()
				st.body = null
	_queue.sort_custom(func(a: ChunkJob, b: ChunkJob) -> bool: return a.priority < b.priority)


func _new_job(coord: Vector2i, near: bool, with_collision: bool) -> ChunkJob:
	var job := ChunkJob.new()
	job.coord = coord
	job.near = near
	job.with_collision = with_collision
	job.stride = settings.near_stride_m if near else settings.far_stride_m
	job.n = int(settings.chunk_m / job.stride) + 1
	job.plants = near and Config.data.vegetation_enabled
	_queue.append(job)
	return job


func _drop_near(st: ChunkState) -> void:
	if st.near_job != null:
		st.near_job.cancelled = true
		st.near_job = null
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


func _drop_chunk(coord: Vector2i, st: ChunkState) -> void:
	_drop_near(st)
	for job in [st.far_job, st.col_job]:
		if job != null:
			(job as ChunkJob).cancelled = true
	for node in [st.far_mesh, st.body]:
		if node != null:
			(node as Node).queue_free()
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


func _uv2_for(n: int) -> PackedVector2Array:
	if not _zero_uv2.has(n):
		var a := PackedVector2Array()
		a.resize(n * n + 4 * (n - 1))
		_zero_uv2[n] = a
	return _zero_uv2[n]
