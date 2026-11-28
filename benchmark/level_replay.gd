extends Node
# Records a drive through the dev level (GameConfig.level_path, Hafren Forest) and replays it
# as a repeatable render benchmark. NOT part of the test suite. Run on demand:
#
#     ./run_level_replay.sh --record [path]   # you drive; quitting (pause → quit, or close the window) saves
#     ./run_level_replay.sh [path]            # replays the drive uncapped, prints frame stats, quits
#       extra flags: --until=<seconds> (default 15), --full for the whole drive, --off=DustPuffs,TireMarks,BushInteraction* frees the nodes with those names or script classes first (PostProcess
#       renders straight to the screen), --flat-sky swaps the panorama sky for a plain colour, --no-timers leaves the
#       renderer's timing off, --empty samples a bare camera for the engine's own floor
#     in a browser (./start_web.sh): https://localhost:8080/?replay=1, with &until=30 or &full=1
#     ./run_level_replay.sh --golden-check   # replays twice (one under CPU load) and checks the per-tick traces match
#     ... --free   # drives the car from the recorded inputs alone (a format 2 recording), no pose writes
#     ... --script=<json> --record=<path> --car=<id>   # writes a synthetic format 2 recording and quits
#     ... --free --golden --car-trace=<file>   # writes the car's full state per tick (the car-step golden)
#     ... --golden --events=<file> --game-script=<json>   # writes game events, audio rows and the final save
#     ./run_level_replay.sh --car-golden | --events-golden [rec] [--check | --bless]   # compare with or rewrite goldens/
#
# Each physics tick stores the car's pose, velocities and the driver's inputs. The replay feeds the
# inputs back through the car's AI controls and snaps the pose each tick, so the car (and its dust,
# marks and felled trees) follows the same path every run whatever the frame rate.

const DEFAULT_PATH := "res://benchmark/runs/hafren.rec"
const REPORT_PATH := "user://level_replay_report.json"  # a native replay's full report (the web one goes to the collector)
const STRIDE := 21  # per tick: basis 9, origin 3, linear velocity 3, angular velocity 3, throttle, steer, handbrake
const WARMUP_FRAMES := 60  # unsampled frames after the warm-up, while the first views settle
const DEFAULT_UNTIL_S := 15.0  # enough to compare one change; --full replays all of it
const FIXTURE_PROFILE_PATH := "user://level_replay_profile.json"  # never written: save_disabled is on
const FORMAT := 2  # 2 adds a TickInput row per tick; format 1 files (hafren.rec) hold poses only

var _path := DEFAULT_PATH
var _recording := false
var _level: Node
var _car: VehicleBody3D
var _ticks := PackedFloat32Array()
var _inputs: Array[PackedFloat32Array] = []  # one TickInput row per tick (format 2)
var _free := false  # --free: the car drives itself from _inputs; no pose is written
var _script_path := ""  # --script=<json>: build a synthetic recording from timed action presses
var _auto_gearbox := true
var _car_id := ""  # the CarLibrary model driven, so every replay draws and drives the same car
var _tick := 0
var _started := false
var _warmup_left := WARMUP_FRAMES
var _samples := {}
var _view_rid: RID
var _last_cap := {}
var _peak_draws := 0
var _draw_breakdown := {}
var _last_usec := 0
var _frame_start_usec := 0  # when this frame's first physics or process step began; 0 until it has
var _tick_start_usec := 0     # this physics tick's start, before any _physics_process runs
var _scripts_end_usec := 0    # when the last _physics_process of the tick returned; the engine's step runs after it
var _phys_scripts_ms := 0.0   # this frame's totals, over all of its physics ticks
var _phys_step_ms := 0.0
var _process_start_usec := 0  # this frame's process step began (process_frame), and its drawing (frame_pre_draw)
var _draw_start_usec := 0
var _until_s := DEFAULT_UNTIL_S
var _off: PackedStringArray = []
var _flat_sky := false
var _record_car := ""  # --car=<id>: record with this car instead of the save's
var _record_at := ""  # --at=<teleport name>: record from this teleport point
var _no_timers := false  # leave the renderer's own timing off, to see what measuring it costs
var _empty := false      # a camera and nothing else: the engine's and browser's own per-frame floor
var _trace_path := ""   # --trace=<file>: golden runs write one JSON line of game state per tick here
var _trace: FileAccess
var _frame_skew := -1   # process frames minus physics frames at the first traced tick; must never change
var _car_trace_path := ""  # --car-trace=<file>: a free golden run writes {tick, input, snap, world} per tick
var _car_trace: FileAccess
var _events_path := ""  # --events=<file>: a golden run writes GameTrace events, audio rows and the final save
var _events: FileAccess
var _game_script: Array = []  # --game-script=<json>: [{tick, do, args}] run through GameTrace.act
var _game_script_path := ""
var _game_step := 0
var _prev_state := {}
var _last_audio := {}
var _driven := 0.0  # a free run's distance, summed from the car's own positions
var _last_pos := Vector3.INF
var _off_road_run := 0  # ticks the free-running car has been off the road in a row, and the longest run so far
var _off_road_max := 0
var _road_resets := 0
var _exit_code := 0


