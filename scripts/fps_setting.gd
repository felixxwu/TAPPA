class_name FpsSetting
extends RefCounted

## The player-facing frame-rate cap (Settings -> Display). A 3-way choice between
## 30, 60 and uncapped, persisted under SETTING_KEY as the Engine.max_fps int to
## apply (0 = uncapped). When the player hasn't chosen, it falls back to the
## platform's natural cap: 30 on a web TOUCH device (single-threaded audio +
## phone thermals — see Platform.is_touch()/is_web() and GameConfig.target_fps_for),
## 60 everywhere else. Picking a value overrides that default for good.
##
## Unlike the camera / mobile-scheme settings (which drive scene-local state via a
## signal), the frame cap IS a global engine property, so the picker applies it by
## writing Engine.max_fps directly and world._ready() re-derives it on the next run.

const SETTING_KEY := "fps_cap"

# 0 is Godot's "no frame cap" sentinel for Engine.max_fps.
const UNCAPPED := 0

# The selector rows, in display order. `value` doubles as the Engine.max_fps to
# apply. Fixed choices (not the tunable GameConfig.target_fps fields) — this is a
# coarse user knob, not a balance value.
const OPTIONS := [
	{"value": 30, "name": "30 FPS", "desc": "Battery-friendly; easiest on phones."},
	{"value": 60, "name": "60 FPS", "desc": "The standard cap."},
	{"value": UNCAPPED, "name": "Uncapped", "desc": "No limit — as fast as the hardware allows."},
]


# The platform's default cap when the player hasn't chosen: web-touch -> 30, else
# 60 (via GameConfig.target_fps_for). Also the value the Settings row highlights
# when nothing is saved yet, so the default option reads as selected.
static func default_cap() -> int:
	return Config.data.target_fps_for(
		Platform.is_mobile_or_web(), Platform.is_web(), Platform.is_touch())


# The cap to actually apply: the player's saved choice, or the platform default
# when unset. world._ready() and the Settings picker both read this.
static func resolve() -> int:
	return int(Save.get_setting(SETTING_KEY, default_cap()))
