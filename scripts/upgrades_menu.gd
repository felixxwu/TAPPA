class_name UpgradesMenu
extends VBoxContainer
# Reusable per-car UPGRADES menu — an engine-detune slider (its label carries the
# live p/w readout), one earn-gated option selector per slot (Stock + the slot's
# catalogue parts; drivetrain is the RWD/AWD/FWD picker), and an engine-swap row
# (only when the host wires on_swap). Owns its Save persistence; reports edits via
# on_change so the host can re-field the car / refresh its own UI. Used by the HQ
# lift (hq.gd) and the car-park detune popup. Mirrors TuningPanel. See
# features/upgrade-catalogue.md.

var _owned: Dictionary = {}
var _on_change: Callable = Callable()
var _on_swap: Callable = Callable()   # valid → show swap row; invalid → omit it
var _pw_limit: float = -1.0   # power-to-weight cap (hp/tonne); -1 = no limit (free)
var _detune_slider: HSlider
var _detune_value: Label
# The host's overlay close button, gated by the p/w limit (bind_close_button). When a
# limit is set and the build exceeds it, this button is painted red and blocks closing
# (proceed) until the player drags power back under the cap.
var _close_button: Button
var _close_button_text := ""
var _on_close: Callable = Callable()

const _KW_KG_TO_HP_TONNE := CarLibrary.KW_KG_TO_HP_TONNE


# Bind the owned car + host callbacks, then build the rows. on_change() runs after
# each spec edit so the host re-fields the car. on_swap() (optional) is the engine-
# swap action; when unset the swap row is omitted (the popup drops it). pw_limit
# (optional) is a power-to-weight cap (hp/tonne); when >= 0 the bound close button
# (bind_close_button) blocks proceeding while the live build exceeds it.
func setup(owned_car: Dictionary, on_change := Callable(), on_swap := Callable(),
		pw_limit := -1.0) -> void:
	_owned = owned_car
	_on_change = on_change
	_on_swap = on_swap
	_pw_limit = pw_limit
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_theme_constant_override("separation", 8)
	rebuild()


# First focusable option, for the host to seat the keyboard/gamepad cursor.
func first_control() -> Control:
	for node in find_children("*", "Control", true, false):
		var c := node as Control
		if c != null and c.focus_mode != Control.FOCUS_NONE \
				and c.is_visible_in_tree() \
				and not (c is BaseButton and (c as BaseButton).disabled):
			return c
	return null


# Rebuild the rows for the current _owned (focus-preserving): preserve the focused
# control's upgrade_focus_key, free the row children (NOT the MenuNav child — freeing
# it would kill WASD/gamepad nav), rebuild the slot rows + optional swap row + the
# detune row (last), re-enforce the house theme, and re-run MenuNav.attach on them.
func rebuild() -> void:
	var focus_key := ""
	var focused := get_viewport().gui_get_focus_owner() if is_inside_tree() else null
	if focused != null and focused.has_meta("upgrade_focus_key") and is_ancestor_of(focused):
		focus_key = String(focused.get_meta("upgrade_focus_key"))

	for c in get_children():
		if c is MenuNav:
			continue
		c.queue_free()

	var id := int(_owned.get("instance_id", -1))
	var installed: Array = _owned.get("installed_upgrades", [])
	for slot in UpgradeLibrary.SLOTS:
		add_child(_make_slot_row(slot, id, installed))
	# Engine swap is lift-only: the popup leaves on_swap invalid and drops the row.
	if _on_swap.is_valid():
		add_child(_make_engine_swap_row(id))
	# Engine detune sits with the upgrades because it trades power for eligibility —
	# it's a p/w knob, not a handling axis (features/tuning.md, engine-swap.md). It goes
	# LAST, below the part slots, as the final power adjustment before you commit.
	add_child(_make_detune_row(id))

	UITheme.enforce(self)
	MenuNav.attach(self)
	_refresh_close_button()  # a part/drivetrain toggle can cross the p/w cap
	if focus_key != "":
		_restore_focus.bind(focus_key).call_deferred()