# Runs after every other node's _physics_process, marking where the physics engine's step begins.
class _Tail extends Node:
	var on_tick: Callable
	func _physics_process(_delta: float) -> void:
		on_tick.call()


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	if Platform.is_web():  # the browser takes the same flags from the URL: ?replay=1&until=30 or &full=1
		for pair in str(JavaScriptBridge.eval("window.location.search", true)).trim_prefix("?").split("&"):
			if not pair.begins_with("replay="):  # ?replay=1 only says "boot into the replay", not which file
				args.append("--" + pair)
	for arg in args:
		if arg == "--record":
			_recording = true
		elif arg.begins_with("--record="):
			_recording = true
			_path = arg.get_slice("=", 1)
		elif arg.begins_with("--replay="):
			_path = arg.get_slice("=", 1)
		elif arg == "--full" or arg == "--full=1":
			_until_s = INF
		elif arg.begins_with("--until="):
			_until_s = float(arg.get_slice("=", 1))
		elif arg == "--no-timers" or arg == "--no-timers=1":
			_no_timers = true
		elif arg == "--empty" or arg == "--empty=1":
			_empty = true
		elif arg == "--flat-sky" or arg == "--flat-sky=1":
			_flat_sky = true
		elif arg.begins_with("--at="):
			_record_at = arg.get_slice("=", 1).uri_decode()
		elif arg.begins_with("--car="):
			_record_car = arg.get_slice("=", 1)
		elif arg == "--adaptive" or arg == "--adaptive=1":
			AdaptiveGraphics.force_on = true
		elif arg == "--golden":
			Benchmark.golden = true
		elif arg.begins_with("--trace="):
			_trace_path = arg.get_slice("=", 1)
		elif arg == "--free":
			_free = true
		elif arg.begins_with("--script="):
			_script_path = arg.get_slice("=", 1)
		elif arg.begins_with("--car-trace="):
			_car_trace_path = arg.get_slice("=", 1)
		elif arg.begins_with("--events="):
			_events_path = arg.get_slice("=", 1)
		elif arg.begins_with("--game-script="):
			_game_script_path = arg.get_slice("=", 1)
		elif arg.begins_with("--off="):
			_off = arg.get_slice("=", 1).split(",")
	if not _recording and DisplayServer.get_name() == "headless":
		push_warning("level replay: headless draws nothing, so these numbers leave out all rendering")
	process_physics_priority = -100  # before the car reads its inputs this tick
	# A landscape-sized frame and no rotate prompt even on a portrait phone, a fixed engine misfire seed,
	# and no cloud sync.
	Benchmark.active = not _recording
	if _script_path != "":
		get_tree().quit(0 if _write_script_recording() else 1)
		return
	if _recording and _record_car == "":
		push_error("level replay: --record needs --car=<id>, so a free replay can field the same car")
		get_tree().quit(1)
		return
	# A recording starts from the same profile and seeds as its free replay will.
	_use_fixture_profile()
	RngStreams.reseed(Benchmark.RNG_SEED)
	_auto_gearbox = Config.data.auto_gearbox
	if Benchmark.golden and not _golden_ready():
		get_tree().quit(1)
		return
	if _empty:
		var cam := Camera3D.new()
		add_child(cam)
		cam.make_current()
		print("level replay: empty scene for %.1f s" % _until_s)
		_start_sampling(get_viewport())
		_started = true
		return
	if not _recording and not _load():
		get_tree().quit(1)
		return
	if _free and _inputs.is_empty():
		push_error("level replay --free: %s has no recorded inputs (format 1); record a new one" % _path)
		get_tree().quit(1)
		return
	Config.data.auto_gearbox = _auto_gearbox
	if _recording:  # start at the spawn teleport, not wherever the level view was last left
		Save.set_setting(LevelView.SAVED_POSE_KEY, null)
		LevelView.recording = true
	_level = load(Scenes.WORLD).instantiate()
	add_child(_level)
	_car = _level.get_node("Car")
	# The level has fielded the save's car by now (or none, with no save, as in a fresh browser); swap in the recorded one
	# before its shader warm-up.
	if _recording:
		if _record_car != "" and CarLibrary.index_of(_record_car) >= 0:
			_car.apply_car(CarLibrary.index_of(_record_car))
		_car_id = String(CarLibrary.all()[_car._car_index]["id"]) if _car._car_index >= 0 else ""
	else:
		_car.apply_car(maxi(CarLibrary.index_of(_car_id), 0))
	var pause := _level.get_node("PauseMenu")
	while not pause.is_armed():  # LevelView arms the pause menu once its shader warm-up is done
		await get_tree().process_frame
	if _recording:
		_place_at_teleport(_level.get_node("Level") as LevelView, _record_at if _record_at != "" else Config.data.level_spawn_teleport)
		print("level replay: recording to %s — quit to save" % _path)
	else:
		print("level replay: replaying %s (%.1f s)%s" % [_path, _tick_count() / float(Engine.physics_ticks_per_second),
			" free" if _free else ""])
		if _free:
			_place_at_teleport(_level.get_node("Level") as LevelView, _record_at if _record_at != "" else Config.data.level_spawn_teleport)
			var recovery := _level.find_child("RoadRecovery", true, false) as RoadRecovery
			if recovery != null:
				recovery.reset_done.connect(func(_p: Vector2) -> void: _road_resets += 1)
		else:
			_car.ai_controlled = true
		var cams := _level.get_node("CameraManager")
		cams._index = cams.ORDER.find(CameraManager.Mode.CHASE)  # not set_mode: that would save over the player's choice
		cams._apply()
		_turn_off()
		if _flat_sky:  # a plain background instead of the panorama sky, to measure what drawing the sky costs
			var env: Environment = _level.get_node("WorldEnvironment").environment
			env.background_mode = Environment.BG_COLOR
			env.background_color = Color(0.72, 0.8, 0.92)
		var view := _level.get_node_or_null("PostProcess/View") as Viewport
		if view != null and view.get_parent().is_queued_for_deletion():  # --off=PostProcess: the root view renders the world
			view = null
		_start_sampling(view if view != null else get_viewport())
	if _free and not _recording:
		_start_free_inputs()
	if _car_trace != null:
		_car.record_contacts = true
		_car_trace.store_line(JSON.stringify(_golden_header(), "", true, true))
	if _events != null:
		_events.store_line(JSON.stringify(_golden_header(), "", true, true))
		GameTrace.listen()
	_started = true


