extends Node
## Debug perf logger: prints Performance monitors once per second so CPU cost
## can be read back from the Godot log after a play session. Debug builds only.

const INTERVAL := 1.0

var _accum := 0.0
var _frames := 0
var _script_us: Dictionary = {}  # StringName -> accumulated usec since last print

## Called by the timing wrappers around per-frame callbacks (see e.g.
## car.gd._physics_process). Accumulates cost per script between prints.
func track(key: StringName, usec: int) -> void:
	_script_us[key] = int(_script_us.get(key, 0)) + usec

func _ready() -> void:
	if not OS.is_debug_build():
		set_process(false)

func _process(delta: float) -> void:
	_accum += delta
	_frames += 1
	if _accum < INTERVAL:
		return
	_accum = 0.0
	var fps := Performance.get_monitor(Performance.TIME_FPS)
	var frame_ms := Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
	var physics_ms := Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
	var nav_ms := Performance.get_monitor(Performance.TIME_NAVIGATION_PROCESS) * 1000.0
	var draw_calls := Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
	var objects := Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)
	var primitives := Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)
	var mem_mb := Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0
	print("[perf] fps=%d process=%.2fms physics=%.2fms nav=%.2fms draw_calls=%d objects=%d prims=%d mem=%.1fMB" % [
		fps, frame_ms, physics_ms, nav_ms, draw_calls, objects, primitives, mem_mb,
	])
	if not _script_us.is_empty() and _frames > 0:
		var keys := _script_us.keys()
		keys.sort_custom(func(a, b): return _script_us[a] > _script_us[b])
		var parts: PackedStringArray = []
		for key in keys:
			parts.append("%s=%.3f" % [key, _script_us[key] / 1000.0 / _frames])
		print("[perf-scripts] ms/frame: " + " ".join(parts))
	_script_us.clear()
	_frames = 0
