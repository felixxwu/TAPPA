extends GutTest
# StartLine: the cinematic pre-event start-line sequence — a MENU (Start / Tune / Upgrades)
# over an orbit idle, a camera fly-in to a fixed 3/4 reveal shot, a per-opponent REVEAL
# (the three real top rivals line up ahead in their actual cars; Next sends each off the
# line and reveals the next one immediately — eager reveal, the roll-up plays underneath),
# then the fade → countdown once the player reaches the line.
# The timed phases are driven by calling _process(dt) directly against stub car/stage/camera
# stubs, so the sequence is tested without booting the run scene. See features/start-line.md.


# Records the launch hand-off (StartLine -> StageManager.begin_countdown()).
class StubStage:
	extends Node
	var begin_calls := 0
	func begin_countdown() -> void:
		begin_calls += 1


# Stand-in for the fielded player Car — a VehicleBody3D (so the roll-up staging, gated on
# `is VehicleBody3D` + the AI hook, runs) with just the hook properties and a minimal
# drivetrain for the gearbox-auto restore.
class StubEngine:
	extends RefCounted
	var auto := false
class StubDrivetrain:
	extends RefCounted
	var engine := StubEngine.new()
class StubPlayer:
	extends VehicleBody3D
	var ai_controlled := false
	var ai_throttle := 0.0
	var ai_steer := 0.0
	var ai_handbrake := false
	var drivetrain := StubDrivetrain.new()
	var retune_calls := 0
	var applied_owned := false
	func retune(_owned: Dictionary) -> void:
		retune_calls += 1
	func apply_owned(_owned: Dictionary) -> String:
		applied_owned = true
		return ""
	var refit_calls := 0
	func refit_upgrades(_owned: Dictionary) -> void:
		refit_calls += 1


# A flat terrain stub at a raised elevation, so the spawn-clearance seating is testable.
class StubTerrain:
	extends Node
	const GROUND_Y := 3.0
	func height_at(_x: float, _z: float) -> float:
		return GROUND_Y


const TEST_PATH := "user://test_start_line_profile.json"
# For the few tests that need a REAL fielded player car rather than StubPlayer — the
# config-identity contract is about the object car.gd holds, which a stub has no notion of.
const CAR_SCENE := preload("res://car.tscn")

var _player: StubPlayer
var _stage: StubStage
var _chase: Camera3D
var _bonnet: Camera3D
var _cam_mgr: CameraManager
var _hud: CanvasLayer
var _save: Node


func before_each() -> void:
	Config.reset()
	# This file drives real start_rally() calls, whose _enter_event() ends in
	# `if auto_load_scenes: change_scene_to_file("res://main.tscn")` — and the seam
	# defaults to TRUE. Under the headless runner that scene is added to /root and
	# never freed, poisoning the shared physics space for every later file (see
	# features/testing.md → "Never let a change_scene_to_file escape", and
	# test_world_isolation.gd, which fails when one escapes).
	RallySession.auto_load_scenes = false
	CarFixtures.install()
	RallyFixtures.install()
	_save = get_node("/root/Save")
	_save.profile_path = TEST_PATH
	_save.save_disabled = false
	_save.load_or_new()
	_player = StubPlayer.new()
	add_child_autofree(_player)
	_stage = StubStage.new()
	add_child_autofree(_stage)
	_chase = Camera3D.new()
	_bonnet = Camera3D.new()
	add_child_autofree(_chase)
	add_child_autofree(_bonnet)
	_cam_mgr = CameraManager.new()
	_cam_mgr.chase_camera = _chase
	_cam_mgr.bonnet_camera = _bonnet
	add_child_autofree(_cam_mgr)  # _ready() applies the saved (chase) mode
	_hud = CanvasLayer.new()
	add_child_autofree(_hud)


func after_each() -> void:
	if RallySession.is_active():
		RallySession.abandon()
	if ChallengeSession.is_active():
		ChallengeSession.abandon()
	RallySession.auto_load_scenes = true
	ChallengeSession.auto_load_scenes = true
	Config.reset()
	CarFixtures.restore()
	RallyFixtures.restore()
	UpgradeFixtures.restore()  # only one test installs it; restore() is a plain reset()
	_save.profile_path = _save.DEFAULT_PROFILE_PATH
	for suffix in ["", ".bak", ".tmp"]:
		if FileAccess.file_exists(TEST_PATH + suffix):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_PATH + suffix))


# Fixture Open: a rally with an event count for the subtitle.
func _rally() -> Dictionary:
	return RallyLibrary.by_id("fx_open")


# Three synthetic leaders in real fixture cars (fastest first) — the grid spawns each
# leader's actual car by its car_id.
func _leaders() -> Array:
	return [
		{"name": "Rival 3", "car_id": "fx_light_rwd", "car_name": "Fixture Roadster", "time_ms": 75430},
		{"name": "Rival 1", "car_id": "fx_rwd_coupe", "car_name": "Fixture Coupe", "time_ms": 78120},
		{"name": "Rival 7", "car_id": "fx_fwd_hatch", "car_name": "Fixture Hatch", "time_ms": 80050},
	]


func _make(leaders := [], event_index := 0) -> StartLine:
	var sl := StartLine.new()
	add_child_autofree(sl)
	sl.set_process(false)  # drive the sequence manually for deterministic timing
	sl.setup(_player, null, _stage, _rally(), event_index, leaders, _cam_mgr, _hud)
	return sl


# Fly the camera in and land in REVEAL for the first opponent.
func _launch_to_reveal(sl: StartLine) -> void:
	sl.launch()
	sl._process(Config.data.start_reveal_fly_seconds + 0.01)


# Send the current front car off; with eager reveal the next opponent's card shows
# immediately (the roll-up plays out underneath and does not gate the reveal).
func _advance_one(sl: StartLine) -> void:
	sl.next_car()


