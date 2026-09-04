extends GutTest
# The SCENE-FREE half of the car-library coverage, split out of test_car_library.gd.
#
# Two kinds live here, and neither needs a world:
#   - Roster invariants over the shipped CARS table (ids unique and resolvable, every
#     spec structurally sane). These read authored data as OPAQUE input — structural
#     contracts only, never a chosen value — so they are catalogue-contract tests and
#     deliberately do NOT install CarFixtures.
#   - Derived car stats (max_lateral_g, horsepower, tire_load_factor) driven by
#     hand-built synthetic dicts + a bare GameConfig.new(), so no catalogue entry is
#     needed at all.
#
# They used to sit in test_car_library.gd, whose before_each builds minimal_world() +
# main.tscn for every test (~1.1 s each). None of these touch that scene, so the build
# was pure cost — ~9 s across the nine. test_car_library.gd keeps the tests that really
# do need a booted car (apply_car / apply_owned / cycle_car / model rendering).
#
# The only setup needed is evicting a fixture roster another file may have leaked,
# which matters solely for the three roster invariants.


func before_each() -> void:
	CarLibrary.reset()
	EngineLibrary.reset()


func test_library_has_a_range_of_cars() -> void:
	assert_gt(CarLibrary.CARS.size(), 1, "more than one car — a roster, not a single car")
	var names := {}
	for spec in CarLibrary.CARS:
		names[spec["name"]] = true
	assert_eq(names.size(), CarLibrary.CARS.size(), "car names are unique")


func test_each_spec_is_sane() -> void:
	for spec in CarLibrary.CARS:
		var who: String = spec["name"]
		assert_gt(spec["mass"], 0.0, who + " has positive mass")
		# The gearbox (gear_ratios / final_drive / shift_time) now lives on the ENGINE
		# (EngineLibrary), not the car — its sanity is checked in test_engine_library.gd.
		assert_true(spec.has("engine"), who + " names an engine")
		assert_gt(spec["tire_compound"], 0.0, who + " tyre compound is positive")
		assert_false(EngineLibrary.by_id(spec["engine"]).is_empty(), who + " engine id resolves")
		assert_between(spec["drive_mode"], 0, 2, who + " drive_mode is RWD/AWD/FWD")
		# drag is NOT asserted: it's a per-car tuning knob and 0 is valid (slippery
		# bodies whose engine baseline already meets their real top-speed resistance
		# need no top-up drag — see CarLibrary's drag note). Pinning drag > 0 pins a
		# tunable value, which the project's testing rules forbid.
		# Downforce is a tuning knob, not an invariant (0 = no wing is valid).
		assert_gte(spec.get("downforce_rear", 0.0), 0.0, who + " rear downforce is non-negative")
		for axis in ["x", "y", "z"]:
			assert_gt(spec["body"][axis], 0.0, who + " body." + axis + " positive")
			assert_gt(spec["cabin"][axis], 0.0, who + " cabin." + axis + " positive")
		assert_gt(spec["track"], 0.0, who + " track positive")
		assert_gt(spec["wheelbase"], 0.0, who + " wheelbase positive")
		assert_gt(spec["wheel_radius"], 0.0, who + " wheel_radius positive")
		assert_gt(spec["wheel_width_front"], 0.0, who + " front tyre width positive")
		assert_gt(spec["wheel_width_rear"], 0.0, who + " rear tyre width positive")
		# Suspension: travel doubles as the wheel raycast length (must clear the
		# wheel radius so the ray reaches the ground), stiffness in the export range.
		assert_gt(spec["suspension_travel"], spec["wheel_radius"], who + " spring travel clears wheel radius")
		assert_gt(spec["suspension_stiffness"], 0.0, who + " spring stiffness is positive")
		# The track must fit inside the body width or wheels poke out absurdly.
		assert_lte(spec["track"], spec["body"]["x"] + 0.1, who + " track within body width")
		# Persistence + progression metadata (see save-persistence.md).
		assert_true(spec["id"] is String and not spec["id"].is_empty(), who + " has a stable string id")
		assert_true(spec["country"] is String and not spec["country"].is_empty(), who + " has a country tag")
		assert_true(spec["car_type"] is String and not spec["car_type"].is_empty(), who + " has a car_type tag")
		assert_gt(spec["max_hp"], 0.0, who + " has positive max_hp")
		assert_gt(spec["reward_tier"], 0, who + " has a reward_tier")
		assert_gt(spec["cost"], 0, who + " has a positive money cost")


