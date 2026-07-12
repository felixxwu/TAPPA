extends GutTest
# Knocking a spectator now applies a small speed-scaled DRAG IMPULSE to the car (a soft
# pass-through contact); the resulting deceleration then feeds the unified damage rule
# (car._integrate_forces / DamageModel.register_deceleration) — the group no longer
# drains HP directly. Drives a live SpectatorGroup with one member on top of a stub car
# so it knocks over on the first tick, and checks the car got the soft drag. See
# scripts/spectator_group.gd, features/damage.md.


class FakeCar:
	extends Node3D
	var damage: DamageModel
	var linear_velocity := Vector3(0, 0, -15.0)  # driving forward, fast enough to knock
	var soft_drag_calls := 0
	var last_strength := 0.0

	func apply_soft_drag(strength: float) -> void:
		soft_drag_calls += 1
		last_strength = strength
		linear_velocity *= (1.0 - clampf(strength, 0.0, 1.0))


func _car() -> FakeCar:
	var car := FakeCar.new()
	car.damage = DamageModel.new()
	car.damage.field(1000.0, 1000.0)
	add_child_autofree(car)
	return car


func _params() -> Dictionary:
	var p: Dictionary = Config.data.spectator_params()
	p["seed"] = 1
	# Make sure the LOD gate is open and the single member is within knock range.
	p["active_radius_m"] = 1000.0
	p["knock_radius_m"] = 5.0
	return p


func test_knocking_a_spectator_damages_the_car() -> void:
	Config.reset()
	var car := _car()
	var group := SpectatorGroup.new()
	add_child_autofree(group)
	# One member essentially on top of the car → knocked on the first tick.
	group.setup(PackedVector2Array([Vector2(0.5, 0.0)]), car, null, {}, {}, _params())
	assert_eq(group.upright_count(), 1, "one upright member to start")

	group._physics_process(1.0 / 60.0)

	assert_eq(group.upright_count(), 0, "the member is knocked over")
	assert_eq(car.soft_drag_calls, 1, "knocking a spectator applies soft drag to the car")
	assert_almost_eq(car.last_strength, Config.data.spectator_drag_strength, 1e-6,
		"with the configured spectator drag strength")


