class_name HqMultiplayer
extends RefCounted
# Docs: features/multiplayer-lobby.md — update in the same change as this file.
# Tests: tests/headless/test_hq_multiplayer.gd — extend in the same change.
# The Multiplayer entry screen: a modal overlay over the garage (same shape as
# HqChallenge's Rally Challenge entry screen — see hq_challenge.gd and
# hq_overlays.gd's build_challenge_overlay, which this mirrors). Race/Spectate hand
# off into LobbySession (features/multiplayer-lobby.md); Back closes back to the
# garage.
#
# Holds a back-reference to the HqController, the same shape as HqChallenge /
# HqOverlays / HQEnvironment.

var _hq: HqController

# Gates the scene load at the end of Race/Spectate, mirroring
# ChallengeSession.auto_load_scenes / RallySession.auto_load_scenes — a test seam so
# the button handlers can be driven end to end (LobbySession.enter and all) without
# actually swapping the running scene out from under the test runner.
var auto_load_scenes := true


func _init(hq: HqController) -> void:
	_hq = hq


# --- Input (runs BEFORE hq.gd's per-station dispatch) ------------------------

# Same contract as HqChallenge.handle_input: the overlay is modal over the garage
# and owns its own MenuNav (attached in build_multiplayer_overlay), so this only
# has to report the event is spoken for while the overlay is up — hq.gd's
# _unhandled_input stops there so the garage below doesn't also react.
func handle_input(_event: InputEvent) -> bool:
	return _hq._multiplayer_shown


# --- Open / close -------------------------------------------------------------

func _open_multiplayer_overlay() -> void:
	_hq._multiplayer_shown = true
	_hq.update_overlays()
	_refresh_multiplayer_overlay()
	UITheme.enforce(_hq._multiplayer_layer)
	UITheme.focus_grab(_hq._multiplayer_race_button)


func _close_multiplayer_overlay() -> void:
	if _hq._multiplayer_layer == null:
		return
	_hq._multiplayer_shown = false
	_hq.update_overlays()


# Rebuild the entry screen's dynamic rows: the current round's loaner-car preview
# (may be one round stale by the time the player is actually in — that's fine, it's
# a preview, not a promise) and the sign-in status line.
#
# The wording on the sign-in line matters: an invisible player must never be left
# thinking they ARE visible. Race/Spectate both still work signed out — only
# visibility to other players is lost — so this is informational, never a gate.
func _refresh_multiplayer_overlay() -> void:
	if _hq._multiplayer_layer == null:
		return
	var unix_time := int(Time.get_unix_time_from_system())
	var round_key_str := RoundClock.round_key(RoundClock.round_index(unix_time))
	var car_id := LobbyRound.car_id_for(round_key_str)
	var car := CarLibrary.by_id(car_id)
	var car_name := String(car.get("name", "")) if not car.is_empty() else ""
	_hq._multiplayer_subtitle_label.text = ("This round's car: %s" % car_name) \
		if car_name != "" else "This round's car"
	var signed_in := Cloud != null and Cloud.auth != null and Cloud.auth.is_signed_in()
	_hq._multiplayer_signin_label.visible = not signed_in
	if not signed_in:
		_hq._multiplayer_signin_label.text = \
			"Sign in to appear on other players' screens — you can still race, but nobody will see you."


# --- Race / Spectate -----------------------------------------------------------

func _on_multiplayer_race_pressed() -> void:
	_close_multiplayer_overlay()
	await LobbySession.enter()
	await _hand_off_to_lobby_scene()


func _on_multiplayer_spectate_pressed() -> void:
	_close_multiplayer_overlay()
	await LobbySession.enter(true)
	await _hand_off_to_lobby_scene()


# Hand off to the driving scene the same way the Rally Challenge entry screen does
# (HqChallenge._hand_off_to_challenge_scene): a loading screen, two frames for it to
# paint, then the scene load — gated on `auto_load_scenes` so a test can drive
# Race/Spectate end to end (including the LobbySession.enter await above) with no
# scene load underneath it.
func _hand_off_to_lobby_scene() -> void:
	if auto_load_scenes:
		var loading := LoadingScreen.new()
		loading.set_step("Joining the lobby…")
		_hq.add_child(loading)
		await _hq.get_tree().process_frame
		await _hq.get_tree().process_frame
		Scenes.change_to(_hq.get_tree(), Scenes.MAIN)
