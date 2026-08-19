class_name HqTuningLift
extends RefCounted
# Docs: features/hq.md, features/tuning.md, features/upgrade-catalogue.md — update in the same
# change as this file.
# Tests: tests/headless/test_hq_tuning_lift.gd, tests/headless/test_menu_flow.gd,
# tests/headless/test_lineup_cache.gd, tests/headless/test_wheel_customization.gd — extend in
# the same change. These are the PRIMARY ones, not all of them: before you change behaviour
# here, `grep -rn '_enter_lift\|_ensure_lift_car\|HqTuningLift' tests/headless/` and read the
# assertions that pin what you are about to change.
# The TUNING LIFT station (todo/menus.md rig 4): entering the bay, raising/lowering the car and
# its beam, the two-row HUB cursor (car selector + actions), the Upgrades / Tuning sub-pages,
# the lift's display car (spawn / reuse / stow), the Repair action and Test Drive. Cut out of
# hq.gd to shrink it; nothing about the behaviour changed, this is a code move plus the `_hq.`
# wiring.
#
# INPUT: `handle_input` is the LIFT branch of hq.gd's `_unhandled_input` dispatch — reached the
# same way HqTable.handle_input / HqCarpark.handle_input / HqMultiplayer.handle_input are, and
# it answers whether the event was this station's to act on. It was `hq._lift_input` before the
# cut; the routing is unchanged.
#
# Holds a back-reference to the HqController and reaches into it for state, widgets and node
# parenting — the same shape as HqOverlays / HqChallenge / HqMultiplayer / HQEnvironment.
#
# WHAT STAYED ON HqController, deliberately:
#   * every lift STATE field and WIDGET (_lift_car, _lift_page, _lift_row, _lift_raised,
#     _lift_tween, _hub_focus, the cursors, _lift_repair_button, _tune_panel, …). hq_overlays.gd
#     BUILDS those widgets and update_overlays / go_to read the flags, so they are shared, not
#     this file's private state — the same split HqMultiplayer uses for its overlay widgets.
#   * thin forwarders for every entry point hq_overlays.gd, the tests and hq.gd itself already
#     call by name (_enter_lift, _lift_hub, _cycle_lift_car, _test_drive, …). Renaming those
#     call sites is not a behaviour-preserving move, so the names stay put and delegate here.

var _hq: HqController


func _init(hq: HqController) -> void:
	_hq = hq


# --- Tuning lift (features/tuning.md / todo/menus.md rig 4) ----------------------

# Enter the tuning bay: raise the selected car on the lift, frame it to one side, and
# show the HUB (car description + Upgrades/Tuning buttons + Test Drive).
func _enter_lift() -> void:
	_ensure_lift_car()
	_hq._lift_page = HqController.LiftPage.HUB
	_hq._lift_row = HqController.LiftRow.ACTIONS  # ...on the actions row, not the car selector above it
	_hq._hub_focus = 1  # the cursor starts on Upgrades each time we enter the bay
	_refresh_lift_ui()
	_hq.go_to(HqController.View.LIFT)
	_raise_lift_car()  # slowly raise the car on the lift as we arrive


# Raise / lower the car on the lift to its target pose. Lowering is the garage rest
# pose; raising is the bay pose. Both animate over hq_lift_raise_time.
func _raise_lift_car() -> void:
	_hq._lift_raised = true
	_apply_lift_height(true)


func _lower_lift_car() -> void:
	_hq._lift_raised = false
	_apply_lift_height(true)


# The car's CALCULATED body rest location (car.gd settled_ride_height) — how high its
# body sits above the plane its wheels rest on, settled on its own suspension. This is
# the LOWERED pose's ride height (a low sports car sits lower than a tall 4x4). Callers
# only reach the lowered pose with a car raised; the 0.0 guards a null deref and is never
# used in practice.
func _lift_car_lowered_height() -> float:
	return _hq._lift_car.settled_ride_height() if is_instance_valid(_hq._lift_car) else 0.0


