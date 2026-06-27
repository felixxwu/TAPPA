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


var _player: Node3D
var _stage: StubStage
var _chase: Camera3D
var _hud: CanvasLayer


func before_each() -> void:
	Config.reset()
	_player = Node3D.new()
	add_child_autofree(_player)
	_stage = StubStage.new()
	add_child_autofree(_stage)
	_chase = Camera3D.new()
	add_child_autofree(_chase)
	_hud = CanvasLayer.new()
	add_child_autofree(_hud)


func after_each() -> void:
	Config.reset()


# RWD Masters: a real rally with an event count for the subtitle.
func _rally() -> Dictionary:
	return RallyLibrary.by_id("rwd_masters")


func _make(target_ms := 75430, event_index := 0) -> StartLine:
	var sl := StartLine.new()
	add_child_autofree(sl)
	sl.set_process(false)  # drive the sequence manually for deterministic timing
	sl.setup(_player, null, _stage, _rally(), event_index, target_ms, _chase, _hud)
	return sl


func test_reveal_shows_time_to_beat_and_context() -> void:
	var sl := _make(75430, 1)  # 1:15.43, second event
	assert_eq(sl._target_label.text, "1:15.43", "the headline shows the time to beat (m:ss.cc)")
	assert_string_contains(sl._subtitle_label.text, "RWD Masters", "the rally is named")
	assert_string_contains(sl._subtitle_label.text, "Event 2 of 3", "the event index is shown")
	assert_eq(sl.sequence_phase(), StartLine.Seq.ORBIT, "it waits in the orbit/reveal phase")


func test_missing_rival_time_shows_dash() -> void:
	var sl := _make(-1)
	assert_eq(sl._target_label.text, "—", "no classified rival time reads as a dash")


func test_reveal_hides_hud_and_takes_the_camera() -> void:
	var sl := _make()
	assert_false(_hud.visible, "the driving HUD is hidden during the reveal")
	assert_true(sl._orbit_cam.current, "the orbit camera takes over for the reveal")


func test_queue_has_a_leader_and_a_trailer() -> void:
	var sl := _make()
	assert_eq(sl.queue_count(), 2, "the car is queued between a leader and a trailing car")


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
