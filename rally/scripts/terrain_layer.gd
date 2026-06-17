@tool
class_name TerrainLayer
extends Resource

# One Perlin noise layer: frequency = 1 / wavelength_m, scaled by amplitude_m.
@export var wavelength_m: float = 60.0:
	set(value):
		wavelength_m = value
		emit_changed()

@export var amplitude_m: float = 1.5:
	set(value):
		amplitude_m = value
		emit_changed()
