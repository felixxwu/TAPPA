extends GutTest
# UpgradesGrid — the ONE per-car upgrades view: a 3x3 grid of slot tiles, each opening an
# UpgradeSlotPopup picker. Shared by the HQ lift, the car-park Change-Upgrades popup, the
# start line and the upgrade reveal.
#
# Everything here runs against the SYNTHETIC catalogue (CarFixtures / UpgradeFixtures), so
# no assertion depends on a shipped car, part or price. What is tested is behaviour that
# must hold for ANY reasonable catalogue: the grid shows one tile per slot captioned
# "slot: value", a press opens the right picker, a pick applies through Save and closes,
# a locked option is visible but unreachable by the cursor, and the ceiling gate holds.

const SaveTestHelpers = preload("res://tests/headless/save_test_helpers.gd")
const TEST_PATH := "user://test_upgrades_grid.json"

var _save: Node


func before_each() -> void:
	_save = SaveTestHelpers.redirect(TEST_PATH)
	CarFixtures.install()
	UpgradeFixtures.install()


func after_each() -> void:
	# The picker parents at the scene/window root so it can escape the WorldPanel
	# SubViewport (see UpgradeSlotPopup._spawn), which means it does NOT die with this
	# test's autofreed nodes. A survivor would hold the one-modal-at-a-time slot and make
	# the NEXT test's open() return null.
	for node in get_tree().get_nodes_in_group(ConfirmPopup.MODAL_GROUP):
		if is_instance_valid(node):
			node.free()
	UpgradeFixtures.restore()
	CarFixtures.restore()
	SaveTestHelpers.cleanup(TEST_PATH)


# A real owned car in the throwaway profile, so the apply paths have something to write to.
func _car() -> Dictionary:
	return _save.grant_car("fx_light_rwd")


func _grid(owned: Dictionary, rating_limit := UpgradesGrid.NO_LIMIT,
		on_change := Callable(), on_swap := Callable()) -> UpgradesGrid:
	var g := UpgradesGrid.new()
	add_child_autofree(g)
	g.setup(owned, on_change, on_swap, rating_limit)
	return g


func _tiles(g: UpgradesGrid) -> Array:
	var out: Array = []
	for c in g._grid.get_children():
		if c is Button:
			out.append(c)
	return out


func _tile_for(g: UpgradesGrid, slot: String) -> Button:
	for t in _tiles(g):
		if String((t as Button).get_meta("upgrade_focus_key", "")) == "tile:%s" % slot:
			return t
	return null


func _tile_text(tile: Button) -> String:
	for l in tile.find_children("*", "Label", true, false):
		return String((l as Label).text)
	return ""


# The open picker, if any. Found through the modal GROUP rather than by walking the
# grid's children: the popup deliberately parents at the scene/window root so it escapes
# the WorldPanel SubViewport the page can be hosted in (UpgradeSlotPopup._spawn), so it
# is never a descendant of the grid.
func _popup(_g: UpgradesGrid) -> UpgradeSlotPopup:
	for node in get_tree().get_nodes_in_group(ConfirmPopup.MODAL_GROUP):
		if node is UpgradeSlotPopup and not node.is_queued_for_deletion():
			return node
	return null


# Every focusable row in an open picker, in list order.
func _popup_rows(p: UpgradeSlotPopup) -> Array:
	var out: Array = []
	for node in p.find_children("*", "Button", true, false):
		out.append(node)
	return out


# --- The grid itself ----------------------------------------------------------

func test_the_grid_shows_one_tile_per_slot_captioned_slot_and_value() -> void:
	var g := _grid(_car())
	var tiles := _tiles(g)
	assert_eq(tiles.size(), UpgradeOptions.grid_slots().size(),
		"one tile per grid slot — the whole build is on one screen")
	assert_eq(g._grid.columns, UpgradesGrid.COLUMNS, "laid out in the grid's column count")
	for slot in UpgradeOptions.grid_slots():
		var tile: Button = _tile_for(g, slot)
		assert_not_null(tile, "slot '%s' has a tile" % slot)
		if tile == null:
			continue
		# The tile uses the SHORT slot name (drivetrain -> drive) so the label fits one
		# line without wrapping — see UpgradeOptions.tile_slot_name.
		var text := _tile_text(tile).to_lower()
		var shown := UpgradeOptions.tile_slot_name(slot).to_lower()
		assert_true(text.begins_with(shown + ":"),
			"tile reads '<slot>: <value>' — got '%s' for '%s'" % [text, slot])
		assert_gt(text.length(), shown.length() + 1,
			"the caption names a VALUE after the colon, not just the slot")