# --- Grid layout -------------------------------------------------------------

func test_three_opponents_line_up_ahead_none_behind() -> void:
	var sl := _make(_leaders())
	assert_eq(sl.queue_count(), 3, "the three top rivals line up ahead of the player")
	# The player is the tail of the grid; nothing is staged behind it.
	assert_eq(sl._grid.back(), _player, "the player is the last car in the grid (nothing behind)")
	# The opponents are spaced one gap apart along the start heading, not stacked.
	var gap := Config.data.start_queue_gap
	for i in 3:
		assert_almost_eq(sl._grid[i].global_position.z, gap * float(i), 0.01,
			"opponent %d sits %d gap(s) behind the line, not on top of the others" % [i, i])


func test_grid_cars_use_the_leaders_actual_cars() -> void:
	# The grid spawns each leader's own car (by car_id), front-first, not arbitrary
	# flavour models. Behaviour: the spawned ids mirror the leaders list.
	var sl := _make(_leaders())
	var want: Array[String] = []
	for e in _leaders():
		want.append(String(e["car_id"]))
	assert_eq(sl.queue_car_ids(), want, "grid cars are the leaders' actual cars, in order")


# A rival running a SWAPPED engine is staged with that engine, not its car's stock one.
# The grid cars idle and pull away audibly during the reveal, and layout fixes cylinder
# count which fixes the firing table which IS the voice — so a prop left on the stock
# engine sounds wrong while the reveal card names the swapped one. Asserted through the
# prop's live config (redline is written by EngineLibrary.apply) rather than by naming a
# number: the fixture engines are looked up for the comparison, so a retune moves both
# sides together.
func test_grid_cars_are_staged_with_the_rivals_fitted_engine() -> void:
	# fx_light_rwd's stock engine is fx_i4; field it running the other fixture engine.
	var stock_id := String(CarLibrary.by_id("fx_light_rwd").get("engine", ""))
	var donor_id := ""
	for eng in EngineLibrary.all():
		if String(eng.get("id", "")) != stock_id:
			donor_id = String(eng.get("id", ""))
			break
	assert_ne(donor_id, "", "the fixture roster offers a second engine to swap in")

	var swapped := [{"name": "Rival 1", "car_id": "fx_light_rwd", "engine_id": donor_id,
		"car_name": "Swapped Roadster", "time_ms": 75430}]
	var sl := _make(swapped)
	var prop = sl._grid[0]
	var donor := EngineLibrary.by_id(donor_id)
	var stock := EngineLibrary.by_id(stock_id)
	assert_ne(float(donor.get("redline_rpm", 0.0)), float(stock.get("redline_rpm", 0.0)),
		"precondition: the two fixture engines differ, so this test can tell them apart")
	assert_almost_eq(float(prop.config.redline_rpm), float(donor["redline_rpm"]), 0.5,
		"the prop runs the rival's FITTED engine, not the car's stock one")
	# The config the voice is BUILT FROM carries the fitted engine's cylinder count...
	assert_eq(int(prop.config.engine_cylinders),
		EngineLibrary.cylinders(donor), "the config names the fitted engine's cylinders")
	# ...and the synth was actually REBUILT from it. Asserted on the synth's own firing
	# phases, not on config alone: config fields are written by EngineLibrary.apply whether
	# or not _reconfigure_engine_audio ever ran, so a config-only assertion would still pass
	# with the voice left stale (or unbuilt — apply_car(index, false) defers it).
	var synth = prop.get_node("EngineAudio")._synth
	assert_not_null(synth, "the prop has an engine synth")
	assert_eq(synth._firing_phases.size(), prop.config.engine_firing_phases().size(),
		"the voice was rebuilt from the config holding the fitted engine")
	# The swap carries its own transmission and mass, so those must move with it.
	assert_almost_eq(float(prop.config.final_drive), float(donor["final_drive"]), 0.001,
		"the fitted engine's final drive came with it")
	assert_gt(float(prop.mass), 0.0, "the prop has a real mass after the swap")


# A rival with NO swap (stock engine, or an empty engine_id from an older cache entry)
# is still staged and still audible — fit_engine rebuilds the voice unconditionally, so
# deferring apply_car's audio build can't leave a stock prop silent.
func test_a_stock_rival_is_still_staged_with_its_own_engine() -> void:
	var stock_id := String(CarLibrary.by_id("fx_light_rwd").get("engine", ""))
	var sl := _make([{"name": "Rival 1", "car_id": "fx_light_rwd", "engine_id": "",
		"car_name": "Fixture Roadster", "time_ms": 75430}])
	var prop = sl._grid[0]
	assert_almost_eq(float(prop.config.redline_rpm),
		float(EngineLibrary.by_id(stock_id)["redline_rpm"]), 0.5,
		"an unswapped rival keeps its car's stock engine")
	# The actual silence guard: fit_engine rebuilds the voice UNCONDITIONALLY, so a stock
	# rival is not left mute by apply_car(index, false) having deferred the build. Reading
	# the synth is what makes this real — config fields alone are written either way.
	var synth = prop.get_node("EngineAudio")._synth
	assert_not_null(synth, "a stock prop still has an engine synth")
	assert_eq(synth._firing_phases.size(), prop.config.engine_firing_phases().size(),
		"a stock prop's voice was built, not left unbuilt by the deferred rebuild")


# A stray tap must NOT start the run. This used to launch: tapping anywhere while the start
# menu was up called launch(), so missing UPGRADES or TUNE CAR — or an idle tap while reading
# the stage banner — committed the player to the stage with no confirmation. Starting is the
# START button's job alone now.
func test_a_tap_on_the_start_menu_does_not_launch() -> void:
	var sl := _make(_leaders())
	assert_eq(sl._seq, StartLine.Seq.MENU, "precondition: the start menu is up")

	var tap := InputEventScreenTouch.new()
	tap.pressed = true
	sl._unhandled_input(tap)
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	sl._unhandled_input(click)

	assert_eq(sl._seq, StartLine.Seq.MENU, "a tap and a click both leave the menu up")
	assert_false(sl._launched, "and neither started the run")
	# The button still works — this removes the accidental path, not the deliberate one.
	sl.launch()
	assert_true(sl._launched, "pressing START still launches")


