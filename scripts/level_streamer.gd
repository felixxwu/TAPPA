class_name LevelStreamer
extends Node3D
# Docs: features/level-streamer.md — update in the same change as this file.
# Tests: tests/headless/test_level_streamer.gd — extend in the same change.
# Streams a saved level's ground (baked heights, 1.5 m near mesh, collision) around the car under a strict per-frame time budget.
#
# Building a chunk is a resumable job split into small units of work. Each frame the scheduler runs units until the budget
# is spent and never starts a unit that its measured cost says would not fit, so a job can stop between any two units and
# carry on next frame. The car sees this node as its terrain (height_at / surface_at).


const SUN := Vector3(-1.0, 1.4, 0.6)
const WALL_THICKNESS_M := 10.0
const WALL_HEIGHT_M := 400.0
const BIOME_CELL := 10.0  # metres per biome mask cell (BIOME_CELL in tools/level_editor_lab.html)
const BIOME_SNOW := 1


# How many vertices the array stage packs between clock checks (each is a few µs).
const CHECK_EVERY := 4


enum Stage { PREP, HEIGHTS, ARRAYS, UPLOAD, ATTACH, COLLIDE, DONE }


# Detail levels, finest first. NEAR is the tiles within NEAR_REACH_M of the car, drawn and driven on only.
# MID reaches further, FAR further still, and HORIZON is one quad per chunk out to horizon_radius_m.
enum Level { NEAR, MID, FAR, HORIZON }


# The streamer's sizes and budget. A plain class, so the adaptive graphics can read the authored rings (LevelKnobs).
class Settings:
	var chunk_m := 96.0  # one draw call per chunk: 48 m chunks made the far ring ~120 calls a frame, 96 m ~40
	var near_tile_m := 24.0  # must divide chunk_m, and be a multiple of mid_stride_m and far_stride_m
	var near_stride_m := 1.5
	var mid_stride_m := 6.0
	var far_stride_m := 12.0
	var mid_radius := 150.0 / 96.0  # in chunks
	var far_radius := 8
	var horizon_radius_m := 3000.0  # 0 turns the horizon off
	var horizon_block_chunks := 12  # chunks per side of one horizon mesh (one draw call)
	# Share of the frame's free time terrain work may use, floored at a share of the frame time, but no longer than at budget_floor_fps.
	var budget_fraction := 0.5
	var budget_min_fraction := 0.25
	var budget_floor_fps := 60.0
	var prefill_slice_ms := 8.0  # boot builds the ground in slices this long, a frame apart, so the loading screen keeps drawing
	# The mid band narrows as the car speeds up, reaching these shares of its reach to the side and behind at mid_squash_speed_mps.
	var mid_side_frac := 0.6
	var mid_back_frac := 0.6
	var mid_squash_speed_mps := 25.0
	var collision_rush_s := 0.5  # collision this many seconds ahead of the car is built at once if missing
	var far_lead_chunks := 3.0  # how far ahead of hidden far meshes a far mesh filling a gap in the horizon is queued


var settings := Settings.new()
var material: Material


var data: LevelData
var bake: LevelBake
var cover: GroundCover
# What brushes the bushes in cover tiles built from now on: the car, even while photo mode moves `focus`
# to its camera (a bush tied to the photo camera would outlive it). Null falls back to `focus`.
var brush: Node3D
var _cover := PackedByteArray()
var _cover_tints := {}
var _bush_ids := {}
var _biome := PackedByteArray()
var _biome_n := 0
var _sun_dir := SUN.normalized()


var focus: Node3D
# Photo mode's render: build full-detail tiles over the whole far ring, nearest first, a few a frame.
var full_detail := false:
	set(v):
		full_detail = v
		_plan_timer = 0.0
# Frame time not taken by anything but terrain (µs), smoothed over recent frames; set by the HUD side.
var spare_us := 2000.0
# Times the car rolled onto a near tile that had no full-detail mesh yet: the streamer fell behind.
var stat_near_misses := 0
# Running mean of how long a near tile takes from its first unit of work to its mesh going in.
var near_build_s := 0.25
var _miss_tile := Vector2i(1 << 30, 1 << 30)
var _plan_us := 0
var _starved := 0  # frames in a row the queue ran only the car's path


# A decaying peak of the cost of one unit in the sample-at-a-time stages (heights, arrays),
# so the stop rule allows for the dear ones rather than the average.
var _peak_us := {"heights": 40.0, "arrays": 10.0}
const PEAK_DECAY := 0.995


var _chunks := {}  # Vector2i -> ChunkState
var _tiles := {}  # Vector2i -> TileState, in near_tile_m squares
var _queue: Array[ChunkJob] = []
var _est := {}  # atomic stage -> moving average of its cost, µs
var _holes_due := {}  # chunks whose near tiles changed in the planner: _run_queue recuts their holes, first
var _horizon := {}  # Vector2i block -> HorizonState, in horizon_block_chunks squares of chunks
var _horizon_due := {}  # horizon blocks whose chunks' far / mid meshes came or went: _run_queue recuts them
var _indices := {}  # verts per side -> PackedInt32Array, grid plus skirts
var _plan_coord := Vector2i(1 << 30, 0)
var _plan_timer := 0.0
var _ran_this_frame := false
var _inflight: Array[ChunkJob] = []
var _prefilling := false


class ChunkState:
	var coord: Vector2i
	var far_mesh: MeshInstance3D
	var mid_mesh: MeshInstance3D
	var mid_heights := PackedFloat32Array()  # halo grid kept for collision and height queries
	var far_heights := PackedFloat32Array()
	# The vertex arrays of the mid and far meshes, kept so the drawn one can be rebuilt with holes
	# where near tiles cover it (_cut_holes), and which mesh and tiles the holes were last cut for.
	var mid_arrays: Array = []
	var far_arrays: Array = []
	var hole_mesh: MeshInstance3D
	var hole_mask := 0
	var far_job: ChunkJob
	var mid_job: ChunkJob


# One horizon block (horizon_block_chunks × horizon_block_chunks chunks, one quad each): its mesh,
# drawn with the cells cut out whose chunk has its own far or mid mesh (see _cut_horizon).
class HorizonState:
	var mesh: MeshInstance3D
	var arrays: Array = []  # vertices, colours, UVs and UV2s of the uncut mesh
	var cut := PackedByteArray()  # 1 per cell (cz * blocks + cx) the drawn mesh leaves out; empty: uncut
	var job: ChunkJob


# One near_tile_m square: its full-detail mesh, and its share of the collision, built from the
# finest grid there (this tile's near grid, else the quarter of its chunk's mid grid under it).
class TileState:
	var near_mesh: MeshInstance3D
	var wanted_us := 0  # when a plan last wanted this tile's full detail
	var near_heights := PackedFloat32Array()  # halo grid
	var near_job: ChunkJob
	var near_arrays := []  # vertices, colours, UVs and UV2s of the drawn near mesh, kept so its edges can be re-stitched
	var stitch := 0  # which edges of the drawn near mesh were blended down to the mid line (see _stitch_mask)
	var body: StaticBody3D
	var body_level := Level.FAR
	var col_job: ChunkJob


class ChunkJob:
	var coord: Vector2i  # a near tile's coord for a tile job, a block's for a horizon job, else a chunk's
	var tile := false
	var origin := Vector2.ZERO  # world position of the square's corner
	var size_m := 64.0
	var level := Level.FAR
	var with_collision := false
	var stride := 8.0
	var n := 9  # vertices per side
	var stage := Stage.PREP
	var cursor := 0
	var priority := 0.0
	var dist := 0.0  # distance from the car, in chunks, at the last plan
	var eta_s := INF  # a near tile's seconds until the car reaches it, at the last plan
	var started_us := 0
	var cancelled := false
	var task_id := -1  # the WorkerThreadPool task building this job's heights and arrays, -1 when none
	var stitch := 0
	var ao_bush := 0.0
	var bank_m := 0.0
	# Near and mid chunks sample a one-sample border so edge normals match their neighbours; far chunks
	# skip it and take one-sided slopes at their edges, which fog hides.
	var halo := 0
	var heights := PackedFloat32Array()  # (n + 2·halo)²
	var verts := PackedVector3Array()
	var colors := PackedColorArray()
	var uvs := PackedVector2Array()
	var uv2s := PackedVector2Array()  # x = tarmac weight (the ground shader's UV2.x)
	var mesh: ArrayMesh


