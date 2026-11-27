extends Node
# Docs: features/world-session.md — update in the same change as this file.
# The game's main scene: loads straight into the world, which shows the title menu over itself.
# A first-time player gets a new world first.


func _ready() -> void:
	if Platform.is_web() and str(JavaScriptBridge.eval("window.location.search", true)).find("vtf=1") != -1:
		get_tree().change_scene_to_file.call_deferred("res://benchmark/vtf_probe.tscn")  # benchmark/vtf_probe.gd
		return
	if Platform.is_web() and str(JavaScriptBridge.eval("window.location.search", true)).find("replay=1") != -1:
		get_tree().change_scene_to_file.call_deferred("res://benchmark/level_replay.tscn")  # benchmark/level_replay.gd
		return
	if not WorldSession.has_world():
		TitleScreen.new_world()
	WorldSession.title_pending = true
	Scenes.change_to.call_deferred(get_tree(), Scenes.WORLD)
