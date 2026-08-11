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


# HOT RELOAD: re-read game_config.tres FROM DISK and swap it in, so a value can be retuned in the
# editor's inspector and seen in the running game without restarting.
#
# reset() cannot do this. `load()` returns the CACHED resource — the copy this process read at
# boot — so re-running it re-duplicates the same stale values however many times you call it. Only
# CACHE_MODE_REPLACE actually goes back to the file (and updates the cache, so later load()s agree
# with what is now live rather than silently disagreeing).
#
# A DEBUG AFFORDANCE, not a game feature. It replaces `data` wholesale, which DISCARDS the runtime
# mutations the game makes to the active config (car.gd's apply_car reshapes `data` for the selected
# car), so the car you are looking at may not match its config until it is re-applied. That is
# acceptable while tuning the look of a menu and is why the caller is a debug-build-only key.
#
# Returns true when the file was read and swapped in.
func reload_from_disk() -> bool:
	var fresh := ResourceLoader.load(CONFIG_PATH, "", ResourceLoader.CACHE_MODE_REPLACE) as GameConfig
	if fresh == null:
		push_error("Config.reload_from_disk: failed to re-read %s" % CONFIG_PATH)
		return false
	data = fresh.duplicate(true)
	return true
