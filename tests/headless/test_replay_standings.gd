extends GutTest
# Standings overlay mode (event-replay feature, Task 6): transparent bg, hide/show
# leaderboard toggle, audio signal. See scripts/standings.gd and
# .superpowers/sdd/task-6-brief.md.

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
