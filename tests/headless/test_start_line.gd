extends GutTest
# StartLine: the cinematic pre-event start-line sequence — a MENU (Start / Tune /
# Upgrades) over an orbit idle, then the fade → countdown once the player launches.
# The timed phases are driven by calling _process(dt) directly against stub
# car/stage/camera stubs, so the sequence is tested without booting the run scene.
# See features/start-line.md.
#
# The per-opponent FLY_IN + REVEAL (the three real top rivals queued ahead in their
# actual cars, one Next press each) died with the rival field in the pivot, but its
# SHAPE is revived for the one rival the roguelike kept: the ghost parks ON THE GRID
# ahead of the player, the MENU orbits until Start, Start flies the camera to a low
# 3/4 shot in front of the rival (Seq is MENU / FLY_IN / REVEAL / DEPART / FADE_OUT /
# FADE_IN / DONE), the rival card — driver, car, time to beat — appears only when the
# fly lands, and a second Start SENDS THE RIVAL OFF: the countdown waits until it has
# driven away (DEPART). `setup()` still takes no `leaders` argument; the grid is one
# parked ghost, not a field.


# Records the launch hand-off (StartLine -> StageManager.begin_countdown()).
class StubStage:
	extends Node
	var begin_calls := 0
	func begin_countdown() -> void:
		begin_calls += 1


# Stand-in for the fielded player Car — a VehicleBody3D (so the staging lock, gated on
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


# Records pose_at_distance() calls without touching RivalGhost's real track machinery
# (TrackProgress sampling is heavier than this file's stubs elsewhere want) — enough
# to prove StartLine parks whatever ghost world.gd hands it ON THE GRID and then
# leaves it alone (features/rival-ghost.md). car() hands back a bare Node3D so the
# reveal's camera anchor has a transform to frame; give_car = false models the
# neutral-baseline ghost (no pickable roster car), whose reveal has no fly.
class StubGhost:
	extends RivalGhost
	var pose_distance_calls: Array = []
	var give_car := true
	var _stub_car: Node3D = null
	func pose_at_distance(s_m: float) -> void:
		pose_distance_calls.append(s_m)
	func car() -> Node3D:
		if give_car and _stub_car == null:
			_stub_car = Node3D.new()
			add_child(_stub_car)
		return _stub_car
	# The send-off hands the real ghost's body to the physics server and then MEASURES
	# how far it actually got (features/rival-ghost.md); there is no body here, so the
	# stub records the handover and rolls the distance on at a fixed pace instead — the
	# contract StartLine depends on is "begin, then drive_departure returns a growing
	# distance", not how the metres are produced.
	const STUB_DEPART_SPEED := 10.0
	var live_departures: Array = []
	var _stub_s := 0.0
	func begin_live_departure(s_m: float) -> void:
		live_departures.append(s_m)
		_stub_s = s_m
	func drive_departure(delta: float) -> float:
		if live_departures.is_empty():
			return _stub_s
		_stub_s += STUB_DEPART_SPEED * delta
		return _stub_s
	var departed_at: Array = []
	func mark_departed_at(s_m: float) -> void:
		departed_at.append(s_m)
		super.mark_departed_at(s_m)


# A profiled ghost ready for the reveal path, with the driver name the card tests pin.
func _ghost_for_reveal(with_car := true) -> StubGhost:
	var ghost := StubGhost.new()
	add_child_autofree(ghost)
	ghost._profile = {"s": PackedFloat32Array([0.0, 10.0]), "t": PackedFloat32Array([0.0, 9.5])}
	ghost._car_index = 0 if with_car else -1
	ghost._rival_name = "R. Ostmeyer"
	ghost.give_car = with_car
	return ghost


# Wire a StartLine around a pre-built ghost and drive it from setup through Start +
# the (shrunk) fly into REVEAL — the "camera arrives at the rival" moment.
func _revealed_sl(ghost: StubGhost) -> StartLine:
	Config.data.start_reveal_fly_seconds = 0.01
	var sl := StartLine.new()
	add_child_autofree(sl)
	sl.set_process(false)
	sl.setup(_player, null, _stage, _rally(), 0, _cam_mgr, _hud, null, null, ghost)
	sl.launch()               # Start: the orbit freezes and the fly begins
	sl._process(0.1)          # past the (shrunk) fly -> REVEAL (or straight there, no car)
	return sl


