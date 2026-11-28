extends GutTest
# Parts and prices (features/loot.md): the parts catalogue, fitting parts through the owned-car
# funnel, weights, engine swaps and tires. The level's shop pages are tested in
# test_level_shop_specialties.gd. A synthetic car roster throughout (CarFixtures); the boost
# catalogue is iterated whole, as opaque input.

const TEST_PATH := "user://test_loot_profile.json"

var _save: Node


func before_each() -> void:
	_save = get_node("/root/Save")
	_save.profile_path = TEST_PATH
	_save.save_disabled = false
	_save.profile = _save._default_profile()
	CarFixtures.install()


func after_each() -> void:
	get_tree().paused = false
	CarFixtures.restore()
	_save.profile_path = _save.DEFAULT_PROFILE_PATH
	for suffix in ["", ".bak", ".tmp"]:
		if FileAccess.file_exists(TEST_PATH + suffix):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_PATH + suffix))


# --- parts on a car ---------------------------------------------------------------------------------

func test_switched_on_parts_reach_the_car_only_through_the_funnel_keys() -> void:
	var owned := {"model_id": String(CarLibrary.all()[0]["id"]), "instance_id": 1, "tuning": {},
		"parts": [{"kind": "part", "id": String(BoostLibrary.CATALOGUE.keys()[0]), "level": 2},
			{"kind": "part", "id": "drivetrain:%d" % Drivetrain.DriveMode.AWD}],
		"engine_from": String(CarLibrary.all()[2]["id"])}
	var f := LootRules.fielded(owned)
	var parts_only: Array = f["boosts"].filter(func(b: Dictionary) -> bool: return b["id"] != "part_weight")
	assert_eq(parts_only.size(), 1)
	assert_eq(parts_only[0]["id"], BoostLibrary.CATALOGUE.keys()[0])
	assert_eq(parts_only[0]["effect"], BoostLibrary.magnitude_for(String(BoostLibrary.CATALOGUE.keys()[0]), 2))
	assert_eq(f["swapped_engine"], CarLibrary.all()[2]["engine"])
	assert_eq(f["drivetrain_override"], Drivetrain.DriveMode.AWD)
	assert_false(owned.has("boosts"), "the saved car is untouched")
	var bare := LootRules.fielded({"model_id": "x", "parts": []})
	assert_eq(bare["boosts"], [])
	assert_false(bare.has("swapped_engine") or bare.has("drivetrain_override"))


func test_parts_switched_off_dont_reach_the_car() -> void:
	var owned := {"model_id": String(CarLibrary.all()[0]["id"]), "parts": [
		{"kind": "part", "id": "drivetrain:%d" % Drivetrain.DriveMode.AWD, "on": false}]}
	var f := LootRules.fielded(owned)
	assert_false(f.has("swapped_engine") or f.has("drivetrain_override"))


func _part_id(k: int) -> String:
	return String(BoostLibrary.CATALOGUE.keys()[k])


func test_one_of_each_part_and_no_kit_for_the_cars_own_layout() -> void:
	var owned := {"model_id": String(CarLibrary.all()[0]["id"]), "parts": [{"kind": "part", "id": _part_id(0), "level": 0}]}
	var own := UpgradeLibrary.stock_drive_mode(owned)
	assert_eq(LootRules.fit_block_reason(owned, {"kind": "part", "id": _part_id(0), "level": 3}), "Already unlocked", "one of each")
	assert_eq(LootRules.fit_block_reason(owned, {"kind": "part", "id": "drivetrain:%d" % own}),
		"Already " + CarLibrary.drive_text(own), "a kit for the car's own layout would do nothing")
	assert_true(LootRules.can_fit(owned, {"kind": "part", "id": "tire:a"}))
	assert_false(LootRules.can_fit(owned, {"kind": "car", "id": "anything"}), "a car isn't a part")


func test_a_car_could_have_every_part_but_the_ones_it_came_with() -> void:
	var owned := {"model_id": String(CarLibrary.all()[0]["id"]), "parts": [
		{"kind": "part", "id": _part_id(0), "level": 0, "on": true}, {"kind": "part", "id": _part_id(1), "level": 0, "on": false}]}
	var own := UpgradeLibrary.stock_drive_mode(owned)
	var all := LootRules.parts_for(owned)
	var keys := {}
	for item: Dictionary in all:
		assert_eq(String(item["kind"]), "part", "only parts count")
		keys[LootRules.item_key(item)] = true
	assert_false(keys.has(LootRules.item_key({"kind": "part", "id": "drivetrain:%d" % own})),
		"the kit for the car's own layout can never be fitted, so it isn't counted")
	var catalogue := 0
	for item: Dictionary in LootRules.catalogue():
		if String(item["kind"]) == "part":
			catalogue += 1
	var factory_abs := 1 if CarLibrary.has_abs(CarLibrary.for_owned(owned)) else 0
	assert_eq(all.size(), catalogue - 1 - factory_abs, "every other part in the catalogue counts")


