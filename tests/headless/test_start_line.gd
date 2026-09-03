extends GutTest
# StartLine: the cinematic pre-event start-line sequence — a MENU (Start / Tune /
# Upgrades) over an orbit idle, then the fade → countdown once the player launches.
# The timed phases are driven by calling _process(dt) directly against stub
# car/stage/camera stubs, so the sequence is tested without booting the run scene.
# See features/start-line.md.
#
# A per-opponent FLY_IN + REVEAL phase (the three real top rivals lined up ahead in
# their actual cars) used to sit between MENU and the fade. Deleted along with the
# rival field it dramatized (todo/roguelike-pivot.md decision 5) — decision 29 keeps
# this MENU, only the reveal goes. `setup()` no longer takes a `leaders` argument, and
# `Seq` is just MENU / FADE_OUT / FADE_IN / DONE.


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
	if ChallengeSession.is_active():
		ChallengeSession.abandon()
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
	_save.set_selected_car(int(owned["instance_id"]))
	ChallengeSession.auto_load_scenes = false
	assert_true(ChallengeSession.start(ChallengeLibrary.DAILY, owned,
		int(Time.get_unix_time_from_system())), "setup: the session car is fielded")
	return owned


# A rally with a fielded player car (turbo/config-identity tests need a REAL Car node,
# not StubPlayer — see CAR_SCENE above).
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
	sl.setup(car, null, _stage, _rally(), 0, _cam_mgr, _hud)
	assert_false(Config.data.has_forced_induction(), "setup: the fielded car starts unboosted")

	owned["installed_upgrades"] = ["fx_turbo_small"]
	car.refit_upgrades(owned)

	assert_true(car.config.has_forced_induction(), "the refit fitted the part to the car's config")
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


# --- MENU / camera -----------------------------------------------------------

func test_menu_hides_hud_and_takes_the_camera() -> void:
	var sl := _make()
	assert_false(_hud.visible, "the driving HUD is hidden during the sequence")
	assert_true(sl._orbit_cam.current, "the start-line camera takes over from the chase camera")
	assert_eq(sl.sequence_phase(), StartLine.Seq.MENU, "it waits in the MENU phase")


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


# --- Eligibility gates (unchanged behaviour) ---------------------------------

func test_launch_is_gated_by_rally_eligibility() -> void:
	_start_session_car()
	var sl := _make()
	sl._rally = {"restriction": {"engine_min_l": 999.0}}
	sl.launch()
	assert_false(sl.has_launched(), "launch() is blocked when the fielded car is ineligible")
	assert_eq(sl.sequence_phase(), StartLine.Seq.MENU, "the sequence does not advance when blocked")


func test_launch_proceeds_when_the_car_is_eligible() -> void:
	_start_session_car()
	var sl := _make()
	sl._rally = {}  # open class: no restriction to fail
	sl.launch()
	assert_true(sl.has_launched(), "launch() proceeds when there is no eligibility gate to fail")


# --- Pre-race menus (unchanged behaviour) ------------------------------------

func test_start_overlay_has_focusable_tune_and_upgrades_buttons() -> void:
	var sl := _make()
	assert_eq(sl._tune_button.focus_mode, Control.FOCUS_ALL,
		"the Tune Car button is keyboard/gamepad focusable (MenuNav attached)")
	assert_eq(sl._upgrades_button.focus_mode, Control.FOCUS_ALL,
		"the Upgrades button is keyboard/gamepad focusable (MenuNav attached)")


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


func test_upgrades_overlay_opens_and_back_returns_to_the_start_overlay() -> void:
	_start_session_car()
	var sl := _make()
	sl._open_upgrades()
	assert_true(sl._upgrades_layer.visible, "opening Upgrades shows the upgrades overlay")
	assert_false(sl._overlay.visible, "the start overlay hides while upgrading")
	sl._close_upgrades()
	assert_true(sl._overlay.visible, "Back restores the start overlay")
	assert_false(sl._upgrades_layer.visible, "Back hides the upgrades overlay")


func test_upgrade_changed_refits_the_live_car() -> void:
	_start_session_car()
	var sl := _make()
	sl._on_upgrade_changed()
	assert_true(_player.refit_calls > 0, "an upgrade edit refits the live car's upgrade state")


# --- Challenge runs stage exactly like a rally event (features/rally-challenge.md) ---
#
# A Daily/Weekly/Monthly challenge stage gets the SAME pre-countdown screen a career
# rally event used to get — the same Upgrades / Tune Car overlays on the same shared
# components. There is no rival field to stage against (spec §3 — decision 5), so it
# always takes the plain launch-straight-to-fade path.

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
	sl.setup(_player, null, _stage, _challenge_rally(), ChallengeSession.events_completed(),
		_cam_mgr, _hud)
	return sl


func test_challenge_menus_bind_to_the_challenge_car_not_the_rally_one() -> void:
	var owned := _start_challenge()
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


func test_challenge_fades_straight_to_the_countdown() -> void:
	_start_challenge()
	var sl := _make_challenge()
	sl._rally = _challenge_rally()
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
	assert_eq(sl._stage_total(_challenge_rally()), ChallengeSession.stage_count(),
		"the stage total comes from the challenge run")
	assert_string_contains(sl._subtitle_label.text.to_upper(), "STAGE 1 OF %d" % ChallengeSession.stage_count())


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
	var sl := _make()
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
	var sl := _make()
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
