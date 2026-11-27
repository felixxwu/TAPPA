class_name FrameSampler
extends Node
# Docs: features/adaptive-graphics.md — update in the same change as this file.
## Times every drawn frame for the adaptive graphics controller: main-thread work minus terrain,
## ground-cover and tree loading, the renderer's GPU time where the platform reports it, and draw counts.

signal sampled(s: Dictionary)

const LOAD_KEYS: Array[StringName] = [&"terrain_streamer", &"ground_cover", &"trees_pump"]

var viewports: Array[RID] = []
var _frame_start_us := 0
var _last_drawn_us := 0


static func budget_ms() -> float:
	var cap := FpsSetting.resolve()
	return 1000.0 / float(cap if cap > 0 else 60)


## Main-thread cost of a frame once its loading work is taken out.
static func cost_of(busy_ms: float, load_ms: float) -> float:
	return maxf(0.0, busy_ms - load_ms)


func watch(vps: Array[RID]) -> void:
	viewports = vps
	for vp in vps:
		RenderingServer.viewport_set_measure_render_time(vp, true)


func _ready() -> void:
	get_tree().physics_frame.connect(_mark_start)
	get_tree().process_frame.connect(_mark_start)
	RenderingServer.frame_post_draw.connect(_on_drawn)


func _exit_tree() -> void:
	if RenderingServer.frame_post_draw.is_connected(_on_drawn):
		RenderingServer.frame_post_draw.disconnect(_on_drawn)


func _mark_start() -> void:
	if _frame_start_us == 0:
		_frame_start_us = Time.get_ticks_usec()


func _on_drawn() -> void:
	var now := Time.get_ticks_usec()
	if _frame_start_us != 0 and _last_drawn_us != 0:
		sampled.emit(sample(now))
	_last_drawn_us = now
	_frame_start_us = 0
	PerfLog.clear_frame()


func sample(now_us: int) -> Dictionary:
	var busy := (now_us - _frame_start_us) / 1000.0
	var load_us := 0
	for key in LOAD_KEYS:
		load_us += PerfLog.frame_us(key)
	var gpu := 0.0
	for vp in viewports:
		gpu += RenderingServer.viewport_get_measured_render_time_gpu(vp)
	return {
		"busy_ms": busy,
		"load_ms": load_us / 1000.0,
		"cost_ms": cost_of(busy, load_us / 1000.0),
		"gpu_ms": gpu,
		"interval_ms": (now_us - _last_drawn_us) / 1000.0,
		"budget_ms": budget_ms(),
		"draws": RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME),
		"prims": RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME),
	}
