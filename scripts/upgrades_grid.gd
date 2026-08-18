class_name UpgradesGrid
extends VBoxContainer
# Docs: features/engine-swap.md — update in the same change as this file.
# Tests: tests/headless/test_engine_swap.gd, tests/headless/test_save_manager.gd, tests/headless/test_upgrade_library.gd — extend in the same change.
# THE per-car upgrades view — one screen, no sub-pages. A heading carrying the player's
# star BALANCE, a single PERFORMANCE line, and a 3x3 grid of icon TILES, one per slot:
# the seven catalogue slots plus the two pseudo-slots (engine swap, engine detune), which
# are tiles here rather than rows of their own because they are the same kind of decision
# ("what does this car run in this respect?") and a menu that answers one question two
# different ways is a menu you have to learn.
#
# Each tile reads "<slot>: <value>" under its icon and opens a picker (UpgradeSlotPopup)
# for that slot alone. Nine tiles at a glance is the whole point: the player sees the
# ENTIRE build without scrolling or drilling, and depth lives one press away instead of
# one page away.
#
# Owns its Save persistence and reports edits via on_change so the host can re-field the
# car. Four hosts: the HQ lift (hq.gd — the only one wiring an engine-swap action), the car
# park's Change-Upgrades popup, the start line, and the upgrade reveal. What each slot
# OFFERS is UpgradeOptions' job, not this file's. See features/upgrade-catalogue.md.

# "No performance ceiling applies". A local mirror of DrivingContext.NO_LIMIT's value —
# this component is per-car and knows nothing about sessions, it just takes a limit — so
# callers computing "no limit" have a self-documenting way to say so.
const NO_LIMIT := -1.0

# THREE COLUMNS. Nine tiles divide into a square 3x3 block, and three is the most that fits
# the NARROWEST supported frame: the logical canvas bottoms out around 400 units wide
# (DisplayStretch on a portrait/4:3 phone), and the car-park popup hands this component
# ~400 minus its panel chrome. At TILE_MIN_W + the grid separation that is ~350 for three
# across — comfortable — where four would need ~470 and overflow. Four columns would also
# leave a ragged last row of one, which reads as a missing tile.
const COLUMNS := 3

# A tile is an icon over ONE line of label ("drive: AWD"). Sized to that and no more: the
# first pass reserved a second label line and left an obvious band of dead space above
# every icon.
#
# Height = icon + separation + one line at font 12, plus a little breathing room. Width is
# the most three columns can take inside the narrowest supported frame (~400 logical units,
# see COLUMNS) once the grid separation is paid for; tiles also EXPAND_FILL, so on a
# desktop-width page they are wider than this floor.
#
# The label does NOT wrap, so these two constants do not have to grow to fit longer text —
# the text is kept short instead (UpgradeOptions.tile_slot_name / `tile_label`).
const TILE_MIN_W := 112.0
const TILE_MIN_H := 54.0
const ICON_SIZE := 26.0

var _owned: Dictionary = {}
var _on_change: Callable = Callable()
var _on_swap: Callable = Callable()   # valid → the engine tile can actually swap (lift only)
var _rating_limit: float = NO_LIMIT   # CarPerformance rating ceiling; NO_LIMIT = free
var _rating_label: Label = null
var _balance_label: Label = null
var _grid: GridContainer = null
# The host's overlay close button, gated by the rating limit (bind_close_button). Over a
# ceiling it is painted red and refuses to close: the car is simply ineligible, so leaving
# would only defer the refusal to the start line.
var _close_button: Button = null
var _close_button_text := ""
var _on_close: Callable = Callable()
# Where Esc / gamepad-B goes. Owned HERE rather than re-attached by the host after every
# edit, because MenuNav.attach defers a focus GRAB — a host re-attaching to keep its back
# route alive would yank the cursor to the first tile on every change.
var _on_back: Callable = Callable()


# Bind the owned car + host callbacks, then build the grid. on_change() runs after each
# edit so the host re-fields the car. on_swap() (optional) is the engine-swap action; with
# it unset the engine tile still shows what the car runs but cannot start a swap.
# rating_limit (optional) is a CarPerformance ceiling; when >= 0 the bound close button
# blocks proceeding while the live build exceeds it.
func setup(owned_car: Dictionary, on_change := Callable(), on_swap := Callable(),
		rating_limit := NO_LIMIT) -> void:
	_owned = owned_car
	_on_change = on_change
	_on_swap = on_swap
	_rating_limit = rating_limit
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_theme_constant_override("separation", UITheme.GAP_TIGHT)
	rebuild()