# World-space Y of the car origin for the lowered / raised pose.
#   LOWERED — the car rests on the FLOOR (hq_lift_pos.y, the lot's y=0 collision floor)
#     at its own settled ride height: exactly how it sits parked, wheels on the ground.
#     NOT measured from the platform top — the beam tucks between the wheels, it does not
#     hold the car up when down.
#   RAISED  — the car sits on top of the beam, hq_lift_car_height above the platform top.
func _lift_car_y(raised: bool) -> float:
	var cfg: GameConfig = Config.data
	if raised:
		return cfg.hq_lift_pos.y + cfg.hq_lift_platform_size.y + cfg.hq_lift_car_height
	return cfg.hq_lift_pos.y + _lift_car_lowered_height()


# World-space Y of the platform beam's CENTRE. Lowered it rests on the floor; raised it
# climbs by the SAME delta the car climbs, so the beam stays tucked under the chassis.
func _lift_platform_y(raised: bool) -> float:
	var cfg: GameConfig = Config.data
	var base := cfg.hq_lift_pos.y + cfg.hq_lift_platform_size.y * 0.5
	var rise := _lift_car_y(true) - _lift_car_y(false)
	return base + (rise if raised else 0.0)


# Move the lift car to its current target height (_lift_raised), tweening unless
# animate is false / the time is 0. The tween is owned by HQ (not the frozen car), so
# it ticks regardless of the car's disabled process mode.
func _apply_lift_height(animate: bool) -> void:
	if not is_instance_valid(_hq._lift_car):
		return
	var target := _lift_car_y(_hq._lift_raised)
	var plat_target := _lift_platform_y(_hq._lift_raised)
	var plat := _hq._env.lift_platform if _hq._env != null else null
	if _hq._lift_tween != null and _hq._lift_tween.is_valid():
		_hq._lift_tween.kill()
	if not animate or Config.data.hq_lift_raise_time <= 0.0:
		var p := _hq._lift_car.global_position
		p.y = target
		_hq._lift_car.global_position = p
		_hq._lift_car.settle_wheels_to_ground(_hq._lift_car.ground_raycast())
		if is_instance_valid(plat):
			var pp := plat.global_position
			pp.y = plat_target
			plat.global_position = pp
		return
	_hq._lift_tween = _hq.create_tween()
	_hq._lift_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_hq._lift_tween.tween_property(_hq._lift_car, "global_position:y", target, Config.data.hq_lift_raise_time)
	# The beam rides up/down with the car (a real 2-post lift), tweened in parallel.
	if is_instance_valid(plat):
		_hq._lift_tween.parallel().tween_property(plat, "global_position:y", plat_target, Config.data.hq_lift_raise_time)
	# Re-droop the wheels each frame as the car's Y animates: they rest on the lot floor
	# when down and extend to full droop (dangle) as the lift raises. Parallel so it runs
	# alongside the height tween; guarded in case the car frees mid-tween.
	_hq._lift_tween.parallel().tween_method(
		func(_v: float) -> void:
			if is_instance_valid(_hq._lift_car):
				_hq._lift_car.settle_wheels_to_ground(_hq._lift_car.ground_raycast()),
		0.0, 1.0, Config.data.hq_lift_raise_time)


# Back out of the bay one level: a sub-menu page returns to the hub; the hub returns
# to the garage. (The hub's own Back-to-garage button goes straight to the garage.)
func _lift_back() -> void:
	if _hq._lift_page == HqController.LiftPage.HUB:
		_hq.go_to(HqController.View.GARAGE)
	else:
		_lift_hub()


# Open a sub-menu (TUNE / UPGRADES) as its own full-height page. These pages use
# native focus (sliders / install buttons), so drop the cursor onto the first control.
func _open_lift_page(page: int) -> void:
	_hq._lift_page = page
	_refresh_lift_ui()
	# _tune_panel and _lift_upgrades_box are unrelated Control subtypes, so assign in a
	# branch rather than a ternary (whose operands would be type-incompatible).
	var box: Control
	if page == HqController.LiftPage.TUNE:
		box = _hq._tune_panel
	else:
		box = _hq._lift_upgrades_box
	# Seat the cursor on the page body's first control, else on the shared Back button
	# (a fresh car's Upgrades body has no focusable control, so it'd otherwise be dead).
	_grab_lift_page_focus.bind(box).call_deferred()


