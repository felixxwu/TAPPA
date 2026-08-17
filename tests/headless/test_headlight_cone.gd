extends GutTest
# The fake headlight cone (scripts/headlight_cone.gd,
# shaders/headlight_cone.gdshaderinc). See todo/night-weather-and-headlights.md and
# features/weather.md.
#
# BEHAVIOUR ONLY. Nothing here pins an authored angle, range, colour or strength —
# a designer retuning headlight_outer_deg or headlight_range_m in the inspector must
# not break a single assertion, and neither must moving the cone onto a further
# condition or retuning how hard any of them burns. What IS pinned is the structure
# that has to hold for any values: the gate is the weather table's "headlights" key,
# the cone points where the car points, the outer edge is always wider than the inner
# one, and on a condition that authors no cone the whole thing is an exact no-op.


func after_each() -> void:
	WeatherLibrary.reset()


func _night_cfg() -> GameConfig:
	var cfg := GameConfig.new()
	cfg.weather = RallyLibrary.WEATHER_NIGHT
	return cfg


# A synthetic two-condition table: one that switches the lights on and one that does
# not, both otherwise featureless. Used instead of the shipped conditions so nothing
# here depends on WHICH conditions are authored to light up, only on the mechanism.
func _install_synthetic_table(strength_field: String) -> void:
	var conditions: Array[Dictionary] = [
		{"id": "dry"},
		{"id": "lit", "headlights": strength_field},
	]
	WeatherLibrary.override_for_test(conditions)


# --- the gate ----------------------------------------------------------------

func test_the_cone_is_armed_by_the_weather_tables_headlights_key() -> void:
	# The gate is authored DATA, not a hardcoded weather id: a condition that names a
	# strength field lights up and one that does not stays dark, whatever those
	# conditions are called. This is what let storm join night without touching the
	# driver — and it is the "no consumer tests == WEATHER_x" rule applied to the cone.
	_install_synthetic_table("night_headlight_amount")
	var cfg := GameConfig.new()
	cfg.night_headlight_amount = 1.0
	cfg.weather = "dry"
	assert_false(HeadlightCone.has_headlights(cfg), "a condition naming no strength is dark")
	cfg.weather = "lit"
	assert_true(HeadlightCone.has_headlights(cfg), "a condition naming one lights up")


func test_a_condition_authored_at_zero_strength_is_off() -> void:
	# Strength doubles as the switch, in the table and in the shader alike: 0 makes
	# headlight_lit() return exactly 0.0, so arming the cone anyway would push uniforms
	# every frame to draw nothing.
	_install_synthetic_table("night_headlight_amount")
	var cfg := GameConfig.new()
	cfg.weather = "lit"
	cfg.night_headlight_amount = 0.0
	assert_false(HeadlightCone.has_headlights(cfg), "zero strength means the lights are off")
	assert_true(HeadlightCone.params(cfg, Transform3D.IDENTITY).is_empty(),
		"and no cone parameters are produced")


func test_the_pushed_strength_is_the_one_the_condition_authors() -> void:
	# Two conditions may light up at DIFFERENT strengths (night is authored bright, a
	# storm's half-dark day much dimmer), so the amount must come from the live
	# condition's own field rather than one shared constant.
	var conditions: Array[Dictionary] = [
		{"id": "bright", "headlights": "night_headlight_amount"},
		{"id": "dim", "headlights": "storm_headlight_amount"},
	]
	WeatherLibrary.override_for_test(conditions)
	var cfg := GameConfig.new()
	cfg.night_headlight_amount = 0.9
	cfg.storm_headlight_amount = 0.2
	cfg.weather = "bright"
	assert_almost_eq(HeadlightCone.params(cfg, Transform3D.IDENTITY)[HeadlightCone.G_AMOUNT] as float,
		0.9, 0.001, "the bright condition pushes its own strength")
	cfg.weather = "dim"
	assert_almost_eq(HeadlightCone.params(cfg, Transform3D.IDENTITY)[HeadlightCone.G_AMOUNT] as float,
		0.2, 0.001, "and the dim one pushes its own, not the other's")


func test_a_null_config_has_no_headlights() -> void:
	# _process runs before Config.data is guaranteed seated on some boot paths.
	assert_false(HeadlightCone.has_headlights(null), "no config -> no cone, not a crash")
	assert_eq(HeadlightCone.amount(null), 0.0, "and no strength to push")


