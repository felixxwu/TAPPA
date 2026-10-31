class_name FreeRoamSettings
extends Resource
# Docs: features/free-roam.md — update in the same change as this file.
# Tests: tests/headless/test_free_roam.gd — extend in the same change.
# Every knob of the free-roam prototype: the island, the road network, the road-first terrain
# and the streaming budget. Defaults are the preset liked in tools/road_network_lab.html
# (todo/2026-10-19-free-roam-pivot.md).

@export_group("Island")
@export var world_seed := 5687
## New World draws random seeds until the roads reach the outermost (snow) ring and total more
## than this, measured junction to junction like tools/road_network_lab.html.
@export var new_world_min_road_km := 40.0
## The car the game starts in, by CarLibrary id (the first car if it is missing).
@export var car_id := "porsche911"
@export var island_radius_m := 10000.0
@export var ring_count := 4

@export_group("Biomes")
## The region each biome ring wears, counting outward from spawn (RegionLibrary ids; wraps if
## there are more rings). Its look, trees, rocks and handling come from RegionLibrary.
@export var ring_regions := PackedStringArray(["home", "greece", "taiga", "snow"])
## Each ring's weather pool, "id:weight,id:weight" (WeatherLibrary ids).
@export var ring_weather := PackedStringArray([
	"dry:5,rain:1,fog:1,night:1",
	"dry:5,sandstorm:1,night:1",
	"dry:3,rain:1,fog:1,storm:1,night:1",
	"dry:3,snow:2,fog:1,night:1",
])
## How long the weather holds before it may change, in seconds of driving.
@export var weather_hold_s := 180.0
## How long the sky, fog and background take to blend to a new biome or weather.
@export var look_crossfade_s := 4.0
## How wide the blend between two rings' road surfaces (gravel / tarmac) is, in metres.
@export var road_surface_blend_m := 150.0
## How wide the fade between two rings' ground textures and tints is, in metres (roughly: the
## wobble in the border stretches or squeezes it in places).
@export var biome_fade_m := 10.0

@export_group("Road network (radial growth)")
@export var node_spacing_m := 300.0
@export var segment_m := 750.0
@export var fork_chance := 0.38
@export var fork_angle_deg := 109.0
@export var heading_jitter_deg := 39.0
@export var outward_pull := 0.48
@export var join_chance := 1.0
@export var roads_from_spawn := 1
## Dead ends no longer than this, measured back to their junction, are cut after growth,
## repeatedly, so a fork whose branches all die out goes too; 0 keeps every dead end.
@export var prune_dead_ends_m := 1000.0
## How far a road may swing from the straight line between its junctions, as a fraction of
## its length; 0 is dead straight.
@export var road_twist := 0.24
## When above 0, the island has just one road: this long, straight out from spawn (the benchmark's).
@export var straight_road_m := 0.0
## Roughly how far the road runs between changes of direction.
@export var bend_length_m := 150.0
## Bends sharper than this (degrees, at one polyline point or where two links meet) are rounded
## off by cutting the corner; 180 leaves every corner as it is.
@export var max_corner_turn_deg := 20.0
@export var road_half_width_m := 1.9
@export var road_shoulder_m := 1.0
## How wide the drawn grass-to-gravel fade is, centred on the shoulder (looks only; the road's grip
## edge stays the shoulder). The ground shader paints it per pixel from the distance to the road,
## so it can be narrower than a mesh triangle without the edge turning jagged.
@export var road_paint_fade_m := 1.0
## Lane markings on tarmac stop this far short of a junction, so the lines of roads meeting there
## don't cross each other; they fade back in over the next 4 m.
@export var marking_junction_clear_m := 6.0

@export_group("Base height and lakes")
@export var base_scale_m := 500.0
@export var base_relief_m := 5.0
@export var water_level_m := -2.0
@export var lake_depth_factor := 1.6
@export var shore_band_m := 5.0
## Where a road runs along or across a lake, the bank from the road's edge down to the lake bed.
@export var lake_road_bank_m := 12.0

@export_group("Road-first terrain")
@export var mountain_m := 300.0
@export var flat_band_m := 2.0
@export var mountain_dist_m := 400.0
@export var ribbon_bank_m := 47.0
@export var ribbon_width_m := 320.0

## Small hills over everything: their height and roughly how far apart they are.
@export var bump_height_m := 5.0
@export var bump_scale_m := 50.0

