extends Node
# Docs: features/world-session.md — update in the same change as this file.
# Tests: tests/headless/test_world_session.gd — extend in the same change.
# The save's world: whether the player has started one (title_boot.gd makes one on first boot) and
# which owned car it began with. Kept in the profile under Save.KEY_WORLD as {seed, car}; keys left
# by older saves are ignored. The level keeps its own progress (LevelView's saved settings).

signal world_changed()

# Bumped whenever the world in the profile is replaced (a new world, a cloud download, a wipe).
# A scene that captured it can tell its world is gone.
var generation := 0


func _ready() -> void:
	Save.replaced.connect(invalidate)


func invalidate() -> void:
	generation += 1
	world_changed.emit()


func has_world() -> bool:
	return not _world().is_empty() and _world().has("seed")


func _world() -> Dictionary:
	return Save.profile.get(Save.KEY_WORLD, {})


func _touch() -> void:
	Save.save()


# Start a new world with a starter car, replacing any world in this profile. Owned cars from an old
# world go with it: a world is the whole save.
func new_world(world_seed: int, starter_model_id: String) -> void:
	Save.profile[Save.KEY_CARS] = []
	var car := Save.grant_car(starter_model_id)
	Save.profile[Save.KEY_WORLD] = {"seed": world_seed, "car": int(car["instance_id"])}
	_touch()
	invalidate()


func world_seed() -> int:
	return int(_world().get("seed", 1))


func active_car() -> Dictionary:
	return Save.get_car(int(_world().get("car", -1)))
