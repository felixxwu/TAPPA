class_name BiomeDirector
extends Node
# Docs: features/free-roam.md — update in the same change as this file.
# Tests: tests/headless/test_free_roam_biomes.gd — extend in the same change.
# Position-based biome state for free roam (todo/2026-10-19-free-roam-pivot.md, stage 4). The
# stage applies a region's look and weather once per scene; here they follow the car:
#
#   * Ring → region. Ring i wears region FreeRoamSettings.ring_regions[i]. Crossing into a ring
#     writes that region's HANDLING (surface grip, deep snow, frozen lakes) onto the live config,
#     re-seeded from the authored values first, so leaving a ring puts its grip back.
#   * Weather drifts. Drive time is cut into slots of `weather_hold_s`; each (ring, slot) draws a
#     condition from the ring's weighted pool (`ring_weather`), seeded from the world seed, so the
#     weather changes every few minutes and differs per biome.
#   * The environment cross-fades. Whenever the target changes (new ring or new weather), the fog
#     and background colours, fog density and sky affect blend to the new target over
#     `look_crossfade_s`. The panorama can't blend, so it swaps at the middle of the fade,
#     when the fog is thickest.
#   * Ring side effects: the wheel debris's off-road particle colour and shape (grass blades,
#     the snow ring's powder clods), from the region look.
#   * Weather side effects: particles on the chase camera, the road tint on every ring's ground
#     material, wind sway, the car's sun dimming and the night headlight cone.
#
# Everything global it writes (cfg.weather, the grip fields, weather_sun_mult, the headlight and
# wind shader globals) is put back on _exit_tree, like world.gd does for a stage.

const CHECK_EVERY_S := 0.25
# Fog thickening at the middle of a cross-fade, hiding the panorama swap.
const SWAP_FOG_SWELL := 2.5

@export var streamer: TerrainStreamer
@export var car: VehicleBody3D
@export var environment: WorldEnvironment
@export var camera: Camera3D

# The car's wheel debris (free_roam.gd creates it). A new ring re-seats its off-road particle
# colour and shape from the ring's region look, the way world.gd does once per stage.
var wheel_particles: WheelParticles = null

var ring := -1
var weather := ""
var drive_time := 0.0

var _check_t := 0.0
var _base_env := {}
var _from := {}
var _to := {}
var _fade_t := -1.0
var _swapped := true
var _particles: Node = null
# The ground colours the weather tints; the _b pair is the outer ring's on a border chunk.
const TINTED := ["albedo_color", "tarmac_color", "albedo_color_b", "tarmac_color_b"]
var _base_colors := {}  # ShaderMaterial -> TINTED's colours as authored


func _ready() -> void:
	if environment == null or environment.environment == null:
		return
	var env := environment.environment
	Config.data.apply_environment(env)  # the weather and region looks fade from this base
	_base_env = {"bg": env.background_color, "fog": env.fog_light_color, "density": env.fog_density,
		"sky_affect": env.fog_sky_affect, "panorama": _panorama()}


func _process(delta: float) -> void:
	if streamer == null or car == null:
		return
	drive_time += delta
	_check_t -= delta
	if _check_t <= 0.0:
		_check_t = CHECK_EVERY_S
		update_now()
	_step_fade(delta)
	if HeadlightCone.has_headlights(Config.data):
		HeadlightCone.push(Config.data, car.global_transform, car.half_width() * 2.0 if car.has_method("half_width") else 1.8)


# Re-read the car's ring and the weather slot, and apply whatever changed.
func update_now() -> void:
	var p := car.global_position
	var r := streamer.terrain.ring_index(p.x, p.z)
	var w := weather_for(streamer.settings, r, drive_time)
	if r == ring and w == weather:
		return
	var ring_changed := r != ring
	ring = r
	if ring_changed:
		apply_handling(Config.data, region_of(streamer.settings, ring))
		_wire_water()
		_seat_particle_look()
	if w != weather:
		weather = w
		_apply_weather(Config.data)
	_start_fade(target_look(Config.data, region_of(streamer.settings, ring), weather, _base_env))


# Write the current ring's handling and weather onto the config again, after a car retune put the
# authored values back.
func reapply() -> void:
	if ring < 0:
		return
	var region := region_of(streamer.settings, ring)
	apply_handling(Config.data, region)
	Config.data.weather = weather
	Config.data.weather_sun_mult = float(target_look(Config.data, region, weather, _base_env).get("sun_mult", 1.0))


