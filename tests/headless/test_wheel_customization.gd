extends GutTest
# Cosmetic wheel customisation (features/wheel-customization.md): the wheel-style
# catalogue derived from the roster, WheelStyle's resolution rules, the optional
# "wheels" key on an owned car, and the solo car-park view that fits them.
#
# Deliberately value-free: no test pins a wheel_texture PATH, a car's stats, or which
# donor is offered — only the CONTRACTS (stock is absent, unknown degrades to stock,
# every option is a real catalogue id, and fitting wheels moves no stat).

const CarFixtures = preload("res://tests/headless/car_fixtures.gd")
const TEST_PATH := "user://test_wheel_customization_profile.json"

var _save: Node


func before_each() -> void:
	get_viewport().gui_release_focus()
	Config.reset()
	# The HQ builds here never assert on scenery counts; trim the framing scatter so
	# each build stays cheap.
	Config.data.hq_tree_count = 8
	Config.data.hq_bush_count = 8
	CarFixtures.install()
	_install_wheel_roster()
	_save = get_node("/root/Save")
	_clean()
	_save.profile_path = TEST_PATH
	_save.save_disabled = false
	_save.load_or_new()
	_save.profile["starter_picked"] = true
	_save.profile["starter_model_id"] = "fx_light_rwd"
	_save.grant_car("fx_light_rwd")
	# A second owned car by default, so wheel_catalogue()'s ownership filter (only owned
	# cars donate wheels) still offers more than the bare stock option to HQ tests below
	# that don't care about eligibility specifically — they just need >1 style to cycle.
	_save.grant_car("fx_rwd_coupe")


func after_each() -> void:
	_clean()
	_save.profile_path = _save.DEFAULT_PROFILE_PATH
	Config.reset()
	CarFixtures.restore()


func _clean() -> void:
	if FileAccess.file_exists(TEST_PATH):
		DirAccess.remove_absolute(TEST_PATH)


# The fixture roster with a wheel_texture added per car. CarFixtures deliberately
# authors NO wheel_texture (test_car.gd leans on that for the blank-disc fallback), but
# a wheel STYLE is a texture — so these tests install their own roster on top. The paths
# are real, loadable assets; nothing here asserts WHICH path a car uses.
func _install_wheel_roster() -> void:
	var textures := [
		"res://blender/mx5/wheel.png",
		"res://blender/focus/wheel.png",
		"res://blender/twingo/wheel.png",
		"res://blender/acty/wheel.png",
	]
	var cars: Array[Dictionary] = CarFixtures.cars()
	for i in cars.size():
		cars[i]["wheel_texture"] = textures[i % textures.size()]
	CarLibrary.override_for_test(cars)


# The id of some catalogue car that is NOT `model_id` — a donor, without naming one.
func _other_car_id(model_id: String) -> String:
	for entry in CarLibrary.all():
		var id := String(entry.get("id", ""))
		if id != model_id and not String(entry.get("wheel_texture", "")).is_empty():
			return id
	return ""


# _other_car_id, granted into the save so it's OWNED (donates wheels under the new
# eligibility rule — see "Eligibility" below).
func _other_owned_car_id(model_id: String) -> String:
	var id := _other_car_id(model_id)
	if not id.is_empty() and not _is_owned(id):
		_save.grant_car(id)
	return id


func _is_owned(model_id: String) -> bool:
	for car in _save.profile.get("cars", []):
		if String((car as Dictionary).get("model_id", "")) == model_id:
			return true
	return false


# --- Catalogue -------------------------------------------------------------------

# Grant every fixture car so wheel_catalogue()'s ownership filter doesn't itself
# constrain a test whose whole point is iterating the catalogue as opaque input.
func _grant_every_car() -> void:
	for entry in CarLibrary.all():
		var id := String(entry.get("id", ""))
		if not _is_owned(id):
			_save.grant_car(id)


# Every offered style is a real catalogue car with a real texture. Iterates the whole
# table as opaque input rather than expecting any particular donor.
func test_wheel_catalogue_entries_are_all_real_catalogue_cars() -> void:
	_grant_every_car()
	var catalogue := CarLibrary.wheel_catalogue(_save.profile)
	assert_gt(catalogue.size(), 0, "the roster donates at least one wheel style")
	for option in catalogue:
		var entry := CarLibrary.by_id(String(option["id"]))
		assert_false(entry.is_empty(), "%s is a resolvable catalogue id" % option["id"])
		assert_eq(String(option["texture"]), String(entry.get("wheel_texture", "")),
			"the offered texture is the donor car's own")
		assert_false(String(option["texture"]).is_empty(), "a style always has a texture")