# Where back goes from this page ("" leaves it to the host). Survives every rebuild, since
# rebuild re-attaches MenuNav with it.
func set_back_action(on_back: Callable) -> void:
	_on_back = on_back


# The heading's star-balance digits ("" before the first rebuild). A readout, for hosts
# and tests that need to assert the page is showing a LIVE balance rather than a stale one.
func balance_text() -> String:
	return _balance_label.text if is_instance_valid(_balance_label) else ""


# First focusable control, for a host seating the keyboard/gamepad cursor itself.
func first_control() -> Control:
	return UITheme.first_focusable(self)


# Rebuild for the current _owned, preserving focus: remember the focused tile's
# upgrade_focus_key, free the children (NOT the MenuNav child — freeing it would kill
# WASD/gamepad nav), redraw heading + rating + tiles, then re-seat the cursor.
func rebuild() -> void:
	var focus_key := ""
	var focused := get_viewport().gui_get_focus_owner() if is_inside_tree() else null
	if focused != null and focused.has_meta("upgrade_focus_key") and is_ancestor_of(focused):
		focus_key = String(focused.get_meta("upgrade_focus_key"))

	for c in get_children():
		if c is MenuNav:
			continue
		c.queue_free()

	var heading := build_title_row("Upgrades")
	_balance_label = heading["label"]
	add_child(heading["row"])
	# The performance readout leads the grid: it is the ONE number every tile below moves,
	# and under a ceiling it is also the number deciding whether the car may enter at all.
	add_child(_make_rating_row())

	_grid = GridContainer.new()
	_grid.columns = COLUMNS
	_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_grid.add_theme_constant_override("h_separation", 4)
	_grid.add_theme_constant_override("v_separation", 4)
	add_child(_grid)
	for slot in UpgradeOptions.grid_slots():
		_grid.add_child(_make_tile(slot))

	UITheme.enforce(self)
	MenuNav.attach(self, {"on_back": _on_back} if _on_back.is_valid() else {})
	_refresh_close_button()  # an edit can cross the ceiling
	if focus_key != "":
		_restore_focus.bind(focus_key).call_deferred()


# A page HEADING that carries the star balance: "Upgrades            7 *".
#
# The balance rides the heading because this page is where stars are SPENT and the slot
# picker quotes prices, so the player must not have to leave to check what they hold — and
# because vertical space here is scarce, so it goes on a line that had to exist anyway.
# Static so a host that draws its own heading can still get the house one.
#
# Returns {row, label}; the caller keeps the label so its own rebuild can re-read the
# balance. Digits + a DRAWN StarRow, never a star CHARACTER: Syne Mono has no glyph for it,
# so a text star renders as tofu on the web export (see star_row.gd).
static func build_title_row(text: String) -> Dictionary:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 5)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var title := UITheme.title(text)
	# Expand-fill on the title pushes the digits + star flush right, the same
	# label-left / value-right shape every stat row uses.
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	row.add_child(title)
	var label := Label.new()
	label.text = "%d" % Save.stars_available()
	label.add_theme_font_size_override("font_size", UITheme.FONT_SIZE)
	row.add_child(label)
	var star := StarRow.new()
	star.star_radius = StarRow.PRICE_RADIUS
	star.setup(1, 1)
	star.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(star)
	return {"row": row, "label": label}


# --- Tiles --------------------------------------------------------------------