func test_grid_cars_are_scripted_and_axis_locked() -> void:
	var sl := _make(_leaders())
	var front = sl._grid[0]
	assert_true(front.ai_controlled, "grid cars drive under scripted control, not player Input")
	assert_true(front.axis_lock_linear_x, "lateral axis locked so they can't veer off line")
	assert_true(front.axis_lock_angular_y, "yaw locked so they stay pointed straight")
	assert_false(front.freeze, "they run live physics (suspension loads), not frozen")
	assert_eq(front.ai_throttle, 0.0, "they idle on the parking brake until they're launched")


# Each grid prop's apply_car() mutates the SHARED global Config.data; the player is
# fielded first, so a prop leaking its gearbox into Config.data would corrupt the
# player's live gearing. Spawning the grid must leave the player's config untouched.
func test_grid_spawn_does_not_clobber_the_players_config() -> void:
	Config.data.final_drive = 7.77  # a sentinel no car uses
	var sl := _make(_leaders())
	assert_eq(sl.queue_count(), 3, "the grid actually spawned props (so the test isn't vacuous)")
	assert_almost_eq(Config.data.final_drive, 7.77, 0.001,
		"the player's final_drive survives the grid spawn (props don't leak into the shared config)")


# Preserving the config's VALUES is not enough — the fielded player car holds that exact
# OBJECT as its `config` (car.gd), and the HUD / engine audio / save layer read Config.data.
# Swapping in a restored duplicate splits the two, so anything the car writes afterwards
# (notably the pre-race Upgrades menu's refit) lands somewhere nothing else reads.
func test_grid_spawn_keeps_the_shared_config_object_identity() -> void:
	var live: GameConfig = Config.data
	var sl := _make(_leaders())
	assert_eq(sl.queue_count(), 3, "the grid actually spawned props (so the test isn't vacuous)")
	assert_same(Config.data, live,
		"the grid spawn restores the player's config IN PLACE, never reassigning Config.data")


# The LIVE engine fields (peak_torque, redline_rpm, …) are plain non-@export vars, so a
# save/restore built on Resource.duplicate() would silently reset them to their declared
# defaults — leaving the shared config claiming a different engine than the fielded car.
func test_grid_spawn_preserves_the_live_engine_fields() -> void:
	Config.data.peak_torque = 333.0    # sentinels, not tuning: the point is they survive
	Config.data.redline_rpm = 7777.0
	var sl := _make(_leaders())
	assert_eq(sl.queue_count(), 3, "the grid actually spawned props (so the test isn't vacuous)")
	assert_almost_eq(Config.data.peak_torque, 333.0, 0.001,
		"the fielded engine's torque survives the grid spawn")
	assert_almost_eq(Config.data.redline_rpm, 7777.0, 0.001,
		"…and so does its redline")


# The bug this pins: a turbo bought and fitted in the pre-race Upgrades menu drove the car
# but lit no boost gauge until the next stage. The menu commits by refitting the LIVE car
# (_on_upgrade_changed -> car.refit_upgrades), which writes the car's own `config`, while the
# HUD asks Config.data.has_forced_induction() — so the two must still be one object after
# the grid has been staged around the car.
func test_a_turbo_fitted_at_the_start_line_reaches_the_config_the_hud_reads() -> void:
	UpgradeFixtures.install()
	var owned := {"model_id": "fx_light_rwd", "installed_upgrades": [], "disabled_upgrades": [],
		"tuning": {}, "instance_id": -1}
	var car := CAR_SCENE.instantiate()
	add_child_autofree(car)
	await get_tree().physics_frame  # _ready(): builds the drivetrain and takes Config.data
	car.apply_owned(owned)          # fielded like world.gd does it (no isolated config)
	var sl := StartLine.new()
	add_child_autofree(sl)
	sl.set_process(false)
	sl.setup(car, null, _stage, _rally(), 0, _leaders(), _cam_mgr, _hud)
	assert_eq(sl.queue_count(), 3, "the grid staged around the fielded car")
	assert_false(Config.data.has_forced_induction(), "setup: the fielded car starts unboosted")

	owned["installed_upgrades"] = ["fx_turbo_small"]
	car.refit_upgrades(owned)

	assert_true(car.config.has_forced_induction(), "the refit fitted the part to the car's config")
	assert_true(Config.data.has_forced_induction(),
		"…and the HUD reads that same config, so the boost gauge appears without a new stage")


func test_player_is_staged_behind_the_grid_to_roll_up() -> void:
	var sl := _make(_leaders())
	assert_true(_player.ai_controlled, "the player is scripted for the roll-up")
	assert_true(_player.axis_lock_linear_x, "player lateral locked during the roll-up")
	assert_true(_player.axis_lock_angular_y, "player yaw locked during the roll-up")
	# Staged the full three-car grid of gaps behind the line (local +Z).
	assert_almost_eq(_player.global_position.z, Config.data.start_queue_gap * 3.0, 0.01,
		"player staged three gaps behind the start line, behind the opponents")


func test_start_line_cars_spawn_a_clearance_above_the_road() -> void:
	var terrain := StubTerrain.new()
	add_child_autofree(terrain)
	var sl := StartLine.new()
	add_child_autofree(sl)
	sl.set_process(false)
	sl.setup(_player, terrain, _stage, _rally(), 0, _leaders(), _cam_mgr, _hud)
	var seated := StubTerrain.GROUND_Y + Config.data.start_spawn_clearance
	assert_almost_eq(sl._start_xform.origin.y, seated, 0.001,
		"the start pose (countdown / reset target) sits a clearance above the road")
	assert_almost_eq(_player.global_position.y, seated, 0.001,
		"the staged player is seated a clearance above the ground")
	assert_almost_eq(sl._grid[0].global_position.y, seated, 0.01,
		"the front opponent spawns a clearance above the ground")


