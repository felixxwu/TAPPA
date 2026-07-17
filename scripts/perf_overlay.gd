class_name PerfOverlay
extends CanvasLayer
# Diagnostic frame-profiling overlay. Toggled with P (`toggle_perf_overlay`);
# forced on for the whole run in benchmark mode (features/benchmark.md).
#
# Choppiness is almost always intermittent frame-time SPIKES, not low average
# FPS, so this tool reports the breakdown that fingerprints the cause:
#   - frame total (current / avg / MAX over a window) -> spike vs steady
#   - CPU process + physics time            -> main-thread / script / collision
#   - render CPU vs render GPU time         -> CPU-bound vs GPU-bound (fill rate,
#                                              post-process shader, draw calls)
#   - draw calls / objects / prims          -> scene complexity
#   - video memory / node counts            -> resource + tree pressure
#   - chunks loaded + chunks integrated     -> correlate spikes with terrain work
#
# Hidden + idle by default (near-zero cost). Toggling on enables per-viewport
# render-time measurement and, on every frame over budget, prints a one-line
# [PERF SPIKE] report to stdout so spikes can be captured from a play session.

const SPIKE_MS := 28.0          # frame-time over budget => log a spike line
const WINDOW := 90              # rolling window for avg / max (frames)
const REFRESH_S := 0.2          # on-screen text refresh cadence
const FONT_SIZE := 15           # readable at a glance (the old 8px was too small)

var terrain: TerrainManager     # for the chunk-integration correlation (optional)
var engine_audio: Node          # fielded car's EngineAudio, for live audio-overrun readout (optional)
# The viewport whose render cpu/gpu time is measured. Defaults to this node's own
# viewport; world.gd points it at the PostProcess SubViewport, which is where the
# 3D pass actually runs in main.tscn (the root viewport's 3D is disabled there).
var measure_viewport: Viewport

var _label: Label
var _frames: PackedFloat32Array = PackedFloat32Array()
var _spikes := 0
var _spike_ms := SPIKE_MS        # spike threshold, relative to the fps cap (set on activate)
var _last_integrations := 0     # terrain.integrations_total at the previous frame
var _audio_skips := 0           # cumulative engine-audio buffer underruns since activate
var _last_skips := 0            # engine_audio.skip_count() at the previous frame
var _refresh_accum := 0.0
var _measure_on := false


func _init(p_terrain: TerrainManager = null) -> void:
	terrain = p_terrain
	layer = 100  # draw above the HUD


func _ready() -> void:
	visible = false
	_label = Label.new()
	_label.position = Vector2(4, 4)
	_label.add_theme_font_size_override("font_size", FONT_SIZE)
	_label.add_theme_color_override("font_color", Color(0.6, 1.0, 0.6))
	_label.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	_label.add_theme_constant_override("outline_size", 3)
	add_child(_label)
	if terrain != null:
		_last_integrations = terrain.integrations_total


# Force the overlay on (benchmark mode) — same path as the P toggle.
func activate() -> void:
	_set_active(true)


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

	# Audio overruns since last frame (engine generator buffer underruns) — an
	# audible crackle, and the live signal for main-thread audio starvation.
	var skips_this_frame := 0
	if engine_audio != null and engine_audio.has_method("skip_count"):
		var total_skips: int = engine_audio.skip_count()
		skips_this_frame = total_skips - _last_skips
		_last_skips = total_skips
		_audio_skips += skips_this_frame

	var stats := _sample(frame_ms)
	if frame_ms >= _spike_ms or skips_this_frame > 0:
		_spikes += 1 if frame_ms >= _spike_ms else 0
		print("[PERF SPIKE] frame=%.1fms process=%.1f physics=%.1f render_cpu=%.1f render_gpu=%.1f draws=%d objs=%d chunks_loaded=%d integrated_this_frame=%d audio_skips=%d" % [
			frame_ms, stats.process_ms, stats.physics_ms, stats.render_cpu_ms,
			stats.render_gpu_ms, stats.draws, stats.objects, stats.chunks, integ_this_frame, skips_this_frame])

	_refresh_accum += delta
	if _refresh_accum >= REFRESH_S:
		_refresh_accum = 0.0
		_label.text = _format(stats)


# The viewport whose render time is measured (see measure_viewport).
func _measure_rid() -> RID:
	var vp := measure_viewport if measure_viewport != null else get_viewport()
	return vp.get_viewport_rid()


# Read all the per-frame metrics into a dictionary.
func _sample(frame_ms: float) -> Dictionary:
	var rid := _measure_rid()
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
		"vram_mb": Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0,
		"texram_mb": Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED) / 1048576.0,
		"nodes": int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
		"phys_objects": int(Performance.get_monitor(Performance.PHYSICS_3D_ACTIVE_OBJECTS)),
		"chunks": terrain.loaded_coords().size() if terrain != null else 0,
	}


func _format(s: Dictionary) -> String:
	var gpu_note := "" if s.render_gpu_ms > 0.0 else "  (gpu timer unsupported)"
	return "\n".join([
		"FPS %d   frame %.1fms  (avg %.1f / MAX %.1f)" % [s.fps, s.frame_ms, s.avg_ms, s.max_ms],
		" cpu process %.1fms   physics %.1fms" % [s.process_ms, s.physics_ms],
		" render cpu %.1fms   gpu %.1fms%s" % [s.render_cpu_ms, s.render_gpu_ms, gpu_note],
		" draws %d   objects %d   prims %d" % [s.draws, s.objects, s.prims],
		" vram %.0fMB (tex %.0fMB)   nodes %d   phys objs %d" % [s.vram_mb, s.texram_mb, s.nodes, s.phys_objects],
		" chunks loaded %d   spikes>%.0fms %d   audio overruns %d" % [s.chunks, _spike_ms, _spikes, _audio_skips],
	])


func _set_active(on: bool) -> void:
	visible = on
	if on == _measure_on:
		return
	_measure_on = on
	# Per-viewport render-time measurement has a small cost; only while active.
	RenderingServer.viewport_set_measure_render_time(_measure_rid(), on)
	if on:
		_frames = PackedFloat32Array()
		_spikes = 0
		# Threshold relative to the fps cap so a 30 fps run's 33 ms frames aren't all
		# flagged (the fixed 28 ms did exactly that). Matches BenchmarkRunner.
		_spike_ms = BenchmarkStats.spike_threshold_ms(Engine.max_fps)
		_audio_skips = 0
		if engine_audio != null and engine_audio.has_method("skip_count"):
			_last_skips = engine_audio.skip_count()
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