const TEST_PATH := "user://test_start_line_profile.json"
# For the few tests that need a REAL fielded player car rather than StubPlayer — the
# config-identity contract is about the object car.gd holds, which a stub has no notion of.
const CAR_SCENE := preload("res://car.tscn")
const CarFixtures = preload("res://tests/headless/car_fixtures.gd")

var _player: StubPlayer
var _stage: StubStage
var _chase: Camera3D
var _bonnet: Camera3D
var _cam_mgr: CameraManager
var _hud: CanvasLayer
var _save: Node


func before_each() -> void:
	Config.reset()
	CarFixtures.install()
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
	if RunSession.is_active():
		RunSession.pause_run()
	RunSession.auto_load_scenes = true
	Config.reset()
	CarFixtures.restore()
	_save.profile_path = _save.DEFAULT_PROFILE_PATH
	for suffix in ["", ".bak", ".tmp"]:
		if FileAccess.file_exists(TEST_PATH + suffix):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_PATH + suffix))


# A stand-in stage set with an event count for the subtitle.
func _rally() -> Dictionary:
	return {"name": "Fixture Open", "events": [{}, {}, {}]}


func _make(event_index := 0) -> StartLine:
	var sl := StartLine.new()
	add_child_autofree(sl)
	sl.set_process(false)  # drive the sequence manually for deterministic timing
	sl.setup(_player, null, _stage, _rally(), event_index, _cam_mgr, _hud)
	return sl


# Grant, select and field a car through a Daily challenge run, so
# DrivingContext.driven_car() resolves it — the only session StartLine stages for now
# that RallySession is deleted (todo/roguelike-pivot.md decision 5). Returns the
# owned-car dict.
func _start_session_car() -> Dictionary:
	var owned: Dictionary = _save.grant_car("fx_light_rwd")
	RunSession.auto_load_scenes = false
	assert_true(RunSession.start(ChallengeLibrary.DAILY, owned,
		int(Time.get_unix_time_from_system())), "setup: the session car is fielded")
	return owned


# A rally with a fielded player car (turbo/config-identity tests need a REAL Car node,
# not StubPlayer — see CAR_SCENE above).
func test_a_turbo_fitted_at_the_start_line_reaches_the_config_the_hud_reads() -> void:
	var owned := {"model_id": "fx_light_rwd", "installed_upgrades": [], "disabled_upgrades": [],
		"tuning": {}, "instance_id": -1}
	var car := CAR_SCENE.instantiate()
	add_child_autofree(car)
	await get_tree().physics_frame  # _ready(): builds the drivetrain and takes Config.data
	car.apply_owned(owned)          # fielded like world.gd does it (no isolated config)
	var sl := StartLine.new()
	add_child_autofree(sl)
	sl.set_process(false)
	sl.setup(car, null, _stage, _rally(), 0, _cam_mgr, _hud)
	assert_false(Config.data.has_forced_induction(), "setup: the fielded car starts unboosted")

	# Granting a boost MID-RUN and refitting is exactly what stage 5's between-stage boost
	# pick does, so this stays pinned — only the seam moved from installed_upgrades to
	# `boosts` when the persistent parts model was deleted.
	owned["boosts"] = UpgradeFixtures.boosts(["fx_turbo_small"])
	car.refit_upgrades(owned)

	assert_true(car.config.has_forced_induction(), "the refit applied the boost to the car's config")
	assert_true(Config.data.has_forced_induction(),
		"…and the HUD reads that same config, so the boost gauge appears without a new stage")


func test_start_line_car_spawns_a_clearance_above_the_road() -> void:
	var terrain := StubTerrain.new()
	add_child_autofree(terrain)
	var sl := StartLine.new()
	add_child_autofree(sl)
	sl.set_process(false)
	sl.setup(_player, terrain, _stage, _rally(), 0, _cam_mgr, _hud)
	var seated := StubTerrain.GROUND_Y + Config.data.start_spawn_clearance
	assert_almost_eq(sl._start_xform.origin.y, seated, 0.001,
		"the start pose (countdown / reset target) sits a clearance above the road")
	assert_almost_eq(_player.global_position.y, seated, 0.001,
		"the staged player is seated a clearance above the ground")