# --- MENU / camera -----------------------------------------------------------

func test_menu_hides_hud_and_takes_the_camera() -> void:
	var sl := _make(_leaders())
	assert_false(_hud.visible, "the driving HUD is hidden during the sequence")
	assert_true(sl._orbit_cam.current, "the start-line camera takes over from the chase camera")
	assert_eq(sl.sequence_phase(), StartLine.Seq.MENU, "it waits in the MENU phase")


func test_start_overlay_uses_the_house_button_row_height() -> void:
	var sl := _make(_leaders())
	assert_eq(sl._start_button.custom_minimum_size.y, float(UITheme.MENU_ROW_H),
		"the Start button uses the fixed menu row height")
	assert_string_contains(sl._subtitle_label.text, "FIXTURE OPEN", "the rally is named")
	assert_string_contains(sl._subtitle_label.text, "STAGE 1 OF 3", "the event index is shown")


func test_grab_start_focus_seats_the_cursor_on_start() -> void:
	# world.gd calls this after the between-event pit-repair popup (RepairReveal)
	# dismisses, since freeing that popup's focused Continue button clears the
	# viewport's focus owner outright and nothing else re-grabs it (the start-line
	# overlay's own MenuNav only re-grabs on ITS root's visibility_changed, which never
	# fires here). Without this hand-off keyboard/gamepad players are left with no
	# focus at all after dismissing the popup.
	var sl := _make(_leaders())
	await get_tree().process_frame  # let MenuNav's deferred initial grab land first
	get_viewport().gui_release_focus()
	assert_null(get_viewport().gui_get_focus_owner(), "focus is cleared, simulating the popup teardown")
	sl.grab_start_focus()
	assert_true(sl._start_button.has_focus(), "focus lands back on Start")


func test_launch_flies_the_camera_then_reveals_the_first_opponent() -> void:
	var sl := _make(_leaders())
	sl.launch()
	assert_true(sl.has_launched(), "launching flips the launched flag")
	assert_eq(sl.sequence_phase(), StartLine.Seq.FLY_IN, "Start begins the camera fly-in")
	assert_false(sl._overlay.visible, "the MENU overlay hides on launch")
	assert_eq(_stage.begin_calls, 0, "the countdown does NOT start yet")
	sl._process(Config.data.start_reveal_fly_seconds + 0.01)
	assert_eq(sl.sequence_phase(), StartLine.Seq.REVEAL, "the fly-in lands in the per-opponent reveal")
	assert_true(sl._reveal_overlay.visible, "the reveal card shows once the camera has arrived")


func test_reveal_card_shows_the_current_front_opponents_name_and_time() -> void:
	var sl := _make(_leaders())
	_launch_to_reveal(sl)
	assert_eq(sl.reveal_index(), 0, "the first opponent (P1) is on the line")
	# Behaviour: the card reflects current_event_leaders()[reveal_index], uppercased by the theme.
	assert_string_contains(sl._reveal_name_label.text, "RIVAL 3", "P1's driver name is shown")
	assert_string_contains(sl._reveal_car_label.text, "FIXTURE ROADSTER", "P1's car is shown")
	assert_string_contains(sl._reveal_time_label.text, "1:15.43", "P1's time to beat is shown (m:ss.cc)")


# --- Reveal-queue radius wiring (engine_audio.gd reads these) ----------------
# engine_audio.gd tightens its proximity radius for queued cars while REVEAL is
# active, using StartLine.active_instance + reveal_focus_car() to tell "the car
# on the card" (normal radius) apart from "everyone still waiting" (tighter
# radius). These are the wiring's own contract, independent of any dB value.

func test_active_instance_is_set_while_the_sequence_is_live() -> void:
	var sl := _make(_leaders())
	assert_eq(StartLine.active_instance, sl, "setup() seats itself as the live instance")
	sl.free()
	await get_tree().process_frame
	assert_null(StartLine.active_instance, "freeing the instance clears the static ref")


func test_reveal_focus_car_is_null_outside_reveal() -> void:
	var sl := _make(_leaders())
	assert_eq(sl.sequence_phase(), StartLine.Seq.MENU)
	assert_null(sl.reveal_focus_car(), "no focus car while waiting in MENU")


func test_reveal_focus_car_is_the_front_grid_car_during_reveal() -> void:
	var sl := _make(_leaders())
	_launch_to_reveal(sl)
	assert_eq(sl.sequence_phase(), StartLine.Seq.REVEAL)
	assert_eq(sl.reveal_focus_car(), sl._grid[0], "the focus car is the one on the reveal card")
	assert_ne(sl.reveal_focus_car(), sl._grid[1], "a queued car behind it is not the focus car")


