extends GutTest
# CoinField (scripts/coin_field.gd) — builds a stage's coins from a CoinLayout plan
# and runs the pickup proximity query (todo/roguelike-pivot.md decisions 13, 35, 36,
# 50 — decision 35 REVERSED by explicit user request, see features/collectables.md).
# Mirrors test_sign_field.gd: a bare TerrainManager, no catalogue or generated
# track. find_pickups and animate are both pure (no scene, no tick needed) so their
# contracts are checked directly.

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


# --- animate: pure spin/bob logic --------------------------------------------------

func test_animate_spins_faster_over_time() -> void:
	var early := CoinField.animate(0, 0.1, 180.0, 2.0, 0.1)
	var later := CoinField.animate(0, 1.0, 180.0, 2.0, 0.1)
	assert_gt(later["spin_rad"], early["spin_rad"], "spin angle keeps increasing with time")


func test_animate_zero_spin_rate_never_rotates() -> void:
	var a := CoinField.animate(2, 0.0, 0.0, 2.0, 0.1)
	var b := CoinField.animate(2, 5.0, 0.0, 2.0, 0.1)
	assert_eq(a["spin_rad"], b["spin_rad"], "zero deg/sec leaves the spin angle fixed")


func test_animate_bob_offset_stays_within_the_amplitude() -> void:
	var amplitude := 0.15
	for i in range(20):
		var t := float(i) * 0.37
		var anim := CoinField.animate(0, t, 180.0, 2.0, amplitude)
		assert_true(absf(anim["y_offset"]) <= amplitude + 0.001,
			"the bob never exceeds its configured amplitude")


func test_animate_zero_bob_amplitude_never_moves_vertically() -> void:
	var anim := CoinField.animate(3, 1.23, 180.0, 2.0, 0.0)
	assert_eq(anim["y_offset"], 0.0)


func test_animate_phase_offsets_different_coins() -> void:
	# Different indices must not move in lockstep — that's the whole point of the
	# per-coin phase offset (CLAUDE.md: relationship, not a pinned magnitude).
	var a := CoinField.animate(0, 1.0, 180.0, 2.0, 0.1)
	var b := CoinField.animate(1, 1.0, 180.0, 2.0, 0.1)
	assert_ne(a["spin_rad"], b["spin_rad"], "different coins spin out of phase")


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
