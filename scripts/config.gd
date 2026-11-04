extends Node
# Docs: features/configuration.md — update in the same change as this file.
# Tests: tests/headless/test_config_applied.gd, tests/headless/test_config_isolation.gd — extend in the same change.
# Autoload "Config": holds the live GameConfig the whole game reads.

var data: GameConfig

# The PRISTINE authored baseline — the game_config.gd defaults, never mutated by the
# game. `data` is a separate instance precisely so the runtime is free to retune itself
# (car.gd's apply_car reshapes `data` per car), which means a field the runtime multiplies
# has no way back to its authored number without a copy that nobody writes to.
#
# UpgradeLibrary.apply's RESEED pre-pass is that reader: an effect targeting a GLOBAL field
# (a coin radius, a money rate) has no per-car re-seed to reset it the way a car field does,
# so the funnel restores those fields from here before every apply — otherwise the same
# multiplier would stack on itself on every stage boot, and un-equipping the skill would
# never give the number back. See UpgradeLibrary.EFFECTS' `reseed` flag.
var _authored: GameConfig


func _init() -> void:
	reset()


# A fresh copy of the authored baseline. The game retunes `data` at runtime (car.gd's
# apply_car reshapes it per car); gameplay tests call reset() so one scene's car can't
# leak into the next.
func reset() -> void:
	data = GameConfig.new()
	_authored = GameConfig.new()


# The authored value of `field`, straight off the pristine baseline (see `_authored`).
# Falls back to the live config's own value when the field is unknown, so a caller can
# never be handed null — a typo'd name degrades to "leave it alone" rather than nulling a
# live tunable mid-drive.
func authored_value(field: String, fallback: Variant) -> Variant:
	if _authored == null or not (field in _authored):
		return fallback
	return _authored.get(field)


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