# Regression: next_car() advances the reveal card (and _grid[0]) the instant the front
# car is waved off, but the NEW front car takes a moment to physically roll up into the
# shot from its old queue slot — so for a beat after every tap, `_grid[0]` is the
# data-correct "next" car while the car still nearest the camera (the one actually on
# screen) is the one that just departed. reveal_focus_car() must track whichever car is
# physically closest to the reveal camera at each moment — including through that
# hand-off beat — not just blindly report `_grid[0]`, or engine_audio.gd exempts the
# wrong car from attenuation and the player hears the car "behind" the one on screen.
func test_reveal_focus_car_tracks_the_camera_target_through_the_hand_off() -> void:
	var sl := _make(_leaders())
	_launch_to_reveal(sl)
	var cam_pos: Vector3 = sl._orbit_cam.global_position

	# Before any tap: the front grid car is already parked in the shot, closest to the
	# camera — it's the focus, matching the earlier (data-index) test above.
	assert_eq(sl.reveal_focus_car(), sl._grid[0], "at rest, the parked front car is the focus")

	# Tap Next: P1 is sent off (now in _departed) but hasn't actually moved yet this
	# frame, so it is still physically nearest the camera — the reveal card has already
	# flipped to P2, but P2 (now _grid[0]) is still back in its old queue slot. The focus
	# car must stay with the (still on-screen) departing car, not jump to data's `_grid[0]`.
	var departing = sl._grid[0]
	sl.next_car()
	assert_eq(sl.reveal_index(), 1, "the card has already advanced to the next opponent")
	assert_ne(sl.reveal_focus_car(), sl._grid[0],
		"the new front car hasn't rolled into shot yet, so it is NOT the focus")
	assert_eq(sl.reveal_focus_car(), departing,
		"the just-departed car is still nearest the camera, so it stays the focus")

	# As the departing car actually pulls away and the new front car rolls up, the focus
	# hands over the moment the new front car becomes the nearer of the two — matching
	# what the player now sees on screen.
	departing.global_position = cam_pos + Vector3(0, 0, -200.0)  # long gone down the lead-in
	assert_eq(sl.reveal_focus_car(), sl._grid[0],
		"once the departed car is far away, focus hands over to the (now nearest) new front car")


func test_reveal_card_shows_the_gap_to_the_fastest_rival() -> void:
	# The card shows each rival's gap to the fastest (P1); the benchmark reads FASTEST.
	var sl := _make(_leaders())
	_launch_to_reveal(sl)
	assert_string_contains(sl._reveal_gap_label.text, "FASTEST", "the fastest rival has no gap to itself")
	sl.next_car()  # reveal P2 — 2.69 s down on P1 (78120 − 75430 ms, from _leaders())
	assert_string_contains(sl._reveal_gap_label.text, "+2.69", "a trailing rival shows its gap to P1")


func test_overall_rank_row_is_hidden_on_the_first_event() -> void:
	# Event 1: nothing has been raced, so the standings are all tied and an "overall"
	# ranking is meaningless — the row is hidden rather than showing a bogus rank.
	var sl := _make(_leaders())  # event_index 0
	_launch_to_reveal(sl)
	assert_false(sl._reveal_overall_row.visible, "no overall ranking on event 1")


func test_overall_rank_row_shows_the_championship_position() -> void:
	# From event 2 on, the card shows each rival's overall championship position (matched
	# by driver name). Inject a known standing and re-render the current card.
	var sl := _make(_leaders())
	_launch_to_reveal(sl)
	sl._overall_rank = {"Rival 3": 2}
	sl._show_reveal_card()
	assert_true(sl._reveal_overall_row.visible, "the overall row shows once a rank is known")
	assert_string_contains(sl._reveal_overall_label.text, "2ND", "it shows the championship position")


# --- Per-opponent reveal loop ------------------------------------------------

func test_next_sends_the_front_car_off_and_advances_the_reveal() -> void:
	var sl := _make(_leaders())
	_launch_to_reveal(sl)
	var p1 = sl._grid[0]
	sl.next_car()
	assert_eq(p1.ai_throttle, 1.0, "Next floors the front car so it pulls off the line")
	# Eager reveal: the next opponent's card shows immediately, no wait for the roll-up.
	assert_eq(sl.sequence_phase(), StartLine.Seq.REVEAL, "the next opponent is revealed right away")
	assert_true(sl._reveal_overlay.visible, "the reveal card stays up for the next opponent")
	assert_eq(sl.reveal_index(), 1, "the reveal advances to the next opponent")
	assert_eq(sl.queue_count(), 2, "the departed car has left the grid")
	assert_string_contains(sl._reveal_name_label.text, "RIVAL 1", "P2 is revealed immediately")




func test_walks_through_all_three_opponents_then_fades_to_the_countdown() -> void:
	var sl := _make(_leaders())
	_launch_to_reveal(sl)
	_advance_one(sl)  # P1 off, P2 revealed
	_advance_one(sl)  # P2 off, P3 revealed
	# Third Next sends P3 off; the player is now the only car left → the fade begins.
	sl.next_car()
	assert_eq(sl.sequence_phase(), StartLine.Seq.FADE_OUT, "the last opponent leaving begins the fade")
	assert_eq(sl.queue_count(), 0, "all three opponents have driven off")
	sl._process(Config.data.start_fade_seconds + 0.01)
	assert_eq(_stage.begin_calls, 1, "the countdown starts at full black")
	assert_true(_chase.current, "the chase camera is handed control back")
	assert_false(sl._orbit_cam.current, "the start-line camera releases control")
	assert_true(_hud.visible, "the driving UI returns")


func test_handoff_releases_the_player_to_normal_driving() -> void:
	var sl := _make(_leaders())
	_launch_to_reveal(sl)
	for i in 3:
		sl.next_car()  # three eager taps: P1, P2, P3 off → fade
	sl._process(Config.data.start_fade_seconds + 0.01)
	assert_false(_player.ai_controlled, "the player is handed back to normal driving")
	assert_false(_player.axis_lock_linear_x, "lateral lock released so the player can steer")
	assert_false(_player.axis_lock_angular_y, "yaw lock released for the run")


func test_reveal_hand_off_restores_the_selected_camera_not_always_chase() -> void:
	_cam_mgr.set_mode(CameraManager.Mode.BONNET)
	var sl := _make(_leaders())
	_launch_to_reveal(sl)
	for i in 3:
		sl.next_car()  # three eager taps walk P1 → P2 → P3 off the line
	sl._process(Config.data.start_fade_seconds + 0.01)
	assert_true(_bonnet.current, "the selected (bonnet) camera is restored at hand-off")
	assert_false(_chase.current, "the start line does not force chase over the chosen mode")


