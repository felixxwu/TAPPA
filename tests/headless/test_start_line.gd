extends GutTest
# StartLine: the pre-event start-line sequence (time-to-beat reveal + orbit camera
# + start queue, then leader drives off / field scoots up / fade → countdown). The
# timed phases are driven by calling _process(dt) directly against stub
# car/stage-manager/camera/HUD, so the sequence is tested without booting the run
# scene. See todo/menus.md location 2 + scripts/start_line.gd.


# Records the launch hand-off (StartLine -> StageManager.begin_countdown()).
class StubStage:
	extends Node
	var begin_calls := 0
	func begin_countdown() -> void:
		begin_calls += 1


# Stand-in for the fielded player Car — a VehicleBody3D (so the roll-up staging,
# which is gated on `is VehicleBody3D` + the AI hook, runs) with just the hook
# properties and a minimal drivetrain for the gearbox-auto restore.
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
	# Records which fielding path the start-line tune takes: retune (live-safe) is
	# correct; apply_owned would relocate wheels + reset the pose and corrupt the body.
	var retune_calls := 0
	var applied_owned := false
	func retune(_owned: Dictionary) -> void:
		retune_calls += 1
	func apply_owned(_owned: Dictionary) -> String:
		applied_owned = true
		return ""


# A flat terrain stub at a raised elevation, so the spawn-clearance seating is testable
# (the real _make passes null terrain, which skips the height lookup).
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
	# A throwaway save profile so the camera mode the manager restores is deterministic
	# (a fresh profile has no camera_mode → defaults to chase) and the real profile is
	# left untouched.
	_save = get_node("/root/Save")
	_save.profile_path = TEST_PATH
	_save.save_disabled = false
	_save.load_or_new()
	_player = StubPlayer.new()
	add_child_autofree(_player)
	_stage = StubStage.new()
	add_child_autofree(_stage)
	# A real CameraManager (chase + bonnet) so the hand-off restores the player's
	# SELECTED camera — the start line no longer force-snaps to chase.
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
		RallySession.abandon()  # a test that started a rally must not leak the session
	Config.reset()
	CarFixtures.restore()
	_save.profile_path = _save.DEFAULT_PROFILE_PATH
	for suffix in ["", ".bak", ".tmp"]:
		if FileAccess.file_exists(TEST_PATH + suffix):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_PATH + suffix))


# RWD Masters: a real rally with an event count for the subtitle.
func _rally() -> Dictionary:
	return RallyLibrary.by_id("rwd_masters")


func _leaders() -> Array:
	return [
		{"name": "Rival 3", "car_name": "Porsche 911", "time_ms": 75430},  # 1:15.43, the leader
		{"name": "Rival 1", "car_name": "Dodge Viper RT/10", "time_ms": 78120},
		{"name": "Rival 7", "car_name": "Focus ST", "time_ms": 80050},
	]


func _make(leaders := [], event_index := 0) -> StartLine:
	var sl := StartLine.new()
	add_child_autofree(sl)
	sl.set_process(false)  # drive the sequence manually for deterministic timing
	sl.setup(_player, null, _stage, _rally(), event_index, leaders, _cam_mgr, _hud)
	return sl


func test_reveal_shows_top_three_times_to_beat_and_context() -> void:
	var sl := _make(_leaders(), 1)  # second event
	assert_eq(sl._leader_rows.size(), 3, "the reveal lists the top three rivals to beat")
	# Reveal text follows the design system: house rule 1 uppercases everything.
	var top := sl._leader_rows[0].text
	assert_string_contains(top, "1:15.43", "the leader's time to beat is shown (m:ss.cc)")
	assert_string_contains(top, "RIVAL 3", "the leader's driver name is shown")
	assert_string_contains(top, "PORSCHE 911", "the car the leader drove is shown")
	assert_string_contains(sl._leader_rows[2].text, "FOCUS ST", "third place's car is shown too")
	assert_string_contains(sl._subtitle_label.text, "RWD MASTERS", "the rally is named")
	assert_string_contains(sl._subtitle_label.text, "EVENT 2 OF 3", "the event index is shown")
	assert_eq(sl.sequence_phase(), StartLine.Seq.ORBIT, "it waits in the orbit/reveal phase")
	# The launch button is a standard house menu button at the one fixed row height
	# (not an oversized block).
	assert_eq(sl._start_button.custom_minimum_size.y, float(UITheme.MENU_ROW_H),
		"the Start button uses the fixed menu row height")


