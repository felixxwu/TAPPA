class_name HqTable
extends RefCounted
# The HQ map table, extracted from hq.gd to shrink it (todo/hq-split.md): entering the table,
# the new-rally reveal sequence, pin focus / panning / target selection, and the rally detail
# panel.
#
# Holds a back-reference to the HqController and reaches into it for state, node parenting and
# widget helpers — the same shape as HqOverlays / HqChallenge / HQEnvironment.
#
# FUNCTIONS ONLY: the table/reveal/detail STATE stays on HqController, as does `_process` (an
# engine callback Godot would never fire on a RefCounted) and the shared
# `_eligibility_summary` / `_qualifying_cars_text` helpers hq_challenge.gd also uses.

var _hq: HqController

func _init(hq: HqController) -> void:
	_hq = hq


func _enter_table() -> void:
	_hq._detail_open = false
	_hq._table_pan = Vector3.ZERO  # re-centre the map each time we open it
	_hq._table_dragged = false
	_hq._table_panning = false
	# Which rallies became enterable since the player last looked? Derived FRESH here,
	# from current state, every single time the map opens — never cached at the moment a
	# rally is finished. That is what makes the reveal generalise to any unlock route:
	# completing a rally, buying a car, a Mystery Box car, an engine swap that moves a
	# car into a class, a cloud restore, or anything nobody has designed yet. (The
	# pre-feature-save backfill itself now lives in Save — see
	# Save._seed_reveals_if_needed — run at the points a profile becomes live, so a
	# future scene/entry point into the map can't forget to seat it.)
	var pending := _pending_reveals()
	# HEADLESS (the test runner) gets the sequence's FINAL STATE with none of its
	# cinematics: the rallies end up marked seen and the table opens live and focused
	# exactly as it does after a real playthrough, but with no awaits to hang the suite
	# on. Skip the animation, never the decision (features/testing.md).
	if Platform.is_headless():
		for rid in pending:
			Save.mark_rally_revealed(String(rid), false)
		if not pending.is_empty():
			Save.save()
		pending = []
	# The pending pins go up in their LOCKED look so the flip is watchable; everything
	# else refreshes normally (newly-earned stars / a special unlocking).
	_hq._refresh_map_pins(pending)
	if not pending.is_empty():
		_hq._go_to(_hq.View.TABLE)
		_run_reveal_sequence(pending)
		return
	# On entry, steer straight to the toughest event the player hasn't finished yet:
	# focus (and pan the camera to) the highest-difficulty incomplete rally pin. From
	# there the player pans the camera and selection tracks the view centre. Falls back
	# to the centre-nearest target when every pin is done (or there are none).
	#
	# The fallback PANS onto that target rather than testing what happens to lie under the
	# view centre: entry re-centres the map (_table_pan = ZERO above), and the middle of the
	# map is rarely within map_select_radius_m of any pin — so seating with
	# _select_target_under_center opened the table with nothing selected at all whenever the
	# fallback was taken (every event completed). See _focus_nearest_target.
	if not _focus_hardest_incomplete():
		_focus_nearest_target()
	_hq._go_to(_hq.View.TABLE)


# --- New-rally reveal --------------------------------------------------------
#
# The rally ids waiting to be shown to the player, in roster order (newest-unlocked
# last). A rally qualifies only when ALL THREE hold:
#
#   * it is unlocked (RallyLibrary.rally_revealed — reveal_after met, or a special
#     whose region gate has opened),
#   * the player owns a car that can ACTUALLY enter it (_has_eligible_car — the same
#     authoritative answer the green/grey pin flag uses), and
#   * it has not already been revealed (Save.rally_revealed_seen).
#
# The middle clause turns the reveal from an event into a STANDING CONDITION: a rally
# that unlocks while the garage can't field it is simply held back and appears the day
# the player buys, wins or engine-swaps a car that qualifies. Nothing expires, because
# this is recomputed on every single map open.
func _pending_reveals() -> Array:
	var out: Array = []
	for rally in RallyLibrary.all():
		var rid := String(rally["id"])
		if Save.rally_revealed_seen(rid):
			continue
		if not RallyLibrary.rally_revealed(rally, Save.profile):
			continue
		if not _hq._has_eligible_car(rally):
			continue
		out.append(rid)
	return out


