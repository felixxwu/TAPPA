extends Node
# Docs: features/world-session.md — update in the same change as this file.
# The game's main scene: loads straight into the world, which shows the title menu over itself.
# A first-time player gets a world built with the cold-open car and drives the cold open instead.


func _ready() -> void:
	if Platform.is_web() and str(JavaScriptBridge.eval("window.location.search", true)).find("vtf=1") != -1:
		get_tree().change_scene_to_file.call_deferred("res://benchmark/vtf_probe.tscn")  # benchmark/vtf_probe.gd
		return
	if Platform.is_web() and str(JavaScriptBridge.eval("window.location.search", true)).find("replay=1") != -1:
		get_tree().change_scene_to_file.call_deferred("res://benchmark/level_replay.tscn")  # benchmark/level_replay.gd
		return
	if Benchmark.autostart_requested():
		Benchmark.apply_sweep(Benchmark.fetch_sweep_config())
		Benchmark.start()
		return
	if not WorldSession.has_world():
		# A first-time player starts in the cold open (ColdOpen), in its car, with no title menu.
		ColdOpen.new_world(Config.data.free_roam.pick_world_seed(), Config.data.free_roam)
	WorldSession.title_pending = not ColdOpen.due()
	Scenes.change_to.call_deferred(get_tree(), Scenes.FREE_ROAM)
