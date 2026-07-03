extends Node
# Autoload "Config": loads the central GameConfig once at startup.

const CONFIG_PATH := "res://config/game_config.tres"

var data: GameConfig


func _init() -> void:
	reset()


# (Re)load a fresh working copy of the authored baseline. The game retunes the
# active config at runtime (car.gd's apply_car mutates `data` to reshape the car
# for the selected CarLibrary entry), so we hold a private DUPLICATE and leave
# the cached .tres pristine. reset() restores the authored baseline — gameplay
# tests call it so a car selection in one scene can't leak into the next.
func reset() -> void:
	var base := load(CONFIG_PATH) as GameConfig
	if base == null:
		push_error("Failed to load %s — using code defaults" % CONFIG_PATH)
		data = GameConfig.new()
	else:
		data = base.duplicate(true)
