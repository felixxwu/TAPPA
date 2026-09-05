extends GutTest
# Integration coverage for the menu showcase build (todo/menu-background-showcase.md).
# Mirrors test_smoke.gd's main.tscn pattern: instantiate, let _ready's awaited build
# run, then assert on the result. See test_menu_showcase_geometry.gd for the pure
# segment/border-safety maths, tested without building any terrain.
#
# Built ONCE in before_all (six TerrainManager bakes over a real track is not cheap
# — see features/testing.md's shared-before_all-over-before_each cost guidance) and
# shared read-only across every test in this file.

var _scene: MenuShowcase


func before_all() -> void:
	_scene = load("res://menu_showcase.tscn").instantiate()
	add_child(_scene)
	await get_tree().physics_frame  # let _build() (TrackGenerator.generate, set_track ×6) run


func after_all() -> void:
	if is_instance_valid(_scene):
		_scene.free()
	_scene = null


func test_builds_a_track_and_starts_the_camera() -> void:
	assert_true(_scene.is_built(), "the showcase finished building")
	var cam := _scene.camera()
	assert_not_null(cam, "a MenuShowcaseCamera was created")
	assert_true(cam.current, "the showcase camera is the active camera")
	assert_gt(cam.shot_count(), 0, "at least one shot was authored from the generated track")


func test_builds_one_terrain_manager_per_region() -> void:
	var floors := _scene.segment_floors()
	assert_eq(floors.size(), RegionLibrary.ordered().size(),
		"one TerrainManager segment per shipped region")
	for f in floors:
		assert_true(f.corridor().size() > 0, "every segment built at least one chunk")


func test_camera_rotation_covers_every_region_segment() -> void:
	var cam := _scene.camera()
	var region_count := RegionLibrary.ordered().size()
	# Each segment contributes at most MenuShowcase's SHOTS_PER_SEGMENT shots (fewer
	# only if a segment came out too short for the border margin — see
	# safe_shot_arcs); every segment on the shipped, hand-tuned SHOWCASE_SEED should
	# comfortably clear it, so the full rotation should include all six.
	assert_eq(cam.shot_count(), region_count * MenuShowcase._SHOTS_PER_SEGMENT,
		"every region segment contributed its shots to the rotation")


func test_segment_materials_are_never_shared_between_segments() -> void:
	var floors := _scene.segment_floors()
	var seen := {}
	for f in floors:
		var mat_id := (f.chunk_material as Resource).get_instance_id()
		assert_false(seen.has(mat_id), "no two segments share the same material instance")
		seen[mat_id] = true


# Forces segment 0 through "dry" (no road_tint — the baseline) then "rain" (darkens
# via a plain multiply, no "color" key — see weather_library.gd), and checks the
# live shader parameter actually moves and comes back. This is the GROUND half of
# the weather cycle (see menu_showcase.gd's class comment for why the ENVIRONMENT
# half is checked separately, without asserting on terrain vertex lighting the
# already-built chunks can't cheaply re-bake).
func test_road_tint_applies_and_reverts_on_reroll() -> void:
	var floors := _scene.segment_floors()
	var mat := floors[0].chunk_material as ShaderMaterial

	_scene._segment_weather_ids[0] = "dry"
	_scene._apply_segment_road_tint(0)
	var dry_tarmac: Color = mat.get_shader_parameter("tarmac_color")
	assert_almost_eq(dry_tarmac.r, _scene._segment_baseline_tarmac[0].r, 0.001,
		"dry reverts to the segment's own baseline tarmac colour")

	_scene._segment_weather_ids[0] = "rain"
	_scene._apply_segment_road_tint(0)
	var rain_tarmac: Color = mat.get_shader_parameter("tarmac_color")
	assert_lt(rain_tarmac.r, dry_tarmac.r, "rain darkens the tarmac relative to dry")

	_scene._segment_weather_ids[0] = "dry"
	_scene._apply_segment_road_tint(0)
	var reverted: Color = mat.get_shader_parameter("tarmac_color")
	assert_almost_eq(reverted.r, dry_tarmac.r, 0.001, "reverting to dry is idempotent")


func test_foliage_is_spawned_across_the_track() -> void:
	var billboard_count := 0
	for child in _scene.get_children():
		if child is BillboardField:
			billboard_count += 1
	assert_gt(billboard_count, 0,
		"at least one region spawned a tree billboard field over the whole track")


func test_environment_swap_on_a_cut_does_not_crash_and_moves_the_environment() -> void:
	var env: Environment = _scene._world_environment.environment
	# _build()'s own initial reroll may have already left ANY eligible condition
	# live (including "dry" itself), so establish a KNOWN "dry" state first rather
	# than trusting whatever the environment already happens to show.
	_scene._segment_weather_ids[0] = "dry"
	_scene._apply_segment_environment(0)
	var baseline_bg: Color = env.background_color
	assert_eq(baseline_bg, _scene._baseline_env["background_color"],
		"dry matches the authored baseline captured before any weather ran")

	# Segment 0's region is guaranteed one of home/home_coast/taiga's eligible ids,
	# all of which include "rain" (a look override) — force it and apply directly,
	# the same call _process makes on a real cut.
	_scene._segment_weather_ids[0] = "rain"
	_scene._apply_segment_environment(0)
	assert_ne(env.background_color, baseline_bg, "a look override actually changes the environment")

	_scene._segment_weather_ids[0] = "dry"
	_scene._apply_segment_environment(0)
	assert_eq(env.background_color, baseline_bg, "dry restores the exact authored baseline")