func test_switching_a_kit_on_switches_the_other_one_off() -> void:
	var parts := [{"kind": "part", "id": "drivetrain:0", "on": true}, {"kind": "part", "id": "drivetrain:1", "on": false},
		{"kind": "part", "id": "grip", "level": 0, "on": true}]
	var on_b := LootRules.toggled(parts, 1)
	assert_eq(on_b.map(func(p: Dictionary) -> bool: return LootRules.is_on(p)), [false, true, true],
		"one kit at a time; other parts are left alone")
	assert_eq(LootRules.toggled(on_b, 1).map(func(p: Dictionary) -> bool: return LootRules.is_on(p)), [false, false, true],
		"switching it off again leaves the stock layout")
	assert_true(LootRules.is_on(parts[0]), "the input is untouched")


func test_abs_is_for_sale_only_to_a_car_without_it() -> void:
	var with_abs := {"abs": true, "id": "fx_abs"}
	var without_abs := {"abs": false, "id": "fx_no_abs"}
	var roster: Array[Dictionary] = [with_abs, without_abs]
	CarLibrary.override_for_test(roster)
	var part := {"kind": "part", "id": "abs", "level": 1}
	assert_eq(LootRules.fit_block_reason({"model_id": "fx_abs"}, part), "Already has ABS")
	assert_true(LootRules.can_fit({"model_id": "fx_no_abs"}, part))
	var ids := func(owned: Dictionary) -> Array:
		return LootRules.parts_for(owned).map(func(i: Dictionary) -> String: return String(i["id"]))
	assert_does_not_have(ids.call({"model_id": "fx_abs"}), "abs", "not counted as an upgrade it could have")
	assert_has(ids.call({"model_id": "fx_no_abs"}), "abs")
	CarLibrary.reset()


func test_the_abs_part_switches_abs_on_through_the_funnel() -> void:
	var cfg := GameConfig.new()
	cfg.abs_enabled = false
	var off := {"model_id": "fx", "parts": [{"kind": "part", "id": "abs", "level": 1, "on": false}]}
	UpgradeLibrary.apply(LootRules.fielded(off), cfg)
	assert_false(cfg.abs_enabled, "switched off, it does nothing")
	var on := {"model_id": "fx", "parts": [{"kind": "part", "id": "abs", "level": 1, "on": true}]}
	UpgradeLibrary.apply(LootRules.fielded(on), cfg)
	assert_true(cfg.abs_enabled)


# Two parts writing the same install_turbo fields would silently overwrite each other if both were on.
func test_only_one_turbo_is_on_at_once() -> void:
	var parts := []
	for id: String in BoostLibrary.CATALOGUE:
		if (BoostLibrary.CATALOGUE[id]["effect_fields"] as Dictionary).has("install_turbo"):
			parts.append({"kind": "part", "id": id, "on": false})
	for i in parts.size():
		var on := LootRules.toggled(parts, i).map(LootRules.is_on)
		assert_eq(on.count(true), 1, "switching on %s leaves only it on" % parts[i]["id"])
		assert_true(on[i])


# Every part names its weight, so a new one can't quietly weigh nothing. Weight savers and engines
# (whose own mass is swapped in) are the exceptions.
func test_every_part_names_its_weight() -> void:
	for id: String in BoostLibrary.CATALOGUE:
		if not (BoostLibrary.CATALOGUE[id]["effect_fields"] as Dictionary).has("mass_mult"):
			assert_true(BoostLibrary.CATALOGUE[id].has("mass_kg"), id)
	for mode in LootRules.KITS:
		assert_true(LootRules.KITS[mode].has("mass_kg"), "kit %d" % mode)
	for id: String in LootRules.TIRES:
		assert_true(LootRules.TIRES[id].has("mass_kg"), id)


