class_name AdaptiveGraphics
extends Node
# Docs: features/adaptive-graphics.md — update in the same change as this file.
## Keeps the level view inside its frame budget by tuning LevelKnobs live: samples each frame,
## feeds the AdaptiveController, and remembers what it learned on this device between sessions.

static var save_path := "user://adaptive_graphics.json"
const SAVE_EVERY_S := 30.0
const JUMP_M := 30.0  # the car moving this far in one frame was teleported, not driven

static var state: Dictionary = {}  # the controller's to_dict(), kept across the level's reloads
static var force_on := false  # the level replay's --adaptive: run it even while benchmarking
static var events: Array = []  # [{t, id, level}] every change, for the replay report

var controller := AdaptiveController.new()
var sampler: FrameSampler
var view: LevelView
var _levels := {}
var _last_car := Vector3.INF
var _was_live := false
var _save_at := 0.0


func setup(v: LevelView) -> void:
	view = v
	controller.knobs = LevelKnobs.build(v)
	if (Benchmark.active and not force_on) or not Config.data.adaptive_enabled:
		controller.enabled = false
		for k in controller.knobs:
			k.set_level(k.top())
		return
	if state.is_empty() and not Benchmark.active:
		state = load_file(save_path)
	controller.from_dict(state, _now())
	for k in controller.knobs:
		k.set_level(k.level)
		_levels[k.id] = k.level
	sampler = FrameSampler.new()
	add_child(sampler)
	var vps: Array[RID] = [get_viewport().get_viewport_rid()]
	var pp := v.effect("PostProcess/View") as Viewport
	if pp != null:
		vps.append(pp.get_viewport_rid())
	sampler.watch(vps)
	sampler.sampled.connect(_on_sample)
	_save_at = _now() + SAVE_EVERY_S


func disturbed() -> void:
	controller.disturbed(_now())


static func load_file(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var json := JSON.new()
	if json.parse(FileAccess.get_file_as_string(path)) != OK:
		return {}
	return json.data if json.data is Dictionary else {}


func save() -> void:
	state = controller.to_dict()
	if Benchmark.active:
		return  # a benchmark's drive isn't this device's normal play
	var f := FileAccess.open(save_path, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(state))


func _exit_tree() -> void:
	if controller.enabled and sampler != null:
		save()


func _now() -> float:
	return Time.get_ticks_usec() / 1e6


# Loading (terrain, cover, tree repacks) is already left out of the frame cost, so a change can be
# measured unless the terrain is scrambling to build the car's path, which shifts the whole frame.
func _quiet(streamer: LevelStreamer) -> bool:
	return streamer == null or not streamer.near_overdue()


func _on_sample(s: Dictionary) -> void:
	var now := _now()
	var live := view.hud_visible() and not view.is_rendering()
	if is_instance_valid(view._car):
		var pos := view._car.global_position
		if _last_car != Vector3.INF and pos.distance_to(_last_car) > JUMP_M:
			controller.disturbed(now)
		_last_car = pos
	if not live:
		_was_live = false
		return
	if not _was_live:
		_was_live = true
		controller.disturbed(now)
	var streamer := view._streamer
	s["now_s"] = now
	s["quiet"] = _quiet(streamer)
	s["near_misses"] = streamer.stat_near_misses if streamer != null else -1
	controller.feed(s)
	for k in controller.knobs:
		if _levels.get(k.id, -1) != k.level:
			_levels[k.id] = k.level
			events.append({"t": now, "id": String(k.id), "level": k.level})
	if streamer != null:
		var spare := maxf(0.0, float(s["budget_ms"]) - maxf(float(s["cost_ms"]), float(s["gpu_ms"])))
		streamer.spare_us = lerpf(streamer.spare_us, spare * 1000.0, 0.1)
	if now >= _save_at:
		_save_at = now + SAVE_EVERY_S
		save()