func setup(p_data: LevelData, p_bake: LevelBake, p_material: Material) -> void:
	data = p_data
	bake = p_bake
	material = p_material
	_cover = GroundCover.decode_cover(data.level)
	_cover_tints = GroundCover.tints(data.level.get("coverKinds", {}))
	_bush_ids = GroundCover.bush_ids(data.level.get("coverKinds", {}))
	_biome = decode_biome(data.level, bake.size)
	_biome_n = ceili(bake.size / BIOME_CELL) if not _biome.is_empty() else 0
	(p_material as ShaderMaterial).set_shader_parameter("snow_depth_m", Config.data.snow_visual_depth_m)
	(p_material as ShaderMaterial).set_shader_parameter("snow_road_lighten", Config.data.level_snow_road_lighten)
	bake.apply_to(p_material as ShaderMaterial)
	bake.road_nearest(0.0, 0.0)  # builds the road index now, not racing on a worker
	cover = GroundCover.new()
	cover.name = "Cover"
	# The baked height, not height_at: a cover tile often builds before the near mesh, and the coarse mid/far grids smooth over road cuttings.
	cover.setup(data.level, bake.height, int(bake.size))
	add_child(cover)


# The ground repeats outwards past the square, so an invisible wall at its edge keeps the car in.
func _ready() -> void:
	var half := bake.size * 0.5
	var body := StaticBody3D.new()
	body.name = "EdgeWall"
	for side in 4:
		var dir := Vector2.RIGHT.rotated(side * PI * 0.5)
		var box := BoxShape3D.new()
		box.size = Vector3(WALL_THICKNESS_M, WALL_HEIGHT_M, bake.size + 2.0 * WALL_THICKNESS_M) if side % 2 == 0 \
			else Vector3(bake.size + 2.0 * WALL_THICKNESS_M, WALL_HEIGHT_M, WALL_THICKNESS_M)
		var cs := CollisionShape3D.new()
		cs.shape = box
		cs.position = Vector3(dir.x, 0.0, dir.y) * (half + WALL_THICKNESS_M * 0.5) + Vector3.UP * (WALL_HEIGHT_M * 0.5 - 50.0)
		body.add_child(cs)
	add_child(body)


func _exit_tree() -> void:
	for job in _inflight:
		job.cancelled = true
		WorkerThreadPool.wait_for_task_completion(job.task_id)
		job.task_id = -1
	_inflight.clear()


func _threads_ok() -> bool:
	return OS.has_feature("threads") and Config.data.threaded_chunk_build


func _max_builds() -> int:
	if _prefilling:
		return OS.get_processor_count()
	return Config.data.chunk_build_tasks_web if OS.has_feature("web") else Config.data.chunk_build_tasks_desktop


# Answered from the loaded chunk under the point when there is one: cheap, and exactly the
# surface that is drawn. Only falls back to the baked heights where nothing is loaded.
func height_at(x: float, z: float) -> float:
	var t := _tile_of(Vector2(x, z))
	var ts: TileState = _tiles.get(t)
	if ts != null and not ts.near_heights.is_empty():
		return _mesh_height(ts.near_heights, settings.near_stride_m, 1, Vector2(t) * settings.near_tile_m, settings.near_tile_m, x, z)
	var coord := _chunk_of(Vector2(x, z))
	var st: ChunkState = _chunks.get(coord)
	var o := Vector2(coord) * settings.chunk_m
	if st != null:
		if not st.mid_heights.is_empty():
			return _mesh_height(st.mid_heights, settings.mid_stride_m, 1, o, settings.chunk_m, x, z)
		if not st.far_heights.is_empty():
			return _mesh_height(st.far_heights, settings.far_stride_m, 0, o, settings.chunk_m, x, z)
	return bake.height(x, z)


# Height on a square's grid (corner `origin`, side `size`), interpolated across the same two
# triangles per cell the mesh uses.
func _mesh_height(heights: PackedFloat32Array, stride: float, halo: int, origin: Vector2, size: float, x: float, z: float) -> float:
	var n := int(size / stride) + 1
	var m := n + 2 * halo
	var lx := (x - origin.x) / stride
	var lz := (z - origin.y) / stride
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


func surface_at(x: float, z: float) -> Vector2:
	return bake.surface_at(x, z)


func road_pose(p: Vector2, facing: Vector3) -> Transform3D:
	return bake.road_pose(p, facing, height_at)


func spawn_pose() -> Transform3D:
	return bake.spawn_pose(height_at)


func budget_us(frame_s: float) -> int:
	var floor_s := minf(frame_s, 1.0 / maxf(settings.budget_floor_fps, 1.0))
	return maxi(int(floor_s * 1e6 * settings.budget_min_fraction), int(spare_us * settings.budget_fraction))


# The ground queue first, then cover tiles from whatever the frame budget has left.
func _process(delta: float) -> void:
	if focus == null:
		return
	var start := Time.get_ticks_usec()
	_plan_timer -= delta
	if _chunk_of(_focus_xz()) != _plan_coord or _plan_timer <= 0.0:
		_plan()
	_guard_collision()
	_count_near_miss()
	var deadline := start + budget_us(delta)
	_run_queue(deadline)
	var mid := Time.get_ticks_usec()
	PerfLog.track(&"terrain_streamer", mid - start)
	cover.stream(_focus_xz(), deadline, _brush())
	PerfLog.track(&"ground_cover", Time.get_ticks_usec() - mid)


## Changes the mid and far detail rings live. A shrink frees what now lies outside them at once,
## rather than when the car next drives away, so the saving shows straight away.
func apply_rings(mid_radius: float, far_radius: int) -> void:
	var shrink := far_radius < settings.far_radius or mid_radius < settings.mid_radius
	settings.mid_radius = mid_radius
	settings.far_radius = far_radius
	_plan_timer = 0.0
	if not shrink or focus == null:
		return
	var here := _focus_xz()
	var centre := _chunk_of(here)
	var cm := settings.chunk_m
	var vel := Vector2.ZERO
	if focus is RigidBody3D:
		var v := (focus as RigidBody3D).linear_velocity
		vel = Vector2(v.x, v.z)
	var ahead := here + vel * 1.5
	for coord: Vector2i in _chunks.keys():
		var off := coord - centre
		var mid := (Vector2(coord) + Vector2(0.5, 0.5)) * cm
		if maxi(absi(off.x), absi(off.y)) > far_radius + 1:
			_drop_chunk(coord, _chunks[coord])
		elif minf(squashed_distance(mid - here, vel), squashed_distance(mid - ahead, vel)) / cm > mid_radius + 0.75:
			_drop_mid(_chunks[coord])


func _count_near_miss() -> void:
	if not focus is RigidBody3D:
		return
	var t := _tile_of(_focus_xz())
	if t == _miss_tile:
		return
	_miss_tile = t
	var ts: TileState = _tiles.get(t)
	if not _prefilling and (ts == null or ts.near_mesh == null):
		stat_near_misses += 1


## True while some near tile on the car's path would be reached before it can be built at this
## device's pace; the queue then runs nothing but collision and those tiles.
func near_overdue() -> bool:
	return _path_due(near_build_s * NEAR_OVERDUE_FACTOR)


# Some unbuilt near tile on the car's path is due within `within_s` seconds.
func _path_due(within_s: float) -> bool:
	var since_s := (Time.get_ticks_usec() - _plan_us) / 1e6
	for list: Array[ChunkJob] in [_queue, _inflight]:
		for job in list:
			if job.tile and not job.with_collision and not job.cancelled and job.stage != Stage.DONE \
					and job.eta_s - since_s < within_s:
				return true
	return false


# Build everything the planner wants with no budget: used once at boot, behind the spawn.
func prefill() -> void:
	_plan()
	_run_all()


func _run_all() -> void:
	var deadline := Time.get_ticks_usec() + 60_000_000
	_run_queue(deadline)
	while (not _queue.is_empty() or not _inflight.is_empty()) and Time.get_ticks_usec() < deadline:
		OS.delay_usec(200)
		_run_queue(deadline)


