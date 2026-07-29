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
	# The overlay disables itself wholesale when the feature is off; these tests are
	# about the visibility GATE inside the enabled path, so switch it on explicitly
	# rather than depending on the authored default.
	Config.data.speed_lines_enabled = true


func after_all() -> void:
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
	# Disabled in config, _ready returns before the material is wired, so warming
	# must no-op on the null material rather than erroring — and must not revive an
	# overlay the player switched off. The guarantee is the LAYER staying hidden:
	# the disabled path never runs _apply_intensity, so the inner rect keeps its
	# default visible=true and says nothing either way.
	Config.data.speed_lines_enabled = false
	var o := _make_overlay()
	o.warm_up(Vector3.ZERO)
	assert_false(o.visible, "a disabled overlay stays switched off through the warm-up")
	o.clear_warm_up()
	assert_false(o.visible, "and stays off after the clear")
	Config.data.speed_lines_enabled = true