func test_every_tile_carries_an_icon_and_is_focusable() -> void:
	var g := _grid(_car())
	for tile in _tiles(g):
		var b := tile as Button
		assert_eq(b.focus_mode, Control.FOCUS_ALL, "tiles take the keyboard/gamepad cursor")
		var icons := b.find_children("*", "TextureRect", true, false)
		assert_eq(icons.size(), 1, "one icon per tile")
		assert_not_null((icons[0] as TextureRect).texture, "the icon has a real texture")


# Both axes, no pointer: the whole point of a grid is that left/right is a different move
# from up/down. A flat list would pass a "down works" test and still be unnavigable.
func test_the_grid_is_navigable_in_both_axes() -> void:
	var frame := Control.new()
	frame.custom_minimum_size = Vector2(400, 320)
	frame.size = Vector2(400, 320)
	add_child_autofree(frame)
	var g := UpgradesGrid.new()
	frame.add_child(g)
	g.setup(_car())
	await get_tree().process_frame
	await get_tree().process_frame
	var tiles := _tiles(g)
	assert_gt(tiles.size(), UpgradesGrid.COLUMNS, "setup: more than one row of tiles")
	var first: Button = tiles[0]
	assert_eq(first.find_valid_focus_neighbor(SIDE_RIGHT), tiles[1],
		"right moves along the row")
	assert_eq(first.find_valid_focus_neighbor(SIDE_BOTTOM), tiles[UpgradesGrid.COLUMNS],
		"down moves to the tile below, not the next one along")
	var second_row: Button = tiles[UpgradesGrid.COLUMNS]
	assert_eq(second_row.find_valid_focus_neighbor(SIDE_TOP), first, "and up comes back")


# --- The picker ---------------------------------------------------------------

func test_pressing_a_tile_opens_the_picker_for_that_slot() -> void:
	var g := _grid(_car())
	assert_null(_popup(g), "no picker before the press")
	_tile_for(g, "turbo").pressed.emit()
	var p := _popup(g)
	assert_not_null(p, "the press opens a picker")
	assert_true(p.is_in_group(ConfirmPopup.MODAL_GROUP),
		"it joins the one-modal-at-a-time group, so the page behind it goes deaf")
	# One row per option the model offers, selectable or not — the slot's whole ladder.
	var labels := 0
	for node in p.find_children("*", "Control", true, false):
		if node is Button or node is Label:
			labels += 1
	assert_gte(labels, UpgradeOptions.options_for(g._owned, "turbo").size(),
		"every option in the slot gets a row")


func test_the_picker_has_no_title_and_no_button_row() -> void:
	# Deliberately bare: the tile the player just pressed already says which slot this is.
	var g := _grid(_car())
	_tile_for(g, "turbo").pressed.emit()
	var p := _popup(g)
	var options := UpgradeOptions.options_for(g._owned, "turbo")
	var known := {}
	for opt in options:
		known[String(opt.get("label", "")).to_upper()] = true
	for b in _popup_rows(p):
		var text := String((b as Button).text).to_upper()
		var matched := false
		for label in known:
			if text.begins_with(String(label)):
				matched = true
		assert_true(matched,
			"every button in the picker is an OPTION row — no Cancel/OK chrome ('%s')" % text)


func test_the_picker_opens_focused_on_the_current_option() -> void:
	var owned := _car()
	var g := _grid(owned)
	_tile_for(g, "turbo").pressed.emit()
	await get_tree().process_frame
	await get_tree().process_frame
	var focused := get_viewport().gui_get_focus_owner()
	assert_not_null(focused, "the picker seats the cursor without a pointer")
	# A fresh car runs nothing in the turbo slot, so the current option is Stock — whatever
	# the catalogue calls it, it is the entry UpgradeOptions marks `current`.
	var want := ""
	for opt in UpgradeOptions.options_for(g._owned, "turbo"):
		if bool(opt.get("current", false)):
			want = String(opt.get("label", "")).to_upper()
	assert_true(focused is Button and String((focused as Button).text).begins_with(want),
		"the cursor opens on what the car is already running")


