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




# --- ragdoll body pooling -----------------------------------------------------
# Building a RigidBody3D + capsule shape + mesh instance used to happen on the frame of
# the hit (and several members can be knocked on one tick). The bodies are now pre-built
# during setup() — behind the loading screen — and recycled, so a knock costs no
# construction. These tests pin the LOGIC (reuse, fallback, inertness, unchanged knock
# behaviour), never the pool size, which is a GameConfig tunable.

func _group_with_pool(pool_size: int, car: FakeCar, members: PackedVector2Array) -> SpectatorGroup:
	var p := _params()
	p["ragdoll_pool_size"] = pool_size
	p["despawn_behind_m"] = 20.0
	var group := SpectatorGroup.new()
	add_child_autofree(group)
	group.setup(members, car, null, {}, {}, p)
	return group


func test_knock_reuses_a_prebuilt_body_instead_of_constructing_one() -> void:
	Config.reset()
	var car := _car()
	var group := _group_with_pool(2, car, PackedVector2Array([Vector2(0.5, 0.0)]))
	var built_at_load := group.ragdolls_built()
	assert_gt(built_at_load, 0, "the pool is built up front, at setup")
	assert_eq(group.pooled_ragdoll_count(), built_at_load, "and all of it starts free")

	group._physics_process(1.0 / 60.0)

	assert_eq(group.ragdoll_count(), 1, "the member is now a live ragdoll")
	assert_eq(group.ragdolls_built(), built_at_load,
		"the knock built no new body — it took one from the pool")
	assert_eq(group.pooled_ragdoll_count(), built_at_load - 1, "one body left the pool")


func test_a_pooled_body_is_inert_and_a_knocked_one_is_live() -> void:
	Config.reset()
	var car := _car()
	# Two members, one far away so it stays upright and its body stays pooled.
	var group := _group_with_pool(2, car, PackedVector2Array([Vector2(0.5, 0.0)]))
	for body: RigidBody3D in group._ragdoll_pool:
		assert_true(body.freeze, "a pooled body doesn't simulate")
		assert_eq(body.collision_layer, 0, "and sits on no collision layer")
		assert_eq(body.collision_mask, 0, "and collides with nothing")
		assert_false(body.visible, "and isn't drawn")

	group._physics_process(1.0 / 60.0)
	var live: RigidBody3D = group._ragdolls[0]
	assert_false(live.freeze, "a knocked body simulates")
	assert_eq(live.collision_layer, int(group._p["ragdoll_layer"]), "on the ragdoll layer")
	assert_eq(live.collision_mask, int(group._p["ragdoll_mask"]), "with the ragdoll mask")
	assert_true(live.visible, "and is drawn")
	assert_gt(live.linear_velocity.length(), 0.0, "and was launched by the knock")


func test_knocked_body_starts_upright_not_mid_tumble() -> void:
	# A recycled body may come back from the pool with an arbitrary rotation; the knock
	# must reset the pose so the spectator topples FROM standing, as a fresh body did.
	Config.reset()
	var car := _car()
	var group := _group_with_pool(1, car, PackedVector2Array([Vector2(0.5, 0.0)]))
	group._ragdoll_pool[0].rotation = Vector3(1.2, 0.4, -0.9)  # a body that tumbled earlier

	group._physics_process(1.0 / 60.0)

	var live: RigidBody3D = group._ragdolls[0]
	assert_almost_eq(live.global_transform.basis.get_euler().length(), 0.0, 1e-4,
		"the knocked ragdoll starts standing upright")


func test_a_retired_ragdoll_goes_back_to_the_pool_inert() -> void:
	Config.reset()
	var car := _car()
	var group := _group_with_pool(1, car, PackedVector2Array([Vector2(0.5, 0.0)]))
	var built_at_load := group.ragdolls_built()
	group._physics_process(1.0 / 60.0)
	assert_eq(group.ragdoll_count(), 1, "knocked")
	assert_eq(group.pooled_ragdoll_count(), 0, "pool drained by the knock")

	# Drive the car far past the ragdoll so it ages out (despawn_behind_m).
	car.global_position = Vector3(0.0, 0.0, -200.0)
	group._physics_process(1.0 / 60.0)

	assert_eq(group.ragdoll_count(), 0, "the settled ragdoll is retired, as before")
	assert_eq(group.pooled_ragdoll_count(), 1, "recycled back into the pool")
	assert_eq(group.ragdolls_built(), built_at_load, "no extra body was ever constructed")
	var body: RigidBody3D = group._ragdoll_pool[0]
	assert_true(is_instance_valid(body), "the recycled body is kept alive for the next knock")
	assert_true(body.freeze, "and is parked inert")
	assert_eq(body.collision_layer, 0, "off every collision layer again")
	assert_almost_eq(body.linear_velocity.length(), 0.0, 1e-6, "with no residual velocity")


func test_an_exhausted_pool_still_knocks_the_member_over() -> void:
	# The pool bounds only the PREBUILT set — with none available a knock must still
	# produce a ragdoll (built on the spot), exactly as it did before pooling.
	Config.reset()
	var car := _car()
	var group := _group_with_pool(0, car, PackedVector2Array([Vector2(0.5, 0.0)]))
	assert_eq(group.pooled_ragdoll_count(), 0, "nothing prebuilt")

	group._physics_process(1.0 / 60.0)

	assert_eq(group.upright_count(), 0, "the member is still knocked over")
	assert_eq(group.ragdoll_count(), 1, "and is a live ragdoll")
	assert_eq(car.soft_drag_calls, 1, "and still drags the car")
