extends Node
# Standalone performance benchmark — NOT part of the test suite. Run on demand
# to investigate choppiness:
#
#     ./run_benchmark.sh              # windowed: captures CPU *and* GPU/render
#     ./run_benchmark.sh --headless   # CPU-only (no GPU timing), quick
#
# Two halves:
#   CPU     — chunk-loading cost on the main thread (compute_chunk_data,
#             _spawn_chunk, a simulated boundary crossing against the cache).
#   RENDER  — per-frame render cpu/gpu time for the real main.tscn, so a
#             GPU-bound frame (fill rate, the full-screen PS1 post-process,
#             per-cell terrain) is distinguishable from a CPU one. Needs a real
#             display; under --headless the renderer is a dummy (timers read 0)
#             so this half is skipped.
#
# Prints a report to stdout and quits. Loose, machine-dependent numbers — read
# them, don't gate on them.

const ManagerScript := preload("res://scripts/terrain_manager.gd")
const RENDER_FRAMES := 150
const WARMUP := 30
const DRIVE_FRAMES := 600        # frames to measure while moving
const DRIVE_SPEED := 35.0        # m/s (~126 km/h) — fast enough to cross boundaries
const SPIKE_MS := 28.0           # frame interval over this counts as a dropped-frame spike


func _ready() -> void:
	print("\n=== rally performance benchmark ===")
	print("display: %s   (%s)\n" % [
		DisplayServer.get_name(),
		"windowed — GPU timing available" if not _headless() else "headless — CPU only"])
	_bench_cpu()
	await _bench_render()
	await _bench_drive()
	print("\n=== benchmark complete ===")
	get_tree().quit()


func _headless() -> bool:
	return DisplayServer.get_name() == "headless"


func _make_manager() -> Node3D:
	var m := Node3D.new()
	m.set_script(ManagerScript)
	m.focus_path = NodePath("")
	m.noise_seed = 1337
	var layers: Array[TerrainLayer] = []
	for params in [[60.0, 1.5], [15.0, 0.4], [3.0, 0.1]]:
		var layer := TerrainLayer.new()
		layer.wavelength_m = params[0]
		layer.amplitude_m = params[1]
		layers.append(layer)
	m.layers = layers
	# The shipped config bakes terrain lighting (terrain_light_amount = 1.0), which
	# more than doubles compute_chunk_data's cost (the per-vertex light bake). Match
	# it here so the benchmark reflects the real chunk-build cost, not an unlit one.
	m.light_amount = 1.0
	return m


func _report(label: String, samples: Array, note: String = "") -> void:
	var total := 0.0
	var worst := 0.0
	for ms in samples:
		total += ms
		worst = maxf(worst, ms)
	var avg: float = total / maxf(samples.size(), 1)
	print("  %-26s avg %7.2f ms   max %7.2f ms   (n=%d) %s"
		% [label, avg, worst, samples.size(), note])


func _bench_cpu() -> void:
	print("-- CPU: chunk loading --")
	var m := _make_manager()
	add_child(m)

	# Load-time precompute cost: noise + de-indexed mesh arrays. Distinct coords so
	# noise can't be cached.
	var compute: Array = []
	for cz in range(6):
		for cx in range(6):
			var t0 := Time.get_ticks_usec()
			m.compute_chunk_data(Vector2i(cx + 100, cz + 100))
			compute.append((Time.get_ticks_usec() - t0) / 1000.0)
	_report("compute_chunk_data", compute, "(load-time precompute cost)")

	# Main-thread cost: build the ArrayMesh + HeightMapShape3D and add the node —
	# the per-frame hitch suspect (runtime caps this to 1/frame).
	var spawn: Array = []
	for cz in range(5):
		for cx in range(5):
			var coord := Vector2i(cx + 200, cz + 200)
			var data: Dictionary = m.compute_chunk_data(coord)  # untimed
			var t0 := Time.get_ticks_usec()
			m._spawn_chunk(coord, data)
			spawn.append((Time.get_ticks_usec() - t0) / 1000.0)
	_report("spawn_chunk (integrate)", spawn, "(main thread, cache spawn at runtime)")

	# One straight-line boundary crossing reconciles the ring and integrates a new
	# row. Synchronous here; at runtime spread over (2*RADIUS+1) frames.
	var crossing: Array = []
	var step: float = ManagerScript.CHUNK_M
	m.update_focus(Vector3.ZERO)
	for i in range(1, 11):
		var t0 := Time.get_ticks_usec()
		m.update_focus(Vector3(i * step, 0.0, 0.0))
		crossing.append((Time.get_ticks_usec() - t0) / 1000.0)
	_report("boundary crossing (row)", crossing,
		"(load-time only; runtime crossings pull from cache)")

	m.queue_free()


