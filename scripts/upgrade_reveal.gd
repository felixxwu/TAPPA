extends Control
class_name UpgradeReveal
# A self-contained reward card: a slot-machine spin that lands on a won upgrade,
# then an Apply/Keep choice (enable now vs leave fitted-disabled for the garage).
# A won repair kit offers a Repair-now/Save-it choice when the driven car is below
# full health; otherwise consumables and the drivetrain kit skip the choice. Emits `finished`
# once the reveal + choice resolves. Used by the standings interstitial; visually
# matches the podium reward card (features/menus.md, features/reward-system.md).

signal finished()

var _car_instance_id := -1
var _choice_item_id := ""
var _choice_pending := false
# Which choice the buttons resolve: "upgrade" (Apply/Keep a slotted part) or
# "repair" (use the just-won repair kit on the driven car now vs save it).
var _choice_mode := "upgrade"
var _reveal_done := false
var _headless := false
var _slot_tween: Tween

var _slot_label: Label
var _slot_caption: Label
var _choice_box: HBoxContainer
var _apply_button: Button
var _keep_button: Button


func _ready() -> void:
	_headless = Platform.is_headless()
	_build_ui()


func _build_ui() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	# Anchor the reward card to the bottom of the screen so it doesn't block the
	# view of the car in the replay behind it. A full-rect VBox aligned to the end
	# drops the (shrink-centred) panel to the bottom, with a margin off the edge.
	var bottom := VBoxContainer.new()
	bottom.set_anchors_preset(Control.PRESET_FULL_RECT)
	bottom.alignment = BoxContainer.ALIGNMENT_END
	bottom.add_theme_constant_override("separation", 0)
	add_child(bottom)
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_bottom", 40)
	bottom.add_child(margin)

	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	panel.add_theme_stylebox_override("panel", UITheme.reward_card_box())
	margin.add_child(panel)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 8)
	panel.add_child(col)

	_slot_label = Label.new()
	_slot_label.add_theme_font_size_override("font_size", 40)
	_slot_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_slot_label.custom_minimum_size = Vector2(_card_width(), 0)
	# Wrap at the card width so a long part name doesn't stretch the card off-screen.
	_slot_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	col.add_child(_slot_label)

	_slot_caption = Label.new()
	_slot_caption.add_theme_font_size_override("font_size", 16)
	_slot_caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_slot_caption.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	col.add_child(_slot_caption)

	# The apply/keep choice: the won part is already fitted (disabled) to the driven
	# car — Apply enables it now, Keep leaves it disabled to enable later in the
	# garage. Both buttons focusable so the choice works on keyboard/gamepad.
	_choice_box = HBoxContainer.new()
	_choice_box.alignment = BoxContainer.ALIGNMENT_CENTER
	_choice_box.add_theme_constant_override("separation", 12)
	_choice_box.visible = false
	col.add_child(_choice_box)
	_apply_button = Button.new()
	_apply_button.focus_mode = Control.FOCUS_ALL
	_apply_button.pressed.connect(_on_apply)
	_choice_box.add_child(_apply_button)
	_keep_button = Button.new()
	_keep_button.focus_mode = Control.FOCUS_ALL
	_keep_button.text = "Keep for later"
	_keep_button.pressed.connect(_on_keep)
	_choice_box.add_child(_keep_button)

	UITheme.enforce(self)


# The reveal card's content width: the 520px design width, shrunk on narrow
# viewports (`viewport_width`) so the card (plus panel padding/border) never
# overflows the screen. Shared with the podium's car-reveal card. Pure.
static func card_width(viewport_width: float) -> float:
	return minf(520.0, viewport_width * 0.8)


func _card_width() -> float:
	return card_width(get_viewport().get_visible_rect().size.x)


# Public entry: spin to the won item, then offer (or auto-resolve) the choice.
func reveal(item_id: String, car_instance_id: int) -> void:
	_car_instance_id = car_instance_id
	var target := String(UpgradeLibrary.by_id(item_id).get("name", item_id))
	_start_slot(Registry.names(UpgradeLibrary.UPGRADES), target, func() -> void: _offer_choice(item_id, target))


# Drive `label` (owned by `host`) through a slot-machine spin over `reel_names`,
# decelerating to a stop on `target`, then run `on_done`. Returns the running Tween,
# or null when it resolves instantly (headless / non-positive `spin_time` / empty
# reel) so tests step straight through. Shared with the podium's car-reveal. Pure
# apart from mutating `label` + driving the returned tween.
static func start_spin(host: Node, label: Label, reel_names: Array, target: String,
		spin_time: float, headless: bool, on_done: Callable) -> Tween:
	if headless or spin_time <= 0.0 or reel_names.is_empty():
		label.text = UITheme.caps(target)
		if on_done.is_valid():
			on_done.call()
		return null
	var reel := build_reel(reel_names, target)
	var tween := host.create_tween()
	tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tween.tween_method(
		func(p: float) -> void:
			var i := clampi(int(round(p)), 0, reel.size() - 1)
			label.text = UITheme.caps(String(reel[i])),
		0.0, float(reel.size() - 1), spin_time)
	tween.tween_callback(func() -> void:
		label.text = UITheme.caps(target)
		if on_done.is_valid():
			on_done.call())
	return tween