func test_the_player_stages_one_slot_behind_the_rival_on_the_line() -> void:
	# The pre-pivot grid order: the rival owns the start line, the player queues one
	# grid gap behind it — and the hand-off (under the fade) snaps the player UP ONTO
	# the line for the countdown.
	var terrain := StubTerrain.new()
	add_child_autofree(terrain)
	var ghost := _ghost_for_reveal()
	var sl := StartLine.new()
	add_child_autofree(sl)
	sl.set_process(false)
	sl.setup(_player, terrain, _stage, _rally(), 0, _cam_mgr, _hud, null, null, ghost)
	var slot: Vector3 = sl._start_xform.origin \
			+ sl._start_xform.basis * Vector3(0.0, 0.0, Config.data.start_queue_gap)
	assert_almost_eq(_player.global_position.distance_to(slot), 0.0, 0.001,
			"the staged pose is one queue gap BEHIND the line (local +Z)")
	assert_gt(_player.global_position.distance_to(sl._start_xform.origin), 1.0,
			"the player is not staged ON the line — the rival is")


# The restored DEPART shuffle (pre-pivot _roll_grid_to_slots): as the rival drives
# off, the staged player is scripted forward off its queue slot — ai_throttle pinned
# while well behind, braking onto the line once there — so the pose the player
# WATCHED is the pose control resumes from, and the handoff's square-up is a
# correction rather than a hidden teleport. StubPlayer has no driving script, so
# this pins the scripting state machine and the end pose, not the live-body motion.
func test_depart_scripts_the_staged_player_up_toward_the_line() -> void:
	var ghost := _ghost_for_reveal()
	var sl := _revealed_sl(ghost)
	assert_eq(sl.sequence_phase(), StartLine.Seq.REVEAL, "setup: on the rival")
	sl.launch()
	assert_eq(sl.sequence_phase(), StartLine.Seq.DEPART, "setup: the rival is off")
	assert_eq(_player.ai_throttle, 0.0, "setup: the staged player sits idle")
	sl._process(0.1)
	assert_eq(_player.ai_throttle, 1.0,
			"DEPART scripts the player rolling up from its queue slot")
	assert_false(_player.ai_handbrake, "no hold while there is road to make up")


func test_the_roll_up_brakes_onto_the_line_instead_of_coasting_past() -> void:
	var ghost := _ghost_for_reveal()
	var sl := _revealed_sl(ghost)
	sl.launch()
	# Put the stub ON the line (a live body would have rolled there): at the target
	# at rest, _roll_car_to must hold on the handbrake with throttle cut.
	_player.global_position = sl._start_xform.origin
	sl._roll_player_up()
	assert_eq(_player.ai_throttle, 0.0, "throttle cut once at the line")
	assert_true(_player.ai_handbrake, "braked to a stop ON the slot, not coasting past")


func test_the_handoff_squares_the_player_up_onto_the_line() -> void:
	var ghost := _ghost_for_reveal()
	var sl := _revealed_sl(ghost)
	sl.launch()
	for i in 400:
		if sl.sequence_phase() != StartLine.Seq.DEPART:
			break
		sl._process(0.1)
	sl._process(Config.data.start_fade_seconds + 0.01)  # full black -> handoff
	assert_almost_eq(_player.global_position.distance_to(sl._start_xform.origin), 0.0, 0.001,
			"control resumes from the line the player rolled up onto")


# A REAL car can spin, stall or hit something on the way off the line, where the old
# posed send-off could only ever arrive. The phase is therefore bounded: a rival that
# never reaches the away mark still hands the screen on, so a bad launch can never
# strand the player on the start line with no countdown and no way out.
func test_a_rival_that_never_gets_away_still_ends_the_departure() -> void:
	Config.data.start_lead_in_ahead_m = 500.0  # unreachable within the timeout
	var ghost := _ghost_for_reveal()
	var sl := _revealed_sl(ghost)
	sl.launch()
	assert_eq(sl.sequence_phase(), StartLine.Seq.DEPART, "setup: the send-off is running")
	var timeout: float = Config.data.start_depart_timeout_seconds
	sl._process(timeout * 0.5)
	assert_eq(sl.sequence_phase(), StartLine.Seq.DEPART,
			"it waits for the rival while there is still time on the bound")
	sl._process(timeout * 0.5 + 0.01)
	assert_eq(sl.sequence_phase(), StartLine.Seq.FADE_OUT,
			"but the phase ends on the bound rather than waiting forever")
	assert_eq(ghost.departed_at.size(), 1,
			"and the ghost is still told where it was left, so the re-entry gate is armed")