func test_params_are_empty_on_a_condition_with_no_cone() -> void:
	# An empty dictionary is what makes push() fall through to reset(), which is the
	# mechanism that keeps every unlit stage bit-for-bit unchanged.
	var cfg := GameConfig.new()
	assert_true(HeadlightCone.params(cfg, Transform3D.IDENTITY).is_empty(),
		"a dry stage produces no cone parameters at all")


func test_every_authored_headlight_strength_is_a_real_unit_field() -> void:
	# The shipped table iterated as OPAQUE input — no condition named, no value pinned.
	# A typo'd field name would make cfg.get() return null and silently disarm the cone
	# on that condition; a strength outside 0..1 would clip the lit pool to white.
	var cfg := GameConfig.new()
	for entry in WeatherLibrary.all():
		if not entry.has("headlights"):
			continue
		var field := String(entry["headlights"])
		var value = cfg.get(field)
		assert_true(value is float,
			"'%s' names a real float field '%s'" % [String(entry.get("id", "")), field])
		assert_between(float(value), 0.0, 1.0,
			"'%s' authors a strength in the unit range" % String(entry.get("id", "")))


# --- the cone follows the car ------------------------------------------------

func test_the_cone_points_where_the_car_points() -> void:
	# Forward is -basis.z (Godot convention). A sign error here would light the road
	# BEHIND the car, which is the single most likely way to get this wrong.
	var cfg := _night_cfg()
	cfg.headlight_pitch_deg = 0.0  # isolate the yaw; the downward aim is tested separately
	var vals := HeadlightCone.params(cfg, Transform3D.IDENTITY)
	assert_almost_eq(vals[HeadlightCone.G_DIR] as Vector3, Vector3(0, 0, -1), Vector3.ONE * 0.001,
		"an unrotated car lights -Z")
	# Yaw a half-turn: the cone must follow, not stay put.
	var turned := Transform3D(Basis(Vector3.UP, PI), Vector3.ZERO)
	var turned_vals := HeadlightCone.params(cfg, turned)
	assert_almost_eq(turned_vals[HeadlightCone.G_DIR] as Vector3, Vector3(0, 0, 1),
		Vector3.ONE * 0.001, "a car turned around lights +Z")


func test_the_cone_aims_downward_not_upward() -> void:
	# Sign check, and the whole point of the pitch knob: a positive pitch must tilt
	# the cone toward the GROUND. Getting this backwards throws the light at the sky
	# and leaves the road black — and it looks plausible either way in the code.
	var cfg := _night_cfg()
	cfg.headlight_pitch_deg = 10.0
	var dir: Vector3 = HeadlightCone.params(cfg, Transform3D.IDENTITY)[HeadlightCone.G_DIR]
	assert_lt(dir.y, 0.0, "a pitched cone points below the horizon")
	assert_lt(dir.z, 0.0, "and still mostly forward, not straight down")


func test_zero_pitch_is_exactly_horizontal() -> void:
	# The pitch must be a pure addition: authoring 0 has to reproduce the original
	# horizontal aim exactly, so the knob can be tuned back out.
	var cfg := _night_cfg()
	cfg.headlight_pitch_deg = 0.0
	var dir: Vector3 = HeadlightCone.params(cfg, Transform3D.IDENTITY)[HeadlightCone.G_DIR]
	assert_almost_eq(dir, Vector3(0, 0, -1), Vector3.ONE * 0.001, "no pitch, no tilt")


func test_the_pitch_is_relative_to_the_car_not_the_world() -> void:
	# Applied about the car's OWN right axis, so a car nosing over a crest or climbing
	# a slope keeps its lights aimed at the road ahead of it rather than into the dirt
	# or off into the sky. Roll the car and the cone must roll with it.
	var cfg := _night_cfg()
	cfg.headlight_pitch_deg = 10.0
	# Roll 180° about the forward axis: "down" for the car is now world-up.
	var rolled := Transform3D(Basis(Vector3(0, 0, 1), PI), Vector3.ZERO)
	var dir: Vector3 = HeadlightCone.params(cfg, rolled)[HeadlightCone.G_DIR]
	assert_gt(dir.y, 0.0, "an inverted car aims its pitch the other way in world space")


func test_the_cone_direction_is_normalised() -> void:
	# The shader dots against this without normalising, so a scaled basis must not
	# leak a non-unit vector through and silently widen or narrow the cone.
	var cfg := _night_cfg()
	var scaled := Transform3D(Basis().scaled(Vector3(3.0, 3.0, 3.0)), Vector3.ZERO)
	var dir: Vector3 = HeadlightCone.params(cfg, scaled)[HeadlightCone.G_DIR]
	assert_almost_eq(dir.length(), 1.0, 0.001, "direction is a unit vector")


