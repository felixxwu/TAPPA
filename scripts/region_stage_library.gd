class_name RegionStageLibrary
extends RefCounted
# Docs: features/region-stage-library.md — update in the same change as this file.
# Tests: tests/headless/test_region_stage_library.gd — extend in the same change.
#
# THE AUTHORED STAGE CATALOGUE (todo/region-stage-slots-redesign.md), replacing the
# rally-pool + runtime-scale model it superseded (scripts/rally_library.gd /
# RegionStagePool's old bag draw). A REGION is a fixed-length array of 8 SLOTS (one per
# stage position in an 8-stage run), each slot a fixed-length array of 3 CANDIDATES.
# RegionStagePool.draw picks exactly one candidate per slot, uniformly at random off the
# run seed — the array POSITION is the difficulty signal; there is no runtime scale on
# top (StageConfig no longer has stage_scale) and nothing to sort.
#
# Every candidate's (seed, turn_count, straightness, terrain_layer*_amplitude, width)
# combination is authored FINAL and was hand-verified to complete a real DFS track
# generation (TrackGenerator.generate, same contract tools/generate_track_cache.gd uses)
# before being committed here. If you edit a candidate's shape fields, re-verify it the
# same way (tools/probe_track_event.gd or a standalone probe) before re-baking.
#
# Per-candidate fields (see §3 of the design spec):
#   seed, turn_count                    — required; TrackGenParams.for_event / StageConfig.apply_event_config
#   straightness                        — required; StageFields.event_straightness
#   terrain_layer1_amplitude            — required; StageConfig.apply_event_config (layer2/3 optional)
#   width, forestiness, surface_mix,
#   cliffiness, weather, water_level     — optional, falls back to the region/GameConfig default
#
# Computed, never authored here (stamped by all_stages_in / RegionStagePool.draw):
# "region", "slot", "candidate" — the last replaces the old rally_id for provenance.
#
# REGION CHARACTER, preserved from the deleted RallyLibrary.RALLIES table this replaces
# (see that file's history / features/regions.md): home runs temperate forest, waterline
# -12; greece runs arid/sandstorm, waterline -11; taiga runs deep boreal forest, waterline
# -12; home_coast runs the flooded lakeland, waterline -7 inland / up to -4 near open
# water; snow runs the Alps, the highest cliffiness on the map, waterline -12/-13, and is
# the only region weather authors "snow" onto. terrain_layer1_amplitude no longer varies
# by region — every region shares SLOT_AMPLITUDE's 10->40 linear escalation across the 8
# slots (see below); region character now comes entirely from forestiness/cliffiness/
# surface_mix/water_level/weather, not amplitude.
# Slot-index -> terrain_layer1_amplitude, linear 10 (slot 0 / stage 1) to 40 (slot 7 /
# stage 8), shared by every region. Candidates within a slot no longer vary shape/terrain
# fields at all (todo/region-stage-slots-redesign.md follow-up) — only the seed differs,
# so a slot is really one authored stage with 3 track-generation rolls.
const SLOT_AMPLITUDE: Array[float] = [10.0, 14.3, 18.6, 22.9, 27.1, 31.4, 35.7, 40.0]