# A reel that cycles the candidate names a few times and ends on the target, so the
# tween that walks it slows to a stop on the won item. Pure.
static func build_reel(names: Array, target: String) -> Array:
	var reel: Array = []
	var count := maxi(14, names.size() * 3)
	for i in count:
		reel.append(String(names[i % names.size()]))
	reel.append(target)
	return reel


# Spin to the won item, then run `on_done`. Wraps the shared `start_spin` with this
# card's reveal-done gate and tween bookkeeping.
func _start_slot(reel_names: Array, target: String, on_done: Callable) -> void:
	_reveal_done = false
	_slot_caption.text = ""
	if _slot_tween != null and _slot_tween.is_valid():
		_slot_tween.kill()
	_slot_tween = start_spin(self, _slot_label, reel_names, target,
		Config.data.podium_slot_spin_time, _headless, func() -> void:
			_reveal_done = true
			on_done.call())


# The won part is already fitted (disabled) to the driven car; Apply enables it,
# Keep leaves it disabled. Consumables (the repair kit) + the drivetrain kit skip
# the choice — a consumable just lands in inventory, the drivetrain kit installs
# enabled (its FWD/RWD/AWD selection is made later in the garage).
func _offer_choice(item_id: String, item_name: String) -> void:
	var driven := Save.get_car(_car_instance_id)
	# The repair kit is a consumable — but if the car you just drove is below full
	# health, offer to spend the just-won kit on it right now (it's already in your
	# inventory), instead of only banking it for the garage. Full-health cars fall
	# through to the plain "added to your inventory" path.
	var driven_entry := CarLibrary.by_id(String(driven.get("model_id", "")))
	var driven_below_full := not driven_entry.is_empty() \
			and float(driven.get("hp", 0.0)) < float(driven_entry.get("max_hp", 0.0))
	if item_id == UpgradeLibrary.REPAIR_KIT_ID and not driven.is_empty() and driven_below_full:
		var repair_car := String(CarLibrary.by_id(String(driven.get("model_id", ""))).get("name", "your car"))
		_choice_mode = "repair"
		_choice_item_id = item_id
		_choice_pending = true
		_slot_caption.text = UITheme.caps("Repair your %s now? (uses 1 kit)" % repair_car)
		_apply_button.text = UITheme.caps("Repair now")
		_keep_button.text = UITheme.caps("Save it")
		_choice_box.visible = true
		UITheme.enforce(self)
		# Framework: focus + WASD/arrow/gamepad nav across Repair/Save (no on_back —
		# the host owns back). Seats the cursor on Repair.
		MenuNav.attach(self, {first = _apply_button})
		return
	if driven.is_empty() or UpgradeLibrary.slot_of(item_id) == "" or UpgradeLibrary.is_consumable(item_id):
		_slot_caption.text = UITheme.caps("%s — added to your inventory" % item_name)
		finished.emit()
		return
	var car_name := String(CarLibrary.by_id(String(driven.get("model_id", ""))).get("name", "your car"))
	if UpgradeLibrary.slot_of(item_id) == "drivetrain":
		Save.set_upgrade_enabled(_car_instance_id, item_id, true)
		_slot_caption.text = UITheme.caps("%s installed on your %s — pick a drive mode in the garage" % [item_name, car_name])
		finished.emit()
		return
	_choice_mode = "upgrade"
	_choice_item_id = item_id
	_choice_pending = true
	_slot_caption.text = UITheme.caps("Fit %s to the %s you just drove?" % [item_name, car_name])
	_apply_button.text = UITheme.caps("Apply to %s" % car_name)
	_keep_button.text = UITheme.caps("Keep for later")
	_choice_box.visible = true
	UITheme.enforce(self)
	# Framework: focus + WASD/arrow/gamepad nav across Apply/Keep (no on_back — the
	# host owns back). Seats the cursor on Apply.
	MenuNav.attach(self, {first = _apply_button})


func _on_apply() -> void:
	if _choice_mode == "repair":
		var car_name := String(CarLibrary.by_id(String(Save.get_car(_car_instance_id).get("model_id", ""))).get("name", "your car"))
		Save.use_repair_kit(_car_instance_id)
		_slot_caption.text = UITheme.caps("%s repaired to full health" % car_name)
		_resolve_choice()
		return
	var item_name := String(UpgradeLibrary.by_id(_choice_item_id).get("name", _choice_item_id))
	Save.set_upgrade_enabled(_car_instance_id, _choice_item_id, true)
	_slot_caption.text = UITheme.caps("%s fitted & enabled — toggle it any time in the garage" % item_name)
	_resolve_choice()


func _on_keep() -> void:
	if _choice_mode == "repair":
		_slot_caption.text = UITheme.caps("Repair kit saved to your inventory")
		_resolve_choice()
		return
	var item_name := String(UpgradeLibrary.by_id(_choice_item_id).get("name", _choice_item_id))
	Save.set_upgrade_enabled(_car_instance_id, _choice_item_id, false)
	_slot_caption.text = UITheme.caps("%s fitted (disabled) — enable it any time in the garage" % item_name)
	_resolve_choice()


func _resolve_choice() -> void:
	_choice_item_id = ""
	_choice_mode = "upgrade"
	_choice_pending = false
	_choice_box.visible = false
	finished.emit()
