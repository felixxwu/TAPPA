extends GutTest
# The overworld's MINIMAP and FULL MAP (`scripts/overworld_map.gd`). See features/overworld.md →
# "Wayfinding".
#
# Everything here is RENDERER-FREE: the map is built with `visuals: false`, so no Control and no
# fog texture exist, while the MODEL — the projection, the revealed destination set, the
# selection cursor and the open/close state machine — is fully live. That split is the whole
# reason the drawing lives in `_paint*` and nothing else reads a Control.
#
# NOTHING here pins a tunable. The panel size, the zoom, the pin radius, the line widths and
# every alpha are GameConfig fields a designer retunes freely; the projection tests choose their
# OWN spans and rects so no assertion depends on the authored ones. The roster is synthetic
# (`RallyFixtures`) for the same reason — reveal is geometric, and the fixtures' pin positions
# are the load-bearing part.

const SaveTestHelpers = preload("res://tests/headless/save_test_helpers.gd")
const TEST_PATH := "user://test_overworld_map.json"

# Map->world scale for this file. Arbitrary and local: the real conversion belongs to
# overworld.gd and is INJECTED, which is the seam these tests use.
const SIZE_M := 1000.0

# THE STARTING LIGHT. HQ lights NOTHING (features/map-exploration.md — `map_hq_reveal_radius`
# ships at 0.0), so a fresh profile over a fixture roster reveals nothing at all and every pin
# test below would pass vacuously with only the garage listed. Rather than raising the HQ radius
# — which would change the shipped reveal rule for the duration of the test — this file lights
# the map the way the game does: through a COMPLETED rally. `_seed_rally` is a test-owned rally
# parked on HQ that `before_each` marks completed in the live profile, exactly as
# test_overworld_zones.gd's `_complete` does.
#
# Its radius is load-bearing fixture geometry, like RallyFixtures' pin positions: wide enough to
# reach every fixture pin clustered around the middle, and deliberately NOT wide enough to reach
# fx_gated (0.28 away), which stays dark so "complete fx_open to open fx_gated" is still the
# reveal-progression case. Every test that depends on either half carries an "else vacuous"
# guard, so moving a pin fails loudly rather than silently.
const SEED_ID := "fx_seed_lit"
const SEED_REVEAL_RADIUS := 0.15


func before_each() -> void:
	RallyFixtures.install()
	SaveTestHelpers.redirect(TEST_PATH)
	_override_with_seed(RallyFixtures.rallies())
	_complete(SEED_ID)


func after_each() -> void:
	SaveTestHelpers.cleanup(TEST_PATH)
	RallyFixtures.restore()


# --- Helpers ------------------------------------------------------------------------------


# A logic-only map over the fixture roster, gated against the LIVE profile (so a test can
# complete a rally and re-`refresh()` to watch a pin appear).
func _map() -> OverworldMap:
	var map := OverworldMap.new()
	add_child_autofree(map)
	map.setup({
		"size_m": SIZE_M,
		# The roster is passed EXPLICITLY through the seam. `setup`'s own default is the shipped
		# `RallyLibrary.RALLIES` const, which `override_for_test` cannot reach — so without this
		# the map would be built over shipped content while reveal was judged against the
		# fixture roster, and no fixture id could ever be listed.
		"rallies": RallyLibrary.all(),
		"to_world": Callable(self, "_to_world"),
		"visuals": false,
	})
	return map


# The lit seed described at the top of the file: an ordinary rally in every respect, parked on
# HQ, with an authored reveal radius that reaches the fixture cluster but not fx_gated.
func _seed_rally() -> Dictionary:
	return {
		"id": SEED_ID, "name": "Fixture Seed", "region": "home", "difficulty": 1,
		"special": false, "map_pos": RallyLibrary.HQ_MAP_POS,
		"reveal_radius": SEED_REVEAL_RADIUS, "restriction": {}, "events": [],
	}


# Install `extra` as the roster WITH the lit seed in front of it, so a test that swaps the whole
# roster for a probe rally still has something lighting the map.
func _override_with_seed(extra: Array[Dictionary]) -> void:
	var roster: Array[Dictionary] = [_seed_rally()]
	roster.append_array(extra)
	RallyLibrary.override_for_test(roster)


func _to_world(map_pos: Vector2) -> Vector3:
	return Overworld.world_xz(map_pos, SIZE_M)


# The host's veto hook, standing in for "the pause menu is open".
func _veto() -> bool:
	return false


func _press(action: String) -> InputEventAction:
	var e := InputEventAction.new()
	e.action = action
	e.pressed = true
	return e


# A REAL gamepad button event for `action`, taken from whatever button the project binds — so
# the test proves a controller press reaches the handler without pinning the button index (a
# platform convention, not behaviour).
func _gamepad_press(action: String) -> InputEventJoypadButton:
	for e in InputMap.action_get_events(action):
		if e is InputEventJoypadButton:
			var press := (e as InputEventJoypadButton).duplicate() as InputEventJoypadButton
			press.pressed = true
			press.pressure = 1.0
			return press
	return null


# Mark a rally completed in the LIVE profile — reveal is re-derived from it, so a reveal test
# has to move the real profile, not a copy.
func _complete(rally_id: String) -> void:
	var rallies: Dictionary = Save.profile[Save.KEY_RALLIES]
	rallies[rally_id] = {"completed": true, "best_placed": 1}


func _ids(map: OverworldMap) -> Array[String]:
	var out: Array[String] = []
	for entry in map.destinations():
		out.append(String(entry.get("id", "")))
	return out