func test_car_ids_are_unique_and_stable_lookups_work() -> void:
	var ids := {}
	for spec in CarLibrary.CARS:
		assert_false(ids.has(spec["id"]), "id '%s' is unique" % spec["id"])
		ids[spec["id"]] = true
	# index_of / by_id resolve a stable id to the current array position.
	for i in CarLibrary.CARS.size():
		var id: String = CarLibrary.CARS[i]["id"]
		assert_eq(CarLibrary.index_of(id), i, "index_of('%s') resolves to %d" % [id, i])
		assert_eq(CarLibrary.by_id(id)["name"], CarLibrary.CARS[i]["name"], "by_id('%s') returns the entry" % id)
	# Unknown ids degrade safely (the save system drops orphaned entries).
	assert_eq(CarLibrary.index_of("nope"), -1, "unknown id -> -1")
	assert_true(CarLibrary.by_id("nope").is_empty(), "unknown id -> empty dict")




# A square-tyre, 50/50 car whose per-wheel load sits exactly at the reference pressure
# reads back its compound as-is (load factor = 1.0). Verifies the stat is anchored on
# the compound, not some hidden scale.
func test_max_lateral_g_returns_compound_at_reference_load() -> void:
	var cfg := GameConfig.new()
	# Pick a mass so each of 4 wheels carries exactly ref_pressure × width.
	var width := 0.225
	var per_wheel := cfg.tire_ref_pressure * width          # load that gives factor 1.0
	var mass := per_wheel * 4.0 / (Platform.gravity())      # 50/50 -> equal on all wheels
	var entry := {"tire_compound": 1.0, "mass": mass, "weight_front": 0.5,
		"wheel_width_front": width, "wheel_width_rear": width}
	assert_almost_eq(CarLibrary.max_lateral_g(entry, cfg), 1.0, 0.0001,
		"at reference pressure the G equals the compound")


func test_max_lateral_g_scales_with_compound() -> void:
	# The stat must be monotonic in the rubber compound, all else equal.
	var cfg := GameConfig.new()
	var base := {"mass": 1200.0, "weight_front": 0.5, "wheel_width_front": 0.225, "wheel_width_rear": 0.225}
	var grippy := base.duplicate(); grippy["tire_compound"] = 1.3
	var hard := base.duplicate(); hard["tire_compound"] = 0.85
	assert_gt(CarLibrary.max_lateral_g(grippy, cfg), CarLibrary.max_lateral_g(hard, cfg),
		"stickier compound -> higher lateral G")


func test_max_lateral_g_drops_with_mass_and_recovers_with_width() -> void:
	# Load sensitivity: adding mass on the same tyres lowers G; widening the tyres
	# raises it back. This is the whole point of the accurate-deep model.
	var cfg := GameConfig.new()
	var light := {"tire_compound": 1.0, "mass": 900.0, "weight_front": 0.5,
		"wheel_width_front": 0.225, "wheel_width_rear": 0.225}
	var heavy := light.duplicate(); heavy["mass"] = 1800.0
	var heavy_wide := heavy.duplicate()
	heavy_wide["wheel_width_front"] = 0.315; heavy_wide["wheel_width_rear"] = 0.315
	assert_lt(CarLibrary.max_lateral_g(heavy, cfg), CarLibrary.max_lateral_g(light, cfg),
		"more mass on the same tyres -> less grip")
	assert_gt(CarLibrary.max_lateral_g(heavy_wide, cfg), CarLibrary.max_lateral_g(heavy, cfg),
		"wider tyres recover grip lost to mass")