# prefill() in slices of prefill_slice_ms with a frame between, so the loading screen keeps drawing; then every cover
# tile in reach, so the spawn shows cover from its first frame.
func prefill_async() -> void:
	_plan()
	_prefilling = true
	while not _queue.is_empty() or not _inflight.is_empty():
		var deadline := Time.get_ticks_usec() + int(settings.prefill_slice_ms * 1000.0)
		_run_queue(deadline)
		while not _inflight.is_empty() and Time.get_ticks_usec() < deadline:
			OS.delay_usec(200)
			_run_queue(deadline)
		await get_tree().process_frame
	_prefilling = false
	cover.max_inflight = OS.get_processor_count()
	while focus != null and (not cover.missing(_focus_xz()).is_empty() or cover.pending() > 0):
		var deadline := Time.get_ticks_usec() + int(settings.prefill_slice_ms * 1000.0)
		cover.stream(_focus_xz(), deadline, _brush())
		while cover.pending() > 0 and Time.get_ticks_usec() < deadline:
			OS.delay_usec(200)
			cover.stream(_focus_xz(), deadline, _brush())
		await get_tree().process_frame
	cover.max_inflight = GroundCover.MAX_INFLIGHT


func _brush() -> Node3D:
	return brush if is_instance_valid(brush) else focus


# The jobs due now by what they build, for the benchmark report.
func due_by_kind() -> Dictionary:
	var out := {"collision": 0, "near": 0, "mid": 0, "far": 0, "horizon": 0}
	for job in _queue:
		if job.cancelled or job.stage == Stage.DONE:
			continue
		var kind := "far"
		if job.tile and job.stage == Stage.COLLIDE:
			kind = "collision"
		elif job.level == Level.NEAR:
			kind = "near"
		elif job.level == Level.MID:
			kind = "mid"
		elif job.level == Level.HORIZON:
			kind = "horizon"
		out[kind] += 1
	return out


func chunk_counts() -> Vector3i:
	var c := Vector3i.ZERO
	for st: ChunkState in _chunks.values():
		c.x += int(st.mid_mesh != null)
		c.y += int(st.far_mesh != null)
	for ts: TileState in _tiles.values():
		c.z += int(ts.body != null)
	return c


func has_collision_at(x: float, z: float) -> bool:
	var ts: TileState = _tiles.get(_tile_of(Vector2(x, z)))
	return ts != null and ts.body != null


func _run_queue(deadline: int) -> void:
	_ran_this_frame = false
	_poll_builds()
	for coord: Vector2i in _holes_due.keys():
		if not _atomic("holes", deadline, _cut_holes.bind(coord)):
			return
		_holes_due.erase(coord)
	var overdue := near_overdue() and _starved < MAX_STARVED_FRAMES
	_starved = _starved + 1 if overdue else 0
	var path_waiting := overdue or _path_due(_near_lead_s())
	for b: Vector2i in _horizon_due.keys():
		if overdue:
			break
		if not _atomic("horizon_holes", deadline, _cut_horizon.bind(b)):
			return
		_horizon_due.erase(b)
	# Far and horizon jobs whose next unit didn't fit in what's left of this frame. Smaller
	# work behind them in that same tier may still fit, so it runs instead of the frame's budget
	# going unused; anything ahead of that tier (collision, near and mid meshes) still stops the
	# frame, so it is never overtaken.
	var blocked := {}
	var i := 0
	while i < _queue.size():
		var job := _queue[i]
		if job.cancelled or job.stage == Stage.DONE:
			_queue.remove_at(i)
			continue
		if blocked.has(job) or job.task_id >= 0 or (overdue and job.priority > STARVE_ABOVE):
			i += 1
			continue
		var threaded := job.stage <= Stage.HEIGHTS and job.cursor == 0 and _threads_ok()
		var stop := Stage.HEIGHTS if threaded else Stage.DONE
		if job.started_us == 0 and not threaded:
			job.started_us = Time.get_ticks_usec()
		if not _step(job, deadline, stop):
			if job.priority < SKIPPABLE_PRIORITY:
				return
			blocked[job] = true
			i += 1
			continue
		if threaded and job.stage == Stage.HEIGHTS:
			var slots := _max_builds()
			if path_waiting and job.priority > STARVE_ABOVE and slots > 1:
				slots -= 1  # one build thread is kept free for collision and the tiles on the car's path
			if _inflight.size() < slots:
				_dispatch_build(job)
			i += 1
			continue
		if job.stage == Stage.DONE:
			_queue.remove_at(i)
		if Time.get_ticks_usec() >= deadline:
			return


func _dispatch_build(job: ChunkJob) -> void:
	_begin_pack(job)
	if job.tile:
		job.stitch = _stitch_mask(job.coord)
		job.started_us = Time.get_ticks_usec()
	# Godot runs low-priority tasks on under a third of its threads; the car's path and collision can't wait behind grass.
	var urgent := job.priority <= STARVE_ABOVE
	job.task_id = WorkerThreadPool.add_task(_build_job.bind(job), urgent, "chunk build")
	_inflight.append(job)


func _build_job(job: ChunkJob) -> void:
	_compute_heights(job)
	if job.cancelled:
		return
	_start_arrays(job)
	_compute_arrays(job)
	if not job.cancelled:
		_finish_arrays(job)


# Hands every finished build back to the queue (to UPLOAD), or drops it if it was cancelled meanwhile.
func _poll_builds() -> void:
	var i := 0
	while i < _inflight.size():
		var job := _inflight[i]
		if WorkerThreadPool.is_task_completed(job.task_id):
			_collect_build(job)
		else:
			i += 1


func _collect_build(job: ChunkJob) -> void:
	WorkerThreadPool.wait_for_task_completion(job.task_id)
	job.task_id = -1
	_inflight.erase(job)
	if job.cancelled:
		job.stage = Stage.DONE


# Queue order, lowest first (d = distance from the car in chunks, at most far_radius + 0.5):
#   collision        d - 2000   (d - 3000 when rushed)
#   near, on path    -1500 + seconds until the car gets there (NEAR_AHEAD_PRIORITY)
#   mid + collision  d - 1000
#   near mesh        d - 200
#   mid mesh         d - 100
#   far mesh, hole   d - 50 - far_lead_chunks         (no mid mesh or mid build: a gap in the horizon)
#   far mesh, hidden d                                (under a finer mesh, or one on its way)
const FAR_GAP_PRIORITY := -50.0


# Near tiles the car reaches within near_lead_s outrank everything but collision, so full detail is
# always under the wheels even if the ground round about has to wait.
const NEAR_AHEAD_PRIORITY := -1500.0


const NEAR_OVERDUE_FACTOR := 1.5


# After this many frames of running only the car's path, one frame lets the rest of the queue run.
const MAX_STARVED_FRAMES := 30


# A near tile stays built this long after the car's path last wanted it, so steering doesn't churn it.
const NEAR_WANT_HOLD_US := 1_000_000


# Work at or past this priority (side near tiles, mid meshes, far, horizon) waits while a
# tile on the car's path is overdue, and leaves one build thread free.
const STARVE_ABOVE := -900.0


# A near tile this close to the car counts as under it.
const NEAR_TOUCH_M := 4.0


# The strip ahead narrows from a tile each side of the path to half a tile as the car reaches this speed.
const NARROW_AT_MPS := 40.0


# Jobs from here on (far meshes and the horizon) may be passed over when blocked; see _run_queue.
const SKIPPABLE_PRIORITY := FAR_GAP_PRIORITY - 30.0


# How far (chunk centre to car, in chunks) a chunk's collision is kept once it leaves the 2×2
# collision block. A block chunk's centre is at most √2 chunks from the car.
const NEAR_KEEP_CHUNKS := 1.6


# Near detail reaches this far from the car (nearest point of a tile), and a tile is kept this much further.
const NEAR_REACH_M := 70.0


const NEAR_KEEP_MARGIN_M := 16.0


# A near tile's edge against mid ground is blended to the mid line over this many metres.
const STITCH_BLEND_M := 3.0


# The horizon's skirts (block edges and round its cut-out cells): deeper than far's 12 m, since a
# horizon quad's straight edge can stray further from the far mesh's 16 m samples beside it.
const HORIZON_SKIRT_M := 30.0


func _far_priority(st: ChunkState, d: float) -> float:
	if st.mid_mesh != null or st.mid_job != null:
		return d
	return d + FAR_GAP_PRIORITY - settings.far_lead_chunks