# A press made during a physics tick only reads as just-pressed on the next tick, so each tick's
# recorded row is pressed at the end of the tick before it (the first one before ticks start).
func _start_free_inputs() -> void:
	TickInput.apply(_inputs[0])
	var tail := _Tail.new()
	tail.process_physics_priority = (1 << 20) + 1
	tail.on_tick = func() -> void:
		if _started and _tick < _inputs.size():
			TickInput.apply(_inputs[_tick])
	add_child(tail)


# Uncaps the frame rate and hooks every per-frame timer; `view` is the viewport whose render time is read.
func _start_sampling(view: Viewport) -> void:
	Engine.max_fps = 0
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	_view_rid = view.get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(_view_rid, not _no_timers)
	get_tree().physics_frame.connect(_mark_frame_start)
	get_tree().process_frame.connect(_mark_frame_start)
	get_tree().physics_frame.connect(_on_tick_start)
	get_tree().process_frame.connect(_close_step)
	get_tree().process_frame.connect(func() -> void: _process_start_usec = Time.get_ticks_usec())
	RenderingServer.frame_pre_draw.connect(func() -> void: _draw_start_usec = Time.get_ticks_usec())
	_samples["process_phase_ms"] = []
	_samples["draw_phase_ms"] = []
	var tail := _Tail.new()
	tail.process_physics_priority = 1 << 20
	tail.on_tick = _on_tick_scripts_done
	add_child(tail)
	_samples["physics_scripts_ms"] = []
	if Platform.is_web():
		# Stamp when the browser starts each frame: Godot runs the car's physics callbacks (wheel ray casts,
		# _integrate_forces) before any signal a script can hear, so only the browser sees the frame's true start.
		JavaScriptBridge.eval("if(!window.__replayRaf){window.__replayRaf=1;const raf=window.requestAnimationFrame.bind(window);"
			+ "window.requestAnimationFrame=function(cb){return raf(function(t){window.__frameStart=performance.now();cb(t);});};}", true)
		_samples["frame_work_ms"] = []
		_samples["pre_ms"] = []
	_samples["physics_step_ms"] = []
	RenderingServer.frame_post_draw.connect(_on_frame_drawn)
	_samples["busy_ms"] = []
	for stream in ["frame_ms", "draws", "objects", "prims", "render_cpu_ms", "render_gpu_ms", "process_ms", "physics_ms",
			"t_s", "car_x", "car_z", "chunks_building", "chunks_queued", "cover_building", "scripts_ms",
			"speed_mps", "near_misses", "near_build_ms", "near_overdue", "due_near", "due_collision"]:
		_samples[stream] = []


func _place_at_teleport(view: LevelView, point: String) -> void:
	for t: Dictionary in view.level.get("teleports", []):
		if String(t.get("name", "")) == point:
			var pose := view.teleport_pose(Vector2(float(t["x"]), float(t["z"])), Vector3.FORWARD)
			_car.reset_to(pose)
			print("level replay: recording from teleport %s at %s (Benchmark.active=%s)" % [point, pose.origin, Benchmark.active])
			return
	push_warning("level replay: no teleport named '%s'; starting where the level put the car (%s)" % [point, _car.global_position])


