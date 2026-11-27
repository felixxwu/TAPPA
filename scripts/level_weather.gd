class_name LevelWeather
extends Node
# Docs: features/weather.md — update in the same change as this file.
# Tests: tests/headless/test_level_weather.gd — extend in the same change.
# Drifts the Hafren level between weather conditions and cross-fades fog, sky and brightness; it writes nothing between fades.

const SWAP_FOG_SWELL := 2.5
const SNOW_AT := 0.5
const G_LIGHT := "world_light"
# How far through a fade the driver reacts and switches the headlights to suit the new weather.
const LIGHTS_AT := 0.85

var view: LevelView
var snow_fn: Callable
# Static so the weather carries on across the level's reloads (buying parts, changing cars, graphics settings).
static var forced_weather := ""
static var seed_value := 0
static var drive_time := 0.0
var _slot := -1
var _slot_id := ""
var _shown := ""
var _env: Environment
var _base := {}
var _from := {}
var _to := {}
var _light := 1.0
var _fade_t := -1.0
var _swapped := true


# Adds the weather node beside the view, once, and starts the level's configured condition.
static func attach(level: LevelView, snow: Callable) -> void:
	var parent := level.get_parent()
	var node := parent.get_node_or_null("LevelWeather") as LevelWeather
	if node == null:
		node = LevelWeather.new()
		node.name = "LevelWeather"
		node.view = level
		node.snow_fn = snow
		if seed_value == 0:
			seed_value = randi() | 1
		parent.add_child(node)
	node.start()


# Shader globals outlive the scene, so leaving the level puts the brightness back to full day.
static func reset() -> void:
	RenderingServer.global_shader_parameter_set(G_LIGHT, Vector3.ONE)
	Config.data.lights_weather = ""


# The weather for a hold slot: slot 0 is `first`, and each later slot is a weighted pick that never repeats the one before.
static func draw(pool_text: String, seed_value_: int, slot: int, first: String = WeatherLibrary.DEFAULT_ID) -> String:
	var pool := parse_pool(pool_text)
	if pool.is_empty():
		return WeatherLibrary.DEFAULT_ID
	var id := first
	for s in range(1, slot + 1):
		var others := pool.filter(func(e: Array) -> bool: return e[0] != id)
		id = _pick(others if not others.is_empty() else pool, seed_value_, s)
	return id


# A weather pool string ("clear:3, rain:1") as [id, weight] pairs, dropping unknown ids and empty weights.
static func parse_pool(text: String) -> Array:
	var out: Array = []
	for part in text.split(",", false):
		var kv := part.strip_edges().split(":")
		var id := kv[0].strip_edges()
		var weight := float(kv[1]) if kv.size() > 1 else 1.0
		if weight > 0.0 and not WeatherLibrary.by_id(id).is_empty() and WeatherLibrary.by_id(id)["id"] == id:
			out.append([id, weight])
	return out


# The environment a weather should end up at: the scene's authored colours, then the weather's overcast look on top.
static func target_look(cfg: GameConfig, weather_id: String, base_env: Dictionary) -> Dictionary:
	var bg: Color = base_env.get("bg", Color.GRAY)
	var out := {"bg": bg, "fog": base_env.get("fog", bg),
		"density": float(base_env.get("density", cfg.fog_density)), "sky_affect": float(base_env.get("sky_affect", 0.15)),
		"panorama": cfg.default_sky_panorama, "sun_mult": 1.0}
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


static func _pick(pool: Array, seed_value_: int, slot: int) -> String:
	var total := 0.0
	for e: Array in pool:
		total += float(e[1])
	var x := ScatterMath.hash01(slot, 0, seed_value_, 919) * total
	for e: Array in pool:
		x -= float(e[1])
		if x < 0.0:
			return String(e[0])
	return String(pool[pool.size() - 1][0])


# Rain is snow inside the snow biome.
static func resolve(id: String, snow: float) -> String:
	return WeatherLibrary.WEATHER_SNOW if id == "rain" and snow > SNOW_AT else id


# The fog's far end the current weather wants, for photo mode to restore.
# The weather showing (a WeatherLibrary id), or "" before the first.
func shown() -> String:
	return _shown


func fog_end() -> float:
	return float(_to.get("end", Config.data.level_fog_end_m))


func is_fading() -> bool:
	return _fade_t >= 0.0


func pool_ids() -> Array:
	return parse_pool(Config.data.level_weather_pool).map(func(e: Array) -> String: return e[0])


