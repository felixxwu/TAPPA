class_name BenchmarkRunner
extends Node
# Docs: features/benchmark.md — update in the same change as this file.
# Tests: tests/headless/test_benchmark_mode.gd, tests/headless/test_benchmark_report.gd, tests/headless/test_benchmark_ui.gd — extend in the same change.
# Records the benchmark run (features/benchmark.md): per-frame timing/render samples
# while free roam's AutoDriver drives a route across the island, then the results
# breakdown (BenchmarkResults) when the time cap or the end of the route is reached.
#
# The car is driven through its real AI inputs (Car.ai_controlled), NOT teleported, so
# the run exercises the actual per-frame workload (streaming, vehicle physics, tyres,
# dust, marks, engine audio). Created and wired by free_roam.gd when Benchmark.active.
# The two pure driving helpers below are shared with AutoDriver.

const STEER_GAIN := 2.5               # rad of heading error -> full steering lock
const THROTTLE_GAIN := 0.5            # m/s of speed error -> full throttle/brake
const WARMUP_FRAMES := 60
# A steady, careful pace for the auto-driver: the run measures rendering, not lap times.
const TOP_SPEED_MPS := 22.0
const LATERAL_ACCEL := 3.5
const BRAKE_DECEL := 4.0             # settle/shader-compile frames left unsampled
const MAX_RUN_SECONDS := 30.0         # hard cap on sampled driving: the run is time-boxed

var _car: Node                        # the fielded Car (VehicleBody3D)
var _driver: AutoDriver               # drives the route; its driven_m is the distance
var _view_rid: RID                    # viewport whose render times we sample
var _running := false
var _warmup_left := WARMUP_FRAMES
var _start_driven_m := 0.0            # driver.driven_m when sampling began
var _samples := {}                    # stream name -> Array of per-frame values
var _spike_frames: Array = []         # per-spike component breakdown (diagnostics)
var _frame_no := 0                    # sampled-frame index (spike timeline)
var _terrain: Node                    # TerrainManager, for spike↔chunk-integration correlation
var _last_integrations := 0           # integrations_total at the previous sampled frame
var _engine_audio: Node               # the fielded car's EngineAudio, for overrun (skip) tracking
var _last_skips := 0                  # skip_count() at the previous sampled frame
var _audio_skips_total := 0           # generator underruns over the sampled window
var _spike_ms := BenchmarkStats.SPIKE_MS  # spike threshold, relative to the fps cap (see setup)
var _run_time := 0.0                  # sampled driving time; the run finishes at MAX_RUN_SECONDS
var _results_screen: BenchmarkResults
var _last_frame_usec := 0              # wall clock at the previous sampled frame
var _queue_timeline: Array = []        # [run seconds, queued jobs, budget ms, jobs due now, due by kind], about once a second


# The TRUE elapsed time since the previous sampled frame, in ms.
#
# Deliberately NOT `_process`'s `delta`: Godot applies delta smoothing
# (`application/run/delta_smoothing`, on by default) which snaps the reported
# delta to integer divisors of the estimated refresh rate to hide judder from
# gameplay code. That is right for physics/animation and WRONG for a profiler —
# measured on this stage, smoothing reported p99 8.3 ms / max 25 ms while the
# real intervals were p99 16.6 ms / max 40 ms, so real hitches were averaged
# away and the `spikes >= _spike_ms` counter read 0 through genuine 30-40 ms
# frames. The monotonic wall clock is unsmoothed, so spikes survive.
#
# Note also that Performance.TIME_PROCESS / TIME_PHYSICS_PROCESS (sampled below)
# are NOT per-frame values: the engine publishes them once per second, and each
# is the MAXIMUM over that second. They are useful as a worst-frame indicator per
# second, but must never be read as "this frame's cost".
func _frame_interval_ms() -> float:
	var now := Time.get_ticks_usec()
	var elapsed := now - _last_frame_usec
	_last_frame_usec = now
	return float(elapsed) / 1000.0