# Return from a sub-menu to the bay hub (restores the up/down hub cursor highlight).
# The hub navigates by hand (left/right cycles the car), so release the native focus
# the sub-page's sliders/buttons held.
func _lift_hub() -> void:
	_hq._lift_page = HqController.LiftPage.HUB
	_hq._release_all_focus()
	_refresh_lift_ui()


# Move the cursor left/right WITHIN the row it currently sits on: between the two chevrons
# on the selector row, or between Back (0), Upgrades (1), Tuning (2) and Test Drive (3) on
# the actions row. Wraps at the ends of that row and repaints.
func _move_hub_focus(step: int) -> void:
	if _hq._lift_row == HqController.LiftRow.SELECTOR:
		_hq._lift_selector_focus = _hq._lift_selector_cursor.wrapped(_hq._lift_selector_focus, step)
	else:
		_hq._hub_focus = _hq._hub_cursor.wrapped(_hq._hub_focus, step)
	_refresh_hub_focus()


# Move the cursor BETWEEN the HUB's two rows (up to the car selector, down to the actions).
# A no-op toward a row with no live stops — with a single car owned the chevrons are hidden
# AND disabled (_refresh_lift_car_label), so up must not strand the cursor on a button that
# isn't on screen.
func _move_lift_row(row: int) -> void:
	if row == _hq._lift_row:
		return
	if row == HqController.LiftRow.SELECTOR and not _selector_has_stops():
		return
	_hq._lift_row = row
	# Re-seat onto a live item in the row we just arrived at.
	if _hq._lift_row == HqController.LiftRow.SELECTOR:
		_hq._lift_selector_focus = _hq._lift_selector_cursor.settled(_hq._lift_selector_focus)
	else:
		_hq._hub_focus = _hq._hub_cursor.settled(_hq._hub_focus)
	_refresh_hub_focus()


# Is the car selector navigable? False when there is nothing to cycle to, in which case the
# HUB collapses to its single actions row.
# Does the selector row hold ANYTHING the cursor can land on?
#
# Asks the row's own cursor rather than the prev chevron, which is what it used to do. That
# was fine while the chevrons were the row's only members, but Repair lives here now, and
# with ONE car owned both chevrons are disabled — so the old test refused the whole row and
# took Repair with it, leaving it pointer-only in exactly the fresh-career state (one car,
# possibly damaged) this station exists for. CLAUDE.md: no menu ships pointer-only.
func _selector_has_stops() -> bool:
	for button in _hq._lift_selector_cursor.buttons:
		if is_instance_valid(button) and not (button as BaseButton).disabled:
			return true
	return false


# Fire the item the cursor sits on, in whichever row it sits: a chevron swaps the car on the
# lift, or on the actions row 0 backs out to the garage, 1/2 open the Upgrades / Tuning
# pages, 3 launches a Test Drive (free roam with the car on the lift).
func _activate_hub_focus() -> void:
	if _hq._lift_row == HqController.LiftRow.SELECTOR:
		_hq._lift_selector_cursor.activate(_hq._lift_selector_focus)
	else:
		_hq._hub_cursor.activate(_hq._hub_focus)


# Paint the manual HUB cursor (the hub uses left/right + up/down + select, not native focus,
# so its buttons are highlighted by hand). Exactly ONE row carries a highlight: the inactive
# row is repainted at an out-of-range index, which clears every button in it — otherwise
# both rows would show a cursor and neither would look active.
func _refresh_hub_focus() -> void:
	var on_selector := _hq._lift_row == HqController.LiftRow.SELECTOR
	_hq._lift_selector_cursor.refresh(_hq._lift_selector_focus if on_selector else -1)
	_hq._hub_cursor.refresh(-1 if on_selector else _hq._hub_focus)