func start() -> void:
	var holder := view.get_parent().get_node_or_null("WorldEnvironment") as WorldEnvironment
	_env = holder.environment if holder != null else null
	if _env != null:
		_base = {"bg": _env.background_color, "fog": _env.fog_light_color, "density": _env.fog_density,
			"sky_affect": _env.fog_sky_affect, "panorama": _panorama()}
	_show(_wanted(), true)


func _process(dt: float) -> void:
	drive_time += dt
	var want := _wanted()
	if want != _shown:
		_show(want, false)
	_step(dt)


func _wanted() -> String:
	var cfg: GameConfig = Config.data
	var slot := floori(drive_time / maxf(cfg.level_weather_hold_s, 1.0))
	if slot != _slot:
		_slot = slot
		_slot_id = draw(cfg.level_weather_pool, seed_value, slot, cfg.level_weather)
	return resolve(forced_weather if forced_weather != "" else _slot_id, _snow())


func _snow() -> float:
	return float(snow_fn.call()) if snow_fn.is_valid() else 0.0


func _show(id: String, instant: bool) -> void:
	_shown = id
	view.apply_weather(id)
	_to = {}
	if _env != null:
		_to = target_look(Config.data, id, _base)
		if String(WeatherLibrary.by_id(id).get("sky_panorama", "")) == "":
			_to["panorama"] = _base["panorama"]
		# the level fogs by distance, so a thicker look pulls the fog's far end in rather than raising density
		_to["end"] = Config.data.level_fog_end_m * float(_base["density"]) / maxf(float(_to["density"]), 0.0001)
		# depth fog's density is how opaque the fog gets at its far end, so above 1 it over-brightens past the fog colour
		_to["density"] = _base["density"]
	_to["sun_mult"] = _look_light(id)
	if instant:
		Config.data.lights_weather = id
		_fade_t = -1.0
		_apply(_to, _to, 1.0)
		return
	_from = {"light": _light}
	if _env != null:
		_from.merge({"bg": _env.background_color, "fog": _env.fog_light_color, "density": _env.fog_density,
			"sky_affect": _env.fog_sky_affect, "end": _env.fog_depth_end})
	_swapped = _env == null or String(_to["panorama"]) == _panorama()
	_fade_t = 0.0


func _look_light(id: String) -> float:
	var wl: Dictionary = WeatherLibrary.by_id(id).get("look", {})
	return float(Config.data.get(String(wl["sun_energy_mult"]))) if wl.has("sun_energy_mult") else 1.0


func _step(dt: float) -> void:
	if _fade_t < 0.0:
		return
	var dur := maxf(Config.data.level_weather_fade_s, 0.01)
	_fade_t = minf(_fade_t + dt, dur)
	var k := smoothstep(0.0, 1.0, _fade_t / dur)
	var swell := 1.0 if _swapped else 1.0 + (SWAP_FOG_SWELL - 1.0) * sin(PI * k)
	_apply(_from, _to, k, swell)
	if k >= LIGHTS_AT:
		_switch_lights()
	if not _swapped and k >= 0.5:
		_swapped = true
		_set_panorama(String(_to["panorama"]))
	if _fade_t >= dur:
		_fade_t = -1.0
		_apply(_to, _to, 1.0)


func _switch_lights() -> void:
	var cfg: GameConfig = Config.data
	if cfg.lights_weather == _shown:
		return
	cfg.lights_weather = _shown
	if not HeadlightCone.has_headlights(cfg):
		HeadlightCone.reset()


func _apply(from: Dictionary, to: Dictionary, k: float, swell := 1.0) -> void:
	_light = lerpf(float(from.get("light", from.get("sun_mult", 1.0))), float(to["sun_mult"]), k)
	RenderingServer.global_shader_parameter_set(G_LIGHT, Vector3(_light, _light, _light))
	if _env == null:
		return
	_env.background_color = (from["bg"] as Color).lerp(to["bg"], k)
	_env.fog_light_color = (from["fog"] as Color).lerp(to["fog"], k)
	_env.fog_density = lerpf(from["density"], to["density"], k)
	_env.fog_sky_affect = lerpf(from["sky_affect"], to["sky_affect"], k)
	_env.fog_depth_end = lerpf(from["end"], to["end"], k) / swell
	if k >= 1.0:
		_set_panorama(String(to["panorama"]))


func _panorama() -> String:
	var mat := _sky_material()
	return mat.panorama.resource_path if mat != null and mat.panorama != null else ""


func _set_panorama(path: String) -> void:
	var mat := _sky_material()
	if mat != null and path != "" and ResourceLoader.exists(path):
		mat.panorama = load(path)


func _sky_material() -> PanoramaSkyMaterial:
	if _env == null or _env.sky == null:
		return null
	return _env.sky.sky_material as PanoramaSkyMaterial
