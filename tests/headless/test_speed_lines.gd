extends GutTest
# scripts/speed_lines.gd — the anime edge-speed-lines overlay. The script eases an
# `intensity` toward a speed-derived target and pushes it into the full-screen
# ColorRect's shader. Because the shader rasterises every pixel whatever the
# intensity, the rect must be HIDDEN while the streaks would be invisible, and
# shown again once they aren't. These cover that gate (against the script's own
# resolved epsilon, never a literal) plus the "don't re-push an unchanged
# parameter" behaviour — no tunable speed/colour value is asserted.

const LinesScript := preload("res://scripts/speed_lines.gd")
const ShaderRes := preload("res://shaders/speed_lines.gdshader")


func before_all() -> void:
	# Most of these are about the visibility GATE inside the enabled path, so switch
	# the effect on explicitly rather than depending on the authored default. Drive
	# the SAVED key (the apply-owner's), not Config.data: the saved value wins over
	# the authored one, so setting only the latter would be order-dependent once
	# anything else has written the key.
	Save.set_setting(SpeedLinesSetting.SETTING_KEY, true)


func after_all() -> void:
	Save.set_setting(SpeedLinesSetting.SETTING_KEY, SpeedLinesSetting.default_enabled())
	Config.reset()


# A wired overlay: the script on a CanvasLayer with the $ColorRect the scene gives
# it, carrying a ShaderMaterial of the real shader. Added to the tree so @onready
# and _ready run exactly as they do in main.tscn.
func _make_overlay() -> CanvasLayer:
	var layer := CanvasLayer.new()
	var rect := ColorRect.new()
	rect.name = "ColorRect"
	var mat := ShaderMaterial.new()
	mat.shader = ShaderRes
	rect.material = mat
	layer.add_child(rect)
	layer.set_script(LinesScript)
	add_child_autofree(layer)
	return layer


func test_hidden_at_zero_intensity() -> void:
	var o := _make_overlay()
	# A stationary car eases to zero intensity: nothing to draw, so the full-screen
	# rect must not be shaded at all.
	o._apply_intensity(0.0)
	assert_false(o._rect.visible, "the overlay rect is hidden when there are no streaks")


func test_visible_above_the_gate() -> void:
	var o := _make_overlay()
	# Just past the script's own resolved threshold — the streaks are drawable, so
	# the rect must be shown (and carry that intensity).
	o._apply_intensity(LinesScript.VISIBLE_EPSILON * 2.0)
	assert_true(o._rect.visible, "the overlay rect is shown once the streaks are visible")
	assert_almost_eq(float(o._rect.material.get_shader_parameter("intensity")),
		LinesScript.VISIBLE_EPSILON * 2.0, 1e-6,
		"the shown intensity is what was pushed to the shader")


func test_hides_again_when_the_streaks_fade_out() -> void:
	var o := _make_overlay()
	o._apply_intensity(LinesScript.VISIBLE_EPSILON * 10.0)
	assert_true(o._rect.visible, "shown while fast")
	o._apply_intensity(0.0)
	assert_false(o._rect.visible, "hidden again once the intensity eases back to nothing")


func test_unchanged_intensity_is_not_republished() -> void:
	var o := _make_overlay()
	var value := LinesScript.VISIBLE_EPSILON * 5.0
	o._apply_intensity(value)
	# Overwrite the shader parameter behind the script's back; a second push of the
	# SAME value must not touch it (that's the skip we're asserting), while a
	# genuinely different value must.
	o._rect.material.set_shader_parameter("intensity", -1.0)
	o._apply_intensity(value)
	assert_almost_eq(float(o._rect.material.get_shader_parameter("intensity")), -1.0, 1e-6,
		"an unchanged intensity is not re-pushed to the shader")
	o._apply_intensity(value * 2.0)
	assert_almost_eq(float(o._rect.material.get_shader_parameter("intensity")), value * 2.0, 1e-6,
		"a changed intensity IS pushed")


# --- Shader pre-warm contract ------------------------------------------------
# The overlay starts hidden, so its full-screen program would otherwise compile on
# the first fast moment of the stage. world.gd's warm block discovers warmers by
# duck-typing on this exact method pair, so the pair itself is the contract.

func test_implements_the_warm_up_contract() -> void:
	var o := _make_overlay()
	# world.gd's warm block filters on precisely these two methods; losing either
	# silently drops the overlay from the pre-warm with no other symptom.
	assert_true(o.has_method("warm_up"), "discoverable by the warm-up walk")
	assert_true(o.has_method("clear_warm_up"), "and clearable after the warmed frame")


func test_warm_up_draws_then_clears() -> void:
	var o := _make_overlay()
	assert_false(o._rect.visible, "starts hidden — nothing would compile the shader")
	o.warm_up(Vector3.ZERO)
	assert_true(o._rect.visible, "warm-up shows the rect so its program compiles")
	o.clear_warm_up()
	assert_false(o._rect.visible, "cleared back to the hidden resting state")


func test_warm_up_stays_visually_transparent() -> void:
	# The compile must happen with nothing actually drawn: intensity stays at zero
	# through the warm frame, so the shader outputs fully transparent regardless of
	# what is layered above or below the overlay.
	var o := _make_overlay()
	o.warm_up(Vector3.ZERO)
	assert_almost_eq(float(o._rect.material.get_shader_parameter("intensity")), 0.0, 1e-6,
		"the warm-up frame shades nothing visible")