# --- Projection ---------------------------------------------------------------------------


# world -> screen -> world is the identity, at an arbitrary span, rotation and rect. This is the
# contract every pin, the player arrow and the fog rely on.
func test_projection_round_trips() -> void:
	var rect := Rect2(Vector2(40.0, 90.0), Vector2(320.0, 240.0))
	var centre := Vector2(120.0, -60.0)
	for rot in [0.0, 0.7, -2.3]:
		for point in [Vector2(0.0, 0.0), Vector2(-310.0, 25.0), Vector2(88.0, 402.0)]:
			var screen := OverworldMap.project(point, centre, 500.0, rot, rect)
			var back := OverworldMap.unproject(screen, centre, 500.0, rot, rect)
			assert_almost_eq(back.x, point.x, 0.01, "x survives the round trip at rot %s" % rot)
			assert_almost_eq(back.y, point.y, 0.01, "y survives the round trip at rot %s" % rot)


# The view's centre lands in the middle of the map rect — the property that makes the player
# arrow sit in the middle of the minimap and the map's centre sit in the middle of the overlay.
func test_view_centre_projects_to_the_middle_of_the_rect() -> void:
	var rect := Rect2(Vector2(10.0, 20.0), Vector2(400.0, 400.0))
	var centre := Vector2(-250.0, 175.0)
	var mid := OverworldMap.project(centre, centre, 900.0, 1.1, rect)
	assert_almost_eq(mid.x, rect.get_center().x, 0.01, "the view centre is the rect centre in x")
	assert_almost_eq(mid.y, rect.get_center().y, 0.01, "the view centre is the rect centre in y")


# The whole map fits: the corners of `Overworld.bounds_for` land inside a square rect when the
# span is the world's edge length, north-up. (No tunable involved — SIZE_M is this file's own.)
func test_the_world_bounds_fit_a_north_up_square_view() -> void:
	var rect := Rect2(Vector2.ZERO, Vector2(600.0, 600.0))
	var world := Overworld.bounds_for(SIZE_M)
	for corner in [world.position, world.end, Vector2(world.position.x, world.end.y)]:
		var p := OverworldMap.project(corner, Vector2.ZERO, SIZE_M, 0.0, rect)
		assert_true(rect.grow(0.5).has_point(p),
				"world corner %s is inside the map rect" % corner)


# Heading-up: whatever the car is facing ends up pointing at the TOP of the view (-y on screen).
func test_heading_rotation_puts_the_car_facing_up() -> void:
	# The array is TYPED so `forward` is a Vector2 rather than a Variant — an untyped literal
	# makes `forward.rotated(...)` return Variant, and `var up :=` then cannot infer a type, which
	# is a parse error under this project's warnings-as-errors settings.
	var facings: Array[Vector2] = [
		Vector2(1.0, 0.0), Vector2(0.0, 1.0), Vector2(-0.6, 0.8).normalized(),
	]
	for forward in facings:
		var rot := OverworldMap.heading_rotation(forward, true)
		var up := forward.rotated(rot)
		assert_almost_eq(up.x, 0.0, 0.001, "facing %s rotates to straight up in x" % forward)
		assert_almost_eq(up.y, -1.0, 0.001, "facing %s rotates to straight up in y" % forward)


# North-up mode does not rotate at all — world +x is screen right and +z screen down already,
# which is what lets the full map skip the rotation entirely.
func test_north_up_mode_does_not_rotate() -> void:
	assert_eq(OverworldMap.heading_rotation(Vector2(1.0, 0.0), false), 0.0,
			"a north-up view applies no rotation")


# --- The revealed set (the fog is load-bearing) --------------------------------------------


# ONLY revealed destinations are listed. The complement is asserted in the same test so it
# cannot pass vacuously: fx_gated is parked outside the starting lit circle and must be absent,
# and it must APPEAR once the rally whose reveal circle reaches it is completed.
func test_only_revealed_destinations_are_listed() -> void:
	var map := _map()
	var listed := _ids(map)
	assert_true(listed.has("fx_open"),
			"a rally inside the starting lit circle is listed (else this test is vacuous)")
	assert_false(listed.has("fx_gated"), "an unrevealed rally is withheld from the map")

	_complete("fx_open")
	map.refresh()
	assert_true(RallyLibrary.rally_revealed(RallyLibrary.by_id("fx_gated"), Save.profile),
			"the shared predicate now reveals fx_gated (else the case below is vacuous)")
	assert_true(_ids(map).has("fx_gated"), "a newly revealed rally appears on the map")


# Every listed rally passes the SHARED predicate — never a lookalike distance test, because the
# fog exists precisely to withhold the shape of an unexplored roster.
func test_every_listed_rally_passes_the_shared_reveal_predicate() -> void:
	var map := _map()
	for entry in map.destinations():
		var id := String(entry.get("id", ""))
		if id == OverworldMap.GARAGE_ID:
			continue
		assert_true(RallyLibrary.rally_revealed(RallyLibrary.by_id(id), Save.profile),
				"%s is listed only because rally_revealed says so" % id)


# The garage is a DESTINATION, not a roster entry: it has no id, no map_pos and no reveal state,
# so the reveal predicate would answer false for it forever. It must always be listed or the
# player can never find their own garage.
func test_the_garage_is_always_listed() -> void:
	var map := _map()
	assert_true(_ids(map).has(OverworldMap.GARAGE_ID), "the garage is listed on a fresh profile")
	# And it stays listed when NOTHING else is: an empty roster (no seed either, so nothing
	# lights anything at all) must not hide home.
	RallyLibrary.override_for_test([] as Array[Dictionary])
	var empty := _map()
	assert_eq(_ids(empty), [OverworldMap.GARAGE_ID] as Array[String],
			"with no rallies at all, the garage is still the one destination")


