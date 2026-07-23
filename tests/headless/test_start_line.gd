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
	if RallySession.is_active():
		RallySession.abandon()
	Config.reset()
	CarFixtures.restore()
	RallyFixtures.restore()
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
	assert_string_contains(sl._subtitle_label.text, "EVENT 1 OF 3", "the event index is shown")


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


func test_over_powered_car_gets_change_upgrades_prompt_on_start() -> void:
	var owned: Dictionary = _save.grant_car("fx_light_rwd")
	_save.set_selected_car(int(owned["instance_id"]))
	RallySession.start_rally(_rally(), owned, true)
	var sl := _make(_leaders())
	var entry := CarLibrary.by_id(String(owned.get("model_id", "")))
	var pw := CarLibrary.power_to_weight(UpgradeLibrary.effective_meta(owned, entry)) * CarLibrary.KW_KG_TO_HP_TONNE
	sl._rally = {"restriction": {"pw_max": pw * 0.8}}
	sl.launch()
	assert_false(sl.has_launched(), "an over-powered car is blocked at Start")
	var popups := sl.find_children("*", "ConfirmPopup", true, false)
	assert_eq(popups.size(), 1, "the gate shows a ConfirmPopup")
	var offers_change := false
	var offers_detune := false
	for b in popups[0].find_children("*", "Button", true, false):
		var txt := (b as Button).text.to_lower()
		if "change upgrades" in txt:
			offers_change = true
		if "detune" in txt:
			offers_detune = true
	assert_true(offers_change, "the popup offers Change Upgrades")
	assert_false(offers_detune, "there is no one-press auto-detune button anymore")


func test_launch_proceeds_when_the_car_is_eligible() -> void:
	var owned: Dictionary = _save.grant_car("fx_light_rwd")
	_save.set_selected_car(int(owned["instance_id"]))
	RallySession.start_rally(_rally(), owned, true)
	var sl := _make(_leaders())
	sl._rally = {}  # open class: no restriction to fail
	sl.launch()
	assert_true(sl.has_launched(), "launch() proceeds when there is no eligibility gate to fail")


func test_under_band_car_cannot_start() -> void:
	# The p/w band floor is a HARD gate now: a car below the floor is INELIGIBLE, so launch
	# is blocked with a "Can't start" popup (the old non-blocking "start anyway" underpower
	# warning — which briefly moved to HQ car selection — is retired: there is no
	# eligible-but-underpowered state anymore).
	var owned: Dictionary = _save.grant_car("fx_light_rwd")
	_save.set_selected_car(int(owned["instance_id"]))
	RallySession.start_rally(_rally(), owned, true)
	var sl := _make(_leaders())
	var entry := CarLibrary.by_id(String(owned.get("model_id", "")))
	var pw := CarLibrary.power_to_weight(UpgradeLibrary.effective_meta(owned, entry)) * CarLibrary.KW_KG_TO_HP_TONNE
	# A band whose floor sits well above the car's p/w -> under-powered -> ineligible.
	sl._rally = {"restriction": {"pw_min": pw * 1.5}}
	sl.launch()
	assert_false(sl.has_launched(), "an under-floor (underpowered) car is ineligible and does not launch")
	var popups := sl.find_children("*", "ConfirmPopup", true, false)
	assert_eq(popups.size(), 1, "an ineligible car shows a Can't start popup")


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
