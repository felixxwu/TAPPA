extends GutTest
# StartLine: the pre-event start-line scene (briefing panel + presence cars) shown
# before the countdown. Built against stub car / stage-manager so the panel content,
# presence line-up and launch hand-off are tested without booting the whole run
# scene. See todo/menus.md location 2 + scripts/start_line.gd.


# Minimal stand-in for the fielded Car: a damage model + a model name.
class StubDamage:
	extends RefCounted
	var hp := 600.0
	var max_hp := 1000.0
	var immortal := false


class StubCar:
	extends Node3D
	var damage := StubDamage.new()
	func current_car_name() -> String:
		return "Audi RS3"


# Records the launch hand-off (StartLine -> StageManager.begin_countdown()).
class StubStage:
	extends Node
	var begin_calls := 0
	func begin_countdown() -> void:
		begin_calls += 1


var _car: StubCar
var _stage: StubStage


func before_each() -> void:
	Config.reset()
	_car = StubCar.new()
	add_child_autofree(_car)
	_stage = StubStage.new()
	add_child_autofree(_stage)


func after_each() -> void:
	Config.reset()


# RWD Masters has a drive_mode restriction, so the restriction line is non-trivial.
func _rally() -> Dictionary:
	return RallyLibrary.by_id("rwd_masters")


func _make(event_index := 0) -> StartLine:
	var sl := StartLine.new()
	add_child_autofree(sl)
	sl.setup(_car, null, _stage, _rally(), event_index)
	return sl


func test_briefing_reflects_rally_and_event() -> void:
	Config.data.start_presence_count = 0  # focus on the panel
	var sl := _make(1)  # second event
	assert_string_contains(sl._rally_label.text, "RWD Masters", "the rally name heads the briefing")
	assert_eq(sl._event_label.text, "Event 2 of 3", "event index is 1-based out of the event count")
	assert_string_contains(sl._restriction_label.text, "RWD", "the car restriction is spelled out")
	assert_eq(sl._car_label.text, "Audi RS3", "the fielded car is named")
	assert_false(sl.has_launched(), "the briefing waits for the player to launch")


func test_hp_bar_reflects_fielded_car() -> void:
	Config.data.start_presence_count = 0
	var sl := _make()
	assert_almost_eq(sl._hp_bar.value, 0.6, 0.001, "the HP bar shows the fielded car's HP fraction")
	assert_string_contains(sl._hp_label.text, "600/1000", "the HP figures are legible before committing")


func test_immortal_car_shows_inf_hp() -> void:
	Config.data.start_presence_count = 0
	_car.damage.immortal = true
	var sl := _make()
	assert_eq(sl._hp_bar.value, 1.0, "an immortal car reads as full")
	assert_string_contains(sl._hp_label.text, "INF", "an immortal car shows INF rather than a number")


func test_presence_cars_spawned() -> void:
	Config.data.start_presence_count = 3
	var sl := _make()
	assert_eq(sl.presence_count(), 3, "the configured number of atmosphere cars line up")


func test_presence_count_zero_spawns_none() -> void:
	Config.data.start_presence_count = 0
	var sl := _make()
	assert_eq(sl.presence_count(), 0, "presence cars can be turned off")


func test_launch_starts_countdown_and_hides_briefing() -> void:
	Config.data.start_presence_count = 0
	var sl := _make()
	sl.launch()
	assert_true(sl.has_launched(), "launching flips the launched flag")
	assert_eq(_stage.begin_calls, 1, "launch hands off to StageManager.begin_countdown()")
	assert_false(sl._briefing.visible, "the briefing hides once launched")
	# Idempotent: a second tap during the countdown must not re-launch.
	sl.launch()
	assert_eq(_stage.begin_calls, 1, "a second launch is ignored")