# --- Pin identity: the kind and the icon a pin draws ----------------------------------------
#
# The pins are ICONS, not coloured dots (a pennant, a car, a trophy, a house, and a part's OWN
# `UpgradeIcons` texture). The DRAWING needs a renderer, but everything that decides WHAT is drawn
# is model state on the entry — `kind` and `icon` — so it is all assertable here. Nothing below
# pins a size, a colour or an authored catalogue entry.


# A rally id the upgrade catalogue actually gates something behind, discovered by walking the
# table as opaque input rather than naming an entry (the catalogue is always subject to change).
# Returns "" if nothing is gated at all, in which case the tests below skip themselves.
func _a_part_gating_rally_id() -> String:
	for item in UpgradeLibrary.UPGRADES:
		var rid := String(item.get("unlocked_by_rally", ""))
		if rid != "":
			return rid
	return ""


# A minimal rally with the given id, parked on HQ — which is where the lit seed sits, so
# installing the two together (`_override_with_seed`) is what stops the fog withholding it.
# Synthetic on purpose: the only load-bearing field is the ID, which is what the upgrade
# catalogue's reverse gate is keyed by.
func _rally_at_hq(id: String) -> Dictionary:
	return {
		"id": id, "name": "Icon Probe", "region": "home", "difficulty": 1, "special": false,
		"map_pos": RallyLibrary.HQ_MAP_POS, "restriction": {}, "events": [],
	}


# Every listed destination reads as one of the map's OWN kinds — the enum the painter switches on.
# A kind outside it would silently draw the fallback glyph for everything.
func test_every_revealed_destination_resolves_to_a_known_kind() -> void:
	var map := _map()
	assert_false(map.destinations().is_empty(), "there is something to check (else vacuous)")
	for entry in map.destinations():
		var kind := int(entry.get("kind", -1))
		assert_true(kind >= 0 and kind < OverworldMap.Kind.size(),
				"%s has a drawable kind, got %s" % [entry.get("id", ""), kind])


# A pin and the 3D marker floating over the same zone must promise the SAME thing — the map
# borrows `OverworldMarker.kind_of` rather than re-deriving the trichotomy, and this is the
# assertion that keeps them from drifting apart.
func test_a_pin_agrees_with_the_3d_marker_about_what_the_rally_promises() -> void:
	var expected := {
		OverworldMarker.Kind.CAR: OverworldMap.Kind.CAR,
		OverworldMarker.Kind.PART: OverworldMap.Kind.PART,
		OverworldMarker.Kind.TROPHY: OverworldMap.Kind.SPECIAL,
		OverworldMarker.Kind.FLAG: OverworldMap.Kind.RALLY,
	}
	var map := _map()
	var checked := 0
	for entry in map.destinations():
		var rally: Dictionary = entry.get("rally", {})
		if rally.is_empty():
			continue    # the garage is not a rally and has no marker
		checked += 1
		assert_eq(int(entry.get("kind", -1)),
				int(expected[OverworldMarker.kind_of(rally)]),
				"%s wears the same kind on the map as on its marker" % entry.get("id", ""))
	assert_gt(checked, 0, "at least one revealed rally pin was compared (else this test is vacuous)")


# A PART pin draws the part's REAL icon — the same `UpgradeIcons` texture the upgrades grid tile
# and the 3D marker wear — so it must resolve to a texture, and to the marker's texture exactly.
func test_a_part_unlock_pin_resolves_to_the_parts_own_icon_texture() -> void:
	var gated := _a_part_gating_rally_id()
	if gated == "":
		pass_test("nothing in the upgrade catalogue is gated behind a rally; nothing to check")
		return
	var roster: Array[Dictionary] = [_rally_at_hq(gated)]
	_override_with_seed(roster)
	var map := _map()
	var found := false
	for entry in map.destinations():
		if String(entry.get("id", "")) != gated:
			continue
		found = true
		assert_eq(int(entry.get("kind", -1)), int(OverworldMap.Kind.PART),
				"a rally that gates an upgrade reads as a PART pin")
		var icon := entry.get("icon", null) as Texture2D
		assert_not_null(icon, "a PART pin resolves to a real icon texture")
		assert_eq(icon, OverworldMarker.part_texture(roster[0]),
				"and it is exactly the texture the 3D marker floats")
	assert_true(found, "the probe rally is revealed and listed (else this test is vacuous)")


# THE LOAD-BEARING NEGATIVE. `UpgradeIcons` hands back the TUNE wrench for any slot it has no art
# for, so a map that asked it for every pin would make the whole roster read as a tuning event.
# A rally that unlocks nothing recognisable must carry NO icon at all and fall back to the flag
# kind — the rule `overworld_marker.gd::part_slot_of` establishes, which the map must not contradict.
func test_a_rally_that_unlocks_nothing_carries_no_icon_and_falls_back_to_the_flag() -> void:
	# Not vacuous: the generic fallback really does exist and really is non-null, which is exactly
	# what the map must NOT reach for.
	assert_not_null(UpgradeIcons.texture("no_such_slot_exists"),
			"UpgradeIcons has a generic fallback (the trap this test guards)")
	_override_with_seed([_rally_at_hq("fx_unlocks_nothing")] as Array[Dictionary])
	var map := _map()
	var found := false
	for entry in map.destinations():
		if String(entry.get("id", "")) != "fx_unlocks_nothing":
			continue
		found = true
		assert_null(entry.get("icon", null),
				"a rally that unlocks nothing resolves to no icon, not to the wrench")
		assert_eq(int(entry.get("kind", -1)), int(OverworldMap.Kind.RALLY),
				"and it reads as an ordinary rally, so the painter draws the pennant")
	assert_true(found, "the probe rally is listed (else this test is vacuous)")


