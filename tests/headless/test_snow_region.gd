extends GutTest

# The snow region — the first region to influence HANDLING as well as look.
#
# Everything here is a RELATION or a STRUCTURE, never a tuned value: a designer retuning
# snow_grass_grip / ice_grip / snow_deep_drag in the inspector must not break this file
# (CLAUDE.md). Where a region is needed, a SYNTHETIC one is installed via the
# Registry.Seam rather than leaning on the shipped Alps entry — except in the two places
# explicitly marked as catalogue-contract checks.

const SNOW_REGION := "test_frozen"
const PLAIN_REGION := "test_plain"

var _cfg: GameConfig


func before_each() -> void:
	Config.reset()
	_cfg = Config.data
	# A synthetic pair: one region that authors every handling block, one that authors
	# none. The values are arbitrary — only the RELATIONS between them are asserted.
	var regions: Array[Dictionary] = [
		{"id": PLAIN_REGION, "name": "Plain"},
		{
			"id": SNOW_REGION, "name": "Frozen",
			"surface_grip": {
				"grass": "snow_grass_grip",
				"gravel": "snow_gravel_grip",
				"tarmac": "snow_tarmac_grip",
			},
			"deep_snow": {"depth": "snow_visual_depth_m", "drag": "snow_deep_drag"},
			"frozen_water": {"grip": "ice_grip"},
		},
	]
	RegionLibrary.override_for_test(regions)


func after_each() -> void:
	RegionLibrary.reset()
	Config.reset()


func _seat(region_id: String) -> GameConfig:
	var live: GameConfig = (load(Config.CONFIG_PATH) as GameConfig).duplicate(true)
	RallySession.apply_event_config(live, {"seed": 1, "region": region_id})
	return live


# --- The has_*/​*_of pair -------------------------------------------------------
# Split in two so a caller cannot confuse "authors nothing" with a real value, exactly
# as water_level_of documents. An unknown id must behave like a region authoring none.

func test_a_region_authoring_no_handling_reports_and_resolves_nothing() -> void:
	for rid in [PLAIN_REGION, "no_such_region", ""]:
		assert_false(RegionLibrary.has_surface_grip(rid), "%s: no grip block" % rid)
		assert_false(RegionLibrary.has_deep_snow(rid), "%s: no deep snow" % rid)
		assert_false(RegionLibrary.has_frozen_water(rid), "%s: no ice" % rid)
		assert_eq(RegionLibrary.surface_grip_of(_cfg, rid), {}, "%s: empty grip" % rid)
		assert_eq(RegionLibrary.deep_snow_of(_cfg, rid), {}, "%s: empty snow" % rid)
		assert_eq(RegionLibrary.frozen_water_of(_cfg, rid), {}, "%s: empty ice" % rid)


func test_a_region_authoring_handling_resolves_the_named_config_fields() -> void:
	assert_true(RegionLibrary.has_surface_grip(SNOW_REGION))
	var grip := RegionLibrary.surface_grip_of(_cfg, SNOW_REGION)
	# The region names FIELDS, never numbers — so what comes back must be what the
	# config currently holds, whatever the designer has set it to.
	assert_eq(grip.get("grass"), _cfg.snow_grass_grip)
	assert_eq(grip.get("gravel"), _cfg.snow_gravel_grip)
	assert_eq(grip.get("tarmac"), _cfg.snow_tarmac_grip)
	var deep := RegionLibrary.deep_snow_of(_cfg, SNOW_REGION)
	assert_eq(deep.get("drag"), _cfg.snow_deep_drag)
	assert_eq(deep.get("depth"), _cfg.snow_visual_depth_m)
	assert_eq(RegionLibrary.frozen_water_of(_cfg, SNOW_REGION).get("grip"), _cfg.ice_grip)