# A car with no authored wheel texture renders a blank disc, which isn't a style.
func test_cars_without_a_wheel_texture_donate_nothing() -> void:
	_grant_every_car()
	var textureless: String = String(CarLibrary.all()[0]["id"])
	var cars: Array[Dictionary] = CarLibrary.all().duplicate(true)
	cars[0].erase("wheel_texture")
	var typed: Array[Dictionary] = []
	typed.assign(cars)
	CarLibrary.override_for_test(typed)
	var catalogue := CarLibrary.wheel_catalogue(_save.profile)
	assert_gt(catalogue.size(), 0, "the other cars still donate their wheels")
	for option in catalogue:
		assert_ne(String(option["id"]), textureless,
			"a car with no wheel texture is not offered as a style")


# --- Eligibility (only owned cars donate wheels) ----------------------------------

# An unowned car's wheels are NOT on offer, even though it authors a real texture.
func test_an_unowned_cars_wheels_are_excluded() -> void:
	var unowned := _other_car_id("fx_light_rwd")
	assert_false(_is_owned(unowned), "the donor is not owned")
	var options := WheelStyle.options_for("fx_light_rwd", _save.profile)
	for option in options:
		assert_ne(String(option["id"]), unowned,
			"an unowned car's wheels are not offered as a style")


# An owned car's wheels ARE on offer.
func test_an_owned_cars_wheels_are_included() -> void:
	var owned := _other_owned_car_id("fx_light_rwd")
	var options := WheelStyle.options_for("fx_light_rwd", _save.profile)
	var found := false
	for option in options:
		if String(option["id"]) == owned:
			found = true
	assert_true(found, "an owned car's wheels are offered as a style")


# The customized car's OWN stock wheels are always on offer, even for a player who
# owns only this one car (no other donor exists yet) — the very first car.
func test_the_customized_cars_own_stock_is_always_available_with_only_one_owned_car() -> void:
	# A hand-built single-car profile, independent of before_each's default second car —
	# the very first car a player owns, with no other donor in the garage yet.
	var solo_profile := {"cars": [{"model_id": "fx_light_rwd", "instance_id": 1}]}
	var options := WheelStyle.options_for("fx_light_rwd", solo_profile)
	assert_eq(options.size(), 1, "with only one owned car, only its own stock option is on offer")
	assert_eq(String(options[0]["id"]), "fx_light_rwd",
		"with only one owned car, its own stock wheels still lead the list")
	assert_true(bool(options[0]["stock"]), "and are flagged as stock")


# The picker lists the car's OWN wheels first, so "revert to stock" is always reachable
# without hunting, and every entry is a real catalogue id.
func test_options_put_the_cars_own_wheels_first() -> void:
	_save.grant_car("fx_fwd_hatch")
	var options := WheelStyle.options_for("fx_fwd_hatch", _save.profile)
	assert_gt(options.size(), 1, "more than one style is on offer")
	assert_eq(String(options[0]["id"]), "fx_fwd_hatch", "the car's own wheels lead the list")
	assert_true(bool(options[0]["stock"]), "the leading option is flagged as stock")
	for i in range(1, options.size()):
		assert_false(bool(options[i]["stock"]), "only one option is the stock one")


# Regression: a car that authors NO wheel_texture donates nothing, so it wouldn't appear
# in its OWN option list — stranding the player on a donor style with no way back to
# their own wheels. Its stock option must be synthesized instead.
func test_a_textureless_car_still_gets_a_stock_option() -> void:
	var cars: Array[Dictionary] = CarLibrary.all().duplicate(true)
	var bare := String(cars[0]["id"])
	cars[0].erase("wheel_texture")
	var typed: Array[Dictionary] = []
	typed.assign(cars)
	CarLibrary.override_for_test(typed)

	var options := WheelStyle.options_for(bare, _save.profile)
	assert_eq(String(options[0]["id"]), bare, "its own wheels still lead the list")
	assert_true(bool(options[0]["stock"]), "and are flagged as the stock option")
	assert_eq(String(options[0]["texture"]), "",
		"stock for a textureless car is the blank disc, i.e. no texture")
	# So the cursor seats on stock, not silently on some donor's wheels.
	assert_eq(WheelStyle.option_index(options, {"model_id": bare}, bare), 0,
		"a textureless car's cursor seats on its own stock option")
	# And exactly one stock option is offered, not two.
	var stock_count := 0
	for option in options:
		if bool(option["stock"]):
			stock_count += 1
	assert_eq(stock_count, 1, "exactly one option is the stock one")


