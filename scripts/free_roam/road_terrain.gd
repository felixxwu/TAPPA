class_name RoadTerrain
extends RefCounted
# Docs: features/free-roam.md — update in the same change as this file.
# Tests: tests/headless/test_free_roam.gd — extend in the same change.
# Road-first terrain: height is built FROM the roads instead of roads being carved into noise.
# Roads sit in valleys, mountains rise with distance from the nearest road, and banks or drops
# line each road. Lakes come from a base field that ignores the roads, so the road layout can
# avoid them before any terrain exists. Every query is a pure function of position, so any
# chunk can be built alone and in any order.
#
# The maths mirrors heightAt() in tools/road_network_lab.html exactly, so a seed shows the
# same mountains in both. The one addition is a fade to sea floor near the coast, which the
# lab never draws.

const RING_TINTS: Array[Color] = [
	Color("#8fbf78"), Color("#d8c48a"), Color("#77a888"), Color("#8fbcc0"), Color("#e6eef2"),
	Color("#b88a8a"), Color("#a898c8"), Color("#c8b888"),
]

var net: RoadNetwork
# The rest stop / loot / dead-end pads (RoadSites), once planned: the ground under each is
# flattened to its road's height and reads as road. Null while the sites are being planned.
var sites: RoadSites
# Distance to the nearest road found by the last height() call; INF when none was looked up.
var last_road_d := INF

var _s: FreeRoamSettings


func setup(settings: FreeRoamSettings, network: RoadNetwork) -> void:
	_s = settings
	net = network


# Low-frequency height that ignores the roads, lifted near spawn so spawn is always dry.
func base_h(x: float, y: float) -> float:
	var raw := _s.base_relief_m * (LabNoise.fbm(x / _s.base_scale_m + 3.0, y / _s.base_scale_m + 3.0, _s.world_seed + 41) - 0.5) * 2.0
	return raw + (1.0 - LabNoise.smooth(300.0, 900.0, LabNoise.hyp(x, y))) * maxf(0.0, _s.water_level_m + 10.0 - raw)


# Small hills laid over everything, two octaves of Perlin noise.
func bump(x: float, y: float) -> float:
	var sc := _s.bump_scale_m
	return (LabNoise.perlin(x / sc, y / sc, _s.world_seed + 71) + LabNoise.perlin(x / sc * 2.03, y / sc * 2.03, _s.world_seed + 73) * 0.5) * _s.bump_height_m


func is_lake(x: float, y: float) -> bool:
	return base_h(x, y) < _s.water_level_m


func coast_r(x: float, y: float) -> float:
	var ang := atan2(y, x)
	return _s.island_radius_m * (0.82 + 0.18 * LabNoise.fbm(cos(ang) * 2.0 + 5.0, sin(ang) * 2.0 + 5.0, _s.world_seed))


# The coastline never comes closer than this (its noise term is never negative), so points
# inside it can skip the coast noise entirely.
func min_coast_r() -> float:
	return _s.island_radius_m * 0.82


func sea_floor() -> float:
	return _s.water_level_m - 30.0


func on_land(x: float, y: float) -> bool:
	var r := LabNoise.hyp(x, y)
	return r < min_coast_r() - 150.0 or r < coast_r(x, y) - 150.0


func is_water(x: float, y: float) -> bool:
	return not on_land(x, y) or is_lake(x, y)


# Terrain height. `cands` is a chunk's pre-gathered road candidates (RoadNetwork.candidates_for);
# pass use_cands = false for a one-off query anywhere.
func height(x: float, y: float, cands: PackedInt32Array, use_cands: bool) -> float:
	var h := _natural_height(x, y, cands, use_cands)
	if sites == null:
		return h
	var i := sites.pad_at(x, y)
	if i < 0:
		return h
	var o := sites.outside(i, x, y)
	# a pad reads as road: full surface inside it, fading over the shoulder outside
	last_road_d = minf(last_road_d, maxf(0.0, _s.road_half_width_m + o))
	return lerpf(sites.pad_h[i], h, LabNoise.smooth(0.0, sites.blend_m(), o))


func _natural_height(x: float, y: float, cands: PackedInt32Array, use_cands: bool) -> float:
	last_road_d = INF
	var r := LabNoise.hyp(x, y)
	if r < min_coast_r() - 400.0:
		return _inland_height(x, y, cands, use_cands)
	var cr := coast_r(x, y)
	if r >= cr - 150.0:
		return sea_floor()
	var h := _inland_height(x, y, cands, use_cands)
	var land := 1.0 - LabNoise.smooth(cr - 400.0, cr - 150.0, r)
	return h if land >= 1.0 else lerpf(sea_floor(), h, land)


func _inland_height(x: float, y: float, cands: PackedInt32Array, use_cands: bool) -> float:
	var water := _s.water_level_m
	var bp := base_h(x, y)
	if bp < water:
		return water - _s.lake_depth_factor * (water - bp)  # meets the shore at exactly the water level
	# mountains flatten out toward a shore, so lakes get banks rather than walls
	var shore := LabNoise.smooth(0.0, _s.shore_band_m, bp - water)
	var ridged := 1.0 - absf(2.0 * LabNoise.fbm(x / 1200.0 + 11.0, y / 1200.0 + 11.0, _s.world_seed + 43) - 1.0)
	var mtn := _s.mountain_m * ridged * ridged * shore
	var found := net.nearest_in(x, y, cands, _s.mountain_dist_m) if use_cands else net.nearest(x, y, _s.mountain_dist_m)
	if not found:
		return bp + mtn + bump(x, y) * shore
	last_road_d = net.hit_d
	var far := LabNoise.smooth(_s.flat_band_m, _s.mountain_dist_m, net.hit_d)
	var hq := maxf(base_h(net.hit_qx, net.hit_qy), water + 3.0)
	var base := hq + (bp - hq) * far
	var k := (LabNoise.fbm(net.hit_s / 400.0 + net.hit_edge * 13.7, net.hit_side * 5.0 + 100.0, _s.world_seed + 57) - 0.5) * 2.0 * _s.ribbon_bank_m
	var rw := _s.ribbon_width_m
	var rib := k * LabNoise.smooth(_s.flat_band_m * 0.5, rw * 0.5, net.hit_d) * (1.0 - LabNoise.smooth(rw * 0.5, rw, net.hit_d))
	# the road takes the bumps at its own centre, so it rolls along its length but stays level across
	var bq := bump(net.hit_qx, net.hit_qy)
	var bumps := bq + (bump(x, y) * shore - bq) * LabNoise.smooth(_s.flat_band_m * 0.5, _s.flat_band_m * 0.5 + 30.0, net.hit_d)
	return base + mtn * far + rib * shore + bumps


func road_weight(d: float) -> float:
	return 1.0 - smoothstep(_s.road_half_width_m, _s.road_half_width_m + _s.road_shoulder_m, d)


# Which biome ring a point is in, counting outward from spawn.
func ring_index(x: float, y: float) -> int:
	var wob := (LabNoise.fbm(x / 1500.0 + 9.0, y / 1500.0 + 9.0, _s.world_seed + 3) - 0.5) * 0.25
	return clampi(floori((LabNoise.hyp(x, y) / (_s.island_radius_m * 0.82) + wob) * _s.ring_count), 0, _s.ring_count - 1)


func ring_tint(x: float, y: float) -> Color:
	return RING_TINTS[ring_index(x, y) % RING_TINTS.size()]
