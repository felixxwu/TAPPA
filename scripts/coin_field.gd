class_name CoinField
extends Node3D
# Docs: features/collectables.md — update in the same change as this file.
# Tests: tests/headless/test_coin_field.gd — extend in the same change.
#
# Builds + owns one stage's coins from a CoinLayout plan (todo/roguelike-pivot.md
# decisions 13, 35, 36, 50). Each coin is a small flat-lit disc mesh (no physics
# body — see BushField for the same choice and why): a per-tick PROXIMITY query
# against the car, not a collider, so a coin can vanish the instant it's collected
# without a physics-frame lag. One-shot per coin (never re-arms once collected,
# unlike BushField's bushes — a spent coin stays spent for the rest of the stage).
#
# THE PICKUP RADIUS IS READ LIVE FROM GameConfig EVERY TICK, never cached at build()
# — see _timed_physics_process. That is deliberate: PerkLibrary's "coin_magnet"
# ("wider coin pickup radius") is wired in a LATER pass (decision 51) and its whole
# job is to widen GameConfig.coin_pickup_radius_m before this reads it; caching the
# radius here would give that pass nothing to reach.

signal coin_collected(index: int, total_collected: int)

const COIN_SHADER := preload("res://shaders/ps1_models_lit.gdshader")
# Flat, front-lit-ish default sun the coin material shades against — mirrors
# BarrierSection's own default (nothing feeds world.gd's light direction into
# roadside props today; see that script's `sun_direction`).
const _SUN_DIR := Vector3(0.35, 0.85, 0.4)

# How many coins were placed / collected this stage. Renderer-independent counts
# (mirrors SignField.sign_count) so headless tests don't need to inspect children.
var coin_count := 0
var collected_count := 0

var _car: Node = null
var _points: PackedVector2Array = PackedVector2Array()  # coin world XZ, index-stable
var _collected: PackedByteArray = PackedByteArray()      # 1 once picked up
var _meshes: Array[MeshInstance3D] = []
var _pickup_sfx_freq := 0.0
var _pickup_sfx_duration := 0.0


# Build every coin from a CoinLayout.plan() result. `terrain` sits the disc on the
# real road-adjacent ground height, exactly like SignField/BarrierField. `car` is
# the VehicleBody3D the proximity query tracks. `params` is
# GameConfig.coin_render_params().
func build(layout: Array, terrain: TerrainManager, car: Node, params: Dictionary) -> void:
	_car = car
	_pickup_sfx_freq = float(params.get("pickup_sfx_freq_hz", 0.0))
	_pickup_sfx_duration = float(params.get("pickup_sfx_duration_sec", 0.0))
	var radius: float = maxf(0.01, float(params.get("radius_m", 0.32)))
	var thickness: float = maxf(0.01, float(params.get("thickness_m", 0.08)))
	var hover: float = float(params.get("hover_m", 0.5))
	var color: Color = params.get("color", Color(0.97, 0.80, 0.13))
	var render_dist := float(params.get("render_distance_m", 0.0))
	var render_fade := float(params.get("render_fade_m", 0.0))

	var mesh := CylinderMesh.new()
	mesh.top_radius = radius
	mesh.bottom_radius = radius
	mesh.height = thickness
	mesh.radial_segments = 14
	var mat := _material(color)

	for entry in layout:
		var pos: Vector2 = entry["pos"]
		var y := terrain.height_at(pos.x, pos.y) + hover
		var mmi := MeshInstance3D.new()
		mmi.name = "Coin%d" % coin_count
		mmi.mesh = mesh
		mmi.material_override = mat
		mmi.position = Vector3(pos.x, y, pos.y)
		MeshUtil.apply_visibility_range(mmi, render_dist, render_fade)
		add_child(mmi)
		_meshes.append(mmi)
		_points.append(pos)
		coin_count += 1
	_collected.resize(coin_count)  # PackedByteArray zero-fills new elements


func _material(col: Color) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = COIN_SHADER
	mat.set_shader_parameter("albedo_color", col)
	mat.set_shader_parameter("light_amount", 0.9)
	mat.set_shader_parameter("light_dir", _SUN_DIR.normalized())
	mat.set_shader_parameter("sun_color", Color(0.55, 0.52, 0.48))
	mat.set_shader_parameter("sky_color", Color(0.55, 0.6, 0.7))
	mat.set_shader_parameter("ground_color", Color(0.35, 0.3, 0.25))
	return mat


func _physics_process(delta: float) -> void:
	var __t := Time.get_ticks_usec()
	_timed_physics_process(delta)
	PerfLog.track(&"coin_field", Time.get_ticks_usec() - __t)


func _timed_physics_process(_delta: float) -> void:
	if _car == null or _points.is_empty() or collected_count >= coin_count:
		return
	var xf: Transform3D = _car.global_transform
	var car_xz := Vector2(xf.origin.x, xf.origin.z)
	# Live read (see header) — the coin_magnet perk pass widens this, not this script.
	var radius := Config.data.coin_pickup_radius_m
	for idx in find_pickups(car_xz, _points, _collected, radius):
		_collect(idx)


func _collect(idx: int) -> void:
	_collected[idx] = 1
	collected_count += 1
	if idx >= 0 and idx < _meshes.size():
		_meshes[idx].visible = false
	Audio.play_beep(_pickup_sfx_freq, _pickup_sfx_duration)
	coin_collected.emit(idx, collected_count)


# Pure: indices in `points` that are NOT YET in `collected` and lie within `radius`
# of `car_xz`. Static + side-effect-free so "a coin is collected once, not twice" is
# unit-testable without a scene or a physics tick (CLAUDE.md — test the logic).
static func find_pickups(car_xz: Vector2, points: PackedVector2Array,
		collected: PackedByteArray, radius: float) -> Array[int]:
	var out: Array[int] = []
	var r2 := radius * radius
	for i in points.size():
		if i < collected.size() and collected[i] != 0:
			continue
		if car_xz.distance_squared_to(points[i]) <= r2:
			out.append(i)
	return out
