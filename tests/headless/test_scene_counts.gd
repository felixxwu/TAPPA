extends GutTest
# SceneCounts.match_items, the 1 cm matcher the scene counts golden is checked with (features/benchmark.md).


func _items() -> Array:
	return [["tree:oak", 10.0, 2.0, 30.0], ["bush", -4.5, 0.0, 7.25], ["fence", 100.0, 1.5, -20.0]]


func _shifted(items: Array, dx: float) -> Array:
	var out := []
	for it: Array in items:
		out.append([it[0], it[1] + dx, it[2], it[3]])
	return out


func _matches(a: Array, b: Array) -> bool:
	var diff := SceneCounts.match_items(a, b, 0.01)
	return diff.only_a.is_empty() and diff.only_b.is_empty()


func test_equal_lists_match() -> void:
	assert_true(_matches(_items(), _items()))


func test_shift_under_a_centimetre_matches() -> void:
	assert_true(_matches(_items(), _shifted(_items(), 0.009)))


func test_shift_over_a_centimetre_is_reported_on_both_sides() -> void:
	var diff := SceneCounts.match_items(_items(), _shifted(_items(), 0.011), 0.01)
	assert_eq(diff.only_a.size(), 3)
	assert_eq(diff.only_b.size(), 3)


func test_type_swap_does_not_match() -> void:
	var b := _items()
	b[0] = ["tree:pine", 10.0, 2.0, 30.0]
	var diff := SceneCounts.match_items(_items(), b, 0.01)
	assert_eq(diff.only_a, [_items()[0]])
	assert_eq(diff.only_b, [b[0]])


func test_extra_item_is_reported() -> void:
	var b := _items()
	b.append(["spectator", 1.0, 0.0, 1.0])
	var diff := SceneCounts.match_items(_items(), b, 0.01)
	assert_true(diff.only_a.is_empty())
	assert_eq(diff.only_b, [["spectator", 1.0, 0.0, 1.0]])


func test_order_does_not_matter() -> void:
	var b := _items()
	b.reverse()
	assert_true(_matches(_items(), b))


func test_items_either_side_of_a_centimetre_boundary_match() -> void:
	assert_true(_matches([["bush", 0.0099, 0.0, 0.0]], [["bush", 0.0101, 0.0, 0.0]]))
	assert_true(_matches([["bush", -0.0001, 0.0, 0.0]], [["bush", 0.0001, 0.0, 0.0]]))


func test_duplicates_pair_one_to_one() -> void:
	var a := [["bush", 1.0, 0.0, 1.0], ["bush", 1.0, 0.0, 1.0]]
	var diff := SceneCounts.match_items(a, [["bush", 1.0, 0.0, 1.0]], 0.01)
	assert_eq(diff.only_a.size(), 1)
	assert_true(diff.only_b.is_empty())