# Seat the sub-page cursor: the body's first focusable control, or the shared Back
# button when the body has none (a fresh car's Upgrades page — see UpgradesGrid.rebuild)
# so the page is never dead to keyboard/gamepad.
func _grab_lift_page_focus(box: Node) -> void:
	var first := UITheme.first_focusable(box)
	UITheme.focus_grab(first if first != null else _hq._lift_back_button)


# Spawn (or keep) the selected car raised on the lift. No-op if the right car is
# already there. The lift car is frozen immediately (wheels hang, as on a ramp).
func _ensure_lift_car() -> void:
	var owned := Save.selected_car()
	if owned.is_empty():
		_clear_lift_car()
		return
	var id := int(owned.get("instance_id", -1))
	var owned_hash := owned.hash()
	# The id/hash match alone is NOT enough to skip re-showing it: _lift_car shares its
	# node with _car_cache (see _spawn_lift_car), and the garage picker's parked lineup
	# borrows that very node while open (_obtain_parked_car) then HIDES + STOWS it on the
	# way out (_release_page_props / _clear_lineup, called by _car_back before _enter_lift
	# on the modes that return to the bay). Reselecting the SAME car — or arriving back on
	# the lift — hits this id/hash match with the node still
	# stowed off-screen from that hide — the "car vanishes from the lift" bug. Requiring
	# `.visible` too forces the fall-through spawn path below, whose _car_cache hit just
	# reconfigures (not rebuilds) the node back onto the lift — cheap, and correct.
	if is_instance_valid(_hq._lift_car) and _hq._lift_car_instance_id == id and _hq._lift_car_hash == owned_hash \
			and _hq._lift_car.visible:
		_hq._lift_owned = owned
		return
	_clear_lift_car()
	_hq._lift_owned = owned
	_hq._lift_car_instance_id = id
	_hq._lift_car_hash = owned_hash
	_hq._lift_car = _spawn_lift_car(owned)
	# Snap the freshly-spawned car (and its beam) to the current target pose. The provisional
	# spawn height was computed before _lift_car existed; now that it does, _apply_lift_height
	# re-derives the LOWERED pose from the car's own settled ride height and conforms its
	# wheels to the platform — a respawn while raised appears already dangling, while lowered,
	# resting at the car's true rest.
	if is_instance_valid(_hq._lift_car):
		_apply_lift_height(false)


func _clear_lift_car() -> void:
	if _hq._lift_tween != null and _hq._lift_tween.is_valid():
		_hq._lift_tween.kill()  # the tween targets the car we're about to free
	if is_instance_valid(_hq._lift_car):
		var cached: Dictionary = _hq._car_cache.get(_hq._lift_car_instance_id, {})
		if cached.get("node") == _hq._lift_car:
			# This node is also the warm _car_cache entry for this car (built or
			# borrowed via _spawn_lift_car below) — don't free it, just hide + stow it,
			# exactly like _release_page_props does for parked cars, so the car park /
			# Free Roam / a future lift visit can reuse it with no re-instancing.
			_hq._lift_car.visible = false
			_hq._lift_car.global_position = _hq._carpark_ui._prewarm_stow_marker().global_position
		else:
			_hq._lift_car.queue_free()
	_hq._lift_car = null
	_hq._lift_car_instance_id = -2
	_hq._lift_car_hash = 0