func test_a_locked_option_is_shown_but_cannot_be_focused() -> void:
	# The supercharger needs the big turbo first, so on a fresh car it is listed with its
	# reason and skipped by the cursor — the ladder is visible without being reachable.
	var owned := _car()
	var g := _grid(owned)
	var locked_labels: Array = []
	for opt in UpgradeOptions.options_for(g._owned, "turbo"):
		if not bool(opt.get("selectable", false)):
			locked_labels.append(String(opt.get("label", "")).to_upper())
	assert_gt(locked_labels.size(), 0, "setup: the fixture turbo slot has a gated option")
	_tile_for(g, "turbo").pressed.emit()
	var p := _popup(g)
	var shown := ""
	for l in p.find_children("*", "Label", true, false):
		shown += String((l as Label).text).to_upper() + "\n"
	for label in locked_labels:
		assert_true(shown.contains(String(label)),
			"the locked option '%s' is still SHOWN" % label)
	for b in _popup_rows(p):
		var text := String((b as Button).text).to_upper()
		for label in locked_labels:
			assert_false(text.begins_with(String(label)),
				"a locked option is never a focusable row ('%s')" % text)


func test_picking_an_option_applies_it_and_closes_the_picker() -> void:
	var owned := _car()
	var id := int(owned["instance_id"])
	# Give the car a part it does not run yet, so picking it is a plain enable (no purchase
	# path involved) — the purchase branch has its own coverage in the save tests.
	_save.install_upgrade(id, "fx_turbo_small", false)
	var changed := [0]
	var g := _grid(_save.get_car(id), UpgradesGrid.NO_LIMIT, func(): changed[0] += 1)
	assert_false(UpgradeLibrary.is_enabled(_save.get_car(id), "fx_turbo_small"),
		"setup: the part is fitted but parked")
	_tile_for(g, "turbo").pressed.emit()
	var p := _popup(g)
	var picked := false
	for b in _popup_rows(p):
		if String((b as Button).text).to_upper().begins_with("SMALL"):
			(b as Button).pressed.emit()
			picked = true
			break
	assert_true(picked, "the fitted part is offered as a pickable row")
	assert_true(UpgradeLibrary.is_enabled(_save.get_car(id), "fx_turbo_small"),
		"picking it writes through to the save")
	assert_true(p.is_queued_for_deletion(), "and the picker closes itself")
	assert_eq(changed[0], 1, "the host is told the build changed, once")
	await get_tree().process_frame
	assert_true(_tile_text(_tile_for(g, "turbo")).to_upper().contains("SMALL"),
		"the tile's caption catches up")


func test_picking_stock_parks_the_slot() -> void:
	var owned := _car()
	var id := int(owned["instance_id"])
	_save.install_upgrade(id, "fx_turbo_small", true)
	var g := _grid(_save.get_car(id))
	_tile_for(g, "turbo").pressed.emit()
	var p := _popup(g)
	for b in _popup_rows(p):
		if String((b as Button).text).to_upper().begins_with("STOCK"):
			(b as Button).pressed.emit()
			break
	assert_false(UpgradeLibrary.is_enabled(_save.get_car(id), "fx_turbo_small"),
		"Stock is the slot's off state and switches the fitted part back off")


func test_the_drivetrain_tile_writes_a_mode_override() -> void:
	var owned := _car()
	var id := int(owned["instance_id"])
	_save.install_upgrade(id, "fx_drivetrain", true)  # own the swap kit so modes unlock
	var g := _grid(_save.get_car(id))
	_tile_for(g, "drivetrain").pressed.emit()
	var p := _popup(g)
	var stock := int(CarLibrary.for_owned(g._owned).get("drive_mode", CarLibrary.RWD))
	var target := -1
	for opt in UpgradeOptions.options_for(g._owned, "drivetrain"):
		if bool(opt.get("selectable", false)) and int(opt["id"]) != stock:
			target = int(opt["id"])
			break
	assert_gte(target, 0, "setup: a non-stock mode is selectable once the kit is owned")
	for b in _popup_rows(p):
		if String((b as Button).text).to_upper().begins_with(
				CarLibrary.drive_text(target).to_upper()):
			(b as Button).pressed.emit()
			break
	assert_eq(int(_save.get_car(id).get("drivetrain_override", -1)), target,
		"the pick lands as a drivetrain override, not as an installed part")


# --- The tune tile: a slider, not a list --------------------------------------

func test_the_tune_tile_opens_a_slider() -> void:
	# Detune is continuous — a list of 21 percentages would be a slider drawn badly.
	var owned := _car()
	var g := _grid(owned)
	_tile_for(g, UpgradeOptions.SLOT_TUNE).pressed.emit()
	var p := _popup(g)
	assert_not_null(p, "the tune tile opens a picker too")
	assert_eq(p.find_children("*", "HSlider", true, false).size(), 1,
		"and that picker is a slider")
	# No OPTION rows — the only button is the Done that lets a slider be left at all
	# (see test_the_tune_popup_can_be_left_with_a_button).
	var option_rows: Array = []
	for b in _popup_rows(p):
		if String((b as Button).text).to_lower() != "done":
			option_rows.append(b)
	assert_eq(option_rows.size(), 0, "with no option rows beside it")


