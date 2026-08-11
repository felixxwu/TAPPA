extends GutTest
# WORLD-SPACE MENUS (world_panel.gd, features/world-panel.md). A WorldPanel hosts an
# ordinary menu Control tree in a SubViewport and shows it on a NON-billboarded Sprite3D,
# so the panel is read at whatever angle its mounting transform gives it.
#
# WHAT THIS FILE IS ACTUALLY GUARDING. A SubViewport receives no window input at all, so
# every widget inside a panel is dead until the panel's pump converts a screen position
# into a panel pixel and pushes it across. The conversion is the part that can be subtly
# wrong: foreshortening concentrates mapping error at the FAR edge of an angled panel, so
# a pump that looks fine dead-centre can miss by a whole button out at the edge. Hence the
# far-edge cases below, which are the point of the file rather than extra thoroughness.
#
# Every panel here is built at a deliberately OFF-SQUARE yaw — testing a square-on panel
# would pass with a conversion that ignored the panel's basis entirely.
#
# No tunable is asserted: not the supersample factor, not the panel's metre height, not a
# marker offset or yaw from GameConfig. Those are look values a designer retunes by eye
# (project rule), so the tests assert the BEHAVIOUR that must hold at any of them —
# a ray at a button's centre presses that button, whatever size the panel is.

const PANEL_YAW := 34.0  # off-square on purpose; not a product value

var _root: Node3D
var _cam: Camera3D
var _panel: WorldPanel


func before_each() -> void:
	_root = Node3D.new()
	add_child_autofree(_root)
	_cam = Camera3D.new()
	_root.add_child(_cam)
	# Camera at the origin looking down −Z (Godot's default forward).
	_cam.global_transform = Transform3D(Basis(), Vector3.ZERO)

	_panel = WorldPanel.new()
	_root.add_child(_panel)
	# 4 m in front of the camera, yawed off-square.
	_panel.global_transform = Transform3D(
		Basis(Vector3.UP, deg_to_rad(PANEL_YAW)), Vector3(0.0, 0.0, -4.0))
	# The panel reads the camera off its viewport in production; headless there is no
	# active 3D camera, so hand it the one built above.
	_panel._camera_override = func() -> Camera3D: return _cam


# Host a single control filling the whole panel, so "aim at the control" and "aim at the
# panel" are the same ray and a miss is unambiguous.
#
# DELIBERATELY NOT A COROUTINE. Callers do their own `await wait_frames(...)` afterwards
# (the hosted control has no rect until a layout pass runs). Awaiting a `-> void` helper
# does not suspend the caller the way it looks like it does, and GUT then treats the test
# as finished and runs after_each — freeing the panel out from under the rest of the test.
func _host_full_rect(ctrl: Control) -> void:
	var holder := Control.new()
	holder.set_anchors_preset(Control.PRESET_FULL_RECT)
	ctrl.set_anchors_preset(Control.PRESET_FULL_RECT)
	holder.add_child(ctrl)
	_panel.host(holder)


# The screen position that lands on a given UV of the panel. Built by going FORWARD
# (panel UV → world point → screen) so the test never reuses the pump's own maths to
# decide where to aim — otherwise a wrong conversion would agree with itself and pass.
func _screen_pos_for_uv(uv: Vector2) -> Vector2:
	var size_m := _panel.world_size()
	var local := Vector3(
		(uv.x - 0.5) * size_m.x,
		(0.5 - uv.y) * size_m.y,
		0.0)
	return _cam.unproject_position(_panel.surface().global_transform * local)


func _press(screen_pos: Vector2, pressed: bool) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = pressed
	ev.position = screen_pos
	ev.global_position = screen_pos
	_panel._input(ev)


func _move(screen_pos: Vector2) -> void:
	var ev := InputEventMouseMotion.new()
	ev.position = screen_pos
	ev.global_position = screen_pos
	_panel._input(ev)


# --- The ray → pixel conversion ---------------------------------------------------

func test_centre_of_panel_maps_to_centre_of_viewport() -> void:
	var got: Variant = _panel.pixel_at(_screen_pos_for_uv(Vector2(0.5, 0.5)))
	assert_not_null(got, "a ray at the panel centre must hit the panel")
	var centre := Vector2(_panel.viewport().size) * 0.5
	assert_almost_eq((got as Vector2).x, centre.x, 1.0)
	assert_almost_eq((got as Vector2).y, centre.y, 1.0)


# THE FAR-EDGE CASE — the one most likely to be subtly wrong on an angled panel, and the
# reason this file exists. A conversion that clamps, or that treats the panel as
# screen-aligned, drifts here while still passing the centre case above.
func test_far_foreshortened_edge_maps_to_that_edge() -> void:
	# With a positive yaw about UP the panel's +X side rotates away from the camera, so
	# UV x≈1 is the compressed far edge.
	var uv := Vector2(0.97, 0.5)
	var got: Variant = _panel.pixel_at(_screen_pos_for_uv(uv))
	assert_not_null(got, "the far edge of the panel is still on the panel")
	var expected := uv * Vector2(_panel.viewport().size)
	# A couple of pixels of slack for the float round-trip through unproject/project.
	assert_almost_eq((got as Vector2).x, expected.x, 3.0)