# Walk the queue: pan to each pin still wearing its locked look, flip it to unlocked,
# banner it, hold, move on. A special gets the bigger beat (its own banner and a longer
# hold — it's a region finale). Player input is LOCKED throughout, so the parade always
# plays out (hq.gd::_unhandled_input).
#
# GENERATION GUARD: `_reveal_token` is bumped here and captured in `token` before the
# first `await`. Every check below asks `_reveal_continue(token)` instead of a bare
# `_reveal_active()` so a STALE coroutine — one still parked in an `await` from a
# sequence that was skipped, then re-armed by a second `_enter_table()` before the first
# resumed — notices its token no longer matches `_reveal_token` and bails immediately,
# instead of going on to pan the camera / bump banners / `erase()` entries out of the
# NEW queue it has no business touching.
func _run_reveal_sequence(pending: Array) -> void:
	_hq._reveal_token += 1
	var token := _hq._reveal_token
	_hq._reveal_queue.clear()
	for rid in pending:
		_hq._reveal_queue.append(String(rid))
	_hq._revealing = true
	# Defensive: _enter_table already drains the queue instantly under headless, but
	# nothing may await in a display-less run (it would hang the suite).
	if Platform.is_headless():
		_finish_reveals()
		return
	var cfg: GameConfig = Config.data
	var cap: int = maxi(1, cfg.hq_reveal_max_queue)
	var shown := _hq._reveal_queue.slice(0, cap)
	var overflow: int = _hq._reveal_queue.size() - shown.size()
	for rid in shown:
		if not _reveal_continue(token):
			return
		var rally := RallyLibrary.by_id(rid)
		var special := RallyLibrary.is_special(rally)
		# 1. Travel to the pin (the existing map-pan tween — one motion for the whole
		#    game) and let it settle while the pin is still grey.
		_pan_table_to(_pin_position(rid))
		await _hq.get_tree().create_timer(cfg.hq_reveal_pan_time).timeout
		if not _reveal_continue(token):
			return
		# 2. Flip it: rebuild the pins with this id no longer held back, so the grey flag
		#    becomes the live one and the readout box pops in.
		_hq._reveal_queue.erase(rid)  # …but it still gets marked seen — see _finish_reveals
		var still_held := _hq._reveal_queue.duplicate()
		_hq._reveal_shown.append(rid)
		_hq._refresh_map_pins(still_held)
		_focus_pin(rid)
		var lead := "SPECIAL EVENT UNLOCKED" if special else "NEW RALLY"
		_set_reveal_banner("%s - %s" % [lead, String(rally.get("name", ""))])
		# 3. Hold on the new thing. A special lingers.
		var hold: float = cfg.hq_reveal_hold_time * (2.0 if special else 1.0)
		await _hq.get_tree().create_timer(hold).timeout
	if _reveal_continue(token) and overflow > 0:
		# The dev "3-star everything" cheat (and any future mass unlock) can open the whole
		# roster at once; the cap keeps that to a few beats and tells the player the rest.
		_set_reveal_banner("+%d MORE RALLIES OPEN" % overflow)
		await _hq.get_tree().create_timer(cfg.hq_reveal_hold_time).timeout
	if not _reveal_continue(token):
		return
	_finish_reveals()


# Pure predicate — no side effects. Still mid-sequence and still worth continuing, right
# now, with no consideration for what (if anything) should happen if it isn't. Split out
# of the old `_reveal_active()`, which used to call `_finish_reveals()` (a disk save +
# pin rebuild) from what read as a plain query; see `_reveal_continue` for the explicit
# abort step that replaces that side effect at the call sites that actually need it.
func _reveal_active() -> bool:
	return _hq._revealing and _hq.is_inside_tree() and _hq._view == _hq.View.TABLE