# The safety net under the car: if the tile under it, or the one it will be over in
# `collision_rush_s`, has no collision yet, build that collision now, whatever the budget. The
# planner and the queue order are meant to keep this from ever firing; when the car outruns
# them anyway (a very fast car, a teleport, a stall), a one-off hitch beats a fall through the
# world.
func _guard_collision() -> void:
	if focus == null:
		return
	var here := _focus_xz()
	_rush_collision(_tile_of(here))
	if focus is RigidBody3D:
		var v := (focus as RigidBody3D).linear_velocity
		_rush_collision(_tile_of(here + Vector2(v.x, v.z) * settings.collision_rush_s))


# Build tile `t`'s collision at once, with no budget: straight from a grid already there, else by
# running its chunk's mid build.
# Returns true when it had to.
func _rush_collision(t: Vector2i) -> bool:
	var ts := _tile(t)
	if ts.body != null:
		return false
	var st := _chunk(_chunk_of_tile(t))
	if not ts.near_heights.is_empty() or not st.mid_heights.is_empty():
		_collide_tile(t)
		if ts.col_job != null:
			ts.col_job.cancelled = true
			ts.col_job = null
		return true
	if st.mid_job == null:
		st.mid_job = _new_job(st.coord, Level.MID, true)
	var job := st.mid_job
	if job.task_id >= 0:
		_collect_build(job)
	job.with_collision = true
	job.priority = -3000.0
	var saved := _ran_this_frame
	_ran_this_frame = false
	_step(job, Time.get_ticks_usec() + 60_000_000, Stage.DONE)
	_ran_this_frame = saved
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
				if not _atomic("attach_%d" % job.level, deadline, _attach.bind(job)):
					return false
			Stage.COLLIDE:
				if not _atomic("collide", deadline, _collide.bind(job)):
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
	work.call()
	_est[kind] = lerpf(est, float(Time.get_ticks_usec() - now), 0.25)
	_ran_this_frame = true
	return true


func _prep(job: ChunkJob) -> void:
	job.halo = 0 if job.level == Level.FAR else 1
	var m := job.n + 2 * job.halo
	job.heights.resize(m * m)
	job.cursor = 0
	job.stage = Stage.HEIGHTS


func _heights(job: ChunkJob, deadline: int) -> bool:
	var m := job.n + 2 * job.halo
	var total := m * m
	var done := 0
	var peak: float = _peak_us["heights"]
	var t_prev := Time.get_ticks_usec()
	while job.cursor < total:
		# Never start a sample that would not fit, judged by the dearest recent sample.
		if (_ran_this_frame or done > 0) and t_prev + peak >= deadline:
			break
		job.heights[job.cursor] = _height_for(job, job.cursor)
		job.cursor += 1
		done += 1
		var t_now := Time.get_ticks_usec()
		peak = maxf(float(t_now - t_prev), peak * PEAK_DECAY)
		t_prev = t_now
	_peak_us["heights"] = peak
	_ran_this_frame = _ran_this_frame or done > 0
	if job.cursor < total:
		return false
	_start_arrays(job)
	return true


func _height_for(job: ChunkJob, k: int) -> float:
	var m := job.n + 2 * job.halo
	var gx := k % m - job.halo
	@warning_ignore("integer_division")
	var gz := k / m - job.halo
	return bake.height(job.origin.x + gx * job.stride, job.origin.y + gz * job.stride)


func _compute_heights(job: ChunkJob) -> void:
	var m := job.n + 2 * job.halo
	for row in m:
		if job.cancelled:
			return
		for col in m:
			var k := row * m + col
			job.heights[k] = _height_for(job, k)
	job.cursor = m * m


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
	var done := 0
	_begin_pack(job)
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
		_pack_at(job, job.cursor)
		job.cursor += 1
		done += 1
	_peak_us["arrays"] = peak
	_ran_this_frame = _ran_this_frame or done > 0
	if job.cursor < n * n:
		return false
	if job.tile:
		job.stitch = _stitch_mask(job.coord)
	_finish_arrays(job)
	return true


func _pack_at(job: ChunkJob, i: int) -> void:
	var n := job.n
	var hl := job.halo
	var m := n + 2 * hl
	var s := job.stride
	var gx := i % n
	@warning_ignore("integer_division")
	var gz := i / n
	var row := (gz + hl) * m
	var h := job.heights[row + gx + hl]
	# central differences, falling back to one-sided at an edge with no border sample
	var xl := maxi(gx - 1, -hl)
	var xr := mini(gx + 1, n - 1 + hl)
	var zd := maxi(gz - 1, -hl)
	var zu := mini(gz + 1, n - 1 + hl)
	var dhx := (job.heights[row + xr + hl] - job.heights[row + xl + hl]) / ((xr - xl) * s)
	var dhz := (job.heights[(zu + hl) * m + gx + hl] - job.heights[(zd + hl) * m + gx + hl]) / ((zu - zd) * s)
	var normal := Vector3(-dhx, 1.0, -dhz).normalized()
	job.verts[i] = Vector3(gx * s, h, gz * s)
	_pack_vertex(job, i, job.origin.x + gx * s, job.origin.y + gz * s, normal)


func _compute_arrays(job: ChunkJob) -> void:
	var n := job.n
	for gz in n:
		if job.cancelled:
			return
		for gx in n:
			_pack_at(job, gz * n + gx)
	job.cursor = n * n


# Skirts: a strip hanging below the edge, so neighbouring chunks at different detail never
# show a crack between them. `job.stitch` is already set.
func _finish_arrays(job: ChunkJob) -> void:
	var n := job.n
	if job.stitch != 0:
		_stitch(job.verts, job.heights, n, job.halo, job.stride, job.stitch)
	var drop: float = [3.0, 6.0, 12.0, HORIZON_SKIRT_M][job.level]
	var perim := _perimeter(n)
	for k in perim.size():
		var src := perim[k]
		job.verts[n * n + k] = job.verts[src] - Vector3(0.0, drop, 0.0)
		job.colors[n * n + k] = job.colors[src]
		job.uvs[n * n + k] = job.uvs[src]
		job.uv2s[n * n + k] = _skirt_uv2(job.uv2s[src])
	job.stage = Stage.UPLOAD


# A skirt vertex is drawn flat: UV2.x = -1 tells the ground shader so.
func _skirt_uv2(uv2: Vector2) -> Vector2:
	return Vector2(-1.0, uv2.y)


# Bit per tile edge (west, east, south, north) set where the neighbouring tile has no near mesh coming, so mid ground meets it.
func _stitch_mask(t: Vector2i) -> int:
	var mask := 0
	for e in 4:
		var nb: TileState = _tiles.get(t + [Vector2i(-1, 0), Vector2i(1, 0), Vector2i(0, -1), Vector2i(0, 1)][e])
		if nb == null or (nb.near_mesh == null and nb.near_job == null):
			mask |= 1 << e
	return mask


# Pulls a near tile's edge vertices onto the straight line between the mid grid's samples (every
# `mid_stride_m`), fading the change out over STITCH_BLEND_M, so no step shows against mid ground.
# Only the drawn vertices move: collision keeps the true heights.
func _stitch(verts: PackedVector3Array, heights: PackedFloat32Array, n: int, hl: int, stride: float, mask: int) -> void:
	var m := n + 2 * hl
	var r := maxi(1, roundi(settings.mid_stride_m / stride))
	var depth := int(STITCH_BLEND_M / stride)
	for e in 4:
		if mask & (1 << e) == 0:
			continue
		var edge := PackedFloat32Array()
		for j in n:
			var c := Vector2i(0 if e == 0 else n - 1, j) if e < 2 else Vector2i(j, 0 if e == 2 else n - 1)
			edge.append(heights[(c.y + hl) * m + c.x + hl])
		for j in n:
			var j0 := j / r * r
			var j1 := mini(j0 + r, n - 1)
			var delta := lerpf(edge[j0], edge[j1], float(j - j0) / r) - edge[j]
			if delta == 0.0:
				continue
			for d in depth:
				var w := 1.0 - d * stride / STITCH_BLEND_M
				var c := Vector2i(d if e == 0 else n - 1 - d, j) if e < 2 else Vector2i(j, d if e == 2 else n - 1 - d)
				verts[c.y * n + c.x].y += w * delta