func test_a_block_naming_an_unknown_field_is_skipped_not_defaulted() -> void:
	# A typo must not silently resolve to 0.0 — on a grip block that reads as "no grip
	# at all", which is a far worse failure than falling back to the baseline.
	RegionLibrary.override_for_test([
		{"id": "typo", "surface_grip": {"grass": "definitely_not_a_field"}},
	] as Array[Dictionary])
	assert_eq(RegionLibrary.surface_grip_of(_cfg, "typo"), {},
		"an unknown field name yields no entry rather than a zero")


func test_resolving_does_not_coerce_to_float() -> void:
	# A float() here crashed rally start with "Nonexistent 'float' constructor" the
	# moment a block named a Color field. Nothing about the pattern is numeric.
	RegionLibrary.override_for_test([
		{"id": "coloured", "surface_grip": {"grass": "ice_color"}},
	] as Array[Dictionary])
	var out := RegionLibrary.surface_grip_of(_cfg, "coloured")
	assert_true(out.get("grass") is Color, "a Color field resolves as a Color")


# --- Seating through the one funnel --------------------------------------------

func test_a_snow_stage_takes_the_regions_grip_and_deep_snow() -> void:
	var live := _seat(SNOW_REGION)
	assert_eq(live.grass_grip, _cfg.snow_grass_grip)
	assert_eq(live.gravel_grip, _cfg.snow_gravel_grip)
	assert_eq(live.tarmac_grip, _cfg.snow_tarmac_grip)
	assert_eq(live.deep_snow_drag, _cfg.snow_deep_drag)
	assert_eq(live.deep_snow_depth_m, _cfg.snow_visual_depth_m)
	assert_eq(live.frozen_water_grip, _cfg.ice_grip)


func test_a_region_without_the_blocks_is_an_exact_no_op() -> void:
	# The property the whole design leans on: every other region must be byte-identical
	# to the authored baseline, so adding this feature changed no existing stage.
	var base: GameConfig = load(Config.CONFIG_PATH)
	var live := _seat(PLAIN_REGION)
	assert_eq(live.grass_grip, base.grass_grip)
	assert_eq(live.gravel_grip, base.gravel_grip)
	assert_eq(live.tarmac_grip, base.tarmac_grip)
	assert_eq(live.deep_snow_drag, 0.0, "no deep snow means exactly zero drag")
	assert_eq(live.deep_snow_depth_m, 0.0, "…and exactly zero visual raise")
	assert_eq(live.frozen_water_grip, 0.0, "…and liquid water")


func test_an_eventless_region_tag_does_not_leak_into_the_next_stage() -> void:
	# apply_event_config pins every omitted field to the AUTHORED baseline, not to the
	# current session config. Without that, one slippery stage would leave the next one
	# slippery too — the same trap track_water_level_m is protected from.
	var base: GameConfig = load(Config.CONFIG_PATH)
	var live: GameConfig = (load(Config.CONFIG_PATH) as GameConfig).duplicate(true)
	RallySession.apply_event_config(live, {"seed": 1, "region": SNOW_REGION})
	assert_ne(live.grass_grip, base.grass_grip, "setup: the snow stage overrode grip")
	RallySession.apply_event_config(live, {"seed": 2, "region": PLAIN_REGION})
	assert_eq(live.grass_grip, base.grass_grip, "the next stage is back to baseline")
	assert_eq(live.deep_snow_drag, 0.0, "…with no residual drag")
	assert_eq(live.frozen_water_grip, 0.0, "…and no residual ice")


func test_an_event_with_no_region_gets_the_baseline() -> void:
	# Free roam / benchmark / dev boot pass events with no region tag.
	var base: GameConfig = load(Config.CONFIG_PATH)
	var live: GameConfig = (load(Config.CONFIG_PATH) as GameConfig).duplicate(true)
	RallySession.apply_event_config(live, {"seed": 3})
	assert_eq(live.grass_grip, base.grass_grip)
	assert_eq(live.deep_snow_drag, 0.0)
	assert_eq(live.frozen_water_grip, 0.0)


# --- The AI field scales with the player ---------------------------------------