# Wire the runner to the live scene and start sampling. `view` is the viewport doing
# the 3D work (the PostProcess SubViewport); render times are measured there, falling
# back to this node's own viewport.
func setup(car: Node, driver: AutoDriver, view: Viewport = null, terrain: Node = null) -> void:
	_car = car
	_driver = driver
	driver.top_speed_mps = TOP_SPEED_MPS
	driver.lateral_accel = LATERAL_ACCEL
	driver.brake_decel = BRAKE_DECEL
	if driver.running:
		driver.place_on_route(0)  # the route starts at the nearest junction, which can be behind the car
	_terrain = terrain
	driver.finished.connect(func(_r: Dictionary) -> void: _finish())
	_engine_audio = car.get_node_or_null("EngineAudio")
	# Spike threshold relative to the frame cap (Engine.max_fps was set by
	# world._ready): 0 = uncapped → 28 ms; a 30 fps cap → ~50 ms, so a 33 ms normal
	# frame isn't miscounted as a spike (the fixed 28 ms flagged every 30 fps frame).
	_spike_ms = BenchmarkStats.spike_threshold_ms(Engine.max_fps)
	_samples.clear()
	for stream in ["frame_ms", "draws", "objects", "prims", "render_cpu_ms",
			"render_gpu_ms", "process_ms", "physics_ms"]:
		_samples[stream] = []
	var target := view if view != null else get_viewport()
	_view_rid = target.get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(_view_rid, true)
	_running = true



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
			_start_driven_m = _driver.driven_m
			# Open the per-script CPU capture window over the SAME frames we sample
			# below, so the scripts breakdown lines up with the render stats.
			PerfLog.begin_capture()
			# Baseline the audio-skip counter so warm-up underruns (shader compiles)
			# don't count against the measured window.
			if _engine_audio != null and _engine_audio.has_method("skip_count"):
				_last_skips = _engine_audio.skip_count()
			# Baseline the wall clock so the first sampled interval measures a real
			# frame, not the span back into warm-up. See _frame_interval_ms.
			_last_frame_usec = Time.get_ticks_usec()
		return
	var frame_ms := _frame_interval_ms()
	var rcpu := RenderingServer.viewport_get_measured_render_time_cpu(_view_rid)
	var proc := Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
	var phys := Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
	_samples["frame_ms"].append(frame_ms)
	_samples["draws"].append(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	_samples["objects"].append(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME))
	_samples["prims"].append(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))
	_samples["render_cpu_ms"].append(rcpu)
	_samples["render_gpu_ms"].append(RenderingServer.viewport_get_measured_render_time_gpu(_view_rid))
	_samples["process_ms"].append(proc)
	_samples["physics_ms"].append(phys)
	# Spike diagnostics: on a dropped frame, record which component was hot so the
	# report can attribute the hitch (render_cpu ⇒ shader compile / render stall,
	# physics ⇒ collision/ragdoll, process ⇒ script/GC/terrain build). `_frame_no`
	# is the sampled-frame index so spikes can be located in time along the run.
	# Terrain chunk integrations since the last sampled frame — a chunk spawned on a
	# spike frame implicates chunk streaming (mesh/collision build) as the cause.
	var integ := 0
	if _terrain != null and "integrations_total" in _terrain:
		var total: int = _terrain.integrations_total
		integ = total - _last_integrations
		_last_integrations = total
	# Audio overruns (generator buffer underruns) since the last sampled frame — a
	# skip on a slow frame implicates main-thread audio starvation (the fill runs in
	# _process; a long frame drains the buffer). Correlated with the spike breakdown.
	var skips := 0
	if _engine_audio != null and _engine_audio.has_method("skip_count"):
		var total_skips: int = _engine_audio.skip_count()
		skips = total_skips - _last_skips
		_last_skips = total_skips
		_audio_skips_total += skips
	if frame_ms >= _spike_ms:
		_spike_frames.append({
			"frame": _frame_no, "frame_ms": frame_ms,
			"render_cpu_ms": rcpu, "process_ms": proc, "physics_ms": phys,
			"chunk_integrations": integ, "audio_skips": skips,
		})
	_frame_no += 1
	if _terrain is TerrainStreamer and int(_run_time) >= _queue_timeline.size():
		var st := _terrain as TerrainStreamer
		_queue_timeline.append([snappedf(_run_time, 0.1), st.queued(), snappedf(st.budget_us(delta) / 1000.0, 0.01), st.queued_due(), st.due_by_kind()])
	_run_time += delta
	if _run_time >= MAX_RUN_SECONDS:
		_finish()


# --- Finish --------------------------------------------------------------------

