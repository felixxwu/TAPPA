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


# --- Slot descriptions --------------------------------------------------------
#
# Each picker opens with one line saying what the slot DOES, for a player who knows nothing
# about cars. Nothing here pins the WORDING — that is authored copy a designer rewrites —
# only that every slot has some, that it reaches the popup, and that it stays out of the
# keyboard path.


# The contract that matters: no slot ships without an explainer. A slot added later with no
# entry would otherwise open a bare list silently, which is exactly the state this feature
# exists to remove.
func test_every_openable_slot_has_a_description() -> void:
	for slot in UpgradeOptions.grid_slots():
		if slot == UpgradeOptions.SLOT_ENGINE:
			continue  # not a picker: the engine tile hands off to the host's car park
		assert_false(UpgradeOptions.slot_description(slot).strip_edges().is_empty(),
			"slot '%s' opens a picker, so it needs a line saying what it does" % slot)


func test_an_unknown_slot_has_no_description_rather_than_a_placeholder() -> void:
	assert_eq(UpgradeOptions.slot_description("not_a_slot"), "",
		"an unlisted slot should degrade to no description row, not to filler text")


func test_the_picker_shows_the_slots_description() -> void:
	var g := _grid(_car())
	_tile_for(g, "turbo").pressed.emit()
	var p := _popup(g)
	assert_not_null(p, "precondition: the picker opened")
	# UITheme.enforce uppercases every label, so compare on the same footing.
	var want := UpgradeOptions.slot_description("turbo").to_upper()
	var found := false
	for node in p.find_children("*", "Label", true, false):
		if (node as Label).text.to_upper() == want:
			found = true
	assert_true(found, "the slot's explainer should be drawn in its picker")


func test_the_detune_slider_also_gets_a_description() -> void:
	var g := _grid(_car())
	_tile_for(g, UpgradeOptions.SLOT_TUNE).pressed.emit()
	var p := _popup(g)
	assert_not_null(p, "precondition: the slider opened")
	var want := UpgradeOptions.slot_description(UpgradeOptions.SLOT_TUNE).to_upper()
	var found := false
	for node in p.find_children("*", "Label", true, false):
		if (node as Label).text.to_upper() == want:
			found = true
	assert_true(found, "the continuous slot needs explaining just as much as the lists")


# A description is reference text, not a control. If it could take focus the gamepad would
# land on an inert row every time a picker opened.
func test_the_description_does_not_steal_focus_from_the_options() -> void:
	var g := _grid(_car())
	_tile_for(g, "turbo").pressed.emit()
	var p := _popup(g)
	var rows := _popup_rows(p)
	assert_gt(rows.size(), 0, "precondition: the picker has options")
	var focused := p.get_viewport().gui_get_focus_owner() if p.get_viewport() != null else null
	if focused != null:
		assert_true(focused is Button,
			"focus must land on something pressable, never on the explainer line")


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


func test_buying_a_part_from_the_picker_also_fits_it() -> void:
	# Save.buy_part fits a part PARKED, which is right for the paths that hand the player
	# something they did not ask for (a reward draw, a mystery box). Picking it here is the
	# opposite: the player opened the slot, chose the option and paid for it, so the menu
	# closing on an unchanged car reads as taking the stars and doing nothing. The price is
	# whatever Save.part_price says, so the balance is set from that rather than pinned.
	var owned := _car()
	var id := int(owned["instance_id"])
	_save.profile["stars_earned"] = _save.part_price("fx_turbo_small")
	_save.profile["stars_spent"] = 0
	assert_false((_save.get_car(id).get("installed_upgrades", []) as Array).has("fx_turbo_small"),
		"setup: the car does not own the part yet")
	var g := _grid(_save.get_car(id))
	_tile_for(g, "turbo").pressed.emit()
	var p := _popup(g)
	for b in _popup_rows(p):
		if String((b as Button).text).to_upper().begins_with("SMALL"):
			(b as Button).pressed.emit()
			break
	var car: Dictionary = _save.get_car(id)
	assert_true((car.get("installed_upgrades", []) as Array).has("fx_turbo_small"),
		"the part is bought onto the car")
	assert_true(UpgradeLibrary.is_enabled(car, "fx_turbo_small"),
		"and is RUNNING — a part the player paid for is not left parked")


