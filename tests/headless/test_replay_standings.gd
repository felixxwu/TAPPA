extends GutTest
# Standings overlay mode (event-replay feature, Task 6): transparent bg, hide/show
# leaderboard toggle, audio signal. See scripts/standings.gd and
# .superpowers/sdd/task-6-brief.md.

const SceneHelpers = preload("res://tests/headless/scene_helpers.gd")

func _make_standings(overlay: bool) -> Control:
	var s: Control = load("res://standings.tscn").instantiate()
	s.overlay_mode = overlay
	add_child_autofree(s)
	return s


func before_each() -> void:
	RallySession.auto_load_scenes = false


func test_overlay_background_is_transparent() -> void:
	var s := _make_standings(true)
	var bg := s.get_node_or_null("Background") as ColorRect
	assert_not_null(bg, "overlay keeps a named Background node")
	assert_almost_eq(bg.color.a, 0.0, 0.5, "overlay background is (near) transparent")


func test_toggle_hides_panel_and_keeps_a_focusable_control() -> void:
	var s := _make_standings(true)
	s.toggle_leaderboard()
	assert_true(s.leaderboard_hidden, "toggle hides the leaderboard")
	var focus_owner := _first_focusable(s)
	assert_not_null(focus_owner, "hidden state still exposes a focusable control")
	s.toggle_leaderboard()
	assert_false(s.leaderboard_hidden, "toggle restores the leaderboard")


func test_toggle_emits_hidden_changed() -> void:
	var s := _make_standings(true)
	watch_signals(s)
	s.toggle_leaderboard()
	assert_signal_emitted(s, "leaderboard_hidden_changed")


func test_non_overlay_mode_is_unaffected() -> void:
	# The normal (non-overlay) standings scene keeps its opaque bg and still
	# connects the podium transition itself.
	var s := _make_standings(false)
	var bg := s.get_node_or_null("Background") as ColorRect
	assert_not_null(bg, "non-overlay standings still has a Background node")
	assert_almost_eq(bg.color.a, 1.0, 0.001, "non-overlay background stays opaque")
	assert_true(RallySession.rally_finished.is_connected(s._on_rally_finished),
		"non-overlay standings owns the podium transition")


func test_session_skips_scene_change_when_host_overlays() -> void:
	# When a live host (world.gd) claims the standings, RallySession must NOT
	# change scene itself — the host overlays instead (Task 7).
	RallySession.standings_overlay_host = true
	var scene_before := get_tree().current_scene
	RallySession._load_standings_scene()   # should be a no-op, no crash, no change
	assert_eq(get_tree().current_scene, scene_before,
		"no scene change requested under overlay host")
	RallySession.standings_overlay_host = false


func _first_focusable(n: Node) -> Control:
	if n is Control and (n as Control).focus_mode == Control.FOCUS_ALL and (n as Control).visible:
		return n
	for c in n.get_children():
		var r := _first_focusable(c)
		if r != null:
			return r
	return null


# --- A challenge skips page 1 (there are no AI opponents to rank against) ---------

# A challenge run has no rival field, so page 1 (the local event standings) has
# nothing to rank and is fed an empty row list. The interstitial goes straight to
# the world board instead. Keyed off the LATCHED mode, so it holds on the FINAL stage too,
# where the session has already gone inactive by the time this screen builds.
func test_a_challenge_skips_straight_to_the_world_board() -> void:
	var s: Control = load("res://standings.tscn").instantiate()
	s.overlay_mode = true
	s.set_challenge_mode(true)
	add_child_autofree(s)
	await get_tree().process_frame
	assert_true(s._global_shown, "the challenge interstitial opens on the world board")
	assert_false(is_instance_valid(s._root_box),
		"page 1 is not left behind it — a one-row local table is nothing to show")


# A CAREER rally still gets page 1: it has a real AI field to rank against, so the
# skip must not leak into the mode that needs both pages.
func test_a_career_rally_still_opens_on_the_local_standings() -> void:
	var s: Control = load("res://standings.tscn").instantiate()
	s.overlay_mode = true
	s.set_challenge_mode(false)
	add_child_autofree(s)
	await get_tree().process_frame
	assert_false(s._global_shown, "a career rally still opens on page 1")
	assert_true(is_instance_valid(s._root_box), "page 1's content is built and live")


# --- Driving UI handover ----------------------------------------------------------
# When the run hands over to the cinematic replay, every overlay addressed to the PERSON
# DRIVING is hidden — the player becomes a viewer. Exercised through _hide_driving_ui
# rather than _present_standings_overlay, because the latter early-returns under
# Platform.is_headless() (the whole suite runs --headless), which would make the
# assertion vacuous.
#
# Built on minimal_world so this costs a sub-second scene build, not a full generation.
var _world: Node = null


# Built ONCE here rather than inside the test: instantiating main.tscn compiles every
# script in the project, and doing that inside a test body attributes all their compile
# warnings to that test, which GUT counts as failures.
func before_all() -> void:
	SceneHelpers.minimal_world()
	_world = load("res://main.tscn").instantiate()
	add_child(_world)
	await wait_frames(2)


func after_all() -> void:
	if _world != null:
		_world.free()
		_world = null
	Config.reset()


func test_replay_hides_every_driving_only_overlay() -> void:
	var world := _world
	# Guard the premise: if these layers stopped existing (or were renamed), the test
	# below would pass by finding nothing to hide.
	var hud := world.get_node_or_null("HUD") as CanvasLayer
	var speed_lines := world.get_node_or_null("SpeedLines") as CanvasLayer
	assert_not_null(hud, "the world should own a HUD layer")
	assert_not_null(speed_lines, "the world should own a SpeedLines layer")

	world._hide_driving_ui()

	assert_false(hud.visible, "the HUD is for the driver, not the replay viewer")
	assert_false(speed_lines.visible,
		"the anime speed lines are a driving cue and must not play over the replay")
	var mobile := world.get_node_or_null("MobileControls") as CanvasLayer
	if mobile != null:
		assert_false(mobile.visible, "touch driving controls must not sit over the replay")