func test_region_grip_reaches_the_lap_time_model() -> void:
	# Snow is a VARIETY lever, not a difficulty one: rival times must lengthen with the
	# player's grip loss. LapTimeModel reads the same live fields, so this is really
	# asserting that the funnel seats them where the solver looks.
	var car := {
		"mass": 1200.0, "peak_torque": 300.0, "redline": 6500.0,
		"drive_mode": CarLibrary.AWD,
	}
	var event := {"seed": 7, "turn_count": 20, "surface_mix": 0.5}
	# A corner is required for grip to matter at all: on a pure straight the lap is
	# power-limited and mu never binds, so the two times would be identical and the test
	# would pass for the wrong reason.
	var track := TrackFixtures.straight_then_arc(80.0, 45.0, PI)
	var base: GameConfig = load(Config.CONFIG_PATH)

	var dry_cfg: GameConfig = base.duplicate(true)
	RallySession.apply_event_config(dry_cfg, event.duplicate())
	Config.data = dry_cfg
	var dry_ms := LapTimeModel.optimum_ms(track, car, event)

	var snow_event: Dictionary = event.duplicate()
	snow_event["region"] = SNOW_REGION
	var snow_cfg: GameConfig = base.duplicate(true)
	RallySession.apply_event_config(snow_cfg, snow_event)
	Config.data = snow_cfg
	var snow_ms := LapTimeModel.optimum_ms(track, car, snow_event)

	assert_gt(dry_ms, 0, "setup: the dry lap actually solved")

	assert_gt(snow_ms, dry_ms,
		"a slippery region lengthens the optimum, so the whole rival field scales")


func test_the_car_rating_is_immune_to_a_slippery_region() -> void:
	# CarPerformance benchmarks at a frozen surface grip. If a region could move a
	# rating, it would silently re-pitch every matched opponent field in the game.
	var car := {
		"mass": 1200.0, "peak_torque": 300.0, "redline": 6500.0,
		"drive_mode": CarLibrary.AWD,
	}
	var base: GameConfig = load(Config.CONFIG_PATH)
	var dry_cfg: GameConfig = base.duplicate(true)
	RallySession.apply_event_config(dry_cfg, {"seed": 1})
	Config.data = dry_cfg
	CarPerformance.reset()
	var dry_rating := CarPerformance.rating(car)

	var snow_cfg: GameConfig = base.duplicate(true)
	RallySession.apply_event_config(snow_cfg, {"seed": 1, "region": SNOW_REGION})
	Config.data = snow_cfg
	CarPerformance.reset()
	assert_eq(CarPerformance.rating(car), dry_rating,
		"the rating is benchmarked at a frozen grip and cannot drift with the region")


# --- Catalogue contract (the shipped Alps entry) --------------------------------
# Deliberately structural: that the blocks EXIST and name real properties, never what
# their values are.

func test_the_shipped_snow_region_names_only_real_config_properties() -> void:
	RegionLibrary.reset()
	var cfg: GameConfig = load(Config.CONFIG_PATH)
	var named := 0
	for region in RegionLibrary.all():
		for block_key in ["surface_grip", "deep_snow", "frozen_water"]:
			for key in (region.get(block_key, {}) as Dictionary).values():
				named += 1
				assert_not_null(cfg.get(String(key)),
					"%s names GameConfig.%s, which does not exist" % [block_key, key])
	assert_gt(named, 0, "at least one region authors a handling block")


# Total solid area of a silhouette mesh, as a fraction of its own bounding box.
#
# This, NOT the bounding box, is the measure that matters. A tree billboard is an opaque
# cutout — TreeSilhouette traces the geometry from the alpha — and a failed trace
# produces degenerate SLIVERS spread across a full-size bounding box. Such a mesh has a
# perfectly healthy width and height and renders as nothing but a scatter of specks.
func _silhouette_fill(mesh: Mesh) -> float:
	if mesh.get_surface_count() == 0:
		return 0.0
	var verts: PackedVector3Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var area := 0.0
	for i in range(0, verts.size(), 3):
		if i + 2 < verts.size():
			area += (verts[i + 1] - verts[i]).cross(verts[i + 2] - verts[i]).length() * 0.5
	var bb := mesh.get_aabb()
	return area / maxf(0.0001, bb.size.x * bb.size.y)