# The garage is not a rally, so it must never be handed a part icon — its glyph is the house.
func test_the_garage_carries_no_part_icon() -> void:
	var map := _map()
	for entry in map.destinations():
		if String(entry.get("id", "")) != OverworldMap.GARAGE_ID:
			continue
		assert_eq(int(entry.get("kind", -1)), int(OverworldMap.Kind.GARAGE),
				"the garage reads as the garage kind")
		assert_null(entry.get("icon", null), "and carries no part icon")


# --- Open / close, keyboard AND gamepad (the mandatory nav coverage) ------------------------


func test_the_map_starts_closed() -> void:
	assert_false(_map().is_open(), "the map is not on screen until it is asked for")


func test_toggle_map_is_bound_on_keyboard_and_gamepad() -> void:
	assert_true(InputMap.has_action(OverworldMap.TOGGLE_ACTION),
			"the map's toggle action exists in project.godot")
	var has_key := false
	var has_pad := false
	for e in InputMap.action_get_events(OverworldMap.TOGGLE_ACTION):
		has_key = has_key or e is InputEventKey
		has_pad = has_pad or e is InputEventJoypadButton or e is InputEventJoypadMotion
	assert_true(has_key, "the map can be opened from the keyboard")
	assert_true(has_pad, "the map can be opened from a controller")


func test_the_toggle_action_opens_and_closes_the_map() -> void:
	var map := _map()
	map._unhandled_input(_press(OverworldMap.TOGGLE_ACTION))
	assert_true(map.is_open(), "the toggle action opens the map")
	map._unhandled_input(_press(OverworldMap.TOGGLE_ACTION))
	assert_false(map.is_open(), "the same action closes it again")


func test_a_gamepad_button_opens_and_closes_the_map() -> void:
	var press := _gamepad_press(OverworldMap.TOGGLE_ACTION)
	assert_not_null(press, "the toggle action has a gamepad binding to press")
	var map := _map()
	map._unhandled_input(press)
	assert_true(map.is_open(), "a controller press opens the map")
	map._unhandled_input(press)
	assert_false(map.is_open(), "a controller press closes it again")


func test_ui_cancel_and_menu_back_close_the_map() -> void:
	for action in ["ui_cancel", "menu_back"]:
		var map := _map()
		map.open()
		assert_true(map.is_open(), "the map is open before %s" % action)
		map._unhandled_input(_press(action))
		assert_false(map.is_open(), "%s closes the map" % action)


# Back must not OPEN the map — otherwise Esc out of nothing would put a map on screen.
func test_back_does_not_open_a_closed_map() -> void:
	var map := _map()
	map._unhandled_input(_press("ui_cancel"))
	assert_false(map.is_open(), "ui_cancel on a closed map does nothing")


# The host's veto (the pause guard: M must not open a map over an open pause screen).
func test_the_host_can_veto_the_toggle() -> void:
	var map := OverworldMap.new()
	add_child_autofree(map)
	map.setup({
		"size_m": SIZE_M, "to_world": Callable(self, "_to_world"), "visuals": false,
		"can_toggle": Callable(self, "_veto"),
	})
	map._unhandled_input(_press(OverworldMap.TOGGLE_ACTION))
	assert_false(map.is_open(), "a vetoed toggle leaves the map closed")


# The signal the host locks the car's controls on.
func test_opening_and_closing_emits_map_toggled() -> void:
	var map := _map()
	watch_signals(map)
	map.open()
	map.close()
	assert_signal_emit_count(map, "map_toggled", 2,
			"the host is told once on open and once on close")


# --- The selection cursor -----------------------------------------------------------------


# Directional input walks the REVEALED destinations and wraps in both directions.
func test_the_selection_cycles_through_the_revealed_destinations_and_wraps() -> void:
	var map := _map()
	map.open()
	var listed := _ids(map)
	assert_gt(listed.size(), 1, "there is more than one destination to cycle (else vacuous)")

	var seen: Array[String] = []
	map.select_id(listed[0])
	for _i in listed.size():
		seen.append(String(map.selected().get("id", "")))
		map.select_step(1)
	assert_eq(seen.size(), listed.size(), "one step per destination visits them all")
	for id in listed:
		assert_true(seen.has(id), "%s is reachable by cycling" % id)
	assert_eq(String(map.selected().get("id", "")), listed[0],
			"a full lap of steps wraps back to where it started")

	map.select_step(-1)
	assert_eq(String(map.selected().get("id", "")), listed[listed.size() - 1],
			"stepping back from the first destination wraps to the last")


# Directional INPUT (both families) moves the cursor, not just the API — this is the "does
# something sensible with left/right" half of the nav rule.
func test_directional_input_moves_the_selection() -> void:
	for action in ["ui_right", "menu_right", "ui_left", "menu_left"]:
		var map := _map()
		map.open()
		var first := String(map.selected().get("id", ""))
		map._unhandled_input(_press(action))
		assert_ne(String(map.selected().get("id", "")), first,
				"%s moves the selection off the opening destination" % action)


