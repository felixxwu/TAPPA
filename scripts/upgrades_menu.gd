class_name UpgradesMenu
extends VBoxContainer
# Reusable per-car UPGRADES menu — an engine-detune slider (its label carries the
# live p/w readout), one earn-gated option selector per slot (Stock + the slot's
# catalogue parts; drivetrain is the RWD/AWD/FWD picker), and an engine-swap row
# (only when the host wires on_swap). Owns its Save persistence; reports edits via
# on_change so the host can re-field the car / refresh its own UI. Used by the HQ
# lift (hq.gd) and the car-park detune popup. Mirrors TuningPanel. See
# features/upgrade-catalogue.md. (Mystery Box moved OUT of this menu onto the
# garage row's own top-level button — see hq.gd/hq_overlays.gd — since it isn't
# a per-car upgrade, it's a garage-wide action.)

# "No power-to-weight cap applies". A local mirror of DrivingContext.NO_LIMIT's
# value — this component is per-car and knows nothing about sessions, it just
# takes a limit — so callers computing "no limit" have a self-documenting way to
# say so instead of passing a bare -1.0.
const NO_LIMIT := -1.0

var _owned: Dictionary = {}
var _on_change: Callable = Callable()
var _on_swap: Callable = Callable()   # valid → show swap row; invalid → omit it
var _pw_limit: float = NO_LIMIT   # power-to-weight cap (hp/tonne); NO_LIMIT = free
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
		pw_limit := NO_LIMIT) -> void:
	_owned = owned_car
	_on_change = on_change
	_on_swap = on_swap
	_pw_limit = pw_limit
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_theme_constant_override("separation", 8)
	rebuild()


# First focusable option, for the host to seat the keyboard/gamepad cursor.
func first_control() -> Control:
	return UITheme.first_focusable(self)


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
		# A hidden slot gets no row: an unwanted nitrous bottle is just a button you don't
		# press, and since nitrous is excluded from effective_meta removing it couldn't
		# change the car's eligibility either — so there is nothing to decide here. See
		# features/nitrous.md.
		if UpgradeLibrary.is_hidden_slot(slot):
			continue
		var row := _make_slot_row(slot, id, installed)
		if row != null:
			add_child(row)
	# Engine swap is lift-only: the popup leaves on_swap invalid and drops the row. It is
	# also absent entirely while the CAPABILITY is still star-locked — same reasoning as a
	# locked part option: a permanently-disabled row just invites a question the garage
	# can't answer. It appears the moment the gating special is won.
	if _on_swap.is_valid() and RallyLibrary.engine_swaps_unlocked(Save.profile):
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
# eligibility is enforced at Start, not by capping — and its label shows the car's
# live p/w at that setting (e.g. "227 HP/T"), flagging the ceiling / OVER LIMIT
# when a pw_limit is set (start line / car-park popup).
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
	_detune_value.text = _detune_label_text()
	# NOT locked by challenge_run — same as a career rally, the ceiling is enforced
	# by the pw_limit-bound close button (bind_close_button), not by freezing the
	# slider. A hard editable=false lock here used to double-enforce it and made the
	# slider look broken with no explanation; the shared pw_limit path (already reused
	# for a challenge via world.gd._build_start_line's synthetic restriction dict) is
	# the one mechanism, exactly like career.
	return handles["panel"]


# The detune slider's value label: the car's LIVE p/w at the current setting —
# the menu's only p/w readout (the standalone stats subtitle was removed). Kept
# to just "<value> HP/T" (no percent/dash prefix) so it fits the narrow label
# column without wrapping or clipping. The max-p/w cap / OVER-LIMIT flag lives
# on the close button now (bind_close_button), not here.
func _detune_label_text() -> String:
	var entry := CarLibrary.by_id(String(_owned.get("model_id", "")))
	var pw := CarLibrary.power_to_weight(UpgradeLibrary.effective_meta(_owned, entry)) * _KW_KG_TO_HP_TONNE
	return "%.0f HP/T" % pw


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
	_detune_value.text = _detune_label_text()
	_refresh_close_button()  # dragging power under/over the cap toggles the gate
	if _on_change.is_valid():
		_on_change.call()


