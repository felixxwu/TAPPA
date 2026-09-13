class_name WindSway
extends RefCounted
# Docs: features/trees.md, features/weather.md
# Tests: tests/headless/test_wind_sway.gd

# Drives the vertex-shader wind sway for billboard trees (shaders/wind_sway.gdshaderinc).
# Pure transport: it converts the live weather condition's authored strength into the
# global shader uniforms that include reads, and nothing else.
#
# THE SAME EVERY CONDITION, EXCEPT STORMS: the base sway (cfg.foliage_wind_strength) is
# what every condition gets unless it names its own "foliage_wind" field in the weather
# table — authored ONLY on storm and sandstorm, so trees read calmer air identically on
# dry, rain, fog, snow and night, and visibly rougher only when the sky itself is
# violent. This is pure authoring, exactly like HeadlightCone's "headlights" key: no
# `weather == "storm"` branch lives here or anywhere downstream.
#
# WHY GLOBALS, not material parameters: foliage materials are built in several scripts
# (foliage.gd, billboard_field.gd) with no common registry, and trees stream in
# continuously as terrain chunks generate — see shaders/wind_sway.gdshaderinc's header
# for the full argument (identical to HeadlightCone's).
#
# THE GLOBALS PERSIST ACROSS SCENES. That is the trap reset() exists to guard: the
# podium and menu showcase render trees with this same shader, so a storm's stronger
# sway must not keep blowing there after a storm stage is exited — see world.gd's
# _exit_tree() and Foliage.spawn_trees()'s base seed.

# Names must match the [shader_globals] block in project.godot and the
# `global uniform` declarations in shaders/wind_sway.gdshaderinc.
const G_STRENGTH := "wind_strength"
const G_SPEED := "wind_speed"
const G_DIR := "wind_dir"


# Sway strength (tip offset as a fraction of tree height) for a weather id. Reads the
# condition's own "foliage_wind" field when the table names one (storm, sandstorm);
# every other condition falls back to the shared base so wind reads the same
# everywhere but a storm. Null cfg => 0.0, matching HeadlightCone.amount's null guard.
static func strength(cfg: GameConfig, id: String) -> float:
	if cfg == null:
		return 0.0
	var entry := WeatherLibrary.by_id(id)
	var field := String(entry.get("foliage_wind", ""))
	var value: float = float(cfg.get(field)) if field != "" else cfg.foliage_wind_strength
	return maxf(value, 0.0)


# Heading (degrees, 0 = world +X, 90 = world +Z — the same convention the particle
# wind and the crosswind force use) trees lean toward. Prefers the condition's own
# "wind_dir" entry (so trees lean the way the rain/dust already streams) and falls
# back to the shared base heading when the condition names none.
static func direction_deg(cfg: GameConfig, id: String) -> float:
	if cfg == null:
		return 0.0
	var entry := WeatherLibrary.by_id(id)
	var field := String(entry.get("wind_dir", ""))
	if field != "":
		return float(cfg.get(field))
	return cfg.foliage_wind_dir_deg


# The sway's maths, as a plain name→value dictionary — split out from push() so it
# can be tested without a live RenderingServer, exactly like HeadlightCone.params.
static func params(cfg: GameConfig, id: String) -> Dictionary:
	if cfg == null:
		return {G_STRENGTH: 0.0, G_SPEED: 0.0, G_DIR: Vector3(1, 0, 0)}
	# Crosswind.direction() is the same deg->unit-vector conversion the storm force
	# and the particle wind use (cos/sin about world +X/+Z) — reused rather than
	# reimplemented so the heading convention can never drift between the two.
	return {
		G_STRENGTH: strength(cfg, id),
		G_SPEED: cfg.foliage_wind_speed,
		G_DIR: Crosswind.direction(direction_deg(cfg, id)),
	}


# Push the sway for the given weather id.
static func push(cfg: GameConfig, id: String) -> void:
	var vals := params(cfg, id)
	for name in vals:
		RenderingServer.global_shader_parameter_set(name, vals[name])


# Push the BASE (dry) wind — used by non-stage scenes (podium, menu showcase) so
# their trees sway too, at the shared everyday strength rather than 0 or a leaked
# storm value.
static func base(cfg: GameConfig) -> void:
	push(cfg, WeatherLibrary.DEFAULT_ID)


# Seed the base wind ONLY if nothing has pushed one yet (the global is still at its
# project.godot default of 0). Called from Foliage.spawn_trees, the one call site for
# every tree field in the game, so a scene that never thinks about weather still gets
# living trees.
#
# THE GUARD IS LOAD-BEARING, not a micro-optimisation. On a stage, world.gd pushes the
# condition's own strength from _apply_weather_look BEFORE _generate_track scatters the
# trees — an unconditional base() here would land afterwards and quietly flatten a
# storm back to calm. Reading the live global instead of tracking a flag is what makes
# that ordering-proof: reset() leaves the base behind on stage exit, so by the time a
# podium or showcase spawns, the value is already non-zero and this is a no-op.
static func seed_base(cfg: GameConfig) -> void:
	var current: Variant = RenderingServer.global_shader_parameter_get(G_STRENGTH)
	if current != null and float(current) > 0.0:
		return
	base(cfg)


# Reset to the base wind, NOT to zero. Unlike the headlight cone (which must go dark
# off-stage), foliage outside a stage should still be alive — a perfectly still podium
# tree next to a swaying stage one would read as a bug, not a feature. What this DOES
# clear is a storm/sandstorm strength leaking into the next scene: reset() always
# lands back on the shared base, never on whatever the last stage authored.
static func reset() -> void:
	if Config.data != null:
		base(Config.data)
	else:
		RenderingServer.global_shader_parameter_set(G_STRENGTH, 0.0)