# Hides and stops every node whose name (wildcards allowed: BushInteraction*) or script class (GroundCover) is in --off; not freed, since other nodes still call into some of them.
func _turn_off() -> void:
	for pattern in _off:
		var hits := 0
		for n in _level.find_children("*", "", true, false):
			var script := n.get_script() as Script
			if String(n.name).match(pattern) or (script != null and script.get_global_name() == pattern):
				n.process_mode = Node.PROCESS_MODE_DISABLED
				if "visible" in n:
					n.visible = false
				hits += 1
		if hits == 0:
			push_warning("level replay: nothing matches --off=%s" % pattern)


# Every replay starts from the same blank profile instead of the player's, and writes nothing back.
func _use_fixture_profile() -> void:
	Save.profile_path = FIXTURE_PROFILE_PATH
	Save.profile = Save._default_profile()
	Save.save_disabled = true


# A golden run must step exactly one process frame per physics tick on the main thread; anything else is refused.
func _golden_ready() -> bool:
	var why := ""
	if _recording:
		why = "--golden replays a recording; it can't record"
	elif DisplayServer.get_name() != "headless":
		why = "run it with --headless"
	elif ProjectSettings.get_setting("physics/3d/run_on_separate_thread", false):
		why = "physics/3d/run_on_separate_thread is on (./run_level_replay.sh --golden-check writes an override.cfg turning it off)"
	elif AdaptiveGraphics.force_on:
		why = "--adaptive changes settings mid-run"
	if why != "":
		push_error("level replay --golden: " + why)
		return false
	Config.data.threaded_chunk_build = false
	Config.data.threaded_tree_build = false
	if _car_trace_path != "" and not _free:
		push_error("level replay --golden: --car-trace needs --free")
		return false
	if _game_script_path != "":
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(_game_script_path))
		if not parsed is Array:
			push_error("level replay --golden: %s isn't a JSON list of {tick, do, args}" % _game_script_path)
			return false
		_game_script = parsed
		_game_script.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a["tick"]) < int(b["tick"]))
	for pair: Array in [[_trace_path, "_trace"], [_car_trace_path, "_car_trace"], [_events_path, "_events"]]:
		if pair[0] == "":
			continue
		var f := FileAccess.open(pair[0], FileAccess.WRITE)
		if f == null:
			push_error("level replay --golden: can't write %s" % pair[0])
			return false
		set(pair[1], f)
	return true


# Line 1 of every golden file: what produced it, so a mismatch caused by another machine or recording shows at once.
func _golden_header() -> Dictionary:
	return {"format": 1, "level_path": Config.data.level_path, "car": _car_id, "seed": Benchmark.RNG_SEED,
		"godot_version": Engine.get_version_info()["string"], "platform": "%s/%s" % [OS.get_name(), Engine.get_architecture_name()],
		"recording": _path.get_file(), "free": _free}


func _physics_process(_delta: float) -> void:
	if not _started:
		return
	if _recording:
		_record_tick()
	elif _empty and _tick < _until_s * Engine.physics_ticks_per_second:
		_tick += 1
	elif _tick < _tick_count() and _tick < _until_s * Engine.physics_ticks_per_second:
		if Benchmark.golden and not _trace_tick(_tick):
			return
		if _free:
			_check_on_road()
		if _car_trace != null:
			_car_trace.store_line(JSON.stringify({"tick": _tick, "input": Array(_inputs[_tick]),
				"snap": _car.snapshot(), "world": _world_state()}, "", true, true))
		if _events != null:
			_events_tick(_tick)
		_play_tick(_tick)
		_tick += 1
	else:
		_finish()


# Writes this tick's game state as one sorted-key JSON line, so two golden runs can be compared with cmp.
func _trace_tick(i: int) -> bool:
	var skew := Engine.get_process_frames() - Engine.get_physics_frames()
	if _frame_skew < 0:
		_frame_skew = skew
	elif skew != _frame_skew:
		push_error("level replay --golden: process and physics frames stopped stepping 1:1 at tick %d" % i)
		_started = false
		get_tree().quit(1)
		return false
	if _trace == null:
		return true
	var engine: EngineSim = _car.drivetrain.engine
	var damage: DamageModel = _car.damage
	var view := _level.get_node("Level") as LevelView
	var weather := _level.find_child("LevelWeather", true, false) as LevelWeather
	var row := {
		"tick": i, "physics_frames": Engine.get_physics_frames(), "process_frames": Engine.get_process_frames(),
		"paused": get_tree().paused,
		"car": {"pos": _vec(_car.global_position), "omega": engine.omega, "gear": engine.gear, "boost": engine.boost,
			"nitrous_charge": engine.nitrous_charge, "misfire_timer": engine._misfire_timer,
			"misfire_count": engine.misfire_count, "limiter_cut_count": engine.limiter_cut_count},
		"damage": {"hp": damage.hp, "wheel_toe": damage.wheel_toe, "engine_temp": damage.engine_temp},
		"weather": {"drive_time": LevelWeather.drive_time, "shown": weather._shown if weather != null else "",
			"config": Config.data.weather},
		"delivery": LevelView.delivery, "money": LevelView.money(),
		"rng": RngStreams.live_states(),
	}
	var trees: LevelTrees = view._trees
	if trees != null:
		var fallen := trees._fallen.keys()
		fallen.sort()
		var hit_tiles := 0
		for t in trees._tiles.values():
			if t.hit != null:
				hit_tiles += 1
		row["trees"] = {"fallen": fallen, "hit_tiles": hit_tiles}
	var streamer: LevelStreamer = view._streamer
	if streamer != null:
		var c := streamer.chunk_counts()
		row["streamer"] = {"chunks": [c.x, c.y, c.z], "tiles": streamer._tiles.size(),
			"cover_tiles": streamer.cover.tiles.size() if streamer.cover != null else 0,
			"cover_pending": streamer.cover.pending() if streamer.cover != null else 0}
	var crowd: LevelSpectators = view._spectators
	if crowd != null:
		var groups := []
		var ids := crowd._live.keys()
		ids.sort()
		for id in ids:
			if not is_instance_valid(crowd._live[id]):
				continue
			var g: SpectatorGroup = crowd._live[id]
			var sum := Vector2.ZERO
			for p in g._pos:
				sum += p
			groups.append([id, g._ragdolls.size(), sum.x, sum.y])
		row["spectators"] = {"live": crowd.live_count(), "groups": groups}
	_trace.store_line(JSON.stringify(row, "", true, true))
	return true