func test_the_apex_tracks_the_car_position() -> void:
	# Whatever the authored offset, moving the car must move the cone apex by the
	# same delta — the offset is car-local, so it cannot introduce a world-space drift.
	var cfg := _night_cfg()
	var at_origin: Vector3 = HeadlightCone.params(cfg, Transform3D.IDENTITY)[HeadlightCone.G_POS]
	var moved := Transform3D(Basis(), Vector3(10.0, 2.0, -5.0))
	var at_moved: Vector3 = HeadlightCone.params(cfg, moved)[HeadlightCone.G_POS]
	assert_almost_eq(at_moved - at_origin, Vector3(10.0, 2.0, -5.0), Vector3.ONE * 0.001,
		"the apex moves with the car, one-for-one")


func test_the_apex_offset_rotates_with_the_car() -> void:
	# The offset is applied along the car's OWN axes. If it were applied in world
	# space the cone would slide off the bonnet as the car turned.
	var cfg := _night_cfg()
	cfg.headlight_offset_m = Vector3(0.0, 0.0, 2.0)  # 2 m forward
	var ahead: Vector3 = HeadlightCone.params(cfg, Transform3D.IDENTITY)[HeadlightCone.G_POS]
	assert_almost_eq(ahead, Vector3(0, 0, -2.0), Vector3.ONE * 0.001,
		"forward offset lands ahead of an unrotated car")
	var turned := Transform3D(Basis(Vector3.UP, PI), Vector3.ZERO)
	var behind: Vector3 = HeadlightCone.params(cfg, turned)[HeadlightCone.G_POS]
	assert_almost_eq(behind, Vector3(0, 0, 2.0), Vector3.ONE * 0.001,
		"the same offset follows the car around")


# --- lamp separation follows the car ------------------------------------------

func test_a_wider_car_gets_wider_spaced_lamps() -> void:
	# The separation is a FRACTION of the fielded car's width, not an absolute figure,
	# so the lamps sit on the body of whatever is fielded rather than at one spacing
	# every car has to live with. Behaviour, not a value: wider car, wider pair.
	var cfg := _night_cfg()
	var narrow: float = HeadlightCone.params(cfg, Transform3D.IDENTITY, 1.5)[HeadlightCone.G_SEPARATION]
	var wide: float = HeadlightCone.params(cfg, Transform3D.IDENTITY, 2.0)[HeadlightCone.G_SEPARATION]
	assert_gt(wide, narrow, "a wider car spaces its lamps further apart")
	assert_gt(narrow, 0.0, "a fielded car has a real separation")


func test_an_unfielded_car_collapses_to_a_single_cone() -> void:
	# car.gd::half_width returns 0 before a car is fielded, which the world's _ready
	# seed push hits. Zero separation is the shader's single-cone path, so that frame
	# renders one cone rather than two coincident ones or a NaN.
	var cfg := _night_cfg()
	assert_eq(HeadlightCone.params(cfg, Transform3D.IDENTITY, 0.0)[HeadlightCone.G_SEPARATION], 0.0,
		"no known width -> a single cone")


func test_separation_can_be_authored_off() -> void:
	# 0 is the documented single-cone setting and the cheaper path on terrain, so it
	# must survive whatever the car's width is.
	var cfg := _night_cfg()
	cfg.headlight_separation_frac = 0.0
	assert_eq(HeadlightCone.params(cfg, Transform3D.IDENTITY, 2.0)[HeadlightCone.G_SEPARATION], 0.0,
		"authoring the fraction to zero collapses the pair whatever the car")


func test_the_lamp_axis_is_the_cars_right_and_is_normalised() -> void:
	# The shader offsets the two apexes along this, so a non-unit vector would scale
	# the separation on top of the authored fraction.
	var cfg := _night_cfg()
	var scaled := Transform3D(Basis().scaled(Vector3(4.0, 4.0, 4.0)), Vector3.ZERO)
	var right: Vector3 = HeadlightCone.params(cfg, scaled, 1.8)[HeadlightCone.G_RIGHT]
	assert_almost_eq(right.length(), 1.0, 0.001, "the lamp axis is a unit vector")
	# Yawing the car must swing the lamp axis with it, or the pair would stay aligned
	# to the world and shear across the bonnet as the car turns.
	var turned := Transform3D(Basis(Vector3.UP, PI), Vector3.ZERO)
	var turned_right: Vector3 = HeadlightCone.params(cfg, turned, 1.8)[HeadlightCone.G_RIGHT]
	assert_almost_eq(turned_right, Vector3(-1, 0, 0), Vector3.ONE * 0.001,
		"the lamp axis turns with the car")


