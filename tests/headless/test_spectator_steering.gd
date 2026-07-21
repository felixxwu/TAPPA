extends GutTest
# SpectatorGroup steering forces (pure statics): separation, flee, road-avoid,
# obstacle-avoid, anchor-return, and the speed clamp. Tested directly without a
# scene — the functions take plain arrays/dicts and return XZ Vector2s.


const CELL := 0.5  # SpectatorGroup.CELL_M


# --- separation ---------------------------------------------------------------

func test_separation_pushes_away_from_a_close_neighbour() -> void:
	var pos := PackedVector2Array([Vector2(0, 0), Vector2(0.3, 0)])
	var up := PackedByteArray([1, 1])
	var f := SpectatorGroup.separation_force(0, pos, up, 0.5)
	assert_lt(f.x, 0.0, "agent at origin is pushed -x, away from the +x neighbour")


func test_separation_ignores_distant_and_knocked_neighbours() -> void:
	var pos := PackedVector2Array([Vector2(0, 0), Vector2(5, 0)])
	var up := PackedByteArray([1, 1])
	assert_eq(SpectatorGroup.separation_force(0, pos, up, 0.5), Vector2.ZERO,
		"neighbour beyond the radius exerts no push")
	var pos2 := PackedVector2Array([Vector2(0, 0), Vector2(0.3, 0)])
	var up2 := PackedByteArray([1, 0])  # neighbour is a ragdoll now
	assert_eq(SpectatorGroup.separation_force(0, pos2, up2, 0.5), Vector2.ZERO,
		"knocked-over neighbours don't crowd the living")


func test_binned_separation_matches_the_unbinned_scan() -> void:
	# The spatial-grid path (used per-tick to bound the O(N^2) crowd cost) must
	# compute the SAME force as the full scan — it only prunes members provably
	# beyond the radius. Spread agents so some share a cell and some don't.
	var radius := 0.6
	var pos := PackedVector2Array([
		Vector2(0, 0), Vector2(0.3, 0.1), Vector2(-0.4, 0.2),
		Vector2(5, 5), Vector2(0.2, -0.3), Vector2(-3, 4)])
	var up := PackedByteArray([1, 1, 1, 1, 0, 1])  # index 4 knocked
	var grid := SpectatorGroup.build_separation_grid(pos, up, radius)
	assert_false(grid.is_empty(), "grid bins the upright members")
	for i in pos.size():
		var full := SpectatorGroup.separation_force(i, pos, up, radius)
		var binned := SpectatorGroup.separation_force(i, pos, up, radius, grid, radius)
		assert_almost_eq(binned.x, full.x, 1e-5, "binned x matches full scan for member %d" % i)
		assert_almost_eq(binned.y, full.y, 1e-5, "binned y matches full scan for member %d" % i)


func test_separation_grid_skips_knocked_members() -> void:
	var pos := PackedVector2Array([Vector2(0, 0), Vector2(0.3, 0)])
	var up := PackedByteArray([1, 0])  # neighbour is a ragdoll
	var grid := SpectatorGroup.build_separation_grid(pos, up, 0.5)
	assert_eq(SpectatorGroup.separation_force(0, pos, up, 0.5, grid, 0.5), Vector2.ZERO,
		"a knocked neighbour exerts no push through the binned path either")


# --- flee ---------------------------------------------------------------------

func test_flee_pushes_away_from_car_within_radius() -> void:
	var f := SpectatorGroup.flee_force(Vector2(3, 0), Vector2(0, 0), 5.0)
	assert_gt(f.x, 0.0, "spectator at +x flees further +x, away from the car at origin")


func test_flee_is_zero_beyond_radius() -> void:
	assert_eq(SpectatorGroup.flee_force(Vector2(10, 0), Vector2(0, 0), 5.0), Vector2.ZERO,
		"car outside the flee radius is ignored")


func test_flee_is_stronger_closer() -> void:
	var near := SpectatorGroup.flee_force(Vector2(1, 0), Vector2(0, 0), 5.0).length()
	var far := SpectatorGroup.flee_force(Vector2(4, 0), Vector2(0, 0), 5.0).length()
	assert_gt(near, far, "the near-field push (the 'light push') dominates up close")


