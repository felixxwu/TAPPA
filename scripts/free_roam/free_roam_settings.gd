class_name FreeRoamSettings
extends Resource
# Docs: features/free-roam.md — update in the same change as this file.
# Tests: tests/headless/test_free_roam.gd — extend in the same change.
# Every knob of the free-roam prototype: the island, the road network, the road-first terrain
# and the streaming budget. Defaults are the preset liked in tools/road_network_lab.html
# (todo/2026-10-19-free-roam-pivot.md).

@export_group("Island")
@export var world_seed := 1
## The car the game starts in, by CarLibrary id (the first car if it is missing).
@export var car_id := "porsche911"
@export var island_radius_m := 5000.0
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

@export_group("Road network (radial growth)")
@export var node_spacing_m := 75.0
@export var segment_m := 175.0
@export var fork_chance := 0.37
@export var fork_angle_deg := 150.0
@export var heading_jitter_deg := 120.0
@export var outward_pull := 0.44
@export var join_chance := 1.0
@export var roads_from_spawn := 3
## How far a road may swing from the straight line between its junctions, as a fraction of
## its length; 0 is dead straight.
@export var road_twist := 1.0
## Roughly how far the road runs between changes of direction.
@export var bend_length_m := 200.0
@export var road_half_width_m := 3.5
@export var road_shoulder_m := 2.0

@export_group("Base height and lakes")
@export var base_scale_m := 500.0
@export var base_relief_m := 15.0
@export var water_level_m := -5.0
@export var lake_depth_factor := 1.6
@export var shore_band_m := 1.0

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
## Road between rest stops, per biome ring counting outward (the last entry covers any ring
## beyond the list). Decision 31: one value per ring, all equal to start with.
@export var rest_stop_spacing_m := PackedFloat32Array([300.0, 300.0, 300.0])
## Road between loot pull-ins. Plenty of them: each shows something from its ring's remaining
## pool (LootLibrary.assign), so there should be more pull-ins than things to find.
@export var loot_slot_spacing_m := 150.0
@export var rest_stop_radius_m := 16.0
@export var loot_pad_radius_m := 7.0
@export var dead_end_radius_m := 14.0
## How far a pad's flat ground blends back into the natural terrain.
@export var pad_blend_m := 12.0
## Draw a placeholder post at every site (until rest stops and loot get real models).
@export var site_markers := true

@export_group("Barriers")
## A road vertex that turns by more than this is a sharp bend and gets a barrier on its outside
## where the land falls away. The module and drop rules are GameConfig's barrier_* fields.
@export var barrier_turn_min_deg := 28.0

@export_group("Foliage")
## One candidate spot per cell of this size; trees are then thinned by the forest noise.
@export var tree_cell_m := 9.0
## Share of the land that is forest (0 = no trees, 1 = everywhere).
@export var forestiness := 0.6
@export var bush_cell_m := 12.0
## One rock-group candidate per cell, before the region's rock density thins it.
@export var rock_cell_m := 45.0
@export var rock_group_chance := 0.35

@export_group("Streaming")
## Strict per-frame terrain budget, microseconds.
@export var budget_us := 1000
@export var chunk_m := 64.0
## Vertex spacing of the near (full-detail) and far meshes.
@export var near_stride_m := 2.0
@export var far_stride_m := 16.0
## Radii in chunks: full detail, horizon, and live collision.
@export var near_radius := 2
@export var far_radius := 6
@export var collision_radius := 1
## The safety net: if the chunk the car will be over in this many seconds has no collision yet,
## it is built at once, over the frame budget (a hitch rather than a fall through the world).
@export var collision_rush_s := 0.5