# --- MENU / camera -----------------------------------------------------------

func test_menu_hides_hud_and_takes_the_camera() -> void:
	var sl := _make()
	assert_false(_hud.visible, "the driving HUD is hidden during the sequence")
	assert_true(sl._orbit_cam.current, "the start-line camera takes over from the chase camera")
	assert_eq(sl.sequence_phase(), StartLine.Seq.MENU, "it waits in the MENU phase")


# --- Rival ghost + the revived reveal (features/rival-ghost.md) ---------------

func test_setup_parks_the_rival_on_the_grid_and_leaves_it_there() -> void:
	var ghost := _ghost_for_reveal()
	var sl := StartLine.new()
	add_child_autofree(sl)
	sl.set_process(false)
	sl.setup(_player, null, _stage, _rally(), 0, _cam_mgr, _hud, null, null, ghost)
	assert_eq(ghost.pose_distance_calls, [0.0],
			"setup poses the rival ON the line — the pre-pivot grid's front slot")
	for i in 12:
		sl._process(0.1)
	assert_eq(ghost.pose_distance_calls.size(), 1,
			"the MENU orbit never re-poses the ghost — it holds its grid slot")
	assert_eq(sl.sequence_phase(), StartLine.Seq.MENU,
			"the MENU orbits the player until Start is pressed — nothing auto-flies")


func test_no_ghost_is_a_harmless_no_op() -> void:
	var sl := _make()  # no ghost handed in (the default null) — a challenge stage, e.g.
	sl._process(0.1)
	assert_eq(sl.sequence_phase(), StartLine.Seq.MENU, "the MENU idle runs fine with no ghost at all")


# --- Rival card + the reveal that shows it (features/start-line.md, rival-ghost.md)
# The deleted per-opponent reveal card's revival, trimmed to the one ghost rival:
# driver name, worn car, gold time to beat — shown only when the fly lands, never
# during the menu idle, and no card at all with no ghost.

func test_the_rival_card_names_the_driver_car_and_time_to_beat() -> void:
	var ghost := _ghost_for_reveal()
	var sl := StartLine.new()
	add_child_autofree(sl)
	sl.set_process(false)
	Config.data.start_reveal_fly_seconds = 0.01
	sl.setup(_player, null, _stage, _rally(), 0, _cam_mgr, _hud, null, null, ghost)
	assert_false(sl.rival_card_visible(), "the card waits for the reveal — not the whole menu")
	sl.launch()
	assert_eq(sl.sequence_phase(), StartLine.Seq.FLY_IN, "Start flies the camera to the rival")
	sl._process(0.1)  # past the (shrunk) fly
	assert_eq(sl.sequence_phase(), StartLine.Seq.REVEAL, "the fly lands in the reveal")
	assert_true(sl.rival_card_visible(), "only now does the card show")
	# The house enforce pass uppercases every Label's text (rules §1), so the card
	# shows the caps form — compare against UITheme.caps, not the raw source string.
	assert_eq(sl.rival_card_name(), UITheme.caps("R. Ostmeyer"), "the driver's name is on the card")
	assert_eq(sl.rival_card_car(), UITheme.caps(String(CarLibrary.all()[0].get("name", ""))),
			"the card names the car the rival wears")
	assert_eq(sl.rival_card_time(), UITheme.format_time(9500, "\u2014"),
			"the gold row shows the profile's own total, formatted like the HUD clock")


func test_the_rival_card_hides_without_a_ghost() -> void:
	var sl := _make()  # no ghost handed in — a challenge stage, e.g.
	assert_false(sl.rival_card_visible(), "no ghost, no rival card")
	assert_eq(sl.rival_card_time(), "", "and no time to beat either")
	for i in 20:
		sl._process(0.1)
	assert_eq(sl.sequence_phase(), StartLine.Seq.MENU, "no rival, no auto-fly — the menu just idles")
	assert_false(sl.rival_card_visible(), "and no card ever appears")