# The abort point `_run_reveal_sequence` actually calls between steps. Returns true to
# keep going. Returns false to stop — and, exactly once, if the reason is that the
# sequence is still marked `_revealing` but the player left the map view (Back, a cloud
# restore bouncing us to the title, …), banks what was queued as seen via an EXPLICIT
# `_finish_reveals()` call here rather than as a hidden side effect of the predicate.
#
# `token` must match the generation `_run_reveal_sequence` captured at its start — a
# stale coroutine whose token has been superseded by a newer sequence returns false
# immediately, without finishing anything (the newer sequence owns that now).
func _reveal_continue(token: int) -> bool:
	if token != _hq._reveal_token:
		return false
	if _reveal_active():
		return true
	if _hq._revealing and _hq.is_inside_tree() and _hq._view != _hq.View.TABLE:
		_finish_reveals()
	return false


# ANY press ends the whole queue at once — this is a requirement, not polish. Players
# open the map constantly and an unskippable cutscene is hated by the third viewing, so
# the press must never be swallowed into "advance one pin".
# Land the final state: every id that was queued (shown, skipped, or capped away) is
# marked seen and saved, the pins go back to their true look, the banner clears, table
# input comes back live, and selection is left on the LAST revealed pin — the player
# wants to look at the new thing, not be yanked to _focus_hardest_incomplete().
func _finish_reveals() -> void:
	var last_shown: String = _hq._reveal_shown[-1] if not _hq._reveal_shown.is_empty() else ""
	for rid in _hq._reveal_queue:
		Save.mark_rally_revealed(rid, false)
		if last_shown == "":
			last_shown = rid
	for rid in _hq._reveal_shown:
		Save.mark_rally_revealed(rid, false)
	Save.save()
	_hq._reveal_queue.clear()
	_hq._reveal_shown.clear()
	_hq._revealing = false
	if not _hq.is_inside_tree():
		return
	_set_reveal_banner("")
	_hq._refresh_map_pins()
	if _hq._view == _hq.View.TABLE and last_shown != "":
		_focus_pin(last_shown)


# The single "which node in this collection carries this rally id" linear scan, shared
# by _pin_position and _focus_pin so their matching logic can't drift apart. The two
# callers deliberately search DIFFERENT collections — _pin_position over `_pins` (every
# pin, locked ones included: a held-back reveal pin must be findable while still
# locked), _focus_pin over the unlocked-only `_table_targets()` (locked pins are never
# cursor targets) — so `nodes` stays a parameter rather than this reaching for `_pins`
# itself; do not collapse that difference away.
func _node_with_rally_id(nodes: Array, rally_id: String) -> Node3D:
	for n in nodes:
		var node := n as Node3D
		if String(node.get_meta("rally_id", "")) == rally_id:
			return node
	return null


# The table-plane position of a rally's pin (Vector3.ZERO if it has none).
func _pin_position(rally_id: String) -> Vector3:
	var pin := _node_with_rally_id(_hq._pins, rally_id)
	return pin.position if pin != null else Vector3.ZERO


# Seat the keyboard/gamepad cursor on a rally's pin, panning the camera to it. No-op
# while the pin is still locked (locked pins aren't cursor targets — see _unlocked_pins).
func _focus_pin(rally_id: String) -> void:
	var targets := _table_targets()
	var nodes: Array = []
	for t in targets:
		nodes.append(t["node"])
	var node := _node_with_rally_id(nodes, rally_id)
	if node == null:
		return
	for i in targets.size():
		if targets[i]["node"] == node:
			_focus_table_target(i, true)
			return


# The one-line reveal banner on the table overlay ("" hides it).
func _set_reveal_banner(text: String) -> void:
	if _hq._reveal_banner == null:
		return
	_hq._reveal_banner.text = text
	_hq._reveal_banner.visible = text != ""