func test_empty_leaders_skips_straight_to_the_fade() -> void:
	# Dev/test harnesses can field no opponents; the player is already on the line, so
	# launch goes straight to the fade + countdown (no grid, no reveal).
	var sl := _make([])
	assert_eq(sl.queue_count(), 0, "no opponents line up")
	sl.launch()
	assert_eq(sl.sequence_phase(), StartLine.Seq.FADE_OUT, "with no opponents, Start goes straight to the fade")
	sl._process(Config.data.start_fade_seconds + 0.01)
	assert_eq(_stage.begin_calls, 1, "the countdown still starts")


func test_launch_is_idempotent() -> void:
	var sl := _make(_leaders())
	sl.launch()
	assert_eq(sl.sequence_phase(), StartLine.Seq.FLY_IN, "launch begins the fly-in")
	sl.launch()  # a stray second press must not restart anything
	assert_eq(sl.sequence_phase(), StartLine.Seq.FLY_IN, "a second launch is ignored")


# --- Eligibility gates (unchanged behaviour) ---------------------------------

func test_launch_is_gated_by_rally_eligibility() -> void:
	var owned: Dictionary = _save.grant_car("fx_light_rwd")
	_save.set_selected_car(int(owned["instance_id"]))
	RallySession.start_rally(_rally(), owned, true)
	var sl := _make(_leaders())
	sl._rally = {"restriction": {"engine_min_l": 999.0}}
	sl.launch()
	assert_false(sl.has_launched(), "launch() is blocked when the fielded car is ineligible")
	assert_eq(sl.sequence_phase(), StartLine.Seq.MENU, "the sequence does not advance when blocked")


func test_launch_proceeds_when_the_car_is_eligible() -> void:
	var owned: Dictionary = _save.grant_car("fx_light_rwd")
	_save.set_selected_car(int(owned["instance_id"]))
	RallySession.start_rally(_rally(), owned, true)
	var sl := _make(_leaders())
	sl._rally = {}  # open class: no restriction to fail
	sl.launch()
	assert_true(sl.has_launched(), "launch() proceeds when there is no eligibility gate to fail")


# --- Pre-race menus (unchanged behaviour) ------------------------------------

func test_start_overlay_has_focusable_tune_and_upgrades_buttons() -> void:
	var sl := _make(_leaders())
	assert_eq(sl._tune_button.focus_mode, Control.FOCUS_ALL,
		"the Tune Car button is keyboard/gamepad focusable (MenuNav attached)")
	assert_eq(sl._upgrades_button.focus_mode, Control.FOCUS_ALL,
		"the Upgrades button is keyboard/gamepad focusable (MenuNav attached)")


func test_tune_overlay_opens_and_back_returns_to_the_start_overlay() -> void:
	RallySession.start_rally(_rally(), _save.selected_car(), true)
	var sl := _make(_leaders())
	sl._open_tune()
	assert_true(sl._tune_layer.visible, "opening Tune Car shows the tuning overlay")
	assert_false(sl._overlay.visible, "the start overlay hides while tuning")
	sl._close_tune()
	assert_true(sl._overlay.visible, "Back restores the start overlay")
	assert_false(sl._tune_layer.visible, "Back hides the tuning overlay")


func test_start_line_tune_uses_retune_and_preserves_the_staged_pose() -> void:
	RallySession.start_rally(_rally(), _save.selected_car(), true)
	var sl := _make(_leaders())
	var pose_before: Transform3D = _player.global_transform
	sl._open_tune()
	sl._on_tune_changed(_save.selected_car())
	assert_gt(_player.retune_calls, 0, "the tune routes through the live-safe retune path")
	assert_false(_player.applied_owned,
		"it must NOT re-field via apply_owned (that relocates wheels + resets the pose)")
	assert_eq(_player.global_transform, pose_before, "the staged grid pose is preserved across a tune")


func test_upgrades_overlay_opens_and_back_returns_to_the_start_overlay() -> void:
	RallySession.start_rally(_rally(), _save.selected_car(), true)
	var sl := _make(_leaders())
	sl._open_upgrades()
	assert_true(sl._upgrades_layer.visible, "opening Upgrades shows the upgrades overlay")
	assert_false(sl._overlay.visible, "the start overlay hides while upgrading")
	sl._close_upgrades()
	assert_true(sl._overlay.visible, "Back restores the start overlay")
	assert_false(sl._upgrades_layer.visible, "Back hides the upgrades overlay")


func test_upgrade_changed_refits_the_live_car() -> void:
	RallySession.start_rally(_rally(), _save.selected_car(), true)
	var sl := _make(_leaders())
	sl._on_upgrade_changed()
	assert_true(_player.refit_calls > 0, "an upgrade edit refits the live car's upgrade state")


# --- Proximity attenuation replaces the bespoke fade/mute --------------------

func test_grid_cars_are_not_force_muted() -> void:
	# With proximity attenuation, queued cars idle (attenuated by distance) rather
	# than being hard-muted, so their EngineAudio must stay processing.
	var sl := _make(_leaders())
	var car = sl._grid[0]
	var ea := car.get_node_or_null("EngineAudio")
	assert_not_null(ea, "grid car has an EngineAudio node")
	assert_ne(ea.process_mode, Node.PROCESS_MODE_DISABLED, "not force-muted")


func test_prune_silences_before_free() -> void:
	# A car about to be despawned has its engine silenced first, so no live note is
	# hard-cut (the new attenuation curve leaves distant cars audible until pruned).
	var sl := _make(_leaders())
	var car := sl._grid[0] as Node3D
	sl._grid.erase(car)
	sl._departed = [car] as Array[Node3D]
	# Place it well past the lead-in so _prune_departed frees it.
	car.global_position = sl._start_xform * Vector3(0, 0, -(sl._cfg().start_lead_in_ahead_m + 50.0))
	var ea := car.get_node_or_null("EngineAudio")
	sl._prune_departed()
	# queue_free is deferred, so the node still exists this frame but is silenced.
	assert_eq(ea.process_mode, Node.PROCESS_MODE_DISABLED, "silenced before free")