func test_the_rival_card_hides_the_car_line_for_the_neutral_baseline() -> void:
	# A ghost with a target but no pickable car (car_index -1, car() invalid) shows
	# the time but no bogus model name — the baseline body is not a car in the
	# roster, and there is nothing to fly the camera to either.
	var ghost := _ghost_for_reveal(false)
	var sl := StartLine.new()
	add_child_autofree(sl)
	sl.set_process(false)
	Config.data.start_reveal_fly_seconds = 0.01
	sl.setup(_player, null, _stage, _rally(), 0, _cam_mgr, _hud, null, null, ghost)
	sl.launch()              # Start, but no car to frame
	assert_eq(sl.sequence_phase(), StartLine.Seq.REVEAL,
			"no car to frame: the card shows without the fly")
	assert_true(sl.rival_card_visible(), "the time to beat still shows")
	assert_eq(sl.rival_card_car(), "", "no roster car, no car line")


func test_the_menu_orbits_until_start_is_pressed() -> void:
	var ghost := _ghost_for_reveal()
	var sl := StartLine.new()
	add_child_autofree(sl)
	sl.set_process(false)
	sl.setup(_player, null, _stage, _rally(), 0, _cam_mgr, _hud, null, null, ghost)
	for i in 20:
		sl._process(0.1)
	assert_eq(sl.sequence_phase(), StartLine.Seq.MENU,
			"the orbit idles on the player until Start — no idle timer auto-flies")
	assert_false(sl.rival_card_visible(), "and the card stays hidden while it orbits")


func test_start_from_the_reveal_sends_the_rival_off_before_the_countdown() -> void:
	# The send-off: Start from the REVEAL drives the rival off down the lead-in
	# (DEPART), and only once it is properly away does the fade (then the countdown)
	# begin — the player never sees the countdown before the rival has left.
	Config.data.start_lead_in_ahead_m = 3.0  # a short lead-in keeps the drive-off quick
	var ghost := _ghost_for_reveal()
	var sl := _revealed_sl(ghost)
	assert_eq(sl.sequence_phase(), StartLine.Seq.REVEAL, "setup: parked on the rival")
	sl.launch()
	assert_true(sl.has_launched(), "Start from the reveal passes the gates")
	assert_eq(sl.sequence_phase(), StartLine.Seq.DEPART, "and sends the rival off, not the fade")
	assert_eq(ghost.live_departures, [0.0],
			"the send-off hands the ghost's body to the physics server from the line — "
			+ "the drive-off is a REAL car, not a posed one (features/rival-ghost.md)")
	var posed_at_launch := ghost.pose_distance_calls.size()
	sl._process(0.1)
	assert_eq(ghost.pose_distance_calls.size(), posed_at_launch,
			"and nothing poses it afterwards — the simulation owns the body now")
	assert_lt(sl._depart_s, Config.data.start_lead_in_ahead_m,
			"mid-departure the rival is still short of the away mark")
	assert_eq(_stage.begin_calls, 0, "no countdown while the rival is still on the road")

	# Wait out the drive-off (the stub rolls the measured distance on per frame).
	for i in 300:
		if sl.sequence_phase() != StartLine.Seq.DEPART:
			break
		sl._process(0.1)
	assert_gt(ghost._reentry_s, 0.0, "the completed departure armed the ghost's re-entry gate")
	assert_eq(sl.sequence_phase(), StartLine.Seq.FADE_OUT, "once properly away, the fade begins")
	sl._process(Config.data.start_fade_seconds + 0.01)
	assert_eq(_stage.begin_calls, 1, "and only at full black does the countdown start")


func test_start_overlay_uses_the_house_button_row_height() -> void:
	var sl := _make()
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
	var sl := _make()
	await get_tree().process_frame  # let MenuNav's deferred initial grab land first
	get_viewport().gui_release_focus()
	assert_null(get_viewport().gui_get_focus_owner(), "focus is cleared, simulating the popup teardown")
	sl.grab_start_focus()
	assert_true(sl._start_button.has_focus(), "focus lands back on Start")


func test_active_instance_is_set_while_the_sequence_is_live() -> void:
	var sl := _make()
	assert_eq(StartLine.active_instance, sl, "setup() seats itself as the live instance")
	sl.free()
	await get_tree().process_frame
	assert_null(StartLine.active_instance, "freeing the instance clears the static ref")


# --- Launch → fade → countdown ------------------------------------------------
# There is no rival field left to reveal (decision 5), so Start goes straight from
# MENU to the fade — the same "no opponents" path the old empty-leaders harness used
# to exercise, now the only path there is.