# The engine-detune slider row: a direct 0–100% torque scale (default 100% = full
# power). Lives here rather than in TuningPanel because it moves power-to-weight,
# which is what this menu is about. The slider spans the full range — rally
# eligibility is enforced at Start, not by capping — and its label pairs the percent
# with the car's live p/w at that setting (e.g. "80% - 200 hp/tonne"), flagging the
# ceiling / OVER LIMIT when a pw_limit is set (start line / car-park popup).
func _make_detune_row(instance_id: int) -> Control:
	# Same house slider-row as the tuning panel's handling axes (shared SliderRow
	# builder), so the detune row matches them exactly — including the focus highlight.
	# pad:0 so the row lines up flush with the (non-panel-wrapped) slot rows above it —
	# the slot selectors have no content inset, so the detune panel must not either.
	var handles := SliderRow.build({
		"name": "Engine detune", "lo": "0%", "hi": "100%",
		"min": 0.0, "max": 100.0, "step": 5.0, "pad": 0,
	})
	_detune_slider = handles["slider"]
	_detune_value = handles["value_label"]
	_detune_slider.set_meta("upgrade_focus_key", "engine_detune")  # keep cursor across rebuild
	var frac := clampf(float(_owned.get("tuning", {}).get("engine_detune", 1.0)), 0.0, 1.0)
	_detune_slider.set_value_no_signal(frac * 100.0)
	_detune_slider.value_changed.connect(_on_detune_changed.bind(instance_id))
	_detune_value.text = _detune_label_text(int(round(frac * 100.0)))
	return handles["panel"]


# The detune slider's value label: the percent plus the car's LIVE p/w at that
# setting — the menu's only p/w readout (the standalone stats subtitle was removed).
# The max-p/w cap / OVER-LIMIT flag lives on the close button now (bind_close_button),
# not here.
func _detune_label_text(pct: int) -> String:
	var entry := CarLibrary.by_id(String(_owned.get("model_id", "")))
	var pw := CarLibrary.power_to_weight(UpgradeLibrary.effective_meta(_owned, entry)) * _KW_KG_TO_HP_TONNE
	return "%d%% - %.0f hp/tonne" % [pct, pw]


# Bind the host overlay's close button so it reflects the p/w gate. `on_close` is the
# host's close/back action. With no limit set the button keeps its text and closes
# freely; with a limit set it reads "Done" and, while the build is OVER the cap, is
# painted red and refuses to close (proceed) — the player drags detune down until the
# ratio is satisfied. Call once after setup(); the menu re-paints it on every edit.
func bind_close_button(button: Button, on_close: Callable) -> void:
	_close_button = button
	_close_button_text = "Done" if _pw_limit >= 0.0 else button.text
	_on_close = on_close
	if not button.pressed.is_connected(request_close):
		button.pressed.connect(request_close)
	_refresh_close_button()


# The gated close action: closes via _on_close only when the p/w gate is satisfied.
# Wired to the close button's press AND handed to the host's MenuNav as `on_back`, so
# both the button and Esc/controller-back are blocked while over the limit.
func request_close() -> void:
	if can_close() and _on_close.is_valid():
		_on_close.call()


# Whether the player may leave the menu: always, unless a p/w limit is set and the
# current build exceeds it.
func can_close() -> bool:
	return not over_pw_limit()


# Paint the close button for the current build: red + "reduce" prompt while over a set
# limit, else the normal close text. No-op until a button is bound.
func _refresh_close_button() -> void:
	if _close_button == null:
		return
	if _pw_limit >= 0.0 and over_pw_limit():
		_close_button.text = "Over limit — reduce to %.0f hp/tonne" % _pw_limit
		_close_button.modulate = UITheme._role_color("red")
	else:
		_close_button.text = _close_button_text
		_close_button.modulate = Color(1, 1, 1, 1)


# An edit to the detune slider: persist the fraction, sync the local snapshot, then
# refresh the label in place (NO full rebuild — a rebuild would drop the slider's drag
# grab). Notifies the host so it re-fields the live car's power.
func _on_detune_changed(value: float, instance_id: int) -> void:
	if _owned.is_empty():
		return
	var frac := clampf(value / 100.0, 0.0, 1.0)
	Save.set_engine_detune(instance_id, frac)
	var tuning: Dictionary = _owned.get("tuning", {})
	tuning["engine_detune"] = frac
	_owned["tuning"] = tuning
	_detune_value.text = _detune_label_text(int(round(value)))
	_refresh_close_button()  # dragging power under/over the cap toggles the gate
	if _on_change.is_valid():
		_on_change.call()


# Whether the current build exceeds the advisory pw_limit (false when no limit set).
func over_pw_limit() -> bool:
	if _pw_limit < 0.0:
		return false
	var entry := CarLibrary.by_id(String(_owned.get("model_id", "")))
	var meta := UpgradeLibrary.effective_meta(_owned, entry)
	return CarLibrary.power_to_weight(meta) * _KW_KG_TO_HP_TONNE > _pw_limit


