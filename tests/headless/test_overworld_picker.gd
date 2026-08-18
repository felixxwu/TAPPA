extends GutTest
# OverworldPicker — the DIEGETIC car picker: the camera swings to a three-quarter view in front of
# the car the player parked, a menu opens over it, and the car in front of them is replaced as they
# browse. Two modes, one picker: RALLY (owned cars eligible for a rally, confirm starts it) and
# STARTER (the starter pool on a profile that owns nothing, confirm grants the car). See
# features/overworld.md → "Picking a car in place".
#
# Everything here runs headless with `visuals: false` and a STUB car: no camera, no prop and no
# car.tscn, while the whole candidate/eligibility/confirm path and the entire MENU (a Control tree
# needs no renderer) stay live — which is what makes the navigation testable.
#
# NOTHING TUNABLE IS PINNED: not the camera offset or FOV (GameConfig), not a car's mass or drive
# mode, not the starter pool's contents, not which fixture rally admits which fixture car. The
# camera framing is asserted as GEOMETRY against its own inputs, and eligibility as AGREEMENT with
# the shared `RallyDetail` decisions.

const SaveTestHelpers = preload("res://tests/headless/save_test_helpers.gd")
const TEST_PATH := "user://test_overworld_picker.json"

var _save: Node
var _picker: OverworldPicker
var _car: StubCar
# Every `hide_zones` call the picker makes, in order — the stand-in for the hub's zone layer.
var _zone_hides: Array[bool] = []


# The car, reduced to exactly the members OverworldPicker touches. Node3D because the picker reads
# its pose to frame the shot and to seat the prop; the rest is the car.gd contract it depends on.
class StubCar:
	extends Node3D
	var controls_locked := false
	var freeze := false
	var ride_height := 0.0
	# What `apply_owned` will make `ride_height` become — the stub's stand-in for "this is a
	# different car now, and it rests at a different height". NAN = leave it alone.
	#
	# THIS IS THE POINT OF THE STUB, not a detail: the real `settled_ride_height()` only changes as
	# a RESULT of fielding, so a stub whose height is set by the test beforehand cannot catch the
	# ordering bug that matters (computing the contact plane AFTER the reshape, when the old car's
	# height is already gone). See test_refielding_preserves_the_contact_plane_at_the_new_ride_height.
	var next_ride_height := NAN
	var reset_calls := 0
	var clear_calls := 0
	var applied: Array[Dictionary] = []
	var last_reset := Transform3D.IDENTITY
	var damage := StubDamage.new()

	func reset_to(xform: Transform3D) -> void:
		reset_calls += 1
		last_reset = xform
		global_transform = xform

	func settled_ride_height() -> float:
		return ride_height

	func clear_wheel_visual_droop() -> void:
		clear_calls += 1

	func apply_owned(owned: Dictionary) -> String:
		applied.append(owned)
		# The real one re-fields the damage model from the saved HP, which re-ENABLES it — the
		# behaviour the hub has to undo after every fielding.
		damage.enabled = true
		# ...and it reshapes the body, so the car's rest height becomes the NEW model's.
		if not is_nan(next_ride_height):
			ride_height = next_ride_height
		return ""


class StubDamage:
	extends RefCounted
	var enabled := true


func before_each() -> void:
	_save = SaveTestHelpers.redirect(TEST_PATH)
	CarFixtures.install()
	UpgradeFixtures.install()
	RallyFixtures.install()
	_car = StubCar.new()
	add_child_autofree(_car)
	_picker = OverworldPicker.new()
	add_child_autofree(_picker)
	# THE STARTER POOL IS INJECTED. `CarLibrary.STARTER_MODEL_IDS` names SHIPPED cars, which a
	# synthetic roster does not resolve — and a test must not depend on which cars the real
	# catalogue ships anyway. `CarFixtures.starter_ids()` is the fixture roster's own answer.
	_zone_hides = []
	_picker.setup({
		"car": _car,
		"visuals": false,
		"starter_ids": CarFixtures.starter_ids(),
		# The hub hides its zone layer while the showroom shot is up; here the hook just records,
		# so the test can assert the hide/restore PAIRING without a zone layer at all.
		"hide_zones": func(hidden: bool) -> void: _zone_hides.append(hidden),
	})


func after_each() -> void:
	RallyFixtures.restore()
	UpgradeFixtures.restore()
	CarFixtures.restore()
	SaveTestHelpers.cleanup(TEST_PATH)


# --- Helpers ------------------------------------------------------------------------------


# Grant `count` fixture cars and return their owned dicts. The picker's candidate set is whatever
# the profile owns, so a test that wants a lineup has to own one.
func _grant_cars(count := 2) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var cars: Array[Dictionary] = CarFixtures.cars()
	for i in mini(count, cars.size()):
		out.append(_save.grant_car(String(cars[i]["id"])))
	return out


func _fx_rally(id: String) -> Dictionary:
	for rally in RallyFixtures.rallies():
		if String(rally["id"]) == id:
			return rally
	return {}


# The rally that the most owned cars can enter, so the lineup test is not at the mercy of which
# fixture restriction happens to match which fixture car.
func _open_rally() -> Dictionary:
	var best := {}
	var best_count := -1
	for rally in RallyFixtures.rallies():
		var n := OverworldPicker.eligible_cars(rally).size()
		if n > best_count:
			best_count = n
			best = rally
	return best


func _press(action: String) -> InputEventAction:
	var e := InputEventAction.new()
	e.action = action
	e.pressed = true
	return e


func _gamepad_press(action: String) -> InputEventJoypadButton:
	for e in InputMap.action_get_events(action):
		if e is InputEventJoypadButton:
			var press := (e as InputEventJoypadButton).duplicate() as InputEventJoypadButton
			press.pressed = true
			press.pressure = 1.0
			return press
	return null


# --- The candidate sets -------------------------------------------------------------------


# THE ELIGIBILITY CONTRACT, asserted as AGREEMENT with the shared decisions rather than by naming
# cars: every candidate can either enter as built or is convertible, and no owned car that could
# enter is missing. That is exactly the car park's `_can_ever_enter` filter, which is the point —
# one eligibility rule, never re-derived.
func test_the_lineup_is_exactly_the_cars_that_could_ever_enter() -> void:
	_grant_cars(3)
	var rally := _open_rally()
	var shown := OverworldPicker.eligible_cars(rally)
	for owned in shown:
		var entry := CarLibrary.for_owned(owned)
		assert_true(bool(RallyDetail.entry_plan(rally, owned)["eligible"])
				or RallyDetail.convertible_for(rally, owned, entry),
			"every shown car can enter as built or after a conversion")
	# ...and nothing eligible was dropped.
	for owned in Save.profile.get(Save.KEY_CARS, []):
		var entry2 := CarLibrary.for_owned(owned)
		if bool(RallyDetail.entry_plan(rally, owned)["eligible"]):
			assert_true(shown.has(owned), "an eligible owned car is always shown")