# Build (or reuse) the selected car as a silent, frozen prop on the lift platform at
# the current pose height (lowered in the garage, raised in the bay — so a re-spawn
# while raised appears already raised). Its own mesh copies, like the car-park props
# (CarProp.dup_meshes).
#
# Checks _car_cache first: this car may already be warm from the garage picker's
# parked lineup, the title lineup, or a previous lift visit (car.tscn embeds every
# car glb, so CarProp.spawn — instantiate + prune 8 unused bodies + dup_meshes — is
# the expensive step; that's the "small lag on every tuning-lift car swap" this
# avoids). GARAGE/LIFT and CARPARK views are mutually exclusive (see
# _evict_unowned_cached_cars), so borrowing a parked-lineup node for the lift, and
# handing it back on _clear_lift_car, is safe.
func _spawn_lift_car(owned: Dictionary) -> Node3D:
	var cfg: GameConfig = Config.data
	var xform := Transform3D.IDENTITY
	xform.origin = Vector3(cfg.hq_lift_pos.x, _lift_car_y(_hq._lift_raised), cfg.hq_lift_pos.z)
	var configure := func(c) -> void: c.global_transform = xform
	var instance_id := int(owned.get("instance_id", -1))
	var owned_hash := owned.hash()
	var cached: Dictionary = _hq._car_cache.get(instance_id, {})
	var node = cached.get("node")
	if is_instance_valid(node) and int(cached.get("hash", 0)) == owned_hash:
		# Already warm — reconfigure the cached node for lift display instead of
		# paying the full CarProp.spawn cost again. Smoke was already attached the
		# first time this node was built (spawn attaches it once; reuse never re-adds
		# it — see _obtain_parked_car / _warm_one_preview, which follow the same rule).
		configure.call(node)
		node.process_mode = Node.PROCESS_MODE_DISABLED
		node.visible = true
		return node
	if is_instance_valid(node):
		node.queue_free()
	# Parented to the HQ node (`_hq`), NOT to this RefCounted collaborator — the prop has to
	# live in the scene tree, and before the cut this read `self` inside hq.gd.
	var fresh := CarProp.spawn(_hq, _hq._car_scene_res(), {
		"owned": owned,
		"configure": configure,
		"disable_process": true,
		"smoke": _hq._carpark_ui._add_synthetic_smoke,
	})
	_hq._car_cache[instance_id] = {"hash": owned_hash, "node": fresh}
	return fresh


# Refresh the whole menu for the current selected car: name + stats, which menu is
# shown, the sliders' gating/values, and the upgrades list.
func _refresh_lift_ui() -> void:
	_hq._lift_owned = Save.selected_car()
	_refresh_lift_car_label()
	# Show the hub (car selector + menu buttons) or a sub-menu page from _lift_page.
	# The car description hides while a sub-menu is open so the centred page has room.
	_hq._lift_hub_controls.visible = _hq._lift_page == HqController.LiftPage.HUB
	_hq._lift_info_panel.visible = _hq._lift_page == HqController.LiftPage.HUB
	_hq._lift_menu_bg.visible = _hq._lift_page != HqController.LiftPage.HUB
	_hq._lift_page_actions.visible = _hq._lift_page != HqController.LiftPage.HUB
	_hq._tune_panel.visible = _hq._lift_page == HqController.LiftPage.TUNE
	_hq._lift_upgrades_box.visible = _hq._lift_page == HqController.LiftPage.UPGRADES
	# TUNE hides the page title to reclaim vertical space (its sliders must fit
	# without scrolling); UPGRADES keeps its heading.
	# The ROW, not the label, so any sibling the heading grows hides with it.
	# Re-bind the TUNE panel to the current owned car and reflect its stored tuning.
	# on_change is a no-op: the HQ lift did not re-field the display car on a tune edit
	# (the change lands on next fielding), so preserve that behaviour.
	_hq._tune_panel.setup(_hq._lift_owned, Callable(), _hq._enter_wheel_swap)
	_hq._tune_panel.refresh()
	# The TUNE page's actions act on the sliders, so they show only while that page is up —
	# they share the bottom row with a "< Back" that belongs to both pages. Set AFTER
	# setup(), which reasserts the Wheels button's own visibility every refresh.
	for b in _hq._tune_action_buttons:
		b.visible = _hq._lift_page == HqController.LiftPage.TUNE
	# NO_LIMIT is deliberate and explicit, not an omitted argument: the garage isn't a
	# commitment point (nothing launches from the lift), so no p/w ceiling gate belongs
	# here — the gate lives at the start line / car park where a car is actually
	# committed to an event.
	_hq._lift_upgrades_box.setup(_hq._lift_owned, _on_lift_upgrade_changed, _hq._enter_engine_swap,
		UpgradesGrid.NO_LIMIT)
	_hq._hub_focus = _hq._hub_cursor.settled(_hq._hub_focus)  # keep the cursor on a live item
	_refresh_hub_focus()  # keep the left/right hub cursor highlight in step
	_hq._normalize_menus()  # re-apply house rules to the freshly-built upgrade rows