func test_missing_rival_times_show_dash() -> void:
	var sl := _make([])
	assert_eq(sl._leader_rows.size(), 1, "with no rival times there's a single placeholder row")
	assert_eq(sl._leader_rows[0].text, "—", "no classified rival times read as a dash")


func test_reveal_hides_hud_and_takes_the_camera() -> void:
	var sl := _make()
	assert_false(_hud.visible, "the driving HUD is hidden during the reveal")
	assert_true(sl._orbit_cam.current, "the orbit camera takes over for the reveal")


func test_queue_has_a_leader_and_a_trailer() -> void:
	var sl := _make()
	assert_eq(sl.queue_count(), 2, "the car is queued between a leader and a trailing car")


func test_queue_cars_are_eligible_for_the_rally() -> void:
	# The leader/trailer that bookend the player must be cars allowed in this rally
	# (RWD Masters fields only RWD cars inside its p/w band), not arbitrary ones.
	var sl := _make()
	var rally := _rally()
	for prop in [sl._leader, sl._trailer]:
		assert_not_null(prop, "the queue car spawned")
		var spec: Dictionary = CarLibrary.all()[prop._car_index]
		assert_true(RallyLibrary.is_eligible(rally, spec),
			"%s lining up is eligible for the rally" % spec["name"])


# Each queue prop's apply_car() mutates the SHARED global Config.data. The player
# is fielded BEFORE the queue spawns, so a prop leaking its gearbox into Config.data
# would corrupt the player's live gearing (its shift table is already built) — e.g.
# the auto box would then shift at the wrong revs. Regression: spawning the queue
# must leave the player's config (here a distinctive final_drive) untouched.
func test_queue_spawn_does_not_clobber_the_players_config() -> void:
	Config.data.final_drive = 7.77  # a sentinel no CarLibrary entry uses
	var sl := _make()
	assert_eq(sl.queue_count(), 2, "the queue actually spawned props (so the test isn't vacuous)")
	assert_almost_eq(Config.data.final_drive, 7.77, 0.001,
		"the player's final_drive survives the queue spawn (props don't leak into the shared config)")


func test_queue_cars_are_scripted_and_axis_locked() -> void:
	var sl := _make()
	var leader = sl._leader
	assert_true(leader.ai_controlled, "queue cars drive under scripted control, not player Input")
	assert_true(leader.axis_lock_linear_x, "lateral axis locked so they can't veer off line")
	assert_true(leader.axis_lock_angular_y, "yaw locked so they stay pointed straight")
	assert_false(leader.freeze, "they run live physics (suspension loads), not frozen")
	assert_eq(leader.ai_throttle, 0.0, "they idle on the parking brake until launch")


func test_launch_floors_the_leader() -> void:
	var sl := _make()
	sl.launch()
	assert_eq(sl._leader.ai_throttle, 1.0, "the leader floors it on launch so it pulls away")


func test_player_is_staged_behind_the_line_to_roll_up() -> void:
	var sl := _make()
	# Staged a full gap behind the line (local +Z, directly behind the leader which sits
	# on the line), scripted + axis-locked so it rolls straight up with the field instead
	# of sitting still and getting rear-ended.
	assert_true(_player.ai_controlled, "the player is scripted for the roll-up")
	assert_true(_player.axis_lock_linear_x, "player lateral locked during the roll-up")
	assert_true(_player.axis_lock_angular_y, "player yaw locked during the roll-up")
	assert_almost_eq(_player.global_position.z, Config.data.start_queue_gap, 0.01,
		"player staged a full gap behind the start line")


