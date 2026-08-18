@tool
class_name TerrainLayer
extends Resource
# Docs: features/terrain.md — update in the same change as this file.
# Tests: tests/headless/test_terrain.gd, tests/headless/test_terrain_lod.gd, tests/headless/test_terrain_noise.gd — extend in the same change. These are the PRIMARY ones, not all of them: before you change behaviour here, `grep -rn 'TerrainLayer' tests/headless/` and read the assertions that pin what you are about to change (5 test files touch this script).

# One Perlin noise layer: frequency = 1 / wavelength_m, scaled by amplitude_m.
@export var wavelength_m: float = 60.0:
	set(value):
		wavelength_m = value
		emit_changed()

@export var amplitude_m: float = 1.5:
	set(value):
		amplitude_m = value
		emit_changed()
