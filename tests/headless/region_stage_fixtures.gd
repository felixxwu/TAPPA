class_name RegionStageFixtures
extends RefCounted
# A synthetic RegionStageLibrary catalogue for tests, mirroring CarFixtures. Install it
# (install()) to run against a stable, test-owned stage roster that never tracks the
# shipped STAGES, so retuning a real region's authored stages can't break a logic test.
# Always restore() in teardown.
#
# One region ("home", a structural id RegionLibrary always ships), 8 slots, 3 candidates
# per slot — the full shape RegionStagePool.draw expects. Every event sets a very low
# water_level so track generation never has to route around lakes — a fixture stage
# generates fast and deterministically.

const SEED_BASE := 100000


static func _candidate(slot: int, candidate: int) -> Dictionary:
	var seed_value := SEED_BASE + slot * 10 + candidate
	return {
		"seed": seed_value, "turn_count": 6,
		"forestiness": 0.4, "surface_mix": 0.5, "straightness": 0.6,
		"cliffiness": 0.3, "water_level": -50.0, "terrain_layer1_amplitude": 12.0,
		"weather": StageFields.WEATHER_DRY,
	}


static func stages() -> Dictionary:
	var slots: Array = []
	for slot in 8:
		var candidates: Array = []
		for candidate in 3:
			candidates.append(_candidate(slot, candidate))
		slots.append(candidates)
	return {"home": slots}


static func install() -> void:
	RegionStageLibrary.override_for_test(stages())


static func restore() -> void:
	RegionStageLibrary.reset()


# A single stamped stage dict — the shape RegionStagePool.draw/all_stages_in produce —
# for a test that just wants "one event to generate", the fx_open replacement.
static func one_stage() -> Dictionary:
	var stage := _candidate(0, 0)
	stage["region"] = "home"
	stage["slot"] = 0
	stage["candidate"] = 0
	return stage