# Whether the current build exceeds the advisory pw_limit (false when no limit set).
func over_pw_limit() -> bool:
	if _pw_limit < 0.0:
		return false
	var entry := CarLibrary.by_id(String(_owned.get("model_id", "")))
	var meta := UpgradeLibrary.effective_meta(_owned, entry)
	# Compare the ROUNDED hp/tonne the player sees in _detune_label_text, not the raw float —
	# otherwise a build displaying exactly the limit (e.g. 100 hp/t off a raw 100.4) reads as
	# "over" even though nothing on screen shows it exceeding the cap.
	return CarLibrary.power_to_weight_hp_tonne(meta) > roundi(_pw_limit)


# Returns null when the slot has nothing worth showing — every real option is still
# star-locked, so a row would be just a label and a "Stock" button the player can't act on.
# "Not even the label" is the point: a visible-but-empty drivetrain row is exactly the
# "when do I get this?" prompt hiding locked options is meant to remove.
func _make_slot_row(slot: String, instance_id: int, installed: Array) -> Control:
	if _slot_parts(slot, installed)["parts"].is_empty():
		return null
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
	# A single HFlowContainer (label + every button as flowed siblings) rather than an
	# HBoxContainer wrapping a nested HFlowContainer: nesting a wrapping container inside a
	# fixed-line one made each slot ROW's own reported height unreliable (a wrap changes the
	# inner container's height mid-layout), which was throwing off the VBoxContainer that
	# stacks the slot rows above one another — rows lost their vertical stacking. A single
	# flow container sizes itself in one pass, so its box-row parent stacks it correctly
	# (confirmed empirically: rows stay stacked even when a row wraps to 2 lines).
	var row := HFlowContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var unlocked := UpgradeLibrary.drivetrain_swap_unlocked(_owned)
	var stock := int(CarLibrary.by_id(String(_owned.get("model_id", ""))).get("drive_mode", CarLibrary.RWD))
	var override := int(_owned.get("drivetrain_override", -1))
	var current := (override if override >= 0 else stock) if unlocked else stock
	var label := Label.new()
	label.text = "Drivetrain:"
	label.add_theme_font_size_override("font_size", 15)
	# EXPAND_FILL on the label (not the buttons): FlowContainer honours per-child expand
	# WITHIN a line (confirmed empirically), so the label eats the line's leftover width,
	# pushing the option buttons after it flush to the row's right edge — label left,
	# buttons right, gap between, matching the house look.
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
# present (the turbo slot's short Small / Big / Supercharger), else its full `name`. The row
# is an HFlowContainer, so a slot with more options than fit simply wraps to the next line.
func _make_option_selector(slot: String, instance_id: int, installed: Array) -> Control:
	# A single HFlowContainer (label + every option button as flowed siblings), not an
	# HBoxContainer wrapping a nested HFlowContainer — see _make_drivetrain_selector for
	# why the nested version broke the slot rows' vertical stacking.
	var row := HFlowContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var label := Label.new()
	# No trailing colon: this page's OWN detune row has none, and neither does any row on
	# the Tuning page beside it, so a colon here was the odd one out rather than a
	# convention.
	label.text = slot.capitalize()
	label.add_theme_font_size_override("font_size", 15)
	# See _make_drivetrain_selector: expand-fill pushes the option buttons flush right.
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
	# One button per VISIBLE catalogue part (see _slot_parts — star-locked parts are absent
	# entirely), greyed until that kit is fitted to this car.
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
	_tighten_option_padding(b)
	b.set_meta("upgrade_focus_key", focus_key)
	b.pressed.connect(on_press)
	return b


# A slot-option row can hold 4+ of these side by side (Stock + several parts), and the
# shared house Button style's 14px left/right content margin (theme/ui_theme.tres) — sized
# for standalone action buttons like "< Map" — eats width fast across that many buttons.
# Measured against the real logical canvas (DisplayStretch: DESIGN_HEIGHT * aspect /
# horizontal_stretch, NOT the raw window size) at the narrowest supported aspect (4:3),
# the WEIGHT row with its lightweight option selected/bracketed needs ~411 logical px but
# the panel can offer at most ~400 there — see the width_frac comment in game_config.gd.
# Duplicating each state's stylebox with a smaller content margin (scoped to just these
# option buttons, not the shared theme, so other buttons in the game are unaffected)
# claws back ~6px of padding per side per button — 4 buttons wide is enough to fit.
const _OPTION_BUTTON_PAD := 6.0