const STAGES: Dictionary = {
	"home": [
		# slot 0 (difficulty tier 1)
		[
			{"seed": 1007, "turn_count": 20, "straightness": 1.0, "terrain_layer1_amplitude": 10.0, "forestiness": 0.7, "surface_mix": 1.0, "cliffiness": 0.4, "water_level": -12.0},
			{"seed": 1102, "turn_count": 20, "straightness": 1.0, "terrain_layer1_amplitude": 10.0, "forestiness": 0.7, "surface_mix": 1.0, "cliffiness": 0.4, "water_level": -12.0},
			{"seed": 1103, "turn_count": 20, "straightness": 1.0, "terrain_layer1_amplitude": 10.0, "forestiness": 0.7, "surface_mix": 1.0, "cliffiness": 0.4, "water_level": -12.0},
		],
		# slot 1 (difficulty tier 1)
		[
			{"seed": 1201, "turn_count": 20, "straightness": 0.925, "terrain_layer1_amplitude": 14.3, "forestiness": 0.45, "surface_mix": 0.4, "cliffiness": 0.5, "water_level": -12.0},
			{"seed": 7031, "turn_count": 20, "straightness": 0.925, "terrain_layer1_amplitude": 14.3, "forestiness": 0.45, "surface_mix": 0.4, "cliffiness": 0.5, "water_level": -12.0},
			{"seed": 7102, "turn_count": 20, "straightness": 0.925, "terrain_layer1_amplitude": 14.3, "forestiness": 0.45, "surface_mix": 0.4, "cliffiness": 0.5, "water_level": -12.0},
		],
		# slot 2 (difficulty tier 2)
		[
			{"seed": 2105, "turn_count": 24, "straightness": 0.6, "terrain_layer1_amplitude": 18.6, "forestiness": 0.85, "surface_mix": 0.7, "cliffiness": 0.65, "water_level": -12.0, "weather": "rain"},
			{"seed": 2204, "turn_count": 24, "straightness": 0.6, "terrain_layer1_amplitude": 18.6, "forestiness": 0.85, "surface_mix": 0.7, "cliffiness": 0.65, "water_level": -12.0, "weather": "rain"},
			{"seed": 2207, "turn_count": 24, "straightness": 0.6, "terrain_layer1_amplitude": 18.6, "forestiness": 0.85, "surface_mix": 0.7, "cliffiness": 0.65, "water_level": -12.0, "weather": "rain"},
		],
		# slot 3 (difficulty tier 2)
		[
			{"seed": 21001, "turn_count": 17, "straightness": 0.7, "terrain_layer1_amplitude": 22.9, "forestiness": 0.47, "surface_mix": 0.25, "cliffiness": 0.5, "water_level": -12.0, "weather": "rain"},
			{"seed": 21002, "turn_count": 17, "straightness": 0.7, "terrain_layer1_amplitude": 22.9, "forestiness": 0.47, "surface_mix": 0.25, "cliffiness": 0.5, "water_level": -12.0, "weather": "rain"},
			{"seed": 21003, "turn_count": 17, "straightness": 0.7, "terrain_layer1_amplitude": 22.9, "forestiness": 0.47, "surface_mix": 0.25, "cliffiness": 0.5, "water_level": -12.0, "weather": "rain"},
		],
		# slot 4 (difficulty tier 3)
		[
			{"seed": 33001, "turn_count": 30, "straightness": 0.65, "terrain_layer1_amplitude": 27.1, "forestiness": 0.7, "surface_mix": 0.7, "cliffiness": 0.6, "water_level": -12.0},
			{"seed": 35001, "turn_count": 30, "straightness": 0.65, "terrain_layer1_amplitude": 27.1, "forestiness": 0.7, "surface_mix": 0.7, "cliffiness": 0.6, "water_level": -12.0},
			{"seed": 35002, "turn_count": 30, "straightness": 0.65, "terrain_layer1_amplitude": 27.1, "forestiness": 0.7, "surface_mix": 0.7, "cliffiness": 0.6, "water_level": -12.0},
		],
		# slot 5 (difficulty tier 3)
		[
			{"seed": 35003, "turn_count": 29, "straightness": 0.6, "terrain_layer1_amplitude": 31.4, "forestiness": 0.7, "surface_mix": 0.5, "cliffiness": 0.75, "water_level": -13.0, "weather": "storm"},
			{"seed": 83001, "turn_count": 29, "straightness": 0.6, "terrain_layer1_amplitude": 31.4, "forestiness": 0.7, "surface_mix": 0.5, "cliffiness": 0.75, "water_level": -13.0, "weather": "storm"},
			{"seed": 83002, "turn_count": 29, "straightness": 0.6, "terrain_layer1_amplitude": 31.4, "forestiness": 0.7, "surface_mix": 0.5, "cliffiness": 0.75, "water_level": -13.0, "weather": "storm"},
		],
		# slot 6 (difficulty tier 4)
		[
			{"seed": 5001, "turn_count": 40, "straightness": 0.75, "terrain_layer1_amplitude": 35.7, "forestiness": 0.47, "surface_mix": 1.0, "cliffiness": 0.75, "water_level": -12.0},
			{"seed": 5003, "turn_count": 40, "straightness": 0.75, "terrain_layer1_amplitude": 35.7, "forestiness": 0.47, "surface_mix": 1.0, "cliffiness": 0.75, "water_level": -12.0},
			{"seed": 5004, "turn_count": 40, "straightness": 0.75, "terrain_layer1_amplitude": 35.7, "forestiness": 0.47, "surface_mix": 1.0, "cliffiness": 0.75, "water_level": -12.0},
		],
		# slot 7 (difficulty tier 4)
		[
			{"seed": 9003, "turn_count": 46, "straightness": 0.5, "terrain_layer1_amplitude": 40.0, "forestiness": 0.7, "surface_mix": 0.3, "cliffiness": 1.0, "water_level": -12.0, "weather": "rain"},
			{"seed": 9101, "turn_count": 46, "straightness": 0.5, "terrain_layer1_amplitude": 40.0, "forestiness": 0.7, "surface_mix": 0.3, "cliffiness": 1.0, "water_level": -12.0, "weather": "rain"},
			{"seed": 9102, "turn_count": 46, "straightness": 0.5, "terrain_layer1_amplitude": 40.0, "forestiness": 0.7, "surface_mix": 0.3, "cliffiness": 1.0, "water_level": -12.0, "weather": "rain"},
		],
	],
	"greece": [
		# slot 0 (difficulty tier 1)
		[
			{"seed": 41001, "turn_count": 16, "straightness": 0.85, "terrain_layer1_amplitude": 10.0, "forestiness": 0.28, "surface_mix": 0.2, "cliffiness": 0.35, "water_level": -11.0, "weather": "sandstorm"},
			{"seed": 41002, "turn_count": 16, "straightness": 0.85, "terrain_layer1_amplitude": 10.0, "forestiness": 0.28, "surface_mix": 0.2, "cliffiness": 0.35, "water_level": -11.0, "weather": "sandstorm"},
			{"seed": 41003, "turn_count": 16, "straightness": 0.85, "terrain_layer1_amplitude": 10.0, "forestiness": 0.28, "surface_mix": 0.2, "cliffiness": 0.35, "water_level": -11.0, "weather": "sandstorm"},
		],
		# slot 1 (difficulty tier 1)
		[
			{"seed": 51001, "turn_count": 14, "straightness": 0.875, "terrain_layer1_amplitude": 14.3, "forestiness": 0.28, "surface_mix": 0.4, "cliffiness": 0.3, "water_level": -11.0, "weather": "sandstorm"},
			{"seed": 51002, "turn_count": 14, "straightness": 0.875, "terrain_layer1_amplitude": 14.3, "forestiness": 0.28, "surface_mix": 0.4, "cliffiness": 0.3, "water_level": -11.0, "weather": "sandstorm"},
			{"seed": 51003, "turn_count": 14, "straightness": 0.875, "terrain_layer1_amplitude": 14.3, "forestiness": 0.28, "surface_mix": 0.4, "cliffiness": 0.3, "water_level": -11.0, "weather": "sandstorm"},
		],
		# slot 2 (difficulty tier 2)
		[
			{"seed": 62001, "turn_count": 24, "straightness": 0.75, "terrain_layer1_amplitude": 18.6, "forestiness": 0.3, "surface_mix": 0.6, "cliffiness": 0.7, "water_level": -12.0},
			{"seed": 62002, "turn_count": 24, "straightness": 0.75, "terrain_layer1_amplitude": 18.6, "forestiness": 0.3, "surface_mix": 0.6, "cliffiness": 0.7, "water_level": -12.0},
			{"seed": 62003, "turn_count": 24, "straightness": 0.75, "terrain_layer1_amplitude": 18.6, "forestiness": 0.3, "surface_mix": 0.6, "cliffiness": 0.7, "water_level": -12.0},
		],
		# slot 3 (difficulty tier 2)
		[
			{"seed": 62004, "turn_count": 24, "straightness": 0.7, "terrain_layer1_amplitude": 22.9, "forestiness": 0.4, "surface_mix": 0.7, "cliffiness": 0.7, "water_level": -12.0, "weather": "sandstorm"},
			{"seed": 900001, "turn_count": 24, "straightness": 0.7, "terrain_layer1_amplitude": 22.9, "forestiness": 0.4, "surface_mix": 0.7, "cliffiness": 0.7, "water_level": -12.0, "weather": "sandstorm"},
			{"seed": 900002, "turn_count": 24, "straightness": 0.7, "terrain_layer1_amplitude": 22.9, "forestiness": 0.4, "surface_mix": 0.7, "cliffiness": 0.7, "water_level": -12.0, "weather": "sandstorm"},
		],
		# slot 4 (difficulty tier 3)
		[
			{"seed": 4001, "turn_count": 33, "straightness": 0.625, "terrain_layer1_amplitude": 27.1, "forestiness": 0.29, "surface_mix": 0.6, "cliffiness": 0.55, "water_level": -11.0, "weather": "sandstorm"},
			{"seed": 4004, "turn_count": 33, "straightness": 0.625, "terrain_layer1_amplitude": 27.1, "forestiness": 0.29, "surface_mix": 0.6, "cliffiness": 0.55, "water_level": -11.0, "weather": "sandstorm"},
			{"seed": 23103, "turn_count": 33, "straightness": 0.625, "terrain_layer1_amplitude": 27.1, "forestiness": 0.29, "surface_mix": 0.6, "cliffiness": 0.55, "water_level": -11.0, "weather": "sandstorm"},
		],
		# slot 5 (difficulty tier 3)
		[
			{"seed": 23201, "turn_count": 21, "straightness": 0.65, "terrain_layer1_amplitude": 31.4, "forestiness": 0.38, "surface_mix": 0.2, "cliffiness": 0.7, "water_level": -11.0, "weather": "sandstorm"},
			{"seed": 23202, "turn_count": 21, "straightness": 0.65, "terrain_layer1_amplitude": 31.4, "forestiness": 0.38, "surface_mix": 0.2, "cliffiness": 0.7, "water_level": -11.0, "weather": "sandstorm"},
			{"seed": 63001, "turn_count": 21, "straightness": 0.65, "terrain_layer1_amplitude": 31.4, "forestiness": 0.38, "surface_mix": 0.2, "cliffiness": 0.7, "water_level": -11.0, "weather": "sandstorm"},
		],
		# slot 6 (difficulty tier 4)
		[
			{"seed": 29001, "turn_count": 51, "straightness": 0.625, "terrain_layer1_amplitude": 35.7, "forestiness": 0.28, "surface_mix": 0.15, "cliffiness": 0.85, "water_level": -11.0, "weather": "sandstorm"},
			{"seed": 29102, "turn_count": 51, "straightness": 0.625, "terrain_layer1_amplitude": 35.7, "forestiness": 0.28, "surface_mix": 0.15, "cliffiness": 0.85, "water_level": -11.0, "weather": "sandstorm"},
			{"seed": 29103, "turn_count": 51, "straightness": 0.625, "terrain_layer1_amplitude": 35.7, "forestiness": 0.28, "surface_mix": 0.15, "cliffiness": 0.85, "water_level": -11.0, "weather": "sandstorm"},
		],
		# slot 7 (difficulty tier 4)
		[
			{"seed": 43001, "turn_count": 32, "straightness": 0.6, "terrain_layer1_amplitude": 40.0, "forestiness": 0.28, "surface_mix": 0.3, "cliffiness": 0.9, "water_level": -11.0, "weather": "sandstorm"},
			{"seed": 43002, "turn_count": 32, "straightness": 0.6, "terrain_layer1_amplitude": 40.0, "forestiness": 0.28, "surface_mix": 0.3, "cliffiness": 0.9, "water_level": -11.0, "weather": "sandstorm"},
			{"seed": 43003, "turn_count": 32, "straightness": 0.6, "terrain_layer1_amplitude": 40.0, "forestiness": 0.28, "surface_mix": 0.3, "cliffiness": 0.9, "water_level": -11.0, "weather": "sandstorm"},
		],
	],
	"taiga": [
		# slot 0 (difficulty tier 1)
		[
			{"seed": 66001, "turn_count": 20, "straightness": 0.875, "terrain_layer1_amplitude": 10.0, "forestiness": 0.7, "surface_mix": 0.6, "cliffiness": 0.25, "water_level": -12.0},
			{"seed": 66002, "turn_count": 20, "straightness": 0.875, "terrain_layer1_amplitude": 10.0, "forestiness": 0.7, "surface_mix": 0.6, "cliffiness": 0.25, "water_level": -12.0},
			{"seed": 66003, "turn_count": 20, "straightness": 0.875, "terrain_layer1_amplitude": 10.0, "forestiness": 0.7, "surface_mix": 0.6, "cliffiness": 0.25, "water_level": -12.0},
		],
		# slot 1 (difficulty tier 1)
		[
			{"seed": 900003, "turn_count": 21, "straightness": 0.861, "terrain_layer1_amplitude": 14.3, "forestiness": 0.45, "surface_mix": 0.1, "cliffiness": 0.25, "water_level": -12.0},
			{"seed": 900004, "turn_count": 21, "straightness": 0.861, "terrain_layer1_amplitude": 14.3, "forestiness": 0.45, "surface_mix": 0.1, "cliffiness": 0.25, "water_level": -12.0},
			{"seed": 900005, "turn_count": 21, "straightness": 0.861, "terrain_layer1_amplitude": 14.3, "forestiness": 0.45, "surface_mix": 0.1, "cliffiness": 0.25, "water_level": -12.0},
		],
		# slot 2 (difficulty tier 2)
		[
			{"seed": 6001, "turn_count": 40, "straightness": 0.85, "terrain_layer1_amplitude": 18.6, "forestiness": 0.55, "surface_mix": 0.8, "cliffiness": 0.3, "water_level": -12.0, "weather": "night"},
			{"seed": 6003, "turn_count": 40, "straightness": 0.85, "terrain_layer1_amplitude": 18.6, "forestiness": 0.55, "surface_mix": 0.8, "cliffiness": 0.3, "water_level": -12.0, "weather": "night"},
			{"seed": 6102, "turn_count": 40, "straightness": 0.85, "terrain_layer1_amplitude": 18.6, "forestiness": 0.55, "surface_mix": 0.8, "cliffiness": 0.3, "water_level": -12.0, "weather": "night"},
		],
		# slot 3 (difficulty tier 2)
		[
			{"seed": 42001, "turn_count": 23, "straightness": 0.725, "terrain_layer1_amplitude": 22.9, "forestiness": 0.35, "surface_mix": 0.15, "cliffiness": 0.6, "water_level": -12.0, "weather": "storm"},
			{"seed": 42002, "turn_count": 23, "straightness": 0.725, "terrain_layer1_amplitude": 22.9, "forestiness": 0.35, "surface_mix": 0.15, "cliffiness": 0.6, "water_level": -12.0, "weather": "storm"},
			{"seed": 42003, "turn_count": 23, "straightness": 0.725, "terrain_layer1_amplitude": 22.9, "forestiness": 0.35, "surface_mix": 0.15, "cliffiness": 0.6, "water_level": -12.0, "weather": "storm"},
		],
		# slot 4 (difficulty tier 3)
		[
			{"seed": 53001, "turn_count": 30, "straightness": 0.775, "terrain_layer1_amplitude": 27.1, "forestiness": 0.65, "surface_mix": 0.8, "cliffiness": 0.4, "water_level": -12.0, "weather": "night"},
			{"seed": 53002, "turn_count": 30, "straightness": 0.775, "terrain_layer1_amplitude": 27.1, "forestiness": 0.65, "surface_mix": 0.8, "cliffiness": 0.4, "water_level": -12.0, "weather": "night"},
			{"seed": 53003, "turn_count": 30, "straightness": 0.775, "terrain_layer1_amplitude": 27.1, "forestiness": 0.65, "surface_mix": 0.8, "cliffiness": 0.4, "water_level": -12.0, "weather": "night"},
		],
		# slot 5 (difficulty tier 3)
		[
			{"seed": 900006, "turn_count": 44, "straightness": 0.699, "terrain_layer1_amplitude": 31.4, "forestiness": 0.45, "surface_mix": 0.1, "cliffiness": 0.75, "water_level": -12.0, "weather": "storm"},
			{"seed": 900007, "turn_count": 44, "straightness": 0.699, "terrain_layer1_amplitude": 31.4, "forestiness": 0.45, "surface_mix": 0.1, "cliffiness": 0.75, "water_level": -12.0, "weather": "storm"},
			{"seed": 900008, "turn_count": 44, "straightness": 0.699, "terrain_layer1_amplitude": 31.4, "forestiness": 0.45, "surface_mix": 0.1, "cliffiness": 0.75, "water_level": -12.0, "weather": "storm"},
		],
		# slot 6 (difficulty tier 4)
		[
			{"seed": 900009, "turn_count": 56, "straightness": 0.624, "terrain_layer1_amplitude": 35.7, "forestiness": 0.45, "surface_mix": 0.1, "cliffiness": 1.0, "water_level": -12.0, "weather": "night"},
			{"seed": 900010, "turn_count": 56, "straightness": 0.624, "terrain_layer1_amplitude": 35.7, "forestiness": 0.45, "surface_mix": 0.1, "cliffiness": 1.0, "water_level": -12.0, "weather": "night"},
			{"seed": 900011, "turn_count": 56, "straightness": 0.624, "terrain_layer1_amplitude": 35.7, "forestiness": 0.45, "surface_mix": 0.1, "cliffiness": 1.0, "water_level": -12.0, "weather": "night"},
		],
		# slot 7 (difficulty tier 4)
		[
			{"seed": 900012, "turn_count": 59, "straightness": 0.584, "terrain_layer1_amplitude": 40.0, "forestiness": 0.45, "surface_mix": 0.8, "cliffiness": 1.0, "water_level": -12.0, "weather": "rain"},
			{"seed": 900013, "turn_count": 59, "straightness": 0.584, "terrain_layer1_amplitude": 40.0, "forestiness": 0.45, "surface_mix": 0.8, "cliffiness": 1.0, "water_level": -12.0, "weather": "rain"},
			{"seed": 900014, "turn_count": 59, "straightness": 0.584, "terrain_layer1_amplitude": 40.0, "forestiness": 0.45, "surface_mix": 0.8, "cliffiness": 1.0, "water_level": -12.0, "weather": "rain"},
		],
	],
	"home_coast": [
		# slot 0 (difficulty tier 1)
		[
			{"seed": 34001, "turn_count": 16, "straightness": 0.85, "terrain_layer1_amplitude": 10.0, "forestiness": 0.57, "surface_mix": 0.3, "cliffiness": 0.35, "water_level": -7.0},
			{"seed": 34002, "turn_count": 16, "straightness": 0.85, "terrain_layer1_amplitude": 10.0, "forestiness": 0.57, "surface_mix": 0.3, "cliffiness": 0.35, "water_level": -7.0},
			{"seed": 34003, "turn_count": 16, "straightness": 0.85, "terrain_layer1_amplitude": 10.0, "forestiness": 0.57, "surface_mix": 0.3, "cliffiness": 0.35, "water_level": -7.0},
		],
		# slot 1 (difficulty tier 1)
		[
			{"seed": 900015, "turn_count": 17, "straightness": 0.757, "terrain_layer1_amplitude": 14.3, "forestiness": 0.631, "surface_mix": 0.1, "cliffiness": 0.35, "water_level": -7.0},
			{"seed": 900016, "turn_count": 17, "straightness": 0.757, "terrain_layer1_amplitude": 14.3, "forestiness": 0.631, "surface_mix": 0.1, "cliffiness": 0.35, "water_level": -7.0},
			{"seed": 900017, "turn_count": 17, "straightness": 0.757, "terrain_layer1_amplitude": 14.3, "forestiness": 0.631, "surface_mix": 0.1, "cliffiness": 0.35, "water_level": -7.0},
		],
		# slot 2 (difficulty tier 2)
		[
			{"seed": 65001, "turn_count": 22, "straightness": 0.664, "terrain_layer1_amplitude": 18.6, "forestiness": 0.693, "surface_mix": 0.4, "cliffiness": 0.45, "water_level": -7.0},
			{"seed": 65002, "turn_count": 22, "straightness": 0.664, "terrain_layer1_amplitude": 18.6, "forestiness": 0.693, "surface_mix": 0.4, "cliffiness": 0.45, "water_level": -7.0},
			{"seed": 65003, "turn_count": 22, "straightness": 0.664, "terrain_layer1_amplitude": 18.6, "forestiness": 0.693, "surface_mix": 0.4, "cliffiness": 0.45, "water_level": -7.0},
		],
		# slot 3 (difficulty tier 2)
		[
			{"seed": 65004, "turn_count": 22, "straightness": 0.571, "terrain_layer1_amplitude": 22.9, "forestiness": 0.754, "surface_mix": 0.35, "cliffiness": 0.55, "water_level": -7.0},
			{"seed": 900018, "turn_count": 22, "straightness": 0.571, "terrain_layer1_amplitude": 22.9, "forestiness": 0.754, "surface_mix": 0.35, "cliffiness": 0.55, "water_level": -7.0},
			{"seed": 900019, "turn_count": 22, "straightness": 0.571, "terrain_layer1_amplitude": 22.9, "forestiness": 0.754, "surface_mix": 0.35, "cliffiness": 0.55, "water_level": -7.0},
		],
		# slot 4 (difficulty tier 3)
		[
			{"seed": 3001, "turn_count": 29, "straightness": 0.479, "terrain_layer1_amplitude": 27.1, "forestiness": 0.816, "surface_mix": 0.5, "cliffiness": 0.4, "water_level": -7.0, "weather": "rain"},
			{"seed": 3004, "turn_count": 29, "straightness": 0.479, "terrain_layer1_amplitude": 27.1, "forestiness": 0.816, "surface_mix": 0.5, "cliffiness": 0.4, "water_level": -7.0, "weather": "rain"},
			{"seed": 3012, "turn_count": 29, "straightness": 0.479, "terrain_layer1_amplitude": 27.1, "forestiness": 0.816, "surface_mix": 0.5, "cliffiness": 0.4, "water_level": -7.0, "weather": "rain"},
		],
		# slot 5 (difficulty tier 3)
		[
			{"seed": 22001, "turn_count": 20, "straightness": 0.386, "terrain_layer1_amplitude": 31.4, "forestiness": 0.877, "surface_mix": 0.1, "cliffiness": 0.8, "water_level": -7.0, "weather": "night"},
			{"seed": 22102, "turn_count": 20, "straightness": 0.386, "terrain_layer1_amplitude": 31.4, "forestiness": 0.877, "surface_mix": 0.1, "cliffiness": 0.8, "water_level": -7.0, "weather": "night"},
			{"seed": 22203, "turn_count": 20, "straightness": 0.386, "terrain_layer1_amplitude": 31.4, "forestiness": 0.877, "surface_mix": 0.1, "cliffiness": 0.8, "water_level": -7.0, "weather": "night"},
		],
		# slot 6 (difficulty tier 4)
		[
			{"seed": 36001, "turn_count": 35, "straightness": 0.293, "terrain_layer1_amplitude": 35.7, "forestiness": 0.939, "surface_mix": 1.0, "cliffiness": 0.75, "water_level": -4.0},
			{"seed": 36002, "turn_count": 35, "straightness": 0.293, "terrain_layer1_amplitude": 35.7, "forestiness": 0.939, "surface_mix": 1.0, "cliffiness": 0.75, "water_level": -4.0},
			{"seed": 36003, "turn_count": 35, "straightness": 0.293, "terrain_layer1_amplitude": 35.7, "forestiness": 0.939, "surface_mix": 1.0, "cliffiness": 0.75, "water_level": -4.0},
		],
		# slot 7 (difficulty tier 4)
		[
			{"seed": 900020, "turn_count": 45, "straightness": 0.2, "terrain_layer1_amplitude": 40.0, "forestiness": 1.0, "surface_mix": 0.1, "cliffiness": 0.9, "water_level": -7.0, "weather": "night"},
			{"seed": 900021, "turn_count": 45, "straightness": 0.2, "terrain_layer1_amplitude": 40.0, "forestiness": 1.0, "surface_mix": 0.1, "cliffiness": 0.9, "water_level": -7.0, "weather": "night"},
			{"seed": 900022, "turn_count": 45, "straightness": 0.2, "terrain_layer1_amplitude": 40.0, "forestiness": 1.0, "surface_mix": 0.1, "cliffiness": 0.9, "water_level": -7.0, "weather": "night"},
		],
	],
	"snow": [
		# slot 0 (difficulty tier 1)
		[
			{"seed": 85001, "turn_count": 24, "straightness": 0.85, "terrain_layer1_amplitude": 10.0, "forestiness": 0.52, "surface_mix": 0.3, "cliffiness": 0.7, "water_level": -12.0, "weather": "snow"},
			{"seed": 85002, "turn_count": 24, "straightness": 0.85, "terrain_layer1_amplitude": 10.0, "forestiness": 0.52, "surface_mix": 0.3, "cliffiness": 0.7, "water_level": -12.0, "weather": "snow"},
			{"seed": 85003, "turn_count": 24, "straightness": 0.85, "terrain_layer1_amplitude": 10.0, "forestiness": 0.52, "surface_mix": 0.3, "cliffiness": 0.7, "water_level": -12.0, "weather": "snow"},
		],
		# slot 1 (difficulty tier 1)
		[
			{"seed": 900023, "turn_count": 25, "straightness": 0.848, "terrain_layer1_amplitude": 14.3, "forestiness": 0.4, "surface_mix": 0.15, "cliffiness": 0.7, "water_level": -12.0},
			{"seed": 900024, "turn_count": 25, "straightness": 0.848, "terrain_layer1_amplitude": 14.3, "forestiness": 0.4, "surface_mix": 0.15, "cliffiness": 0.7, "water_level": -12.0},
			{"seed": 900025, "turn_count": 25, "straightness": 0.848, "terrain_layer1_amplitude": 14.3, "forestiness": 0.4, "surface_mix": 0.15, "cliffiness": 0.7, "water_level": -12.0},
		],
		# slot 2 (difficulty tier 2)
		[
			{"seed": 86001, "turn_count": 30, "straightness": 0.75, "terrain_layer1_amplitude": 18.6, "forestiness": 0.48, "surface_mix": 0.2, "cliffiness": 0.85, "water_level": -12.0, "weather": "snow"},
			{"seed": 86002, "turn_count": 30, "straightness": 0.75, "terrain_layer1_amplitude": 18.6, "forestiness": 0.48, "surface_mix": 0.2, "cliffiness": 0.85, "water_level": -12.0, "weather": "snow"},
			{"seed": 86003, "turn_count": 30, "straightness": 0.75, "terrain_layer1_amplitude": 18.6, "forestiness": 0.48, "surface_mix": 0.2, "cliffiness": 0.85, "water_level": -12.0, "weather": "snow"},
		],
		# slot 3 (difficulty tier 2)
		[
			{"seed": 87001, "turn_count": 32, "straightness": 0.7, "terrain_layer1_amplitude": 22.9, "forestiness": 0.46, "surface_mix": 0.4, "cliffiness": 0.85, "water_level": -12.0, "weather": "snow"},
			{"seed": 87002, "turn_count": 32, "straightness": 0.7, "terrain_layer1_amplitude": 22.9, "forestiness": 0.46, "surface_mix": 0.4, "cliffiness": 0.85, "water_level": -12.0, "weather": "snow"},
			{"seed": 87003, "turn_count": 32, "straightness": 0.7, "terrain_layer1_amplitude": 22.9, "forestiness": 0.46, "surface_mix": 0.4, "cliffiness": 0.85, "water_level": -12.0, "weather": "snow"},
		],
		# slot 4 (difficulty tier 3)
		[
			{"seed": 88001, "turn_count": 38, "straightness": 0.62, "terrain_layer1_amplitude": 27.1, "forestiness": 0.43, "surface_mix": 0.35, "cliffiness": 0.9, "water_level": -13.0, "weather": "snow"},
			{"seed": 88002, "turn_count": 38, "straightness": 0.62, "terrain_layer1_amplitude": 27.1, "forestiness": 0.43, "surface_mix": 0.35, "cliffiness": 0.9, "water_level": -13.0, "weather": "snow"},
			{"seed": 88003, "turn_count": 38, "straightness": 0.62, "terrain_layer1_amplitude": 27.1, "forestiness": 0.43, "surface_mix": 0.35, "cliffiness": 0.9, "water_level": -13.0, "weather": "snow"},
		],
		# slot 5 (difficulty tier 3)
		[
			{"seed": 900026, "turn_count": 42, "straightness": 0.585, "terrain_layer1_amplitude": 31.4, "forestiness": 0.4, "surface_mix": 0.15, "cliffiness": 0.9, "water_level": -12.0, "weather": "night"},
			{"seed": 900027, "turn_count": 42, "straightness": 0.585, "terrain_layer1_amplitude": 31.4, "forestiness": 0.4, "surface_mix": 0.15, "cliffiness": 0.9, "water_level": -12.0, "weather": "night"},
			{"seed": 900028, "turn_count": 42, "straightness": 0.585, "terrain_layer1_amplitude": 31.4, "forestiness": 0.4, "surface_mix": 0.15, "cliffiness": 0.9, "water_level": -12.0, "weather": "night"},
		],
		# slot 6 (difficulty tier 4)
		[
			{"seed": 89001, "turn_count": 46, "straightness": 0.52, "terrain_layer1_amplitude": 35.7, "forestiness": 0.43, "surface_mix": 0.3, "cliffiness": 0.95, "water_level": -13.0, "weather": "snow"},
			{"seed": 89002, "turn_count": 46, "straightness": 0.52, "terrain_layer1_amplitude": 35.7, "forestiness": 0.43, "surface_mix": 0.3, "cliffiness": 0.95, "water_level": -13.0, "weather": "snow"},
			{"seed": 89003, "turn_count": 46, "straightness": 0.52, "terrain_layer1_amplitude": 35.7, "forestiness": 0.43, "surface_mix": 0.3, "cliffiness": 0.95, "water_level": -13.0, "weather": "snow"},
		],
		# slot 7 (difficulty tier 4)
		[
			{"seed": 89101, "turn_count": 48, "straightness": 0.46, "terrain_layer1_amplitude": 40.0, "forestiness": 0.41, "surface_mix": 0.35, "cliffiness": 1.0, "water_level": -13.0, "weather": "snow"},
			{"seed": 89102, "turn_count": 48, "straightness": 0.46, "terrain_layer1_amplitude": 40.0, "forestiness": 0.41, "surface_mix": 0.35, "cliffiness": 1.0, "water_level": -13.0, "weather": "snow"},
			{"seed": 89103, "turn_count": 48, "straightness": 0.46, "terrain_layer1_amplitude": 40.0, "forestiness": 0.41, "surface_mix": 0.35, "cliffiness": 1.0, "water_level": -13.0, "weather": "snow"},
		],
	],
}


