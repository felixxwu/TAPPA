extends GutTest
# Docs: features/hq.md, features/map-exploration.md
# Tests: (this file)
# The map table's PIN LAYER (scripts/hq_map_table.gd, class_name HqMapTable) — the seam
# tests for the cut that moved it out of hq.gd. Two things are pinned here:
#
#   1. hq.gd CONSTRUCTS and WIRES the module (it is not an optional collaborator: the
#      table cannot draw without it, and _build_hq's own pin build runs through it).
#   2. The behaviour still reachable through the controller's two forwarders —
#      `_refresh_map_pins` (which hq_table.gd and test_menu_flow.gd both call by that
#      name) and `_paint_pin_readout` (hq_table.gd's focus repaint) — still works, so the
#      move cannot have broken a call site.
#
# Nothing here asserts an authored value: no pin position, no star count, no rally id, no
# fog radius, no link width. It iterates the roster as opaque input and checks structure —
# a designer retuning the map or re-authoring the roster must not break this file.

const SceneHelpers = preload("res://tests/headless/scene_helpers.gd")
const CarFixtures = preload("res://tests/headless/car_fixtures.gd")
const TEST_PATH := "user://test_hq_map_table_profile.json"

var _save: Node


func before_each() -> void:
	get_viewport().gui_release_focus()
	Config.reset()
	Config.data.world_space_menus = false
	# The framing scatter is never asserted on here, so trim it to keep each hq.tscn
	# build cheap (the same trim test_menu_flow.gd makes).
	Config.data.hq_tree_count = 8
	Config.data.hq_bush_count = 8
	# Light the whole map, so the pin set under test is the WHOLE roster rather than
	# whatever happens to sit near HQ_MAP_POS. Reveal is a separate feature with its own
	# tests (features/map-exploration.md); smuggling it in here would make these
	# structural assertions depend on it.
	Config.data.map_hq_reveal_radius = 10.0
	CarFixtures.install()
	UpgradeFixtures.install()
	RallyFixtures.install()
	_save = get_node("/root/Save")
	_clean()
	_save.profile_path = TEST_PATH
	_save.save_disabled = false
	_save.load_or_new()
	_save.profile["starter_picked"] = true
	_save.grant_car("fx_light_rwd")


func after_each() -> void:
	_clean()
	_save.profile_path = _save.DEFAULT_PROFILE_PATH
	Config.reset()
	CarFixtures.restore()
	UpgradeFixtures.restore()
	RallyFixtures.restore()
	RallyLibrary.reset()
	RegionLibrary.reset()


func _clean() -> void:
	for suffix in ["", ".bak", ".tmp"]:
		if FileAccess.file_exists(TEST_PATH + suffix):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_PATH + suffix))


func _hq() -> Node3D:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	return hq


# --- The wiring ---------------------------------------------------------------

func test_hq_constructs_the_map_table_module_wired_back_to_itself() -> void:
	var hq: Node3D = await _hq()
	assert_not_null(hq._map_table_ui, "_build_hq constructs the pin layer")
	assert_true(hq._map_table_ui is HqMapTable, "and it is an HqMapTable")
	assert_eq(hq._map_table_ui._hq, hq,
		"the module holds a back-reference to the controller, like every other hq_*.gd cut")


# The controller keeps the two names the pin layer is reached BY, because hq_table.gd and the
# menu tests call them off the controller. A cut is not allowed to move a call site, so if
# these ever stop existing on HqController the refactor has changed behaviour.
func test_the_controller_still_exposes_the_two_pin_layer_entry_points() -> void:
	var hq: Node3D = await _hq()
	assert_true(hq.has_method("_refresh_map_pins"),
		"hq_table.gd calls _hq._refresh_map_pins — the forwarder must stay")
	assert_true(hq.has_method("_paint_pin_readout"),
		"hq_table.gd calls _hq._paint_pin_readout — the forwarder must stay")


# --- The behaviour reachable through it ---------------------------------------

