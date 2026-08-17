extends GutTest
# GameConfig.exhaust_locals_for: the ONE place that resolves a car spec to its exhaust
# pipe placements — position plus yaw (features/exhaust-flames.md) — shared by car.gd and
# ExhaustFlames.
#
# Every spec here is SYNTHETIC — the resolution reads only `id` and `wheelbase`, so a
# hand-built dict is the honest input, and nothing here depends on the shipped roster or
# on any authored offset. Also covers the exhaust lab's camera clamp.


var _cfg: GameConfig


func before_each() -> void:
	Config.reset()
	_cfg = Config.data
	_cfg.exhaust_offsets = {}
	_cfg.exhaust_offset_fallback = Vector3(0.4, 0.3, 0.0)


func after_each() -> void:
	Config.reset()


func test_an_authored_entry_is_returned_verbatim() -> void:
	var pipes := PackedVector4Array([Vector4(0.5, 0.2, 1.8, 15.0), Vector4(-0.5, 0.2, 1.8, -15.0)])
	_cfg.exhaust_offsets = {"synth": [pipes[0], pipes[1]]}
	assert_eq(_cfg.exhaust_locals_for({"id": "synth", "wheelbase": 2.5}), pipes,
		"an authored entry should be used exactly as written, yaw included")


# --- Yaw -----------------------------------------------------------------------
#
# A pipe may be authored as a Vector3 (position only) or a Vector4 (position + yaw in
# degrees). Both must work, and mixing them in one list must work — otherwise angling a
# single pipe would force every other car's entry to be rewritten.


func test_a_vector3_pipe_defaults_to_pointing_straight_back() -> void:
	_cfg.exhaust_offsets = {"synth": [Vector3(0.5, 0.2, 1.8)]}
	var pipes := _cfg.exhaust_locals_for({"id": "synth", "wheelbase": 2.5})
	assert_eq(pipes[0], Vector4(0.5, 0.2, 1.8, 0.0),
		"a position-only pipe keeps its position and takes yaw 0")


func test_a_vector4_pipe_keeps_its_yaw() -> void:
	_cfg.exhaust_offsets = {"synth": [Vector4(0.5, 0.2, 1.8, 25.0)]}
	assert_almost_eq(_cfg.exhaust_locals_for({"id": "synth", "wheelbase": 2.5})[0].w,
		25.0, 0.0001, "an authored yaw must survive resolution")


func test_vector3_and_vector4_pipes_can_be_mixed_in_one_car() -> void:
	_cfg.exhaust_offsets = {"synth": [Vector3(0.5, 0.2, 1.8), Vector4(-0.5, 0.2, 1.8, -30.0)]}
	var pipes := _cfg.exhaust_locals_for({"id": "synth", "wheelbase": 2.5})
	assert_eq(pipes.size(), 2, "both forms count as pipes")
	assert_almost_eq(pipes[0].w, 0.0, 0.0001, "the position-only one is straight back")
	assert_almost_eq(pipes[1].w, -30.0, 0.0001, "the angled one keeps its angle")


func test_the_fallback_points_straight_back() -> void:
	var pipes := _cfg.exhaust_locals_for({"wheelbase": 2.5})
	for p in pipes:
		assert_almost_eq(p.w, 0.0, 0.0001,
			"an un-dialled-in car has no reason to prefer any angle")


# A single-exit car is a real case, not a degenerate one — the list length IS the pipe count.
func test_a_single_pipe_entry_stays_a_single_pipe() -> void:
	_cfg.exhaust_offsets = {"synth": [Vector3(0.0, 0.25, 1.9)]}
	assert_eq(_cfg.exhaust_locals_for({"id": "synth", "wheelbase": 2.5}).size(), 1,
		"a one-pipe car should not be padded out to a pair")


func test_a_quad_exit_entry_keeps_all_four() -> void:
	_cfg.exhaust_offsets = {"synth": [
		Vector3(0.5, 0.2, 1.8), Vector3(0.3, 0.2, 1.8),
		Vector3(-0.3, 0.2, 1.8), Vector3(-0.5, 0.2, 1.8)]}
	assert_eq(_cfg.exhaust_locals_for({"id": "synth", "wheelbase": 2.5}).size(), 4)


# --- The fallback ------------------------------------------------------------


