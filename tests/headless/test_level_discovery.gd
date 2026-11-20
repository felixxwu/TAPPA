extends GutTest
# LevelDiscovery (scripts/level_discovery.gd): the level map's "where have I driven" grid, with no scene.


func test_stamp_shows_only_near_the_spot() -> void:
	var d := LevelDiscovery.new(1000.0, 10.0)
	assert_eq(d.shown(Vector2(100, -50)), 0.0, "nothing is shown before driving")
	assert_true(d.stamp(Vector2(100, -50), 200.0, 40.0), "a first stamp shows something new")
	assert_eq(d.shown(Vector2(100, -50)), 1.0, "the spot itself is fully shown")
	assert_eq(d.shown(Vector2(100, -50 + 140)), 1.0, "inside the radius, short of the feather, is fully shown")
	var edge := d.shown(Vector2(100 + 185, -50))
	assert_true(edge > 0.0 and edge < 1.0, "the feather fades out toward the radius")
	assert_eq(d.shown(Vector2(100 + 260, -50)), 0.0, "past the radius stays hidden")
	assert_eq(d.shown(Vector2(-400, 400)), 0.0, "far away stays hidden")
	assert_eq(d.shown(Vector2(5000, 0)), 0.0, "outside the level is hidden")


func test_restamping_the_same_spot_changes_nothing() -> void:
	var d := LevelDiscovery.new(600.0, 10.0)
	d.stamp(Vector2.ZERO, 100.0, 20.0)
	d.changed = false
	assert_false(d.stamp(Vector2.ZERO, 100.0, 20.0), "nothing new to show")
	assert_false(d.changed)
	assert_false(d.stamp(Vector2.ZERO, 50.0, 20.0), "a smaller stamp never hides what was shown")
	assert_eq(d.shown(Vector2(70, 0)), 1.0)


func test_stamp_near_the_edge_stays_in_the_grid() -> void:
	var d := LevelDiscovery.new(600.0, 10.0)
	d.stamp(Vector2(299, 299), 150.0, 30.0)
	d.stamp(Vector2(-400, 0), 150.0, 30.0)  # off the level entirely, but its disc reaches in
	assert_eq(d.shown(Vector2(295, 295)), 1.0)
	assert_eq(d.shown(Vector2(-295, 0)), 1.0)


func test_fog_image_is_clear_where_shown_and_follows_later_stamps() -> void:
	var d := LevelDiscovery.new(600.0, 10.0)
	d.stamp(Vector2.ZERO, 100.0, 20.0)
	var img := d.fog_image(Color.BLACK)
	assert_eq(img.get_size(), Vector2i(d.cells, d.cells))
	assert_eq(img.get_pixel(d.cells / 2, d.cells / 2).a, 0.0, "clear over the stamped spot")
	assert_eq(img.get_pixel(0, 0).a, 1.0, "opaque fog elsewhere")
	d.stamp(Vector2(-295, -295), 50.0, 10.0)  # the north-west corner: row 0, column 0
	assert_eq(d.fog_image(Color.BLACK).get_pixel(0, 0).a, 0.0, "a stamp after the first image clears it too")


func test_save_round_trip_and_mismatches() -> void:
	var d := LevelDiscovery.new(600.0, 10.0)
	d.stamp(Vector2(50, 50), 80.0, 20.0)
	var saved := d.to_save("res://a.json")
	var back := LevelDiscovery.new(600.0, 10.0)
	assert_true(back.load_save(saved, "res://a.json"))
	assert_eq(back.grid, d.grid, "the grid comes back as it was")
	var other := LevelDiscovery.new(600.0, 10.0)
	assert_false(other.load_save(saved, "res://b.json"), "another level's discovery is ignored")
	assert_false(LevelDiscovery.new(600.0, 20.0).load_save(saved, "res://a.json"), "a different cell size is ignored")
	assert_false(LevelDiscovery.new(800.0, 10.0).load_save(saved, "res://a.json"), "a different level size is ignored")
	assert_false(other.load_save(null, "res://a.json"))
	assert_eq(other.shown(Vector2(50, 50)), 0.0, "a refused save leaves the grid empty")