func _make_slot_row(slot: String, instance_id: int, installed: Array) -> Control:
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 2)

	# The drivetrain slot has NO enable/disable toggle — owning the swap kit is the
	# unlock, and the selector's stock choice IS the "off" state (disabling would just
	# re-select the original drive mode). We always show the FWD/RWD/AWD selector so the
	# row reads like every other slot: when the kit isn't owned yet, only the car's stock
	# drive mode is selected + enabled and the other two are greyed (earn-gated), exactly
	# like a part option greys until its kit is fitted.
	if slot == "drivetrain":
		box.add_child(_make_drivetrain_selector(instance_id))
		return box

	# The weight slot is a bespoke p/w lever: Stock + ballast (free) + lightweight
	# (earned), ordered heavy→light with each option labelled by its rounded kg delta.
	if slot == "weight":
		box.add_child(_make_weight_selector(instance_id, installed))
		return box

	# Every other slot is an EARN-GATED option selector on the right — "SLOT:" on the
	# left, then None + one button per catalogue part in this slot. None is always
	# available and plays the "off" role; each part option is greyed until its kit is
	# fitted to this car. Built on the same enable/disable machinery (one enabled part
	# per slot), so the reward flow is unchanged — purely the menu presentation.
	box.add_child(_make_option_selector(slot, instance_id, installed))
	return box


# The FWD/RWD/AWD picker shown on the drivetrain slot row. When the swap kit is owned
# every mode is selectable and the current mode is the stored override (or the car's stock
# drive_mode when unset, -1). When the kit ISN'T owned yet the row still shows all three
# modes, but only the car's stock mode is selected + enabled — the other two are greyed,
# exactly like a part option greys until its kit is fitted. The whole selector is
# earn-gated by owning the kit, not per option.
func _make_drivetrain_selector(instance_id: int) -> Control:
	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var unlocked := UpgradeLibrary.drivetrain_swap_unlocked(_owned)
	var stock := int(CarLibrary.by_id(String(_owned.get("model_id", ""))).get("drive_mode", CarLibrary.RWD))
	var override := int(_owned.get("drivetrain_override", -1))
	var current := (override if override >= 0 else stock) if unlocked else stock
	var label := Label.new()
	label.text = "Drivetrain:"
	label.add_theme_font_size_override("font_size", 15)
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(label)
	# Available = every mode once unlocked, else only the stock mode. Reuses the shared
	# _option_button builder so bracket-active / FOCUS_ALL / focus-key live in one place.
	for mode in [CarLibrary.RWD, CarLibrary.AWD, CarLibrary.FWD]:
		row.add_child(_option_button(CarLibrary.drive_text(mode), mode == current, unlocked or mode == stock,
			"drivetrain:" + str(mode), _set_drivetrain.bind(instance_id, mode)))
	return row


func _set_drivetrain(instance_id: int, mode: int) -> void:
	Save.set_drivetrain_override(instance_id, mode)
	_owned = Save.get_car(instance_id)
	rebuild()
	if _on_change.is_valid():
		_on_change.call()


# The earn-gated option selector shown on every part slot except drivetrain: "SLOT:" then
# None + one button per catalogue part in this slot (in catalogue order). None is always
# available (the "off" state); each part is greyed until that kit is fitted to this car,
# and the active option is bracketed. The button label is the part's `menu_label` if
# present (Turbo's short Small / Big), else its full `name`.
func _make_option_selector(slot: String, instance_id: int, installed: Array) -> Control:
	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var label := Label.new()
	label.text = "%s:" % slot.capitalize()
	label.add_theme_font_size_override("font_size", 15)
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(label)
	# The catalogue parts for this slot, in catalogue order, and which one (if any) is
	# currently the enabled pick.
	var scan := _slot_parts(slot, installed)
	var parts: Array = scan["parts"]
	var current_id: String = scan["current_id"]
	# None is always available and plays the "off" role.
	row.add_child(_option_button("Stock", current_id == "", true,
		"opt:%s:none" % slot, _set_slot_option.bind(instance_id, slot, "")))
	# One button per catalogue part, greyed until that kit is fitted to this car.
	for def in parts:
		var pid := String(def.get("id", ""))
		var text := String(def.get("menu_label", def.get("name", pid)))
		row.add_child(_option_button(text, current_id == pid, installed.has(pid),
			"opt:%s:%s" % [slot, pid], _set_slot_option.bind(instance_id, slot, pid)))
	return row


