extends Control
# Visual proof sheet for the UI design system (scripts/ui_theme.gd + the global
# theme/ui_theme.tres). Builds a representative screen — title, stat panel, money
# readout, a menu column with a selected option, and a locked bar — then captures
# it to tools/ui_preview.png. Pure tooling; not shipped. Run via:
#
#   xvfb-run -a -s "-screen 0 1280x720x24" godot --path rally \
#       --rendering-driver opengl3 res://tools/ui_preview.tscn
#
# (Boots as a scene so the project default theme is applied to every Control.)

const OUT := "res://tools/ui_preview.png"


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	# A grassy field behind, like the game world, so panel/text contrast is honest.
	var bg := ColorRect.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(0.42, 0.55, 0.30)
	add_child(bg)

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for s in ["left", "top", "right", "bottom"]:
		margin.add_theme_constant_override("margin_" + s, 40)
	add_child(margin)

	var cols := HBoxContainer.new()
	cols.add_theme_constant_override("separation", 40)
	margin.add_child(cols)

	# --- Left column: a terminal-style stat panel + money. ---
	var left := VBoxContainer.new()
	left.add_theme_constant_override("separation", UITheme.GAP)
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cols.add_child(left)

	left.add_child(UITheme.title("Rally HQ"))

	var stat_panel := UITheme.panel(1.0, 18)
	left.add_child(stat_panel)
	var stats := VBoxContainer.new()
	stats.add_theme_constant_override("separation", 2)
	stat_panel.add_child(stats)
	stats.add_child(UITheme.label("PERKS", UITheme.SIZE_HEADING))
	stats.add_child(UITheme.label("SLOT 1: " , UITheme.SIZE_LABEL))
	stats.add_child(_row("HEALTH   [#][#][#][#][#]  700/700", "green"))
	stats.add_child(_row("POWER    [#][#][#].  .    245", "ink"))
	stats.add_child(_row("WEIGHT   .  .  .  .  .    1760", "ink"))
	stats.add_child(_row("GRIP     [#][#][#][#][#]  190", "ink"))

	var money_row := UITheme.panel(1.0, 14)
	left.add_child(money_row)
	money_row.add_child(UITheme.money("$88,052"))

	# --- Right column: a menu with one option selected + a locked bar. ---
	var right := VBoxContainer.new()
	right.add_theme_constant_override("separation", UITheme.GAP)
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.alignment = BoxContainer.ALIGNMENT_CENTER
	cols.add_child(right)

	right.add_child(UITheme.title("Paused"))

	var continue_btn := UITheme.button("Continue")
	UITheme.mark_selected(continue_btn, true)
	right.add_child(UITheme.flank(continue_btn, true))

	right.add_child(UITheme.button("Settings"))
	right.add_child(UITheme.button("Quit"))

	var locked := UITheme.button("Locked (5/20)")
	locked.disabled = true
	right.add_child(locked)

	await _capture()


func _row(text: String, role: String) -> Label:
	return UITheme.label(text, UITheme.SIZE_LABEL, role)


func _capture() -> void:
	for _i in 6:
		await get_tree().process_frame
	var img := get_viewport().get_texture().get_image()
	var err := img.save_png(OUT)
	print("ui-preview: saved ", OUT, " err=", err)
	get_tree().quit()