func test_moving_the_tune_slider_writes_the_detune_through() -> void:
	var owned := _car()
	var id := int(owned["instance_id"])
	var g := _grid(_save.get_car(id))
	_tile_for(g, UpgradeOptions.SLOT_TUNE).pressed.emit()
	var slider := _popup(g).find_children("*", "HSlider", true, false)[0] as HSlider
	slider.value = 50.0
	assert_almost_eq(float(_save.get_car(id).get("tuning", {}).get("engine_detune", 1.0)),
		0.5, 0.001, "the slider writes the detune fraction straight to the save")
	assert_true(_tile_text(_tile_for(g, UpgradeOptions.SLOT_TUNE)).contains("50"),
		"and the tile's caption tracks it live, without a rebuild that would drop the drag")


# --- The engine tile ----------------------------------------------------------

func test_the_engine_tile_starts_the_hosts_swap_flow() -> void:
	# A swap TRADES engines with another car the player owns and spends a token, so the
	# choice is "which car" and the HOST owns that screen (hq.gd puts the car park into SWAP
	# mode). The tile starts that flow; it must NOT offer the engine catalogue, which would
	# imply you can simply fit any engine — a thing the game does not let you do.
	# Unlock the capability and bank a token the way the game does: complete the special
	# that gates swapping, and put a token in the shared inventory.
	_save.complete_rally(RallyLibrary.ENGINE_SWAP_UNLOCK_RALLY, 60000, 1)
	_save.profile["inventory"][UpgradeLibrary.ENGINE_SWAP_TOKEN_ID] = 1
	var fired := [0]
	var g := _grid(_car(), UpgradesGrid.NO_LIMIT, Callable(), func(): fired[0] += 1)
	var tile := _tile_for(g, UpgradeOptions.SLOT_ENGINE)
	assert_false(tile.disabled, "with the capability, a token and a host flow, the tile is live")
	tile.pressed.emit()
	assert_eq(fired[0], 1, "pressing it hands off to the host's swap flow")
	assert_null(_popup(g), "and opens no option list of its own")


func test_the_engine_tile_is_dead_without_a_host_swap_flow() -> void:
	# The start line, the upgrade reveal and the car-park popup all host this page but own
	# no car picker. The tile still SHOWS the fitted engine — useful either way — it just
	# cannot be pressed.
	var g := _grid(_car(), UpgradesGrid.NO_LIMIT, Callable(), Callable())
	var tile := _tile_for(g, UpgradeOptions.SLOT_ENGINE)
	assert_true(tile.disabled, "no swap flow, no press")
	assert_true(_tile_text(tile).to_lower().begins_with("engine:"), "but it still names the engine")


func test_the_close_button_gates_on_the_rating_ceiling() -> void:
	var owned := _car()
	var g := _grid(owned, 1.0)  # below any drivable car's rating, so it always reads as over
	var done := Button.new()
	done.text = "Close"
	add_child_autofree(done)
	var closed := [0]
	g.bind_close_button(done, func(): closed[0] += 1)
	assert_true(g.over_rating_limit(), "the build busts the ceiling")
	assert_false(g.can_close(), "so leaving is refused")
	assert_true(String(done.text).begins_with("Over limit"), "and the button says why")
	g.request_close()
	assert_eq(closed[0], 0, "pressing it while over the limit does nothing")


func test_no_ceiling_means_no_gate() -> void:
	var g := _grid(_car())
	var done := Button.new()
	done.text = "Close"
	add_child_autofree(done)
	var closed := [0]
	g.bind_close_button(done, func(): closed[0] += 1)
	assert_false(g.over_rating_limit(), "an uncapped page is never over the limit")
	assert_eq(done.text, "Close", "and the host's own button text is left alone")
	g.request_close()
	assert_eq(closed[0], 1, "closing just works")


func test_the_performance_line_carries_the_ceiling_when_one_is_set() -> void:
	var capped := _grid(_car(), 1.0)
	assert_true(String(capped._rating_label.text).contains("/"),
		"under a ceiling the readout is '<rating> / <limit>'")
	var free := _grid(_car())
	assert_false(String(free._rating_label.text).contains("/"),
		"uncapped it is just the rating")