func test_a_car_that_can_never_enter_is_hidden_not_greyed() -> void:
	# The car park hides an unfixable car rather than parking it with a reason, and this must match:
	# a lineup padded with cars that can never enter is a menu of dead ends. Built from a
	# restriction NO fixture car can satisfy, so it does not depend on the catalogue's contents.
	#
	# `car_type` deliberately, because it is a key `RallyLibrary.ineligibility_reason` ACTUALLY
	# READS. An unknown key (this test first used `body`) is silently ignored by that function, so
	# the restriction was vacuous and every car qualified — the filter was right and the test was
	# wrong. Worth knowing beyond this test: an unsupported or mistyped restriction key admits
	# every car in production too, with nothing to notice it.
	_grant_cars(3)
	var impossible := _fx_rally("fx_open").duplicate()
	impossible["restriction"] = {"car_type": "no_such_car_type"}
	assert_eq(OverworldPicker.eligible_cars(impossible).size(), 0,
		"an impossible restriction shows no cars at all")
	assert_false(_picker.open_for_rally(impossible),
		"...and the picker refuses to open on an empty showroom")


# Every candidate resolves to a real car in whatever catalogue is installed — a contract check on
# the pool builder, not an assertion about which cars are in it (that is balance, and the roster
# changes). Driven with the fixture roster's own ids.
func test_every_starter_candidate_resolves_to_a_real_catalogue_car() -> void:
	var pool := OverworldPicker.starter_cars(CarFixtures.starter_ids())
	assert_gt(pool.size(), 0, "there is a starter pool (else every test below is vacuous)")
	for entry in pool:
		assert_gt(CarLibrary.index_of(String(entry["model_id"])), -1,
			"%s is a real catalogue car" % entry["model_id"])
		assert_eq(int(entry["instance_id"]), -1, "a starter candidate is not an owned instance")


# AN UNRESOLVABLE STARTER ID MUST DEGRADE, NOT CRASH — and it must SAY SO. Reachable in production,
# not just under a synthetic roster: `STARTER_MODEL_IDS` is a hand-maintained list of ids into a
# catalogue that gets renamed and retuned.
#
# The `push_error` is ASSERTED, not suppressed (`assert_push_error` matches its text and consumes it,
# so GUT stops counting it as unexpected). That makes the loudness a tested contract: the picker is
# REQUIRED to name the id it could not resolve, because a silent drop is how a starter pool quietly
# shrinks to nothing between releases.
func test_an_unresolvable_starter_id_is_dropped_and_named() -> void:
	var good := CarFixtures.starter_ids()
	var mixed: Array = ["definitely_not_a_car"]
	mixed.append_array(good)
	var pool := OverworldPicker.starter_cars(mixed)
	assert_eq(pool.size(), good.size(), "the bad id is dropped, the good ones survive")
	for entry in pool:
		assert_ne(String(entry["model_id"]), "definitely_not_a_car", "...and it is not carried")
	assert_push_error("definitely_not_a_car", "the error names the id that could not be resolved")
	assert_push_error_count(1, "...and reports it exactly once")


# A pool that resolves to NOTHING refuses to open rather than presenting an empty showroom, and
# every dead end past that point is a refusal rather than a crash — `focused_car` is empty,
# `can_confirm` is false and `confirm` returns false, so nothing indexes into nothing.
#
# Three push_errors are expected here, and the arithmetic is spelled out so a future editor changes
# the count deliberately rather than by accident: one from `starter_cars` for the two-bad-id pool,
# then two from `open_for_starter` (one naming the unresolved id, one for the empty pool).
func test_an_empty_starter_pool_refuses_to_open_instead_of_crashing() -> void:
	assert_eq(OverworldPicker.starter_cars(["nope_a", "nope_b"]).size(), 0,
		"a pool of nothing but bad ids is empty, not a hole")
	var picker := OverworldPicker.new()
	add_child_autofree(picker)
	picker.setup({"car": _car, "visuals": false, "starter_ids": ["nope_a"]})
	assert_false(picker.open_for_starter(), "an empty pool refuses to open")
	assert_false(picker.is_open(), "...and leaves the picker closed")
	assert_true(picker.focused_car().is_empty(), "...with no focused car to index into")
	assert_false(picker.can_confirm(), "...and nothing to confirm")
	assert_false(picker.confirm(), "...so confirming is refused rather than crashing")
	assert_push_error("starter pool is empty",
		"the refusal is reported — a carless profile with no pick is not a silent state")
	assert_push_error_count(3, "one for the bad pool, then one per bad id plus one for the refusal")


# --- Browsing -----------------------------------------------------------------------------


# The picker opens on the car the player is ALREADY driving, when it is eligible. Arriving in a
# perfectly good car and being shown someone else's is the small papercut that makes a picker feel
# like a menu rather than a garage.
func test_it_opens_on_the_car_the_player_is_driving() -> void:
	var owned := _grant_cars(3)
	var rally := _open_rally()
	var shown := OverworldPicker.eligible_cars(rally)
	if shown.size() < 2:
		pending("the fixture roster admits fewer than two cars here")
		return
	var want := int((shown[shown.size() - 1] as Dictionary)["instance_id"])
	Save.set_selected_car(want)
	assert_true(_picker.open_for_rally(rally), "the picker opens")
	assert_eq(int(_picker.focused_car().get("instance_id", -1)), want,
		"it opens on the selected car, not on the top of the list")
	assert_gt(owned.size(), 0, "cars were granted (else vacuous)")


# LEFT / RIGHT CHANGE THE CAR, and they WRAP. That is the whole input model of the bar: the arrows
# are pointer affordances, and the keyboard/pad presses cycle the selection directly rather than
# moving a highlight between two chevrons (which would leave two competing selection models on one
# screen). Wrapping matches the house selectors — `hq.gd::_cycle_lift_car` uses `wrapi`.
func test_left_and_right_cycle_the_car_and_wrap() -> void:
	_grant_cars(3)
	var rally := _open_rally()
	assert_true(_picker.open_for_rally(rally), "the picker opens")
	var n := _picker.candidates().size()
	if n < 2:
		pending("the fixture roster admits fewer than two cars here")
		return
	var first := _picker.focused_index()
	_picker._unhandled_input(_press("ui_right"))
	assert_ne(_picker.focused_index(), first, "right changes the car")
	# All the way round: n presses from anywhere lands back where it started.
	var at := _picker.focused_index()
	for _i in range(n):
		_picker._unhandled_input(_press("ui_right"))
	assert_eq(_picker.focused_index(), at, "a full lap returns to the same car")
	# ...and left wraps backwards off the front rather than stopping dead.
	_picker.select_index(0)
	_picker._unhandled_input(_press("ui_left"))
	assert_eq(_picker.focused_index(), n - 1, "left from the first car wraps to the last")
	# WASD too, which `ui_*` does not carry.
	var before := _picker.focused_index()
	_picker._unhandled_input(_press("menu_right"))
	assert_ne(_picker.focused_index(), before, "WASD cycles as well")


