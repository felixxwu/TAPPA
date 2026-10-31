extends Node
# Docs: features/world-session.md — update in the same change as this file.
# The game's main scene: loads straight into the world, which shows the title menu over itself.
# A first-time player gets a world built with the cold-open car and drives the cold open instead.


func _ready() -> void:
	if Benchmark.autostart_requested():
		Benchmark.apply_sweep(Benchmark.fetch_sweep_config())
		Benchmark.start()
		return
	if not WorldSession.has_world():
		# A first-time player starts in the cold open (ColdOpen), in its car, with no title menu.
		WorldSession.new_world(Config.data.free_roam.pick_world_seed(), ColdOpen.car_id(Config.data.free_roam))
		WorldSession.fresh = true
		WorldSession.set_cold_open_pending(true)
	WorldSession.title_pending = not ColdOpen.due()
	Scenes.change_to.call_deferred(get_tree(), Scenes.FREE_ROAM)