# --- Resolution rules ------------------------------------------------------------

func test_absent_key_means_stock_wheels() -> void:
	var owned := {"model_id": "fx_light_rwd"}
	assert_eq(WheelStyle.current_wheel_id(owned, "fx_light_rwd"), "fx_light_rwd",
		"a car with no wheels key wears its own")
	assert_false(WheelStyle.is_swapped(owned, "fx_light_rwd"), "stock is not a swap")
	assert_eq(WheelStyle.texture_for(owned, "fx_light_rwd"),
		String(CarLibrary.by_id("fx_light_rwd").get("wheel_texture", "")),
		"stock resolves to the car's own texture")


func test_a_fitted_style_resolves_to_the_donors_texture() -> void:
	var donor := _other_car_id("fx_light_rwd")
	var owned := {"model_id": "fx_light_rwd", "wheels": donor}
	assert_eq(WheelStyle.current_wheel_id(owned, "fx_light_rwd"), donor, "the donor is worn")
	assert_true(WheelStyle.is_swapped(owned, "fx_light_rwd"), "a donor style is a swap")
	assert_eq(WheelStyle.texture_for(owned, "fx_light_rwd"),
		String(CarLibrary.by_id(donor).get("wheel_texture", "")),
		"the donor's own texture is rendered")


# The catalogue is always subject to change: a style whose donor was renamed or dropped
# must degrade to the car's own wheels, never to a blank disc or an error.
func test_unknown_style_falls_back_to_stock() -> void:
	var owned := {"model_id": "fx_light_rwd", "wheels": "no_such_car_at_all"}
	assert_eq(WheelStyle.texture_for(owned, "fx_light_rwd"),
		String(CarLibrary.by_id("fx_light_rwd").get("wheel_texture", "")),
		"a dangling style id degrades to the car's own wheels")


func test_option_index_finds_the_worn_style_and_defaults_to_stock() -> void:
	var donor := _other_owned_car_id("fx_light_rwd")
	var options := WheelStyle.options_for("fx_light_rwd", _save.profile)
	var worn := {"model_id": "fx_light_rwd", "wheels": donor}
	assert_eq(String(options[WheelStyle.option_index(options, worn, "fx_light_rwd")]["id"]), donor,
		"the cursor seats on the worn style")
	var dangling := {"model_id": "fx_light_rwd", "wheels": "gone"}
	assert_eq(WheelStyle.option_index(options, dangling, "fx_light_rwd"), 0,
		"an unknown style seats the cursor on stock")


# --- Save round-trip -------------------------------------------------------------

func test_set_wheels_round_trips() -> void:
	var id: int = _save.selected_instance_id()
	var donor := _other_car_id("fx_light_rwd")
	_save.set_wheels(id, donor)
	assert_eq(String(_save.get_car(id).get("wheels", "")), donor, "the style is stored")
	# And it survives a save/load cycle.
	_save.save_now()
	_save.load_or_new()
	assert_eq(String(_save.get_car(id).get("wheels", "")), donor, "the style persists")


# "Stock" is canonically the key being ABSENT — that keeps owned.hash() (the key the HQ
# car-prop caches use) identical to a never-customised car, so a revert invalidates the
# cached prop exactly as a fit does.
func test_reverting_to_stock_erases_the_key_and_restores_the_hash() -> void:
	var id: int = _save.selected_instance_id()
	var before: int = _save.get_car(id).hash()
	var donor := _other_car_id("fx_light_rwd")
	_save.set_wheels(id, donor)
	assert_ne(_save.get_car(id).hash(), before, "fitting wheels changes the owned hash")
	_save.set_wheels(id, "")
	assert_false(_save.get_car(id).has("wheels"), "an empty id erases the key")
	assert_eq(_save.get_car(id).hash(), before, "reverting restores the original hash")
	# Passing the car's OWN model id is also a revert, not a stored self-reference.
	_save.set_wheels(id, "fx_light_rwd")
	assert_false(_save.get_car(id).has("wheels"), "the car's own id erases the key")


# A new car is born stock: no wheels key, so no migration is needed for old saves.
func test_new_cars_carry_no_wheels_key() -> void:
	var car: Dictionary = _save.grant_car("fx_awd")
	assert_false(car.has("wheels"), "a granted car has no wheels key")