# --- edge cases the shader relies on -----------------------------------------

func test_the_outer_edge_is_always_wider_than_the_inner_edge() -> void:
	# The shader does smoothstep(cos_outer, cos_inner, ...), which is undefined-ish
	# if the edges are equal or inverted. Wider angle == SMALLER cosine, so outer
	# must always come out strictly below inner however the two are authored —
	# including the degenerate case of someone setting outer narrower than inner.
	var cfg := _night_cfg()
	cfg.headlight_inner_deg = 30.0
	cfg.headlight_outer_deg = 10.0  # deliberately inverted
	var vals := HeadlightCone.params(cfg, Transform3D.IDENTITY)
	assert_lt(vals[HeadlightCone.G_COS_OUTER] as float, vals[HeadlightCone.G_COS_INNER] as float,
		"outer cosine stays strictly below inner even when authored backwards")


func test_the_range_is_never_zero() -> void:
	# The shader divides the distance by this range; a zero would produce a NaN and
	# blow out the whole frame rather than simply showing nothing.
	var cfg := _night_cfg()
	cfg.headlight_range_m = 0.0
	assert_gt(HeadlightCone.params(cfg, Transform3D.IDENTITY)[HeadlightCone.G_RANGE] as float, 0.0,
		"range is clamped above zero")


func test_strength_is_clamped_to_unit_range() -> void:
	# The shader multiplies the cone by this and adds the result to the light term, so
	# an over-1 value would clip the lit pool to white rather than simply looking bright.
	var cfg := _night_cfg()
	cfg.night_headlight_amount = 5.0
	assert_eq(HeadlightCone.params(cfg, Transform3D.IDENTITY)[HeadlightCone.G_AMOUNT], 1.0,
		"over-bright authoring clamps to 1")
	cfg.night_headlight_amount = -1.0
	assert_true(HeadlightCone.params(cfg, Transform3D.IDENTITY).is_empty(),
		"negative authoring reads as lights-off, not as a negative cone")


# --- the weather entry -------------------------------------------------------

func test_night_authors_every_look_key() -> void:
	# world.gd reads the five LOOK_KEYS as an unguarded set, so a partially authored
	# look block would crash the stage boot rather than degrade.
	var entry := WeatherLibrary.by_id(RallyLibrary.WEATHER_NIGHT)
	assert_eq(String(entry.get("id", "")), RallyLibrary.WEATHER_NIGHT, "the night entry exists")
	var look: Dictionary = entry.get("look", {})
	for key in WeatherLibrary.LOOK_KEYS:
		assert_true(look.has(key), "night authors the '%s' look key" % key)


func test_night_is_purely_a_look_and_never_touches_physics() -> void:
	# Decision 4 of the spec, pinned: night must contribute nothing to
	# physics_fields, which keys the opponent cache. If it ever did, every night
	# stage would silently invalidate cached opponent times and need rebalancing.
	var entry := WeatherLibrary.by_id(RallyLibrary.WEATHER_NIGHT)
	assert_false(entry.has("grip_mult"), "night does not scale grip")
	assert_false(entry.has("wind"), "night has no wind")
	assert_false(entry.has("particles"), "night constructs no particle field")
	assert_eq(WeatherLibrary.physics_fields(entry), [],
		"night names no physics field, so it cannot churn the opponent cache")
	var cfg := GameConfig.new()
	assert_eq(WeatherLibrary.grip_mult(cfg, RallyLibrary.WEATHER_NIGHT), 1.0,
		"grip on a night stage is exactly dry")


func test_the_dark_conditions_switch_the_headlights_on() -> void:
	# The two conditions dark enough for a driver to reach for the lights. Structure
	# only: that each arms the cone at all, never how brightly — the strengths differ
	# (each condition's world is dark to a different degree) and are inspector tuning.
	for id in [RallyLibrary.WEATHER_NIGHT, RallyLibrary.WEATHER_STORM]:
		var cfg := GameConfig.new()
		cfg.weather = id
		assert_true(HeadlightCone.has_headlights(cfg), "'%s' switches the lights on" % id)