func test_start_line_cars_spawn_a_clearance_above_the_road() -> void:
	# The player and both queue cars are seated start_spawn_clearance above the road at
	# spawn so they settle onto their wheels instead of clipping into the ground. Uses a
	# raised flat terrain stub so the clearance is observable.
	var terrain := StubTerrain.new()
	add_child_autofree(terrain)
	var sl := StartLine.new()
	add_child_autofree(sl)
	sl.set_process(false)
	sl.setup(_player, terrain, _stage, _rally(), 0, [], _cam_mgr, _hud)
	var seated := StubTerrain.GROUND_Y + Config.data.start_spawn_clearance
	assert_almost_eq(sl._start_xform.origin.y, seated, 0.001,
		"the start pose (countdown / reset target) sits a clearance above the road")
	assert_almost_eq(_player.global_position.y, seated, 0.001,
		"the staged player is seated a clearance above the ground")
	assert_almost_eq(sl._leader.global_position.y, seated, 0.01,
		"the leader ahead spawns a clearance above the ground")
	assert_almost_eq(sl._trailer.global_position.y, seated, 0.01,
		"the trailer behind spawns a clearance above the ground")


func test_player_rolls_up_on_a_stagger_after_the_leader() -> void:
	var sl := _make()
	sl.launch()
	# Just after launch the player hasn't moved yet (it waits one stagger).
	assert_eq(_player.ai_throttle, 0.0, "player holds until its stagger")
	sl._process(Config.data.start_queue_stagger_seconds + 0.01)
	assert_eq(_player.ai_throttle, 1.0, "player rolls up once its stagger elapses")


func test_trailer_rolls_up_and_brakes_to_a_stop() -> void:
	var sl := _make()
	sl.launch()
	# The trailer holds on its parking brake until its (later) stagger.
	sl._process(Config.data.start_queue_stagger_seconds + 0.01)
	assert_eq(sl._trailer.ai_throttle, 0.0, "trailer holds until its stagger")
	# Once its stagger elapses it rolls up toward its slot a gap behind the line.
	sl._process(Config.data.start_queue_stagger_seconds + 0.01)
	assert_eq(sl._trailer.ai_throttle, 1.0, "trailer rolls up once its stagger elapses")
	# Reaching its slot while still rolling fast makes it brake (throttle -1.0), like
	# the player at the line, instead of coasting through and drifting.
	sl._trailer.global_position = sl._trailer_target
	sl._trailer.linear_velocity = Vector3(0, 0, -5)  # still moving well above the stop threshold
	sl._process(0.05)
	assert_eq(sl._trailer.ai_throttle, -1.0, "trailer brakes while still rolling into its slot")
	assert_true(sl._trailer.ai_handbrake, "trailer holds the brake to settle on its slot")
	# Once nearly stopped it drops to zero throttle (handbrake still on) rather than
	# holding the brake/gas axis — the auto box mustn't grab reverse and rev against
	# the handbrake as it settles.
	sl._trailer.linear_velocity = Vector3.ZERO
	sl._process(0.05)
	assert_eq(sl._trailer.ai_throttle, 0.0, "trailer cuts throttle once stopped (no reverse-gas rev)")
	assert_true(sl._trailer.ai_handbrake, "trailer holds on the handbrake once settled")


func test_fade_waits_for_the_player_to_come_to_a_stop() -> void:
	var sl := _make()
	sl.launch()
	# Past the roll-up window but the player is still moving: must NOT transition yet
	# (and we're under the safety cap).
	_player.linear_velocity = Vector3(0, 0, -5)
	sl._process(Config.data.start_queue_stagger_seconds + Config.data.start_trailer_scoot_seconds + 0.2)
	assert_eq(sl.sequence_phase(), StartLine.Seq.DRIVE_OFF, "holds the reveal while the player is still rolling")
	# Once stopped, it transitions into the fade.
	_player.linear_velocity = Vector3.ZERO
	sl._process(0.1)
	assert_eq(sl.sequence_phase(), StartLine.Seq.FADE_OUT, "fades once the player has come to a stop")


func test_handoff_releases_the_player_to_normal_driving() -> void:
	var sl := _make()
	sl.launch()
	sl._process(Config.data.start_drive_off_seconds)
	sl._process(Config.data.start_fade_seconds)
	assert_false(_player.ai_controlled, "the player is handed back to normal driving")
	assert_false(_player.axis_lock_linear_x, "lateral lock released so the player can steer")
	assert_false(_player.axis_lock_angular_y, "yaw lock released for the run")


