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


func test_bounds_of_returns_min_and_span() -> void:
	var pts := PackedVector2Array([Vector2(2, 5), Vector2(-1, 5), Vector2(4, 9)])
	var b := LoadingScreen.bounds_of(pts)
	assert_almost_eq(b.position, Vector2(-1, 5), Vector2(1e-4, 1e-4), "position is the min corner")
	assert_almost_eq(b.size, Vector2(5, 4), Vector2(1e-4, 1e-4), "size is the span (max - min)")


func test_fit_transform_maps_bounds_into_padded_rect_preserving_aspect() -> void:
	# A 10x10 world box into a 100x100 rect, pad 10 -> inner 80x80, square aspect fills it.
	var b := Rect2(Vector2(0, 0), Vector2(10, 10))
	var xf := LoadingScreen.fit_transform(b, Rect2(0, 0, 100, 100), 10.0)
	var p0 := xf * Vector2(0, 0)
	var p1 := xf * Vector2(10, 10)
	assert_almost_eq(p0, Vector2(10, 10), Vector2(0.5, 0.5), "world min maps to the inner top-left")
	assert_almost_eq(p1, Vector2(90, 90), Vector2(0.5, 0.5), "world max maps to the inner bottom-right")


func test_fit_transform_shared_frame_maps_centre_to_rect_centre() -> void:
	# Same bounds/rect/pad -> a shared world point maps identically; this is what lets
	# the track line and chunk squares line up in one frame.
	var b := Rect2(Vector2(-5, -5), Vector2(20, 20))
	var xf := LoadingScreen.fit_transform(b, Rect2(0, 0, 200, 120), 8.0)
	var centre := b.position + b.size * 0.5
	assert_almost_eq(xf * centre, Vector2(100, 60), Vector2(0.6, 0.6), "world centre maps to rect centre")


func test_set_chunk_size_stored() -> void:
	var screen := LoadingScreen.new()
	add_child_autofree(screen)
	screen.set_chunk_size(50.0)
	assert_almost_eq(screen._preview._chunk_size, 50.0, 1e-4, "chunk size stored on the preview")


func test_update_loaded_chunks_stores_corners() -> void:
	var screen := LoadingScreen.new()
	add_child_autofree(screen)
	var corners := PackedVector2Array([Vector2(0, 0), Vector2(50, 0), Vector2(0, 50)])
	screen.update_loaded_chunks(corners)
	assert_eq(screen._preview._chunk_corners.size(), 3, "preview stores the supplied chunk corners")


func test_preview_clips_contents() -> void:
	var screen := LoadingScreen.new()
	add_child_autofree(screen)
	assert_true(screen._preview.clip_contents, "preview clips squares that fall outside the panel")


func test_carve_prefix_empty_and_full() -> void:
	var pts := PackedVector2Array([Vector2(0, 0), Vector2(10, 0), Vector2(20, 0)])
	assert_eq(LoadingScreen.carve_prefix(pts, 0.0).size(), 0, "progress 0 -> nothing white")
	assert_eq(LoadingScreen.carve_prefix(pts, 1.0).size(), pts.size(), "progress 1 -> whole line white")
	assert_eq(LoadingScreen.carve_prefix(PackedVector2Array([Vector2(0, 0)]), 0.5).size(), 0,
		"< 2 points -> empty")


func test_carve_prefix_interpolates_boundary() -> void:
	# 3 points along +X (0, 10, 20). progress 0.5 -> split_f = 1.0 -> ki=1, frac=0:
	# prefix = first two points, ending exactly at the midpoint.
	var pts := PackedVector2Array([Vector2(0, 0), Vector2(10, 0), Vector2(20, 0)])
	var half := LoadingScreen.carve_prefix(pts, 0.5)
	assert_eq(half.size(), 2, "half -> first two points")
	assert_almost_eq(half[half.size() - 1], Vector2(10, 0), Vector2(1e-4, 1e-4), "prefix ends at the midpoint")
	# progress 0.25 -> split_f = 0.5 -> ki=0, frac=0.5 -> [p0, lerp(p0, p1, 0.5) = (5, 0)].
	var q := LoadingScreen.carve_prefix(pts, 0.25)
	assert_eq(q.size(), 2, "quarter -> p0 + interpolated boundary")
	assert_almost_eq(q[1], Vector2(5, 0), Vector2(1e-4, 1e-4), "boundary interpolated at 1/4 length")


func test_set_carve_progress_clamps_and_stores() -> void:
	var screen := LoadingScreen.new()
	add_child_autofree(screen)
	screen.set_carve_progress(1.5)
	assert_almost_eq(screen._preview._carve_progress, 1.0, 1e-4, "clamped to 1")
	screen.set_carve_progress(-0.2)
	assert_almost_eq(screen._preview._carve_progress, 0.0, 1e-4, "clamped to 0")
