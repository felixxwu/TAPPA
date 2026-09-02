class_name HqPresentReveal
extends RefCounted
# Docs: features/hq.md, features/reward-system.md — update in the same change as this file.
# Tests: tests/headless/test_hq_present_reveal.gd, tests/headless/test_menu_flow.gd (the
# "present-box car reveal" section) — extend in the same change.
# The PRESENT-BOX car reveal: the forced beat HQ opens on after a rally that won the player a
# car. Cut out of hq.gd to shrink it; nothing about the behaviour changed, this is a code move
# plus the `_hq.` wiring.
#
# Holds a back-reference to the HqController and reaches into it for the car-park widgets it
# re-labels and the reveal's own state — the same shape as HqOverlays / HqChallenge /
# HQEnvironment.
#
# NO INPUT BRANCH OF ITS OWN, on purpose: the present runs INSIDE View.CARPARK
# (CarparkMode.PRESENT), so keyboard/gamepad input reaches it through HqCarpark.handle_input and
# hq.gd's _car_back / _on_start_pressed exactly as before the cut. Nothing about which input
# goes where changed.
#
# WHAT STAYED ON HqController: the four reveal STATE fields (_present_box, _present_instance_id,
# _present_opened, _present_marker) and thin forwarders for the three entry points hq.gd and the
# tests call by name (_enter_present_box, _open_present, _leave_present_to_garage). The state is
# read from outside this file (a test asserts on _present_opened, hq.gd's _car_back branches on
# it), so it is shared state, not this file's private bookkeeping — the same split
# HqChallenge uses for _challenge_shown.

var _hq: HqController


func _init(hq: HqController) -> void:
	_hq = hq


# --- Present-box car reveal --------------------------------------------------
# How a won car is handed over. The rally GRANTS it (rally_session), then HQ opens on a
# giant present in an empty car park with the car inside it. The podium used to do this
# with a slot-machine reel and a showroom turntable, on the results screen — away from the
# garage the car actually arrives in, and over in a moment. The box puts the reveal where
# the car is and makes the player perform it.

# THESE FOUR NOW LIVE IN GameConfig — the consts are FALLBACK DEFAULTS ONLY.
# They are pure LOOK / FEEL values (the box's clearance around the car and the timing of the
# opening cinematic), so per CLAUDE.md they are authored in config/game_config.tres (group
# "HQ Present Box") and read through `Config.get_float(...)` at the point of use. RETUNE IN THE
# .tres. The consts stay as the documented shipped value and as the fallback when a field is
# missing, and because outside callers may name them.
#   PRESENT_CLEARANCE_M -> hq_present_clearance_m
#   PRESENT_LID_RISE    -> hq_present_lid_rise
#   PRESENT_OPEN_TIME   -> hq_present_open_time
#   PRESENT_WALL_TIME   -> hq_present_wall_time
const PRESENT_CLEARANCE_M := 0.55
const PRESENT_LID_RISE := 9.0        # how far the lid travels up before it leaves frame
const PRESENT_OPEN_TIME := 0.7       # seconds for the lid to clear
const PRESENT_WALL_TIME := 1.1       # seconds for a wall to fall (slow — it has weight)


