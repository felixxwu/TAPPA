extends GutTest
# LevelData.route: the sat-nav path follows the roads, through junctions, never a straight shortcut.


func _node(x: float, z: float) -> Dictionary:
	return {"x": x, "z": z, "w": 3.0, "m": null, "tension": 1.0}


func _data() -> LevelData:
	var d := LevelData.new()
	d.load_save({"size": 600, "roads": [
		[_node(-100.0, 0.0), _node(0.0, 0.0), _node(100.0, 0.0)],
		[_node(0.0, 0.4), _node(0.0, 60.0)],
		[_node(-100.0, 200.0), _node(100.0, 200.0)]]}, false)
	return d


func test_route_goes_through_the_junction() -> void:
	var from := Vector2(-100.0, 0.0)
	var to := Vector2(0.0, 60.0)
	var r := _data().route(from, to)
	assert_gt(r.size(), 2)
	assert_eq(r[0], from)
	assert_eq(r[r.size() - 1], to)
	var length := 0.0
	var near_junction := false
	for i in r.size():
		near_junction = near_junction or r[i].distance_to(Vector2.ZERO) < 3.0
		if i > 0:
			length += r[i].distance_to(r[i - 1])
	assert_true(near_junction, "turns at the junction, not a straight shortcut")
	assert_gte(length, from.distance_to(to))
	assert_gt(length, from.distance_to(to) + 20.0)


func test_unconnected_road_has_no_route() -> void:
	assert_true(_data().route(Vector2(-100.0, 0.0), Vector2(50.0, 200.0)).is_empty())


func test_the_route_marks_where_the_road_splits() -> void:
	var d := _data()
	var ids := d.route_ids(Vector2(-100.0, 0.0), Vector2(0.0, 60.0))
	var split := []
	for id in ids:
		if d.is_junction(id):
			split.append(Vector2(d.sx[id], d.sz[id]))
	assert_false(split.is_empty(), "the turn onto the side road is a junction")
	for p: Vector2 in split:
		assert_lt(p.length(), 3.0, "and only there, not along the plain road")


func test_the_arrow_shows_the_next_junction_within_reach() -> void:
	var pts := PackedVector2Array([Vector2(0, 0), Vector2(10, 0), Vector2(20, 0), Vector2(30, 0), Vector2(40, 0)])
	var junction: Array[bool] = [false, false, false, true, false]
	assert_eq(RouteArrow.next_junction(pts, junction, 0, 50.0), 3)
	assert_eq(RouteArrow.next_junction(pts, junction, 0, 25.0), -1, "too far ahead yet")
	assert_eq(RouteArrow.next_junction(pts, junction, 3, 50.0), -1, "gone once the car has passed it")
	assert_eq(RouteArrow.nearest_point(pts, Vector2(21, 3)), 2)