func test_launch_goes_straight_to_the_fade_and_starts_the_countdown() -> void:
	var sl := _make()
	sl.launch()
	assert_true(sl.has_launched(), "launching flips the launched flag")
	assert_eq(sl.sequence_phase(), StartLine.Seq.FADE_OUT, "Start goes straight to the fade")
	assert_false(sl._overlay.visible, "the MENU overlay hides on launch")
	assert_eq(_stage.begin_calls, 0, "the countdown does NOT start until the fade completes")
	sl._process(Config.data.start_fade_seconds + 0.01)
	assert_eq(_stage.begin_calls, 1, "the countdown starts at full black")
	assert_true(_chase.current, "the chase camera is handed control back")
	assert_false(sl._orbit_cam.current, "the start-line camera releases control")
	assert_true(_hud.visible, "the driving UI returns")


func test_launch_is_idempotent() -> void:
	var sl := _make()
	sl.launch()
	assert_eq(sl.sequence_phase(), StartLine.Seq.FADE_OUT, "launch begins the fade")
	sl.launch()  # a stray second press must not restart anything
	assert_eq(sl.sequence_phase(), StartLine.Seq.FADE_OUT, "a second launch is ignored")


func test_handoff_releases_the_player_to_normal_driving() -> void:
	var sl := _make()
	sl.launch()
	sl._process(Config.data.start_fade_seconds + 0.01)
	assert_false(_player.ai_controlled, "the player is handed back to normal driving")
	assert_false(_player.axis_lock_linear_x, "lateral lock released so the player can steer")
	assert_false(_player.axis_lock_angular_y, "yaw lock released for the run")


func test_hand_off_restores_the_selected_camera_not_always_chase() -> void:
	_cam_mgr.set_mode(CameraManager.Mode.BONNET)
	var sl := _make()
	sl.launch()
	sl._process(Config.data.start_fade_seconds + 0.01)
	assert_true(_bonnet.current, "the selected (bonnet) camera is restored at hand-off")
	assert_false(_chase.current, "the start line does not force chase over the chosen mode")


# The eligibility gate (RallyLibrary.ineligibility_reason) is deleted
# (todo/region-stage-slots-redesign.md) — world.gd never handed StartLine a rally
# dict with a real `restriction` field, so the gate was a permanent no-op. launch()
# is unconditional now; see the sequence-progression tests elsewhere in this file.


# --- Pre-race menus (unchanged behaviour) ------------------------------------

# NOTE: five tests covering the start line's UPGRADES button lived here. Decision 29
# leaves the start line offering Tune Car ONLY -- upgrades have nothing to show once the
# persistent parts model is gone and boosts are picked between stages instead. The TUNE
# half, the fade, and the challenge car-binding tests below are untouched.


func test_tune_overlay_opens_and_back_returns_to_the_start_overlay() -> void:
	_start_session_car()
	var sl := _make()
	sl._open_tune()
	assert_true(sl._tune_layer.visible, "opening Tune Car shows the tuning overlay")
	assert_false(sl._overlay.visible, "the start overlay hides while tuning")
	sl._close_tune()
	assert_true(sl._overlay.visible, "Back restores the start overlay")
	assert_false(sl._tune_layer.visible, "Back hides the tuning overlay")


func test_start_line_tune_uses_retune_and_preserves_the_staged_pose() -> void:
	var owned := _start_session_car()
	var sl := _make()
	var pose_before: Transform3D = _player.global_transform
	sl._open_tune()
	sl._on_tune_changed(owned)
	assert_gt(_player.retune_calls, 0, "the tune routes through the live-safe retune path")
	assert_false(_player.applied_owned,
		"it must NOT re-field via apply_owned (that relocates wheels + resets the pose)")
	assert_eq(_player.global_transform, pose_before, "the staged pose is preserved across a tune")


func _challenge_rally() -> Dictionary:
	return {"name": "Daily Challenge", "restriction": {}}


# Start a real Daily challenge run on a freshly granted fixture car and return it.
func _start_challenge() -> Dictionary:
	var owned: Dictionary = _save.grant_car("fx_light_rwd")
	RunSession.auto_load_scenes = false
	assert_true(RunSession.start(ChallengeLibrary.DAILY, owned,
		int(Time.get_unix_time_from_system())), "setup: the challenge run starts")
	return owned