func test_the_headlight_cone_never_touches_physics() -> void:
	# The cone is a look, on every condition that has one: it re-lights a wedge and
	# changes no grip and no force, so it must never reach physics_fields() and re-key
	# the opponent cache. Nothing about switching the lights on rebalances a stage.
	for entry in WeatherLibrary.all():
		if not entry.has("headlights"):
			continue
		assert_false(WeatherLibrary.physics_fields(entry).has(String(entry["headlights"])),
			"'%s' keeps its cone out of the physics fields" % String(entry.get("id", "")))


# --- the night sky override ---------------------------------------------------

func test_night_names_a_sky_and_no_other_condition_does() -> void:
	# Night is the only condition that REPLACES the sky — rain and dust are things
	# happening under the region's sky, night is a different sky. The key is optional
	# by design, so this pins that the mechanism stays opt-in rather than becoming a
	# sixth mandatory look key every existing entry would have to author.
	var night := WeatherLibrary.by_id(RallyLibrary.WEATHER_NIGHT)
	var field := String(night.get("sky_panorama", ""))
	assert_ne(field, "", "night names a sky field")
	var cfg := GameConfig.new()
	assert_true(cfg.get(field) is String, "and it names a real GameConfig field")
	assert_ne(String(cfg.get(field)), "", "which holds a path")
	for entry in WeatherLibrary.all():
		if String(entry.get("id", "")) == RallyLibrary.WEATHER_NIGHT:
			continue
		assert_false(entry.has("sky_panorama"),
			"'%s' leaves the region's sky alone" % String(entry.get("id", "")))


func test_there_is_a_default_sky_for_regions_that_name_none() -> void:
	# home / home_coast author no sky_panorama. The region look now assigns
	# unconditionally, falling back to this — which is what stops a Greece or night
	# sky following the player into the next home stage, since the PanoramaSkyMaterial
	# is a shared main.tscn sub-resource. An empty default would reintroduce the leak.
	var cfg := GameConfig.new()
	assert_ne(cfg.default_sky_panorama, "", "a fallback sky exists")
	assert_true(ResourceLoader.exists(cfg.default_sky_panorama),
		"and it points at a real resource")
	assert_true(ResourceLoader.exists(cfg.night_sky_panorama),
		"the night sky resource exists too")


# --- the car dims with the world ---------------------------------------------

func test_car_light_scales_with_the_weather_sun_multiplier() -> void:
	# The bug night exposed: the terrain bakes sun_energy_mult into its vertex
	# colours but apply_car_light used to push sun_color raw, so the car kept full
	# sunlight while the world dimmed (already visible on rain and storm). Behaviour,
	# not a value: halving the multiplier must halve the car's sun.
	var cfg := GameConfig.new()
	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/ps1_models_lit.gdshader")
	cfg.weather_sun_mult = 1.0
	cfg.apply_car_light(mat)
	var full: Color = mat.get_shader_parameter("sun_color")
	cfg.weather_sun_mult = 0.5
	cfg.apply_car_light(mat)
	var dimmed: Color = mat.get_shader_parameter("sun_color")
	assert_almost_eq(dimmed.r, full.r * 0.5, 0.001, "a dimmer stage dims the car's sun")
	assert_almost_eq(dimmed.g, full.g * 0.5, 0.001, "on every channel")


func test_weather_lit_dims_colour_and_keeps_alpha() -> void:
	# The one place that knows the dimming rule. Alpha must survive untouched — the
	# water shader's colours carry meaningful alpha, and scaling it would turn a dim
	# lake transparent instead of dark.
	var cfg := GameConfig.new()
	cfg.weather_sun_mult = 0.5
	var out := cfg.weather_lit(Color(0.8, 0.6, 0.4, 0.9))
	assert_almost_eq(out.r, 0.4, 0.001, "red halves")
	assert_almost_eq(out.b, 0.2, 0.001, "blue halves")
	assert_almost_eq(out.a, 0.9, 0.001, "alpha is untouched")


func test_foliage_light_dims_with_the_weather() -> void:
	# Trees were lit on their sunward side at night, when there is no sun. The
	# directional term is sun_color * ndl, so dimming sun_color is what removes it.
	var cfg := GameConfig.new()
	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/billboard_opaque.gdshader")
	cfg.weather_sun_mult = 1.0
	cfg.apply_foliage_light(mat)
	var full: Color = mat.get_shader_parameter("sun_color")
	cfg.weather_sun_mult = 0.25
	cfg.apply_foliage_light(mat)
	var dim: Color = mat.get_shader_parameter("sun_color")
	assert_almost_eq(dim.r, full.r * 0.25, 0.001, "a dark stage dims the trees' sun")
	assert_lt(dim.r, full.r, "strictly darker")


