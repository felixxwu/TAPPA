extends GutTest
# Docs: features/drivetrain-and-tires.md
# Tests: this file guards the GameConfig.TIRE_SURFACE_AXES registry itself.
#
# The registry is the ONE place that says which surface-dependent tyre multipliers exist
# (`tire_snow_grip_mult`, `tire_tarmac_grip_mult`, …). Everything that consumes them —
# the live physics, the rival solver, car.gd's neutral re-seed, car_performance's meta
# carry list — derives from the table instead of naming the fields, which is what makes
# adding a surface axis a one-file change.
#
# That design has exactly one new way to go wrong, and this file closes it in both
# directions:
#
#   row with no property  — the axis applies as a permanent 1.0 on every surface
#   property with no row  — the @export compiles, the part reads as fitted, and it does
#                           absolutely nothing (the round-002 silent no-op, back again)
#
# Nothing here pins an authored value: the table is iterated as opaque input and no test
# asserts which axes exist or what any multiplier is set to. Registering a new axis, or
# retuning one, keeps this file green.
#
# ROUND-006 CORRECTION. The blend-rule test below used to PROBE for inertness — it called
# the resolver on a snow stage and on full tarmac and failed the axis if neither moved.
# That silently encoded the assumption that every axis is keyed on SURFACE, so the first
# probe to register a legitimate weather axis was failed by this file for a defect it did
# not have. The rule now asks _channel_weight directly whether an arm exists (NAN means it
# does not), which is the property actually worth guarding and cannot false-fail an axis
# keyed on something new.


func _config_property_names() -> Dictionary:
	var cfg := GameConfig.new()
	var names := {}
	for prop in cfg.get_property_list():
		names[String(prop["name"])] = true
	return names


func test_every_registered_axis_names_a_real_config_property() -> void:
	var names := _config_property_names()
	for axis in GameConfig.TIRE_SURFACE_AXES:
		var field := String(axis["field"])
		assert_true(names.has(field),
			("GameConfig.TIRE_SURFACE_AXES registers '%s', which is not a GameConfig " +
			"property — that axis would resolve to a permanent 1.0 on every surface. " +
			"Add the matching @export next to the table.") % field)


func test_every_registered_axis_has_a_blend_rule() -> void:
	# An axis whose channel has no arm in _channel_weight contributes nothing on any stage
	# — inert exactly like a missing property. Asked DIRECTLY rather than inferred from
	# probing: _channel_weight returns NAN for a channel it has no rule for, which is
	# distinguishable from the 0.0 that merely means "not on that channel right now".
	# Probing cannot make that distinction, and a probing version of this test failed a
	# correct weather axis in round 006.
	var ctx := GameConfig.fill_tire_context({}, 0.0, false, RallyLibrary.WEATHER_DRY)
	for axis in GameConfig.TIRE_SURFACE_AXES:
		var channel := String(axis["channel"])
		assert_false(is_nan(GameConfig._channel_weight(channel, ctx)),
			("GameConfig.TIRE_SURFACE_AXES axis '%s' uses channel '%s', which " +
			"_channel_weight has no arm for — the axis would be inert on every stage. " +
			"Add its arm next to the table.") % [String(axis["field"]), channel])


func test_every_surface_grip_mult_property_is_registered() -> void:
	# The other direction, and the one that has actually shipped: declaring the @export
	# and stopping there. Any GameConfig property matching the surface-multiplier naming
	# convention must be in the table, or nothing will ever read it.
	var registered := {}
	for axis in GameConfig.TIRE_SURFACE_AXES:
		registered[String(axis["field"])] = true
	for name in _config_property_names():
		if not name.begins_with("tire_") or not name.ends_with("_grip_mult"):
			continue
		assert_true(registered.has(name),
			("GameConfig.%s looks like a surface-dependent tyre axis but is not in " +
			"TIRE_SURFACE_AXES, so nothing reads it — the part applies and changes " +
			"nothing. Add a row to the table (and its arm in _channel_weight).") % name)


func test_an_unfitted_car_is_an_exact_no_op() -> void:
	# The identity every consumer relies on: a car with no such compound (all axes at
	# 1.0, or a car_meta that carries none of the keys) must leave grip untouched on
	# every surface, so the mechanism costs nothing for the cars that do not use it.
	var neutral := {}
	for axis in GameConfig.TIRE_SURFACE_AXES:
		neutral[String(axis["field"])] = 1.0
	var ctx := {}
	for snowy in [true, false]:
		for w in [0.0, 0.5, 1.0]:
			GameConfig.fill_tire_context(ctx, w, snowy, RallyLibrary.WEATHER_DRY)
			assert_almost_eq(GameConfig.tire_surface_mult_for(neutral, ctx), 1.0, 1e-6,
				"all-neutral axes must be an exact no-op (snowy=%s, tarmac=%s)" % [snowy, w])
			assert_almost_eq(GameConfig.tire_surface_mult_for({}, ctx), 1.0, 1e-6,
				"a car_meta carrying no axis keys must read as the identity")


func test_a_live_config_and_a_car_meta_resolve_identically() -> void:
	# The physics passes a live GameConfig and the lap-time model passes a car_meta
	# Dictionary; the AI field diverging from the player's car is the failure this
	# shared resolver exists to prevent, so both sources must agree.
	var cfg := GameConfig.new()
	var meta := {}
	var v := 1.15
	for axis in GameConfig.TIRE_SURFACE_AXES:
		var field := String(axis["field"])
		cfg.set(field, v)
		meta[field] = v
		v += 0.1
	var ctx := {}
	for snowy in [true, false]:
		for w in [0.0, 0.35, 1.0]:
			GameConfig.fill_tire_context(ctx, w, snowy, RallyLibrary.WEATHER_DRY)
			assert_almost_eq(GameConfig.tire_surface_mult_for(cfg, ctx),
				GameConfig.tire_surface_mult_for(meta, ctx), 1e-6,
				"config and car_meta must resolve the same (snowy=%s, tarmac=%s)" % [snowy, w])


func test_the_stage_context_carries_weather_even_though_no_axis_reads_it_yet() -> void:
	# Weather is in the context deliberately, ahead of any axis needing it, so that adding
	# a wet-weather axis stays a one-file change. If someone "tidies" it away as unused,
	# the next weather-keyed axis silently becomes a three-file change again — which is
	# exactly the round-006 failure this design was corrected to prevent.
	var ctx := GameConfig.fill_tire_context({}, 0.5, false, RallyLibrary.WEATHER_RAIN)
	assert_true(ctx.has("weather"),
		"fill_tire_context must carry the stage weather so a weather-keyed axis needs no caller edit")
	assert_eq(String(ctx["weather"]), RallyLibrary.WEATHER_RAIN,
		"fill_tire_context must pass the weather through unchanged")
	assert_true(ctx.has("tarmac") and ctx.has("snowy"),
		"fill_tire_context must carry the surface context every existing channel reads")