# The lift's UpgradesGrid on_change: a part / drivetrain edit changed the car's spec,
# so respawn the display prop (its hash flipped) and refresh the lift name + stats to
# match — the component has already rebuilt its own rows + stats line.
func _on_lift_upgrade_changed() -> void:
	_ensure_lift_car()
	_hq._lift_owned = Save.selected_car()
	_refresh_lift_car_label()
	# The balance is repainted by the component's own rebuild() (UpgradesGrid), so nothing
	# to re-read here.


# The UPGRADES page heading.
#
# The Dev settings page fits a part straight onto Save.selected_instance_id() with no
# reference back to the lift, so it can't rebuild the display car itself the way
# _on_lift_upgrade_changed does. Same fix, reached via SettingsMenu.dev_car_upgraded
# instead of the upgrades-menu callback: rebuild (the changed installed_upgrades flips
# owned.hash(), so _ensure_lift_car's cache correctly treats it as stale) and re-read
# the stats line, so a dev-fitted part (nitrous included) shows up without having to
# leave and re-enter the lift.
func _on_dev_car_upgraded() -> void:
	_ensure_lift_car()
	_hq._lift_owned = Save.selected_car()
	_refresh_lift_car_label()


# Fill the lift's two readout rows for the current owned car — the name in the selector
# row's middle box, its stats on the row below — and gate the chevrons on there being
# something to cycle to. With one car owned they are hidden AND disabled: hidden so the row
# reads as a plain nameplate, disabled so neither cursor nor click can reach a button that
# isn't on screen (ButtonCursor skips disabled stops, but knows nothing of visibility).
func _refresh_lift_car_label() -> void:
	var entry := CarLibrary.for_owned(_hq._lift_owned)
	_hq._lift_car_label.text = EngineSwap.display_name(entry, _hq._lift_owned)
	_hq._lift_car_stats_label.text = _hq._car_stats_text(_hq._lift_owned, entry)
	var cyclable: bool = _lift_cycle_order().size() > 1
	for chevron in [_hq._lift_prev_button, _hq._lift_next_button]:
		chevron.visible = cyclable
		chevron.disabled = not cyclable
	# Never leave the cursor stranded in a row with nothing live in it (the last other car
	# was sold / wrecked out from under it). Gated on the ROW being empty, not on the
	# chevrons being gone: Repair also lives here, so losing the chevrons no longer empties
	# the row — and ejecting anyway is what made Repair unreachable on a one-car garage.
	if _hq._lift_row == HqController.LiftRow.SELECTOR and not _selector_has_stops():
		_hq._lift_row = HqController.LiftRow.ACTIONS
	elif not cyclable and _hq._lift_row == HqController.LiftRow.SELECTOR:
		# The chevrons went away but the row still has stops — re-seat onto a live one
		# instead of leaving the cursor on a hidden button.
		_hq._lift_selector_focus = _hq._lift_selector_cursor.settled(_hq._lift_selector_focus)


# The owned cars in the order the lift's chevrons walk them, by ASCENDING instance_id — the
# order they were acquired, which is stable.
#
# Deliberately NOT profile["cars"] order: Save.set_selected_car promotes the selected car to
# the FRONT of that array, so cycling by list position would renumber the list on every
# press and ping-pong between two cars instead of touring the collection.
func _lift_cycle_order() -> Array:
	var ids: Array = []
	for car in Save.profile.get(Save.KEY_CARS, []):
		ids.append(int(car.get("instance_id", -1)))
	ids.sort()
	return ids