func test_an_unlisted_car_falls_back_to_a_mirrored_pair() -> void:
	var pipes := _cfg.exhaust_locals_for({"id": "nobody", "wheelbase": 2.5})
	assert_eq(pipes.size(), 2, "the fallback is a twin exit")
	assert_almost_eq(pipes[0].x, -pipes[1].x, 0.0001, "mirrored across the centreline")
	assert_almost_eq(pipes[0].y, pipes[1].y, 0.0001, "at the same height")
	assert_almost_eq(pipes[0].z, pipes[1].z, 0.0001, "at the same point down the car")


# A NEGATIVE authored X must still produce one pipe each side rather than two on the
# same side — the fallback mirrors a magnitude, it doesn't copy a sign.
func test_the_fallback_mirrors_regardless_of_the_configured_sign() -> void:
	_cfg.exhaust_offset_fallback = Vector3(-0.4, 0.3, 0.0)
	var pipes: PackedVector4Array = _cfg.exhaust_locals_for({"wheelbase": 2.5})
	assert_ne(signf(pipes[0].x), signf(pipes[1].x), "one pipe each side of the car")


# The point of deriving Z from the wheelbase: a longer car's pipes sit further back, so
# the fallback lands near the tail of any car instead of at a fixed distance that would
# be wrong for most of them. +Z is rearward.
func test_the_fallback_sits_further_back_on_a_longer_car() -> void:
	var short_car := _cfg.exhaust_locals_for({"wheelbase": 2.0})
	var long_car := _cfg.exhaust_locals_for({"wheelbase": 3.2})
	assert_gt(long_car[0].z, short_car[0].z, "a longer car's tail is further rearward")
	assert_gt(short_car[0].z, 0.0, "the fallback is behind the car origin, not in front")


func test_an_empty_authored_list_falls_back_rather_than_going_dark() -> void:
	_cfg.exhaust_offsets = {"synth": []}
	assert_eq(_cfg.exhaust_locals_for({"id": "synth", "wheelbase": 2.5}).size(), 2,
		"an empty list should fall back, not leave the car with no pipes")


# A hand-edited config resource is exactly where a wrong type will come from, and the
# result of dropping the whole entry is a car that silently never flames.
func test_a_malformed_entry_falls_back() -> void:
	_cfg.exhaust_offsets = {"synth": "not a list"}
	assert_eq(_cfg.exhaust_locals_for({"id": "synth", "wheelbase": 2.5}).size(), 2)
	_cfg.exhaust_offsets = {"synth": [1.0, "nope"]}
	assert_eq(_cfg.exhaust_locals_for({"id": "synth", "wheelbase": 2.5}).size(), 2,
		"a list with no Vector3 in it is as good as no list")


func test_a_partly_malformed_entry_keeps_the_valid_pipes() -> void:
	_cfg.exhaust_offsets = {"synth": [Vector3(0.5, 0.2, 1.8), "junk"]}
	var pipes := _cfg.exhaust_locals_for({"id": "synth", "wheelbase": 2.5})
	assert_eq(pipes.size(), 1, "the junk is dropped")
	assert_eq(pipes[0], Vector4(0.5, 0.2, 1.8, 0.0), "the real pipe survives")


func test_a_spec_with_no_id_falls_back() -> void:
	_cfg.exhaust_offsets = {"synth": [Vector3(0.5, 0.2, 1.8)]}
	assert_eq(_cfg.exhaust_locals_for({"wheelbase": 2.5}).size(), 2,
		"an id-less spec must not accidentally match an authored entry")


# --- Exhaust lab camera ------------------------------------------------------


# The orbit must never pass over the pole: past vertical the look_at up-vector degenerates
# and the view flips, which is exactly the moment you lose track of which pipe you're aiming at.
func test_orbit_clamps_the_pitch_at_both_ends() -> void:
	var up := ExhaustLab.orbit_from(0.0, 0.0, Vector2(0.0, 100000.0))
	var down := ExhaustLab.orbit_from(0.0, 0.0, Vector2(0.0, -100000.0))
	assert_lt(up.y, PI * 0.5, "cannot orbit over the top")
	assert_gt(down.y, -PI * 0.5, "cannot orbit under the bottom")
	assert_gt(up.y, down.y, "the two clamps are on opposite sides")


func test_orbit_yaw_is_unclamped_so_the_car_can_be_spun_freely() -> void:
	var a := ExhaustLab.orbit_from(0.0, 0.0, Vector2(500.0, 0.0))
	var b := ExhaustLab.orbit_from(0.0, 0.0, Vector2(-500.0, 0.0))
	assert_ne(a.x, b.x, "dragging opposite ways yaws opposite ways")
	assert_almost_eq(a.x, -b.x, 0.0001, "and symmetrically")