func test_horsepower_is_consistent_with_power_to_weight() -> void:
	# horsepower and power_to_weight both come from peak_power_kw, so for any car
	# the identity horsepower == p/w · mass · (kW→hp) must hold. Synthetic entry:
	# torque/redline supplied directly so no catalogue engine is needed.
	var mass := 1200.0
	var entry := {"peak_torque": 400.0, "redline": 6000.0, "mass": mass}
	var expected := CarLibrary.power_to_weight(entry) * mass \
		* CarLibrary.KW_KG_TO_HP_TONNE / 1000.0
	assert_almost_eq(CarLibrary.horsepower(entry), expected, 0.001,
		"horsepower is peak power scaled by the shared kW→hp factor")
	assert_gt(CarLibrary.horsepower(entry), 0.0, "a real engine makes positive power")


func test_horsepower_scales_with_torque() -> void:
	# More torque, all else equal, means more power — must hold for any tuning values.
	var base := {"peak_torque": 300.0, "redline": 6000.0, "mass": 1200.0}
	var strong := base.duplicate(); strong["peak_torque"] = 500.0
	assert_gt(CarLibrary.horsepower(strong), CarLibrary.horsepower(base),
		"more torque -> more horsepower")


func test_tire_load_factor_is_neutral_when_sensitivity_is_zero() -> void:
	# With the effect disabled the factor is exactly 1.0 for any load/width.
	var cfg := GameConfig.new()
	cfg.tire_load_sensitivity = 0.0
	assert_almost_eq(cfg.tire_load_factor(5000.0, 0.2), 1.0, 0.0001, "k=0 -> no load effect")
	# And a degenerate (zero/negative) load or width is safely neutral, never a divide blow-up.
	assert_eq(cfg.tire_load_factor(0.0, 0.2), 1.0, "zero load -> neutral")
	assert_eq(cfg.tire_load_factor(5000.0, 0.0), 1.0, "zero width -> neutral")


# --- Aero-rated grip ----------------------------------------------------------
# CarLibrary.max_lateral_g gained an optional reference SPEED so a Grip readout can show
# what the aero kit bought (todo/simplified-upgrade-menu.md §5). The default must stay
# exactly the static-load figure the car-select panel has always shown.

func test_max_lateral_g_defaults_to_the_static_figure() -> void:
	var cfg := GameConfig.new()
	var entry := {"mass": 1200.0, "weight_front": 0.55, "tire_compound": 1.0,
		"wheel_width_front": 0.225, "wheel_width_rear": 0.225,
		"downforce_front": 3.0, "downforce_rear": 3.0}
	assert_almost_eq(CarLibrary.max_lateral_g(entry, cfg, 0.0),
		CarLibrary.max_lateral_g(entry, cfg), 0.0000001,
		"an explicit zero speed matches the no-speed call")


func test_downforce_raises_grip_only_above_zero_speed() -> void:
	var cfg := GameConfig.new()
	var base := {"mass": 1200.0, "weight_front": 0.5, "tire_compound": 1.0,
		"wheel_width_front": 0.225, "wheel_width_rear": 0.225}
	var winged := base.duplicate()
	winged["downforce_front"] = 3.0
	winged["downforce_rear"] = 3.0
	assert_almost_eq(CarLibrary.max_lateral_g(winged, cfg, 0.0),
		CarLibrary.max_lateral_g(base, cfg, 0.0), 0.0000001,
		"downforce does nothing standing still")
	assert_gt(CarLibrary.max_lateral_g(winged, cfg, 50.0),
		CarLibrary.max_lateral_g(winged, cfg, 0.0),
		"and adds grip once the car is moving")
	assert_almost_eq(CarLibrary.max_lateral_g(base, cfg, 50.0),
		CarLibrary.max_lateral_g(base, cfg, 0.0), 0.0000001,
		"a car with no wing is unaffected by the reference speed")
