extends Control
class_name RepairReveal
# The between-event pit-repair popup (features/damage.md): a small modal shown at the
# START of every rally event after the first, telling the player the engineers patched
# the fielded car up — a slice of the lost HP restored and the bent wheels bent part-way
# back toward straight. The actual repair happens in RallySession._enter_event /
# Save.field_repair BEFORE the scene reloads; this card only REPORTS the summary handed
# in via reveal(). Dismissed with a single Continue button (keyboard / gamepad / tap),
# then emits `finished` so the run scene proceeds to the start-line briefing.
#
# Visually matches the reward card (UpgradeReveal): pure-black house panel, one font
# size, uppercase, centred. Built by world.gd before the start line (session runs only).

signal finished()

var _summary: Dictionary = {}
var _continue_button: Button
var _health_label: Label
var _wheels_label: Label


func _ready() -> void:
	_build_ui()


func _build_ui() -> void:
	# Fill the viewport explicitly: a bare Control added straight to a CanvasLayer is
	# NOT sized by a parent container (unlike UpgradeReveal, which lives inside a
	# SIZE_EXPAND_FILL slot), so full-rect anchors alone leave it at its 0-size default
	# and the centred card lands top-left. Stamp the size from the viewport and keep it
	# in sync so the card stays centred across resizes.
	_fill_viewport()
	get_viewport().size_changed.connect(_fill_viewport)

	# Dim the world behind the card so it reads as a modal (and eats stray clicks).
	var bg := ColorRect.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.color = UITheme.PANEL_DIM
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	# A full-rect column, vertically centred, with a shrink-centred card — the same
	# centring idiom the wreck screen / reward card use (a CenterContainer child does
	# NOT fill here, so it's not used).
	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.alignment = BoxContainer.ALIGNMENT_CENTER
	add_child(root)

	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	panel.add_theme_stylebox_override("panel", UITheme.reward_card_box())
	root.add_child(panel)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", UITheme.GAP)
	panel.add_child(col)

	col.add_child(UITheme.title("Pit Repairs Complete"))

	_health_label = Label.new()
	_health_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(_health_label)

	_wheels_label = Label.new()
	_wheels_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(_wheels_label)

	_continue_button = UITheme.button("Continue")
	_continue_button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_continue_button.pressed.connect(_on_continue)
	col.add_child(_continue_button)

	UITheme.enforce(self)


# Populate the card from a Save.field_repair summary
# ({repaired, hp_before, hp_after, max_hp, hp_gained}) and seat focus on Continue.
func reveal(summary: Dictionary) -> void:
	_summary = summary
	var max_hp := float(summary.get("max_hp", 0.0))
	var before := float(summary.get("hp_before", 0.0))
	var after := float(summary.get("hp_after", 0.0))
	var pct := func(v: float) -> int:
		return int(round(100.0 * v / max_hp)) if max_hp > 0.0 else 0
	var pct_after: int = pct.call(after)
	var gained: int = pct_after - int(pct.call(before))
	# A sub-1-point patch (e.g. a wheels-only fix on a near-full car) rounds to +0%,
	# which reads as "nothing happened" — show "+<1%" instead when HP did climb.
	var gain_txt := "+<1%" if gained <= 0 and after > before else "+%d%%" % gained
	_health_label.text = UITheme.caps("Health  %s  →  %d%%" % [gain_txt, pct_after])
	_wheels_label.text = UITheme.caps("Wheel alignment  recentered")
	UITheme.enforce(self)
	# Framework: focus + WASD/arrow/gamepad nav (single button; no on_back — the host
	# owns back). Seats the cursor on Continue so it's driveable without a pointer.
	MenuNav.attach(self, {first = _continue_button})


func _fill_viewport() -> void:
	set_deferred("size", get_viewport_rect().size)
	position = Vector2.ZERO


func _on_continue() -> void:
	finished.emit()
