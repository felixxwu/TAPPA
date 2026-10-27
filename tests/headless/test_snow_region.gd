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


# --- The has_*/​*_of pair -------------------------------------------------------
# Split in two so a caller cannot confuse "authors nothing" with a real value. An unknown id must behave like a region authoring none.

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
	# frozen ground — two levers over one variable.
	var cfg: GameConfig = Config.data
	assert_eq(WeatherLibrary.grip_mult(cfg, WeatherLibrary.WEATHER_SNOW), 1.0,
		"snowfall does not touch grip")
	var entry := WeatherLibrary.by_id(WeatherLibrary.WEATHER_SNOW)
	assert_eq(String(entry.get("id", "")), WeatherLibrary.WEATHER_SNOW,
		"setup: the snow condition is a real entry, not the dry fallback")