# The wheel debris's off-road particle (colour, blade or clod) for the ring's region; the default
# blade where the region authors none.
func _seat_particle_look() -> void:
	if wheel_particles != null:
		wheel_particles.apply_region_look(RegionLibrary.look_of(region_of(streamer.settings, ring)))


# The region a ring wears: ring_regions[i], wrapping; the authored progression if the list is empty.
static func region_of(s: FreeRoamSettings, r: int) -> String:
	if not s.ring_regions.is_empty():
		return s.ring_regions[posmod(r, s.ring_regions.size())]
	var regions := RegionLibrary.ordered()
	return String(regions[posmod(r, regions.size())]["id"])


# The weather for ring `r` at `t` seconds of driving: a weighted draw from the ring's pool,
# fixed for the whole slot of weather_hold_s it falls in.
static func weather_for(s: FreeRoamSettings, r: int, t: float) -> String:
	var pool := parse_pool(s.ring_weather[posmod(r, s.ring_weather.size())] if not s.ring_weather.is_empty() else "")
	if pool.is_empty():
		return WeatherLibrary.DEFAULT_ID
	var slot := floori(t / maxf(s.weather_hold_s, 1.0))
	var total := 0.0
	for e: Array in pool:
		total += float(e[1])
	var x := ScatterMath.hash01(slot, r, s.world_seed, 919) * total
	for e: Array in pool:
		x -= float(e[1])
		if x < 0.0:
			return String(e[0])
	return String(pool[pool.size() - 1][0])


# "dry:4,rain:1" → [["dry", 4.0], ["rain", 1.0]]. Unknown condition ids and non-positive weights
# are dropped, so a typo can't select a weather that doesn't exist.
static func parse_pool(text: String) -> Array:
	var out: Array = []
	for part in text.split(",", false):
		var kv := part.strip_edges().split(":")
		var id := kv[0].strip_edges()
		var weight := float(kv[1]) if kv.size() > 1 else 1.0
		if weight > 0.0 and not WeatherLibrary.by_id(id).is_empty() and WeatherLibrary.by_id(id)["id"] == id:
			out.append([id, weight])
	return out


# Write a region's handling onto the live config, from the authored values (so leaving the snow
# ring puts every other ring's grip back).
static func apply_handling(cfg: GameConfig, region_id: String) -> void:
	var base: GameConfig = load(Config.CONFIG_PATH)
	var sgrip := RegionLibrary.surface_grip_of(base, region_id)
	cfg.grass_grip = float(sgrip.get("grass", base.grass_grip))
	cfg.gravel_grip = float(sgrip.get("gravel", base.gravel_grip))
	cfg.tarmac_grip = float(sgrip.get("tarmac", base.tarmac_grip))
	var deep := RegionLibrary.deep_snow_of(base, region_id)
	cfg.deep_snow_drag = float(deep.get("drag", 0.0))
	cfg.deep_snow_depth_m = float(deep.get("depth", 0.0))
	cfg.frozen_water_grip = float(RegionLibrary.frozen_water_of(base, region_id).get("grip", 0.0))


# The environment a region + weather pair should end up at: the region's background colour (or
# the scene's authored one), then the weather's overcast look on top, and the weather's or the
# region's panorama.
static func target_look(cfg: GameConfig, region_id: String, weather_id: String, base_env: Dictionary) -> Dictionary:
	var look := RegionLibrary.look_of(region_id)
	var bg: Color = look.get("background_color", base_env.get("bg", Color.GRAY))
	var out := {"bg": bg, "fog": look.get("background_color", base_env.get("fog", bg)),
		"density": float(base_env.get("density", cfg.fog_density)), "sky_affect": float(base_env.get("sky_affect", 0.15)),
		"panorama": String(look.get("sky_panorama", cfg.default_sky_panorama)), "sun_mult": 1.0}
	var entry := WeatherLibrary.by_id(weather_id)
	var wl: Dictionary = entry.get("look", {})
	if not wl.is_empty():
		var wbg: Color = cfg.get(String(wl["background_color"]))
		out["bg"] = wbg
		out["fog"] = wbg
		out["density"] = float(out["density"]) * float(cfg.get(String(wl["fog_density_mult"])))
		out["sky_affect"] = float(cfg.get(String(wl["fog_sky_affect"])))
		out["sun_mult"] = float(cfg.get(String(wl["sun_energy_mult"])))
	var sky_field := String(entry.get("sky_panorama", ""))
	if sky_field != "" and String(cfg.get(sky_field)) != "":
		out["panorama"] = String(cfg.get(sky_field))
	return out