func _bench_render() -> void:
	print("\n-- RENDER: real scene --")
	if _headless():
		print("  skipped (headless: no GPU timing). Run windowed: ./run_benchmark.sh")
		return

	# GPU timestamp queries are unsupported on several backends (OpenGL/macOS),
	# so the real signal is the wall-clock frame interval. To expose render cost
	# we must uncap fps and disable vsync — otherwise the interval is pinned to
	# the refresh rate and hides all headroom. (Restored after the run.)
	var prev_max_fps := Engine.max_fps
	var prev_vsync := DisplayServer.window_get_vsync_mode(0)
	Engine.max_fps = 0
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)

	var scene: Node3D = load("res://main.tscn").instantiate()
	add_child(scene)
	# The 3D world renders through the PostProcess SubViewport (the root
	# viewport's 3D pass is disabled while main.tscn is in the tree) — measure
	# the viewport that actually does the 3D work.
	var view := scene.get_node_or_null("PostProcess/View") as SubViewport
	var rid := view.get_viewport_rid() if view != null else get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(rid, true)

	for _i in WARMUP:
		await get_tree().process_frame

	var cpu: Array = []
	var gpu: Array = []
	var frame: Array = []   # real wall-clock interval between presented frames (ms)
	var last := Time.get_ticks_usec()
	for _i in RENDER_FRAMES:
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		frame.append((now - last) / 1000.0)
		last = now
		cpu.append(RenderingServer.viewport_get_measured_render_time_cpu(rid))
		gpu.append(RenderingServer.viewport_get_measured_render_time_gpu(rid))

	_report("render cpu", cpu)
	_report("render gpu", gpu)
	_report("frame interval (vsync off)", frame, "(p95 %.2f ms)" % _percentile(frame, 0.95))
	print("  draws %d   objects %d   prims %d" % [
		int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
		int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)),
		int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))])

	var gpu_avg := 0.0
	for v in gpu:
		gpu_avg += v
	if gpu_avg <= 0.0:
		print("  note: GPU timer unsupported on this backend (e.g. OpenGL/macOS).")
		print("        With vsync off, frame interval ≈ GPU+present cost since")
		print("        render-cpu and CPU work are tiny — that's the GPU signal.")

	Engine.max_fps = prev_max_fps
	DisplayServer.window_set_vsync_mode(prev_vsync)
	scene.queue_free()


func _percentile(samples: Array, q: float) -> float:
	if samples.is_empty():
		return 0.0
	var sorted := samples.duplicate()
	sorted.sort()
	var idx := int(clampf(q * (sorted.size() - 1), 0, sorted.size() - 1))
	return sorted[idx]


# Drive the viewpoint across chunk boundaries and measure the REAL per-frame
# interval — the scenario where choppiness actually shows up. Chunks are now
# precomputed and served from the cache, so this measures cache-spawn cost, not
# generation. vsync ON (the felt experience): spikes that line up with chunk
# integration ⇒ cache-spawn cost; frequent jitter with no integrations and low
# render cost ⇒ frame pacing.
func _bench_drive() -> void:
	print("\n-- DRIVE: scene in motion (cache-spawn cost) --")
	if _headless():
		print("  note: headless — interval reflects CPU only (no GPU/vsync pacing).")

	var prev_vsync := DisplayServer.window_get_vsync_mode(0)
	if not _headless():
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED)

	var scene: Node3D = load("res://main.tscn").instantiate()
	add_child(scene)
	await get_tree().process_frame  # let _ready build the initial ring + track

	var car := scene.get_node_or_null("Car") as Node3D
	var floor_node := scene.get_node_or_null("Floor")
	if car == null or floor_node == null:
		print("  skipped: scene missing Car/Floor")
		scene.queue_free()
		DisplayServer.window_set_vsync_mode(prev_vsync)
		return

	# Freeze physics so scripted motion is exact (the focus still drives terrain
	# streaming; collision shapes are still added/removed as chunks load).
	if car is RigidBody3D:
		(car as RigidBody3D).freeze = true

	for _i in WARMUP:
		await get_tree().process_frame

	var start: Vector3 = car.global_position
	var pos: Vector3 = start
	var integ0: int = floor_node.integrations_total
	var frame: Array = []
	var spikes := 0
	var spikes_with_integ := 0
	var last := Time.get_ticks_usec()
	var prev_integ: int = floor_node.integrations_total
	for _i in DRIVE_FRAMES:
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		var dt_ms := (now - last) / 1000.0
		last = now
		frame.append(dt_ms)
		var integrated: int = floor_node.integrations_total - prev_integ
		prev_integ = floor_node.integrations_total
		if dt_ms >= SPIKE_MS:
			spikes += 1
			if integrated > 0:
				spikes_with_integ += 1
		pos.x += DRIVE_SPEED / 60.0   # fixed virtual step => deterministic distance
		car.global_position = pos

	var integrated_total: int = floor_node.integrations_total - integ0
	_report("frame interval (driving)", frame, "(p95 %.2f ms)" % _percentile(frame, 0.95))
	print("  drove %.0f m   chunks integrated %d   spikes>%.0fms %d (%d on an integration frame) / %d frames" % [
		car.global_position.distance_to(start), integrated_total,
		SPIKE_MS, spikes, spikes_with_integ, DRIVE_FRAMES])

	scene.queue_free()
	DisplayServer.window_set_vsync_mode(prev_vsync)
