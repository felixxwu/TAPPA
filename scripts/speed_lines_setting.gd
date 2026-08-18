class_name SpeedLinesSetting
extends RefCounted
# Docs: features/rendering.md — update in the same change as this file.
# Tests: tests/headless/test_speed_lines.gd — extend in the same change.

## The player-facing "speed blur" toggle: whether the anime edge-speed-lines
## overlay (scripts/speed_lines.gd, shaders/speed_lines.gdshader) draws at all.
## Persisted under SETTING_KEY as a bool; when the player hasn't chosen, it falls
## back to the AUTHORED default in GameConfig.speed_lines_enabled.
##
## This is the apply-owner for the setting, in the shape of scripts/fps_setting.gd
## (the exemplar for the pattern — read that first): the module owns the key, the
## default, the read-back, AND the re-apply, so the settings UI only has to call
## `apply()` and every live overlay updates. speed_lines.gd depends on THIS, never
## on SettingsMenu — a rendering node must not need the settings UI in order to
## know whether to draw.
##
## NOTE: adding the player-facing menu row is deliberately NOT done here; only the
## seam exists so far.

const SETTING_KEY := "speed_lines"

# Live overlays join this group in _ready so apply() can re-apply to all of them
# without the caller holding a reference. speed_lines.gd is the only member.
const GROUP := &"speed_lines_overlay"


## The AUTHORED default, used only when the player has never chosen. This reads
## GameConfig — a designer-authored baseline resource — and nothing here or in the
## settings UI may ever WRITE `Config.data.speed_lines_enabled`. Writing the
## player's runtime choice back into the field that supplies this default would
## make the "authored default" drift with player input (and leak across scenes,
## since Config.data is a shared autoloaded resource). The player's choice belongs
## in the save profile, via apply() below — nowhere else.
static func default_enabled() -> bool:
	return Config.data.speed_lines_enabled


## Whether the effect should be drawn: the player's saved choice, or the authored
## default when unset. speed_lines.gd._ready() and the Settings row both read this.
static func resolve() -> bool:
	return bool(Save.get_setting(SETTING_KEY, default_enabled()))


## Persist the player's choice and apply it to every overlay currently in the tree,
## so the toggle takes effect immediately rather than on the next scene load.
static func apply(tree: SceneTree, on: bool) -> void:
	Save.set_setting(SETTING_KEY, on)
	if tree == null:
		return
	for node in tree.get_nodes_in_group(GROUP):
		if node.has_method("set_effect_enabled"):
			node.set_effect_enabled(on)