# The pins a keyboard/gamepad cursor can land on: the unlocked ones, in rally order
# (a locked special pin is skipped — it's non-pickable until its star gate opens).
# EVERY pin is a cursor target, enterable or not.
#
# Readouts are hover-only, so a pin the cursor cannot reach can never show its box — and a
# pin that cannot answer when you point at it is just a shape on a dark table. So hovering
# is open to all of them, and it is _activate_table_focus that refuses to OPEN a locked one.
# Seeing what is out there is the point; entering it before you get there is not.
func _unlocked_pins() -> Array:
	return _hq._pins.duplicate()


# Every focus target on the table right now: the unlocked rally pins, plus the present box
# that trades stars for a car. Each entry: {node, kind, pos}; kind is "pin" or "present".
#
# A new kind needs NO neighbour wiring: the map cursor is "whichever target sits nearest the
# view centre" (_select_target_under_center), so appearing in this list is all it takes to be
# reachable by keyboard, gamepad and drag alike.
# Cached (see _table_targets_cache): rebuilt only when the cache is invalidated by a pin
# rebuild, so the per-frame pan glide doesn't re-allocate it.
func _table_targets() -> Array:
	if _hq._table_targets_cache == null:
		_hq._table_targets_cache = _build_table_targets()
	return _hq._table_targets_cache


func _build_table_targets() -> Array:
	var out: Array = []
	for pin in _unlocked_pins():
		out.append({"node": pin, "kind": "pin", "pos": (pin as Node3D).position})
	return out


# The table's on-screen up/right directions as world vectors in the (flat) XZ plane.
# The table camera is fixed and never rotated/tilted much, so these are effectively
# constant; deriving them from the cam pose keeps up = "away into the screen" and
# right = 90° clockwise of it, matching what the player sees. Returns [up, right].
func _table_plane_axes() -> Array:
	var cfg: GameConfig = Config.data
	var fwd: Vector3 = cfg.hq_table_cam_look - cfg.hq_table_cam_eye
	fwd.y = 0.0
	var up := fwd.normalized() if fwd.length() > 0.001 else Vector3(0.0, 0.0, -1.0)
	var right := Vector3(-up.z, 0.0, up.x)  # up rotated -90° about Y (world +X when up = -Z)
	return [up, right]


# Slide the table camera `dist` world-metres in screen-direction `dir2` (UP/DOWN/LEFT/
# RIGHT, or a diagonal sum), then snap selection to whichever target now sits nearest
# the view centre. The player drives the camera directly; the "cursor" is just whatever
# the camera reticle is pointed at, so there are no discrete jumps between pins. Both the
# held-glide (_process, dist = speed·delta) and tests drive this.
func _pan_table_step(dir2: Vector2, dist: float) -> void:
	if dir2 == Vector2.ZERO or dist <= 0.0:
		return
	var cfg: GameConfig = Config.data
	var axes := _table_plane_axes()
	# Godot's Vector2.UP/DOWN use screen convention (y+ = down), so the y term is
	# negated to line up with axes[0] ("up" as a world-space direction).
	var want: Vector3 = axes[1] * dir2.x - axes[0] * dir2.y
	if want.length() < 0.001:
		return
	want = want.normalized()
	var half := cfg.hq_map_plane_size
	_hq._table_pan.x = clampf(_hq._table_pan.x + want.x * dist, -half.x * 0.5, half.x * 0.5)
	_hq._table_pan.z = clampf(_hq._table_pan.z + want.z * dist, -half.y * 0.5, half.y * 0.5)
	if _hq._view == _hq.View.TABLE:
		_hq._move_camera_to(_hq._station_xform(_hq.View.TABLE), true)
	_select_target_under_center()


# The map-plane point currently under the table camera's centre. The camera looks at
# hq_table_cam_look, offset by the live pan (see _station_xform), so the centre is just
# that look point shifted by _table_pan — i.e. where a ray down the camera's centre
# meets the map. Selection tracks whichever target lies nearest here.
func _table_center_pos() -> Vector3:
	var cfg: GameConfig = Config.data
	return Vector3(cfg.hq_table_cam_look.x + _hq._table_pan.x, 0.0, cfg.hq_table_cam_look.z + _hq._table_pan.z)