static func _vec(v: Vector3) -> Array:
	return [v.x, v.y, v.z]


# What the car can change outside itself: the trees it felled and every ragdoll it knocked over.
func _world_state() -> Dictionary:
	var view := _level.get_node("Level") as LevelView
	var fallen: Array = view._trees._fallen.keys() if view._trees != null else []
	fallen.sort()
	var ragdolls := []
	var crowd: LevelSpectators = view._spectators
	if crowd != null:
		var ids := crowd._live.keys()
		ids.sort()
		for id in ids:
			if not is_instance_valid(crowd._live[id]):
				continue
			for b: RigidBody3D in (crowd._live[id] as SpectatorGroup)._ragdolls:
				if is_instance_valid(b):
					var basis := b.global_transform.basis
					ragdolls.append({"group": id, "basis": _vec(basis.x) + _vec(basis.y) + _vec(basis.z),
						"origin": _vec(b.global_position), "linear_velocity": _vec(b.linear_velocity),
						"angular_velocity": _vec(b.angular_velocity), "sleeping": b.sleeping})
	return {"fallen_trees": fallen, "ragdolls": ragdolls}


# A free run must stay on the road: no off-road stretch long enough for RoadRecovery to step in, and no reset.
func _check_on_road() -> void:
	var p := _car.global_position
	if _last_pos != Vector3.INF:
		_driven += p.distance_to(_last_pos)
	_last_pos = p
	var view := _level.get_node("Level") as LevelView
	_off_road_run = _off_road_run + 1 if view.is_off_road(Vector2(p.x, p.z)) else 0
	_off_road_max = maxi(_off_road_max, _off_road_run)


# The events seen at the start of tick `i` (so caused by ticks before it), then this tick's scripted actions.
func _events_tick(i: int) -> void:
	var view := _level.get_node("Level") as LevelView
	var now := GameTrace.read(view, _car)
	if i == 0:
		_prev_state = now
	for e: Dictionary in GameTrace.diff(_prev_state, now, i):
		_events.store_line(JSON.stringify(e, "", true, true))
	_prev_state = now
	# Only when it changes: the music and bus levels sit still for most ticks.
	var audio := GameTrace.audio_row(i)
	audio.erase("tick")
	if audio != _last_audio:
		_last_audio = audio.duplicate(true)
		_events.store_line(JSON.stringify(audio.merged({"tick": i, "kind": "audio"}), "", true, true))
	while _game_step < _game_script.size() and int(_game_script[_game_step]["tick"]) <= i:
		if int(_game_script[_game_step]["tick"]) == i:
			GameTrace.act(view, _car, _game_script[_game_step])
		_game_step += 1


func _record_tick() -> void:
	var t := _car.global_transform
	var b := t.basis
	var v := _car.linear_velocity
	var w := _car.angular_velocity
	_ticks.append_array([b.x.x, b.x.y, b.x.z, b.y.x, b.y.y, b.y.z, b.z.x, b.z.y, b.z.z,
		t.origin.x, t.origin.y, t.origin.z, v.x, v.y, v.z, w.x, w.y, w.z,
		Input.get_axis("brake_reverse", "accelerate"), Input.get_axis("steer_right", "steer_left"),
		1.0 if Input.is_action_pressed("handbrake") else 0.0])
	_inputs.append(TickInput.sample())


func _tick_count() -> int:
	return _inputs.size() if _free else floori(_ticks.size() / float(STRIDE))


