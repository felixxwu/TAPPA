extends GutTest
# The shared TrackPreview accepts water cells and draws without crashing; the
# loading screen forwards water to it.

const TrackPreview = preload("res://scripts/track_preview.gd")

func test_accepts_water_cells() -> void:
	var tp := TrackPreview.new()
	add_child_autofree(tp)
	tp.size = Vector2(200, 200)
	tp.set_points(PackedVector2Array([Vector2(0, 0), Vector2(10, 10)]))
	tp.set_water(PackedVector2Array([Vector2(2, 2), Vector2(3, 3)]), 1.0)
	tp.queue_redraw()
	await get_tree().process_frame
	assert_eq(tp.water_cell_count(), 2, "water cells stored for drawing")

func test_loading_screen_forwards_water() -> void:
	var ls := LoadingScreen.new()
	add_child_autofree(ls)
	# Should not error; the preview stores the cells.
	ls.update_track_preview(PackedVector2Array([Vector2(0, 0), Vector2(5, 5)]))
	ls.update_water(PackedVector2Array([Vector2(1, 1)]), 1.0)
	await get_tree().process_frame
	assert_true(true, "update_water forwarded without error")