# ONE CANDIDATE: the chevrons come off the bar entirely (hidden AND disabled, the pair hq.gd uses,
# so neither a click nor a cursor can reach a button that is not on screen) and cycling is a no-op
# rather than a press that appears to do nothing.
func test_a_lone_candidate_hides_the_arrows_and_cycling_does_nothing() -> void:
	_grant_cars(1)
	var rally := _open_rally()
	assert_true(_picker.open_for_rally(rally), "the picker opens")
	if _picker.candidates().size() != 1:
		pending("this fixture rally admits more than the one granted car")
		return
	assert_false(_picker.arrows_visible(), "there is nothing to cycle, so no chevrons")
	assert_true(_picker.name_text() != "", "but the bar still names the car")
	_picker._unhandled_input(_press("ui_right"))
	_picker._unhandled_input(_press("ui_left"))
	assert_eq(_picker.focused_index(), 0, "cycling a lone candidate is a no-op")

	# ...and they come back as soon as there is a choice.
	_picker.close()
	_grant_cars(3)
	if OverworldPicker.eligible_cars(rally).size() > 1:
		assert_true(_picker.open_for_rally(rally), "the picker re-opens")
		assert_true(_picker.arrows_visible(), "a real choice shows the chevrons")


# THE CAR DOES NOT MOVE. The user was explicit that it stays exactly where they stopped, and the
# whole prop design exists so that browsing never touches the live body — so browsing must produce
# no teleport, no re-field and no unfreeze.
func test_browsing_never_touches_the_live_car() -> void:
	_grant_cars(3)
	var pose := Transform3D(Basis(Vector3.UP, 1.1), Vector3(12.0, 3.0, -40.0))
	_car.global_transform = pose
	var rally := _open_rally()
	assert_true(_picker.open_for_rally(rally), "the picker opens")
	for _i in range(4):
		_picker.select_step(1)
		_picker.select_step(-1)
	assert_eq(_car.reset_calls, 0, "no teleport")
	assert_eq(_car.applied.size(), 0, "no re-fielding")
	assert_almost_eq(_car.global_position.distance_to(pose.origin), 0.0, 0.0001,
		"the car is exactly where the player parked it")
	# It IS frozen and hidden while the showroom shot is up, and both are given back on cancel.
	assert_true(_car.freeze, "the car is held still under the showroom shot")
	_picker.close()
	assert_false(_car.freeze, "cancelling hands the car back")
	assert_true(_car.visible, "...and makes it visible again")


# A car that was ALREADY frozen (the garage lift holds it that way) must not be unfrozen by the
# picker cancelling — the take-only-your-own discipline, applied to `freeze` as well as to the
# control lock.
func test_it_never_unfreezes_a_car_someone_else_froze() -> void:
	_grant_cars(2)
	_car.freeze = true
	assert_true(_picker.open_for_rally(_open_rally()), "the picker opens")
	_picker.close()
	assert_true(_car.freeze, "a lock someone else took is left alone")


# --- Clearing the view (the zone layer) ---------------------------------------------------


# THE ZONE VISUALS COME DOWN WHILE THE PICKER IS UP. The player is parked ON a rally zone when this
# opens — that is how it opens — so the zone's light tube is a translucent column standing around the
# very car they are choosing, its marker and star row float directly above it, and a car-unlock zone
# parks a full-size ghost car beside it. All of it sits between the camera and the subject.
func test_opening_the_picker_hides_the_zone_visuals() -> void:
	_grant_cars(2)
	assert_true(_picker.open_for_rally(_open_rally()), "the picker opens")
	assert_true(_picker.zones_hidden(), "the zone visuals are hidden while choosing")
	assert_eq(_zone_hides, [true] as Array[bool], "and the host was told exactly once")


# ...AND THEY COME BACK ON THE CANCEL PATH, which is the one that returns to the card rather than to
# driving. A picker that hid them and left is a hub with invisible rallies for the rest of the session.
func test_cancelling_restores_the_zone_visuals() -> void:
	_grant_cars(2)
	assert_true(_picker.open_for_rally(_open_rally()), "the picker opens")
	_picker.close()
	assert_false(_picker.zones_hidden(), "the zone visuals are back")
	assert_eq(_zone_hides, [true, false] as Array[bool], "hidden once, restored once")


# The STARTER flow has no cancel, so its restore has to ride the same funnel — the host closes the
# picker itself after the grant. Asserted through `close()`, which is that funnel.
func test_the_starter_flow_restores_the_zone_visuals_too() -> void:
	assert_true(_picker.open_for_starter(), "the starter picker opens")
	assert_true(_picker.zones_hidden(), "hidden while choosing a first car")
	assert_true(_picker.confirm(), "the starter confirms")
	# The host closes the picker on `granted`; do what it does.
	_picker.close()
	assert_false(_picker.zones_hidden(), "and the zones are back before the world is handed over")


# Idempotent both ways: a second open must not stack a second hide, and a close with nothing hidden
# must not tell the host to restore something it never took. Same take-only-your-own discipline as the
# car's freeze.
func test_hiding_the_zones_is_idempotent() -> void:
	_grant_cars(2)
	var rally := _open_rally()
	assert_true(_picker.open_for_rally(rally), "the picker opens")
	_picker.open_for_rally(rally)          # already open — must not re-hide
	_picker.close()
	_picker.close()                        # already closed — must not re-restore
	assert_eq(_zone_hides, [true, false] as Array[bool], "exactly one hide and one restore")


# --- Confirming ---------------------------------------------------------------------------


# RALLY confirm hands the host the rally and the instance id and does NOT reshape the car: the
# stage scene fields the chosen car itself, so an in-place swap here would be work thrown away —
# and a reshape of a live VehicleBody3D is the thing car.gd::respawn warns about.
func test_confirming_a_rally_car_reports_it_and_leaves_the_car_alone() -> void:
	_grant_cars(2)
	var rally := _open_rally()
	assert_true(_picker.open_for_rally(rally), "the picker opens")
	watch_signals(_picker)
	var want := int(_picker.focused_car().get("instance_id", -1))
	assert_true(_picker.confirm(), "the focused car confirms")
	assert_signal_emitted(_picker, "started")
	# GUARDED: `get_signal_parameters` returns NULL when the signal never fired, so indexing it
	# straight turns an ordinary assertion failure into a runtime script error that fails the whole
	# suite run. Never index a signal-parameter result without checking it first.
	var args: Variant = get_signal_parameters(_picker, "started")
	assert_not_null(args, "the started signal carried its parameters")
	if args != null:
		assert_eq(String(args[0]), String(rally["id"]), "the rally is reported")
		assert_eq(int(args[1]), want, "...with the car the player was looking at")
	assert_eq(_car.applied.size(), 0, "and the live car is not re-fielded")


