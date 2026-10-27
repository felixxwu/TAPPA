extends GutTest
# Free roam's minimap (features/minimap.md): the seen-sites record, which sites a map shows, the
# heading-up tilted projection, and the tap that asks for the full map. Bare-logic and a bare
# MiniMap control — no free-roam scene, no world generation.

const TEST_PATH := "user://test_mini_map_profile.json"

var _save: Node
var _was_enabled := true


func before_each() -> void:
	_save = get_node("/root/Save")
	_save.profile_path = TEST_PATH
	_save.save_disabled = false
	_save.profile = _save._default_profile()
	CarFixtures.install()
	WorldSession.new_world(1, String(CarLibrary.all()[0]["id"]))
	_was_enabled = Config.data.minimap_enabled
	Config.data.minimap_enabled = true  # the shipped game has it off; these tests are about the map


func after_each() -> void:
	get_tree().paused = false
	Config.data.minimap_enabled = _was_enabled
	CarFixtures.restore()
	_save.profile_path = _save.DEFAULT_PROFILE_PATH
	for suffix in ["", ".bak", ".tmp"]:
		if FileAccess.file_exists(TEST_PATH + suffix):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_PATH + suffix))


# Site 0 spawn (rest), 1 a rest stop, 2 a loot slot, 3 a dead end, along the x axis.
func _sites() -> RoadSites:
	var s := RoadSites.new()
	s.kind = PackedInt32Array([RoadSites.Kind.REST, RoadSites.Kind.REST, RoadSites.Kind.LOOT, RoadSites.Kind.DEAD_END])
	s.pos = PackedVector2Array([Vector2.ZERO, Vector2(1000, 0), Vector2(2000, 0), Vector2(3000, 0)])
	s.radius = PackedFloat32Array([0.0, 0.0, 0.0, 0.0])
	for i in s.pos.size():
		s._box_cells[Vector2i(floori(s.pos[i].x / RoadSites.BOX_CELL_M), floori(s.pos[i].y / RoadSites.BOX_CELL_M))] = PackedInt32Array([i])
	return s


func _kinds(markers: Array) -> Dictionary:
	var out := {}
	for m: Array in markers:
		out[int(m[2])] = int(m[1])
	return out


func _map() -> MiniMap:
	var mm := MiniMap.new()
	add_child_autofree(mm)
	mm.set_frame_size(Vector2(240, 100))
	return mm


# --- seen sites ----------------------------------------------------------------------------------

func test_a_site_within_the_radius_becomes_seen_and_one_outside_does_not() -> void:
	var s := _sites()
	assert_eq(MiniMap.mark_seen_near(s, Vector2(1050, 0), 100.0), 1)
	assert_true(WorldSession.is_seen(1))
	assert_false(WorldSession.is_seen(2))
	assert_eq(MiniMap.mark_seen_near(s, Vector2(1050, 0), 100.0), 0, "already seen is not new")


func test_seen_sites_are_ints_and_an_old_save_without_the_key_reads_as_spawn_only() -> void:
	WorldSession.see(4)
	var world: Dictionary = _save.profile[_save.KEY_WORLD]
	world["seen"] = [0.0, 4.0]  # as JSON hands it back
	assert_true(WorldSession.is_seen(4))
	assert_true(WorldSession.seen_sites()[1] is int)
	world.erase("seen")
	assert_eq(WorldSession.seen_sites(), [0])
	assert_true(WorldSession.see(7), "an old save takes new sightings")
	assert_true(WorldSession.is_seen(7))


# --- what a map shows ----------------------------------------------------------------------------

func test_only_seen_rest_stops_show_and_a_lit_one_always_shows_lit() -> void:
	var s := _sites()
	var shown := _kinds(MiniMap.site_markers(s, {0: true}, Vector2.ZERO, INF))
	assert_eq(shown, {0: MiniMap.Marker.REST_LIT}, "nothing else seen yet")
	for i in [1, 2, 3]:
		WorldSession.see(i)
	shown = _kinds(MiniMap.site_markers(s, {0: true}, Vector2.ZERO, INF))
	assert_eq(shown, {0: MiniMap.Marker.REST_LIT, 1: MiniMap.Marker.REST_UNLIT}, "loot slots and dead ends never show")


func test_markers_are_limited_to_the_radius() -> void:
	var s := _sites()
	WorldSession.see(1)
	var shown := _kinds(MiniMap.site_markers(s, {}, Vector2.ZERO, 500.0))
	assert_false(shown.has(1))


# --- the projection ------------------------------------------------------------------------------

func test_ahead_is_up_and_right_is_right_whatever_the_heading() -> void:
	var mm := _map()
	for fwd: Vector2 in [Vector2(0, -1), Vector2(1, 0), Vector2(-0.6, 0.8)]:
		var car := Vector2(500, -200)
		mm.set_view(car, fwd)
		var right := Vector2(-fwd.y, fwd.x)  # the car's right in world xz (its +X)
		var c := mm.world_to_local(car)
		var ahead := mm.world_to_local(car + fwd * 50.0)
		var side := mm.world_to_local(car + right * 50.0)
		assert_lt(ahead.y, c.y, "a point ahead is above the car for %s" % fwd)
		assert_almost_eq(ahead.x, c.x, 0.01, "straight ahead stays centred for %s" % fwd)
		assert_gt(side.x, c.x, "a point to the right is to the right for %s" % fwd)