func test_set_wheels_on_an_unknown_car_is_a_no_op() -> void:
	_save.set_wheels(-999, "fx_awd")
	pass_test("setting wheels on a car that doesn't exist doesn't crash")


# Wheels are a SEPARATE system: fitting them never touches the engine-swap state.
func test_wheels_are_independent_of_the_engine_swap_system() -> void:
	var id: int = _save.selected_instance_id()
	_save.set_wheels(id, _other_car_id("fx_light_rwd"))
	var car: Dictionary = _save.get_car(id)
	assert_false(car.has("swapped_engine"), "fitting wheels doesn't touch the engine")


# --- Cosmetic-only guarantee -----------------------------------------------------

# THE load-bearing test: a car wearing someone else's wheels must be physically
# identical to the same car on stock wheels. Compares the whole resolved config, so a
# future change that lets the donor's radius/width leak through fails here.
func test_fitting_wheels_changes_no_physics() -> void:
	var scene: PackedScene = load("res://car.tscn")
	var stock_owned := {"model_id": "fx_light_rwd", "instance_id": 1, "hp": 800.0}
	var shod_owned := {"model_id": "fx_light_rwd", "instance_id": 2, "hp": 800.0,
		"wheels": _other_car_id("fx_light_rwd")}

	var stock: Variant = scene.instantiate()
	add_child_autofree(stock)
	stock.use_isolated_config()
	stock.apply_owned(stock_owned)
	var shod: Variant = scene.instantiate()
	add_child_autofree(shod)
	shod.use_isolated_config()
	shod.apply_owned(shod_owned)
	await get_tree().physics_frame

	assert_eq(shod.config.wheel_radius, stock.config.wheel_radius, "wheel radius is unchanged")
	assert_eq(shod.config.wheel_width_front, stock.config.wheel_width_front,
		"front tyre width is unchanged")
	assert_eq(shod.config.wheel_width_rear, stock.config.wheel_width_rear,
		"rear tyre width is unchanged")
	assert_eq(shod.config.mass, stock.config.mass, "mass is unchanged")
	assert_eq(shod.config.wheel_friction_slip_front, stock.config.wheel_friction_slip_front,
		"front grip is unchanged")
	assert_eq(shod.config.wheel_friction_slip_rear, stock.config.wheel_friction_slip_rear,
		"rear grip is unchanged")
	# The physics wheels themselves keep the car's own radius.
	for wheel in shod.find_children("*", "VehicleWheel3D", false):
		# almost_eq: wheel_radius round-trips through the node's 32-bit float property.
		assert_almost_eq(wheel.wheel_radius, stock.config.wheel_radius, 0.0001,
			"every fitted wheel keeps the car's own physics radius")


# The visual DOES change: the tyre caps render the donor's texture. Asserted on the
# shader parameter, not material identity (_wheel_material builds per texture path).
func test_fitting_wheels_changes_the_rendered_texture() -> void:
	var donor := _other_car_id("fx_light_rwd")
	var scene: PackedScene = load("res://car.tscn")
	var car: Variant = scene.instantiate()
	add_child_autofree(car)
	car.use_isolated_config()
	car.apply_owned({"model_id": "fx_light_rwd", "instance_id": 1, "hp": 800.0, "wheels": donor})
	await get_tree().physics_frame
	var want: String = String(CarLibrary.by_id(donor).get("wheel_texture", ""))
	var seen := 0
	for wheel in car.find_children("*", "VehicleWheel3D", false):
		var tire := wheel.get_node_or_null("Visual/Tire") as MeshInstance3D
		if tire == null:
			continue
		var mat := tire.get_surface_override_material(0) as ShaderMaterial
		assert_not_null(mat, "each tyre cap has its own material")
		var tex: Texture2D = mat.get_shader_parameter("albedo_texture")
		assert_eq(tex.resource_path, want, "the tyre cap renders the donor's wheel texture")
		seen += 1
	assert_eq(seen, 4, "all four wheels are re-skinned (no per-axle staggering)")