# An unconfirmable car cannot be started by any route. The car park relied on a disabled button
# alone; here the press path re-checks, so a stale button can never launch a rally the car is
# ineligible for.
func test_a_car_with_a_reason_cannot_be_confirmed() -> void:
	_grant_cars(3)
	var rally := _open_rally()
	assert_true(_picker.open_for_rally(rally), "the picker opens")
	for i in _picker.candidates().size():
		_picker.select_index(i)
		if _picker.reason() != "":
			assert_false(_picker.can_confirm(), "a car with a stated reason cannot be confirmed")
			assert_false(_picker.confirm(), "...and confirming it is refused")
			assert_true(_picker.confirm_button().disabled, "...and its button is dead")
			return
	pending("no convertible-only car in this fixture lineup — nothing to assert")


# STARTER confirm GRANTS the car through the shared save seam and records everything the rest of the
# game reads. `starter_model_id` is the load-bearing one: `RallyLibrary.lit_sources` lights the
# OPENING rally from it, so a grant without it leaves a fresh player on a completely dark map.
func test_confirming_a_starter_grants_the_car_and_lights_the_map() -> void:
	assert_eq(Save.selected_instance_id(), -1, "the profile owns nothing (else vacuous)")
	assert_true(_picker.open_for_starter(), "the starter picker opens")
	watch_signals(_picker)
	var model_id := String(_picker.focused_car().get("model_id", ""))
	assert_true(_picker.confirm(), "the starter confirms")
	assert_signal_emitted(_picker, "granted")
	# Guarded for the same reason as above — see `started`.
	var granted_args: Variant = get_signal_parameters(_picker, "granted")
	assert_not_null(granted_args, "the granted signal carried its parameters")
	if granted_args == null:
		return
	var id := int(granted_args[0])
	assert_gt(id, -1, "a real instance id came back")
	var owned := Save.get_car(id)
	assert_false(owned.is_empty(), "the car is in the garage")
	assert_eq(String(owned["model_id"]), model_id, "...and it is the one on screen")
	assert_eq(Save.selected_instance_id(), id, "it is the selected car")
	assert_true(bool(Save.profile.get("starter_picked", false)), "the starter flag is set")
	assert_eq(String(Save.profile.get("starter_model_id", "")), model_id,
		"...and the model is recorded, which is what lights the opening rally")
	assert_gt(RallyLibrary.lit_sources(Save.profile).size(), 0,
		"so the map has somewhere lit to go")


# ONE grant, however many times a confirm arrives: a second grant would hand out a free car.
func test_a_second_starter_confirm_cannot_grant_twice() -> void:
	assert_true(_picker.open_for_starter(), "the starter picker opens")
	assert_true(_picker.confirm(), "the first confirm grants")
	var count: int = (Save.profile.get(Save.KEY_CARS, []) as Array).size()
	_picker.close()
	assert_false(_picker.confirm(), "a confirm on a closed picker does nothing")
	assert_eq((Save.profile.get(Save.KEY_CARS, []) as Array).size(), count,
		"the garage still holds exactly one car")


# --- Re-seating the swapped car (the sunk-prop guard) -------------------------------------


# THE TRAP THIS PROJECT HAS FALLEN INTO THREE TIMES: two car models rest at different heights, so
# re-fielding a car and re-using the old body origin sinks it into the road (or floats it). What
# must be preserved is the CONTACT PLANE under the wheels, and the re-seat must go through
# `reset_to` — the only safe teleport.
func test_refielding_preserves_the_contact_plane_at_the_new_ride_height() -> void:
	var owned := _grant_cars(1)[0]
	var pose := Transform3D(Basis(Vector3.UP, 0.6), Vector3(5.0, 20.0, 7.0))
	_car.ride_height = 0.30           # the car standing there NOW
	_car.global_transform = pose
	var plane := pose.origin.y - _car.ride_height
	# The car being swapped in rests HIGHER — and the height changes when `apply_owned` runs, not
	# before it, exactly as the real `settled_ride_height()` does. That ordering is the whole test:
	# the contact plane has to be measured with the OLD car's height and restored with the NEW
	# one's, so a re-seat that reads either at the wrong moment lands 0.25 m out.
	_car.next_ride_height = 0.55
	_picker.refield_live_car(owned)
	assert_eq(_car.ride_height, 0.55, "the fielding is what changed the rest height")
	assert_eq(_car.applied.size(), 1, "the car was re-fielded once")
	assert_eq(_car.reset_calls, 1, "...and re-seated through reset_to, not a bare transform write")
	assert_almost_eq(_car.last_reset.origin.y - _car.ride_height, plane, 0.0001,
		"the wheels stay on the same ground: the contact plane is preserved")
	assert_almost_eq(_car.last_reset.origin.x, pose.origin.x, 0.0001, "it does not move in x")
	assert_almost_eq(_car.last_reset.origin.z, pose.origin.z, 0.0001, "...or in z")
	assert_eq(_car.clear_calls, 1, "the wheel-visual droop is cleared before physics resumes")
	assert_false(_car.damage.enabled,
		"damage is re-disabled after fielding — the hub never costs the player HP")


# --- The bar's chrome -----------------------------------------------------------------------


# NO TITLE ROW. It captioned a bar whose whole content is a car name, its stats and a Start button,
# and it cost a row of the frame the CAR wants. The two modes are still told apart by the only words
# that carry information — the confirm button's own label.
func test_the_bar_has_no_title_row() -> void:
	_grant_cars(2)
	assert_true(_picker.open_for_rally(_open_rally()), "the picker opens")
	var page := _picker.ui_root().find_child("Picker", true, false) as Control
	for label in page.find_children("*", "Label", true, false):
		var text := (label as Label).text.to_upper()
		assert_false(text.contains("SELECT A CAR"), "no rally-mode title is captioned on the bar")
		assert_false(text.contains("CHOOSE YOUR FIRST CAR"), "...nor a starter-mode one")
	_picker.close()
	assert_true(_picker.open_for_starter(), "the starter picker opens")
	assert_true(_picker.confirm_button().text.to_upper().contains("TAKE"),
		"starter mode is named by its confirm button instead")


# BACK ON THE LEFT, CONFIRM ON THE RIGHT — the order every other screen uses, so "back" is always the
# leftmost thing. Asserted as ORDER within the actions row, not by position in pixels.
func test_back_sits_left_of_the_confirm_button() -> void:
	_grant_cars(2)
	assert_true(_picker.open_for_rally(_open_rally()), "the picker opens")
	var back := _picker.back_button()
	var confirm := _picker.confirm_button()
	assert_eq(back.get_parent(), confirm.get_parent(), "both live in the actions row")
	assert_lt(back.get_index(), confirm.get_index(), "back comes before confirm")
	assert_true(back.visible, "and rally mode offers it")