# A neighbour's near mesh came or went: re-stitch the drawn tile's edge bands in place, from its
# kept true heights, rebuilding only the mesh (no job, no collision change) and only if a vertex moved.
func _restitch(ts: TileState, mask: int) -> void:
	var verts: PackedVector3Array = ts.near_arrays[0]
	var n := int(settings.near_tile_m / settings.near_stride_m) + 1
	var hl := (roundi(sqrt(ts.near_heights.size())) - n) / 2
	var m := n + 2 * hl
	var depth := int(STITCH_BLEND_M / settings.near_stride_m)
	var moved := false
	var before := verts.duplicate()
	for e in 4:
		for j in n:
			for d in depth:
				var c := Vector2i(d if e == 0 else n - 1 - d, j) if e < 2 else Vector2i(j, d if e == 2 else n - 1 - d)
				verts[c.y * n + c.x].y = ts.near_heights[(c.y + hl) * m + c.x + hl]
	_stitch(verts, ts.near_heights, n, hl, settings.near_stride_m, mask)
	var perim := _perimeter(n)
	for k in perim.size():
		verts[n * n + k].y = verts[perim[k]].y - 3.0
	for i in verts.size():
		if absf(verts[i].y - before[i].y) > 0.01:
			moved = true
			break
	ts.stitch = mask
	if moved:
		ts.near_arrays[0] = verts
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = verts
		arrays[Mesh.ARRAY_COLOR] = ts.near_arrays[1]
		arrays[Mesh.ARRAY_TEX_UV] = ts.near_arrays[2]
		arrays[Mesh.ARRAY_TEX_UV2] = ts.near_arrays[3]
		arrays[Mesh.ARRAY_INDEX] = _indices_for(n)
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		ts.near_mesh.mesh = mesh


# Once per _arrays call: values _pack_vertex reuses for every vertex.
func _begin_pack(job: ChunkJob) -> void:
	job.ao_bush = Config.data.level_ao_bush_ground
	job.bank_m = Config.data.snow_bank_width_m


# Sun shading and the cover's ground tint go into COLOR.rgb, the ground's uprightness (normal.y) into COLOR.a for the rock blend, the biome's snow into UV; the road and grass boost are painted per pixel from the bake's textures.
func _pack_vertex(job: ChunkJob, i: int, px: float, pz: float, normal: Vector3) -> void:
	var light := 0.55 + 0.45 * maxf(normal.dot(_sun_dir), 0.0)
	var tint := GroundCover.ground_multiplier(_cover, int(bake.size), _cover_tints, px, pz)
	# UV is (snow, lift): how white the ground is drawn, and how much of the snow depth it is drawn raised off the road.
	var snow := snow_at(px, pz)
	light *= lerpf(GroundCover.bush_shade(_cover, int(bake.size), _bush_ids, px, pz, job.ao_bush), 1.0, snow)  # snow covers the bushes' shade
	var lift := 0.0
	if snow > 0.0:
		tint = tint.lerp(Color.WHITE, snow)
		var near := bake.road_nearest(px, pz)
		lift = snow * smoothstep(near.z + 0.5, near.z + 0.5 + job.bank_m, near.x)
	job.uvs[i] = Vector2(snow, lift)
	job.colors[i] = Color(light * tint.r, light * tint.g, light * tint.b, normal.y)


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
	if job.level == Level.HORIZON:
		_attach_horizon(job)
		return
	var st: ChunkState = null if job.tile else _chunks.get(job.coord)
	var ts: TileState = _tiles.get(job.coord) if job.tile else null
	if st == null and ts == null:
		job.stage = Stage.DONE
		return
	var mi := MeshInstance3D.new()
	mi.mesh = job.mesh
	mi.material_override = material
	mi.position = Vector3(job.origin.x, 0.0, job.origin.y)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF  # the ground barely shadows itself in this look, and it was a second draw call per chunk
	mi.add_to_group(&"id_terrain")  # outlines treat all ground as one surface, with no line at chunk seams
	add_child(mi)
	var arrays := [job.verts, job.colors, job.uvs, job.uv2s]
	match job.level:
		Level.NEAR:
			if ts.near_mesh != null:
				ts.near_mesh.queue_free()
			ts.near_mesh = mi
			ts.stitch = job.stitch
			ts.near_arrays = [job.verts, job.colors, job.uvs, job.uv2s]
			ts.near_heights = job.heights
			ts.near_job = null
			if job.started_us > 0 and job.eta_s <= _near_lead_s():
				var took := minf((Time.get_ticks_usec() - job.started_us) / 1e6, _near_lead_s())
				near_build_s = lerpf(near_build_s, took, 0.2)
			# collision built from the coarser mid grid is redone from this one
			job.with_collision = ts.body != null and ts.body_level != Level.NEAR
			_cut_holes(_chunk_of_tile(job.coord))
		Level.MID:
			st.mid_mesh = mi
			st.mid_heights = job.heights
			st.mid_arrays = arrays
			st.mid_job = null
			_horizon_changed(job.coord)
		Level.FAR:
			st.far_mesh = mi
			st.far_heights = job.heights
			st.far_arrays = arrays
			st.far_job = null
			_horizon_changed(job.coord)
	if st != null:
		_show_finest(st)
		# The mesh just uploaded has no holes: only recut it if near tiles really cover the chunk.
		if mi == (st.mid_mesh if st.mid_mesh != null else st.far_mesh):
			st.hole_mesh = mi
			st.hole_mask = 0
		_cut_holes(job.coord)
	job.verts = PackedVector3Array(); job.colors = PackedColorArray(); job.uvs = PackedVector2Array()
	job.uv2s = PackedVector2Array()
	job.stage = Stage.COLLIDE if job.with_collision else Stage.DONE


# Only a chunk's finer built mesh is drawn (near tiles cut holes in it instead, see _cut_holes).
func _show_finest(st: ChunkState) -> void:
	if st.far_mesh != null:
		st.far_mesh.visible = st.mid_mesh == null


# Rebuild the drawn coarse mesh of chunk `coord` (mid, else far) leaving out the quarters its
# near tiles cover, with a skirt round each hole so no crack shows against the tile. The two
# grids differ slightly in height, so drawing both in one place would flicker.
func _cut_holes(coord: Vector2i) -> void:
	var st: ChunkState = _chunks.get(coord)
	if st == null:
		return
	var mi := st.mid_mesh if st.mid_mesh != null else st.far_mesh
	if mi == null:
		return
	var mask := 0
	var tpc := _tiles_per_chunk()
	for i in tpc * tpc:
		@warning_ignore("integer_division")
		var ts: TileState = _tiles.get(coord * tpc + Vector2i(i % tpc, i / tpc))
		if ts != null and ts.near_mesh != null:
			mask |= 1 << i
	if mi == st.hole_mesh and mask == st.hole_mask:
		return
	st.hole_mesh = mi
	st.hole_mask = mask
	var mid := mi == st.mid_mesh
	var stride := settings.mid_stride_m if mid else settings.far_stride_m
	mi.mesh = _coarse_mesh(st.mid_arrays if mid else st.far_arrays, int(settings.chunk_m / stride) + 1,
		int(settings.near_tile_m / stride), tpc, mask, 6.0 if mid else 12.0)


# Whether grid cell (cx, cz) of a chunk lies in one of the tiles set in `mask`.
@warning_ignore("integer_division")
static func _covered(mask: int, cx: int, cz: int, cells_per_tile: int, tpc: int) -> bool:
	return (mask >> ((cz / cells_per_tile) * tpc + cx / cells_per_tile)) & 1 == 1


