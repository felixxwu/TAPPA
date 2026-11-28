extends GutTest

# The snow region — the first region to influence HANDLING as well as look.
#
# Everything here is a RELATION or a STRUCTURE, never a tuned value: a designer retuning
# snow_grass_grip / snow_deep_drag must not break this file
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
		assert_eq(RegionLibrary.surface_grip_of(_cfg, rid), {}, "%s: empty grip" % rid)
		assert_eq(RegionLibrary.deep_snow_of(_cfg, rid), {}, "%s: empty snow" % rid)


func test_a_region_authoring_handling_resolves_the_named_config_fields() -> void:
	var grip := RegionLibrary.surface_grip_of(_cfg, SNOW_REGION)
	# The region names FIELDS, never numbers — so what comes back must be what the
	# config currently holds, whatever the designer has set it to.
	assert_eq(grip.get("grass"), _cfg.snow_grass_grip)
	assert_eq(grip.get("gravel"), _cfg.snow_gravel_grip)
	assert_eq(grip.get("tarmac"), _cfg.snow_tarmac_grip)
	var deep := RegionLibrary.deep_snow_of(_cfg, SNOW_REGION)
	assert_eq(deep.get("drag"), _cfg.snow_deep_drag)
	assert_eq(deep.get("depth"), _cfg.snow_visual_depth_m)


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
		{"id": "coloured", "surface_grip": {"grass": "wheel_color"}},
	] as Array[Dictionary])
	var out := RegionLibrary.surface_grip_of(_cfg, "coloured")
	assert_true(out.get("grass") is Color, "a Color field resolves as a Color")


# --- Catalogue contract (the shipped Alps entry) --------------------------------
# Deliberately structural: that the blocks EXIST and name real properties, never what
# their values are.

func test_the_shipped_snow_region_names_only_real_config_properties() -> void:
	RegionLibrary.reset()
	var cfg: GameConfig = GameConfig.new()
	var named := 0
	for region in RegionLibrary.all():
		for block_key in ["surface_grip", "deep_snow"]:
			for key in (region.get(block_key, {}) as Dictionary).values():
				named += 1
				assert_not_null(cfg.get(String(key)),
					"%s names GameConfig.%s, which does not exist" % [block_key, key])
	assert_gt(named, 0, "at least one region authors a handling block")
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
