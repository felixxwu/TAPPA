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


func test_theme_uses_the_house_font() -> void:
	var theme := UITheme.theme()
	assert_not_null(theme.default_font, "theme has a default font")
	assert_eq(theme.default_font_size, UITheme.FONT_SIZE, "default size is the one house size")


func test_primary_font_loads() -> void:
	assert_not_null(UITheme.font(), "the UI font (Syne Mono) loads")


func test_label_helper_applies_role_colour() -> void:
	var money := UITheme.money("$88,052")
	assert_eq(money.get_theme_color("font_color"), UITheme.GOLD, "money is gold")
	var danger := UITheme.label("WRECKED", "red")
	assert_eq(danger.get_theme_color("font_color"), UITheme.RED, "danger is red")
	money.free()
	danger.free()


func test_caps_uppercases() -> void:
	assert_eq(UITheme.caps("Continue"), "CONTINUE")


func test_button_helper_uppercases_fixed_height_unfocusable() -> void:
	var b := UITheme.button("Settings")
	assert_eq(b.text, "SETTINGS", "rule 1: button text is uppercased")
	assert_eq(b.custom_minimum_size.y, float(UITheme.MENU_ROW_H), "rule 3: fixed compact height")
	assert_eq(b.focus_mode, Control.FOCUS_NONE, "menu buttons take no focus ring")
	b.free()


func test_label_helper_uppercases_and_uses_one_size() -> void:
	var l := UITheme.label("Continue")
	assert_eq(l.text, "CONTINUE", "rule 1: label text is uppercased")
	assert_eq(l.get_theme_font_size("font_size"), UITheme.FONT_SIZE, "rule 2: one font size")
	l.free()


func test_enforce_applies_rules_across_a_menu_tree() -> void:
	# A menu subtree built without the helpers still gets normalised.
	var root := VBoxContainer.new()
	var lab := Label.new()
	lab.text = "Standings"
	lab.add_theme_font_size_override("font_size", 44)  # a rogue big size
	root.add_child(lab)
	var btn := Button.new()
	btn.text = "Next >"
	root.add_child(btn)
	add_child(root)

	UITheme.enforce(root)
	assert_eq(lab.text, "STANDINGS", "rule 1: labels uppercased")
	assert_eq(lab.get_theme_font_size("font_size"), UITheme.FONT_SIZE, "rule 2: rogue size overridden")
	assert_eq(btn.text, "NEXT >", "rule 1: buttons uppercased")
	assert_eq(btn.custom_minimum_size.y, float(UITheme.MENU_ROW_H), "rule 3: single-line button height")
	root.free()


func test_mark_selected_underlines_green_when_selected() -> void:
	var b := Button.new()
	UITheme.mark_selected(b, true)
	# mark_selected wraps the box with the theme-wide hard shadow (UITheme.shadowed) —
	# unwrap it to reach the StyleBoxFlat-specific border properties.
	var wrapper := b.get_theme_stylebox("normal") as UIHardShadowBox
	assert_not_null(wrapper, "a shadow-wrapped stylebox is applied")
	var box := wrapper.inner as StyleBoxFlat
	assert_not_null(box, "the wrapped stylebox is a StyleBoxFlat")
	assert_eq(box.border_width_bottom, 3, "selected row has a bottom underline")
	assert_eq(box.border_color, UITheme.GREEN, "underline is green")
	assert_eq(b.get_theme_color("font_color"), UITheme.GREEN, "selected text is green")
	# Unselected: no underline.
	UITheme.mark_selected(b, false)
	var off := (b.get_theme_stylebox("normal") as UIHardShadowBox).inner as StyleBoxFlat
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


# --- UI scale (features/ui-design-system.md → "UI scale") ------------------------

func test_px_scales_authored_sizes_consistently() -> void:
	# The design constants and px() must agree — whatever UI_SCALE is tuned to.
	assert_eq(UITheme.FONT_SIZE, UITheme.px(16), "FONT_SIZE is the scaled authored 16")
	assert_eq(UITheme.MENU_ROW_H, UITheme.px(30), "MENU_ROW_H is the scaled authored 30")
	assert_eq(UITheme.px(0), 0, "px(0) stays 0")


func test_ui_scale_is_a_sane_factor() -> void:
	# Sanity only (never pin the chosen value): positive and monotonic.
	assert_gt(UITheme.UI_SCALE, 0.0, "UI_SCALE is positive")
	assert_true(UITheme.px(20) > UITheme.px(10), "px is monotonic")


# An invisible surface casts no shadow. UIHardShadowBox's shadow rect is normally hidden
# under the widget's own opaque face (only the down-right sliver shows); behind a
# zero-alpha fill there is nothing to hide it, so the whole offset rect used to show at
# full strength and read as a big dark translucent panel — the "dark container around all
# the cards" on a carousel page, whose MenuPage body is deliberately transparent.
func test_a_transparent_wrapped_box_casts_no_shadow() -> void:
	var opaque := UITheme.shadowed(UITheme.panel_box(1.0)) as UIHardShadowBox
	assert_not_null(opaque, "shadowed() returns the wrapper")
	assert_true(opaque.casts_shadow(), "a box with a real fill still casts")

	var clear := UITheme.shadowed(UITheme.panel_box(0.0)) as UIHardShadowBox
	assert_false(clear.casts_shadow(), "a fully transparent box casts nothing")

	var empty := UITheme.shadowed(StyleBoxEmpty.new()) as UIHardShadowBox
	assert_false(empty.casts_shadow(), "a StyleBoxEmpty casts nothing")

	# The wrapper must still forward the wrapped box's padding either way, or a
	# transparent panel's children would reflow when the shadow is skipped.
	assert_eq(clear.get_margin(SIDE_LEFT), UITheme.panel_box(0.0).get_margin(SIDE_LEFT),
		"content margins are forwarded regardless of whether the shadow draws")


# A transparent MenuPage body (what the carousel pages ask for) must come out
# non-casting end to end, not just at the UITheme helper level.
func test_a_transparent_menu_page_body_casts_no_shadow() -> void:
	var page := MenuPage.new({"alpha": 0.0})
	add_child(page)
	var box := page.panel().get_theme_stylebox("panel") as UIHardShadowBox
	assert_not_null(box, "the body box is shadow-wrapped as before")
	assert_false(box.casts_shadow(), "a transparent body paints no shadow rect")
	page.free()

	var solid := MenuPage.new({})
	add_child(solid)
	var solid_box := solid.panel().get_theme_stylebox("panel") as UIHardShadowBox
	assert_true(solid_box.casts_shadow(), "an ordinary opaque page still casts")
	solid.free()