# One grid tile: a focusable Button with an icon over a "<slot>: <value>" label.
#
# The contents are a VBox ANCHORED across the button rather than Button.icon + Button.text,
# because a Button lays out no children of its own — it draws its own icon/text pair on one
# line and ignores anything parented to it. So the column is built by hand, pinned full-rect,
# and set MOUSE_FILTER_IGNORE so clicks fall through to the button underneath it. The tile
# also carries a real custom_minimum_size: UITheme.enforce pins single-line buttons to
# MENU_ROW_H, and while its "no children" test spares a tile from that, the tile still has to
# demand its own height because its children are anchored (they contribute no minimum size).
func _make_tile(slot: String) -> Button:
	var b := Button.new()
	b.focus_mode = Control.FOCUS_ALL
	b.custom_minimum_size = Vector2(TILE_MIN_W, TILE_MIN_H)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.set_meta("upgrade_focus_key", "tile:%s" % slot)  # keep the cursor here across a rebuild
	b.pressed.connect(_on_tile_pressed.bind(slot))
	# A dead tile still SHOWS what is fitted — that is information the player
	# — that is information the player wants either way — it just cannot be pressed, and
	# dims so the difference is visible.
	if not _tile_enabled(slot):
		b.disabled = true
		b.focus_mode = Control.FOCUS_NONE
		b.modulate = UITheme.MUTED
		b.tooltip_text = _disabled_hint(slot)

	var col := VBoxContainer.new()
	col.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_theme_constant_override("separation", 2)
	b.add_child(col)

	var icon := TextureRect.new()
	icon.texture = UpgradeIcons.texture(slot)
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	icon.custom_minimum_size = Vector2(ICON_SIZE, ICON_SIZE)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	col.add_child(icon)

	var label := Label.new()
	label.text = "%s: %s" % [
		UpgradeOptions.tile_slot_name(slot), UpgradeOptions.current_label(_owned, slot)]
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	# ONE LINE, never wrapped: a wrapped tile is a taller tile, and a grid of uneven rows
	# stops reading as a grid. Fitting is handled by keeping the TEXT short rather than by
	# growing the tile — UpgradeOptions.tile_slot_name abbreviates the long slot names and
	# `tile_label` abbreviates the long values (engine shows "V12", not "27L Merlin V12").
	# Clipping stays OFF so that if a future part name does overrun it is visibly wrong
	# here rather than silently truncated in front of the player.
	label.add_theme_font_size_override("font_size", 12)
	col.add_child(label)
	return b


# A tile press: open the picker for that slot. The detune tile is the one exception — it is
# a continuous knob, so it opens a slider instead of a list of percentages.
func _on_tile_pressed(slot: String) -> void:
	if slot == UpgradeOptions.SLOT_TUNE:
		_open_tune_popup()
		return
	if slot == UpgradeOptions.SLOT_ENGINE:
		# NOT a picker of engines. A swap TRADES this car's engine with another car the
		# player owns and spends a token, so the choice being made is "which car", and the
		# host owns the screen that asks it (hq.gd::_enter_engine_swap puts the car park
		# into SWAP mode). Only the HQ lift supplies that action; the other hosts leave the
		# tile inert, which _tile_enabled reflects.
		if _on_swap.is_valid():
			_on_swap.call()
		return
	UpgradeSlotPopup.open(self, _rated_options(slot), _apply_option.bind(slot),
		UpgradeOptions.slot_description(slot))


# The slot's options with the performance rating each one WOULD give the car stamped on.
#
# Stamped on the way into the popup rather than inside UpgradeOptions.options_for because a
# rating is a simulated benchmark lap, and options_for is on the grid's hot path — every
# tile asks it for a caption on every rebuild. Doing it here confines the cost to a picker
# the player actually opened: a handful of sims, memoised by CarPerformance thereafter.
func _rated_options(slot: String) -> Array:
	var out: Array = []
	for opt in UpgradeOptions.options_for(_owned, slot):
		var row: Dictionary = (opt as Dictionary).duplicate()
		row["rating"] = UpgradeOptions.rating_with(_owned, slot, String(row.get("id", "")))
		out.append(row)
	return out


# Whether a tile can be pressed at all.
#
# Dead when the slot offers the player nothing to change: every part in it is still locked,
# or (for engine) a swap is not possible from here. Better to grey the tile than to let the
# player select into it and find a list they cannot act on — the press, the read and the
# back-out all cost something and teach nothing.
func _tile_enabled(slot: String) -> bool:
	if slot == UpgradeOptions.SLOT_ENGINE:
		# The host owns the car picker a swap needs; without it the tile is informational.
		return _on_swap.is_valid() and UpgradeOptions.has_choice(_owned, slot)
	return UpgradeOptions.has_choice(_owned, slot)


# Why a greyed tile is greyed, for its tooltip.
func _disabled_hint(slot: String) -> String:
	if slot == UpgradeOptions.SLOT_ENGINE:
		if not _on_swap.is_valid():
			return "Engine swaps are done in the garage"
		return UpgradeOptions.engine_swap_blocked_reason(_owned)
	return "Nothing unlocked for this slot yet"


func _open_tune_popup() -> void:
	var instance_id := int(_owned.get("instance_id", -1))
	var current := clampf(float(_owned.get("tuning", {}).get("engine_detune", 1.0)), 0.0, 1.0)
	UpgradeSlotPopup.open_slider(self, current * 100.0,
		_apply_detune.bind(instance_id), _detune_label_text,
		UpgradeOptions.slot_description(UpgradeOptions.SLOT_TUNE))