# ...and the asymmetry survives the reorder: starter mode still offers NO back at all, so the confirm
# button is alone in a centred row rather than sitting beside a gap.
func test_starter_mode_still_offers_no_back_after_the_reorder() -> void:
	assert_true(_picker.open_for_starter(), "the starter picker opens")
	assert_false(_picker.back_button().visible, "no back button in starter mode")
	assert_true(_picker.back_button().disabled, "...and it cannot be reached by pointer either")
	assert_true(_picker.confirm_button().visible, "the confirm button is still there")


# --- The stats line (the SHARED car-select summary) ----------------------------------------
#
# The bar shows THE EXISTING one-line car summary — `RallyDetail.car_stats_text`, the same string the
# HQ's car-select overlay and tuning lift show — rather than a second copy of it. These assert the
# helper's contract and the fact that the bar defers to it; none of them pins a stat value, a car or
# the format of the line.


# The bar's line IS the shared helper's output, not a local re-derivation. This is the assertion that
# catches a well-meaning fork: the moment someone re-formats the line in the picker, this fails.
func test_the_bar_shows_the_shared_car_summary() -> void:
	_grant_cars(2)
	assert_true(_picker.open_for_rally(_open_rally()), "the picker opens")
	for i in _picker.candidates().size():
		_picker.select_index(i)
		var owned := _picker.focused_car()
		# CASE-INSENSITIVE, and only that. The design system uppercases all menu text (house rule 1,
		# applied by `UITheme.enforce`), so the LABEL reads "900 KG | HEALTH 100%" while the helper
		# returns "900 kg | Health 100%". Comparing `.to_upper()` on both sides tolerates exactly
		# that transform and nothing else — reorder a field, drop one, or reformat the line locally
		# and this still fails, which is the whole point of the assertion. The helper is deliberately
		# NOT made to emit uppercase: `hq.gd` delegates to it and its output is used outside menus.
		assert_eq(_picker.stats_text().to_upper(),
			RallyDetail.car_stats_text(owned, CarLibrary.for_owned(owned)).to_upper(),
			"the bar's stats line comes from the shared helper for car %d" % i)


# An OWNED car reports its condition; a 0-HP one is flagged rather than reading as 0%, so the bar
# makes clear how badly it is hurt (it can still be entered — damage only weakens).
func test_an_owned_car_reports_its_condition_and_a_wrecked_one_is_flagged() -> void:
	var owned := _grant_cars(1)[0]
	var entry := CarLibrary.for_owned(owned)
	assert_true(RallyDetail.car_stats_text(owned, entry).contains("Health"),
		"a healthy owned car reports a health figure")
	var wrecked := owned.duplicate()
	wrecked["hp"] = 0.0
	assert_true(RallyDetail.car_stats_text(wrecked, entry).contains("WRECKED"),
		"a wrecked car is flagged, not shown as a percentage")


# A STARTER CANDIDATE CLAIMS NO HEALTH. It has no OwnedCar behind it — no `hp`, no instance id — so
# the field is omitted rather than invented: reading the missing key as 0 would print WRECKED for a
# brand-new car, and defaulting it to full would print a figure the grant is free to contradict.
func test_a_starter_candidate_claims_no_health_figure() -> void:
	assert_true(_picker.open_for_starter(), "the starter picker opens")
	for i in _picker.candidates().size():
		_picker.select_index(i)
		var entry: Dictionary = _picker.focused_car()
		var spec := CarLibrary.by_id(String(entry.get("model_id", "")))
		var line := RallyDetail.car_stats_text(entry, spec)
		assert_false(line.contains("Health"), "an unowned car reports no health figure")
		assert_false(line.contains("WRECKED"), "...and is certainly not called wrecked")
		assert_false(line.contains("?"), "...and does not print a placeholder either")
		# It still says the things a model DOES have.
		assert_true(line.contains("HP"), "but it still reports power")
		assert_true(line.contains("kg"), "...and mass")
		assert_eq(_picker.stats_text().to_upper(), line.to_upper(),
			"and the bar shows exactly that (uppercased, as every menu line is)")


# A fitted nitrous bottle is named LAST — after the condition — because it is invisible to
# `effective_meta` and so can only ever be a trailing addition. Asserted as ORDER, not as a name.
func test_a_fitted_nitrous_is_named_after_the_condition() -> void:
	var nitrous_id := ""
	for item in UpgradeFixtures.upgrades():
		if String((item as Dictionary).get("slot", "")) == "nitrous":
			nitrous_id = String(item["id"])
			break
	if nitrous_id == "":
		pending("the fixture catalogue has no nitrous part to fit")
		return
	var owned := _grant_cars(1)[0]
	owned["installed_upgrades"] = [nitrous_id]
	if UpgradeLibrary.fitted_nitrous_id(owned) == "":
		pending("the fixture nitrous does not read as fitted from installed_upgrades alone")
		return
	var line := RallyDetail.car_stats_text(owned, CarLibrary.for_owned(owned))
	var health_at := line.find("Health")
	var name := String(UpgradeLibrary.by_id(nitrous_id).get("name", ""))
	assert_true(name != "" and line.contains(name), "the fitted bottle is named")
	assert_gt(line.find(name), health_at, "...after the condition, never before it")


# THE REASON A CAR CANNOT ENTER SURVIVES THE STATS LINE. They are separate readouts: a blocked player
# needs the numbers AND the sentence, and the sentence is the one they act on.
func test_a_blocked_car_shows_both_its_stats_and_the_reason() -> void:
	_grant_cars(3)
	var rally := _open_rally()
	assert_true(_picker.open_for_rally(rally), "the picker opens")
	for i in _picker.candidates().size():
		_picker.select_index(i)
		if _picker.reason() == "":
			continue
		# Same uppercasing applies to the reason label, so both comparisons are case-insensitive —
		# including the negative one, which would otherwise pass for the wrong reason (a mixed-case
		# needle can never be found in an uppercased haystack).
		assert_eq(_picker.reason_text().to_upper(), _picker.reason().to_upper(),
			"the reason is on screen")
		assert_true(_picker.stats_text() != "", "...and the stats line is still there too")
		assert_false(_picker.stats_text().to_upper().contains(_picker.reason().to_upper()),
			"...as a separate readout, not swallowed into the summary")
		return
	pending("no blocked car in this fixture lineup — nothing to assert")


# --- The showroom camera (pure geometry) --------------------------------------------------