func test_the_heading_shows_a_live_star_balance() -> void:
	# The picker quotes prices, so the balance has to be on this page — and has to be
	# re-read on every rebuild, since buying a part on this page spends it.
	_save.profile["stars_earned"] = 7
	_save.profile["stars_spent"] = 0
	var g := _grid(_car())
	assert_eq(g.balance_text(), "7", "the heading names the balance")
	_save.profile["stars_spent"] = 5
	g.rebuild()
	assert_eq(g.balance_text(), "2", "and it tracks spending")


func test_the_popup_is_not_parented_inside_the_page() -> void:
	# The bug this guards: the upgrades page can be hosted inside a WorldPanel — a
	# SubViewport drawn onto a 3D quad in the garage. A CanvasLayer parented under the page
	# renders INTO that SubViewport, so the popup's full-rect dim filled the quad with black
	# and its list was scaled down with the viewport until it was unreadable. It has to be a
	# sibling of the scene, not a child of the menu.
	var nested := Control.new()
	add_child_autofree(nested)
	var popup := UpgradeSlotPopup.open(nested, [
		{"id": "", "label": "Stock", "current": true, "selectable": true,
			"price": -1, "locked_reason": ""},
	], func(_id): pass)
	assert_not_null(popup, "the popup opened")
	assert_false(nested.is_ancestor_of(popup),
		"the popup is NOT inside the page that opened it")
	var scene := get_tree().current_scene
	if scene != null:
		assert_eq(popup.get_parent(), scene, "it hangs off the scene root instead")
	popup.free()


# --- Slots with nothing to choose are greyed out ------------------------------

func test_a_tile_is_dead_when_every_option_is_still_locked() -> void:
	# Pressing into a slot whose whole ladder is locked shows "Stock" plus greyed lines the
	# player cannot act on — a press, a read and a back-out that teach nothing. The tile
	# greys instead, so the screen says up front where there is a decision to make.
	var g := _grid(_car())
	for slot in UpgradeOptions.grid_slots():
		var tile: Button = _tile_for(g, slot)
		if tile == null:
			continue
		assert_eq(tile.disabled, not UpgradeOptions.has_choice(g._owned, slot),
			"slot '%s': the tile is live exactly when it offers a choice" % slot)


func test_unlocking_a_part_brings_its_tile_back_to_life() -> void:
	# The other half of the rule: a dead slot must come back the moment the rally gating its
	# part is won, or the grey-out could strand a slot the player has legitimately opened up.
	#
	# A SYNTHETIC one-part catalogue, because the shared fixture roster has free ballast in
	# every slot it gates — this test needs a slot whose ONLY option is locked, and building
	# that condition is the whole setup.
	UpgradeLibrary.override_for_test([{
		"id": "fx_only_turbo", "name": "Gated Turbo", "slot": "turbo",
		"unlocked_by_rally": UpgradeFixtures.FX_GATE_RALLY, "consumable": false,
		"effect": {"peak_torque_mult": 1.2},
	}])
	var g := _grid(_car())
	assert_false(UpgradeOptions.has_choice(g._owned, "turbo"),
		"setup: the slot's only part is still gated")
	assert_true(_tile_for(g, "turbo").disabled, "so its tile starts dead")

	_save.complete_rally(UpgradeFixtures.FX_GATE_RALLY, 60000, 1)
	g.rebuild()

	assert_true(UpgradeOptions.has_choice(g._owned, "turbo"), "the part is now reachable")
	assert_false(_tile_for(g, "turbo").disabled, "and the tile is live again")


func test_the_tune_popup_can_be_left_with_a_button() -> void:
	# The list variant closes itself when an option is picked, but a slider has no such
	# gesture — without a Done button the only way out is Esc / gamepad-B, which a pointer
	# or touchscreen does not have and a player has to guess at.
	var g := _grid(_car())
	_tile_for(g, UpgradeOptions.SLOT_TUNE).pressed.emit()
	var p := _popup(g)
	assert_not_null(p, "the tune tile opens its popup")
	var done: Button = null
	for b in p.find_children("*", "Button", true, false):
		if String((b as Button).text).to_lower() == "done":
			done = b
	assert_not_null(done, "the tune popup carries a Done button")
	if done == null:
		return
	assert_eq(done.focus_mode, Control.FOCUS_ALL, "and it is reachable by keyboard/gamepad")
	done.pressed.emit()
	assert_null(_popup(g), "pressing it closes the popup")