func test_a_switched_on_part_adds_its_weight() -> void:
	var car := {"model_id": String(CarLibrary.all()[0]["id"]), "instance_id": 1}
	var stock := float(LootRules.fitted_stats(car)["mass"])
	for id: String in BoostLibrary.CATALOGUE:
		if not BoostLibrary.CATALOGUE[id].has("mass_kg"):
			continue
		car["parts"] = [{"kind": "part", "id": id, "on": true}]
		assert_almost_eq(float(LootRules.fitted_stats(car)["mass"]), stock + float(BoostLibrary.CATALOGUE[id]["mass_kg"]), 0.01, id)
		car["parts"][0]["on"] = false
		assert_almost_eq(float(LootRules.fitted_stats(car)["mass"]), stock, 0.01, "%s off weighs nothing" % id)


func test_a_drivetrain_kit_adds_the_difference_from_the_stock_layout() -> void:
	var car := {"model_id": String(CarLibrary.all()[0]["id"]), "instance_id": 1}
	var stock := float(LootRules.fitted_stats(car)["mass"])
	var stock_kit := float(LootRules.KITS[UpgradeLibrary.stock_drive_mode(car)]["mass_kg"])
	for mode in LootRules.KITS:
		car["parts"] = [{"kind": "part", "id": "drivetrain:%d" % mode, "on": true}]
		assert_almost_eq(float(LootRules.fitted_stats(car)["mass"]), stock + float(LootRules.KITS[mode]["mass_kg"]) - stock_kit, 0.01, "kit %d" % mode)


func test_the_weight_doesnt_depend_on_the_order_parts_were_bought() -> void:
	var saver := ""
	var heavy := ""
	for id: String in BoostLibrary.CATALOGUE:
		if (BoostLibrary.CATALOGUE[id]["effect_fields"] as Dictionary).has("mass_mult"):
			saver = id
		elif BoostLibrary.CATALOGUE[id].has("mass_kg"):
			heavy = id
	var parts := [{"kind": "part", "id": saver, "on": true}, {"kind": "part", "id": heavy, "on": true}]
	var model := String(CarLibrary.all()[0]["id"])
	var one_way := float(LootRules.fitted_stats({"model_id": model, "parts": parts})["mass"])
	parts.reverse()
	assert_almost_eq(float(LootRules.fitted_stats({"model_id": model, "parts": parts})["mass"]), one_way, 0.01)


# Power shows what the engine makes at full boost, stock turbo included, since peak_torque is before boost.
func test_stock_power_counts_the_engines_own_boost() -> void:
	for spec: Dictionary in CarLibrary.all():
		var cfg := GameConfig.new()
		EngineLibrary.apply(EngineLibrary.by_id(String(spec["engine"])), cfg)
		var boosted := CarLibrary.horsepower(spec) * LootRules._full_boost_factor(cfg)
		assert_almost_eq(float(LootRules.fitted_stats({"model_id": spec["id"]})["hp"]), boosted, 0.01, String(spec["id"]))


# The shop header and garage cards read what the fitted parts actually do to the car.
func test_fitted_stats_follow_the_parts_switched_on() -> void:
	var car := {"model_id": String(CarLibrary.all()[0]["id"]), "instance_id": 1}
	var stock := LootRules.fitted_stats(car)
	assert_almost_eq(float(stock["mass"]), float(CarLibrary.all()[0]["mass"]), 0.01, "no parts: the car's own weight")
	var ids := {"mass_mult": "", "install_turbo": "", "max_hp_mult": ""}
	for id: String in BoostLibrary.CATALOGUE:
		for key: String in ids:
			if (BoostLibrary.CATALOGUE[id]["effect_fields"] as Dictionary).has(key):
				ids[key] = id
	car["parts"] = [{"kind": "part", "id": ids["mass_mult"], "on": true}]
	assert_lt(float(LootRules.fitted_stats(car)["mass"]), float(stock["mass"]), "a weight part makes it lighter")
	car["parts"][0]["on"] = false
	assert_almost_eq(float(LootRules.fitted_stats(car)["mass"]), float(stock["mass"]), 0.01, "switched off, it doesn't count")
	car["parts"] = [{"kind": "part", "id": ids["install_turbo"], "on": true}]
	assert_ne(float(LootRules.fitted_stats(car)["hp"]), float(stock["hp"]), "a turbo changes the power")
	assert_almost_eq(float(stock["max_hp"]), float(CarLibrary.all()[0]["max_hp"]), 0.01, "no parts: the car's own health")
	car["parts"] = [{"kind": "part", "id": ids["max_hp_mult"], "on": true}]
	assert_gt(float(LootRules.fitted_stats(car)["max_hp"]), float(stock["max_hp"]), "a roll cage adds health")
	var other := (UpgradeLibrary.stock_drive_mode(car) + 1) % Drivetrain.DriveMode.size()
	car["parts"] = [{"kind": "part", "id": "drivetrain:%d" % other, "on": true}]
	assert_eq(int(LootRules.fitted_stats(car)["drive_mode"]), other, "a kit changes the driven wheels")