func _finish() -> void:
	if not _running:
		return  # already finished (time cap + progress could both fire the same frame)
	_running = false
	# Park the car behind the results panel.
	_driver.running = false
	_car.ai_throttle = 0.0
	_car.ai_steer = 0.0
	_car.ai_handbrake = true

	var stats := BenchmarkStats.summarise(_samples, _spike_ms)
	stats["distance_m"] = maxf(0.0, _driver.driven_m - _start_driven_m)
	stats["disabled"] = _disabled_toggle_names()
	# The worst spikes (by frame time), with their component breakdown, so the report
	# can attribute the hitches. Sorted descending, capped so the payload stays small.
	_spike_frames.sort_custom(func(a, b): return a["frame_ms"] > b["frame_ms"])
	stats["spike_frames"] = _spike_frames.slice(0, 20)
	stats["audio_skips"] = _audio_skips_total
	stats["pass"] = Benchmark.pass_index
	if _terrain is TerrainStreamer:
		stats["terrain"] = terrain_stats(_terrain as TerrainStreamer, _queue_timeline)
	var scripts := PerfLog.end_capture(_samples["frame_ms"].size())
	Benchmark.finish(stats)
	_report(stats, scripts)

	# Two-pass spike diagnosis: after the cold pass, reset and drive the SAME stage
	# again in the same page (warm WebGL shader/texture cache) instead of showing
	# results, so comparing pass 0 vs pass 1 spikes isolates first-use GPU stalls.
	if Benchmark.two_pass and Benchmark.pass_index == 0:
		Benchmark.pass_index = 1
		# Let the POST flush, then scene-reload (NOT a page reload — the GL context
		# and its compiled shaders must persist for the warm pass).
		await get_tree().create_timer(1.0).timeout
		Benchmark.seat_world()
		get_tree().reload_current_scene()
		return

	_results_screen = BenchmarkResults.new()
	add_child(_results_screen)
	_results_screen.setup(stats, _run_again, Benchmark.exit_to_hq)


# How the terrain streamer kept up over the run: the queue over time, its work per frame, and
# what each kind of unit cost on this device.
static func terrain_stats(st: TerrainStreamer, queue_timeline: Array) -> Dictionary:
	var counts := st.chunk_counts()
	return {
		"queue_timeline": queue_timeline,
		"queued_at_end": st.queued(),
		"due_at_end": st.queued_due(),
		"avg_ms_per_frame": st.stat_total_us / 1000.0 / maxi(1, st.stat_frames),
		"worst_ms": st.stat_worst_us / 1000.0,
		"overruns": st.stat_overruns,
		"rushes": st.stat_rushes,
		"chunks": {"mid": counts.x, "far": counts.y, "collision": counts.z},
		"us_per_sample": st.stat_us_per_sample,
		"unit_cost_us": st._est.duplicate(),
	}


# --- Result reporting (feedback loop) ------------------------------------------

# POST the run's report to the dev machine so it lands in build/bench-results/
# for analysis (features/benchmark.md → "Feedback loop"). Fire-and-forget: the
# results panel shows whether it was delivered. Skipped headless / when no URL
# resolves (desktop dev without bench_report_url set).
func _report(stats: Dictionary, scripts: Dictionary) -> void:
	var url := _resolve_report_url()
	if url == "" or Platform.is_headless():
		return
	var device := BenchmarkReport.probe_device()
	var label := BenchmarkReport.make_label(
		String(device.get("build_version", "")), stats.get("disabled", []),
		Benchmark.render_height)
	if Benchmark.two_pass:
		label += "-warm" if int(stats.get("pass", 0)) == 1 else "-cold"
	if Benchmark.tree_mode >= 0:
		label += "_trees%d" % Benchmark.tree_mode
	var stamp := Time.get_datetime_string_from_system(true)
	var report := BenchmarkReport.build(stats, scripts, device, stamp, label)
	var body := BenchmarkReport.to_json(report)

	if _results_screen != null:
		_results_screen.set_report_status("reporting…")
	var http := HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(_on_report_done)
	var err := http.request(url, ["Content-Type: application/json"],
		HTTPClient.METHOD_POST, body)
	if err != OK and _results_screen != null:
		_results_screen.set_report_status("report failed (request error %d)" % err)


func _on_report_done(_result: int, code: int, _headers: PackedStringArray,
		_body: PackedByteArray) -> void:
	if _results_screen == null:
		return
	if code == 200:
		_results_screen.set_report_status("reported ✓")
	else:
		_results_screen.set_report_status("report failed (HTTP %d)" % code)


# The endpoint to POST results to. An explicit GameConfig.bench_report_url wins
# (set it on an installed APK to reach your dev machine). Otherwise, on a web
# build, POST to "/bench" on the page's own origin — the serve_web.sh collector —
# so the LAN loop is zero-config. Empty everywhere else (desktop dev).
func _resolve_report_url() -> String:
	var configured := String(Config.data.bench_report_url)
	if configured != "":
		return configured
	if Platform.is_web():
		var origin = JavaScriptBridge.eval("window.location.origin", true)
		if origin != null:
			return String(origin) + "/bench"
	return ""


# The display names of every toggle the player turned OFF for this run, so the
# results record what configuration produced them.
func _disabled_toggle_names() -> Array[String]:
	var names: Array[String] = []
	for t in Benchmark.TOGGLES:
		if not Benchmark.get_option(String(t["key"])):
			names.append(String(t["name"]))
	return names


# "Run again": reload the scene on a fresh benchmark world. Benchmark.active stays true
# and the config overrides are still in place, so the same drive re-runs.
func _run_again() -> void:
	Benchmark.seat_world()
	get_tree().reload_current_scene()