# --- road avoidance -----------------------------------------------------------

func test_road_force_pushes_off_the_carriageway() -> void:
	# Road on the +x side (world x in [0.5, 1.0)) should push -x.
	var road := { Vector2i(1, 0): true }
	var f := SpectatorGroup.road_force(Vector2(0, 0), road, 2.0)
	assert_lt(f.x, 0.0, "spectator is pushed away from the road on its +x side")


func test_road_force_zero_with_no_road_nearby() -> void:
	assert_eq(SpectatorGroup.road_force(Vector2(0, 0), {}, 1.0), Vector2.ZERO,
		"no road cells -> no road force")


func test_road_force_is_graded_by_distance() -> void:
	# The push fades with distance to the road: a spectator standing close to the
	# carriageway is shoved harder than one near the far edge of the probe. This
	# smooth gradient (rather than a bang-bang full/zero push at the probe edge) is
	# what lets the road push and the anchor pull meet at a single stable resting
	# point, instead of chattering across the old hard switching surface.
	var road := {}
	for cx in range(4, 40):        # road at world x >= 2.0
		road[Vector2i(cx, 0)] = true
	var probe := 4.0
	var near := SpectatorGroup.road_force(Vector2(1.5, 0), road, probe).length()  # 0.5 m off
	var far := SpectatorGroup.road_force(Vector2(-1.5, 0), road, probe).length()  # 3.5 m off
	assert_gt(near, far, "closer to the road -> stronger push")
	assert_gt(far, 0.0, "still a gentle push within probe range")
	# Beyond the probe the push has faded to nothing (no hard cliff to oscillate on).
	assert_almost_eq(SpectatorGroup.road_force(Vector2(-3.0, 0), road, probe).length(), 0.0, 1e-6,
		"a spectator a full probe-length off the road feels no push")


# --- obstacle avoidance -------------------------------------------------------

func test_obstacle_force_pushes_away_from_a_tree() -> void:
	var grid := SpectatorScatter.build_point_grid(PackedVector2Array([Vector2(0.3, 0)]), 1.0)
	var f := SpectatorGroup.obstacle_force(Vector2(0, 0), grid, 1.0, 0.5)
	assert_lt(f.x, 0.0, "pushed -x, away from the tree at +x")


# --- anchor -------------------------------------------------------------------

func test_anchor_pulls_toward_home() -> void:
	var f := SpectatorGroup.anchor_force(Vector2(0, 0), Vector2(5, 0), 1.0)
	assert_gt(f.x, 0.0, "pulled +x toward home")


func test_anchor_dead_zone() -> void:
	assert_eq(SpectatorGroup.anchor_force(Vector2(0, 0), Vector2(0.5, 0), 1.0), Vector2.ZERO,
		"within the dead zone there is no pull")


# --- speed clamp --------------------------------------------------------------

func test_clamp_speed_caps_magnitude() -> void:
	assert_almost_eq(SpectatorGroup.clamp_speed(Vector2(10, 0), 3.0).length(), 3.0, 1e-4,
		"velocity is capped at max_speed")


func test_clamp_speed_leaves_slow_vectors() -> void:
	var v := Vector2(1, 0)
	assert_eq(SpectatorGroup.clamp_speed(v, 3.0), v, "below the cap is unchanged")


# --- prioritised arbitration (combine) ----------------------------------------

func test_combine_flees_car_before_avoiding_static_obstacles() -> void:
	# Flee already saturates the speed budget, so a conflicting road/tree avoid push
	# cannot bend the path — escaping the car beats dodging static obstacles.
	var flee := Vector2(3.0, 0)      # == max_speed, pointing +x away from car
	var avoid := Vector2(0, 3.0)     # would push +z if it had any budget
	var out := SpectatorGroup.combine(flee, avoid, Vector2.ZERO, Vector2.ZERO, 3.0)
	assert_almost_eq(out.x, 3.0, 1e-3, "keeps full flee speed along +x")
	assert_almost_eq(out.y, 0.0, 1e-3, "static avoidance gets no budget while fleeing hard")


