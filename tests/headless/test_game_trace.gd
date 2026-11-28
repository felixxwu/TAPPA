extends GutTest
# Covers benchmark/game_trace.gd (the replay's game-state event log) and the Audio.on_beep hook. Docs: features/benchmark.md.


func _state() -> Dictionary:
	return {
		"money": 100, "delivery": {}, "done": [], "cars": ["a"], "parts": {"a": []},
		"weather": "dry", "weather_setting": "dry", "discovered": 3, "discovery_hash": "h0", "rally": "",
		"beeps": [], "hp": 1000.0, "engine_temp": 90.0, "wrecked": false,
		"engine_sfx": {"bov": false, "nitrous": false, "emptied": false, "misfires": 0, "limiter_cuts": 0},
	}


func _kinds(events: Array) -> Array:
	return events.map(func(e: Dictionary) -> String: return String(e["kind"]))


func after_each() -> void:
	GameTrace.stop()


func test_equal_states_give_no_events() -> void:
	assert_eq(GameTrace.diff(_state(), _state(), 5), [])


func test_each_kind_fires_once_on_its_change_with_the_tick() -> void:
	var changes := {
		"money": {"money": 150},
		"delivery_started": {"delivery": {"to": "B", "key": "k"}},
		"delivered": {"done": ["k"]},
		"bought_car": {"cars": ["a", "b"]},
		"bought_part": {"parts": {"a": ["turbo"]}},
		"weather": {"weather": "rain"},
		"discovered": {"discovered": 4, "discovery_hash": "h1"},
		"rally": {"rally": "Hafren"},
		"hp": {"hp": 900.0},
		"engine_temp": {"engine_temp": 91.0},
		"wrecked": {"wrecked": true},
		"beep": {"beeps": [{"hz": 0.0, "sec": 0.0, "db": 0.0}]},
		"engine_sfx": {"engine_sfx": {"bov": true, "nitrous": false, "emptied": false, "misfires": 0, "limiter_cuts": 0}},
	}
	for kind: String in changes:
		var events := GameTrace.diff(_state(), _state().merged(changes[kind], true), 42)
		assert_eq(_kinds(events), [kind], kind)
		assert_eq(events[0]["tick"], 42, kind)


func test_picking_up_a_delivery_fires_once() -> void:
	var started := _state().merged({"delivery": {"to": "B", "key": "k"}}, true)
	var loaded := _state().merged({"delivery": {"to": "B", "key": "k", "cargo_hp": 100.0}}, true)
	assert_eq(_kinds(GameTrace.diff(started, loaded, 1)), ["picked_up"])
	assert_eq(GameTrace.diff(loaded, loaded, 2), [])


func test_completing_a_delivery_pays_and_does_not_report_a_drop() -> void:
	var on := _state().merged({"delivery": {"to": "B", "key": "k", "cargo_hp": 100.0}}, true)
	var done := _state().merged({"money": 200, "done": ["k"]}, true)
	assert_eq(_kinds(GameTrace.diff(on, done, 1)), ["money", "delivered"])


func test_event_order_is_stable() -> void:
	var now := _state().merged({"money": 1, "rally": "R", "hp": 1.0, "weather": "fog", "cars": ["a", "c"]}, true)
	var first := GameTrace.diff(_state(), now, 7)
	assert_eq(_kinds(first), ["money", "bought_car", "weather", "rally", "hp"])
	assert_eq(GameTrace.diff(_state(), now, 7), first)


func test_final_save_drops_only_the_wall_clock_keys() -> void:
	var profile := {"created_utc": "x", "updated_utc": "y", "settings": {"level_money": 5}, "schema_version": 3}
	assert_eq(GameTrace.final_save(profile), {"settings": {"level_money": 5}, "schema_version": 3})
	assert_true(profile.has("updated_utc"), "the live profile is left alone")


func test_on_beep_fires_without_an_audio_device() -> void:
	var audio := get_node("/root/Audio") as AudioManager
	assert_false(audio.is_available(), "headless: no playback")
	GameTrace.listen()
	audio.play_beep(440.0)
	var events := GameTrace.diff({}, {"beeps": GameTrace._beeps.duplicate()}, 3)
	assert_eq(_kinds(events), ["beep"])
	assert_eq(events[0]["hz"], 440.0)