# Put the previous (-1) / next (+1) owned car on the lift, wrapping at both ends. Fired by
# the selector chevrons — by click, or by a cursor select with the selector row active.
func _cycle_lift_car(step: int) -> void:
	var ids := _lift_cycle_order()
	if ids.size() < 2:
		return
	var here := ids.find(Save.selected_instance_id())
	if here < 0:
		here = 0
	Save.set_selected_car(int(ids[wrapi(here + step, 0, ids.size())]))
	# _ensure_lift_car's id/hash key respawns the prop for the newly selected car; the
	# refresh redraws the name, stats, sliders and upgrade rows to match it.
	_ensure_lift_car()
	_refresh_lift_ui()


# Repair the car on the lift: full health, straight wheels, for the flat star price
# (Save.repair_car, features/star-economy.md). A no-op when the car needs nothing or the
# balance is short — Save re-checks both, so a stale button cannot half-complete.
func _repair_selected_car() -> void:
	var id := Save.selected_instance_id()
	if id < 0 or not Save.repair_car(id):
		return
	# Repaint the hub row and the star meter the purchase just moved. Re-fielding the car
	# on the lift is not needed: repair changes health and wheel toe, neither of which the
	# lift's frozen display prop shows.
	_hq.update_overlays()


# Write the Repair button's label and disabled state. Three states, all readable off the
# button itself rather than hidden: nothing to fix, affordable, or short of stars — the
# price is information the player can act on even when they cannot pay it yet.
func _refresh_repair_button() -> void:
	if not is_instance_valid(_hq._lift_repair_button):
		return
	var id := Save.selected_instance_id()
	if id < 0 or not Save.car_needs_repair(id):
		_hq._lift_repair_button.text = "Repair"
		_hq._lift_repair_button.icon = null   # nothing to pay, so no price star
		_hq._lift_repair_button.disabled = true
		return
	var price := Save.repair_price(id)
	# Same DRAWN price star as the upgrade options (UpgradeSlotPopup._option_button): the ★
	# character this label used to carry has no glyph in Syne Mono and rendered as a tofu
	# box in the web export, which has no system font to fall back on.
	_hq._lift_repair_button.text = "Repair %d" % price
	_hq._lift_repair_button.icon = StarRow.price_icon()
	_hq._lift_repair_button.icon_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_hq._lift_repair_button.disabled = Save.stars_available() < price


# Test Drive from the tuning bay: launch free roam with the car currently on the lift —
# no car picker, we're already focused on one. Fields the OWNED (tuned) instance.
func _test_drive() -> void:
	var id := Save.selected_instance_id()
	if id < 0:
		return
	await _hq._launch_free_roam(id, "")


# --- Input (the LIFT branch of hq.gd's _unhandled_input dispatch) ------------

# The whole keyboard/gamepad contract for this station, in the order its sub-states nest: the
# HUB's two cursor rows first, then the sub-menu pages (which navigate by NATIVE focus, so
# only Back is handled here). Returns true when the event was this station's to act on — the
# same contract as HqTable.handle_input / HqCarpark.handle_input.
#
# This was `hq._lift_input` before the cut, reached from the same `match _view` arm. Nothing
# about which input goes where changed: only the function's home and its name.
func handle_input(event: InputEvent) -> bool:
	if _hq._lift_page == HqController.LiftPage.HUB:
		# Hub: two cursor rows (see LiftRow). up/down move between the car
		# selector and the actions row, left/right move within whichever row is
		# active, select fires it, menu_back is a shortcut to the garage.
		if event.is_action_pressed("menu_up"):
			_move_lift_row(HqController.LiftRow.SELECTOR)
		elif event.is_action_pressed("menu_down"):
			_move_lift_row(HqController.LiftRow.ACTIONS)
		elif event.is_action_pressed("menu_left"):
			_move_hub_focus(-1)
		elif event.is_action_pressed("menu_right"):
			_move_hub_focus(1)
		elif event.is_action_pressed("menu_select"):
			_activate_hub_focus()
		elif event.is_action_pressed("menu_back"):
			_hq.go_to(HqController.View.GARAGE)
		else:
			return false
		return true
	if event.is_action_pressed("menu_back"):
		_lift_hub()  # a sub-menu page backs out to the hub (its controls use
		# native focus for up/down/left-right/select)
		return true
	return false
