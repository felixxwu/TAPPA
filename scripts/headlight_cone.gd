class_name HeadlightCone
extends RefCounted

# Drives the fake headlight cone for the weather conditions that switch the car's
# lights on (todo/night-weather-and-headlights.md). Pure transport: it converts the
# car's pose plus the authored GameConfig knobs into the global shader uniforms that
# shaders/headlight_cone.gdshaderinc reads, and nothing else.
#
# WHICH CONDITIONS light up is NOT decided here — it is the weather table's
# "headlights" key (WeatherLibrary.headlight_amount), so a condition switching the
# lights on is pure authoring, exactly like its look block or its road tint. Night
# authors full strength; storm authors much less, because a storm's world is a dimmed
# DAY and the cone is ADDED on top of that light term, so night's strength there would
# blow the lit pool out to white.
#
# WHY GLOBALS, not material parameters: the materials that read the cone are built
# in five different scripts (terrain_manager, billboard_field, foliage, sign_field,
# mesh_util) with no common registry, and terrain chunks stream in continuously, so
# a per-material push would need re-registration bookkeeping on every chunk load.
# There are only ~10-30 live materials, so this is a correctness choice rather than
# a performance one — globals cannot go stale when a chunk appears mid-frame.
#
# THE GLOBALS PERSIST ACROSS SCENES. That is the trap this class exists to guard:
# the podium and the HQ render trees and ground with the same shaders, so a lit
# stage that did not clear up after itself would leave a stray cone burning there. world.gd
# calls reset() from _exit_tree(), which covers every exit path regardless of
# destination.

# Names must match the [shader_globals] block in project.godot and the
# `global uniform` declarations in shaders/headlight_cone.gdshaderinc.
const G_POS := "hl_pos"
const G_DIR := "hl_dir"
const G_RIGHT := "hl_right"
const G_SEPARATION := "hl_separation"
const G_COLOR := "hl_color"
const G_RANGE := "hl_range"
const G_COS_INNER := "hl_cos_inner"
const G_COS_OUTER := "hl_cos_outer"
const G_AMOUNT := "headlight_amount"


# The cone's strength for the stage's live condition, 0..1, straight out of the weather
# table. 0 means the lights are off (no condition here authors a cone, or none is
# seated at all), and is what every other function gates on.
static func amount(cfg: GameConfig) -> float:
	if cfg == null:
		return 0.0
	return WeatherLibrary.headlight_amount(cfg, cfg.weather)


# True when the stage's weather switches the car's headlights on. Deliberately reads
# the AMOUNT rather than testing a weather id: which conditions light up is authored in
# the table, so adding a third one needs no change here (and none of the "no consumer
# tests == WEATHER_x" rule is broken). A condition authored at exactly 0 is off, which
# is the honest answer — the shaders would render nothing either way.
static func has_headlights(cfg: GameConfig) -> bool:
	return amount(cfg) > 0.0


# The cone's maths, as a plain name→value dictionary. Split out from push() so it
# can be tested without a live RenderingServer (headless returns nothing useful for
# global parameter reads) — push() is then pure transport with no logic to get wrong.
# Returns an EMPTY dictionary on a stage whose condition authors no cone.
static func params(cfg: GameConfig, xform: Transform3D, car_width_m: float = 0.0) -> Dictionary:
	var strength := amount(cfg)
	if strength <= 0.0:
		return {}
	var basis := xform.basis
	var forward := -basis.z.normalized()
	# Offset is car-LOCAL (x right, y up, z forward) so the apex sits on the bonnet
	# line and turns with the car rather than sliding around it.
	var off: Vector3 = cfg.headlight_offset_m
	var apex: Vector3 = xform.origin + basis.x * off.x + basis.y * off.y + forward * off.z
	# Aim the cone DOWN by the authored pitch, about the car's own right axis so the
	# tilt stays relative to the car on a slope or over a crest. Without this the cone
	# runs parallel to the ground and the lit pool only begins where the outer edge
	# descends to ground level, several metres ahead of the bumper.
	forward = forward.rotated(basis.x.normalized(), -deg_to_rad(cfg.headlight_pitch_deg))
	# Half-angles are authored in degrees because that is what a designer can reason
	# about; the shader compares cosines so the conversion happens once here rather
	# than per fragment. Outer is forced strictly wider than inner (a SMALLER cosine),
	# so the shader's smoothstep can never get an inverted or degenerate edge pair
	# however the two are authored.
	var inner_deg: float = cfg.headlight_inner_deg
	var outer_deg: float = maxf(cfg.headlight_outer_deg, inner_deg + 0.5)
	var col: Color = cfg.headlight_color
	# Lamp separation is a fraction of the FIELDED CAR'S width, so the pair sits on
	# the body rather than at some fixed spacing every car has to live with. A car
	# that has not been fielded yet reports zero width (car.gd → half_width), which
	# collapses cleanly to a single cone for that frame — _process corrects it on the
	# next one, so the only case this affects is the seed push during _ready.
	var separation: float = maxf(car_width_m, 0.0) * cfg.headlight_separation_frac
	return {
		G_POS: apex,
		G_DIR: forward,
		G_RIGHT: basis.x.normalized(),
		G_SEPARATION: separation,
		G_COLOR: Vector3(col.r, col.g, col.b),
		G_RANGE: maxf(cfg.headlight_range_m, 0.001),
		G_COS_INNER: cos(deg_to_rad(inner_deg)),
		G_COS_OUTER: cos(deg_to_rad(outer_deg)),
		G_AMOUNT: strength,
	}


# Push the cone for a car pose. `xform` is the car's global transform; forward is
# -basis.z (Godot convention, matching world.gd's camera maths).
static func push(cfg: GameConfig, xform: Transform3D, car_width_m: float = 0.0) -> void:
	var vals := params(cfg, xform, car_width_m)
	if vals.is_empty():
		reset()
		return
	for name in vals:
		RenderingServer.global_shader_parameter_set(name, vals[name])


# Zero the cone. headlight_amount == 0 makes headlight_lit() return exactly 0.0, so
# every shader that includes the cone is a bit-for-bit no-op again. Safe to call
# when no cone was ever pushed, and safe to call repeatedly.
static func reset() -> void:
	RenderingServer.global_shader_parameter_set(G_AMOUNT, 0.0)
