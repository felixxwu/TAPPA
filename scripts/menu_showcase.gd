class_name MenuShowcase
extends Node3D
# Docs: features/menu-showcase.md — update in the same change as this file.
# Tests: tests/headless/test_menu_showcase.gd — extend in the same change.
#
# PROTOTYPE — phase 1 of todo/menu-background-showcase.md. Builds one fixed-seed
# track and flies a MenuShowcaseCamera around it, wearing only the "home" look
# (which authors no ground override — see RegionLibrary.look_of — so the scene's
# own baseline shader IS home's look, no extra application code needed here yet).
#
# NOT YET BUILT (later phases, see the spec): the other five regions as arc-length
# segments, the border-safety camera rule, per-segment foliage, and the per-region
# weather cycle. This step only proves the track/terrain-building recipe stands
# alone from world.gd/main.tscn, and that the hosting + camera-choreography shape
# works — deliberately minimal beyond that.

# Picked by eye for a gently curving, scenic loop. Not a tunable balance value
# (CLAUDE.md's rule against pinning authored values doesn't apply — this is a fixed
# background, not a rollable stage), but still not asserted as a literal in tests.
const SHOWCASE_SEED := 8675309
const TURN_COUNT := 6
const STRAIGHTNESS := 0.85

# How far past the track itself the chunk corridor reaches, so every chunk any shot
# could see is cached before the camera ever moves — the same "resident before the
# camera can reach it" rule the multi-region design leans on, applied here to one
# region's chunks. Reuses the shape of TrackProgress's own off-track leash rather
# than inventing a new distance.
const _CORRIDOR_LEASH_M := 60.0

const _SHOT_COUNT := 4
const _SHOT_AHEAD_M := 20.0
const _SHOT_OFFSET := Vector3(10.0, 9.0, 10.0)

@onready var _floor: TerrainManager = $Floor

var _camera: MenuShowcaseCamera
var _built := false


func _ready() -> void:
	await _build()


func is_built() -> bool:
	return _built


func camera() -> MenuShowcaseCamera:
	return _camera


func _build() -> void:
	var cfg: GameConfig = Config.data
	var params := TrackGenParams.new()
	params.seed = SHOWCASE_SEED
	params.turn_count = TURN_COUNT
	params.straightness = STRAIGHTNESS
	params.width = cfg.track_width
	params.clearance = cfg.track_clearance

	var result: Dictionary = await TrackGenerator.generate(params)
	var centerline := result["centerline"] as Curve2D

	_floor.noise_seed = SHOWCASE_SEED
	var bake_args := TerrainManager.bake_args(cfg)
	await _floor.set_track(centerline, bake_args[0], bake_args[1], bake_args[2], bake_args[3], bake_args[4])
	_floor.set_corridor(_floor.corridor_coords(centerline, _CORRIDOR_LEASH_M))
	for coord in _floor.corridor():
		_floor.cache_chunk(coord)
	_floor.build_initial()

	_camera = MenuShowcaseCamera.new()
	add_child(_camera)
	_camera.setup(_build_shots(centerline))
	_camera.current = true
	_built = true


# A handful of fixed, hand-picked shots evenly spaced around the loop — an elevated
# 3/4 angle looking a little way down the road from each stop. Multi-region border
# safety (todo/menu-background-showcase.md) doesn't apply yet: there is only one
# region in this prototype, so every shot is automatically "safe".
func _build_shots(centerline: Curve2D) -> Array:
	var shots: Array = []
	var length := centerline.get_baked_length()
	if length <= 0.0:
		return shots
	for i in _SHOT_COUNT:
		var s := length * float(i) / float(_SHOT_COUNT)
		var here := centerline.sample_baked(s)
		var ahead := centerline.sample_baked(fmod(s + _SHOT_AHEAD_M, length))
		var pos := Vector3(here.x, _floor.height_at(here.x, here.y), here.y) + _SHOT_OFFSET
		var look := Vector3(ahead.x, _floor.height_at(ahead.x, ahead.y), ahead.y)
		shots.append({"pos": pos, "look_at": look})
	return shots