# The selection only ever names something the player is allowed to know about.
func test_an_unrevealed_destination_cannot_be_selected() -> void:
	var map := _map()
	assert_false(map.select_id("fx_gated"), "selecting a withheld destination is refused")
	assert_true(map.selected().is_empty(), "and leaves nothing selected")


# Opening picks the NEAREST destination, so the footer answers the likeliest question first.
func test_opening_selects_the_nearest_destination() -> void:
	var map := _map()
	# Park the car on top of one of the revealed pins, then open.
	var target := map.destinations()[0]
	var at: Vector3 = target.get("world_pos", Vector3.ZERO)
	map.update(1.0, at, Basis.IDENTITY)
	map.open()
	assert_eq(String(map.selected().get("id", "")), String(target.get("id", "")),
			"the destination the car is sitting on is the one selected on open")


# --- Pointer picking ------------------------------------------------------------------------
# Touch and mouse are the ONLY way to choose a destination on a phone, so the hit test is a
# behaviour, not a convenience. `nearest_pin_id` is static and takes its whole view explicitly,
# which is what lets these run with no Control and no pointer at all. Nothing here pins the
# authored pick radius — each test passes its own.


func _pin(id: String, world: Vector3) -> Dictionary:
	return {"id": id, "name": id, "kind": OverworldMap.Kind.RALLY, "world_pos": world}


func _pins() -> Array[Dictionary]:
	var out: Array[Dictionary] = [
		_pin("near", Vector3(0.0, 0.0, 0.0)),
		_pin("far", Vector3(400.0, 0.0, 400.0)),
	]
	return out


# A tap ON a pin picks that pin: the tap point is projected through the same transform that drew
# it, so "where it looks" and "what is hit" cannot drift apart.
func test_a_tap_on_a_pin_picks_it() -> void:
	var rect := Rect2(Vector2.ZERO, Vector2(500.0, 500.0))
	var at := OverworldMap.project(Vector2(400.0, 400.0), Vector2.ZERO, 1000.0, 0.0, rect)
	assert_eq(OverworldMap.nearest_pin_id(_pins(), at, Vector2.ZERO, 1000.0, 0.0, rect, 20.0),
			"far", "the tap lands on the pin drawn there")


# A tap on empty map picks NOTHING — otherwise every stray tap would re-route the player to
# whichever pin happened to be least far away across the whole world.
func test_a_tap_away_from_every_pin_picks_nothing() -> void:
	var rect := Rect2(Vector2.ZERO, Vector2(500.0, 500.0))
	var at := OverworldMap.project(Vector2(-400.0, 400.0), Vector2.ZERO, 1000.0, 0.0, rect)
	assert_eq(OverworldMap.nearest_pin_id(_pins(), at, Vector2.ZERO, 1000.0, 0.0, rect, 20.0),
			"", "an empty patch of map picks nothing")


# Between two pins inside the radius, the NEARER one wins — a fat finger over a cluster must
# still resolve to the pin it is closest to.
func test_overlapping_pins_resolve_to_the_nearest() -> void:
	var rect := Rect2(Vector2.ZERO, Vector2(500.0, 500.0))
	var pins: Array[Dictionary] = [
		_pin("a", Vector3(0.0, 0.0, 0.0)),
		_pin("b", Vector3(20.0, 0.0, 0.0)),
	]
	var at := OverworldMap.project(Vector2(18.0, 0.0), Vector2.ZERO, 1000.0, 0.0, rect)
	assert_eq(OverworldMap.nearest_pin_id(pins, at, Vector2.ZERO, 1000.0, 0.0, rect, 200.0),
			"b", "the closer of two candidates wins")


# --- The sat-nav ----------------------------------------------------------------------------


# The route is gated by the SAME fog as the pin: a destination the player has not revealed cannot
# be routed to, or the sat-nav would draw a line into content the map is withholding.
func test_an_unrevealed_destination_cannot_be_routed_to() -> void:
	var map := _map()
	assert_false(map.set_route("fx_gated"), "routing to a withheld destination is refused")
	assert_eq(map.route_id(), "", "and no route is set")


# Setting and clearing a route is the state the minimap draws from.
func test_a_route_can_be_set_and_cleared() -> void:
	var map := _map()
	var id := String(map.destinations()[0].get("id", ""))
	assert_true(map.set_route(id), "a revealed destination can be routed to")
	assert_eq(map.route_id(), id, "the sat-nav names it")
	map.clear_route()
	assert_eq(map.route_id(), "", "clearing cancels the sat-nav")


# With no road network there is nothing to follow, and the map must say so by drawing NOTHING
# rather than by inventing a straight line the player cannot drive.
func test_a_route_without_roads_draws_nothing() -> void:
	var map := _map()
	assert_true(map.set_route(String(map.destinations()[0].get("id", ""))))
	assert_eq(map.route_points().size(), 0, "no road network, no drawn route")
	assert_almost_eq(map.route_length_m(), 0.0, 0.001, "and no quoted road distance")


# A route survives the refresh timer: it is RE-PLANNED every refresh (so it follows the car), and
# a re-plan must not silently drop the destination the player chose.
func test_a_route_survives_a_refresh() -> void:
	var map := _map()
	var id := String(map.destinations()[0].get("id", ""))
	map.set_route(id)
	map.refresh()
	assert_eq(map.route_id(), id, "the chosen destination outlives a refresh")