func _tighten_option_padding(b: Button) -> void:
	for state in ["normal", "hover", "pressed", "focus", "disabled"]:
		var src := b.get_theme_stylebox(state, "Button")
		if src == null:
			continue
		var box := src.duplicate() as StyleBoxFlat
		if box == null:
			continue
		box.content_margin_left = _OPTION_BUTTON_PAD
		box.content_margin_right = _OPTION_BUTTON_PAD
		b.add_theme_stylebox_override(state, box)


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
		var pid := String(def.get("id", ""))
		# STAR-GATED parts are omitted ENTIRELY, not greyed: a row of locked options invites
		# "when do I get the big turbo?", which is a question the garage can't answer. A new
		# player's turbo row therefore reads "Stock | Small" and nothing else, and grows as
		# specials are won. What DOES stay visible-but-disabled is a part that is unlocked
		# and merely not yet fitted to THIS car — that one the player can act on.
		#
		# A part already fitted is kept regardless of its gate, so a car can never display
		# less than it is actually running (see UpgradeLibrary.apply — the gate governs
		# earning a part, never keeping one).
		if not UpgradeLibrary.rally_gate_met(pid, Save.profile) and not installed.has(pid):
			continue
		parts.append(def)
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
	# An HBoxContainer, NOT a flow container: this is the widest slot row (four ballast /
	# stock / lightweight options), so it is the one that wraps first — and a weight ladder
	# reads as a ladder only while it is one continuous line from heaviest to lightest.
	# Broken across two lines the ordering stops being legible. So the row keeps its options
	# on one line and asks for the width it needs; MenuPage's body box hugs its contents, so
	# the box widens to fit rather than the row folding.
	#
	# The nesting warning in _make_drivetrain_selector still stands — what broke the slot
	# rows' vertical stacking there was a WRAPPING container nested inside a fixed-line one.
	# A plain HBox has no wrap to change its height mid-layout, so it stacks fine.
	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var label := Label.new()
	# No trailing colon — matching every other row on this page and the Tuning page (this one
	# was missed when the rest were changed).
	label.text = "Weight"
	label.add_theme_font_size_override("font_size", 15)
	# See _make_drivetrain_selector: expand-fill pushes the option buttons flush right.
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


# The engine-swap row: current engine label + a Swap button that runs the host's on_swap
# action. Disabled when swapping is still STAR-LOCKED, when there's no other owned car to
# swap with, or when no token is held (its label spells out which).
#
# The capability gate is separate from the currency on purpose: tokens keep dropping and
# banking from the very start, they simply cannot be SPENT until the star-gated special is
# won (RallyLibrary.engine_swaps_unlocked). A visible stack of tokens you can't use yet is
# the pull toward that event — so the locked label names the tokens held rather than
# hiding them. See features/engine-swap.md and features/nitrous.md's sibling discussion.
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
	if not RallyLibrary.engine_swaps_unlocked(Save.profile):
		# Checked FIRST: while locked it is the only true reason, and reporting "no other
		# car" or "no tokens" instead would send the player after the wrong thing.
		button.text = "Swap Engine — locked"
		button.disabled = true
		button.tooltip_text = _swap_locked_hint(tokens)
	elif not has_target:
		button.text = "Swap Engine"
		button.disabled = true
		button.tooltip_text = "No other car to swap engines with"
	elif tokens <= 0:
		button.text = "Swap Engine — no tokens"
		button.disabled = true
		button.tooltip_text = "You have no engine swap tokens — win one from a rally reward"
	else:
		button.text = "Swap Engine (%s)" % UITheme.count_noun(tokens, "token")
		button.disabled = false
		button.tooltip_text = "Swap engines with another car (costs 1 token)"
	button.pressed.connect(_on_swap)
	row.add_child(button)
	return row


# Why the swap button is locked, naming the banked tokens so they read as a teaser rather
# than a junk reward the player has been collecting for nothing.
func _swap_locked_hint(tokens: int) -> String:
	var held := "%s banked — " % UITheme.count_noun(tokens, "token") if tokens > 0 else ""
	# "rallies", not "events": the gate counts completed RALLIES (an event is one stage inside
	# a rally) — same wording as the map pin's locked-special teaser.
	return "%sengine swapping unlocks when you win the special event that opens after %s" % [
		held, UITheme.count_noun(RallyLibrary.engine_swap_completion_requirement(),
			"rally", "rallies")]


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
		if c != null and c.has_meta("upgrade_focus_key") \
				and String(c.get_meta("upgrade_focus_key")) == focus_key \
				and UITheme.is_focusable(c):
			c.grab_focus()
			return