@export_group("Sites")
## Road between rest stops in a ring whose region doesn't set its own `rest_stop_spacing_m`
## (RegionLibrary).
@export var rest_stop_spacing_m := 1050.0
## Road between coins (loot spots; dead ends hold one too).
@export var loot_slot_spacing_m := 250.0
## Money a coin in the spawn ring is worth.
@export var coin_value := 500
## Money a coin is worth on top of that, per ring further out.
@export var coin_value_per_ring := 500
@export var rest_stop_radius_m := 16.0
## How far before a dead end's checkpoint pad its coin sits on the road.
@export var dead_end_coin_gap_m := 10.0
## How far a pad's flat ground blends back into the natural terrain, at least. The blend widens
## where the pad sits far above or below the land around it, so its slope stays under
## pad_blend_max_slope (rise over run), up to pad_blend_max_m.
@export var pad_blend_m := 12.0
@export var pad_blend_max_m := 40.0
@export var pad_blend_max_slope := 0.25

@export_group("Barriers")
## A bend (the few rounded vertices of one corner) that turns by more than this in total is sharp and gets a barrier on its outside
## where the land falls away. The module and drop rules are GameConfig's barrier_* fields.
@export var barrier_turn_min_deg := 28.0

@export_group("Foliage")
## One candidate spot per cell of this size; trees are then thinned by the forest noise.
@export var tree_cell_m := 6.0
## Share of the land that is forest (0 = no trees, 1 = everywhere).
@export var forestiness := 0.8
@export var bush_cell_m := 7.0
## Trees and bushes crowd the road and thin out away from it: right at the road every spot grows
## (and the forest noise leaves no gaps), easing over this distance to the far densities below.
@export var roadside_falloff_m := 50.0
## Share of tree / bush spots kept far from the road.
@export_range(0.0, 1.0) var far_tree_density := 0.35
@export_range(0.0, 1.0) var far_bush_density := 0.3
## One rock-group candidate per cell, before the region's rock density thins it.
@export var rock_cell_m := 45.0
@export var rock_group_chance := 0.35

@export_group("Streaming")
## Share of the frame's free time (from the last frames' cpu / gpu load) terrain work may use.
@export_range(0.0, 1.0) var budget_fraction := 0.5
## Floor under that budget, as a share of the actual frame time, so a slow frame gets a longer
## floor and streaming gets the same time per second at any frame rate...
@export_range(0.0, 1.0) var budget_min_fraction := 0.25
## ...but no longer than it would be at this frame rate. On a device whose every frame is busy
## (a phone browser), a floor that grows with slow frames slows them further, and so on.
@export var budget_floor_fps := 60.0
## Boot and travel build the ground in slices of this many milliseconds, a frame apart, so the
## loading screen keeps drawing.
@export var prefill_slice_ms := 8.0
@export var chunk_m := 64.0
## Vertex spacing of the three detail levels: near (the 2×2 chunks round the car), mid (which
## also carries the trees and everything else planted) and far (the horizon).
@export var near_stride_m := 2.0
## The near level is drawn in squares this size (2×2 of them round the car), smaller than a
## chunk so less of it is rebuilt per metre driven. Must divide chunk_m, and be a multiple of
## mid_stride_m and far_stride_m.
@export var near_tile_m := 32.0
@export var mid_stride_m := 8.0
@export var far_stride_m := 16.0
## Radii in chunks: mid detail and planting, and the horizon. Collision covers the near block.
@export var mid_radius := 1.5
@export var far_radius := 6
## The mid band narrows as the car speeds up, reaching these shares of its reach to the side and
## behind at mid_squash_speed_mps (ahead it always reaches mid_radius).
@export_range(0.1, 1.0) var mid_side_frac := 0.6
@export_range(0.1, 1.0) var mid_back_frac := 0.6
@export var mid_squash_speed_mps := 25.0
## The safety net: if the chunk the car will be over in this many seconds has no collision yet,
## it is built at once, over the frame budget (a hitch rather than a fall through the world).
@export var collision_rush_s := 0.5
## Queue order between planting and far meshes: planting a near chunk d chunks away waits for any
## far mesh that would fill a gap in the horizon closer than d + this many chunks (0 = planting
## and far gaps at the same distance tie; larger favours the horizon over foliage). Never puts
## either ahead of a collision or near-mesh build.
@export_range(0.0, 40.0) var far_lead_chunks := 3.0

