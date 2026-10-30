extends Node
# Docs: features/world-session.md — update in the same change as this file.
# The game's main scene: loads straight into the world, which shows the title menu over itself.
# A first-time player gets a world built with the first starter car, so it is ready behind the menu.


func _ready() -> void:
	if Benchmark.autostart_requested():
		Benchmark.apply_sweep(Benchmark.fetch_sweep_config())
		Benchmark.start()
		return
	if not WorldSession.has_world():
		WorldSession.new_world(Config.data.free_roam.pick_world_seed(), TitleScreen.starter_choices()[0])
		WorldSession.fresh = true
	WorldSession.title_pending = true
	Scenes.change_to.call_deferred(get_tree(), Scenes.FREE_ROAM)
