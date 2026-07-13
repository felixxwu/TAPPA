extends GutTest
# Loading overlay shown by world.gd while the world is built (track, terrain,
# tree/bush scatter). The staged-loading awaits are no-ops under headless, so
# generation must still complete synchronously when main.tscn is instantiated.

# Preloaded (not load()ed) so the scene's script dependencies — world.gd and the
# generators it pulls in — compile when THIS test script is collected, not inside
# a test body. Otherwise any reload-time warning from those scripts gets
# attributed to the running test as an "unexpected error" in an isolated --fast
# run (GUT blames whatever test is executing when the engine logs the warning).
const MAIN_SCENE := preload("res://main.tscn")


func test_set_step_updates_label() -> void:
	var screen := LoadingScreen.new()
	add_child_autofree(screen)
	screen.set_step("Scattering trees…")
	# The design system uppercases all menu text (house rule 1).
	assert_eq(screen._step.text, "SCATTERING TREES…", "step label reflects set_step() (uppercased)")


func test_finish_frees_overlay() -> void:
	var screen := LoadingScreen.new()
	add_child(screen)
	screen.finish()
	assert_true(screen.is_queued_for_deletion(), "finish() tears the overlay down")


func test_world_generation_completes_synchronously_when_headless() -> void:
	# In headless the _yield_frame() awaits collapse to no-ops, so the entire
	# staged generation chain runs within instantiate()+add_child. The TrackProgress
	# node is wired at the very end of that chain, so its presence proves the whole
	# chain ran — i.e. staging didn't accidentally defer world-gen across frames.
	var scene: Node3D = MAIN_SCENE.instantiate()
	add_child_autofree(scene)
	assert_not_null(scene.get_node_or_null("TrackProgress"),
		"world finished generating synchronously (TrackProgress node is set up)")


func test_loading_overlay_removed_after_generation() -> void:
	var scene: Node3D = MAIN_SCENE.instantiate()
	add_child_autofree(scene)
	# finish() queue_frees the overlay during _ready; one frame later it's gone.
	await get_tree().process_frame
	for child in scene.get_children():
		assert_false(child is LoadingScreen, "loading overlay is removed once the world is ready")


func test_fit_points_returns_empty_below_two_points() -> void:
	assert_eq(LoadingScreen.fit_points(PackedVector2Array(), Rect2(0, 0, 100, 100), 4.0).size(), 0,
		"no points -> nothing to draw")
	assert_eq(LoadingScreen.fit_points(PackedVector2Array([Vector2(1, 1)]), Rect2(0, 0, 100, 100), 4.0).size(), 0,
		"one point -> nothing to draw")


func test_fit_points_maps_into_padded_rect_preserving_aspect() -> void:
	# A 10x10 square of world points fits into a 100x100 rect with pad 10 -> inner 80x80,
	# centered. Square aspect == square inner box, so it should fill the inner box exactly.
	var pts := PackedVector2Array([
		Vector2(0, 0), Vector2(10, 0), Vector2(10, 10), Vector2(0, 10)])
	var out: PackedVector2Array = LoadingScreen.fit_points(pts, Rect2(0, 0, 100, 100), 10.0)
	assert_eq(out.size(), 4, "same number of points out")
	for p in out:
		assert_true(p.x >= 9.99 and p.x <= 90.01, "x stays within the padded rect")
		assert_true(p.y >= 9.99 and p.y <= 90.01, "y stays within the padded rect")
	# The bounding box of the output spans the full inner box on at least one axis.
	var minx: float = out[0].x
	var maxx: float = out[0].x
	for p in out:
		minx = minf(minx, p.x)
		maxx = maxf(maxx, p.x)
	assert_almost_eq(maxx - minx, 80.0, 0.5, "square input fills the 80px inner width")


func test_update_track_preview_stores_points() -> void:
	var screen := LoadingScreen.new()
	add_child_autofree(screen)
	var pts := PackedVector2Array([Vector2(0, 0), Vector2(5, 5)])
	screen.update_track_preview(pts)
	assert_eq(screen._preview._points.size(), 2, "preview stores the supplied points")