func test_a_ray_past_the_edge_misses_the_panel() -> void:
	# Just outside the quad: must return null so the press is left for the world behind
	# the panel rather than being clamped onto the nearest button.
	assert_null(_panel.pixel_at(_screen_pos_for_uv(Vector2(1.06, 0.5))),
		"a ray beyond the panel's bounds must not report a hit")


func test_world_size_follows_the_sprite_rather_than_a_stored_copy() -> void:
	# The hit-test region is derived from the quad the player actually sees, so changing
	# the quad changes the region — there is no second copy to fall out of sync.
	var before := _panel.world_size()
	_panel.surface().pixel_size *= 2.0
	assert_almost_eq(_panel.world_size().x, before.x * 2.0, 0.001)
	assert_almost_eq(_panel.world_size().y, before.y * 2.0, 0.001)


# --- Forwarding into the hosted tree ----------------------------------------------

func test_a_tap_at_a_buttons_centre_presses_it() -> void:
	var btn := Button.new()
	var fired := [false]
	btn.pressed.connect(func() -> void: fired[0] = true)
	_host_full_rect(btn)
	await wait_frames(2)

	var pos := _screen_pos_for_uv(Vector2(0.5, 0.5))
	_press(pos, true)
	_press(pos, false)
	await wait_frames(1)
	assert_true(fired[0], "a press aimed at the button must reach it through the panel")


func test_a_tap_that_misses_the_panel_presses_nothing() -> void:
	var btn := Button.new()
	var fired := [false]
	btn.pressed.connect(func() -> void: fired[0] = true)
	_host_full_rect(btn)
	await wait_frames(2)

	var pos := _screen_pos_for_uv(Vector2(1.06, 0.5))
	_press(pos, true)
	_press(pos, false)
	await wait_frames(1)
	assert_false(fired[0], "a press off the panel must not reach the hosted tree")


# A DRAG, not a click — the case that fails silently if the pump forwards only press and
# release. Sliders are the only menu widget that needs continuous motion, and the tuning
# page is built out of them.
func test_a_drag_across_a_slider_moves_it() -> void:
	var slider := HSlider.new()
	slider.min_value = 0.0
	slider.max_value = 100.0
	slider.value = 0.0
	_host_full_rect(slider)
	await wait_frames(2)

	_press(_screen_pos_for_uv(Vector2(0.1, 0.5)), true)
	await wait_frames(1)
	var after_press := slider.value
	# Motion while held, toward the far end of the track.
	for x in [0.3, 0.5, 0.7]:
		_move(_screen_pos_for_uv(Vector2(x, 0.5)))
		await wait_frames(1)
	_press(_screen_pos_for_uv(Vector2(0.7, 0.5)), false)
	await wait_frames(1)
	assert_gt(slider.value, after_press,
		"motion while pressed must reach the slider, or drags die on world panels")


# A drag that leaves the quad keeps going. On a foreshortened panel the on-screen area is
# much smaller than the player expects, so slipping off mid-drag is normal — the grab has
# to survive it or sliders feel broken exactly when the panel is most angled.
func test_a_drag_that_leaves_the_panel_keeps_tracking() -> void:
	var slider := HSlider.new()
	slider.min_value = 0.0
	slider.max_value = 100.0
	slider.value = 50.0
	_host_full_rect(slider)
	await wait_frames(2)

	_press(_screen_pos_for_uv(Vector2(0.5, 0.5)), true)
	await wait_frames(1)
	var held := slider.value
	_move(_screen_pos_for_uv(Vector2(1.4, 0.5)))  # well off the quad
	await wait_frames(1)
	_press(_screen_pos_for_uv(Vector2(1.4, 0.5)), false)
	await wait_frames(1)
	assert_ne(slider.value, held,
		"a drag that slipped off the panel must still be delivered")


func test_keys_reach_a_hosted_menu_nav() -> void:
	# The pump forwards non-pointer events verbatim: no ray, but it still has to happen at
	# all, or MenuNav and ui_accept are dead inside every panel.
	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_FULL_RECT)
	var first := Button.new()
	first.text = "FIRST"
	var second := Button.new()
	second.text = "SECOND"
	box.add_child(first)
	box.add_child(second)
	_panel.host(box)
	MenuNav.attach(box, {"first": first})
	await wait_frames(2)
	assert_eq(_panel.viewport().gui_get_focus_owner(), first as Control,
		"the hosted menu should seat its cursor inside the panel's own viewport")

	var ev := InputEventAction.new()
	ev.action = "menu_down"
	ev.pressed = true
	_panel._unhandled_input(ev)
	await wait_frames(1)
	assert_eq(_panel.viewport().gui_get_focus_owner(), second as Control,
		"menu_down must cross into the panel and move its focus")


# --- UI scale ----------------------------------------------------------------------