func test_every_region_tree_texture_traces_to_a_solid_silhouette() -> void:
	# THE REGRESSION GUARD FOR TWO REAL BUGS, both of which shipped invisible trees while
	# the textures looked perfectly fine in an image viewer:
	#
	#   1. A fragmented alpha traced to 12 vertices 0.004 units tall — nothing at all.
	#   2. A *less* fragmented alpha traced to 92 triangles filling 0.3% of a FULL-SIZE
	#      bounding box: degenerate slivers, which render as dark specks floating where
	#      the tree should be. The first version of this test asserted bounding-box
	#      height and PASSED that tree, which is why it now measures solid area.
	#
	# The threshold is deliberately far below any real tree — the shipped four trace to
	# 80-134% fill — so this catches "traced to nothing", it does not police art. Fill
	# can exceed 100%: the tracer emits overlapping triangles.
	RegionLibrary.reset()
	var checked := 0
	for region in RegionLibrary.all():
		for species in RegionLibrary.tree_mix(RegionLibrary.look_of(String(region["id"]))):
			var path := String((species as Dictionary).get("texture", ""))
			var tex: Texture2D = load(path)
			assert_not_null(tex, "%s loads" % path)
			var mesh := Foliage.tree_silhouette_mesh(tex)
			assert_gt(mesh.get_surface_count(), 0, "%s traces to a surface" % path)
			assert_gt(mesh.get_aabb().size.y, 0.1, "%s traces to real height" % path)
			assert_gt(_silhouette_fill(mesh), 0.25,
				"%s traces to a SOLID body, not slivers (a near-zero fill renders as "
				% path + "floating specks with no tree)")
			checked += 1
	assert_gt(checked, 0, "at least one region tree was actually checked")


# --- Snowfall is a look condition, not a grip one -------------------------------

func test_the_snowfall_condition_carries_no_grip_multiplier() -> void:
	# The REGION owns grip in this corner, dry stages included. If snowfall also scaled
	# mu, a snowy stage would be arbitrarily slipperier than a dry one on the same
	# frozen ground — two levers over one variable. It must therefore also stay out of
	# physics_fields, so it never re-keys the opponent cache for a change it cannot make.
	var cfg: GameConfig = Config.data
	assert_eq(WeatherLibrary.grip_mult(cfg, RallyLibrary.WEATHER_SNOW), 1.0,
		"snowfall does not touch grip")
	var entry := WeatherLibrary.by_id(RallyLibrary.WEATHER_SNOW)
	assert_eq(String(entry.get("id", "")), RallyLibrary.WEATHER_SNOW,
		"setup: the snow condition is a real entry, not the dry fallback")
	assert_eq(WeatherLibrary.physics_fields(entry), [],
		"and names nothing that could change a lap time")


# --- Per-species baseline proportions -------------------------------------------

func test_the_alps_conifers_are_taller_than_they_are_wide() -> void:
	# Catalogue contract, stated as a RELATION so any reasonable retune survives: a
	# conifer species must not be authored wider than it is tall. The bug this guards is
	# forgetting size_scale entirely on a tall narrow cutout, which leaves it stretched
	# onto the square card and drawn at up to twice its real width.
	RegionLibrary.reset()
	var cfg: GameConfig = Config.data
	for species in RegionLibrary.tree_mix(RegionLibrary.look_of("snow")):
		var entry: Dictionary = species
		var scale: Vector2 = entry.get("size_scale", Vector2.ONE)
		var base: Vector2 = cfg.region_tree_billboard_size_m \
			if String(entry.get("profile", "home")) == "region" else cfg.tree_size_m
		var w := base.x * scale.x
		var h := base.y * scale.y
		assert_lt(w, h, "%s is drawn taller than wide, as a conifer must be"
			% String(entry.get("texture", "?")))