func test_warm_up_is_inert_when_the_feature_is_off() -> void:
	# Warming must not revive an overlay the player switched off: nothing will ever
	# draw, so there is no program to compile and the layer must stay hidden.
	Save.set_setting(SpeedLinesSetting.SETTING_KEY, false)
	var o := _make_overlay()
	o.warm_up(Vector3.ZERO)
	assert_false(o.visible, "a disabled overlay stays switched off through the warm-up")
	assert_false(o._rect.visible, "and its rect is never shown for the warm frame")
	o.clear_warm_up()
	assert_false(o.visible, "and stays off after the clear")
	Save.set_setting(SpeedLinesSetting.SETTING_KEY, true)


# --- The on/off seam (SpeedLinesSetting / set_effect_enabled) -----------------
# The disabled state used to be terminal: _ready returned before binding the
# material and turned _process off, so an overlay that started switched off could
# never be switched back on. These pin that it is recoverable in both directions.

func test_starts_from_the_saved_setting() -> void:
	Save.set_setting(SpeedLinesSetting.SETTING_KEY, false)
	var off := _make_overlay()
	assert_false(off.is_effect_enabled(), "constructed disabled when the setting says off")
	assert_false(off.visible, "and the layer is hidden")
	Save.set_setting(SpeedLinesSetting.SETTING_KEY, true)
	var on := _make_overlay()
	assert_true(on.is_effect_enabled(), "constructed enabled when the setting says on")
	assert_true(on.visible, "and the layer is shown")


func test_can_be_enabled_after_being_constructed_disabled() -> void:
	# The exact bug: an overlay that came up disabled must be fully wired, so turning
	# the effect on mid-run actually starts drawing again.
	Save.set_setting(SpeedLinesSetting.SETTING_KEY, false)
	var o := _make_overlay()
	Save.set_setting(SpeedLinesSetting.SETTING_KEY, true)
	o.set_effect_enabled(true)
	assert_true(o.is_effect_enabled(), "the effect reports itself on")
	assert_true(o.visible, "the layer is shown again")
	assert_true(o.is_processing(), "and per-frame easing has resumed")
	assert_not_null(o._mat, "the material was bound even while disabled")
	# And it really can draw: the shader gate still works after the revival.
	o._apply_intensity(LinesScript.VISIBLE_EPSILON * 4.0)
	assert_true(o._rect.visible, "the rect can be shown after being switched back on")


func test_disabling_mid_run_stops_drawing() -> void:
	var o := _make_overlay()
	o._apply_intensity(LinesScript.VISIBLE_EPSILON * 4.0)
	o.set_effect_enabled(false)
	assert_false(o.visible, "the layer is hidden as soon as the effect is switched off")
	assert_false(o.is_processing(), "and the per-frame work stops")
	assert_false(o._rect.visible, "the streaks stop rendering rather than freezing on screen")


func test_toggling_is_idempotent() -> void:
	var o := _make_overlay()
	o.set_effect_enabled(false)
	o.set_effect_enabled(false)
	assert_false(o.is_effect_enabled(), "off twice is still off")
	assert_false(o.visible, "with no visible side effect from the repeat")
	o.set_effect_enabled(true)
	o.set_effect_enabled(true)
	assert_true(o.is_effect_enabled(), "on twice is still on")
	assert_true(o.visible, "and the layer is shown")
	assert_true(o.is_processing(), "and processing runs exactly as after a single call")


func test_a_pre_ready_choice_wins_over_the_saved_setting() -> void:
	# A caller may configure the overlay before it enters the tree; that explicit
	# choice must survive _ready rather than being overwritten by the saved value.
	Save.set_setting(SpeedLinesSetting.SETTING_KEY, true)
	var layer := CanvasLayer.new()
	var rect := ColorRect.new()
	rect.name = "ColorRect"
	var mat := ShaderMaterial.new()
	mat.shader = ShaderRes
	rect.material = mat
	layer.add_child(rect)
	layer.set_script(LinesScript)
	layer.set_effect_enabled(false)
	add_child_autofree(layer)
	assert_false(layer.is_effect_enabled(), "the pre-ready choice survived _ready")
	assert_false(layer.visible, "and was applied once the node was wired")


func test_apply_persists_and_reaches_live_overlays() -> void:
	# SpeedLinesSetting is the apply-owner: one call both saves the choice and
	# re-applies it to every overlay in the tree.
	var o := _make_overlay()
	SpeedLinesSetting.apply(get_tree(), false)
	assert_false(SpeedLinesSetting.resolve(), "the choice is persisted")
	assert_false(o.is_effect_enabled(), "and pushed to the live overlay")
	SpeedLinesSetting.apply(get_tree(), true)
	assert_true(SpeedLinesSetting.resolve(), "and back on again")
	assert_true(o.is_effect_enabled(), "with the live overlay following")


func test_apply_never_writes_the_authored_default() -> void:
	# The player's runtime choice must not drift the authored GameConfig baseline
	# that its own fallback default reads.
	var authored := Config.data.speed_lines_enabled
	SpeedLinesSetting.apply(get_tree(), not authored)
	assert_eq(Config.data.speed_lines_enabled, authored,
		"the authored default is untouched by a player toggle")
	Save.set_setting(SpeedLinesSetting.SETTING_KEY, true)