func test_the_way_out_arrow_points_away_from_spawn_whatever_the_heading() -> void:
	var mm := _map()
	mm.set_view(Vector2.ZERO, Vector2(0, -1))
	assert_eq(mm.outward_dir(), Vector2.ZERO, "no arrow at spawn")
	for fwd: Vector2 in [Vector2(0, -1), Vector2(1, 0), Vector2(-0.6, 0.8)]:
		var car := Vector2(500, -200)
		mm.set_view(car, fwd)
		var away := mm.world_to_local(car * 1.1) - mm.world_to_local(car)
		assert_almost_eq(mm.outward_dir().angle_to(away), 0.0, 0.01, "points away from spawn for %s" % fwd)
		assert_almost_eq(mm.outward_dir().length(), 1.0, 0.001)


func test_the_ground_is_tilted_away_far_is_narrower_and_compressed() -> void:
	var mm := _map()
	mm.near_frac = 0.5
	var far_w := mm.screen_of(Vector2(1, 0)).x - mm.screen_of(Vector2(0, 0)).x
	var near_w := mm.screen_of(Vector2(1, 1)).x - mm.screen_of(Vector2(0, 1)).x
	assert_lt(far_w, near_w)
	# Equal steps of ground take less screen height the further away they are.
	var far_step := mm.screen_of(Vector2(0.5, 0.25)).y - mm.screen_of(Vector2(0.5, 0.0)).y
	var near_step := mm.screen_of(Vector2(0.5, 1.0)).y - mm.screen_of(Vector2(0.5, 0.75)).y
	assert_lt(far_step, near_step)


# --- tap and visibility --------------------------------------------------------------------------

func _tap(mm: MiniMap) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = true
	ev.position = mm.screen_of(Vector2(0.5, 0.5))
	mm._gui_input(ev)


func test_a_tap_on_the_map_asks_for_the_full_map() -> void:
	var mm := _map()
	watch_signals(mm)
	_tap(mm)
	assert_signal_emitted(mm, "open_requested")


func test_with_the_minimap_off_only_the_prompt_shows_and_a_tap_passes_through() -> void:
	Config.data.minimap_enabled = false
	var mm := _map()
	var rs := FakeRestStops.new()
	autofree(rs)
	rs.site = 3
	mm.rest_stops = rs
	mm.car = Node3D.new()
	autofree(mm.car)
	mm._process(0.0)
	assert_false(mm._ground.visible, "no map drawn")
	assert_true(mm.prompt_label.visible, "the rest-stop prompt still shows")
	watch_signals(mm)
	_tap(mm)
	assert_signal_not_emitted(mm, "open_requested")


# The whole minimap box takes a press, not just the tilted map inside it: its top corners (outside
# the trapezoid) open the full map too.
func test_a_press_anywhere_on_the_minimap_box_counts() -> void:
	# Godot routes a press to a Control when its _has_point accepts it; the default is the whole
	# rect. The minimap used to narrow that to the tilted map shape, so a press on the box's
	# corners did nothing — it must not override _has_point again.
	var names: Array = []
	for m: Dictionary in (load("res://scripts/free_roam/mini_map.gd") as Script).get_script_method_list():
		names.append(String(m["name"]))
	assert_false("_has_point" in names, "the whole minimap box takes a press")
	assert_eq(_map().mouse_filter, Control.MOUSE_FILTER_STOP, "and it does take presses")


func test_toggle_map_asks_for_the_full_map() -> void:
	var mm := _map()
	watch_signals(mm)
	var ev := InputEventAction.new()
	ev.action = "toggle_map"
	ev.pressed = true
	mm._unhandled_input(ev)
	assert_signal_emitted(mm, "open_requested")


func test_while_paused_it_hides_and_ignores_taps() -> void:
	var mm := _map()
	watch_signals(mm)
	get_tree().paused = true
	mm._process(0.0)
	assert_false(mm.visible)
	_tap(mm)
	assert_signal_not_emitted(mm, "open_requested")
	get_tree().paused = false
	mm._process(0.0)
	assert_true(mm.visible)


class FakeRestStops:
	extends RestStops
	var site := -1
	var opens := 0
	func prompt_site() -> int:
		return site
	func can_open() -> bool:
		return site >= 0
	func open_here() -> bool:
		opens += 1
		return site >= 0


func test_the_line_prompts_at_a_rest_stop() -> void:
	var mm := _map()
	var rs := FakeRestStops.new()
	autofree(rs)
	mm.rest_stops = rs
	mm.update_prompt_label()
	assert_false(mm.prompt_label.visible)
	rs.site = 3
	mm.update_prompt_label()
	assert_true(mm.prompt_label.visible)
	assert_string_contains(mm.prompt_label.text, "REST STOP")


func test_a_tap_on_the_prompt_opens_the_rest_stop_not_the_map() -> void:
	var mm := _map()
	var rs := FakeRestStops.new()
	autofree(rs)
	mm.rest_stops = rs
	rs.site = 3
	mm.update_prompt_label()
	watch_signals(mm)
	var ev := InputEventScreenTouch.new()
	ev.pressed = true
	mm.prompt_label.gui_input.emit(ev)
	assert_eq(rs.opens, 1)
	assert_signal_not_emitted(mm, "open_requested")
