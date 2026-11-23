class_name GraphicsSettings
extends RefCounted
# Docs: features/settings.md — update in the same change as this file.
# Tests: tests/headless/test_graphics_settings.gd — extend in the same change.

## The Settings → Graphics page's choices: performance knobs saved in the player's profile and laid
## over GameConfig when the level loads. An option the player never touched keeps its GameConfig value.

const SETTING_KEY := "graphics"

## Each option drives one or more GameConfig fields. A choice's value is either a bool written as-is,
## or a float multiplying the field's GameConfig value. The default choice is the one matching GameConfig.
const OPTIONS := [
	{"key": "tree_distance", "name": "Tree distance", "fields": ["level_tree_draw_m"],
		"choices": [["Near", 0.5], ["Normal", 1.0], ["Far", 2.0], ["Very far", 3.0]]},
	{"key": "cover_distance", "name": "Grass & bushes distance",
		"fields": ["ground_cover_reach", "ground_cover_fade_start", "ground_cover_fade_end",
			"ground_cover_far_reach", "ground_cover_far_fade_start", "ground_cover_far_fade_end"],
		"choices": [["Near", 0.5], ["Normal", 1.0], ["Far", 1.5], ["Very far", 2.0]]},
	{"key": "weather_particles", "name": "Rain & snow particles",
		"fields": ["rain_particle_count", "sand_particle_count", "storm_particle_count", "snowfall_particle_count"],
		"choices": [["Off", 0.0], ["Low", 0.5], ["Normal", 1.0]]},
	{"key": "dust_puffs", "name": "Dust puffs", "fields": ["dust_puffs_enabled"], "choices": [["On", true], ["Off", false]]},
	{"key": "wheel_particles", "name": "Wheel spray", "fields": ["wheel_particles_enabled"], "choices": [["On", true], ["Off", false]]},
	{"key": "engine_smoke", "name": "Engine smoke", "fields": ["engine_smoke_enabled"], "choices": [["On", true], ["Off", false]]},
	{"key": "exhaust_flames", "name": "Exhaust flames", "fields": ["exhaust_flames_enabled"], "choices": [["On", true], ["Off", false]]},
	{"key": "tire_marks", "name": "Tyre marks", "fields": ["tire_marks_enabled"], "choices": [["On", true], ["Off", false]]},
	{"key": "spectators", "name": "Spectators", "fields": ["spectators_enabled"], "choices": [["On", true], ["Off", false]]},
]

# GameConfig's own value of each field this module has overwritten, so a reset can put it back.
static var _authored: Dictionary = {}


static func option(key: String) -> Dictionary:
	for o in OPTIONS:
		if o["key"] == key:
			return o
	return {}


static func _saved() -> Dictionary:
	var s: Variant = Save.get_setting(SETTING_KEY, {})
	return s if s is Dictionary else {}


## Index into the option's choices that is in force: the saved one, or the one matching GameConfig.
static func choice_index(key: String) -> int:
	var o := option(key)
	var saved := _saved()
	if saved.has(key):
		return clampi(int(saved[key]), 0, o["choices"].size() - 1)
	var field := String(o["fields"][0])
	var authored: Variant = _authored.get(field, Config.data.get(field))
	for i in o["choices"].size():
		var v: Variant = o["choices"][i][1]
		if (v is bool and v == bool(authored)) or (not v is bool and is_equal_approx(float(v), 1.0)):
			return i
	return 0


static func choice_label(key: String) -> String:
	return String(option(key)["choices"][choice_index(key)][0])


## Step an option to its next choice and save it.
static func cycle(key: String) -> void:
	var saved := _saved()
	saved[key] = (choice_index(key) + 1) % option(key)["choices"].size()
	Save.set_setting(SETTING_KEY, saved)


static func reset() -> void:
	Save.set_setting(SETTING_KEY, {})


## Lay the saved choices over `cfg` (Config.data); fields of unsaved options get their GameConfig value back.
static func apply(cfg: GameConfig) -> void:
	var saved := _saved()
	for o in OPTIONS:
		for field in o["fields"]:
			if not saved.has(o["key"]):
				if _authored.has(field):
					cfg.set(field, _authored[field])
					_authored.erase(field)
				continue
			if not _authored.has(field):
				_authored[field] = cfg.get(field)
			var v: Variant = o["choices"][choice_index(o["key"])][1]
			var base: Variant = _authored[field]
			if v is bool:
				cfg.set(field, v)
			elif base is int:
				cfg.set(field, roundi(base * float(v)))
			else:
				cfg.set(field, base * float(v))