# Closing the map keeps the route. The whole point is to follow it while DRIVING, which happens
# with the full map shut.
func test_closing_the_map_keeps_the_route() -> void:
	var map := _map()
	var id := String(map.destinations()[0].get("id", ""))
	map.open()
	map.set_route(id)
	map.close()
	assert_eq(map.route_id(), id, "the sat-nav outlives the map that set it")


# `ui_accept` is the pointerless path to the sat-nav (gamepad, keyboard), and pressing it again on
# the same destination cancels — one action, both directions.
func test_accept_sets_the_route_and_pressing_it_again_clears_it() -> void:
	var map := _map()
	map.open()
	var sel := String(map.selected().get("id", ""))
	map._unhandled_input(_press("ui_accept"))
	assert_eq(map.route_id(), sel, "accept routes to the selected destination")
	map._unhandled_input(_press("ui_accept"))
	assert_eq(map.route_id(), "", "accept on the routed destination cancels it")


# --- The road reveal gate -------------------------------------------------------------------
# A road is PAINTED only when both of its endpoints are revealed. This is a map-only rule — the
# network is still built and carved into the terrain progress-independently — so everything here
# asserts on what the map decided to draw (`road_is_shown`), never on the network.
#
# The stub network below is the test's own input: node ids matter (they are the reveal keys), the
# geometry does not, and nothing reaches into `OverworldRoads` or the shipped roster.


# A road graph over explicit node ids, in the shape `OverworldRoads` publishes.
class StubRoads:
	extends RefCounted

	var _nodes: Array[Dictionary] = []
	var _edges: Array[Dictionary] = []

	func _init(node_ids: Array, links: Array) -> void:
		for i in node_ids.size():
			_nodes.append({"id": String(node_ids[i]), "world": Vector2(float(i) * 100.0, 0.0)})
		for link in links:
			var a := int(link[0])
			var b := int(link[1])
			_edges.append({
				"a": a, "b": b, "tarmac": 0.0, "length_m": 100.0,
				"points": PackedVector2Array([_nodes[a]["world"], _nodes[b]["world"]]),
			})

	func nodes() -> Array[Dictionary]:
		return _nodes

	func edges() -> Array[Dictionary]:
		return _edges

	func width_m() -> float:
		return 7.0


# The map, with a road network wired in. `fx_open` is revealed by the lit seed; `fx_gated` is not
# (see SEED_REVEAL_RADIUS at the top of the file), which is what makes the two edges below differ.
func _map_with_roads(node_ids: Array, links: Array) -> OverworldMap:
	var map := OverworldMap.new()
	add_child_autofree(map)
	map.setup({
		"size_m": SIZE_M,
		"rallies": RallyLibrary.all(),
		"to_world": Callable(self, "_to_world"),
		"roads": StubRoads.new(node_ids, links),
		"visuals": false,
	})
	return map


# Find the captured edge joining two node ids, whichever way round it was stored.
func _road_between(map: OverworldMap, a: String, b: String) -> int:
	for i in map.road_count():
		var ends := map.road_ends(i)
		if ends.size() == 2 and ((ends[0] == a and ends[1] == b) or (ends[0] == b and ends[1] == a)):
			return i
	return -1


# THE RULE. A road to a revealed pin is drawn; a road to a hidden one is not — otherwise the map
# signposts content the fog is deliberately withholding.
func test_a_road_to_a_hidden_pin_is_not_painted() -> void:
	var map := _map_with_roads(["__hq__", SEED_ID, "fx_open", "fx_gated"],
			[[0, 2], [2, 3]])
	assert_true(_ids(map).has("fx_open"), "else vacuous: fx_open must be revealed")
	assert_false(_ids(map).has("fx_gated"), "else vacuous: fx_gated must be hidden")

	var open_edge := _road_between(map, "__hq__", "fx_open")
	var dark_edge := _road_between(map, "fx_open", "fx_gated")
	assert_gt(open_edge, -1, "the revealed edge was captured")
	assert_gt(dark_edge, -1, "the edge into the dark was captured")
	assert_true(map.road_is_shown(open_edge), "a road between revealed ends is painted")
	assert_false(map.road_is_shown(dark_edge), "a road to a hidden pin is withheld")


# BOTH ends, not either: the edge above has one revealed end, and it is still dropped. A half-drawn
# road is the same signpost with a shorter line.
func test_an_edge_with_one_hidden_end_is_dropped_whole() -> void:
	var map := _map_with_roads(["__hq__", SEED_ID, "fx_open", "fx_gated"], [[2, 3]])
	assert_eq(map.road_count(), 1, "one edge captured")
	assert_true(_ids(map).has("fx_open"), "else vacuous: one end is revealed")
	assert_false(map.road_is_shown(0), "one hidden end hides the whole edge")


# The road HOME is always drawn. The garage is exempt from the fog for its pin, and a player who
# cannot see the way back to their own garage has been given a worse map, not a mysterious one.
func test_the_garage_end_never_hides_a_road() -> void:
	var map := _map_with_roads(["__hq__", SEED_ID, "fx_open"], [[0, 2]])
	assert_true(map.road_is_shown(_road_between(map, "__hq__", "fx_open")),
			"an edge from the garage to a revealed pin is painted")


# Completing a rally OPENS its roads, on the same refresh that lights its pin — the drawn network
# grows with exploration rather than being handed over up front.
func test_completing_a_rally_opens_the_road_to_it() -> void:
	var map := _map_with_roads(["__hq__", SEED_ID, "fx_open", "fx_gated"], [[2, 3]])
	assert_false(map.road_is_shown(0), "else vacuous: the edge starts hidden")
	_complete("fx_open")
	map.refresh()
	if not _ids(map).has("fx_gated"):
		pending("fx_open's reveal radius no longer reaches fx_gated; fixture geometry moved")
		return
	assert_true(map.road_is_shown(0), "both ends revealed, so the road appears")