# --- Challenge runs stage exactly like a rally event (features/rally-challenge.md) ---
#
# A Daily/Weekly/Monthly challenge stage gets the SAME pre-countdown screen a career
# rally event gets — the same Upgrades / Tune Car overlays on the same shared
# components — with one difference: a challenge has no rival field (spec §3), so it
# passes no leaders and takes the existing empty-leaders path (no reveal card) rather
# than fabricating rivals to stage against.

# The synthetic event dict world.gd._build_start_line hands StartLine for a challenge:
# a display name and nothing else. The performance ceiling is NOT smuggled in here as a
# restriction key — restrictions are categorical — the screen asks DrivingContext for it.
func _challenge_rally() -> Dictionary:
	return {"name": "Daily Challenge", "restriction": {}}


# Start a real Daily challenge run on a freshly granted fixture car and return it.
func _start_challenge() -> Dictionary:
	var owned: Dictionary = _save.grant_car("fx_light_rwd")
	ChallengeSession.auto_load_scenes = false
	assert_true(ChallengeSession.start(ChallengeLibrary.DAILY, owned,
		int(Time.get_unix_time_from_system())), "setup: the challenge run starts")
	return owned


func _make_challenge() -> StartLine:
	var sl := StartLine.new()
	add_child_autofree(sl)
	sl.set_process(false)
	sl.setup(_player, null, _stage, _challenge_rally(), ChallengeSession.events_completed(), [],
		_cam_mgr, _hud)
	return sl


func test_challenge_menus_bind_to_the_challenge_car_not_the_rally_one() -> void:
	# RallySession is inactive during a challenge, so a start line that asked IT for the
	# driven car would get -1 and bind the panels to nothing. Both pre-race menus must
	# resolve the run's own locked car instead.
	var owned := _start_challenge()
	assert_false(RallySession.is_active(), "setup: no rally is running alongside the challenge")
	var sl := _make_challenge()
	sl._open_tune()
	sl._open_upgrades()
	var want := int(owned["instance_id"])
	assert_eq(int(sl._tune_panel._owned.get("instance_id", -1)), want,
		"the Tune Car panel is bound to the challenge's locked car")
	assert_eq(int(sl._upgrades_menu._owned.get("instance_id", -1)), want,
		"the Upgrades menu is bound to the challenge's locked car")
	assert_eq(int(sl._driven_car().get("instance_id", -1)), want,
		"the shared driven-car resolver answers with the challenge car")


func test_challenge_upgrade_edit_refits_the_live_challenge_car() -> void:
	_start_challenge()
	var sl := _make_challenge()
	sl._on_upgrade_changed()
	assert_gt(_player.refit_calls, 0, "an upgrade edit refits the live car during a challenge too")


func test_challenge_shows_no_rival_panel_and_fades_straight_to_the_countdown() -> void:
	# No rival field to stage against: no grid cars, no reveal card shown, and Start
	# goes straight to the fade + countdown — the existing empty-leaders path, not a
	# fabricated rival list.
	var owned := _start_challenge()
	var sl := _make_challenge()
	sl._rally = _challenge_rally()
	assert_eq(sl.queue_count(), 0, "a challenge lines up no rival cars")
	assert_false(sl._reveal_overlay.visible, "the rival-times card is not shown")
	sl.launch()
	assert_true(sl.has_launched(), "Start launches (the eligible locked car passes the gate)")
	assert_eq(sl.sequence_phase(), StartLine.Seq.FADE_OUT, "with no rivals, Start fades straight out")
	assert_false(sl._reveal_overlay.visible, "still no rival card after launching")
	sl._process(Config.data.start_fade_seconds + 0.01)
	assert_eq(_stage.begin_calls, 1, "the countdown starts")


func test_challenge_header_counts_the_runs_own_stages() -> void:
	# A challenge has no authored event list, so the "Stage N of M" header falls back to
	# the active run's stage count rather than a rally's fixed events-per-rally.
	_start_challenge()
	var sl := _make_challenge()
	assert_eq(sl._stage_total(_challenge_rally()), ChallengeSession.stage_count(),
		"the stage total comes from the challenge run")
	assert_string_contains(sl._subtitle_label.text.to_upper(), "STAGE 1 OF %d" % ChallengeSession.stage_count())


# --- The pre-race performance ceiling goes through DrivingContext ---------------
#
# _rating_limit() no longer digs the restriction out of the event dict itself — it asks
# DrivingContext, which answers for whichever session is fielding the car. These
# tests cover the CHALLENGE branch, which is the only place a performance ceiling
# still exists — career rally entry is purely categorical now, with no gate at all.

func test_challenge_rating_limit_comes_from_the_periods_ceiling() -> void:
	_start_challenge()
	var sl := _make_challenge()
	# Derived from the same accessor chain the code under test uses — no band value
	# is pinned (CEILING_BAND_HP_TONNE is authored/tunable).
	assert_eq(sl._rating_limit(), ChallengeLibrary.ceiling_for(ChallengeSession.period_key()),
		"a challenge's pre-race ceiling is its period's rolled cap")
	assert_ne(sl._rating_limit(), DrivingContext.NO_LIMIT,
		"a real ceiling applies during a challenge — not the silent 'no limit' fallback")