func _play_tick(i: int) -> void:
	if _free:
		return
	var f := _ticks.slice(i * STRIDE, (i + 1) * STRIDE)
	var t := Transform3D(Basis(Vector3(f[0], f[1], f[2]), Vector3(f[3], f[4], f[5]), Vector3(f[6], f[7], f[8])),
		Vector3(f[9], f[10], f[11]))
	# Written straight to the physics server: a plain global_transform write outside the step is discarded.
	var rid := _car.get_rid()
	PhysicsServer3D.body_set_state(rid, PhysicsServer3D.BODY_STATE_TRANSFORM, t)
	PhysicsServer3D.body_set_state(rid, PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, Vector3(f[12], f[13], f[14]))
	PhysicsServer3D.body_set_state(rid, PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY, Vector3(f[15], f[16], f[17]))
	_car.ai_throttle = f[18]
	_car.ai_steer = f[19]
	_car.ai_handbrake = f[20] > 0.5


func _process(_delta: float) -> void:
	if not _started or _recording:
		return
	if _warmup_left > 0:
		_warmup_left -= 1
		_last_usec = Time.get_ticks_usec()
		if _warmup_left == 0:
			PerfLog.begin_capture()
		return
	# Wall-clock interval, not delta: Godot smooths delta and would hide the hitches (features/benchmark.md).
	var now := Time.get_ticks_usec()
	var frame_ms := (now - _last_usec) / 1000.0
	_samples["frame_ms"].append(frame_ms)
	_last_usec = now
	if frame_ms >= BenchmarkStats.SPIKE_MS and _car != null:
		var p := _car.global_position
		print("  spike %.1f ms at %.2f s, car (%.0f, %.0f), render cpu %.1f ms" % [frame_ms,
			_tick / float(Engine.physics_ticks_per_second), p.x, p.z, RenderingServer.viewport_get_measured_render_time_cpu(_view_rid)])
	_samples["draws"].append(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	var draws := int(_samples["draws"][-1])
	if draws > _peak_draws:
		_peak_draws = draws
		_draw_breakdown = {"draws": draws, "t_s": _tick / float(Engine.physics_ticks_per_second), "by_owner": _visible_by_owner()}
	_samples["objects"].append(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME))
	_samples["prims"].append(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))
	_samples["render_cpu_ms"].append(RenderingServer.viewport_get_measured_render_time_cpu(_view_rid))
	_samples["render_gpu_ms"].append(RenderingServer.viewport_get_measured_render_time_gpu(_view_rid))
	_samples["process_ms"].append(Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0)
	_samples["physics_ms"].append(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0)
	var car_at := _car.global_position if _car != null else Vector3.ZERO
	_samples["t_s"].append(_tick / float(Engine.physics_ticks_per_second))
	_samples["car_x"].append(car_at.x)
	_samples["car_z"].append(car_at.z)
	var cap: Dictionary = PerfLog._cap_us
	var slow := {}
	for key in cap:
		var ms := (int(cap[key]) - int(_last_cap.get(key, 0))) / 1000.0
		if ms >= 0.5:
			slow[String(key)] = snappedf(ms, 0.1)
	_last_cap = cap.duplicate()
	_samples["scripts_ms"].append(slow)
	var streamer: LevelStreamer = _level.get_node("Level").get("_streamer")
	_samples["chunks_building"].append(streamer._inflight.size() if streamer != null else 0)
	_samples["chunks_queued"].append(streamer._queue.size() if streamer != null else 0)
	_samples["cover_building"].append(streamer.cover.pending() if streamer != null and streamer.cover != null else 0)
	_samples["speed_mps"].append(_car.linear_velocity.length() if _car != null else 0.0)
	_samples["near_misses"].append(streamer.stat_near_misses if streamer != null else 0)
	_samples["near_build_ms"].append(streamer.near_build_s * 1000.0 if streamer != null else 0.0)
	_samples["near_overdue"].append(int(streamer.near_overdue()) if streamer != null else 0)
	var due := streamer.due_by_kind() if streamer != null else {}
	_samples["due_near"].append(int(due.get("near", 0)))
	_samples["due_collision"].append(int(due.get("collision", 0)))


func _mark_frame_start() -> void:
	if _frame_start_usec == 0:
		_frame_start_usec = Time.get_ticks_usec()


# Busy time: the frame's physics, scripts and draw submission, before it waits for the next screen refresh.
func _on_frame_drawn() -> void:
	if _started and _warmup_left == 0 and _frame_start_usec != 0:
		_samples["busy_ms"].append((Time.get_ticks_usec() - _frame_start_usec) / 1000.0)
		_samples["physics_scripts_ms"].append(_phys_scripts_ms)
		_samples["physics_step_ms"].append(_phys_step_ms)
		if _process_start_usec != 0 and _draw_start_usec >= _process_start_usec:
			_samples["process_phase_ms"].append((_draw_start_usec - _process_start_usec) / 1000.0)
			_samples["draw_phase_ms"].append((Time.get_ticks_usec() - _draw_start_usec) / 1000.0)
		if Platform.is_web():
			var work := float(JavaScriptBridge.eval("performance.now()-(window.__frameStart||performance.now())", true))
			_samples["frame_work_ms"].append(work)
			_samples["pre_ms"].append(maxf(work - _samples["busy_ms"][-1], 0.0))
	_frame_start_usec = 0
	_process_start_usec = 0
	_phys_scripts_ms = 0.0
	_phys_step_ms = 0.0


