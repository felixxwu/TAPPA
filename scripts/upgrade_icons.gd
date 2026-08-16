class_name UpgradeIcons
extends RefCounted
# The 32x32 monochrome stroke icon each upgrade GRID TILE wears (UpgradesGrid), keyed by
# slot id. White by design so a caller tints it with `modulate` rather than needing a
# second asset per state.
#
# A lookup table rather than `load("res://textures/icons/%s.svg" % slot)`: a slot with no
# authored icon must draw SOMETHING (a tile with a hole where the picture goes reads as a
# broken build, not as "no icon"), and a string-built path can only discover that at
# runtime. Preloading also keeps the grid's rebuild — which runs on every edit — off the
# disk entirely.

const _BY_SLOT := {
	"turbo": preload("res://textures/icons/turbo.svg"),
	"gearbox": preload("res://textures/icons/gearbox.svg"),
	"aero": preload("res://textures/icons/aero.svg"),
	"tires": preload("res://textures/icons/tires.svg"),
	"weight": preload("res://textures/icons/weight.svg"),
	"drivetrain": preload("res://textures/icons/drivetrain.svg"),
	"nitrous": preload("res://textures/icons/nitrous.svg"),
	UpgradeOptions.SLOT_ENGINE: preload("res://textures/icons/engine.svg"),
	UpgradeOptions.SLOT_TUNE: preload("res://textures/icons/tune.svg"),
}

# The wrench stands in for "some upgrade we have no picture for yet" — a new catalogue slot
# gets a usable tile the day it is authored, without blocking on an artist.
const _FALLBACK := preload("res://textures/icons/tune.svg")


static func texture(slot: String) -> Texture2D:
	return _BY_SLOT.get(slot, _FALLBACK)