# Seat the cursor on the highest-difficulty rally pin the player hasn't completed yet,
# panning the camera to it. Difficulty is the hidden authored tier; ties break toward
# the first such pin in rally order (targets are built in that order). Completed pins are
# skipped. Returns false when there's no incomplete pin (all done, or no pins at all),
# leaving the caller to seat focus some other way.
func _focus_hardest_incomplete() -> bool:
	var targets := _table_targets()
	var best := -1
	var best_diff := -1
	for i in targets.size():
		var t: Dictionary = targets[i]
		if String(t["kind"]) != "pin":
			continue
		var rally_id := String((t["node"] as Node3D).get_meta("rally_id"))
		if Save.rally_completed(rally_id):
			continue
		var rally := RallyLibrary.by_id(rally_id)
		var diff := int(rally.get("difficulty", 0)) if not rally.is_empty() else 0
		if diff > best_diff:
			best_diff = diff
			best = i
	if best < 0:
		return false
	_focus_table_target(best, true)  # pan the camera onto it so selection sticks
	return true


# The target nearest the view centre as [index, distance_m] — index -1 when the table has
# no targets at all. Shared by the two seating rules below, which differ ONLY in whether
# map_select_radius_m applies: it is the rule for a cursor the PLAYER is driving, not for
# seating one.
func _nearest_target_to_center() -> Array:
	var targets := _table_targets()
	var center := _table_center_pos()
	var best := -1
	var best_d := INF
	for i in targets.size():
		var off: Vector3 = Vector3(targets[i]["pos"]) - center
		off.y = 0.0
		var d := off.length()
		if d < best_d:
			best_d = d
			best = i
	return [best, best_d]


# Seat the cursor on the target nearest the view centre AND pan the camera onto it, at any
# distance. This is the entry fallback (_enter_table), which is why map_select_radius_m is
# deliberately NOT applied here: the map has just been re-centred, so "whatever is already
# under the reticle" is usually nothing at all. Returns false when the table has no targets.
func _focus_nearest_target() -> bool:
	var best := int(_nearest_target_to_center()[0])
	if best < 0:
		return false
	_focus_table_target(best, true)
	return true


# Seat the cursor on whichever pin sits nearest the view
# centre, without moving the camera (the player already put it there). This is the
# raycast-to-centre selection that keyboard pan, drag pan, and table entry all share.
func _select_target_under_center() -> void:
	var targets := _table_targets()
	if targets.is_empty():
		_hq._table_focus_index = -1
		_hq._table_focus_node = null
		return
	var nearest := _nearest_target_to_center()
	var best := int(nearest[0])
	# Nothing is selected unless the view is actually ON a pin. The cursor used to snap to
	# the nearest pin at any distance, so Enter over empty sea opened whichever rally was
	# least far away — a menu for somewhere the player was not looking.
	if best < 0 or float(nearest[1]) > Config.data.map_select_radius_m:
		_clear_table_focus()
		return
	# Repaint ONLY when the selection actually changed. This runs every frame while a pan
	# direction is held (_pan_table_step), and _focus_table_target repaints every pin, so
	# without this guard each frame allocated a StyleBoxFlat per pin (28 at full unlock) to
	# redraw state that was already correct. Compared on the node, not the index — see
	# _table_focus_node.
	if targets[best]["node"] == _hq._table_focus_node:
		return
	_focus_table_target(best, false)


