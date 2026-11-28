extends Node
# Docs: features/world-session.md — update in the same change as this file.
# The game's main scene: loads straight into the world, giving a first-time player a new world first.


func _ready() -> void:
	if Platform.is_web() and str(JavaScriptBridge.eval("window.location.search", true)).find("vtf=1") != -1:
		get_tree().change_scene_to_file.call_deferred("res://benchmark/vtf_probe.tscn")  # benchmark/vtf_probe.gd
		return
	if Platform.is_web() and str(JavaScriptBridge.eval("window.location.search", true)).find("replay=1") != -1:
		get_tree().change_scene_to_file.call_deferred("res://benchmark/level_replay.tscn")  # benchmark/level_replay.gd
		return
	if not WorldSession.has_world():
		WorldSession.new_world(randi(), Config.authored_value("level_car_id", Config.data.level_car_id))
	Scenes.change_to.call_deferred(get_tree(), Scenes.WORLD)
