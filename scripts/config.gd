extends Node
# Docs: features/configuration.md — update in the same change as this file.
# Tests: tests/headless/test_config_applied.gd, tests/headless/test_config_isolation.gd — extend in the same change.
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


# --- Field lookups (the ONE place every call site reads a GameConfig field) -----------------
#
# Semantics: `field in cfg` (an "is this a real declared property" check), NOT
# `cfg.get(field) != null`. The two callers this replaced disagreed on exactly this point, and
# it matters for catching a typo'd field name: every GameConfig field is an `@export var` with
# a non-null default (float/bool/int/Color — see game_config.gd), so a DECLARED field never
# legitimately holds null. That means `in` and `!= null` agree for every real field; the only
# case they could diverge is a field that doesn't exist at all, where both `in` (false) and
# `get()` (null) already resolve to "missing" the same way. `in` is used here because it says
# directly what we mean ("does this property exist"), rather than inferring existence from a
# null check that happens to work only because no field is ever null-valued.
#
# A missing field pushes a warning rather than silently resolving to the fallback — a typo'd
# field name should be loud, not a quiet revert to a default that then looks like a balance
# choice nobody made.
func get_float(field: String, fallback: float) -> float:
	if data == null:
		return fallback
	if not (field in data):
		push_warning("Config.get_float: no such GameConfig field %s (using fallback %s)" % [field, fallback])
		return fallback
	return float(data.get(field))


func get_bool(field: String, fallback: bool) -> bool:
	if data == null:
		return fallback
	if not (field in data):
		push_warning("Config.get_bool: no such GameConfig field %s (using fallback %s)" % [field, fallback])
		return fallback
	return bool(data.get(field))