func test_a_bought_part_parks_the_one_it_replaces() -> void:
	# The enable is exclusive, so the buy path gets the one-part-per-slot rule for free
	# rather than leaving two parts in the same slot switched on.
	var owned := _car()
	var id := int(owned["instance_id"])
	_save.install_upgrade(id, "fx_turbo_small", true)
	_save.profile["stars_earned"] = _save.part_price("fx_turbo_big")
	_save.profile["stars_spent"] = 0
	var g := _grid(_save.get_car(id))
	_tile_for(g, "turbo").pressed.emit()
	var p := _popup(g)
	for b in _popup_rows(p):
		if String((b as Button).text).to_upper().begins_with("BIG"):
			(b as Button).pressed.emit()
			break
	var car: Dictionary = _save.get_car(id)
	assert_true(UpgradeLibrary.is_enabled(car, "fx_turbo_big"), "the bought part runs")
	assert_false(UpgradeLibrary.is_enabled(car, "fx_turbo_small"),
		"and the slot's outgoing part is parked")


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


# The conversion CAPABILITY is garage-wide (the fixture part is authored ungated), but each
# non-stock layout is BOUGHT per car. These pin the economics, never the price — the balance
# is set from Save.drive_mode_price() so retuning it cannot break them.


# The first non-stock mode this car has not bought, or -1.
func _unbought_mode(owned: Dictionary) -> int:
	var stock := int(CarLibrary.for_owned(owned).get("drive_mode", CarLibrary.RWD))
	for mode in [CarLibrary.RWD, CarLibrary.AWD, CarLibrary.FWD]:
		if mode != stock and not _save.drive_mode_available(owned, mode):
			return mode
	return -1


func _press_mode_row(p: UpgradeSlotPopup, mode: int) -> void:
	for b in _popup_rows(p):
		if String((b as Button).text).to_upper().begins_with(
				CarLibrary.drive_text(mode).to_upper()):
			(b as Button).pressed.emit()
			return


func test_the_drivetrain_tile_writes_a_mode_override() -> void:
	var owned := _car()
	var id := int(owned["instance_id"])
	var target := _unbought_mode(_save.get_car(id))
	assert_gte(target, 0, "setup: the car has a non-stock layout to convert to")
	_save.profile["stars_earned"] = _save.drive_mode_price()  # afford exactly one conversion
	var g := _grid(_save.get_car(id))
	_tile_for(g, "drivetrain").pressed.emit()
	_press_mode_row(_popup(g), target)
	assert_eq(int(_save.get_car(id).get("drivetrain_override", -1)), target,
		"the pick lands as a drivetrain override, not as an installed part")


func test_converting_spends_stars_and_records_the_mode() -> void:
	var owned := _car()
	var id := int(owned["instance_id"])
	var target := _unbought_mode(_save.get_car(id))
	_save.profile["stars_earned"] = _save.drive_mode_price()
	var before: int = _save.stars_available()
	var g := _grid(_save.get_car(id))
	_tile_for(g, "drivetrain").pressed.emit()
	_press_mode_row(_popup(g), target)
	assert_eq(_save.stars_available(), before - _save.drive_mode_price(),
		"a conversion is paid for")
	assert_true((_save.get_car(id).get("drivetrain_modes_bought", []) as Array).has(target),
		"and the car records the layout it bought")


# Buy ONCE, switch freely thereafter — the same deal a bought part gets (fit it, then toggle
# between Stock and fitted for nothing). Going back to the car's own layout is always free.
func test_a_bought_mode_is_free_to_return_to() -> void:
	var owned := _car()
	var id := int(owned["instance_id"])
	var target := _unbought_mode(_save.get_car(id))
	var stock := int(CarLibrary.for_owned(_save.get_car(id)).get("drive_mode", CarLibrary.RWD))
	_save.profile["stars_earned"] = _save.drive_mode_price()
	var g := _grid(_save.get_car(id))
	_tile_for(g, "drivetrain").pressed.emit()
	_press_mode_row(_popup(g), target)
	assert_eq(_save.stars_available(), 0, "precondition: the conversion consumed the balance")
	# Back to stock, then out to the bought layout again — neither may charge.
	g = _grid(_save.get_car(id))
	_tile_for(g, "drivetrain").pressed.emit()
	_press_mode_row(_popup(g), stock)
	assert_eq(int(_save.get_car(id).get("drivetrain_override", -1)), stock, "reverted to stock")
	g = _grid(_save.get_car(id))
	_tile_for(g, "drivetrain").pressed.emit()
	_press_mode_row(_popup(g), target)
	assert_eq(int(_save.get_car(id).get("drivetrain_override", -1)), target,
		"and back out again, with no stars to pay it")