# Open on the present. `instance_id` is a car the player ALREADY OWNS — the box is a
# presentation, not a transaction, so backing out or quitting cannot cost them the car.
func _enter_present_box(instance_id: int) -> void:
	_hq._present_instance_id = instance_id
	_hq._carpark_mode = HqController.CarparkMode.PRESENT
	_hq._view = HqController.View.CARPARK
	_hq._detail_open = false
	_hq._present_opened = false
	# An EMPTY lot: the point is one box, alone.
	_hq._carpark_ui._clear_lineup()
	# ...but the lot still needs its ONE BAY, because the car-park panel is welded to
	# _markers[_focus] (_car_panel_xform) and _clear_lineup empties that list. With no marker
	# the panel had no anchor at all, so it never appeared — and since the Open button lives
	# on it, the box came up with no visible way to open it, on a screen the player is FORCED
	# through. Seating it HERE rather than at open time also means the panel does not move:
	# the same marker carries the opened car, so the Open button and the car detail that
	# replaces it are read at exactly the same position and angle.
	_hq._present_marker = _add_present_marker()
	_hq._focus = 0
	_hq._no_eligible_label.visible = false
	_hq._car_warning_label.visible = false
	_hq._car_stats_label.text = ""
	_hq._car_name_label.text = ""       # filled in once the car is revealed
	_hq._rally_banner.text = "You won a car"
	if is_instance_valid(_hq._car_hint_label):
		_hq._car_hint_label.text = "Open it to see what you won"
		_hq._car_hint_label.visible = true
	_set_carpark_arrows_visible(false)  # nothing to cycle through
	_refresh_present_button()
	_hq.update_overlays()
	_hq._move_camera_to(_hq._station_xform(HqController.View.CARPARK), true)

	if is_instance_valid(_hq._present_box):
		_hq._present_box.queue_free()
	# Fit the LARGEST car on the roster: width across X, length along Z (a car-park marker
	# faces +Z, so length runs along depth), and walls tall enough to clear the tallest roof.
	var bounds := CarLibrary.max_car_bounds()
	var clearance := Config.get_float("hq_present_clearance_m", PRESENT_CLEARANCE_M)
	_hq._present_box = PresentBox.build_openable(
		bounds.x + clearance,
		bounds.z + clearance,
		bounds.y + clearance)
	_hq._present_box.position = HQEnvironment.carpark_center()
	_hq.add_child(_hq._present_box)


# The present's single bay, at the centre of the lot. Registered in `_markers` because that
# is what both the car-park panel (_car_panel_xform) and the camera framing key off; the
# ordinary lineup builds the same thing per owned car (hq_carpark.gd::_render_lineup_page).
func _add_present_marker() -> Marker3D:
	var marker := Marker3D.new()
	marker.position = HQEnvironment.carpark_center()
	# Nose toward +Z (the courtyard / camera), matching every other car-park bay marker.
	marker.rotation.y = PI
	_hq.add_child(marker)
	_hq._markers.append(marker)
	return marker


# The bottom button: Open while the box is shut, then the way out. It is never disabled —
# the player is FORCED through this beat (see _car_back), so a dead button here would be a
# dead end rather than a pause.
func _refresh_present_button() -> void:
	if not is_instance_valid(_hq._start_button):
		return
	_hq._start_button.text = "Back to garage" if _hq._present_opened else "Open it"
	_hq._start_button.disabled = false
	# Back is hidden until the box is open: there is nowhere to go back TO — the player has
	# arrived here straight from a rally they won.
	if is_instance_valid(_hq._car_back_button):
		_hq._car_back_button.visible = _hq._present_opened


# Hide the prev/next arrows without hiding the centre label they share a row with.
func _set_carpark_arrows_visible(on: bool) -> void:
	if not is_instance_valid(_hq._car_nav_row):
		return
	for child in _hq._car_nav_row.get_children():
		if child is Button:
			(child as Button).visible = on