# A network whose endpoints cannot be resolved FAILS OPEN. An unidentifiable network is the old
# ungated behaviour; blanking every road would be a far more confusing failure than drawing one road
# too many — and `setup`'s `roads` seam is documented as duck-typed, so a source with `edges()` and
# no `nodes()` is a shape the map must tolerate.
class EdgesOnlyRoads:
	extends RefCounted

	func edges() -> Array[Dictionary]:
		return [{
			"a": 0, "b": 1, "tarmac": 0.0, "length_m": 100.0,
			"points": PackedVector2Array([Vector2.ZERO, Vector2(100.0, 0.0)]),
		}]

	func width_m() -> float:
		return 7.0


func test_a_road_source_without_nodes_still_draws_every_road() -> void:
	var map := OverworldMap.new()
	add_child_autofree(map)
	map.setup({
		"size_m": SIZE_M, "rallies": RallyLibrary.all(),
		"to_world": Callable(self, "_to_world"),
		"roads": EdgesOnlyRoads.new(), "visuals": false,
	})
	assert_eq(map.road_count(), 1, "the edge was captured")
	assert_eq(map.road_ends(0), PackedStringArray(["", ""]), "with unresolved endpoints")
	assert_true(map.road_is_shown(0), "an unidentifiable network fails open rather than blank")


# --- The synthetic cursor (NAV COVERAGE) ----------------------------------------------------
# CLAUDE.md's nav rule: the full map is a menu, and this is its navigation. The cursor is a
# SYNTHETIC POINTER — pad/keyboard motion goes through the same `_pick_at` / `_set_hover` /
# `select_id` path as the mouse — so these tests drive `move_cursor` / `place_cursor` (the one entry
# point for cursor motion) and the real directional ACTIONS, on keyboard AND gamepad.
#
# `_process`'s `Input.get_vector` polling is the only untestable half (it needs a real held stick);
# it does nothing but call `move_cursor`, which is what is asserted here.
#
# Nothing pins a tunable: the cursor speed and the pick radius are GameConfig fields, so every
# assertion below is about WHERE the cursor ended up relative to geometry the test computes itself.


# The map's own view rect and the screen position of a given destination within it — the same
# projection the painter uses, so a test aims where the player would see the pin.
func _pin_screen_pos(map: OverworldMap, id: String) -> Vector2:
	for entry in map.destinations():
		if String(entry.get("id", "")) == id:
			var w: Vector3 = entry.get("world_pos", Vector3.ZERO)
			return OverworldMap.project(Vector2(w.x, w.z), Vector2.ZERO, SIZE_M, 0.0,
					map.full_map_rect())
	return Vector2.INF


# A destination that can actually be AIMED AT: one where putting the pointer on the pin resolves to
# that pin. `""` when the fixture roster has none.
#
# WHY THIS EXISTS. Pins can share a pixel. The lit seed rally is parked on `HQ_MAP_POS` and so is the
# garage, so both project to the SAME point, and a pointer put there is genuinely ambiguous — the
# mouse resolves it exactly as the cursor does (last equal-distance candidate wins). Picking a target
# by INDEX therefore silently asserts about tie-breaking order rather than about magnetism. This asks
# the code's OWN predicate (`pick_at`) which pins are unambiguous, so no threshold is pinned and a
# fixture reshuffle degrades to `pending` instead of failing.
func _aimable_id(map: OverworldMap, avoid: String = "") -> String:
	for id in _ids(map):
		if id == avoid:
			continue
		if map.pick_at(_pin_screen_pos(map, id)) == id:
			return id
	return ""


# A cursor only exists once it is asked for: a mouse player must never get a second crosshair.
func test_the_cursor_starts_disarmed() -> void:
	var map := _map()
	map.open()
	assert_false(map.cursor_active(), "no cursor until pad or keyboard input asks for one")


# ARROW KEYS and WASD arm the cursor and park it ON the selection, so the two ways of moving it can
# never disagree about what is selected. This is the keyboard half of the nav rule.
func test_a_directional_key_arms_the_cursor_on_the_selection() -> void:
	for action in ["ui_right", "menu_right", "ui_down", "menu_left"]:
		var map := _map()
		map.open()
		map._unhandled_input(_press(action))
		assert_true(map.cursor_active(), "%s arms the cursor" % action)
		var sel := String(map.selected().get("id", ""))
		assert_ne(sel, "", "%s leaves something selected" % action)
		assert_almost_eq(map.cursor_pos().distance_to(_pin_screen_pos(map, sel)), 0.0, 1.0,
				"%s leaves the cursor on the selected pin" % action)


# The GAMEPAD half of the same rule, driven by whatever button the project actually binds so no
# button index is pinned.
func test_a_gamepad_direction_arms_the_cursor() -> void:
	var press := _gamepad_press("ui_right")
	if press == null:
		pending("no gamepad button is bound to ui_right in this project")
		return
	var map := _map()
	map.open()
	map._unhandled_input(press)
	assert_true(map.cursor_active(), "a gamepad direction arms the cursor")
	assert_almost_eq(map.cursor_pos().distance_to(
			_pin_screen_pos(map, String(map.selected().get("id", "")))), 0.0, 1.0,
			"and parks it on the selected pin")