# --- engine swaps --------------------------------------------------------------------------------

func test_a_cars_weight_and_power_follow_its_swapped_engine() -> void:
	var a := {"model_id": String(CarLibrary.all()[0]["id"]), "engine_from": String(CarLibrary.all()[2]["id"])}
	var donor_engine := String(CarLibrary.all()[2]["engine"])
	var own_engine := String(CarLibrary.all()[0]["engine"])
	var stats := LootRules.fitted_stats(a)
	assert_almost_eq(float(stats["hp"]), CarLibrary.horsepower({"engine": donor_engine}), 0.01)
	assert_almost_eq(float(stats["mass"]), EngineSwap.recompute_mass(float(CarLibrary.all()[0]["mass"]),
		float(EngineLibrary.by_id(own_engine)["mass"]), float(EngineLibrary.by_id(donor_engine)["mass"])), 0.01)


func test_an_old_saves_bought_engine_does_nothing() -> void:
	var owned := {"model_id": String(CarLibrary.all()[0]["id"]), "parts": [{"kind": "part", "id": "engine_swap:old", "on": true}]}
	assert_false(LootRules.fielded(owned).has("swapped_engine"))


# --- tires ---------------------------------------------------------------------------------------

func test_only_one_tire_is_on_at_once_and_other_parts_are_left_alone() -> void:
	var parts := [{"kind": "part", "id": "tire:a", "on": true}, {"kind": "part", "id": "tire:b", "on": false},
		{"kind": "part", "id": "engine_swap:e", "on": true}]
	var on_b := LootRules.toggled(parts, 1)
	assert_eq(on_b.map(LootRules.is_on), [false, true, true])
	assert_eq(LootRules.on_stock_tires(on_b).map(LootRules.is_on), [false, false, true], "stock switches off tires only")


func test_a_fitted_tire_reaches_the_config_through_the_funnel() -> void:
	for id: String in LootRules.TIRES:
		var part := {"kind": "part", "id": "tire:" + id, "on": true}
		var fielded := LootRules.fielded({"parts": [part]})
		assert_true((fielded["boosts"] as Array).any(func(b: Dictionary) -> bool: return b["id"] == "tire:" + id), "%s is a boost on the fielded car" % id)
		var cfg := GameConfig.new()
		cfg.wheel_friction_slip_front = 1.0
		cfg.wheel_friction_slip_rear = 1.0
		UpgradeLibrary.apply(fielded, cfg)
		var fields: Dictionary = LootRules.TIRES[id]["effect_fields"]
		assert_almost_eq(cfg.wheel_friction_slip_front, float(Config.data.get(fields["tire_grip_mult"])), 1e-5, "%s flat" % id)
		assert_almost_eq(cfg.tire_tarmac_grip_mult, float(Config.data.get(fields["tire_tarmac_grip_mult"])), 1e-5, "%s tarmac" % id)
		assert_almost_eq(cfg.tire_snow_grip_mult, float(Config.data.get(fields["tire_snow_grip_mult"])), 1e-5, "%s snow" % id)
		part["on"] = false
		assert_true((LootRules.fielded({"parts": [part]})["boosts"] as Array).is_empty(), "%s off is stock" % id)


func test_tires_fit_every_car_once() -> void:
	var tire := {"kind": "part", "id": "tire:x"}
	assert_true(LootRules.can_fit({"model_id": "fx"}, tire))
	assert_false(LootRules.can_fit({"model_id": "fx", "parts": [tire]}, tire), "not twice")


func test_every_part_on_sale_shows_on_exactly_one_shop_page() -> void:
	for item: Dictionary in LootRules.catalogue():
		assert_false(LootRules.is_engine(item), "engines aren't sold")
		var pages := [LootRules.is_upgrade(item), LootRules.is_tire(item), LootRules.is_drivetrain(item)]
		assert_eq(pages.count(true), 1, LootRules.item_key(item))