# `cells` (one byte per grid cell, 1 = covered) replaces `mask` when given: a mask holds at most
# 63 cells, and a horizon block can have more.
func _coarse_mesh(src: Array, n: int, cells_per_tile: int, tpc: int, mask: int, drop: float,
		cells := PackedByteArray()) -> ArrayMesh:
	var verts: PackedVector3Array = src[0]
	var colors: PackedColorArray = src[1]
	var uvs: PackedVector2Array = src[2]
	var uv2s: PackedVector2Array = src[3]
	var idx := _indices_for(n)
	if mask != 0 or not cells.is_empty():
		# Skirts add vertices, and these arrays are shared with the chunk's stored copy.
		verts = verts.duplicate()
		colors = colors.duplicate()
		uvs = uvs.duplicate()
		uv2s = uv2s.duplicate()
		var covered := func(cx: int, cz: int) -> bool: return _covered(mask, cx, cz, cells_per_tile, tpc)
		if not cells.is_empty():
			covered = func(cx: int, cz: int) -> bool: return cells[cz * (n - 1) + cx] == 1
		idx = PackedInt32Array()
		for zi in n - 1:
			for xi in n - 1:
				if covered.call(xi, zi):
					continue
				var a := zi * n + xi
				idx.append_array([a, a + 1, a + n, a + 1, a + n + 1, a + n])
				# an edge shared with a covered cell hangs a skirt into the hole
				for e in [[xi + 1, zi, xi + 1, zi + 1, xi + 1 < n - 1 and covered.call(xi + 1, zi)],
						[xi, zi, xi, zi + 1, xi > 0 and covered.call(xi - 1, zi)],
						[xi, zi + 1, xi + 1, zi + 1, zi + 1 < n - 1 and covered.call(xi, zi + 1)],
						[xi, zi, xi + 1, zi, zi > 0 and covered.call(xi, zi - 1)]]:
					if not e[4]:
						continue
					var t0: int = e[1] * n + e[0]
					var t1: int = e[3] * n + e[2]
					var s0 := verts.size()
					for v in [t0, t1]:
						verts.append(verts[v] - Vector3(0.0, drop, 0.0))
						colors.append(colors[v])
						uvs.append(uvs[v])
						uv2s.append(_skirt_uv2(uv2s[v]))
					idx.append_array([t0, t1, s0, t1, s0 + 1, s0, t0, s0, t1, t1, s0, s0 + 1])
		var perim := _perimeter(n)
		for k in perim.size():
			var t0 := perim[k]
			var t1 := perim[(k + 1) % perim.size()]
			if covered.call(_edge_cell(n, t0, t1).x, _edge_cell(n, t0, t1).y):
				continue
			var s0 := n * n + k
			var s1 := n * n + (k + 1) % perim.size()
			idx.append_array([t0, t1, s0, t1, s1, s0, t0, s0, t1, t1, s0, s1])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_TEX_UV2] = uv2s
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	if not idx.is_empty():
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


# A tile job builds its own collision; a chunk's mid build builds its tiles'.
func _collide(job: ChunkJob) -> void:
	job.stage = Stage.DONE
	if job.tile:
		var ts: TileState = _tiles.get(job.coord)
		if ts != null:
			ts.col_job = null
		_collide_tile(job.coord)
	else:
		for t in _tiles_of_chunk(job.coord):
			_collide_tile(t)


# Tile `t`'s collision from the finest grid there, replacing collision built from a coarser one.
func _collide_tile(t: Vector2i) -> void:
	var ts := _tile(t)
	var heights := ts.near_heights
	var stride := settings.near_stride_m
	var level := Level.NEAR
	var grid_n := int(settings.near_tile_m / stride) + 1
	var off := Vector2i.ZERO
	if heights.is_empty():
		var st: ChunkState = _chunks.get(_chunk_of_tile(t))
		if st == null or st.mid_heights.is_empty():
			return
		heights = st.mid_heights
		stride = settings.mid_stride_m
		level = Level.MID
		grid_n = int(settings.chunk_m / stride) + 1
		off = (t - _chunk_of_tile(t) * _tiles_per_chunk()) * int(settings.near_tile_m / stride)
	if ts.body != null and ts.body_level <= level:
		return
	var n := int(settings.near_tile_m / stride) + 1
	var m := grid_n + 2
	var data := PackedFloat32Array()
	data.resize(n * n)
	for gz in n:
		for gx in n:
			data[gz * n + gx] = heights[(off.y + gz + 1) * m + off.x + gx + 1]
	var shape := HeightMapShape3D.new()
	shape.map_width = n
	shape.map_depth = n
	shape.map_data = data
	var cs := CollisionShape3D.new()
	cs.shape = shape
	# HeightMapShape3D has unit cells, so the shape is scaled to the vertex spacing.
	cs.scale = Vector3(stride, 1.0, stride)
	var body := StaticBody3D.new()
	var half := settings.near_tile_m * 0.5
	body.position = Vector3(t.x * settings.near_tile_m + half, 0.0, t.y * settings.near_tile_m + half)
	body.add_child(cs)
	add_child(body)
	if ts.body != null:
		ts.body.queue_free()
	ts.body = body
	ts.body_level = level


func _focus_xz() -> Vector2:
	return Vector2(focus.global_position.x, focus.global_position.z)


func _chunk_of(p: Vector2) -> Vector2i:
	return Vector2i(floori(p.x / settings.chunk_m), floori(p.y / settings.chunk_m))


func _tile_of(p: Vector2) -> Vector2i:
	return Vector2i(floori(p.x / settings.near_tile_m), floori(p.y / settings.near_tile_m))


func _tiles_per_chunk() -> int:
	return roundi(settings.chunk_m / settings.near_tile_m)


func _chunk_of_tile(t: Vector2i) -> Vector2i:
	var tpc := _tiles_per_chunk()
	return Vector2i(floori(float(t.x) / tpc), floori(float(t.y) / tpc))


func _tiles_of_chunk(c: Vector2i) -> Array[Vector2i]:
	var tpc := _tiles_per_chunk()
	var out: Array[Vector2i] = []
	for i in tpc * tpc:
		@warning_ignore("integer_division")
		out.append(c * tpc + Vector2i(i % tpc, i / tpc))
	return out


func _chunk(c: Vector2i) -> ChunkState:
	var st: ChunkState = _chunks.get(c)
	if st == null:
		st = ChunkState.new()
		st.coord = c
		_chunks[c] = st
	return st


func _tile(t: Vector2i) -> TileState:
	var ts: TileState = _tiles.get(t)
	if ts == null:
		ts = TileState.new()
		_tiles[t] = ts
	return ts


# Decide what should exist around the car and queue jobs for what is missing, nearest first.
# Distance is measured from both the car and where it will be in a second and a half, so the
# road ahead fills before the road behind.
func _plan() -> void:
	_plan_timer = 0.25
	var here := _focus_xz()
	var ahead := here
	var vel := Vector2.ZERO
	if focus is RigidBody3D:
		var v := (focus as RigidBody3D).linear_velocity
		vel = Vector2(v.x, v.z)
		ahead += vel * 1.5
	_plan_coord = _chunk_of(here)
	var cm := settings.chunk_m
	var far_r := settings.far_radius
	var col_block := collision_block_of(here)
	for coord: Vector2i in _chunks.keys():
		var off := coord - _plan_coord
		if maxi(absi(off.x), absi(off.y)) > far_r + 2:
			_drop_chunk(coord, _chunks[coord])
	for dz in range(-far_r - 2, far_r + 3):
		for dx in range(-far_r - 2, far_r + 3):
			var coord := _plan_coord + Vector2i(dx, dz)
			var center := (Vector2(coord) + Vector2(0.5, 0.5)) * cm
			var d := minf(center.distance_to(here), center.distance_to(ahead)) / cm
			var d_mid := minf(squashed_distance(center - here, vel), squashed_distance(center - ahead, vel)) / cm
			var st: ChunkState = _chunks.get(coord)
			# Shed full detail and collision first, before the horizon test below: a chunk can be
			# past the horizon yet still inside the drop square (a jump of a few hundred metres:
			# a teleport), and it must not keep its near mesh, collision or queued near / collision
			# jobs at their old priorities (which a prefill would then run, lengthening the hitch).
			if st != null:
				# collision keeps a little past its block, so a car wavering on a chunk's middle
				# line doesn't rebuild the same collision over and over
				if center.distance_to(here) / cm > NEAR_KEEP_CHUNKS:
					_drop_collision(st)
				if d_mid > settings.mid_radius + 1.5:
					_drop_mid(st)
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
				st = _chunk(coord)
			var want_mid := d_mid <= settings.mid_radius + 0.75
			var want_col := col_block.has_point(coord)
			if st.far_mesh == null and st.far_job == null:
				st.far_job = _new_job(coord, Level.FAR, false)
			if want_mid:
				if st.mid_mesh == null and st.mid_job == null:
					st.mid_job = _new_job(coord, Level.MID, want_col)
				if st.mid_job != null:
					st.mid_job.with_collision = st.mid_job.with_collision or want_col
					st.mid_job.priority = d - (1000.0 if want_col else 100.0)
					st.mid_job.dist = d
			elif st.mid_job != null:
				# In the hysteresis band (no longer wanted, not yet dropped): an unfinished near
				# build drops to the near-mesh tier rather than keeping a collision-tier priority.
				st.mid_job.priority = d - 100.0
				st.mid_job.dist = d
			if st.far_job != null:
				st.far_job.priority = _far_priority(st, d)
				st.far_job.dist = d
			if want_col and st.mid_mesh != null:
				for t in _tiles_of_chunk(coord):
					var ts := _tile(t)
					if ts.body == null and ts.col_job == null:
						ts.col_job = _new_job(t, Level.NEAR, true)
						ts.col_job.stage = Stage.COLLIDE
					if ts.col_job != null:
						ts.col_job.priority = d - 2000.0
	# Near tiles: every tile within near_reach() of the car, kept a little past it.
	var tm := settings.near_tile_m
	_plan_us = Time.get_ticks_usec()
	var wanted := wanted_near_tiles(here, vel)
	for t: Vector2i in _tiles.keys():
		var ts: TileState = _tiles[t]
		if wanted.has(t):
			ts.wanted_us = _plan_us
		else:
			var gap := _tile_gap(t, here)
			var held := _plan_us - ts.wanted_us <= NEAR_WANT_HOLD_US and gap <= near_reach() + vel.length() * _near_lead_s() + settings.near_tile_m * 2.0
			if gap > near_reach() + NEAR_KEEP_MARGIN_M and not held:
				_drop_near_tile(t, ts)
		if ts.near_mesh == null and ts.near_job == null and ts.body == null and ts.col_job == null:
			_tiles.erase(t)
	for t: Vector2i in wanted:
		var ts := _tile(t)
		if ts.near_mesh == null and ts.near_job == null:
			ts.near_job = _new_job(t, Level.NEAR, false)
		if ts.near_job != null:
			var eta: float = wanted[t]
			ts.near_job.dist = ((Vector2(t) + Vector2(0.5, 0.5)) * tm).distance_to(here) / cm
			ts.near_job.eta_s = eta
			ts.near_job.priority = NEAR_AHEAD_PRIORITY + eta if eta <= _near_lead_s() else ts.near_job.dist - 200.0
	for t in near_tiles_of(here):
		var ts: TileState = _tiles[t]
		if ts.near_mesh != null and ts.near_job == null and ts.stitch != _stitch_mask(t):
			_restitch(ts, _stitch_mask(t))
	_plan_horizon(here)
	# Cancelled and finished jobs leave now rather than when they reach the head: a queue that
	# never drains (a car outdriving the far ring) would otherwise carry them for ever.
	var live: Array[ChunkJob] = []
	for job in _queue:
		if not job.cancelled and job.stage != Stage.DONE:
			live.append(job)
	_queue = live
	_queue.sort_custom(func(a: ChunkJob, b: ChunkJob) -> bool: return a.priority < b.priority)


