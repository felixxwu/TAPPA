extends GutTest
# CoinField (scripts/coin_field.gd) — builds a stage's coins from a CoinLayout plan
# and runs the pickup proximity query (todo/roguelike-pivot.md decisions 13, 35, 36,
# 50). Mirrors test_sign_field.gd: a bare TerrainManager, no catalogue or generated
# track. find_pickups is pure (no scene, no physics tick needed) so the "collected
# once, not twice" contract is checked directly.

# A dynamic body standing in for the car (only global_transform is read).
class FakeCar:
	extends Node3D


func _layout(positions: Array[Vector2]) -> Array:
	var out := []
	for p in positions:
		out.append({"pos": p, "side": 1})
	return out


func _field(positions: Array[Vector2], car: Node = null) -> CoinField:
	var terrain := TerrainManager.new()
	terrain.focus_path = NodePath("")
	add_child_autofree(terrain)
	var field := CoinField.new()
	add_child_autofree(field)
	field.build(_layout(positions), terrain, car, GameConfig.new().coin_render_params())
	return field


# --- find_pickups: pure logic ----------------------------------------------------

func test_find_pickups_returns_points_within_radius() -> void:
	var points := PackedVector2Array([Vector2(0, 0), Vector2(10, 0), Vector2(0, 10)])
	var collected := PackedByteArray([0, 0, 0])
	var hits := CoinField.find_pickups(Vector2(0.5, 0.0), points, collected, 1.0)
	assert_eq(hits, [0], "only the point inside the radius is returned")


func test_find_pickups_skips_already_collected_points() -> void:
	var points := PackedVector2Array([Vector2(0, 0), Vector2(0.1, 0)])
	var collected := PackedByteArray([1, 0])
	var hits := CoinField.find_pickups(Vector2(0, 0), points, collected, 5.0)
	assert_eq(hits, [1], "index 0 is already collected and is skipped")


func test_find_pickups_returns_nothing_when_out_of_range() -> void:
	var points := PackedVector2Array([Vector2(100, 100)])
	var collected := PackedByteArray([0])
	assert_eq(CoinField.find_pickups(Vector2.ZERO, points, collected, 1.0).size(), 0)


func test_find_pickups_can_return_several_at_once() -> void:
	var points := PackedVector2Array([Vector2(0, 0), Vector2(0.2, 0), Vector2(50, 50)])
	var collected := PackedByteArray([0, 0, 0])
	var hits := CoinField.find_pickups(Vector2.ZERO, points, collected, 1.0)
	assert_eq(hits, [0, 1], "every not-yet-collected point in range comes back")


# --- build(): the scene side ------------------------------------------------------

func test_build_places_one_node_per_coin() -> void:
	var field := _field([Vector2(0, 0), Vector2(10, 0), Vector2(20, 0)])
	assert_eq(field.coin_count, 3)
	assert_eq(field.collected_count, 0)
	var meshes := field.get_children().filter(func(c): return c is MeshInstance3D)
	assert_eq(meshes.size(), 3, "one visible mesh per placed coin")


# --- pickup: the physics-tick side -------------------------------------------------

func test_driving_onto_a_coin_collects_it_once() -> void:
	Config.reset()
	Config.data.coin_pickup_radius_m = 3.0
	var car := FakeCar.new()
	add_child_autofree(car)
	car.global_position = Vector3(-100.0, 0.0, -100.0)  # nowhere near any coin
	var field := _field([Vector2(0, 0), Vector2(50, 0)], car)

	field._physics_process(0.016)
	assert_eq(field.collected_count, 0, "setup: the car starts nowhere near a coin")

	car.global_position = Vector3(0.0, 0.0, 0.0)  # drive onto the first coin
	field._physics_process(0.016)
	assert_eq(field.collected_count, 1, "the coin under the car is collected")
	assert_false(field._meshes[0].visible, "a collected coin's mesh disappears")
	assert_true(field._meshes[1].visible, "the untouched coin stays visible")

	# Sitting on the same spot must not double-collect it.
	field._physics_process(0.016)
	assert_eq(field.collected_count, 1, "a coin is collected once, not every tick it sits on it")


func test_coin_collected_signal_reports_the_running_total() -> void:
	Config.reset()
	Config.data.coin_pickup_radius_m = 3.0
	var car := FakeCar.new()
	add_child_autofree(car)
	car.global_position = Vector3(0.0, 0.0, 0.0)
	var field := _field([Vector2(0, 0), Vector2(3.0, 0.0)], car)
	var totals: Array[int] = []
	field.coin_collected.connect(func(_i: int, total: int) -> void: totals.append(total))

	field._physics_process(0.016)
	assert_eq(totals, [1, 2], "both coins in range are reported, running total each time")
	Config.reset()