func _make_challenge() -> StartLine:
	var sl := StartLine.new()
	add_child_autofree(sl)
	sl.set_process(false)
	sl.setup(_player, null, _stage, _challenge_rally(), RunSession.events_completed(),
		_cam_mgr, _hud)
	return sl


# The binding rule survives the Upgrades button's deletion: whatever the start line opens
# must bind to the RUN's locked car, not to whatever the garage last selected. Tune is the
# only such menu now (decision 29), so it carries the assertion.
func test_challenge_menus_bind_to_the_challenge_car_not_the_rally_one() -> void:
	var owned := _start_challenge()
	var sl := _make_challenge()
	sl._open_tune()
	var want := int(owned["instance_id"])
	assert_eq(int(sl._tune_panel._owned.get("instance_id", -1)), want,
		"the Tune Car panel is bound to the challenge's locked car")
	assert_eq(int(sl._driven_car().get("instance_id", -1)), want,
		"the shared driven-car resolver answers with the challenge car")


func test_challenge_fades_straight_to_the_countdown() -> void:
	_start_challenge()
	var sl := _make_challenge()
	sl.launch()
	assert_true(sl.has_launched(), "Start launches (the eligible locked car passes the gate)")
	assert_eq(sl.sequence_phase(), StartLine.Seq.FADE_OUT, "Start fades straight out")
	sl._process(Config.data.start_fade_seconds + 0.01)
	assert_eq(_stage.begin_calls, 1, "the countdown starts")


func test_challenge_header_counts_the_runs_own_stages() -> void:
	# A challenge has no authored event list, so the "Stage N of M" header falls back to
	# the active run's stage count rather than a rally's fixed events-per-rally.
	_start_challenge()
	var sl := _make_challenge()
	assert_eq(sl._stage_total(_challenge_rally()), RunSession.stage_count(),
		"the stage total comes from the challenge run")
	assert_string_contains(sl._subtitle_label.text.to_upper(), "STAGE 1 OF %d" % RunSession.stage_count())


# --- The pre-race performance ceiling goes through DrivingContext ---------------
#
# _rating_limit() no longer digs the restriction out of the event dict itself — it asks
# DrivingContext, which answers for whichever session is fielding the car. These
# tests cover the CHALLENGE branch, the only place a performance ceiling still exists —
# rally entry is purely categorical, with no gate at all.

func test_challenge_rating_limit_comes_from_the_periods_ceiling() -> void:
	_start_challenge()
	var sl := _make_challenge()
	# Derived from the same accessor chain the code under test uses — no band value
	# is pinned (CEILING_BAND_HP_TONNE is authored/tunable).
	assert_eq(sl._rating_limit(), ChallengeLibrary.ceiling_for(RunSession.period_key()),
		"a challenge's pre-race ceiling is its period's rolled cap")
	assert_ne(sl._rating_limit(), DrivingContext.NO_LIMIT,
		"a real ceiling applies during a challenge — not the silent 'no limit' fallback")


func test_the_action_row_is_horizontal_and_offers_a_way_out() -> void:
	var sl := _make()
	# Find the row by what it CONTAINS (buttons), not by a child count — the count
	# changed when decision 29 dropped the Upgrades action, and pinning it just makes
	# this test break again the next time an action is added or removed.
	var row: HBoxContainer = null
	for node in sl.find_children("*", "HBoxContainer", true, false):
		for child in (node as HBoxContainer).get_children():
			if child is Button:
				row = node
				break
		if row != null:
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
	var sl := _make()
	var row: HBoxContainer = null
	for node in sl.find_children("*", "HBoxContainer", true, false):
		for child in (node as HBoxContainer).get_children():
			if child is Button:
				row = node
				break
		if row != null:
			break
	assert_not_null(row, "setup: found the action row")
	for child in row.get_children():
		if child is Button:
			assert_lt((child as Button).custom_minimum_size.x, float(UITheme.BUTTON_MIN_W),
				"button '%s' must not carry the stacked-column width floor" % (child as Button).text)
	var needed := row.get_combined_minimum_size().x
	assert_lt(needed, float(DisplayStretch.DESIGN_HEIGHT) * 16.0 / 9.0,
		"the whole row fits a 16:9 canvas at the design height (needs %.0f)" % needed)