# An UNOWNED fielding (free roam / prop / opponent, via apply_car) must show stock
# wheels even if this same instance previously wore a donor style.
func test_bare_apply_car_reverts_to_stock_wheels() -> void:
	var donor := _other_car_id("fx_light_rwd")
	var scene: PackedScene = load("res://car.tscn")
	var car: Variant = scene.instantiate()
	add_child_autofree(car)
	car.use_isolated_config()
	car.apply_owned({"model_id": "fx_light_rwd", "instance_id": 1, "hp": 800.0, "wheels": donor})
	car.apply_car(CarLibrary.index_of("fx_light_rwd"))
	await get_tree().physics_frame
	var want: String = String(CarLibrary.by_id("fx_light_rwd").get("wheel_texture", ""))
	var wheel: Node = car.find_children("*", "VehicleWheel3D", false)[0]
	var mat := (wheel.get_node("Visual/Tire") as MeshInstance3D).get_surface_override_material(0) as ShaderMaterial
	assert_eq((mat.get_shader_parameter("albedo_texture") as Texture2D).resource_path, want,
		"an unowned fielding wears the car's own wheels")


# reskin_wheels is the live try-on: it repaints the caps without disturbing geometry.
func test_reskin_wheels_changes_only_the_texture() -> void:
	var donor := _other_car_id("fx_light_rwd")
	var scene: PackedScene = load("res://car.tscn")
	var car: Variant = scene.instantiate()
	add_child_autofree(car)
	car.use_isolated_config()
	car.apply_owned({"model_id": "fx_light_rwd", "instance_id": 1, "hp": 800.0})
	await get_tree().physics_frame
	var wheel: Node = car.find_children("*", "VehicleWheel3D", false)[0]
	var radius_before: float = wheel.wheel_radius
	var pos_before: Vector3 = wheel.position

	car.reskin_wheels(String(CarLibrary.by_id(donor).get("wheel_texture", "")))
	var mat := (wheel.get_node("Visual/Tire") as MeshInstance3D).get_surface_override_material(0) as ShaderMaterial
	assert_eq((mat.get_shader_parameter("albedo_texture") as Texture2D).resource_path,
		String(CarLibrary.by_id(donor).get("wheel_texture", "")), "the preview texture is applied")
	assert_eq(wheel.wheel_radius, radius_before, "a re-skin doesn't resize the wheel")
	assert_eq(wheel.position, pos_before, "a re-skin doesn't move the wheel")

	# Regression: a preview must NOT be recorded as the fielding override, or it would
	# outlive the preview on a pooled/reused node and leak into a later bare apply_car.
	# Re-fielding this same instance UNOWNED must therefore show its own wheels, even
	# though a donor style is currently previewed on it.
	car.apply_car(CarLibrary.index_of("fx_light_rwd"))
	await get_tree().physics_frame
	var mat_after := (wheel.get_node("Visual/Tire") as MeshInstance3D).get_surface_override_material(0) as ShaderMaterial
	assert_eq((mat_after.get_shader_parameter("albedo_texture") as Texture2D).resource_path,
		String(CarLibrary.by_id("fx_light_rwd").get("wheel_texture", "")),
		"a live preview never leaks into a later unowned fielding")

	# "" restores the car's own wheels.
	car.reskin_wheels(String(CarLibrary.by_id(donor).get("wheel_texture", "")))
	car.reskin_wheels("")
	var mat2 := (wheel.get_node("Visual/Tire") as MeshInstance3D).get_surface_override_material(0) as ShaderMaterial
	assert_eq((mat2.get_shader_parameter("albedo_texture") as Texture2D).resource_path,
		String(CarLibrary.by_id("fx_light_rwd").get("wheel_texture", "")),
		"an empty re-skin restores the car's own wheels")


# --- The HQ wheel view is DELETED, and so is every test of it --------------------
#
# Seventeen tests lived here, driving `hq.tscn`'s solo wheel station: that entering from
# the lift parks the car ALONE (no neighbours, so the side-on framing has a clear view of
# its stance), that it uses the side-on camera, that cycling steps the style and previews
# it live, that fitting saves and returns to the lift, that backing out discards the
# preview and re-skins the car, that re-entering after an early back-out rewires cleanly,
# that a 0 HP car can still change wheels, and that the whole view was keyboard/gamepad
# navigable.
#
# The diegetic hub is deleted (decision 9) and the flat shell has no wheel screen at all,
# so there is nothing left to drive. Everything ABOVE this line is host-free and still
# passes: the catalogue, the eligibility rule, the resolution rules, the save round-trip
# and the cosmetic-only guarantee are the whole feature minus its UI.
#
# WHOEVER BUILDS THE FLAT WHEEL SCREEN owes those behaviours again — see
# features/wheel-customization.md, which keeps them written down, and note the two that
# were bugs first: discarding the preview on back-out, and rewiring cleanly on re-entry.