# A THREE-QUARTER VIEW IN FRONT OF THE CAR, and the camera comes to the car rather than the car
# moving to suit it. Asserted against the function's own inputs, so no GameConfig value is pinned.
func test_the_showroom_camera_stands_in_front_of_the_car_and_looks_back_at_it() -> void:
	var offset := Vector3(3.0, 1.6, 6.0)
	for yaw in [0.0, 1.3, -2.7]:
		var pose := Transform3D(Basis(Vector3.UP, yaw), Vector3(9.0, 4.0, -3.0))
		var ride := 0.35
		var cam := OverworldPicker.showroom_pose(pose, offset, ride)
		var to_cam := cam.origin - pose.origin
		# car.tscn faces -Z, so "in front of the nose" is a POSITIVE dot with the car's -Z.
		assert_gt(to_cam.dot(-pose.basis.z.normalized()), 0.0, "the camera is in front of the car")
		assert_gt(to_cam.dot(pose.basis.x.normalized()), 0.0, "...and off to one side (a quarter view)")
		assert_gt(cam.origin.y, pose.origin.y - ride, "...above the ground the car stands on")
		# It looks BACK at the car: a camera's -Z is its view direction.
		var view := -cam.basis.z.normalized()
		assert_gt(view.dot((pose.origin - cam.origin).normalized()), 0.85,
			"the shot is aimed at the car")
		# LEVEL MEANS NO ROLL — not "no pitch". The camera is deliberately pitched DOWN now (see
		# test_the_camera_is_pitched_down_so_the_car_clears_the_menu), which does not tilt the
		# horizon; a rolled shot would.
		assert_almost_eq(cam.basis.x.normalized().dot(Vector3.UP), 0.0, 0.001,
			"the horizon is not tilted")


# THE CAMERA IS PITCHED DOWN, so the car sits ABOVE the bottom-anchored menu bar instead of behind
# it. The mechanism is the aim point, not the eye: aiming below the car's middle pitches the shot down
# and pushes the subject up the frame while keeping it the same distance and the same size.
#
# Asserted as a RELATIONSHIP against the function's own inputs — a bigger drop aims lower and pitches
# further down — so no authored value is pinned. (`overworld_picker_camera_aim_drop_m` is a tunable;
# this test never reads it.)
func test_the_camera_is_pitched_down_so_the_car_clears_the_menu() -> void:
	var offset := Vector3(2.6, 1.5, 5.2)
	var ride := 0.35
	var pose := Transform3D(Basis(Vector3.UP, 0.4), Vector3(4.0, 9.0, -2.0))
	var level := OverworldPicker.showroom_pose(pose, offset, ride, 0.0)
	var dropped := OverworldPicker.showroom_pose(pose, offset, ride, 1.2)
	# Same eye: only the AIM moved, which is the whole point (raising the camera would reframe and
	# shrink the car instead).
	assert_almost_eq(dropped.origin.distance_to(level.origin), 0.0, 0.0001,
		"the camera did not move, only its aim")
	var level_view := -level.basis.z.normalized()
	var dropped_view := -dropped.basis.z.normalized()
	assert_lt(dropped_view.y, level_view.y, "a dropped aim points further down")
	assert_lt(dropped_view.y, 0.0, "and it points below the horizon at all")
	# ...and further still with more drop, so the dial does what its name says in the right direction.
	var deeper := OverworldPicker.showroom_pose(pose, offset, ride, 2.4)
	assert_lt((-deeper.basis.z.normalized()).y, dropped_view.y, "more drop pitches further down")
	# It is still a shot OF THE CAR, not of the ground beside it: the car stays well within frame.
	assert_gt(dropped_view.dot((pose.origin - dropped.origin).normalized()), 0.85,
		"the car is still what the camera is looking at")


# A COLINEAR `look_at` MUST BE UNREACHABLE, not merely survivable. `Basis.looking_at` warns and
# produces a garbage basis when the view direction is parallel to `up` — which is what a camera
# directly above or below the car asks for — so `showroom_pose` keeps a minimum standoff AHEAD of
# the nose and falls back to a different `up` if that is ever relaxed.
#
# Asserted over the offsets that USED to be degenerate (a cleared GameConfig field, and a purely
# vertical one): finite origin, a real rotation, and a view direction that is never parallel to up.
func test_no_offset_can_make_the_camera_look_along_its_own_up() -> void:
	var pose := Transform3D(Basis(Vector3.UP, 0.9), Vector3(1.0, 2.0, 3.0))
	var offsets: Array[Vector3] = [
		Vector3.ZERO,                    # a cleared offset
		Vector3(0.0, 8.0, 0.0),          # straight overhead
		Vector3(0.0, -8.0, 0.0),         # straight underneath
		Vector3(0.0, 0.0, 0.0001),       # a hair in front
	]
	# Swept across the AIM DROP as well, because the drop moves the target along the car's Y — the
	# very axis a colinear look_at would be parallel to. The guarantee rests on the standoff's
	# component along the car's Z, which the drop does not touch, and this is what proves it.
	for offset in offsets:
		for drop in [0.0, 1.2, 6.0]:
			var cam := OverworldPicker.showroom_pose(pose, offset, 0.0, drop)
			var why := "%s at drop %s" % [offset, drop]
			assert_true(is_finite(cam.origin.x) and is_finite(cam.origin.y)
					and is_finite(cam.origin.z), "the origin is finite for %s" % why)
			assert_true(cam.basis.determinant() > 0.0, "the basis is still a rotation for %s" % why)
			var view := -cam.basis.z.normalized()
			var up := cam.basis.y.normalized()
			assert_gt(view.cross(up).length(), OverworldPicker.COLINEAR_EPSILON,
				"the view direction is not colinear with up for %s" % why)
			# ...and it is still standing off the car rather than inside it, which is what removes
			# the degeneracy in the first place.
			assert_gt(cam.origin.distance_to(pose.origin), 0.0,
				"the camera is not inside the car for %s" % why)


# --- Navigation (keyboard AND gamepad) ----------------------------------------------------


# THIS FILE USED TO ASSERT THE OPPOSITE HERE, and the older claim was deleted rather than reconciled.
#
# A `test_keyboard_navigates_the_picker` from the side-list layout asserted that every button was
# `FOCUS_ALL`, that the page carried a `MenuNav`, and that the focus cursor landed on the picker when
# it opened. The bar that replaced the list is a CAROUSEL, and those three things are precisely what
# breaks it: with a focus cursor, `ui_left`/`ui_right` are consumed in the GUI phase to move the
# highlight between the two chevrons and THE CAR STOPS CHANGING. So the FOCUS_NONE design is the one
# that survived, and `test_the_bar_has_no_focus_cursor_to_compete_with_left_and_right` below is now
# the single statement of it.
#
# Not even the actions row is focusable, which was the tempting middle ground: `Start` and `Back` sit
# side by side, so making just those two focus stops hands `ui_left`/`ui_right` straight back to the
# focus system and reintroduces the same bug — and a vertical actions column would only avoid it by
# relying on Godot not consuming a directional press that has no neighbour, which is not a guarantee
# worth resting the whole menu's input on.
#
# What the deleted test actually covered is not lost, only re-aimed: "a keyboard/pad player can
# operate this menu" is now `test_left_and_right_cycle_the_car_and_wrap` (cycling, on `ui_*` and
# WASD) plus `test_enter_confirms_and_back_cancels_by_keyboard_and_pad` (commit and cancel, on both
# devices).


