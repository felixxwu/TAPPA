extends GutTest
# CarLamps: glowing head and tail lamp flares at the car's authored lamp centres
# (features/car-lamps.md). Driven against a stub car exposing the two things CarLamps reads,
# `lamp_locals` and `brake_lamp`, under a synthetic weather table so nothing depends on which
# shipped conditions are dark. No authored colour, size or brightness is asserted.


class StubCar:
	extends Node3D
	var lamp_locals := {
		"head": PackedVector3Array([Vector3(-0.5, 0.2, -1.6), Vector3(0.5, 0.2, -1.6)]),
		"tail": PackedVector3Array([Vector3(-0.5, 0.2, 1.8), Vector3(0.5, 0.2, 1.8)]),
	}
	var brake_lamp := 0.0


var _car: StubCar
var _lamps: CarLamps
var _saved_weather: Variant
var _saved_night: float


func before_each() -> void:
	_saved_weather = Config.data.weather
	_saved_night = Config.data.night_headlight_amount
	var conditions: Array[Dictionary] = [{"id": "dry"}, {"id": "lit", "headlights": "night_headlight_amount"}]
	WeatherLibrary.override_for_test(conditions)
	Config.data.weather = "dry"
	Config.data.night_headlight_amount = 1.0
	_car = StubCar.new()
	add_child_autofree(_car)
	_lamps = CarLamps.new()
	add_child_autofree(_lamps)
	_lamps.setup(_car)


func after_each() -> void:
	Config.data.weather = _saved_weather
	Config.data.night_headlight_amount = _saved_night
	WeatherLibrary.reset()


func _tick() -> void:
	_lamps._physics_process(1.0 / 60.0)


func test_lamp_locals_for_reads_the_authored_points() -> void:
	var cfg := GameConfig.new()
	cfg.lamp_offsets = {"car": {"head": [Vector3(1, 2, 3)], "tail": [Vector3(4, 5, 6), Vector3(7, 8, 9)]}}
	var locals := cfg.lamp_locals_for({"id": "car"})
	assert_eq(locals["head"], PackedVector3Array([Vector3(1, 2, 3)]))
	assert_eq(locals["tail"], PackedVector3Array([Vector3(4, 5, 6), Vector3(7, 8, 9)]))


func test_a_car_without_an_entry_has_no_lamps() -> void:
	var locals := GameConfig.new().lamp_locals_for({"id": "unlisted"})
	assert_true(locals["head"].is_empty() and locals["tail"].is_empty(), "no entry -> no lamp points")
	_car.lamp_locals = locals
	_tick()
	assert_eq(_lamps.lamp_count(), 0, "a car without lamp points gets no lamp flares")


func test_by_day_nothing_glows_until_the_brake_is_pressed() -> void:
	_tick()
	assert_false(_lamps.head_lit(), "headlights are off by day")
	assert_false(_lamps.tail_lit(), "tail lamps are off by day with no brake")
	_car.brake_lamp = 1.0
	_tick()
	assert_true(_lamps.tail_lit(), "the foot brake lights the tail lamps by day")
	assert_false(_lamps.head_lit(), "braking does not switch the headlights on")


func test_at_night_head_and_tail_lamps_glow_without_braking() -> void:
	Config.data.weather = "lit"
	_tick()
	assert_true(_lamps.head_lit(), "headlights glow when the weather switches the cone on")
	assert_true(_lamps.tail_lit(), "tail lamps run with the headlights")


func test_braking_is_never_dimmer_than_running_lights() -> void:
	var levels_running := CarLamps.lamp_levels(Config.data, 1.0, 0.0)
	var levels_braking := CarLamps.lamp_levels(Config.data, 1.0, 1.0)
	assert_true(levels_braking.y >= levels_running.y, "pressing the brake never dims the tail lamps")


func test_lamps_follow_the_car_and_sit_at_its_lamp_points() -> void:
	_car.global_transform = Transform3D(Basis(Vector3.UP, 1.0), Vector3(10, 2, -5))
	_tick()
	var expected: Vector3 = _car.global_transform * _car.lamp_locals["head"][0]
	var found := false
	for child in _lamps.get_children():
		if (child as Node3D).global_position.distance_to(expected) < 0.001:
			found = true
	assert_true(found, "a lamp sits at the car's first headlight point in world space")


func test_lamps_rebuild_when_the_car_changes() -> void:
	assert_eq(_lamps.lamp_count(), 4)
	_car.lamp_locals = {"head": PackedVector3Array([Vector3.ZERO]), "tail": PackedVector3Array()}
	_tick()
	assert_eq(_lamps.lamp_count(), 1, "swapping to a car with different lamps rebuilds the flares")