# Drop the cursor entirely: nothing selected, no highlight, and every hover-only readout
# closed. NOT _focus_table_target(-1) — that clamps into range and would select the first
# pin, which is the opposite of "nothing here".
func _clear_table_focus() -> void:
	_hq._table_focus_index = -1
	_hq._table_focus_node = null
	for t in _table_targets():
		var node: Node3D = t["node"]
		if node.has_meta("label_panel"):
			UITheme.mark_panel_focused(node.get_meta("label_panel"), false)
		if node.has_meta("label_sprite"):
			var sprite: Node3D = node.get_meta("label_sprite")
			if is_instance_valid(sprite):
				sprite.visible = false


# Seat the cursor on target `i`, paint the focus highlight (the hover-style readout
# underline), and (when `pan`) slide the map so the focused pin centres under the
# table camera.
func _focus_table_target(i: int, pan := true) -> void:
	var targets := _table_targets()
	if targets.is_empty():
		_hq._table_focus_index = -1
		_hq._table_focus_node = null
		return
	_hq._table_focus_index = clampi(i, 0, targets.size() - 1)
	var sel: Dictionary = targets[_hq._table_focus_index]
	_hq._table_focus_node = sel["node"]
	for t in targets:
		var on: bool = t == sel
		var node: Node3D = t["node"]
		if node.has_meta("label_panel"):
			UITheme.mark_panel_focused(node.get_meta("label_panel"), on)
		# HOVER-ONLY readouts, with NO exceptions: a pin shows its box only while the cursor
		# is on it, so the table reads as a MAP with one thing selected rather than a
		# noticeboard of a dozen open menus competing for the eye. The 3D marker still stands
		# at every pin, so nothing is hidden — only the menu chrome is.
		if node.has_meta("label_sprite"):
			var sprite: Node3D = node.get_meta("label_sprite")
			if is_instance_valid(sprite):
				sprite.visible = on
	if pan:
		_pan_table_to(Vector3(sel["pos"]))


# Fire the focused target: open the pin's rally detail.
func _activate_table_focus() -> void:
	var targets := _table_targets()
	if _hq._table_focus_index < 0 or _hq._table_focus_index >= targets.size():
		return
	var t: Dictionary = targets[_hq._table_focus_index]
	match String(t["kind"]):
		"pin":
			# A hovered-but-unreached prize pin is a preview, not a destination — its label
			# is readable, its detail panel is not.
			if bool((t["node"] as Node3D).get_meta("locked", false)):
				return
			_on_rally_pin(String((t["node"] as Node3D).get_meta("rally_id")))


# Slide the map so `target` (a table-plane world position) centres under the table
# camera's look point, clamped to the map extents (as a finger-drag would).
func _pan_table_to(target: Vector3) -> void:
	var cfg: GameConfig = Config.data
	var half: Vector2 = cfg.hq_map_plane_size
	_hq._table_pan.x = clampf(target.x - cfg.hq_table_cam_look.x, -half.x * 0.5, half.x * 0.5)
	_hq._table_pan.z = clampf(target.z - cfg.hq_table_cam_look.z, -half.y * 0.5, half.y * 0.5)
	if _hq._view == _hq.View.TABLE:
		_hq._move_camera_to(_hq._station_xform(_hq.View.TABLE), false)