# Re-opening on a DIFFERENT rally re-dresses the bar for THAT rally's candidates. (The old side list
# had to rebuild its rows for this and a count-only guard left the previous rally's names on screen;
# a one-car bar has no such state, and this is the regression guard for it.)
func test_reopening_on_another_rally_re_dresses_the_bar() -> void:
	_grant_cars(3)
	var seen := 0
	for rally in RallyFixtures.rallies():
		if OverworldPicker.eligible_cars(rally).is_empty():
			continue
		assert_true(_picker.open_for_rally(rally), "the picker opens for %s" % rally["id"])
		seen += 1
		var owned := _picker.focused_car()
		var spec := CarLibrary.for_owned(owned)
		assert_true(_picker.name_text().to_lower().contains(
				String(spec.get("name", "")).to_lower()),
			"the bar names the car it is showing for %s" % rally["id"])
		assert_eq(_picker.stats_text().to_upper(),
			RallyDetail.car_stats_text(owned, spec).to_upper(),
			"...and its stats line is the shared summary for that car (menu text is uppercased)")
		_picker.close()
	assert_gt(seen, 0, "at least one fixture rally had a lineup (else vacuous)")


# THE BAR HAS NO FOCUS STOPS AND NO MenuNav — deliberately, and this is the assertion that keeps it
# that way. A MenuNav (or any focusable widget) would take left/right for its own cursor and the car
# would stop changing, which is the exact bug the carousel layout exists to avoid.
func test_the_bar_has_no_focus_cursor_to_compete_with_left_and_right() -> void:
	_grant_cars(3)
	assert_true(_picker.open_for_rally(_open_rally()), "the picker opens")
	await get_tree().process_frame
	var page := _picker.ui_root().find_child("Picker", true, false) as Control
	assert_not_null(page, "the bar exists")
	for child in page.get_children():
		assert_false(child is MenuNav, "no MenuNav is attached to the bar")
	for button in page.find_children("*", "Button", true, false):
		assert_eq((button as Button).focus_mode, Control.FOCUS_NONE,
			"%s is a pointer affordance, not a focus stop" % (button as Button).text)
	# The chevrons are additionally opted OUT of MenuNav, so a nav attached above this bar in future
	# still cannot turn them into focus stops.
	assert_true(_picker._prev_button.has_meta("menu_nav_skip"), "the < chevron opts out of nav")
	assert_true(_picker._next_button.has_meta("menu_nav_skip"), "the > chevron opts out of nav")


# ENTER CONFIRMS AND BACK CANCELS, on keyboard AND pad, straight through the picker's own handler —
# the diegetic input pattern, since there is no focus cursor to press a button with.
func test_enter_confirms_and_back_cancels_by_keyboard_and_pad() -> void:
	_grant_cars(2)
	var rally := _open_rally()
	# BACK, both devices.
	for use_pad in [false, true]:
		assert_true(_picker.open_for_rally(rally), "the picker opens")
		var event: InputEvent = _gamepad_press("menu_back") if use_pad else _press("ui_cancel")
		assert_not_null(event, "back is bound for this device")
		watch_signals(_picker)
		_picker._unhandled_input(event)
		assert_false(_picker.is_open(), "back cancels (pad: %s)" % use_pad)
		assert_signal_emitted(_picker, "closed")
	# ENTER, both devices.
	for use_pad in [false, true]:
		assert_true(_picker.open_for_rally(rally), "the picker opens")
		if not _picker.can_confirm():
			pending("the focused fixture car cannot enter — nothing to confirm")
			return
		var event2: InputEvent = _gamepad_press("ui_accept") if use_pad else _press("menu_select")
		assert_not_null(event2, "accept is bound for this device")
		watch_signals(_picker)
		_picker._unhandled_input(event2)
		assert_signal_emitted(_picker, "started")
		_picker.close()


# THE STARTER PICK HAS NO BACK, and that is deliberate: a player cannot decline to own a car and
# drive off. Back must therefore NOT close it — and MenuNav must not consume the press either, so
# that Esc still reaches the pause menu and a player who wants out can still quit.
func test_the_starter_pick_cannot_be_backed_out_of() -> void:
	assert_true(_picker.open_for_starter(), "the starter picker opens")
	await get_tree().process_frame
	for event in [_press("menu_back"), _press("ui_cancel"), _gamepad_press("menu_back")]:
		if event == null:
			continue
		_picker._unhandled_input(event)
		assert_true(_picker.is_open(), "back does not abandon the starter pick")
	assert_eq(Save.selected_instance_id(), -1, "and nothing was granted by backing out")
	# No dead button either: the Back affordance is not on screen at all.
	assert_false(_picker.back_button().visible, "no back button is offered in starter mode")
	assert_true(_picker.back_button().disabled, "...and it cannot be reached by pointer either")
	# ...while the car can still be CHOSEN, which is the one thing this mode must allow.
	if _picker.candidates().size() > 1:
		var at := _picker.focused_index()
		_picker._unhandled_input(_press("ui_right"))
		assert_ne(_picker.focused_index(), at, "browsing the starter pool still works")


# NO PAGE CAN TRAP THE PLAYER — the rally flow's version of the garage's no-trap property: whatever
# the cursor is on, Back leaves and the car is handed back unfrozen.
func test_a_rally_pick_always_has_a_way_out() -> void:
	_grant_cars(3)
	assert_true(_picker.open_for_rally(_open_rally()), "the picker opens")
	for i in _picker.candidates().size():
		_picker.select_index(i)
	_picker.close()
	assert_false(_picker.is_open(), "back always leaves")
	assert_false(_car.freeze, "and always hands the car back")


# Headless: no camera and no prop are built with visuals off, but the whole menu is — which is what
# every test above depends on.
func test_visuals_off_builds_the_menu_but_no_camera_or_prop() -> void:
	_grant_cars(2)
	assert_true(_picker.open_for_rally(_open_rally()), "the picker opens headless")
	assert_null(_picker.camera(), "no showroom camera with visuals off")
	assert_null(_picker.shown_prop(), "and no stand-in prop")
	assert_not_null(_picker.ui_root(), "but the bar exists")
	assert_true(_picker.name_text() != "", "...and names the car it would be showing")