func _start_fade(target: Dictionary) -> void:
	var env := environment.environment if environment != null else null
	if env == null:
		return
	_from = {"bg": env.background_color, "fog": env.fog_light_color, "density": env.fog_density,
		"sky_affect": env.fog_sky_affect}
	_to = target
	_swapped = String(target.get("panorama", "")) == _panorama()
	_fade_t = 0.0
	Config.data.weather_sun_mult = float(target.get("sun_mult", 1.0))


func _step_fade(delta: float) -> void:
	if _fade_t < 0.0 or environment == null:
		return
	var dur := maxf(streamer.settings.look_crossfade_s, 0.01)
	_fade_t = minf(_fade_t + delta, dur)
	var k := smoothstep(0.0, 1.0, _fade_t / dur)
	var env := environment.environment
	env.background_color = (_from["bg"] as Color).lerp(_to["bg"], k)
	env.fog_light_color = (_from["fog"] as Color).lerp(_to["fog"], k)
	var swell := 1.0 if _swapped else 1.0 + (SWAP_FOG_SWELL - 1.0) * sin(PI * k)
	env.fog_density = lerpf(_from["density"], _to["density"], k) * swell
	env.fog_sky_affect = lerpf(_from["sky_affect"], _to["sky_affect"], k)
	if not _swapped and k >= 0.5:
		_swapped = true
		_set_panorama(String(_to["panorama"]))
	if _fade_t >= dur:
		_fade_t = -1.0
		env.fog_density = _to["density"]


func is_fading() -> bool:
	return _fade_t >= 0.0


func _panorama() -> String:
	var sky_mat := _sky_material()
	return sky_mat.panorama.resource_path if sky_mat != null and sky_mat.panorama != null else ""


func _set_panorama(path: String) -> void:
	var sky_mat := _sky_material()
	if sky_mat != null and path != "" and ResourceLoader.exists(path):
		sky_mat.panorama = load(path)


func _sky_material() -> PanoramaSkyMaterial:
	var env := environment.environment if environment != null else null
	if env == null or env.sky == null:
		return null
	return env.sky.sky_material as PanoramaSkyMaterial


# The weather's own side effects, outside the cross-faded environment.
func _apply_weather(cfg: GameConfig) -> void:
	cfg.weather = weather
	WindSway.push(cfg, weather)
	var entry := WeatherLibrary.by_id(weather)
	# road tint, from the authored ground colours each time so changes never compound
	var tint: Dictionary = entry.get("road_tint", {})
	for mat in streamer.ring_materials():
		if not _base_colors.has(mat):
			_base_colors[mat] = TINTED.map(func(p: String): return mat.get_shader_parameter(p))
		var base: Array = _base_colors[mat]
		for k in TINTED.size():
			var col: Color = base[k] if base[k] != null else Color.WHITE
			if not tint.is_empty():
				var color_field := String(tint.get("color", ""))
				col = WeatherLibrary.tinted(col, float(cfg.get(String(tint["amount"]))),
					cfg.get(color_field) if color_field != "" else Color.BLACK, color_field != "")
			mat.set_shader_parameter(TINTED[k], col)
	# particles on the chase camera
	if is_instance_valid(_particles):
		_particles.queue_free()
	_particles = null
	var kind := String(entry.get("particles", ""))
	if kind != "" and camera != null:
		var wind_field := String(entry.get("wind_dir", ""))
		var speed_field := String(entry.get("particle_speed", ""))
		_particles = WeatherField.spawn(camera, kind, int(cfg.get(String(entry["particle_count"]))),
			float(cfg.get(wind_field)) if wind_field != "" else 0.0,
			float(cfg.get(speed_field)) if speed_field != "" else 0.0)
	if not HeadlightCone.has_headlights(cfg):
		HeadlightCone.reset()


# Lakes slow the car (the stage's soft water hazard), unless this ring's lakes are frozen, which
# the tyre model handles as ice instead.
func _wire_water() -> void:
	if not car.has_method("set_water_query"):
		return
	if Config.data.frozen_water_grip > 0.0:
		car.set_water_query(Callable())
	else:
		var wl := streamer.settings.water_level_m
		var st := streamer
		car.set_water_query(func(p: Vector3) -> bool: return st.height_at(p.x, p.z) < wl)


func _exit_tree() -> void:
	if is_instance_valid(_particles):
		_particles.queue_free()
	HeadlightCone.reset()
	WindSway.reset()
	var cfg: GameConfig = Config.data
	cfg.weather_sun_mult = 1.0
	cfg.weather = WeatherLibrary.DEFAULT_ID
	apply_handling(cfg, "")