func test_launch_starts_the_drive_off_not_the_countdown() -> void:
	var sl := _make()
	sl.launch()
	assert_true(sl.has_launched(), "launching flips the launched flag")
	assert_eq(sl.sequence_phase(), StartLine.Seq.DRIVE_OFF, "launch begins the drive-off animation")
	assert_eq(_stage.begin_calls, 0, "the countdown does NOT start until after the fade")
	assert_false(sl._overlay.visible, "the reveal overlay hides on launch")


func test_fade_hands_back_camera_ui_and_starts_countdown() -> void:
	var sl := _make()
	sl.launch()
	# Drive through the drive-off, then the fade-to-black.
	sl._process(Config.data.start_drive_off_seconds)
	assert_eq(sl.sequence_phase(), StartLine.Seq.FADE_OUT, "drive-off completes into the fade")
	assert_eq(_stage.begin_calls, 0, "still no countdown mid-drive-off")
	sl._process(Config.data.start_fade_seconds)
	# At full black the hand-off fires.
	assert_eq(_stage.begin_calls, 1, "the countdown starts at full black")
	assert_true(_chase.current, "the chase camera is handed control back")
	assert_false(sl._orbit_cam.current, "the orbit camera releases control")
	assert_true(_hud.visible, "the driving UI returns")


# The hand-off restores the player's SELECTED camera (via the CameraManager), not a
# hard-coded chase camera: a player who picked bonnet keeps it through the start line.
func test_fade_restores_the_selected_camera_not_always_chase() -> void:
	_cam_mgr.set_mode(CameraManager.Mode.BONNET)
	var sl := _make()
	sl.launch()
	sl._process(Config.data.start_drive_off_seconds)
	sl._process(Config.data.start_fade_seconds)
	assert_true(_bonnet.current, "the selected (bonnet) camera is restored at hand-off")
	assert_false(_chase.current, "the start line does not force chase over the chosen mode")
	assert_false(sl._orbit_cam.current, "the orbit camera releases control")


func test_start_overlay_has_a_focusable_tune_car_button() -> void:
	var sl := _make()
	assert_not_null(sl._tune_button, "the pre-event overlay offers a Tune Car button")
	assert_eq(sl._tune_button.focus_mode, Control.FOCUS_ALL,
		"the Tune Car button is keyboard/gamepad focusable (MenuNav attached)")


func test_tune_overlay_opens_and_back_returns_to_the_start_overlay() -> void:
	# A live session so the tune panel binds the racing car (skip_track_gen: no scene).
	RallySession.start_rally(_rally(), _save.selected_car(), true)
	var sl := _make()
	sl._open_tune()
	assert_true(sl._tune_layer.visible, "opening Tune Car shows the tuning overlay")
	assert_false(sl._overlay.visible, "the start overlay hides while tuning")
	sl._close_tune()
	assert_true(sl._overlay.visible, "Back restores the start overlay")
	assert_false(sl._tune_layer.visible, "Back hides the tuning overlay")


func test_start_line_tune_uses_retune_and_preserves_the_staged_pose() -> void:
	# Regression: the Tune Car edit must re-apply tuning via the live-safe retune path,
	# NOT re-field via apply_owned (which relocates the wheels + resets the pose and
	# corrupts the staged body). The staged grid pose must survive a tune untouched.
	RallySession.start_rally(_rally(), _save.selected_car(), true)
	var sl := _make()
	var pose_before: Transform3D = _player.global_transform
	sl._open_tune()
	sl._on_tune_changed(_save.selected_car())
	assert_gt(_player.retune_calls, 0, "the tune routes through the live-safe retune path")
	assert_false(_player.applied_owned,
		"it must NOT re-field via apply_owned (that relocates wheels + resets the pose)")
	assert_eq(_player.global_transform, pose_before, "the staged grid pose is preserved across a tune")


func test_launch_is_idempotent() -> void:
	var sl := _make()
	sl.launch()
	sl._process(Config.data.start_drive_off_seconds)
	sl._process(Config.data.start_fade_seconds)
	assert_eq(_stage.begin_calls, 1, "countdown started once")
	# A stray launch after the sequence has moved on must not restart anything.
	sl.launch()
	sl._process(Config.data.start_fade_seconds)
	assert_eq(_stage.begin_calls, 1, "a late launch is ignored")
