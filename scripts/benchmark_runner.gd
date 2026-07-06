class_name BenchmarkRunner
extends Node
# Drives the benchmark run (features/benchmark.md): auto-pilots the fielded car
# down the whole generated stage at a steady moderate speed, records per-frame
# timing/render samples the entire way, and shows the results breakdown
# (BenchmarkResults) when the car crosses the finish.
#
# The car is driven through its real AI inputs (Car.ai_controlled — the same
# hook the start-line presence cars use), NOT teleported: the run exercises the
# actual per-frame workload (vehicle physics, the tire model, wheel dust, tire
# marks, engine audio) so the numbers reflect real play. Steering is a simple
# pure-pursuit follow of the road centerline; the off-track reset (TrackProgress)
# is the safety net if a corner is fumbled — the car snaps back onto the road
# and carries on. Created and wired by world.gd when Benchmark.active.

const TARGET_SPEED_KMH := 50.0        # the requested moderate benchmark pace
const TARGET_SPEED_MPS := TARGET_SPEED_KMH / 3.6
const LOOKAHEAD_M := 12.0             # pure-pursuit aim point ahead on the road
const STEER_GAIN := 2.5               # rad of heading error -> full steering lock
const THROTTLE_GAIN := 0.5            # m/s of speed error -> full throttle/brake
const WARMUP_FRAMES := 60             # settle/shader-compile frames left unsampled

var _car: Node                        # the fielded Car (VehicleBody3D)
var _progress: TrackProgress          # progress + finish edge + off-track reset
var _centerline: Curve2D              # the road, for the pursuit aim point
var _view_rid: RID                    # viewport whose render times we sample
var _running := false
var _warmup_left := WARMUP_FRAMES
var _start_offset := 0.0              # progress offset when sampling began
var _samples := {}                    # stream name -> Array of per-frame values
var _results_screen: BenchmarkResults


# Wire the runner to the live scene and start driving. `view` is the viewport
# doing the 3D work (the PostProcess SubViewport in main.tscn); render times are
# measured there, falling back to this node's own viewport.
func setup(car: Node, progress: TrackProgress, centerline: Curve2D, view: Viewport = null) -> void:
	_car = car
	_progress = progress
	_centerline = centerline
	for stream in ["frame_ms", "draws", "objects", "prims", "render_cpu_ms",
			"render_gpu_ms", "process_ms", "physics_ms"]:
		_samples[stream] = []
	var target := view if view != null else get_viewport()
	_view_rid = target.get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(_view_rid, true)
	# Hand the car to the AI: unlocked, auto box, driven via the ai_* inputs.
	_car.controls_locked = false
	_car.handbrake_locked = false
	_car.ai_controlled = true
	_car.ai_throttle = 0.0
	_car.ai_steer = 0.0
	_car.ai_handbrake = false
	if "drivetrain" in _car and _car.drivetrain != null and _car.drivetrain.engine != null:
		_car.drivetrain.engine.auto = true
	_running = true


# --- Driving (physics tick) ----------------------------------------------------

func _physics_process(_delta: float) -> void:
	if not _running or not is_instance_valid(_car):
		return
	var offset := _progress.progress_offset()
	var aim := _centerline.sample_baked(minf(offset + LOOKAHEAD_M, _progress.baked_length()))
	_car.ai_steer = steer_toward(_car.global_transform, aim)
	var speed: float = (_car as RigidBody3D).linear_velocity.length() if _car is RigidBody3D else 0.0
	_car.ai_throttle = throttle_for(speed, TARGET_SPEED_MPS)
	if _progress.progress_percent() >= 1.0:
		_finish()


# Pure-pursuit steering: the ai_steer (-1..1, left positive) that turns the car
# toward `target` (an XZ road point). Positive heading error = target to the
# left (a Node3D's forward is -Z, +X is its right), matching the input axes.
static func steer_toward(car_xform: Transform3D, target: Vector2) -> float:
	var local := car_xform.affine_inverse() * Vector3(target.x, car_xform.origin.y, target.y)
	var heading_error := atan2(-local.x, -local.z)
	return clampf(heading_error * STEER_GAIN, -1.0, 1.0)


# Proportional speed hold: the ai_throttle (-1..1, forward positive) that pulls
# the speed toward the target — full throttle well below it, braking above it.
static func throttle_for(speed_mps: float, target_mps: float) -> float:
	return clampf((target_mps - speed_mps) * THROTTLE_GAIN, -1.0, 1.0)


# --- Sampling (render frames) --------------------------------------------------

func _process(delta: float) -> void:
	if not _running:
		return
	if _warmup_left > 0:
		# Let the first frames (car settling onto its wheels, first-visible shader
		# compiles) pass unrecorded so they don't pollute the stats.
		_warmup_left -= 1
		if _warmup_left == 0:
			_start_offset = _progress.progress_offset()
		return
	_samples["frame_ms"].append(delta * 1000.0)
	_samples["draws"].append(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	_samples["objects"].append(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME))
	_samples["prims"].append(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))
	_samples["render_cpu_ms"].append(RenderingServer.viewport_get_measured_render_time_cpu(_view_rid))
	_samples["render_gpu_ms"].append(RenderingServer.viewport_get_measured_render_time_gpu(_view_rid))
	_samples["process_ms"].append(Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0)
	_samples["physics_ms"].append(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0)


# --- Finish --------------------------------------------------------------------

func _finish() -> void:
	_running = false
	# Park the car: throttle off, handbrake on — it skids to a stop in the runoff
	# behind the results panel.
	_car.ai_throttle = 0.0
	_car.ai_steer = 0.0
	_car.ai_handbrake = true

	var stats := BenchmarkStats.summarise(_samples)
	stats["distance_m"] = maxf(0.0, _progress.progress_offset() - _start_offset)
	stats["disabled"] = _disabled_toggle_names()
	Benchmark.finish(stats)

	_results_screen = BenchmarkResults.new()
	add_child(_results_screen)
	_results_screen.setup(stats, _run_again, Benchmark.exit_to_hq)


# The display names of every toggle the player turned OFF for this run, so the
# results record what configuration produced them.
func _disabled_toggle_names() -> Array[String]:
	var names: Array[String] = []
	for t in Benchmark.TOGGLES:
		if not Benchmark.get_option(String(t["key"])):
			names.append(String(t["name"]))
	return names


# "Run again": reload the run scene. Benchmark.active stays true and the config
# overrides are still in place, so the same stage regenerates and re-runs.
func _run_again() -> void:
	get_tree().reload_current_scene()
