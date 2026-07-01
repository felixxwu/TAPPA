extends GutTest
# Hitting a spectator costs the car HP (a bit more than a bush graze). Drives a live
# SpectatorGroup with one member sitting on top of a stub car so it knocks over on the
# first tick, and checks the car's DamageModel took the spectator soft-hit. See
# scripts/spectator_group.gd, features/damage.md.


class FakeCar:
	extends Node3D
	var damage: DamageModel
	var linear_velocity := Vector3(0, 0, -15.0)  # driving forward, fast enough to knock


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
	assert_almost_eq(car.damage.hp, 1000.0 - Config.data.spectator_hp_loss, 1e-3,
		"knocking the spectator costs the car spectator_hp_loss")


func test_spectator_hit_hurts_more_than_a_bush() -> void:
	# The design: a spectator costs a bit MORE HP than a bush graze.
	assert_gt(Config.data.spectator_hp_loss, Config.data.bush_hp_loss,
		"a spectator hit costs more than a bush graze")
