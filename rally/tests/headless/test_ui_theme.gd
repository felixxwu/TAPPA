extends GutTest
# Guards the UI design system (scripts/ui_theme.gd + theme/ui_theme.tres):
# the global theme is wired and carries the house font/styleboxes, and the
# UITheme helpers produce the expected roles / selection treatment.


func test_theme_resource_loads() -> void:
	var theme := UITheme.theme()
	assert_not_null(theme, "theme/ui_theme.tres loads")
	assert_true(theme is Theme, "it is a Theme")


func test_project_default_theme_is_the_design_system() -> void:
	# project.godot [gui] theme/custom must point at the generated theme so every
	# Control inherits the house look automatically.
	var path := str(ProjectSettings.get_setting("gui/theme/custom", ""))
	assert_eq(path, "res://theme/ui_theme.tres", "global default theme is wired")


func test_theme_uses_the_pixel_font() -> void:
	var theme := UITheme.theme()
	assert_not_null(theme.default_font, "theme has a default font")
	assert_eq(theme.default_font_size, UITheme.SIZE_BODY, "default size is the body size")


func test_primary_font_loads() -> void:
	assert_not_null(UITheme.font(), "VT323 font loads")


func test_label_helper_applies_role_colour() -> void:
	var money := UITheme.money("$88,052")
	assert_eq(money.get_theme_color("font_color"), UITheme.GOLD, "money is gold")
	var danger := UITheme.label("WRECKED", UITheme.SIZE_BODY, "red")
	assert_eq(danger.get_theme_color("font_color"), UITheme.RED, "danger is red")
	money.free()
	danger.free()


func test_caps_uppercases() -> void:
	assert_eq(UITheme.caps("Continue"), "CONTINUE")


func test_button_helper_is_uppercase_and_unfocusable() -> void:
	var b := UITheme.button("Settings")
	assert_eq(b.text, "SETTINGS", "button text is uppercased")
	assert_eq(b.focus_mode, Control.FOCUS_NONE, "menu buttons take no focus ring")
	b.free()


func test_mark_selected_underlines_green_when_selected() -> void:
	var b := Button.new()
	UITheme.mark_selected(b, true)
	var box := b.get_theme_stylebox("normal") as StyleBoxFlat
	assert_not_null(box, "a stylebox is applied")
	assert_eq(box.border_width_bottom, 3, "selected row has a bottom underline")
	assert_eq(box.border_color, UITheme.GREEN, "underline is green")
	assert_eq(b.get_theme_color("font_color"), UITheme.GREEN, "selected text is green")
	# Unselected: no underline.
	UITheme.mark_selected(b, false)
	var off := b.get_theme_stylebox("normal") as StyleBoxFlat
	assert_eq(off.border_width_bottom, 0, "unselected row has no underline")
	b.free()


func test_flank_shows_markers_only_when_active() -> void:
	var inner := UITheme.button("Continue")
	var row := UITheme.flank(inner, true)
	# Triangle, inner, triangle.
	assert_eq(row.get_child_count(), 3, "flank wraps inner with two markers")
	assert_true((row.get_child(0) as Label).visible, "left marker shown when active")
	assert_true((row.get_child(2) as Label).visible, "right marker shown when active")
	row.free()

	var inner2 := UITheme.button("Continue")
	var row2 := UITheme.flank(inner2, false)
	assert_false((row2.get_child(0) as Label).visible, "markers hidden when inactive")
	row2.free()


func test_panel_box_is_black_and_sharp_cornered() -> void:
	var box := UITheme.panel_box(0.9, 18)
	assert_eq(box.bg_color, Color(0.0, 0.0, 0.0, 0.9), "panel is black at the given alpha")
	assert_eq(box.corner_radius_top_left, 0, "no rounded corners")
	assert_eq(box.content_margin_left, 18.0, "honours the padding")
