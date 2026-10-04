class_name OutlineSetting
extends RefCounted
# Docs: features/settings.md / features/rendering.md — update in the same change.
# Tests: tests/headless/test_settings_menu.gd — extend in the same change.

## The player-facing "Outlines" toggle: whether the object-ID outline pass
## (scripts/spike_id_pass.gd + ps1_post_process.gdshader) runs. Apply-owner in the
## shape of scripts/speed_lines_setting.gd: owns the key, the default, the read-back
## and the re-apply. Off also stops the ID viewport rendering, so it saves the
## extra draw pass, not just the lines.

const SETTING_KEY := "outlines"

# Live outline passes join this group so apply() reaches them without a reference.
const GROUP := &"outline_pass"


## The AUTHORED default (GameConfig.outlines_enabled). Never write the player's
## choice back into it — see speed_lines_setting.gd for why.
static func default_enabled() -> bool:
	return Config.data.outlines_enabled


static func resolve() -> bool:
	return bool(Save.get_setting(SETTING_KEY, default_enabled()))


## Persist the choice and apply it to every live outline pass.
static func apply(tree: SceneTree, on: bool) -> void:
	Save.set_setting(SETTING_KEY, on)
	if tree == null:
		return
	for node in tree.get_nodes_in_group(GROUP):
		node.set_effect_enabled(on)