func _horizon_blocks() -> int:
	return maxi(settings.horizon_block_chunks, 1)


func _horizon_block_m() -> float:
	return settings.chunk_m * _horizon_blocks()


func horizon_block_of_chunk(coord: Vector2i) -> Vector2i:
	var b := _horizon_blocks()
	return Vector2i(floori(float(coord.x) / b), floori(float(coord.y) / b))


# Chunk `coord` gained or lost its far or mid mesh: its horizon block is recut at the head of the
# next _run_queue, so the two never draw over the same ground.
func _horizon_changed(coord: Vector2i) -> void:
	if not _horizon.is_empty():
		var b := horizon_block_of_chunk(coord)
		if _horizon.has(b):
			_horizon_due[b] = true


# Every block whose nearest point is within horizon_radius_m of the car gets a horizon mesh; a
# block goes again once it is a block further than that. Queued at the block's distance in
# chunks, so a horizon block sits in the far-mesh tier and can be passed over when blocked.
func _plan_horizon(here: Vector2) -> void:
	var r := settings.horizon_radius_m
	if r <= 0.0:
		for b: Vector2i in _horizon.keys():
			_drop_horizon(b)
		return
	var bm := _horizon_block_m()
	var cm := settings.chunk_m
	for b: Vector2i in _horizon.keys():
		if _dist_to_rect(here, Rect2(Vector2(b) * bm, Vector2(bm, bm))) > r + bm:
			_drop_horizon(b)
	var lo := Vector2i(floori((here.x - r) / bm), floori((here.y - r) / bm))
	var hi := Vector2i(floori((here.x + r) / bm), floori((here.y + r) / bm))
	for bz in range(lo.y, hi.y + 1):
		for bx in range(lo.x, hi.x + 1):
			var b := Vector2i(bx, bz)
			var rect := Rect2(Vector2(b) * bm, Vector2(bm, bm))
			if _dist_to_rect(here, rect) > r:
				continue
			var hs: HorizonState = _horizon.get(b)
			if hs == null:
				hs = HorizonState.new()
				_horizon[b] = hs
			if hs.mesh == null and hs.job == null:
				hs.job = _new_job(b, Level.HORIZON, false)
			if hs.job != null:
				hs.job.dist = rect.get_center().distance_to(here) / cm
				hs.job.priority = hs.job.dist


func _attach_horizon(job: ChunkJob) -> void:
	var hs: HorizonState = _horizon.get(job.coord)
	job.stage = Stage.DONE
	if hs == null:
		return
	var mi := MeshInstance3D.new()
	mi.mesh = job.mesh
	mi.material_override = material
	mi.position = Vector3(job.origin.x, 0.0, job.origin.y)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.add_to_group(&"id_terrain")
	add_child(mi)
	hs.mesh = mi
	hs.arrays = [job.verts, job.colors, job.uvs, job.uv2s]
	hs.cut = PackedByteArray()  # the mesh just uploaded is uncut
	hs.job = null
	_cut_horizon(job.coord)
	job.verts = PackedVector3Array(); job.colors = PackedColorArray(); job.uvs = PackedVector2Array()
	job.uv2s = PackedVector2Array()


# The cells of block `b` whose chunk draws its own far or mid mesh: 1 at cz * blocks + cx, or
# empty when there are none.
func horizon_cut(b: Vector2i) -> PackedByteArray:
	var nb := _horizon_blocks()
	var cut := PackedByteArray()
	for i in nb * nb:
		@warning_ignore("integer_division")
		var st: ChunkState = _chunks.get(b * nb + Vector2i(i % nb, i / nb))
		if st != null and (st.far_mesh != null or st.mid_mesh != null):
			if cut.is_empty():
				cut.resize(nb * nb)
			cut[i] = 1
	return cut


# Rebuild block `b`'s drawn mesh leaving out the cells finer meshes cover, with a skirt round each
# hole (the same cut as near tiles make in a coarse mesh, one cell per chunk).
func _cut_horizon(b: Vector2i) -> void:
	var hs: HorizonState = _horizon.get(b)
	if hs == null or hs.mesh == null:
		return
	var cut := horizon_cut(b)
	if cut == hs.cut:
		return
	var nb := _horizon_blocks()
	hs.cut = cut
	# every cell covered: nothing left to draw
	hs.mesh.visible = cut.is_empty() or cut.has(0)
	if hs.mesh.visible:
		hs.mesh.mesh = _coarse_mesh(hs.arrays, nb + 1, 1, nb, 0, HORIZON_SKIRT_M, cut)


func _drop_horizon(b: Vector2i) -> void:
	var hs: HorizonState = _horizon.get(b)
	if hs == null:
		return
	if hs.job != null:
		hs.job.cancelled = true
	if hs.mesh != null:
		hs.mesh.queue_free()
	_horizon.erase(b)
	_horizon_due.erase(b)


# The 2×2 chunks that carry collision: the four round the chunk corner nearest `p`, so the car is
# always at least half a chunk inside the block.
func collision_block_of(p: Vector2) -> Rect2i:
	var corner := Vector2i(roundi(p.x / settings.chunk_m), roundi(p.y / settings.chunk_m))
	return Rect2i(corner - Vector2i.ONE, Vector2i(2, 2))


# How far near (full) detail reaches: NEAR_REACH_M, or out to the whole far ring while full_detail is on.
func near_reach() -> float:
	return settings.far_radius * settings.chunk_m if full_detail else NEAR_REACH_M


func _near_lead_s() -> float:
	return Config.data.adaptive_near_lead_s