# The detune slider's value label: the car's LIVE power-to-weight at that setting, since
# what the knob actually does is trade power for eligibility. `percent` is the slider's
# value, already written through by the time this is asked for.
func _detune_label_text(_percent: float) -> String:
	var entry := CarLibrary.for_owned(_owned)
	var pw := CarLibrary.power_to_weight(UpgradeLibrary.effective_meta(_owned, entry)) \
		* CarLibrary.KW_KG_TO_HP_TONNE
	return "%.0f HP/T" % pw


# A live detune edit. NO rebuild — a rebuild would drop the slider's drag grab and free the
# popup's host out from under it — so the rating line and the close gate are repainted in
# place instead.
func _apply_detune(percent: float, instance_id: int) -> void:
	if _owned.is_empty():
		return
	var frac := clampf(percent / 100.0, 0.0, 1.0)
	Save.set_engine_detune(instance_id, frac)
	var tuning: Dictionary = _owned.get("tuning", {})
	tuning["engine_detune"] = frac
	_owned["tuning"] = tuning
	_refresh_rating()
	_refresh_close_button()   # dragging power under/over the ceiling toggles the gate
	_refresh_tile_label(UpgradeOptions.SLOT_TUNE)
	if _on_change.is_valid():
		_on_change.call()


# Apply the picked option for `slot`, then re-read + redraw.
#
# WHAT the pick means is decided by UpgradeOptions.option_edit — the same function the
# hypothetical build (UpgradeOptions.build_with) reads, so a rating quoted in the picker and
# the car this produces cannot disagree about the edit. HOW it is performed still lives
# here, and still goes through the SAME Save entry points the slot rows used to, so the
# one-enabled-part-per-slot rule, the purchase re-checks and the reward flow are untouched.
func _apply_option(id: String, slot: String) -> void:
	var instance_id := int(_owned.get("instance_id", -1))
	# The SAVED car, not _owned: option_edit asks "is this part already on the car", and the
	# authority on that is the save. (A synthetic owned-car dict — the component tests and
	# the reward reveal's preview — yields {} here, which reads as "nothing installed", the
	# same answer the old code's Save.get_car(...).get(...) gave.)
	var car := Save.get_car(instance_id)
	var edit := UpgradeOptions.option_edit(car, slot, id)
	match String(edit.get("kind", "none")):
		"none":
			# Not a slot edit. The engine swap is a whole flow the HOST owns (it needs a
			# partner car to pick), so the tile starts it rather than performing it; nothing
			# to re-read here, because the host's flow re-enters this component when it
			# finishes. The detune has its own live path (_apply_detune).
			if slot == UpgradeOptions.SLOT_ENGINE and _on_swap.is_valid():
				_on_swap.call()
			return
		"drive_mode":
			# A layout the car has not paid for is BOUGHT here first, mirroring the part
			# branch below: buy, then select. Reverting to stock (and re-selecting a mode
			# already bought) is free and falls straight through.
			var mode := int(edit["mode"])
			if not Save.drive_mode_available(car, mode) \
					and not Save.buy_drive_mode(instance_id, mode):
				return  # the balance moved under the button; refuse rather than half-apply
			Save.set_drivetrain_override(instance_id, mode)
		"clear_slot":
			_clear_slot(instance_id, slot)
		"enable_part":
			Save.set_upgrade_enabled(instance_id, id, true)
		"fit_part":
			if bool(edit.get("free", false)):
				Save.install_upgrade(instance_id, id, true)   # free ballast: fit + enable
			elif not Save.buy_part(instance_id, id):
				return   # the balance moved under the button; refuse rather than half-apply
			else:
				# ...then switch it on. `buy_part` fits every part PARKED, which is right for
				# the paths that hand a player something they did not ask for (a reward draw,
				# a prize-rally part award): those must never silently change how the car
				# drives. This path is the opposite — the player opened the slot, picked this
				# option and spent stars on it, so leaving it parked means the menu takes the
				# payment and visibly does nothing. Enable is exclusive, so it parks the
				# slot's outgoing part for free. Same buy-then-enable pair
				# Save.apply_build_plan uses.
				Save.set_upgrade_enabled(instance_id, id, true)
	_resync_owned(instance_id)
	rebuild()
	if _on_change.is_valid():
		_on_change.call()


# Disable every applied part in `slot` on the car — the "Stock" state.
func _clear_slot(instance_id: int, slot: String) -> void:
	for def in UpgradeLibrary.all():
		if String(def.get("slot", "")) == slot:
			Save.set_upgrade_enabled(instance_id, String(def.get("id", "")), false)


# Re-read the car after an edit. A car that isn't in the save (a synthetic owned-car dict,
# as the component tests and the reward reveal's preview use) keeps the dict it was handed
# rather than being blanked to {}.
func _resync_owned(instance_id: int) -> void:
	var fresh := Save.get_car(instance_id)
	if not fresh.is_empty():
		_owned = fresh