# Without the stars the row is not pressable at all, so the player can never half-apply a
# conversion they cannot afford.
func test_an_unaffordable_conversion_is_not_selectable() -> void:
	var owned := _car()
	var id := int(owned["instance_id"])
	var target := _unbought_mode(_save.get_car(id))
	_save.profile["stars_earned"] = 0
	for opt in UpgradeOptions.options_for(_save.get_car(id), "drivetrain"):
		if int(opt["id"]) == target:
			assert_false(bool(opt.get("selectable", false)), "no stars, no conversion")
			assert_ne(String(opt.get("locked_reason", "")), "", "and it says what it needs")


# The car's OWN layout is never gated and never charged — otherwise a player with no stars
# could be stranded in a layout they cannot leave.
func test_the_stock_layout_is_always_free() -> void:
	var owned := _car()
	_save.profile["stars_earned"] = 0
	var stock := int(CarLibrary.for_owned(owned).get("drive_mode", CarLibrary.RWD))
	for opt in UpgradeOptions.options_for(owned, "drivetrain"):
		if int(opt["id"]) == stock:
			assert_true(bool(opt.get("selectable", false)), "stock is always reachable")
			assert_lt(int(opt.get("price", -1)), 0, "and never costs anything")


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
	# Unlock the capability the way the game does: complete the special that gates
	# swapping. That is the WHOLE gate now — swaps are free and unlimited afterwards.
	_save.record_podium_rally(RallyLibrary.ENGINE_SWAP_UNLOCK_RALLY, 60000, 1)
	var fired := [0]
	var g := _grid(_car(), UpgradesGrid.NO_LIMIT, Callable(), func(): fired[0] += 1)
	var tile := _tile_for(g, UpgradeOptions.SLOT_ENGINE)
	assert_false(tile.disabled, "with the capability unlocked and a host flow, the tile is live")
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

	_save.record_podium_rally(UpgradeFixtures.FX_GATE_RALLY, 60000, 1)
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


# --- The rating each option would give the car --------------------------------

func test_every_picker_row_quotes_the_rating_that_option_would_give() -> void:
	# The point of the figure is that a slot's ladder can be read as numbers instead of
	# part names the player has to already know. Asserted as "the row carries the same
	# number rating_with reports", not as a specific rating — the benchmark is tuning.
	var owned := _car()
	var id := int(owned["instance_id"])
	_save.install_upgrade(id, "fx_turbo_small", false)
	var g := _grid(_save.get_car(id))
	_tile_for(g, "turbo").pressed.emit()
	var p := _popup(g)
	var seen := 0
	for opt in UpgradeOptions.options_for(g._owned, "turbo"):
		var want := UpgradeOptions.rating_with(g._owned, "turbo", String(opt.get("id", "")))
		var needle := "(%d)" % want
		var found := false
		for node in p.find_children("*", "Control", true, false):
			var text := ""
			if node is Button:
				text = String((node as Button).text)
			elif node is Label:
				text = String((node as Label).text)
			# .to_upper() both sides: UITheme.enforce uppercases row text, so a
			# case-sensitive match here would never fire.
			if text.to_upper().begins_with(String(opt.get("label", "")).to_upper()) \
					and text.contains(needle):
				found = true
				break
		assert_true(found, "the '%s' row quotes its rating %s" % [opt.get("label", ""), needle])
		seen += 1
	assert_gt(seen, 1, "setup: the slot offered more than just Stock")