## The near tiles wanted now, each with the seconds until the car reaches it (INF for tiles round
## about that it isn't heading onto): everything within near_reach(), plus a corridor a tile wide
## each side along its path for adaptive_near_lead_s of travel.
func wanted_near_tiles(here: Vector2, vel: Vector2) -> Dictionary:
	var out := {}
	for t in near_tiles_of(here):
		out[t] = 0.0 if _tile_gap(t, here) <= NEAR_TOUCH_M else INF
	if full_detail or vel.length() < 1.0:
		return out
	var speed := vel.length()
	var tm := settings.near_tile_m
	var dir := vel / speed
	var length := speed * _near_lead_s()
	var step := tm * 0.5
	var d := 0.0
	while d <= length:
		var p := here + dir * d
		for t in _tiles_round(p, lerpf(tm, tm * 0.5, clampf(speed / NARROW_AT_MPS, 0.0, 1.0))):
			var along := maxf(0.0, (Vector2(t) + Vector2(0.5, 0.5)).dot(dir) * tm - here.dot(dir) - tm * 0.5)
			out[t] = minf(float(out.get(t, INF)), along / speed)
		d += step
	return out


func _tiles_round(p: Vector2, r: float) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var lo := _tile_of(p - Vector2.ONE * r)
	var hi := _tile_of(p + Vector2.ONE * r)
	for tz in range(lo.y, hi.y + 1):
		for tx in range(lo.x, hi.x + 1):
			if _tile_gap(Vector2i(tx, tz), p) <= r:
				out.append(Vector2i(tx, tz))
	return out


# The near tiles drawn at full detail: those whose closest point is within near_reach() of `p`.
func near_tiles_of(p: Vector2) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var reach := near_reach()
	var lo := _tile_of(p - Vector2.ONE * reach)
	var hi := _tile_of(p + Vector2.ONE * reach)
	for tz in range(lo.y, hi.y + 1):
		for tx in range(lo.x, hi.x + 1):
			if _tile_gap(Vector2i(tx, tz), p) <= reach:
				out.append(Vector2i(tx, tz))
	return out


# Distance from `p` to the closest point of tile `t`.
func _tile_gap(t: Vector2i, p: Vector2) -> float:
	var tm := settings.near_tile_m
	return p.distance_to(Vector2(clampf(p.x, t.x * tm, (t.x + 1) * tm), clampf(p.y, t.y * tm, (t.y + 1) * tm)))


# Distance as the mid band measures it: true distance ahead of the car, but stretched to the sides
# and behind as the car speeds up (by up to 1 / mid_side_frac and 1 / mid_back_frac at
# mid_squash_speed_mps), so the band narrows into an egg pointing the way the car is going. What
# enters the band each second is its width across the direction of travel times the speed, so the
# narrower it is the less there is to build; a fast car can't turn into the sides in time anyway.
func squashed_distance(off: Vector2, vel: Vector2) -> float:
	var speed := vel.length()
	var t := clampf(speed / maxf(settings.mid_squash_speed_mps, 0.01), 0.0, 1.0)
	if t <= 0.0:
		return off.length()
	var fwd := vel / speed
	var along := off.dot(fwd)
	var side := off.dot(Vector2(-fwd.y, fwd.x))
	if along < 0.0:
		along /= lerpf(1.0, settings.mid_back_frac, t)
	side /= lerpf(1.0, settings.mid_side_frac, t)
	return Vector2(along, side).length()


static func _dist_to_rect(p: Vector2, r: Rect2) -> float:
	return (p.clamp(r.position, r.end) - p).length()


func _new_job(coord: Vector2i, level: Level, with_collision: bool) -> ChunkJob:
	var job := ChunkJob.new()
	job.coord = coord
	job.level = level
	job.with_collision = with_collision
	job.stride = [settings.near_stride_m, settings.mid_stride_m, settings.far_stride_m, settings.chunk_m][level]
	job.tile = level == Level.NEAR
	job.size_m = settings.near_tile_m if job.tile else settings.chunk_m
	if level == Level.HORIZON:
		job.size_m = _horizon_block_m()
	job.origin = Vector2(coord) * job.size_m
	job.n = int(job.size_m / job.stride) + 1
	_queue.append(job)
	return job


func _drop_near_tile(t: Vector2i, ts: TileState) -> void:
	if ts.near_job != null:
		ts.near_job.cancelled = true
		ts.near_job = null
	if ts.near_mesh != null:
		ts.near_mesh.queue_free()
		ts.near_mesh = null
		ts.near_heights = PackedFloat32Array()
		ts.near_arrays = []
		_holes_due[_chunk_of_tile(t)] = true


func _drop_mid(st: ChunkState) -> void:
	if st.mid_job != null:
		st.mid_job.cancelled = true
	st.mid_job = null
	if st.mid_mesh != null:
		st.mid_mesh.queue_free()
		st.mid_mesh = null
		st.mid_heights = PackedFloat32Array()
		st.mid_arrays = []
		_show_finest(st)
		_holes_due[st.coord] = true
		_horizon_changed(st.coord)


# The chunk's collision and any queued collision build go (it left the collision block).
func _drop_collision(st: ChunkState) -> void:
	if st.mid_job != null:
		st.mid_job.with_collision = false
	for t in _tiles_of_chunk(st.coord):
		var ts: TileState = _tiles.get(t)
		if ts == null:
			continue
		if ts.col_job != null:
			ts.col_job.cancelled = true
			ts.col_job = null
		if ts.body != null:
			ts.body.queue_free()
			ts.body = null


func _drop_chunk(coord: Vector2i, st: ChunkState) -> void:
	for t in _tiles_of_chunk(coord):
		var ts: TileState = _tiles.get(t)
		if ts != null:
			_drop_near_tile(t, ts)
	_drop_mid(st)
	_drop_collision(st)
	for t in _tiles_of_chunk(coord):
		_tiles.erase(t)
	if st.far_job != null:
		st.far_job.cancelled = true
	if st.far_mesh != null:
		st.far_mesh.queue_free()
	_chunks.erase(coord)
	_holes_due.erase(coord)
	_horizon_changed(coord)


func _perimeter(n: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	for x in n: out.append(x)
	for z in range(1, n): out.append(z * n + n - 1)
	for x in range(n - 2, -1, -1): out.append((n - 1) * n + x)
	for z in range(n - 2, 0, -1): out.append(z * n)
	return out


# The grid cell the chunk-border skirt segment t0 -> t1 hangs from.
func _edge_cell(n: int, t0: int, t1: int) -> Vector2i:
	var x0 := t0 % n
	var z0 := t0 / n
	var x1 := t1 % n
	var z1 := t1 / n
	if z0 == 0 and z1 == 0:
		return Vector2i(mini(x0, x1), 0)
	if z0 == n - 1 and z1 == n - 1:
		return Vector2i(mini(x0, x1), n - 2)
	if x0 == 0 and x1 == 0:
		return Vector2i(0, mini(z0, z1))
	return Vector2i(n - 2, mini(z0, z1))


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


# The save's biome mask (biomeRle) as one byte per BIOME_CELL cell, row-major over a ceil(size / BIOME_CELL) square
# grid from the level's north-west corner (BIOME_SNOW = snow); empty when the save has none.
static func decode_biome(level: Dictionary, size: float) -> PackedByteArray:
	var biome: Variant = level.get("biomeRle")
	if not biome is String:
		return PackedByteArray()
	var n := ceili(size / BIOME_CELL)
	return GroundCover.rle_decode(Marshalls.base64_to_raw(biome), n * n)


# How snowy the ground is at (x, z), from 0 (forest) to 1 (snow), blended between the centres of the save's biome cells.
func snow_at(x: float, z: float) -> float:
	if _biome_n < 2:
		return 0.0
	var fc := clampf((x + bake.size / 2) / BIOME_CELL - 0.5, 0.0, _biome_n - 1.0)
	var fr := clampf((z + bake.size / 2) / BIOME_CELL - 0.5, 0.0, _biome_n - 1.0)
	var c := mini(int(fc), _biome_n - 2)
	var r := mini(int(fr), _biome_n - 2)
	var i := r * _biome_n + c
	var a := float(_biome[i] == BIOME_SNOW)
	var b := float(_biome[i + 1] == BIOME_SNOW)
	var d := float(_biome[i + _biome_n] == BIOME_SNOW)
	var e := float(_biome[i + _biome_n + 1] == BIOME_SNOW)
	return lerpf(lerpf(a, b, fc - c), lerpf(d, e, fc - c), fr - r)