func test_foliage_and_car_agree_on_the_light() -> void:
	# Trees, car and terrain must dim together or the scene comes apart — a lit tree
	# beside an unlit car is more obviously wrong than either alone. Pinning that they
	# derive from the same values, not that those values are anything in particular.
	var cfg := GameConfig.new()
	cfg.weather_sun_mult = 0.4
	var tree := ShaderMaterial.new()
	tree.shader = load("res://shaders/billboard_opaque.gdshader")
	var car := ShaderMaterial.new()
	car.shader = load("res://shaders/ps1_models_lit.gdshader")
	cfg.apply_foliage_light(tree)
	cfg.apply_car_light(car)
	var t: Color = tree.get_shader_parameter("sun_color")
	var c: Color = car.get_shader_parameter("sun_color")
	assert_almost_eq(t.r, c.r, 0.001, "trees and car take the same sun")
	assert_almost_eq(t.g, c.g, 0.001, "on every channel")


func test_the_weather_sun_multiplier_defaults_to_no_dimming() -> void:
	# A session-less boot (free roam, benchmark, dev) never runs the weather look, so
	# the default must be the identity or those stages would render dark.
	assert_eq(GameConfig.new().weather_sun_mult, 1.0, "the default is no dimming")


# --- the shaders actually include the cone ------------------------------------

func test_every_night_lit_shader_includes_the_cone() -> void:
	# The cone lives in one .gdshaderinc so the maths cannot drift between shaders.
	# If a shader silently loses the include, its surfaces stay black at night while
	# everything around them lights up — a bug that is obvious in-game and invisible
	# in every other test.
	var lit_at_night: PackedStringArray = [
		"res://shaders/ps1_models.gdshader",
		"res://shaders/ps1_terrain_snow.gdshader",
		"res://shaders/ps1_models_lit.gdshader",
		"res://shaders/billboard_opaque.gdshader",
		"res://shaders/tree_canopy.gdshader",
	]
	for path in lit_at_night:
		var shader: Shader = load(path)
		assert_not_null(shader, "%s loads" % path)
		assert_true(shader.code.contains("headlight_cone.gdshaderinc"),
			"%s includes the shared cone" % path)
		assert_true(shader.code.contains("headlight_lit("),
			"%s actually calls the cone" % path)


func test_the_cone_is_added_to_the_light_term_never_multiplied() -> void:
	# THE critical detail (todo/night-weather-and-headlights.md). At night the light
	# term is baked near-black, so a multiplicative cone cannot re-light it — the
	# headlight would simply not appear. Every use site must ADD.
	var lit_at_night: PackedStringArray = [
		"res://shaders/ps1_models.gdshader",
		"res://shaders/ps1_terrain_snow.gdshader",
		"res://shaders/ps1_models_lit.gdshader",
		"res://shaders/billboard_opaque.gdshader",
		"res://shaders/tree_canopy.gdshader",
	]
	for path in lit_at_night:
		var code: String = (load(path) as Shader).code
		# Two shapes are legitimate: applying headlight_lit() inline, or (tree_canopy)
		# computing it in vertex() and applying hl_color to the carried varying in
		# fragment(). Both must APPEND to the light term — what this rules out is a
		# `* hl_color` anywhere, which is the mistake that would silently produce no
		# visible headlight at all.
		assert_true(code.contains("+ hl_color *") or code.contains("+= hl_color *"),
			"%s adds the cone to the light term" % path)
		assert_false(code.contains("* hl_color"),
			"%s never multiplies by the cone — a dark bake cannot be re-lit that way" % path)


func test_the_terrain_shader_still_has_no_vertex_stage() -> void:
	# The cone is fragment-side on terrain deliberately, and the include declares
	# only globals and a function. Restated here next to the night work so that a
	# future "just move it to the vertex stage for speed" change trips a test whose
	# name says why it exists, not only the far-away render smoke test.
	var code: String = (load("res://shaders/ps1_models.gdshader") as Shader).code
	assert_false(code.contains("void vertex()"),
		"terrain stays free of a vertex stage; cells reach 25 m at the coarsest LOD")