# THE "IT'S TOO SMALL" DIAL. ui_scale lays the menu out on a SMALLER canvas so every
# widget reads bigger on the panel — which only works if the frame shrinks while the
# rendered area still fills the viewport. Get the second half wrong and the menu is bigger
# but cropped, or correctly sized on a panel that no longer covers its own quad.
#
# Asserts the RELATIONSHIP (2× the scale = half the canvas, same rendered coverage), not
# any particular scale value — the default is a look tunable.
func test_ui_scale_shrinks_the_layout_canvas_but_still_fills_the_panel() -> void:
	var plain := WorldPanel.new(2.0, 1.0)
	_root.add_child(plain)
	var scaled := WorldPanel.new(2.0, 2.0)
	_root.add_child(scaled)
	await wait_frames(1)

	var frame_plain := plain.frame()
	var frame_scaled := scaled.frame()
	assert_almost_eq(frame_scaled.size.x, frame_plain.size.x * 0.5, 0.5,
		"double the ui_scale must lay the menu out on half the canvas width")
	assert_almost_eq(frame_scaled.size.y, frame_plain.size.y * 0.5, 0.5,
		"double the ui_scale must lay the menu out on half the canvas height")

	# Both must still cover their whole viewport, or the menu is cropped / undersized.
	for pair in [[frame_plain, plain], [frame_scaled, scaled]]:
		var frame := pair[0] as Control
		var panel := pair[1] as WorldPanel
		var covered := frame.size * frame.scale
		assert_almost_eq(covered.x, float(panel.viewport().size.x), 1.0,
			"the scaled frame must fill the viewport width")
		assert_almost_eq(covered.y, float(panel.viewport().size.y), 1.0,
			"the scaled frame must fill the viewport height")


# --- Hosting -----------------------------------------------------------------------

# THE A/B TOGGLE IS A MOVE, NOT A REBUILD (hq.gd::_sync_panel). The same tree has to be
# able to go from a CanvasLayer to a panel and back with its widgets and signal
# connections intact — a swap that rebuilt the tree would compare two different menus and
# would drop every callback the host had wired.
func test_a_tree_moves_between_a_flat_host_and_a_panel_intact() -> void:
	var layer := CanvasLayer.new()
	_root.add_child(layer)
	var tree := VBoxContainer.new()
	var btn := Button.new()
	var fired := [false]
	btn.pressed.connect(func() -> void: fired[0] = true)
	tree.add_child(btn)
	layer.add_child(tree)

	_panel.host(tree)
	await wait_frames(1)
	assert_eq(_panel.hosted(), tree as Control, "the panel should now own the tree")
	assert_eq(layer.get_child_count(), 0, "the flat host must have let go of it")

	# ...and back to the flat host, the direction the toggle also has to work in.
	tree.get_parent().remove_child(tree)
	layer.add_child(tree)
	await wait_frames(1)
	assert_eq(tree.get_parent(), layer as Node, "the tree returns to the flat host")
	# The widget survived both moves with its wiring — the point of moving rather than
	# rebuilding.
	btn.emit_signal("pressed")
	assert_true(fired[0], "connections must survive being reparented between hosts")


# --- Visibility gating ------------------------------------------------------------

# The perf lesson inherited from the map-table pin labels: a render target left armed
# composites UI nobody is looking at, every frame.
func test_a_hidden_panel_stops_compositing() -> void:
	_host_full_rect(Button.new())
	await wait_frames(2)
	assert_eq(_panel.viewport().render_target_update_mode, SubViewport.UPDATE_ALWAYS,
		"a visible panel must be compositing")
	_panel.visible = false
	await wait_frames(1)
	assert_eq(_panel.viewport().render_target_update_mode, SubViewport.UPDATE_DISABLED,
		"a hidden panel must not keep compositing")


func test_a_hidden_panel_forwards_nothing() -> void:
	var btn := Button.new()
	var fired := [false]
	btn.pressed.connect(func() -> void: fired[0] = true)
	_host_full_rect(btn)
	await wait_frames(2)
	_panel.visible = false

	var pos := _screen_pos_for_uv(Vector2(0.5, 0.5))
	_press(pos, true)
	_press(pos, false)
	await wait_frames(1)
	assert_false(fired[0], "a hidden panel must not eat presses meant for what IS shown")


# The menu_nav.gd change this feature required. is_on_screen already knew that a hidden
# CanvasLayer ancestor breaks the visibility chain without changing anything on the
# Control chain; a hidden WorldPanel is the same trap one host later — a SubViewport is
# not a CanvasLayer, so without the Node3D clause a hidden panel's MenuNav stays live and
# keeps eating menu_* / ui_cancel from whatever is actually on screen.
func test_menu_nav_is_inert_inside_a_hidden_world_panel() -> void:
	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_FULL_RECT)
	var btn := Button.new()
	box.add_child(btn)
	_panel.host(box)
	await wait_frames(2)
	assert_true(MenuNav.is_on_screen(btn), "a shown panel's widgets are on screen")

	_panel.visible = false
	await wait_frames(1)
	assert_false(MenuNav.is_on_screen(btn),
		"a widget inside a hidden world panel must not count as on screen")