func test_combine_blends_separation_with_flee_so_a_crowd_never_collapses() -> void:
	# Separation is NOT starved by flee — the two urgent local forces blend, so a
	# fleeing crowd fans out sideways rather than piling onto one point and freezing.
	# (Flee weighted higher than separation, mirroring w_flee > w_separation.)
	var flee := Vector2(4.0, 0)      # strong flee, +x away from the car
	var sep := Vector2(0, 1.5)       # neighbour push, +z
	var out := SpectatorGroup.combine(flee, Vector2.ZERO, sep, Vector2.ZERO, 3.5)
	assert_gt(out.x, 0.0, "still fleeing the car along +x")
	assert_gt(out.y, 0.0, "separation still bends the path so the crowd spreads")
	assert_gt(out.x, out.y, "flee's larger pull keeps escape the dominant direction")
	assert_lte(out.length(), 3.5 + 1e-3, "total never exceeds max_speed")


func test_combine_uses_avoidance_when_not_fleeing() -> void:
	# No car (flee zero) -> obstacle avoidance gets the budget.
	var out := SpectatorGroup.combine(Vector2.ZERO, Vector2(0, 2.0), Vector2.ZERO, Vector2.ZERO, 3.0)
	assert_gt(out.y, 0.0, "with no car, the crowd still avoids obstacles")


func test_combine_partial_budget_blends_lower_priority() -> void:
	# A weak flee (1 of 3 budget) leaves room; avoidance fills the remainder but is
	# capped so the total never exceeds max_speed.
	var out := SpectatorGroup.combine(Vector2(1, 0), Vector2(0, 10.0), Vector2.ZERO, Vector2.ZERO, 3.0)
	assert_almost_eq(out.x, 1.0, 1e-3, "flee component preserved")
	assert_gt(out.y, 0.0, "remaining budget spent on avoidance")
	assert_lte(out.length(), 3.0 + 1e-3, "total never exceeds max_speed")


# --- settling (no on-the-spot jiggle) -----------------------------------------

class _StubCar:
	extends Node3D
	var linear_velocity := Vector3.ZERO


func test_roadside_crowd_settles_instead_of_jiggling() -> void:
	# The real jiggle: spectators line the verge, so the road push (keep off the
	# carriageway) and the anchor pull (drift home) act on them at once. With a
	# bang-bang road push the two can never balance — a member is dragged across the
	# probe-edge switching surface and shoved back, chattering between two spots
	# forever. The distance-graded road push gives a smooth gradient that meets the
	# anchor at a single resting point, so the crowd settles. We measure PATH LENGTH
	# (a jiggle racks up travel even though its net displacement is ~0).
	var car := _StubCar.new()
	add_child_autofree(car)
	car.global_position = Vector3(1000.0, 0.0, 1000.0)  # far away → nobody is fleeing

	# A straight road band, spectators scattered along both verges (the shipping path).
	var road := {}
	for cx in range(190, 221):
		for cz in range(160, 241):
			road[Vector2i(cx, cz)] = true

	var p := Config.data.spectator_params()
	p["seed"] = 1
	p["active_radius_m"] = 100000.0   # LOD gate always open
	p["sim_interval"] = 1             # steer every tick for a deterministic run
	var sep: float = p["separation_m"]
	var members := SpectatorScatter.members(
		Vector2(100, 100), Vector2(0, 1), 15.0, 11.0, 50, sep, road, {},
		p["tree_avoid_m"], 1.5, 1)
	assert_gt(members.size(), 10, "scattered a real roadside crowd")

	var group := SpectatorGroup.new()
	add_child_autofree(group)
	group.setup(members, car, null, road, {}, p)

	# Let it settle.
	for _i in 400:
		group._physics_process(1.0 / 60.0)

	# Total distance the whole crowd travels over the next second. A jiggle racks up
	# travel even with ~0 net displacement; a settled crowd barely moves.
	var prev := PackedVector2Array()
	for i in members.size():
		prev.append(group.member_position(i))
	var path := 0.0
	for _i in 60:
		group._physics_process(1.0 / 60.0)
		for i in members.size():
			var now := group.member_position(i)
			path += prev[i].distance_to(now)
			prev[i] = now
	# The unfixed (bang-bang) road force leaves the crowd churning ~9 m of travel a
	# second here; the graded push settles it to well under a metre.
	assert_lt(path, 2.0,
		"a settled roadside crowd barely moves (total path over 1s = %f m)" % path)