# A pin was tapped: CENTRE ON IT FIRST, then open its detail.
#
# The camera used to stay put and the panel just appeared, which left the pin you tapped
# somewhere off at the edge of the table — so on closing the panel you were looking at a
# different part of the map than the rally you had just been reading about, and the cursor
# (which tracks whatever is nearest the view centre) had moved on to something else
# entirely. Centring first keeps tapping and the keyboard cursor in agreement: both end up
# with the same rally selected AND under the camera.
#
# Awaits the glide so the movement is visible rather than being covered by the panel the
# instant it starts. menu_camera_move_time == 0 (the snap case, and the headless tests)
# falls through with no wait at all.
func _on_rally_pin(rally_id: String) -> void:
	_hq._selected_rally_id = rally_id
	var pin := _node_with_rally_id(_hq._pins, rally_id)
	if pin != null:
		# Already under the camera? Then there is nothing to glide, and no reason to make the
		# player wait — this is the keyboard/gamepad path, where the cursor centred the pin
		# before Select was ever pressed.
		#
		# Measured in the map PLANE, like every other distance the table compares against
		# map_select_radius_m (see _nearest_target_to_center). A pin sits a table-height above
		# the plane the view centre lies in, so a straight distance_to() carries that height in
		# and never came under the radius — the keyboard path always sat through a 0.6 s glide
		# that moved the camera nowhere.
		var to_pin: Vector3 = pin.position - _table_center_pos()
		to_pin.y = 0.0
		var already: bool = to_pin.length() <= Config.data.map_select_radius_m
		_pan_table_to(pin.position)
		_select_target_under_center()
		var glide: float = Config.data.menu_camera_move_time
		if not already and glide > 0.0 and _hq.is_inside_tree():
			await _hq.get_tree().create_timer(glide).timeout
			# The player can leave the table (or tap elsewhere) mid-glide; opening the panel
			# then would drop them into a menu they have navigated away from.
			if _hq._view != _hq.View.TABLE or _hq._selected_rally_id != rally_id:
				return
	_show_detail()


# Show the detail panel for the selected rally (a sub-state of the TABLE view).
func _show_detail() -> void:
	var rally := RallyLibrary.by_id(_hq._selected_rally_id)
	# The stage COUNT is all the per-stage detail the panel shows now — it rides on the
	# title ("Coastal Sprint - 3 stages") instead of a whole left-hand column.
	var stage_count: int = (rally.get("events", []) as Array).size()
	_hq._detail_title.text = "%s - %d %s" % [
		String(rally.get("name", "?")), stage_count,
		"stage" if stage_count == 1 else "stages"]
	var region := String(rally.get("region", ""))
	_hq._detail_region.text = region  # UITheme.enforce uppercases it
	_hq._detail_region.visible = region != ""
	# Difficulty is a hidden tier (it drives reward value, not anything the player
	# sees) — the eligible-car requirement is the visible gate. The gold chip marks a
	# star-gated special event.
	_hq._detail_special.visible = RallyLibrary.is_special(rally)

	# --- Eligibility: restriction + how many of the player's cars can enter.
	_hq._detail_restriction.text = _hq._restriction_text(rally.get("restriction", {}))
	var elig := _hq._eligibility_summary(rally, Save.profile.get("cars", []))
	var total := int(elig["total"])
	var qualify := int(elig["qualify"])
	if total == 0:
		_hq._detail_qualify.text = "No cars owned yet"
		_hq._detail_qualify.add_theme_color_override("font_color", UITheme.INK_DIM)
	elif qualify == 0:
		_hq._detail_qualify.text = "No cars qualify"
		_hq._detail_qualify.add_theme_color_override("font_color", UITheme.RED)
	else:
		_hq._detail_qualify.text = _hq._qualifying_cars_text(elig["names"])
		_hq._detail_qualify.add_theme_color_override("font_color", UITheme.GREEN)
	var adjust := int(elig["adjust"])
	_hq._detail_adjust.visible = adjust > 0
	_hq._detail_adjust.text = "%d need a tune / swap to fit" % adjust
	# No owned car qualifies for this rally yet — the button would only lead to an
	# empty car park, so disable it rather than let the player tap through to it.
	_hq._detail_enter_button.disabled = qualify == 0

	# --- Record: best finish + medal stars.
	var best := Save.best_placement(_hq._selected_rally_id)
	_hq._detail_record.text = "Best: P%d" % best if best > 0 else "Not yet completed"
	# The star row always shows, unrun or not — an empty row of three reads as
	# "no medals yet" and keeps the record line's layout stable between rallies.
	_hq._detail_stars.visible = true
	_hq._detail_stars.setup(_hq._stars_for(_hq._selected_rally_id), _hq.MAX_STARS)

	_hq._detail_open = true
	_hq._view = _hq.View.TABLE
	_hq._update_overlays()


func _hide_detail() -> void:
	_hq._detail_open = false
	_hq._update_overlays()
