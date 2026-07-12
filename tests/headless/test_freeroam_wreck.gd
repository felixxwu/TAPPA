extends "res://tests/headless/sim_test.gd"

# In free-roam (an UNBOUND damage model, instance_id < 0) there is no DNF flow,
# so reaching 0 HP must still emit wrecked(), heal the car back to full, and drop
# it at the spawn so play continues (car.gd._on_wrecked). Guards the car-level
# wreck->heal->reset path on top of the model-level wreck tests in
# test_damage_model.gd.
func test_freeroam_wreck_heals_and_resets_to_spawn() -> void:
	await setup_settled_car()
	var car := _car
	var dmg: DamageModel = car.damage
	assert_not_null(dmg, "car has a damage model")
	assert_lt(dmg.instance_id, 0, "free-roam car is unbound")

	var wrecks := {"n": 0}
	car.wrecked.connect(func() -> void: wrecks["n"] += 1)

	# Move the car far from spawn so a reset back to the start is observable.
	var away := car.global_transform
	away.origin += Vector3(500, 0, 500)
	car.global_transform = away
	var moved_pos := car.global_position

	# Drain the remaining HP to zero.
	dmg.apply_loss(dmg.hp)

	assert_eq(wrecks["n"], 1, "wrecked emitted once at 0 HP")
	assert_eq(dmg.hp, dmg.max_hp, "free-roam car healed to full")
	assert_gt(car.global_position.distance_to(moved_pos), 400.0,
		"car reset back to spawn, away from where it wrecked")