func test_challenge_upgrades_close_button_gates_on_the_ceiling() -> void:
	var owned := _start_challenge()
	var id := int(owned["instance_id"])
	var sl := _make_challenge()
	# Force the car OVER the ceiling by running it at full power against a stand-in
	# ceiling one point below its own rating — the same "derive the expectation from the
	# car under test" trick test_upgrades_grid.gd uses, so nothing tunable is pinned.
	_save.set_engine_detune(id, 1.0)
	sl._open_upgrades()
	var entry := CarLibrary.by_id(String(owned["model_id"]))
	var full_rating := CarPerformance.rating(
		CarPerformance.merged_meta(_save.get_car(id), entry))
	# Re-bind the live menu to a ceiling this car provably busts at full power.
	sl._upgrades_menu.setup(_save.get_car(id), Callable(), Callable(), float(full_rating - 1))
	sl._upgrades_menu.bind_close_button(sl._upgrades_back, sl._close_upgrades)
	assert_true(sl._upgrades_menu.over_rating_limit(), "setup: full power busts the stand-in ceiling")
	assert_false(sl._upgrades_menu.can_close(), "the close button blocks while over the ceiling")
	assert_true(String(sl._upgrades_back.text).begins_with("Over limit"),
		"the close button paints as blocked")
	# Detune under the cap: the gate clears with no challenge-specific mechanism.
	sl._upgrades_menu._apply_detune(25.0, id)
	assert_false(sl._upgrades_menu.over_rating_limit(), "detuning under the ceiling clears the gate")
	assert_true(sl._upgrades_menu.can_close(), "proceeding is allowed once under the ceiling")
	assert_false(String(sl._upgrades_back.text).begins_with("Over limit"),
		"the close button returns to its plain label")


# The pre-countdown menu lays its actions out in ONE horizontal row across the bottom,
# the same shape the garage row and lift hub use — stacked vertically these four ate most
# of a phone screen and covered the car the staging shot exists to show.
func test_the_action_row_is_horizontal_and_offers_a_way_out() -> void:
	var sl := _make(_leaders())
	var row: HBoxContainer = null
	for node in sl.find_children("*", "HBoxContainer", true, false):
		if (node as HBoxContainer).get_child_count() >= 4:
			row = node
			break
	assert_not_null(row, "the actions live in a single horizontal row")

	var labels: Array[String] = []
	for child in row.get_children():
		if child is Button:
			labels.append(String((child as Button).text).to_upper())
			assert_ne((child as Button).focus_mode, Control.FOCUS_NONE,
				"every action stays reachable by keyboard/gamepad")
	# EXIT is the only way off the start line now that pause is suppressed here.
	var joined := " | ".join(labels)
	assert_true(joined.contains("EXIT"),
		"an Exit action is offered (pause is disabled while staged) — got %s" % joined)
	assert_true(joined.contains("START"), "and Start — got %s" % joined)


# The row must FIT. UITheme.button pins a 180-unit width floor, which is right for a
# stacked column but not for four buttons side by side — 4 x 180 plus gaps needs ~750
# logical units against a canvas ~556 wide (~445 on the web-touch tier), so the row ran
# off both edges and the outer buttons were unreachable. Asserts the relationship (the
# row's minimum fits the canvas), never a pixel width.
func test_the_action_row_fits_across_the_screen() -> void:
	var sl := _make(_leaders())
	var row: HBoxContainer = null
	for node in sl.find_children("*", "HBoxContainer", true, false):
		if (node as HBoxContainer).get_child_count() >= 4:
			row = node
			break
	assert_not_null(row, "setup: found the action row")
	for child in row.get_children():
		if child is Button:
			assert_lt((child as Button).custom_minimum_size.x, float(UITheme.BUTTON_MIN_W),
				"button '%s' must not carry the stacked-column width floor" % (child as Button).text)
	var needed := row.get_combined_minimum_size().x
	assert_lt(needed, float(DisplayStretch.DESIGN_HEIGHT) * 16.0 / 9.0,
		"the whole row fits a 16:9 canvas at the design height (needs %.0f)" % needed)


# --- Re-staging the grid after a start-line build change ---------------------

func test_restaging_replaces_the_grid_with_the_current_field() -> void:
	# The bug this guards: the grid props are spawned ONCE from `_leaders` when the start
	# line is built, but the field is matched to the player's rating and the player can
	# edit upgrades while standing on it. Without a re-stage, a re-drawn field would leave
	# the OLD cars parked in front of the player — the grid lying about who they are racing.
	var owned: Dictionary = _save.grant_car("fx_light_rwd")
	_save.set_selected_car(int(owned["instance_id"]))
	RallySession.start_rally(_rally(), owned, true)
	# Field the start line with a deliberately WRONG leader set, so a successful re-stage
	# is visible as the grid changing to the session's real one.
	var sl := _make(_leaders())
	var stale := sl.queue_car_ids().duplicate()

	sl._restage_grid()

	var want: Array[String] = []
	for row in RallySession.current_event_leaders():
		want.append(String((row as Dictionary).get("car_id", "")))
	assert_eq(sl.queue_car_ids(), want, "the grid now shows the session's current field")
	assert_ne(sl.queue_car_ids(), stale, "and is no longer the field it was built with")
	assert_eq(sl._grid.back(), _player, "the player survives the re-stage as the grid tail")


func test_restaging_does_not_leave_the_old_props_on_the_grid() -> void:
	# remove_child before queue_free: the free is deferred, so a bare queue_free would
	# leave the outgoing car clipping through its replacement for a frame.
	var owned: Dictionary = _save.grant_car("fx_light_rwd")
	_save.set_selected_car(int(owned["instance_id"]))
	RallySession.start_rally(_rally(), owned, true)
	var sl := _make(_leaders())
	var before: Array[Node] = []
	for car in sl._grid:
		if car != _player:
			before.append(car)

	sl._restage_grid()

	for car in before:
		assert_false(is_instance_valid(car) and sl.is_ancestor_of(car),
			"an outgoing prop is out of the tree immediately, not at end-of-frame")