# One selector button: bracketed AND painted the house accent (GREEN) when active so the
# selected option stands out clearly, greyed when its option isn't available yet, FOCUS_ALL
# so keyboard/gamepad can reach it, and tagged with a stable focus key so the cursor lands
# back on it after the rebuild a press triggers.
func _option_button(text: String, active: bool, available: bool, focus_key: String,
		on_press: Callable) -> Button:
	var b := Button.new()
	b.text = "[%s]" % text if active else text
	b.focus_mode = Control.FOCUS_ALL
	b.disabled = not available
	if active:
		# Accent the active pick in the house "selected" colour (matches focus underline).
		b.add_theme_color_override("font_color", UITheme.GREEN)
		b.add_theme_color_override("font_hover_color", UITheme.GREEN)
		b.add_theme_color_override("font_focus_color", UITheme.GREEN)
	b.set_meta("upgrade_focus_key", focus_key)
	b.pressed.connect(on_press)
	return b


func _set_slot_option(instance_id: int, slot: String, item_id: String) -> void:
	# None (item_id == "") disables every part in the slot; otherwise enable the chosen
	# part (same-slot exclusivity switches any sibling off). Goes through the shared
	# enable/disable path so the one-enabled-per-slot rule and the reward flow are
	# preserved. The host's on_change respawns the display prop + refreshes stats.
	if item_id == "":
		_clear_slot(instance_id, slot)
	else:
		Save.set_upgrade_enabled(instance_id, item_id, true)
	_owned = Save.get_car(instance_id)
	rebuild()  # updates stats + rebuilds rows + re-seats MenuNav focus
	if _on_change.is_valid():
		_on_change.call()


# The catalogue parts in `slot` (non-consumable), in catalogue order, plus which one (if
# any) is the currently enabled pick on `_owned`. Shared by the option + weight rows.
func _slot_parts(slot: String, installed: Array) -> Dictionary:
	var parts: Array = []
	var current_id := ""
	for def in UpgradeLibrary.all():
		if String(def.get("slot", "")) != slot or bool(def.get("consumable", false)):
			continue
		parts.append(def)
		var pid := String(def.get("id", ""))
		if installed.has(pid) and UpgradeLibrary.is_enabled(_owned, pid):
			current_id = pid
	return {"parts": parts, "current_id": current_id}


# Disable every applied part in `slot` on the car — the "Stock"/None state.
func _clear_slot(instance_id: int, slot: String) -> void:
	for def in UpgradeLibrary.all():
		if String(def.get("slot", "")) == slot:
			Save.set_upgrade_enabled(instance_id, String(def.get("id", "")), false)


# The WEIGHT slot selector: "Weight:" then the weight parts ordered heavy→light with a
# "Stock" option sitting between the ballast (mass_mult > 1) and the lightweight
# (mass_mult < 1). Each option is labelled by its rounded kg delta off the car's base
# mass (e.g. "+500kg" / "-200kg"); Stock is the no-change default. Ballast options are
# `free` (always selectable); the lightweight option greys until won as a reward.
func _make_weight_selector(instance_id: int, installed: Array) -> Control:
	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var label := Label.new()
	label.text = "Weight:"
	label.add_theme_font_size_override("font_size", 15)
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(label)

	# Weight-slot parts, heaviest first; which one (if any) is the enabled pick.
	var scan := _slot_parts("weight", installed)
	var parts: Array = scan["parts"]
	var current_id: String = scan["current_id"]
	parts.sort_custom(func(a, b): return _mass_mult(a) > _mass_mult(b))

	var base := _base_mass_no_weight()
	var stock_added := false
	for def in parts:
		# Insert Stock (no change) once we cross from ballast (>1) to lightweight (<1).
		if not stock_added and _mass_mult(def) < 1.0:
			row.add_child(_option_button("Stock", current_id == "", true,
				"opt:weight:none", _set_weight_option.bind(instance_id, "")))
			stock_added = true
		var pid := String(def.get("id", ""))
		var available := UpgradeLibrary.is_free(pid) or installed.has(pid)
		row.add_child(_option_button(_weight_delta_label(_mass_mult(def), base),
			current_id == pid, available, "opt:weight:%s" % pid,
			_set_weight_option.bind(instance_id, pid)))
	if not stock_added:  # no lightweight option authored → Stock goes at the end
		row.add_child(_option_button("Stock", current_id == "", true,
			"opt:weight:none", _set_weight_option.bind(instance_id, "")))
	return row


func _mass_mult(def: Dictionary) -> float:
	return float((def.get("effect", {}) as Dictionary).get("mass_mult", 1.0))