# A pin per rally, parented under the pins root, each tagged with the rally it stands for.
# Counted against the roster rather than a number, and the ids are only checked for
# MEMBERSHIP of the roster — the fixture roster's contents are free to change.
func test_refresh_map_pins_builds_one_tagged_pin_per_rally() -> void:
	var hq: Node3D = await _hq()
	hq._pins_stamp = null  # force a real rebuild rather than the no-change fast path
	hq._refresh_map_pins()
	assert_eq(hq._pins.size(), RallyLibrary.all().size(),
		"every rally on the roster gets a pin, reached or not")
	var ids := {}
	for rally in RallyLibrary.all():
		ids[String(rally["id"])] = true
	for pin in hq._pins:
		assert_true(is_instance_valid(pin), "the pin is a live node")
		assert_eq(pin.get_parent(), hq._pins_root, "and it hangs under the pins root")
		assert_true(pin.has_meta("rally_id"), "a pin names the rally it stands for")
		assert_true(ids.has(String(pin.get_meta("rally_id"))),
			"and that rally is a real roster entry")


# The rebuild-skip stamp survived the move: a second refresh with nothing changed keeps the
# SAME pin nodes (this is what makes tapping the table cheap — see HqMapTable's note), while
# clearing the stamp forces fresh ones.
func test_refresh_map_pins_keeps_its_rebuild_skip() -> void:
	var hq: Node3D = await _hq()
	hq._pins_stamp = null
	hq._refresh_map_pins()
	var first: Array = hq._pins.duplicate()
	assert_false(first.is_empty(), "setup: the map has pins")

	hq._refresh_map_pins()
	assert_eq(hq._pins, first, "nothing changed, so the pins we already have are kept")

	hq._pins_stamp = null
	hq._refresh_map_pins()
	assert_ne(hq._pins, first, "a cleared stamp rebuilds them")


# The hover-only readout: hidden until the cursor is on the pin, and its off-screen viewport
# is armed in lockstep so a hidden box never composites (the whole point of routing every
# visibility change through this one function).
func test_paint_pin_readout_toggles_the_box_and_its_viewport_together() -> void:
	var hq: Node3D = await _hq()
	hq._pins_stamp = null
	hq._refresh_map_pins()
	var pin: Node3D = null
	for candidate in hq._pins:
		if candidate.has_meta("label_sprite"):
			pin = candidate
			break
	assert_not_null(pin, "setup: at least one pin carries a readout box")

	var sprite: Node3D = pin.get_meta("label_sprite")
	var vp: SubViewport = sprite.get_meta("viewport")
	assert_false(sprite.visible, "a readout starts hidden — the table is a map, not a noticeboard")
	assert_eq(vp.render_target_update_mode, SubViewport.UPDATE_DISABLED,
		"and a hidden box composites nothing")

	hq._paint_pin_readout(pin, true)
	assert_true(sprite.visible, "the hovered pin shows its box")
	assert_eq(vp.render_target_update_mode, SubViewport.UPDATE_ALWAYS,
		"and arms its render target while it is up")

	hq._paint_pin_readout(pin, false)
	assert_false(sprite.visible, "leaving the pin hides it again")
	assert_eq(vp.render_target_update_mode, SubViewport.UPDATE_DISABLED,
		"and disarms the target — a readout must never be left compositing unwatched")


# The exploration fog is shaded onto the map plane by the module, but the mask itself is a
# STATIC re-export on HqController (features/hq.md / features/overworld.md both document
# `HqController.build_fog_mask(profile)`, and the overworld's terrain shader is its second
# consumer). The cut had to leave that public name where it was.
func test_the_fog_mask_re_export_stays_on_the_controller() -> void:
	var mask: Variant = HqController.build_fog_mask(Save.profile)
	assert_true(mask is ImageTexture, "build_fog_mask still hands back a mask texture")


# The map plane is shaded, not left with its raw material, after a pin refresh — the fog pass
# runs as part of the rebuild rather than having been orphaned by the move.
func test_refreshing_the_pins_shades_the_map_plane_with_the_fog() -> void:
	var hq: Node3D = await _hq()
	hq._pins_stamp = null
	hq._refresh_map_pins()
	assert_true(hq._map_plane.material_override is ShaderMaterial,
		"the map plane carries the fog shader after a rebuild")