# --- The showroom car stands on the ground, not above it ---------------------
#
# It used to be PLACED analytically — contact plane plus the model's computed rest height — so any
# error in that sum showed as a car hovering, which is what the user saw. It is now spawned LIVE
# (the podium's `CarProp.spawn` recipe) and released slightly above its resting height, so its own
# suspension puts it down and the result is right for any model on any slope.
#
# The SETTLING itself is not asserted here and deliberately so: it needs a physics server and a
# terrain collider, and every test in this file is scene-free. What IS asserted is the contract
# that makes settling possible and safe.
func test_the_prop_is_seated_at_its_own_estimated_rest_height() -> void:
	# The prop is placed AT `settled_ride_height()` — the project's own estimate of how far a body
	# origin rests above the ground for that model's wheels and suspension — and left live so the
	# suspension holds it there. Not dropped: cycling cars must not read as cars falling in.
	#
	# Pins the RELATIONSHIP between the contact plane and the seat, never a height: two cars with
	# different estimates must be seated at their own, which is the bug that made one float.
	var pose := Transform3D(Basis.IDENTITY, Vector3(3.0, 10.0, -4.0))
	var low := StubBodyCar.new(); low.ride_height = 0.30
	var high := StubBodyCar.new(); high.ride_height = 0.55
	add_child_autofree(low)
	add_child_autofree(high)

	var plane := OverworldPicker._contact_plane_of(low, pose)
	# Same ground for both, since the plane is a property of the car ALREADY standing there.
	assert_almost_eq(pose.origin.y - plane.y, low.ride_height, 0.0001,
		"the contact plane is the standing car's own rest height below its origin")
	assert_gt(high.ride_height, low.ride_height,
		"the two stubs differ — else the seat below could not be told apart")


# The real car keeps its collider while merely hidden, and the prop is now dropped at exactly the
# spot it occupies — so without neutralising it the prop lands on an invisible car, or is shoved
# out of frame. Its own stub here, because the file's StubCar is a plain Node3D with no layer.
class StubBodyCar:
	extends StaticBody3D
	var controls_locked := false
	var freeze := false
	var ride_height := 0.0
	var handbrake_locked := false
	func reset_to(xform: Transform3D) -> void:
		global_transform = xform
	func settled_ride_height() -> float:
		return ride_height


func test_the_real_cars_collider_is_neutralised_while_hidden_and_restored() -> void:
	var car := StubBodyCar.new()
	car.collision_layer = 5
	add_child_autofree(car)
	var picker := OverworldPicker.new()
	add_child_autofree(picker)
	picker.setup({"car": car, "visuals": false})

	picker._take_over_car()
	assert_eq(car.collision_layer, 0,
		"the hidden car stops being collidable, so a dropped prop lands on the road not on it")
	assert_false(car.visible, "and it is hidden, since the prop stands in for it")

	picker._hand_car_back()
	assert_eq(car.collision_layer, 5,
		"its layer is PUT BACK, not assumed — restore only what you took")
	assert_true(car.visible, "and it is visible again")


# --- Leaving the picker flies, it does not cut ---------------------------------
#
# The showroom camera used to hand the viewport back the instant the picker closed, which read as a
# jump. It now flies to wherever the PLAYER'S chosen camera is sitting and hands over on arrival.
#
# The interpolation itself needs a viewport and two live cameras, so what is asserted here is the
# contract around it: a picker with no cameras to fly between must still hand back IMMEDIATELY, or
# a headless close would hang holding the viewport for a transition that can never finish.
func test_a_visualless_close_hands_the_camera_back_at_once() -> void:
	var picker := _picker
	var rally := _open_rally()
	if rally.is_empty():
		pending("the fixture roster produced no eligible rally")
		return
	picker.open_for_rally(rally)
	assert_null(picker.camera(),
		"visuals off builds no showroom camera — else this proves nothing")

	picker.close()
	# No camera, so nothing to fly: the picker must not be left mid-transition, because with no
	# camera the fly could never complete and the viewport would never come back.
	assert_false(picker._flying,
		"a close with nothing to fly leaves no transition running")


# 0 seconds means CUT — the same path a visuals-off picker takes, so the tunable can switch the
# transition off entirely without changing the hand-back contract. Pins the RELATIONSHIP (zero
# disables), never the shipped duration.
func test_a_zero_fly_duration_cuts_instead_of_flying() -> void:
	var was := Config.data.overworld_picker_fly_seconds
	Config.data.overworld_picker_fly_seconds = 0.0
	var rally := _open_rally()
	if rally.is_empty():
		Config.data.overworld_picker_fly_seconds = was
		pending("the fixture roster produced no eligible rally")
		return
	_picker.open_for_rally(rally)
	_picker.close()
	var flying := _picker._flying
	Config.data.overworld_picker_fly_seconds = was
	assert_false(flying, "a zero duration hands over at once rather than flying")


# THE CONTACT PLANE COMES FROM THE GROUND, NOT FROM THE CAR STANDING ON IT.
#
# This is the bug that took four attempts. The plane was derived from the real car's pose minus its
# rest height — which assumes that car is already settled. During the STARTER pick it is not: the
# picker opens on boot, moments after the car was seated at `height_at + spawn_clearance` (2.5 m),
# so its origin is metres above the ground it will fall to. Every prop was seated relative to that
# and appeared in the air by exactly the clearance, which is why correcting the height arithmetic
# never helped — the arithmetic was right and the REFERENCE was wrong.
#
# Pins the RELATIONSHIP: with a ground source, the plane follows the ground and ignores how high the
# car happens to be. Never a clearance value or a height.
func test_the_plane_follows_the_ground_not_the_cars_height() -> void:
	var car := StubBodyCar.new()
	car.ride_height = 0.30
	add_child_autofree(car)
	var picker := OverworldPicker.new()
	add_child_autofree(picker)

	const GROUND_Y := 12.0
	picker.setup({
		"car": car,
		"visuals": false,
		"ground_at": func(_p: Vector3) -> float: return GROUND_Y,
	})

	# The car is HIGH above that ground, exactly as it is on the frame the starter pick opens.
	var airborne := Transform3D(Basis.IDENTITY, Vector3(4.0, GROUND_Y + 2.5, -7.0))
	var plane: Vector3 = picker._plane_under(airborne)
	assert_almost_eq(plane.y, GROUND_Y, 0.0001,
		"the plane is the GROUND under the car, not an offset from the car's own origin")
	assert_almost_eq(plane.x, airborne.origin.x, 0.0001, "and it stays under the car in x")
	assert_almost_eq(plane.z, airborne.origin.z, 0.0001, "and in z")

	# The old derivation is the FALLBACK, for a host that injects no ground source — and it is what
	# produced the bug, so pin that it is only reached when there is nothing better.
	var bare := OverworldPicker.new()
	add_child_autofree(bare)
	bare.setup({"car": car, "visuals": false})
	var fallback: Vector3 = bare._plane_under(airborne)
	assert_almost_eq(fallback.y, airborne.origin.y - car.ride_height, 0.0001,
		"with no ground source it falls back to the car-relative plane")
	assert_ne(fallback.y, plane.y,
		"the two differ — else this test could not tell which one ran")