func test_the_stock_row_rates_the_car_as_it_stands() -> void:
	# No per-row "before -> after" is drawn, so Stock being first and rating the CURRENT
	# build is what supplies the baseline the other rows are read against.
	var owned := _car()
	var id := int(owned["instance_id"])
	_save.install_upgrade(id, "fx_turbo_small", true)
	var g := _grid(_save.get_car(id))
	assert_eq(UpgradeOptions.rating_with(g._owned, "turbo", ""), _grid(
		UpgradeOptions.build_with(g._owned, "turbo", "")).current_rating(),
		"the Stock row's figure is the grid's own rating of that same build")


func test_a_hypothetical_build_is_never_written_to_the_save() -> void:
	# rating_with has to APPLY the option to work out what it is worth. Doing that on the
	# real car would fit parts the player never bought by merely opening a picker.
	var owned := _car()
	var id := int(owned["instance_id"])
	var before: Dictionary = _save.get_car(id).duplicate(true)
	UpgradeOptions.rating_with(_save.get_car(id), "turbo", "fx_turbo_small")
	var after: Dictionary = _save.get_car(id)
	assert_eq(after.get("installed_upgrades", []), before.get("installed_upgrades", []),
		"rating an option installs nothing")
	assert_eq(after.get("disabled_upgrades", []), before.get("disabled_upgrades", []),
		"and parks nothing")


func test_a_hypothetical_build_parks_the_slots_other_parts() -> void:
	# One part per slot: the figure quoted for the Big turbo must be the car running BIG,
	# not the car running both turbos at once.
	var owned := _car()
	var id := int(owned["instance_id"])
	_save.install_upgrade(id, "fx_turbo_small", true)
	var hypo := UpgradeOptions.build_with(_save.get_car(id), "turbo", "fx_turbo_big")
	assert_true(UpgradeLibrary.is_enabled(hypo, "fx_turbo_big"), "the picked part runs")
	assert_false(UpgradeLibrary.is_enabled(hypo, "fx_turbo_small"),
		"and the slot's other part is parked")
	var stock := UpgradeOptions.build_with(_save.get_car(id), "turbo", "")
	assert_false(UpgradeLibrary.is_enabled(stock, "fx_turbo_small"),
		"Stock parks the whole slot")


# --- The weight slot reads as a number, not a name ----------------------------

func test_weight_options_read_as_a_signed_mass_delta() -> void:
	# The weight slot is really one number, so its rows state the kilos rather than the
	# part's authored name. The POPUP row carries the unit ("-200 kg" — a bare number means
	# nothing to a player who does not already know this slot deals in mass); the TILE drops
	# it, because a tile has to fit three across a phone on one line.
	#
	# The figures are DERIVED from each part's mass multiplier against this car, so nothing
	# here pins an authored value — only the sign, the format and the unit.
	var owned := _car()
	var g := _grid(owned)
	var seen := 0
	for opt in UpgradeOptions.options_for(g._owned, "weight"):
		var id := String(opt.get("id", ""))
		if id == "":
			assert_eq(String(opt.get("label", "")), "Stock", "Stock keeps its name")
			continue
		var label := String(opt.get("label", ""))
		assert_true(label.begins_with("+") or label.begins_with("-"),
			"a weight row is a signed number, got '%s'" % label)
		assert_true(label.ends_with(" kg"), "...with its unit, got '%s'" % label)
		var tile := String(opt.get("tile_label", ""))
		assert_eq(tile + " kg", label,
			"the tile shows the same number WITHOUT the unit, got tile '%s' vs row '%s'"
				% [tile, label])
		assert_true(tile.substr(1).is_valid_int(),
			"...and the tile is nothing but the number, got '%s'" % tile)
		# Sign follows the part: a multiplier above 1 adds mass, below 1 sheds it.
		var mult := float((UpgradeLibrary.by_id(id).get("effect", {}) as Dictionary)
			.get("mass_mult", 1.0))
		assert_eq(label.begins_with("+"), mult > 1.0,
			"'%s' has the sign its multiplier implies" % label)
		seen += 1
	assert_gt(seen, 0, "setup: the weight slot offered at least one part")