# Open the box on the car inside it.
func _open_present() -> void:
	if _hq._present_opened:
		return
	var car := Save.get_car(_hq._present_instance_id)
	if car.is_empty():
		# Nothing to show (a profile edited between the win and the reveal). Leave rather
		# than stranding the player in a forced screen with no car in it.
		_leave_present_to_garage()
		return
	_hq._present_opened = true
	# Make it the SELECTED car, so the "Back to garage" exit lands on the car just opened.
	_hq._selected_instance_id = _hq._present_instance_id
	Save.set_selected_car(_hq._present_instance_id)
	_refresh_present_button()
	# A new car can make locked rallies enterable, so the map behind us is now stale.
	_hq._refresh_map_pins()

	# Put the car IN the box first, while the walls still hide it. It goes on the bay the box
	# was already standing on, so the panel welded to that marker does not shift when the lid
	# comes off — a second marker here would rebuild it in place and re-seat the panel.
	var marker := _hq._present_marker if is_instance_valid(_hq._present_marker) else _add_present_marker()
	var node := _hq._carpark_ui._obtain_parked_car(car, marker)
	if node != null:
		_hq._carpark_ui._seat_car_at_marker(node, marker)

	# Name it under the car. Set BEFORE the animation so a headless run — which never
	# animates — still ends in the revealed state.
	var entry := CarLibrary.for_owned(car)
	_hq._car_name_label.text = String(entry.get("name", "A car")) if not entry.is_empty() else "A car"
	_hq._car_stats_label.text = "Parked up and ready to field."
	if is_instance_valid(_hq._car_hint_label):
		_hq._car_hint_label.text = ""
		_hq._car_hint_label.visible = false

	if Platform.is_headless():
		# No awaited timers, no tweens: a cinematic that waits on real time would add
		# seconds to every test that opens a present. Drop the box and be done.
		if is_instance_valid(_hq._present_box):
			_hq._present_box.queue_free()
			_hq._present_box = null
		return
	_animate_present_open()


# Lid up and away first, walls falling as it clears, so it reads as one gesture rather than
# four panels flopping at once.
func _animate_present_open() -> void:
	if not is_instance_valid(_hq._present_box):
		return
	var lid_rise := Config.get_float("hq_present_lid_rise", PRESENT_LID_RISE)
	var open_time := Config.get_float("hq_present_open_time", PRESENT_OPEN_TIME)
	var wall_time := Config.get_float("hq_present_wall_time", PRESENT_WALL_TIME)
	var lid: Node3D = _hq._present_box.get_node_or_null("Lid")
	if lid != null:
		var lid_tween := _hq.create_tween()
		lid_tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		lid_tween.tween_property(lid, "position:y",
			lid.position.y + lid_rise, open_time)
	# Each wall is a hinge Node3D pivoted at its bottom edge, so a quarter turn about the
	# axis PARALLEL to that edge drops it flat outward (see PresentBox.build_openable).
	var falls := {
		"SideN": Vector3(-PI * 0.5, 0.0, 0.0),
		"SideS": Vector3(PI * 0.5, 0.0, 0.0),
		"SideW": Vector3(0.0, 0.0, PI * 0.5),
		"SideE": Vector3(0.0, 0.0, -PI * 0.5),
	}
	for side_name in falls:
		var side: Node3D = _hq._present_box.get_node_or_null(String(side_name))
		if side == null:
			continue
		var t := _hq.create_tween()
		# TRANS_QUAD + EASE_IN is the gravity curve: displacement goes as t², so a wall
		# barely moves for the first moment and then accelerates into the floor, like a
		# panel tipping past its balance point.
		t.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
		t.tween_interval(open_time * 0.45)
		t.tween_property(side, "rotation", falls[side_name], wall_time)


# Leave for the GARAGE rather than the map: the player has just been given a car, and the
# garage is where they look at and field it.
func _leave_present_to_garage() -> void:
	_cleanup_present_reveal()
	_hq._carpark_mode = HqController.CarparkMode.RALLY
	_hq.go_to(HqController.View.GARAGE)


# Free the reveal props and restore the ordinary car-park chrome.
func _cleanup_present_reveal() -> void:
	if is_instance_valid(_hq._present_box):
		_hq._present_box.queue_free()
	_hq._present_box = null
	_hq._present_instance_id = -1
	_hq._present_opened = false
	_set_carpark_arrows_visible(true)
	if is_instance_valid(_hq._start_button):
		_hq._start_button.disabled = false
	if is_instance_valid(_hq._car_back_button):
		_hq._car_back_button.visible = true
	if is_instance_valid(_hq._car_hint_label):
		_hq._car_hint_label.text = ""
		_hq._car_hint_label.visible = false
