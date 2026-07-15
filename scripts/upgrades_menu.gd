class_name UpgradesMenu
extends VBoxContainer
# Reusable per-car UPGRADES menu — one earn-gated option selector per slot
# (Stock + the slot's catalogue parts; drivetrain is the RWD/AWD/FWD picker),
# an engine-swap row (only when the host wires on_swap), and a live p/w + G
# stats line. Owns its Save persistence; reports edits via on_change so the host
# can re-field the car / refresh its own UI. Used by the HQ lift (hq.gd) and the
# car-park detune popup. Mirrors TuningPanel. See features/upgrade-catalogue.md.

var _owned: Dictionary = {}
var _on_change: Callable = Callable()
var _on_swap: Callable = Callable()   # valid → show swap row; invalid → omit it
var _stats_label: Label

const _KW_KG_TO_HP_TONNE := CarLibrary.KW_KG_TO_HP_TONNE


# Bind the owned car + host callbacks, then build the rows. on_change() runs after
# each spec edit so the host re-fields the car. on_swap() (optional) is the engine-
# swap action; when unset the swap row is omitted (the popup drops it).
func setup(owned_car: Dictionary, on_change := Callable(), on_swap := Callable()) -> void:
	_owned = owned_car
	_on_change = on_change
	_on_swap = on_swap
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
# it would kill WASD/gamepad nav), rebuild the stats line + slot rows + optional swap
# row, re-enforce the house theme, and re-run MenuNav.attach on the fresh rows.
func rebuild() -> void:
	var focus_key := ""
	var focused := get_viewport().gui_get_focus_owner() if is_inside_tree() else null
	if focused != null and focused.has_meta("upgrade_focus_key") and is_ancestor_of(focused):
		focus_key = String(focused.get_meta("upgrade_focus_key"))

	for c in get_children():
		if c is MenuNav:
			continue
		c.queue_free()

	_stats_label = Label.new()
	_stats_label.add_theme_font_size_override("font_size", 15)
	add_child(_stats_label)
	_refresh_stats()

	var id := int(_owned.get("instance_id", -1))
	var installed: Array = _owned.get("installed_upgrades", [])
	for slot in UpgradeLibrary.SLOTS:
		add_child(_make_slot_row(slot, id, installed))
	# Engine swap is lift-only: the popup leaves on_swap invalid and drops the row.
	if _on_swap.is_valid():
		add_child(_make_engine_swap_row(id))

	UITheme.enforce(self)
	MenuNav.attach(self)
	if focus_key != "":
		_restore_focus.bind(focus_key).call_deferred()


# Live power-to-weight (hp/tonne) + max lateral G for the current spec — recomputed
# from effective_meta each rebuild, so toggling a part updates it immediately. Uses
# the same helpers hq.gd._car_stats_text formats, so it agrees with the car banner.
func _refresh_stats() -> void:
	var entry := CarLibrary.by_id(String(_owned.get("model_id", "")))
	var meta := UpgradeLibrary.effective_meta(_owned, entry)
	_stats_label.text = "%.0f hp/tonne   |   %.2f G" % [
		CarLibrary.power_to_weight(meta) * _KW_KG_TO_HP_TONNE,
		CarLibrary.max_lateral_g(meta, Config.data),
	]


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
		row.add_child(_option_button(_drive_text(mode), mode == current, unlocked or mode == stock,
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
	var parts: Array = []
	var current_id := ""
	for def in UpgradeLibrary.all():
		if String(def.get("slot", "")) != slot or bool(def.get("consumable", false)):
			continue
		parts.append(def)
		var pid := String(def.get("id", ""))
		if installed.has(pid) and UpgradeLibrary.is_enabled(_owned, pid):
			current_id = pid
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


# One selector button: bracketed when active, greyed when its option isn't available yet,
# FOCUS_ALL so keyboard/gamepad can reach it, and tagged with a stable focus key so the
# cursor lands back on it after the rebuild a press triggers.
func _option_button(text: String, active: bool, available: bool, focus_key: String,
		on_press: Callable) -> Button:
	var b := Button.new()
	b.text = "[%s]" % text if active else text
	b.focus_mode = Control.FOCUS_ALL
	b.disabled = not available
	b.set_meta("upgrade_focus_key", focus_key)
	b.pressed.connect(on_press)
	return b


func _set_slot_option(instance_id: int, slot: String, item_id: String) -> void:
	# None (item_id == "") disables every part in the slot; otherwise enable the chosen
	# part (same-slot exclusivity switches any sibling off). Goes through the shared
	# enable/disable path so the one-enabled-per-slot rule and the reward flow are
	# preserved. The host's on_change respawns the display prop + refreshes stats.
	if item_id == "":
		for def in UpgradeLibrary.all():
			if String(def.get("slot", "")) == slot:
				Save.set_upgrade_enabled(instance_id, String(def.get("id", "")), false)
	else:
		Save.set_upgrade_enabled(instance_id, item_id, true)
	_owned = Save.get_car(instance_id)
	rebuild()  # updates stats + rebuilds rows + re-seats MenuNav focus
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


func _drive_text(drive_mode: int) -> String:
	match drive_mode:
		CarLibrary.RWD: return "RWD"
		CarLibrary.AWD: return "AWD"
		CarLibrary.FWD: return "FWD"
		_: return "?"


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