# MAGNETISM, the whole point of "to help with selection": landing NEAR a pin selects it. The offset
# below is deliberately not zero — a player should not have to be pixel-perfect.
func test_the_cursor_selects_a_pin_it_lands_near() -> void:
	var map := _map()
	map.open()
	# Aim at an unambiguously aimable destination that is NOT already selected, so a pass proves the
	# move did it (and is not just tie-breaking between two co-located pins).
	var target := _aimable_id(map, String(map.selected().get("id", "")))
	if target == "":
		pending("no unambiguously aimable unselected pin; fixture reveal geometry moved")
		return
	map.place_cursor(_pin_screen_pos(map, target) + Vector2(3.0, -3.0))
	assert_eq(String(map.selected().get("id", "")), target,
			"landing near a pin selects it without pixel-perfect aim")
	assert_true(map.cursor_active(), "and the cursor is armed")


# Gliding across EMPTY map must not clear the selection — otherwise `ui_accept` mid-glide would do
# nothing and the footer would blank out as the player moved.
func test_gliding_over_empty_map_keeps_the_last_selection() -> void:
	var map := _map()
	map.open()
	var target := _aimable_id(map)
	var corner := map.full_map_rect().position
	if target == "" or map.pick_at(corner) != "":
		# Either no pin can be aimed at unambiguously, or a pin has moved into the corner this test
		# needs to be EMPTY. Both are fixture geometry, so degrade rather than fail.
		pending("no aimable pin, or the map corner is no longer empty; fixture geometry moved")
		return
	map.place_cursor(_pin_screen_pos(map, target))
	var held := String(map.selected().get("id", ""))
	assert_eq(held, target, "else vacuous: the pin was picked up first")
	map.place_cursor(corner)
	assert_eq(String(map.selected().get("id", "")), held,
			"empty map keeps the last selection rather than clearing it")


# The cursor cannot leave the drawn map, however hard the stick is pushed — an off-map cursor is
# invisible and selects nothing, which reads as the controls having died.
func test_the_cursor_cannot_leave_the_drawn_map() -> void:
	var map := _map()
	map.open()
	var rect := map.full_map_rect()
	for delta in [Vector2(99999.0, 99999.0), Vector2(-99999.0, -99999.0),
			Vector2(99999.0, -99999.0)]:
		map.move_cursor(delta)
		var p := map.cursor_pos()
		assert_true(rect.grow(0.5).has_point(p),
				"the cursor stays inside the map after %s (got %s)" % [delta, p])


# A real pointer disarms the synthetic one, so a mouse user never sees two cursors. (The pad
# re-arms it on the next direction — covered above.)
func test_mouse_motion_disarms_the_synthetic_cursor() -> void:
	var map := _map()
	map.open()
	map._unhandled_input(_press("ui_right"))
	assert_true(map.cursor_active(), "else vacuous: the cursor was armed first")
	var motion := InputEventMouseMotion.new()
	motion.position = map.full_map_rect().get_center()
	map._unhandled_input(motion)
	assert_false(map.cursor_active(), "real mouse motion disarms the synthetic cursor")


# Closing the map disarms the cursor — it must not be left drawn over a map nobody is looking at,
# and re-opening should not resume mid-glide.
func test_closing_the_map_disarms_the_cursor() -> void:
	var map := _map()
	map.open()
	map._unhandled_input(_press("ui_right"))
	map.close()
	assert_false(map.cursor_active(), "closing the map disarms the cursor")


# The cursor and the mouse share ONE path, so what the cursor selects can be routed with the same
# `ui_accept` a click uses. This is the end-to-end pad journey: aim, then commit.
func test_a_cursor_selection_can_be_routed_with_accept() -> void:
	var map := _map()
	map.open()
	var target := _aimable_id(map)
	if target == "":
		pending("no unambiguously aimable pin; fixture reveal geometry moved")
		return
	map.place_cursor(_pin_screen_pos(map, target))
	map._unhandled_input(_press("ui_accept"))
	assert_eq(map.route_id(), target, "the cursor's pin is what gets routed to")


# --- The minimap hides behind any modal -------------------------------------
#
# It already hid behind the full map and behind a pause. It must also hide behind the CAR PICKER,
# which is the case the user reported: a driving instrument floating over a car-selection screen.
#
# Asserted on the PREDICATE, not on the layer: every test in this file runs `visuals: false`, so
# there is no minimap node to read, and `_process` writes
# `visible = not _open and not _paused() and not _other_claimer()` — the third term is the new
# behaviour and the only part worth pinning here.
#
# Driven through the SHARED mechanism rather than through the picker: any VISIBLE node in
# `MenuNav.SCREEN_CLAIMER_GROUP` counts, and that is what every modal joins (MenuPage per page, the
# picker, and this map for its own full map). So a bare Control stands in for the picker, this test
# does not import it, and it stays true for modals not yet written.
func test_the_minimap_hides_while_another_modal_claims_the_screen() -> void:
	var map := _map()
	assert_false(map._other_claimer(),
		"nothing is claiming the screen while driving — else this proves nothing")

	var modal := Control.new()
	add_child_autofree(modal)
	modal.add_to_group(MenuNav.SCREEN_CLAIMER_GROUP)
	assert_true(map._other_claimer(),
		"a visible screen claimer (the car picker, a rally card) hides the minimap")

	# An INVISIBLE claimer does not count — `MenuNav.screen_claimer` skips those, which is how the
	# rally card closes (hidden, not freed), so the minimap must come back for it.
	modal.visible = false
	assert_false(map._other_claimer(),
		"a hidden claimer releases the minimap again")
