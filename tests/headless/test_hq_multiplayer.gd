extends GutTest
# Docs: features/multiplayer-lobby.md
# Tests: (this file)
# HQ Multiplayer entry screen (scripts/hq_multiplayer.gd, scripts/hq_overlays.gd ->
# build_multiplayer_overlay): a modal overlay over the garage, opened from the
# garage row's Multiplayer button. Mirrors test_menu_flow.gd's Rally Challenge
# entry-point tests (test_hq_challenge_entry_opens_and_is_navigable and friends) —
# same hq.tscn instantiation, same MenuNav-search-by-type pattern.
#
# Nothing here pins an authored value (no specific car name, no round number, no
# LOBBY_EPOCH-derived number) — only the structural/nav contract the project rule
# on menu navigation requires.

const SceneHelpers = preload("res://tests/headless/scene_helpers.gd")


func before_each() -> void:
	get_viewport().gui_release_focus()
	Config.reset()
	Config.data.world_space_menus = false
	Config.data.hq_tree_count = 8
	Config.data.hq_bush_count = 8


func _press(action: String) -> InputEventAction:
	var e := InputEventAction.new()
	e.action = action
	e.pressed = true
	return e


func _find_nav(layer: CanvasLayer) -> MenuNav:
	var nav: MenuNav = null
	for child in layer.find_children("*", "MenuNav", true, false):
		nav = child
	return nav


func test_multiplayer_overlay_builds_with_race_spectate_back() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	assert_not_null(hq._multiplayer_layer, "build_multiplayer_overlay built the overlay layer")
	assert_false(hq._multiplayer_layer.visible, "the multiplayer overlay starts hidden")
	assert_not_null(hq._multiplayer_race_button)
	assert_not_null(hq._multiplayer_spectate_button)
	assert_not_null(hq._multiplayer_back_button)
	assert_eq(hq._multiplayer_race_button.text, "Race")
	assert_eq(hq._multiplayer_spectate_button.text, "Spectate")


func test_multiplayer_entry_opens_over_the_garage_and_is_navigable() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._on_exterior_start()
	# The Multiplayer button lives on the GARAGE row, so the real open always happens
	# from the garage view — and the close-restores-garage rule below only holds there.
	hq.go_to(hq.View.GARAGE, true)
	await get_tree().process_frame

	hq._multiplayer_ui._open_multiplayer_overlay()
	assert_true(hq._multiplayer_layer.visible, "opening the entry screen shows its overlay")
	assert_false(hq._garage_layer.visible, "the garage hides behind the modal multiplayer overlay")

	await get_tree().process_frame  # deferred MenuNav focus grab
	var focused := hq.get_viewport().gui_get_focus_owner()
	assert_eq(focused, hq._multiplayer_race_button, "opening lands focus on Race first")

	var nav := _find_nav(hq._multiplayer_layer)
	assert_not_null(nav, "the multiplayer screen has MenuNav attached")

	# Keyboard/gamepad nav: down through Race -> Spectate -> Back, then back up.
	nav._unhandled_input(_press("menu_down"))
	assert_eq(hq.get_viewport().gui_get_focus_owner(), hq._multiplayer_spectate_button,
		"menu_down moves focus from Race onto Spectate")
	nav._unhandled_input(_press("menu_down"))
	assert_eq(hq.get_viewport().gui_get_focus_owner(), hq._multiplayer_back_button,
		"menu_down again reaches Back")
	nav._unhandled_input(_press("menu_up"))
	assert_eq(hq.get_viewport().gui_get_focus_owner(), hq._multiplayer_spectate_button,
		"menu_up moves focus back onto Spectate")

	# ui_cancel (routed to on_back = _close_multiplayer_overlay) closes the modal and
	# restores the garage, same contract as the challenge screen's Back path.
	nav._unhandled_input(_press("menu_back"))
	assert_false(hq._multiplayer_layer.visible, "menu_back closes the multiplayer overlay")
	assert_true(hq._garage_layer.visible, "closing the overlay restores the garage")


func test_multiplayer_entry_shows_signed_out_wording() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._on_exterior_start()

	# Signed out is the default test-runner state (no cloud session), which is exactly
	# the state this line exists to cover: an invisible player must never be told they
	# ARE visible.
	assert_false(Cloud.auth.is_signed_in(), "setup: the test runner starts signed out")
	hq._multiplayer_ui._open_multiplayer_overlay()
	assert_true(hq._multiplayer_signin_label.visible,
		"signed out shows the sign-in status line")
	# UITheme uppercases label text, so compare case-insensitively — the CONTENT is
	# the contract here, not the styling.
	assert_string_contains(hq._multiplayer_signin_label.text.to_lower(),
		"nobody will see you",
		"the wording never implies the player IS visible while signed out")


func test_multiplayer_race_and_spectate_do_not_change_scene_with_auto_load_scenes_off() -> void:
	# auto_load_scenes is the test seam (mirrors ChallengeSession.auto_load_scenes /
	# RallySession.auto_load_scenes) — driving the button handlers end to end,
	# including the real LobbySession.enter() await, without swapping the running
	# scene out from under this test.
	#
	# LobbySession is an autoload whose `board` already talks to the real Cloud rest
	# client (see lobby_session.gd's _ready), so this substitutes a FakeRestClient
	# on it for the duration of the test — the same fake test_lobby_session.gd uses —
	# rather than let a headless test run issue a real network request.
	var fake := FakeRestClient.new()
	add_child_autofree(fake)
	fake.queue_ok({"fields": {
		"round_index": {"integerValue": "500"},
		"started_at_ms": {"integerValue": str(LobbySession.now_ms() - 5_000)},
	}})
	fake.queue_ok({"fields": {
		"round_index": {"integerValue": "500"},
		"started_at_ms": {"integerValue": str(LobbySession.now_ms() - 5_000)},
	}})
	var orig_rest = LobbySession.board.rest
	LobbySession.board.rest = fake

	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._on_exterior_start()
	hq._multiplayer_ui.auto_load_scenes = false

	var current_scene := hq.get_tree().current_scene
	hq._multiplayer_ui._open_multiplayer_overlay()
	await hq._multiplayer_ui._on_multiplayer_race_pressed()
	assert_false(hq._multiplayer_layer.visible, "Race closes the entry overlay")
	assert_eq(hq.get_tree().current_scene, current_scene,
		"with auto_load_scenes off, Race does not swap the running scene")
	assert_true(LobbySession.is_active(), "Race joined the lobby (racing, not spectating)")
	LobbySession.leave()

	hq._multiplayer_ui._open_multiplayer_overlay()
	await hq._multiplayer_ui._on_multiplayer_spectate_pressed()
	assert_eq(hq.get_tree().current_scene, current_scene,
		"with auto_load_scenes off, Spectate does not swap the running scene either")
	assert_true(LobbySession.is_active(), "Spectate also joined the lobby")
	LobbySession.leave()

	LobbySession.board.rest = orig_rest
