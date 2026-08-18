@tool
class_name TerrainLayer
extends Resource
# Docs: features/terrain.md — update in the same change as this file.
# Tests: tests/headless/test_terrain.gd, tests/headless/test_terrain_cliffs.gd, tests/headless/test_terrain_lod.gd, tests/headless/test_terrain_memory.gd, tests/headless/test_terrain_noise.gd — extend in the same change.

# One Perlin noise layer: frequency = 1 / wavelength_m, scaled by amplitude_m.
@export var wavelength_m: float = 60.0:
	set(value):
		wavelength_m = value
		emit_changed()

@export var amplitude_m: float = 1.5:
	set(value):
		amplitude_m = value
		emit_changed()