# --- ragdoll vertical placement -----------------------------------------------

func test_ragdoll_centre_of_mass_is_mid_body() -> void:
	# Body origin (the auto COM of a single centred capsule) sits at mid-height, so
	# the ragdoll spins about its waist, not its head.
	var ground := 5.0
	var h := 1.6
	var body_y := SpectatorGroup.ragdoll_body_y(ground, h)
	assert_almost_eq(body_y, ground + h * 0.5, 1e-4, "COM is at the figure's middle")
	assert_almost_eq(body_y - h * 0.5, ground, 1e-4, "capsule bottom rests on the ground")


func test_ragdoll_mesh_feet_align_with_ground_for_any_foot_offset() -> void:
	# Whatever the mesh's internal foot offset, its feet should land on the ground:
	# feet_world = body_y + mesh_offset_y + aabb_min_y, where aabb_min_y = -foot_offset.
	var ground := 0.0
	var h := 1.6
	for foot_offset: float in [0.0, 0.4, 0.82, 1.2]:
		var body_y := SpectatorGroup.ragdoll_body_y(ground, h)
		var mesh_y := SpectatorGroup.ragdoll_mesh_offset_y(foot_offset, h)
		var feet := body_y + mesh_y + (-foot_offset)
		assert_almost_eq(feet, ground, 1e-4,
			"mesh feet sit on the ground (foot_offset=%s)" % foot_offset)


# --- knock launch (shared by SpectatorGroup ragdolls and SignField signs) ------

func test_knock_launch_impulse_scales_with_car_speed() -> void:
	var dir := Vector3.FORWARD  # along -Z, the car's travel direction here
	# Same launch params, only the car speed differs.
	var slow := SpectatorGroup.knock_launch_velocity(dir, 1.0, 0.8, 1.0, 22.0, 0.3)
	var fast := SpectatorGroup.knock_launch_velocity(dir, 20.0, 0.8, 1.0, 22.0, 0.3)
	assert_lt(slow.length(), fast.length(), "a slower car imparts a smaller impulse")
	assert_lt(slow.y, fast.y, "the upward kick scales with car speed, not a constant")
	# The crux of the fix: a slow nudge must scatter the body along the ground, NOT
	# fling it skyward — the upward component stays below the horizontal one.
	var slow_horiz := Vector2(slow.x, slow.z).length()
	assert_lt(slow.y, slow_horiz, "a slow hit stays low (lift < horizontal launch)")
	# The upward angle is fixed (lift is a fraction of the launch), so slow and fast
	# share the same trajectory shape — only the magnitude grows.
	assert_almost_eq(slow.y / slow.length(), fast.y / fast.length(), 1e-4,
		"launch angle is constant; only the magnitude scales with speed")


func test_knock_launch_floor_keeps_a_crawl_from_doing_nothing() -> void:
	# Below the speed floor the launch clamps up to speed_min so even a near-stop topples
	# the body, but the upward bias is still only a fraction of that small launch.
	var v := SpectatorGroup.knock_launch_velocity(Vector3.FORWARD, 0.0, 0.8, 1.0, 22.0, 0.3)
	assert_almost_eq(v.length(), 1.0, 1e-4, "a dead stop still launches at the speed floor")
	assert_lt(v.y, Vector2(v.x, v.z).length(), "even the floor launch stays low, not skyward")


func test_knock_spin_scale_tapers_to_zero_at_low_speed() -> void:
	assert_almost_eq(SpectatorGroup.knock_spin_scale(0.0, 0.8, 22.0), 0.0, 1e-4,
		"a stopped car imparts no tumble spin")
	assert_eq(SpectatorGroup.knock_spin_scale(100.0, 0.8, 22.0), 1.0,
		"spin saturates at 1.0 for a fast hit")
	var mid := SpectatorGroup.knock_spin_scale(11.0, 1.0, 22.0)
	assert_almost_eq(mid, 0.5, 1e-4, "spin scales linearly with speed below saturation")