func test_a_weight_delta_is_measured_against_the_empty_slot() -> void:
	# Not against the car's CURRENT mass: swapping one ballast for another must report
	# what the new part weighs, not the difference between the two, or the same part
	# would quote a different number depending on what it is replacing.
	var owned := _car()
	var id := int(owned["instance_id"])
	var bare := _label_for_weight_part(_save.get_car(id), "fx_lightweight")
	_save.install_upgrade(id, "fx_ballast", true)
	var shod := _label_for_weight_part(_save.get_car(id), "fx_lightweight")
	assert_eq(shod, bare,
		"the same part quotes the same kilos whatever is currently fitted")


func test_other_slots_keep_their_part_names() -> void:
	# The number-only treatment is the weight slot's alone — every other slot names parts
	# that are not interchangeable quantities.
	var g := _grid(_car())
	for opt in UpgradeOptions.options_for(g._owned, "turbo"):
		var label := String(opt.get("label", ""))
		assert_false(label.begins_with("+") or label.begins_with("-"),
			"turbo rows are named, not numbered — got '%s'" % label)


func _label_for_weight_part(owned: Dictionary, pid: String) -> String:
	for opt in UpgradeOptions.options_for(owned, "weight"):
		if String(opt.get("id", "")) == pid:
			return String(opt.get("label", ""))
	return ""


func test_a_weight_delta_is_rounded_to_the_nearest_hundred() -> void:
	# The exact kilos come from a multiplier against this car, so they land on figures like
	# 243 — precision the player cannot act on. Asserted as "a round hundred, and never
	# zero for a real part", which holds for any car mass and any authored multiplier.
	var g := _grid(_car())
	var seen := 0
	for opt in UpgradeOptions.options_for(g._owned, "weight"):
		if String(opt.get("id", "")) == "":
			continue
		var kilos := int(String(opt.get("label", "")))
		assert_eq(kilos % 100, 0, "'%s' is a round hundred" % opt.get("label", ""))
		assert_ne(kilos, 0, "a real part never reads as no change at all")
		seen += 1
	assert_gt(seen, 0, "setup: the weight slot offered a part")


# --- Contract tests: the whole class of bug this file exists to catch ----------------
#
# Three invariants, all equality-between-two-code-paths or rule-derived. None names a
# catalogue id, a star price or a stat, so retuning any of them cannot break these.


# THE DIFFERENTIAL TEST. `build_with` (the hypothetical the picker rates) and
# `_apply_option` (the real edit) must produce the SAME CAR for every slot and every
# option. They used to be two independent `match slot` ladders held together by a comment
# claiming they agreed — and they did not: the drivetrain arm of one marked the layout paid
# for while the other did not, so every drive-mode row quoted the unconverted car's rating.
#
# Compared as MERGED METAS rather than raw dicts: that is what makes it value-agnostic and
# meaningful at once — it asserts the two paths describe the same car, whatever the numbers.
func test_build_with_agrees_with_a_real_apply_for_every_slot_and_option() -> void:
	for slot in UpgradeOptions.grid_slots():
		# The two pseudo-slots are not slot edits at all (the engine tile hands off to a
		# host flow, tune is a live slider), and option_edit reports them as such.
		if slot == UpgradeOptions.SLOT_ENGINE or slot == UpgradeOptions.SLOT_TUNE:
			continue
		for opt in UpgradeOptions.options_for(_car(), slot):
			if not bool(opt.get("selectable", false)):
				continue
			var option_id := String(opt.get("id", ""))
			# A fresh car per option, with stars for anything the row might cost, so each
			# pair is compared from the same starting point.
			var owned := _car()
			var id := int(owned["instance_id"])
			_save.profile["stars_earned"] = 9999
			var entry: Dictionary = CarLibrary.for_owned(_save.get_car(id))
			var hypo: Dictionary = UpgradeOptions.build_with(_save.get_car(id), slot, option_id)
			var g := _grid(_save.get_car(id))
			g._apply_option(option_id, slot)
			var real: Dictionary = _save.get_car(id)
			assert_eq(CarPerformance.merged_meta(hypo, entry),
				CarPerformance.merged_meta(real, entry),
				"slot '%s' option '%s': the rated hypothetical and the real edit must agree"
					% [slot, option_id])