# The car's base mass with NO weight option applied: the current effective mass divided
# by whichever weight mult is currently active (1.0 if none), so the per-option deltas
# read off the same neutral base regardless of what's selected.
func _base_mass_no_weight() -> float:
	var entry := CarLibrary.by_id(String(_owned.get("model_id", "")))
	var mass := float(UpgradeLibrary.effective_meta(_owned, entry).get("mass", 0.0))
	var active := 1.0
	for def in UpgradeLibrary.all():
		if String(def.get("slot", "")) != "weight":
			continue
		var pid := String(def.get("id", ""))
		if (_owned.get("installed_upgrades", []) as Array).has(pid) and UpgradeLibrary.is_enabled(_owned, pid):
			active = _mass_mult(def)
	return mass / active if active != 0.0 else mass


# A weight option's kg delta off the base mass, rounded to the nearest 100 and signed
# (e.g. "+500kg", "-200kg").
func _weight_delta_label(mult: float, base_mass: float) -> String:
	var delta := roundi((mult - 1.0) * base_mass / 100.0) * 100
	return "%+dkg" % delta


# Select a weight option. "" = Stock (disable every weight part). A free ballast the car
# doesn't own yet is installed on the spot (then enabled exclusively); an already-owned
# part (or the earned lightweight) is just enabled. One weight part enabled at a time.
func _set_weight_option(instance_id: int, item_id: String) -> void:
	if item_id == "":
		_clear_slot(instance_id, "weight")
	elif not (Save.get_car(instance_id).get("installed_upgrades", []) as Array).has(item_id):
		Save.install_upgrade(instance_id, item_id, true)  # free ballast: fit + enable
	else:
		Save.set_upgrade_enabled(instance_id, item_id, true)
	_owned = Save.get_car(instance_id)
	rebuild()
	if _on_change.is_valid():
		_on_change.call()


# The engine-swap row: current engine label + a Swap button that runs the host's
# on_swap action. Disabled when there's no other owned car to swap with OR when no
# token is held (its label spells out which). See features/engine-swap.md.
func _make_engine_swap_row(instance_id: int) -> HBoxContainer:
	var owned := Save.get_car(instance_id)
	var entry := CarLibrary.by_id(String(owned.get("model_id", "")))
	var current := EngineSwap.current_engine_id(owned, String(entry.get("engine", "")))
	var row := HBoxContainer.new()
	var label := Label.new()
	label.text = "Engine: %s" % EngineLibrary.by_id(current).get("name", current)
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(label)
	var button := Button.new()
	button.focus_mode = Control.FOCUS_ALL
	button.set_meta("upgrade_focus_key", "swap")  # keep the cursor here across a rebuild
	# Each branch sets the button's text/disabled/tooltip for its state.
	var tokens := Save.engine_swap_tokens_owned()
	var has_target := not _swap_targets(instance_id).is_empty()
	if not has_target:
		button.text = "Swap Engine"
		button.disabled = true
		button.tooltip_text = "No other car to swap engines with"
	elif tokens <= 0:
		button.text = "Swap Engine — no tokens"
		button.disabled = true
		button.tooltip_text = "You have no engine swap tokens — win one from a rally reward"
	else:
		button.text = "Swap Engine (%d token%s)" % [tokens, "" if tokens == 1 else "s"]
		button.disabled = false
		button.tooltip_text = "Swap engines with another car (costs 1 token)"
	button.pressed.connect(_on_swap)
	row.add_child(button)
	return row


# The owned cars this car can swap engines with: every OTHER owned car. No car is
# excluded on health — a damaged partner is repaired as part of the swap. Shared by
# the swap-row gating so it never disagrees with the car-park swap lineup.
func _swap_targets(current_id: int) -> Array:
	var targets: Array = []
	if Save.get_car(current_id).is_empty():
		return targets
	for car in Save.profile.get("cars", []):
		if int(car.get("instance_id", -1)) == current_id:
			continue
		targets.append(car)
	return targets


# Re-grab the control tagged with `focus_key` after a rebuild, so the keyboard/gamepad
# cursor stays put across a toggle press. No-op if that control no longer exists.
func _restore_focus(focus_key: String) -> void:
	for node in find_children("*", "Control", true, false):
		var c := node as Control
		if c != null and not UITheme.in_dying_subtree(c) \
				and c.has_meta("upgrade_focus_key") \
				and String(c.get_meta("upgrade_focus_key")) == focus_key \
				and c.focus_mode != Control.FOCUS_NONE and c.is_visible_in_tree() \
				and not (c is BaseButton and (c as BaseButton).disabled):
			c.grab_focus()
			return