func _on_tick_start() -> void:
	_close_step()
	_tick_start_usec = Time.get_ticks_usec()


func _on_tick_scripts_done() -> void:
	_scripts_end_usec = Time.get_ticks_usec()
	_phys_scripts_ms += (_scripts_end_usec - _tick_start_usec) / 1000.0


# The engine's step for the previous tick ends when the next tick or the frame's process step begins.
func _close_step() -> void:
	if _scripts_end_usec != 0:
		_phys_step_ms += (Time.get_ticks_usec() - _scripts_end_usec) / 1000.0
		_scripts_end_usec = 0


func _finish() -> void:
	_started = false
	if _free:
		TickInput.release_all()
	if _trace != null:
		_trace.close()
		print("level replay: trace written to %s" % _trace_path)
	if _car_trace != null:
		_car_trace.close()
		print("level replay: car trace written to %s" % _car_trace_path)
	if _events != null:
		_events_tick(_tick)  # what the last tick did
		_events.store_line(JSON.stringify({"tick": _tick, "kind": "final_save", "save": GameTrace.final_save()}, "", true, true))
		_events.close()
		GameTrace.stop()
		print("level replay: events written to %s" % _events_path)
	if _free:
		var limit := roundi(Config.data.off_road_reset_timeout_s * Engine.physics_ticks_per_second)
		print("level replay: longest off-road stretch %d ticks (RoadRecovery resets at %d), %d road resets" % [_off_road_max, limit, _road_resets])
		if _road_resets > 0 or _off_road_max >= limit:
			push_error("level replay --free: the car left the road; record a drive that stays on it")
			_exit_code = 1
	var stats := BenchmarkStats.summarise(_samples)
	stats["distance_m"] = _driven_m()
	var scripts := PerfLog.end_capture(_samples["frame_ms"].size())
	print("\n=== level replay benchmark: %s ===" % _path)
	BenchmarkStats.print_summary(stats, DisplayServer.get_name() == "headless")
	if Platform.is_web():
		await _post(stats, scripts)  # the browser has no terminal: the results go to start_web.sh's collector
	else:
		var f := FileAccess.open(REPORT_PATH, FileAccess.WRITE)
		if f != null:
			f.store_string(BenchmarkReport.to_json(_report(stats, scripts)))
			print("level replay: report written to %s" % ProjectSettings.globalize_path(REPORT_PATH))
	get_tree().quit(_exit_code)


# How far the car went over the ticks played, from the recorded positions.
func _driven_m() -> float:
	if _free:
		return _driven
	var d := 0.0
	for i in range(1, mini(_tick, floori(_ticks.size() / float(STRIDE)))):
		var a := i * STRIDE + 9
		d += Vector3(_ticks[a], _ticks[a + 1], _ticks[a + 2]).distance_to(
			Vector3(_ticks[a - STRIDE], _ticks[a - STRIDE + 1], _ticks[a - STRIDE + 2]))
	return d


func _post(stats: Dictionary, scripts: Dictionary) -> void:
	var report := _report(stats, scripts)
	var http := HTTPRequest.new()
	add_child(http)
	var origin := String(JavaScriptBridge.eval("window.location.origin", true))
	if http.request(origin + "/bench", ["Content-Type: application/json"], HTTPClient.METHOD_POST, BenchmarkReport.to_json(report)) == OK:
		await http.request_completed


func _report(stats: Dictionary, scripts: Dictionary) -> Dictionary:
	var device := BenchmarkReport.probe_device()
	var label := "level-replay-" + _path.get_file().get_basename()
	if not _off.is_empty():
		label += "-off-" + "+".join(_off).replace("*", "")
	if _flat_sky:
		label += "-flatsky"
	if _no_timers:
		label += "-notimers"
	if AdaptiveGraphics.force_on:
		label += "-adaptive"
	if _empty:
		label = "level-replay-empty"
	var report := BenchmarkReport.build(stats, scripts, device, Time.get_datetime_string_from_system(true), label, LevelView.load_ms)
	report["draw_breakdown"] = _draw_breakdown
	if AdaptiveGraphics.force_on:
		report["adaptive"] = AdaptiveGraphics.events
	report["frames"] = _samples  # every frame's samples, to line a spike up with what was happening then
	return report


func _exit_tree() -> void:
	if not _recording or _ticks.is_empty():
		return
	DirAccess.make_dir_recursive_absolute(_path.get_base_dir())
	var file := FileAccess.open(_path, FileAccess.WRITE)
	if file == null:
		push_error("level replay: can't write %s" % _path)
		return
	file.store_var(_header(_record_at if _record_at != "" else Config.data.level_spawn_teleport).merged({"ticks": _ticks, "inputs": _inputs}))
	print("level replay: saved %.1f s to %s" % [_ticks.size() / float(STRIDE) / Engine.physics_ticks_per_second, _path])
	_ticks = PackedFloat32Array()