@export_group("Stunts")
## A drift: the car pointing at least this far from where it's going, at this speed (m/s). Each
## second of it pays this much once the drift ends.
@export var drift_min_angle_deg := 25.0
@export var drift_min_speed_mps := 10.0
@export var drift_money_per_s := 75.0
## Going fast: each second at this speed (m/s) or more pays this much once the car slows.
@export var fast_speed_mps := 30.0
@export var fast_money_per_s := 50.0
## A drift or fast stretch shorter than this pays nothing; dropping out of one for less than
## stunt_grace_s (a drift swinging to the other side) doesn't end it.
@export var stunt_min_s := 1.0
@export var stunt_grace_s := 0.4
## A jump: each second with all four wheels off the ground pays this much once the car lands;
## a hop shorter than jump_min_s pays nothing.
@export var jump_money_per_s := 200.0
@export var jump_min_s := 0.3
## A near miss: a tree passing within this distance of the car's centre at this speed (m/s),
## without being hit.
@export var near_miss_radius_m := 2.0
@export var near_miss_min_speed_mps := 15.0
@export var near_miss_money := 100

@export_group("Feedback")
## How long a loot / shop message stays up, in seconds.
@export var toast_s := 3.0
## The "Checkpoint reached" / region band: fade in and out time, and how long it holds.
@export var banner_fade_s := 0.6
@export var banner_hold_s := 3.0
## How often the world is saved and the map's explored area updated, in seconds.
@export var save_every_s := 5.0
@export var map_every_s := 0.25
## Dropped money: how close the car must come to pick it up, and the crystal that marks it
## (radius, the heights of its upper and lower halves, and how high it floats).
@export var dropped_reach_m := 6.0
@export var drop_crystal_color := Color(1.0, 0.8, 0.2)
@export var drop_crystal_radius_m := 0.3
@export var drop_crystal_top_m := 0.9
@export var drop_crystal_bottom_m := 0.6
@export var drop_crystal_float_m := 1.4
## The light on the lamp post by every rest stop's cabin (TerrainStreamer._lamp_post).
@export var cabin_lamp_range_m := 14.0
@export var cabin_lamp_energy := 2.5
## The crowd by a rest stop: half its length along the road and half its depth.
@export var rest_crowd_half_len_m := 6.0
@export var rest_crowd_half_depth_m := 3.0

@export_group("Cold open")
## A first-time player's start (ColdOpen, todo/2026-10-30-cold-open.md): the car they start in
## (a CarLibrary id; the first starter car if it's missing).
@export var cold_open_car_id := "mx5"
## The furthest down the spawn cabin's road the cold open may start, and the nearest it may: it
## starts as far out as the lamp post stays in view, but never nearer than the minimum.
@export var cold_open_max_distance_m := 320.0
@export var cold_open_min_distance_m := 220.0
## How far the road between the start and the cabin may stray off the straight line between them
## for the lamp post to count as in view.
@export var cold_open_view_corridor_m := 6.0
## The car's state at the start: HP as a fraction of max (below the cooling-failure fraction, so the
## cooling is already gone), and engine temperature as a fraction of the overheat threshold.
@export_range(0.0, 1.0) var cold_open_start_hp_frac := 0.4
@export_range(0.0, 2.0) var cold_open_start_temp_frac := 0.85
## The lowest HP the car can fall to during the cold open, as a fraction of max: it limps, never gives up.
@export_range(0.0, 1.0) var cold_open_hp_floor_frac := 0.1
## How many coins the trail to the cabin is split into. Their total is the dearest other starter car.
@export var cold_open_trail_coins := 12
## Seconds after the "Checkpoint reached" band before the camera and control options open.
@export var cold_open_options_delay_s := 1.0


# The closest the coast ever comes, which is also the radius the biome rings divide.
func inner_radius_m() -> float:
	return island_radius_m * 0.82


# A random island worth playing, for New World (falls back to world_seed if none turns up).
func pick_world_seed() -> int:
	var s: FreeRoamSettings = duplicate()
	for _try in 200:
		s.world_seed = randi() % 100000
		if s.island_qualifies():
			return s.world_seed
	return world_seed


func island_qualifies() -> bool:
	var net := RoadNetwork.new()
	var terrain := RoadTerrain.new()
	terrain.setup(self, net)
	net.build(self, terrain)
	var length := 0.0
	var reaches_snow := false
	for e: Vector2i in net.edges:
		length += Vector2(net.node_x[e.x] - net.node_x[e.y], net.node_y[e.x] - net.node_y[e.y]).length()
		reaches_snow = reaches_snow or terrain.ring_index(net.node_x[e.y], net.node_y[e.y]) == ring_count - 1
	return reaches_snow and length > new_world_min_road_km * 1000.0
