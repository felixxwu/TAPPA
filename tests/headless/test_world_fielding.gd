extends GutTest
# WHAT THE RUN SCENE FIELDS (world.gd::_field_player_car -> _field_car).
#
# Two things meet here and nowhere else, which is why this file exists rather than
# folding into a unit test of either half:
#   1. the run's CAR — the bound OwnedCar, not the default library car, with its damage
#      model bound to that instance id so the stage's damage lands on the right car;
#   2. the run's EFFECTS — `RunSession.boosts()` (run-scoped picks) merged with
#      `PerkLibrary.equipped_effects(Save.profile)` (permanent purchases) onto a
#      DUPLICATED owned dict, so the effects funnel sees them and the saved profile
#      never does (todo/roguelike-pivot.md decision 51, features/perks.md).
#
# Test 1 is salvaged from the deleted test_menu_flow.gd
# (`test_run_scene_fields_the_bound_session_car`), ported off RallySession.
#
# Cheap world: SceneHelpers.minimal_world() cuts the build to well under a second, and
# nothing here inspects the track, terrain or foliage.

const SceneHelpers = preload("res://tests/headless/scene_helpers.gd")
const CarFixtures = preload("res://tests/headless/car_fixtures.gd")

const FX_PERKS: Array[Dictionary] = [
	{
		"id": "fx_magnet", "label": "Fixture Magnet", "price": 1,
		"unlock": {"stat": LifetimeStats.STAGES_CLEARED, "threshold": 0},
		# A real EFFECTS key and a real GameConfig magnitude field (both code names, not
		# authored catalogue data), so the funnel is exercised end to end.
		"effect_fields": {"coin_pickup_radius_mult": "perk_coin_radius_mult"},
	},
]

var _save: Node
var _scene: Node3D


func before_each() -> void:
	SceneHelpers.minimal_world()
	CarFixtures.install()
	PerkLibrary.override_for_test(FX_PERKS)
	_save = Save
	_save.profile = _save._default_profile()
	# No scene loads from the session itself — this file instantiates main.tscn directly.
	RunSession.auto_load_scenes = false


func after_each() -> void:
	if RunSession.is_active():
		RunSession.pause_run()
	_save.clear_run()
	RunSession.clear_last_result()
	RunSession.auto_load_scenes = true
	PerkLibrary.reset()
	CarFixtures.restore()
	Config.reset()


# Start a region run on a freshly granted fixture car and boot the run scene.
func _field(model_id: String, region_id := "") -> Dictionary:
	var owned: Dictionary = _save.grant_car(model_id)
	var region := region_id if region_id != "" else String(RegionLibrary.ordered()[0]["id"])
	assert_true(RunSession.start_region(region, owned), "setup: the run started")
	_scene = load("res://main.tscn").instantiate()
	add_child_autofree(_scene)
	await get_tree().process_frame
	return owned


func test_the_run_scene_fields_the_bound_session_car() -> void:
	var owned := await _field("fx_awd")
	var car: VehicleBody3D = _scene.get_node("Car")
	assert_eq(car.damage.instance_id, int(owned["instance_id"]),
		"the car's damage model is bound to the fielded instance, so the stage's damage "
		+ "lands on the car that drove it")
	assert_eq(car.current_car_name(), String(CarLibrary.by_id("fx_awd")["name"]),
		"the owned car's model is fielded, not the default library car")


# THE DECISION-51 SEAM, end to end: an equipped perk reaches the live config through the
# same `boosts` list a run's picks use. Asserts the RELATION (the field moved by the
# multiplier the perk names), never a shipped number — both are tunables.
func test_an_equipped_perk_reaches_the_fielded_cars_config() -> void:
	_save.profile[_save.KEY_BOUGHT_PERKS] = ["fx_magnet"]
	_save.profile[_save.KEY_EQUIPPED_PERKS] = ["fx_magnet"]
	var authored := float(Config.authored_value("coin_pickup_radius_m", 0.0))
	var mult: float = Config.data.perk_coin_radius_mult

	await _field("fx_awd")

	assert_almost_eq(Config.data.coin_pickup_radius_m, authored * mult, 0.001,
		"the equipped perk's effect landed on the live config at fielding time")


func test_an_unequipped_perk_leaves_the_config_at_its_authored_value() -> void:
	# The other half of the reseed contract, at the world level: owning a perk without
	# equipping it must change nothing.
	_save.profile[_save.KEY_BOUGHT_PERKS] = ["fx_magnet"]
	_save.profile[_save.KEY_EQUIPPED_PERKS] = []

	await _field("fx_awd")

	assert_almost_eq(Config.data.coin_pickup_radius_m,
		float(Config.authored_value("coin_pickup_radius_m", 0.0)), 0.001)


# The merge happens on a DUPLICATE. A run's boosts and a player's perks must never be
# written back into profile["cars"] — a run's picks are wiped when it ends, and a perk
# lives on the profile, not on one car.
func test_fielding_writes_no_boosts_into_the_saved_profile() -> void:
	_save.profile[_save.KEY_BOUGHT_PERKS] = ["fx_magnet"]
	_save.profile[_save.KEY_EQUIPPED_PERKS] = ["fx_magnet"]
	var owned := await _field("fx_awd")
	var stored: Dictionary = _save.get_car(int(owned["instance_id"]))
	assert_false(stored.has("boosts"),
		"the effects were merged onto a duplicate, never onto the saved car")


# --- The stage wears its REGION's look ------------------------------------------------
#
# world.gd::_current_region_look hardcoded `region_id := "home"` from the stage-2 deletion
# (its comment said stage 4's region select would give it a real answer) until stage 9
# wired it to RunSession.region_id() — so every region run was driven under the home
# palette, sky and tree mix. The handling overrides were never affected: StageConfig reads
# `event["region"]` off the drawn stage, which was always right.
#
# Asserts the RELATION (the world resolves the run's own region's look), never a look
# VALUE — every field in a region's look block is authored data.

func test_a_region_runs_stage_wears_that_regions_look() -> void:
	# The LAST region in the unlock order, to be sure this is not the "home" default
	# passing by coincidence.
	var ordered := RegionLibrary.ordered()
	var region := String(ordered[ordered.size() - 1]["id"])
	await _field("fx_awd", region)
	assert_eq(_scene._current_region_look(), RegionLibrary.look_of(region),
		"the driven stage resolves the RUN's region, not the home default")


func test_a_challenge_stage_falls_back_to_the_home_look() -> void:
	# A challenge is rolled from the period hash and authors no region at all, so it must
	# land on the plain home look rather than whatever the last region run left behind.
	var owned: Dictionary = _save.grant_car("fx_awd")
	assert_true(RunSession.start(ChallengeLibrary.DAILY, owned,
		int(Time.get_unix_time_from_system())), "setup: the challenge started")
	_scene = load("res://main.tscn").instantiate()
	add_child_autofree(_scene)
	await get_tree().process_frame
	assert_eq(_scene._current_region_look(), RegionLibrary.look_of("home"))