func _header(at: String) -> Dictionary:
	return {"format": FORMAT, "level": Config.data.level_path, "car": _car_id, "hz": Engine.physics_ticks_per_second,
		"seed": Benchmark.RNG_SEED, "at": at, "auto_gearbox": _auto_gearbox}


# --script: [{from_s, to_s, action, strength}], or {car, auto_gearbox, steps: [...]}; a step lasts at least one tick.
func _write_script_recording() -> bool:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(_script_path))
	var steps: Array = parsed.get("steps", []) if parsed is Dictionary else (parsed if parsed is Array else [])
	if steps.is_empty():
		push_error("level replay: no steps in %s" % _script_path)
		return false
	_auto_gearbox = bool(parsed.get("auto_gearbox", Config.data.auto_gearbox)) if parsed is Dictionary else Config.data.auto_gearbox
	if parsed is Dictionary and parsed.has("car"):
		_record_car = String(parsed["car"])
	if CarLibrary.index_of(_record_car) < 0:
		push_error("level replay --script: needs --car=<id> (or a \"car\" key) naming a real car")
		return false
	_car_id = _record_car
	if _path == DEFAULT_PATH:  # never overwrite the hand-driven benchmark
		_path = "res://benchmark/runs/synthetic_%s.rec" % _script_path.get_file().get_basename()
	var hz := Engine.physics_ticks_per_second
	var spans := []  # [action, first tick, end tick, strength]
	var last := 0
	for step: Dictionary in steps:
		var from := roundi(float(step["from_s"]) * hz)
		var to := maxi(roundi(float(step["to_s"]) * hz), from + 1)
		spans.append([StringName(step["action"]), from, to, float(step.get("strength", 1.0))])
		last = maxi(last, to)
	var prev := {}
	for t in last:
		var now := {}
		for h: Array in spans:
			if t >= h[1] and t < h[2]:
				now[h[0]] = h[3]
		var down: Array = now.keys().filter(func(a: StringName) -> bool: return float(prev.get(a, 0.0)) <= 0.0)
		_inputs.append(TickInput.pack(now, down))
		prev = now
	DirAccess.make_dir_recursive_absolute(_path.get_base_dir())
	var file := FileAccess.open(_path, FileAccess.WRITE)
	if file == null:
		push_error("level replay: can't write %s" % _path)
		return false
	file.store_var(_header(_record_at if _record_at != "" else Config.data.level_spawn_teleport).merged({"ticks": _ticks, "inputs": _inputs}))
	print("level replay: wrote %d synthetic ticks to %s" % [_inputs.size(), _path])
	_inputs.clear()
	return true


func _load() -> bool:
	var file := FileAccess.open(_path, FileAccess.READ)
	if file == null:
		push_error("level replay: no recording at %s (record one with --record)" % _path)
		return false
	var d: Dictionary = file.get_var()
	if String(d.get("level", "")) != Config.data.level_path:
		push_warning("level replay: recorded on %s, but the dev level is now %s" % [d.get("level"), Config.data.level_path])
	if int(d.get("hz", 0)) != Engine.physics_ticks_per_second:
		push_warning("level replay: recorded at %s Hz physics, running at %d" % [d.get("hz"), Engine.physics_ticks_per_second])
	_ticks = d["ticks"]
	_car_id = String(d.get("car", ""))
	if int(d.get("format", 1)) >= 2:
		_inputs.assign(d["inputs"])
		_auto_gearbox = bool(d["auto_gearbox"])
		if _record_at == "":
			_record_at = String(d["at"])
	return true


# At the frame with the most draw calls: how many on-screen meshes each of the level's top-level nodes contributes, as "Owner/Class" -> [meshes, multimesh instances, shadow casters].
func _visible_by_owner() -> Dictionary:
	var cam := get_viewport().get_camera_3d()
	var out := {}
	if cam == null:
		return out
	var stack: Array[Node] = [_level]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			stack.append(c)
		var g := n as GeometryInstance3D
		if g == null or not g.is_visible_in_tree():
			continue
		var centre := g.global_transform * g.get_aabb().get_center()
		var far := g.visibility_range_end
		if far > 0.0 and centre.distance_to(cam.global_position) > far + g.get_aabb().size.length():
			continue
		if not cam.is_position_in_frustum(centre) and centre.distance_to(cam.global_position) > g.get_aabb().size.length():
			continue
		var path := String(_level.get_path_to(g)).split("/")
		var key := "%s/%s" % ["/".join(path.slice(0, mini(3, path.size() - 1))).rstrip("0123456789_"), g.get_class()]
		var row: Array = out.get(key, [0, 0, 0])
		row[0] += 1
		var mmi := g as MultiMeshInstance3D
		if mmi != null and mmi.multimesh != null:
			row[1] += mmi.multimesh.visible_instance_count if mmi.multimesh.visible_instance_count >= 0 else mmi.multimesh.instance_count
		if g.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF:
			row[2] += 1
		out[key] = row
	return out
