class_name PerfOverlay
extends CanvasLayer
# Diagnostic frame-profiling overlay. Toggled with P (`toggle_perf_overlay`).
#
# Choppiness is almost always intermittent frame-time SPIKES, not low average
# FPS, so this tool reports the breakdown that fingerprints the cause:
#   - frame total (current / avg / MAX over a window) -> spike vs steady
#   - CPU process + physics time            -> main-thread / script / collision
#   - render CPU vs render GPU time         -> CPU-bound vs GPU-bound (fill rate,
#                                              post-process shader, draw calls)
#   - draw calls / objects                  -> scene complexity
#   - chunks loaded + chunks integrated     -> correlate spikes with terrain work
#
# Hidden + idle by default (near-zero cost). Toggling on enables per-viewport
# render-time measurement and, on every frame over budget, prints a one-line
# [PERF SPIKE] report to stdout so spikes can be captured from a play session.

const SPIKE_MS := 28.0          # frame-time over budget => log a spike line
const WINDOW := 90              # rolling window for avg / max (frames)
const REFRESH_S := 0.2          # on-screen text refresh cadence

var terrain: TerrainManager     # for the chunk-integration correlation (optional)

var _label: Label
var _frames: PackedFloat32Array = PackedFloat32Array()
var _spikes := 0
var _last_integrations := 0     # terrain.integrations_total at the previous frame
var _refresh_accum := 0.0
var _measure_on := false


func _init(p_terrain: TerrainManager = null) -> void:
	terrain = p_terrain
	layer = 100  # draw above the HUD


func _ready() -> void:
	visible = false
	_label = Label.new()
	_label.position = Vector2(4, 4)
	_label.add_theme_font_size_override("font_size", 8)
	_label.add_theme_color_override("font_color", Color(0.6, 1.0, 0.6))
	_label.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	_label.add_theme_constant_override("outline_size", 2)
	add_child(_label)
	if terrain != null:
		_last_integrations = terrain.integrations_total


func _process(delta: float) -> void:
	if Input.is_action_just_pressed("toggle_perf_overlay"):
		_set_active(not visible)
	if not visible:
		return

	var frame_ms := delta * 1000.0
	_frames.append(frame_ms)
	if _frames.size() > WINDOW:
		_frames = _frames.slice(_frames.size() - WINDOW)

	var integ_this_frame := 0
	if terrain != null:
		integ_this_frame = terrain.integrations_total - _last_integrations
		_last_integrations = terrain.integrations_total

	var stats := _sample(frame_ms)
	if frame_ms >= SPIKE_MS:
		_spikes += 1
		print("[PERF SPIKE] frame=%.1fms process=%.1f physics=%.1f render_cpu=%.1f render_gpu=%.1f draws=%d objs=%d chunks_loaded=%d integrated_this_frame=%d" % [
			frame_ms, stats.process_ms, stats.physics_ms, stats.render_cpu_ms,
			stats.render_gpu_ms, stats.draws, stats.objects, stats.chunks, integ_this_frame])

	_refresh_accum += delta
	if _refresh_accum >= REFRESH_S:
		_refresh_accum = 0.0
		_label.text = _format(stats)


# Read all the per-frame metrics into a dictionary.
func _sample(frame_ms: float) -> Dictionary:
	var rid := get_viewport().get_viewport_rid()
	return {
		"fps": Engine.get_frames_per_second(),
		"frame_ms": frame_ms,
		"avg_ms": _avg(),
		"max_ms": _max(),
		"process_ms": Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
		"physics_ms": Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0,
		"render_cpu_ms": RenderingServer.viewport_get_measured_render_time_cpu(rid),
		"render_gpu_ms": RenderingServer.viewport_get_measured_render_time_gpu(rid),
		"draws": int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
		"objects": int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)),
		"prims": int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)),
		"chunks": terrain.loaded_coords().size() if terrain != null else 0,
	}


func _format(s: Dictionary) -> String:
	var gpu_note := "" if s.render_gpu_ms > 0.0 else "  (gpu timer unsupported)"
	return "\n".join([
		"FPS %d   frame %.1fms  (avg %.1f / MAX %.1f)" % [s.fps, s.frame_ms, s.avg_ms, s.max_ms],
		" cpu process %.1fms   physics %.1fms" % [s.process_ms, s.physics_ms],
		" render cpu %.1fms   gpu %.1fms%s" % [s.render_cpu_ms, s.render_gpu_ms, gpu_note],
		" draws %d   objects %d   prims %d" % [s.draws, s.objects, s.prims],
		" chunks loaded %d   spikes>%.0fms %d" % [s.chunks, SPIKE_MS, _spikes],
	])


func _set_active(on: bool) -> void:
	visible = on
	if on == _measure_on:
		return
	_measure_on = on
	# Per-viewport render-time measurement has a small cost; only while active.
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), on)
	if on:
		_frames = PackedFloat32Array()
		_spikes = 0
		if terrain != null:
			_last_integrations = terrain.integrations_total


func _avg() -> float:
	if _frames.is_empty():
		return 0.0
	var total := 0.0
	for f in _frames:
		total += f
	return total / _frames.size()


func _max() -> float:
	var m := 0.0
	for f in _frames:
		m = maxf(m, f)
	return m