# --- Catalogue seam ------------------------------------------------------------------
# Same override_for_test()/reset() shape as CarLibrary/EngineLibrary/RallyLibrary, but
# NOT Registry.Seam: that helper is built for a flat Array[Dictionary] roster, and this
# catalogue's shape is {region_id: [8 slots of 3 candidates]}. An empty override means
# "use the shipped STAGES", exactly like the other catalogues.
static var _override: Dictionary = {}

static func override_for_test(regions: Dictionary) -> void:
	_override = regions

static func reset() -> void:
	_override = {}

static func all() -> Dictionary:
	return _override if not _override.is_empty() else STAGES


# region_id's 8 slots, each an Array of 3 authored candidate Dictionaries (no stamping —
# callers that need region/slot/candidate provenance go through RegionStagePool.draw or
# all_stages_in, which stamp it). Empty Array for an unknown region id.
static func slots_in(region_id: String) -> Array:
	return all().get(region_id, [])


# Every stage of `region_id`, fully stamped with region/slot/candidate — the flat view
# the offline cache baker and the structural tests walk (24 dicts per region, 120 total
# across the catalogue when STAGES is unmodified).
static func all_stages_in(region_id: String) -> Array:
	var out: Array = []
	var slots := slots_in(region_id)
	for slot_index in slots.size():
		var candidates: Array = slots[slot_index]
		for candidate_index in candidates.size():
			var stage: Dictionary = (candidates[candidate_index] as Dictionary).duplicate(true)
			stage["region"] = region_id
			stage["slot"] = slot_index
			stage["candidate"] = candidate_index
			out.append(stage)
	return out


# Every stage of every region, fully stamped — used by TrackCache.all_event_keys and
# tools/generate_track_cache.gd to enumerate the whole catalogue.
static func all_stages() -> Array:
	var out: Array = []
	for region_id in all().keys():
		out.append_array(all_stages_in(region_id))
	return out


static func region_ids() -> Array:
	return all().keys()