# Repaint one tile's caption in place, for the edit paths that must not rebuild.
func _refresh_tile_label(slot: String) -> void:
	if _grid == null or not is_instance_valid(_grid):
		return
	for tile in _grid.get_children():
		var b := tile as Button
		if b == null or String(b.get_meta("upgrade_focus_key", "")) != "tile:%s" % slot:
			continue
		for l in b.find_children("*", "Label", true, false):
			(l as Label).text = UITheme.caps("%s: %s" % [slot,
				UpgradeOptions.current_label(_owned, slot)])
		return


# --- Performance readout + the close gate -------------------------------------

# The page's persistent PERFORMANCE line: one number for how fast the whole build is, where
# every tile shows only its own slot. Under a ceiling it also carries the target
# ("512 / 480") and turns red when over, because that is the number deciding whether the car
# may enter at all.
func _make_rating_row() -> Control:
	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", 5)
	var name_label := Label.new()
	name_label.text = UITheme.caps("Performance")
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(name_label)
	_rating_label = Label.new()
	row.add_child(_rating_label)
	_refresh_rating()
	return row


# Repaint the readout in place. Called from every edit path rather than rebuilding the row,
# so a live slider drag keeps its grab.
func _refresh_rating() -> void:
	if _rating_label == null or not is_instance_valid(_rating_label):
		return
	var rating := current_rating()
	if _rating_limit >= 0.0:
		_rating_label.text = "%d / %d" % [rating, roundi(_rating_limit)]
		_rating_label.modulate = (UITheme._role_color("red") if over_rating_limit()
			else Color(1, 1, 1, 1))
	else:
		_rating_label.text = "%d" % rating
		_rating_label.modulate = Color(1, 1, 1, 1)


# The current build's CarPerformance rating — the number the readout shows and the gate
# judges, so the two can never disagree. merged_meta, not effective_meta: the latter omits
# grip and downforce, and a rating blind to tyres and aero would not move when the player
# fits either.
func current_rating() -> int:
	if _owned.is_empty():
		return 0
	return CarPerformance.rating(CarPerformance.merged_meta(_owned, CarLibrary.for_owned(_owned)))


# Whether the current build exceeds the rating ceiling (false when none is set).
func over_rating_limit() -> bool:
	if _rating_limit < 0.0:
		return false
	# Compare the ROUNDED ceiling against the integer rating the player is shown, so a build
	# displaying exactly the limit never reads as "over".
	return current_rating() > roundi(_rating_limit)


# Bind the host overlay's close button so it reflects the rating gate. `on_close` is the
# host's close/back action. With no limit set the button keeps its text and closes freely;
# with a limit set it reads "Done" and, while the build is OVER the ceiling, is painted red
# and refuses to close. Call once after setup(); the page re-paints it on every edit.
func bind_close_button(button: Button, on_close: Callable) -> void:
	_close_button = button
	_close_button_text = "Done" if _rating_limit >= 0.0 else button.text
	_on_close = on_close
	if not button.pressed.is_connected(request_close):
		button.pressed.connect(request_close)
	_refresh_close_button()


# The gated close action: closes via _on_close only when the rating gate is satisfied.
# Wired to the close button's press AND handed to the host's MenuNav as `on_back`, so both
# the button and Esc/controller-back are blocked while over the limit.
func request_close() -> void:
	if can_close() and _on_close.is_valid():
		_on_close.call()


# Whether the player may leave: always, unless a rating ceiling is set and the build
# exceeds it.
func can_close() -> bool:
	return not over_rating_limit()


func _refresh_close_button() -> void:
	if _close_button == null or not is_instance_valid(_close_button):
		return
	if _rating_limit >= 0.0 and over_rating_limit():
		_close_button.text = "Over limit — reduce to %d performance" % roundi(_rating_limit)
		_close_button.modulate = UITheme._role_color("red")
	else:
		_close_button.text = _close_button_text
		_close_button.modulate = Color(1, 1, 1, 1)


# Re-grab the tile tagged with `focus_key` after a rebuild, so the keyboard/gamepad cursor
# stays put across the press that triggered it. No-op if that tile no longer exists.
func _restore_focus(focus_key: String) -> void:
	for node in find_children("*", "Control", true, false):
		var c := node as Control
		if c != null and c.has_meta("upgrade_focus_key") \
				and String(c.get_meta("upgrade_focus_key")) == focus_key \
				and UITheme.is_focusable(c):
			c.grab_focus()
			return
