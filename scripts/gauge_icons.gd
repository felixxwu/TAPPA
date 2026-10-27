class_name GaugeIcons
extends RefCounted
# The pixel-art glyph under each in-run HUD gauge (features/hud.md): health, boost pressure,
# NOS and temperature. Authored in tools/build_pixel_icons.py, drawn by HudGauge.

enum Kind { HEALTH, BOOST, NOS, TEMP }

const TEXTURES := {
	Kind.HEALTH: preload("res://icons/hud/health.png"),
	Kind.BOOST: preload("res://icons/hud/boost.png"),
	Kind.NOS: preload("res://icons/hud/nos.png"),
	Kind.TEMP: preload("res://icons/hud/temp.png"),
}


static func texture(kind: Kind) -> Texture2D:
	return TEXTURES[kind]