# `""` is the universal Stock sentinel. For a LAYOUT that has to mean the car's authored
# mode — int("") is 0, which is a real drive mode — so this pins that the sentinel never
# silently converts a car.
func test_the_stock_sentinel_is_the_off_state_in_every_slot() -> void:
	var owned := _car()
	var entry: Dictionary = CarLibrary.for_owned(owned)
	for slot in UpgradeOptions.grid_slots():
		if slot == UpgradeOptions.SLOT_ENGINE or slot == UpgradeOptions.SLOT_TUNE:
			continue
		var bare: Dictionary = UpgradeOptions.build_with(owned, slot, "")
		assert_eq(CarPerformance.merged_meta(bare, entry),
			CarPerformance.merged_meta(owned, entry),
			"slot '%s': the Stock sentinel on an unmodified car must change nothing" % slot)


# Every non-consumable part in the catalogue must be REACHABLE from its own slot's picker.
# This is the assertion the original drivetrain bug would have failed: the conversion kit
# sat in the table with slot "drivetrain", and that slot's picker listed drive modes, so no
# row for the kit existed on any screen and no second car could ever acquire it.
#
# Iterates the catalogue as opaque input (explicitly allowed) — it names no id and asserts
# no value, only that the catalogue and the pickers enumerate the same set.
func test_every_catalogue_part_is_reachable_from_its_slots_picker() -> void:
	var owned := _car()
	var slots := UpgradeOptions.grid_slots()
	for def in UpgradeLibrary.all():
		if bool(def.get("consumable", false)):
			continue
		var slot := String(def.get("slot", ""))
		if slot == "" or not slots.has(slot):
			continue  # hidden slots have no garage row by design (UpgradeLibrary.HIDDEN_SLOTS)
		var found := false
		for opt in UpgradeOptions.options_for(owned, slot):
			if String(opt.get("id", "")) == String(def.get("id", "")):
				found = true
		assert_true(found,
			"part '%s' is authored in slot '%s' but that slot's picker never offers it, so "
			% [def.get("id", "?"), slot] + "no car could ever acquire it")


# An option the player cannot take says "Locked" — never a price. A greyed row quoting
# "2 STARS" reads as a price tag on something buyable (it is the same shape the affordable
# rows carry beside the star icon) when it actually means "you cannot take this". One word
# for every unavailable option, whatever the reason.
func test_an_unaffordable_option_reads_as_locked_not_as_a_price() -> void:
	var owned := _car()
	_save.profile["stars_earned"] = 0   # afford nothing at all
	var quoted_a_price := false
	var saw_locked := false
	for slot in UpgradeOptions.grid_slots():
		if slot == UpgradeOptions.SLOT_ENGINE or slot == UpgradeOptions.SLOT_TUNE:
			continue
		for opt in UpgradeOptions.options_for(_save.get_car(int(owned["instance_id"])), slot):
			var reason := String(opt.get("locked_reason", ""))
			if reason == "":
				continue
			saw_locked = true
			# Derived, not pinned: the reason must not contain the figure the pricing API
			# would quote for this option.
			if reason.contains(str(Save.part_price(String(opt.get("id", ""))))):
				quoted_a_price = true
	assert_true(saw_locked, "setup: with no stars, something is unavailable")
	assert_false(quoted_a_price, "an unavailable row must not quote what it would cost")


# Ballast (anything that ADDS mass) is gone from the shipped catalogue: entry is
# categorical, so there is nothing to duck under by getting slower, and an option whose
# whole effect is "make your car worse" is a row every player scrolls past. The `free` and
# mass-adding BRANCHES survive, which is why the synthetic fx_ballast fixture remains.
func test_the_shipped_catalogue_offers_no_mass_adding_part() -> void:
	UpgradeFixtures.restore()   # the real catalogue, not the synthetic roster
	for def in UpgradeLibrary.all():
		var mult := float((def.get("effect", {}) as Dictionary).get("mass_mult", 1.0))
		assert_lte(mult, 1.0,
			"'%s' adds mass; ballast was retired from the shipped catalogue" % def.get("id", "?"))
	UpgradeFixtures.install()
