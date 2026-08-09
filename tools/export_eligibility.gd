extends Node
# Export the rally x car eligibility matrix to JSON, for tools/fit_map_pins.py.
#
# WHY THIS EXISTS. The pin fitter needs to know whether a player can actually ENTER a rally,
# not just reach its pin — a map whose frontier is full of rallies the garage cannot drive
# is soft-locked however elegant its geometry. But eligibility is decided by
# RallyLibrary.is_eligible, which lives in GDScript and reads the car catalogue, the engine
# catalogue and the upgrade rules. Reimplementing that in Python would duplicate the
# game's central progression rule in a second language, and the copy would drift the first
# time a band was retuned.
#
# So: compute it HERE with the real predicate, and hand the fitter a lookup table.
#
# The reason this works at all is that eligibility does NOT depend on map_pos. Bands and
# cars decide it; the fitter only ever moves pins. So the matrix is computed once and stays
# valid for the whole anneal — it only needs regenerating when a restriction band, a car or
# an engine changes.
#
# "Can enter" matches what the car park actually allows: eligible outright, OR able to duck
# under a pw_max ceiling by detuning, with the pw_min floor judged at the car's MAX
# potential (the player may always tune up for free). Same three allowances as
# hq._entry_plan, so the fitter and the game agree on who can start what.
#
# Run via ./export_eligibility.sh.

const OUT_PATH := "res://data/eligibility.json"


func _ready() -> void:
	var matrix := {}
	for rally in RallyLibrary.all():
		var admitted: Array = []
		for spec in CarLibrary.all():
			var car := {"model_id": String(spec.get("id", "")), "instance_id": 1,
				"installed_upgrades": [], "disabled_upgrades": [], "tuning": {}}
			var meta := UpgradeLibrary.effective_meta(car, spec)
			var floor_meta := UpgradeLibrary.max_potential_meta(car, spec)
			if RallyLibrary.is_eligible(rally, meta, floor_meta) \
					or RallyLibrary.qualifying_detune(rally, meta) > 0.0:
				admitted.append(String(spec.get("id", "")))
		matrix[String(rally["id"])] = admitted

	var payload := {
		"cars": _car_ids(),
		"starters": CarLibrary.STARTER_MODEL_IDS,
		# rally_id -> the car ids that can enter it.
		"eligible": matrix,
		# rally_id -> the car it awards ("" for none), so the fitter can grow the garage as
		# its closure walks outward.
		"prize_car": _prizes(),
		# car_id -> stock power-to-weight in hp/tonne. The fitter ranks car prizes by this to
		# push FASTER cars further from HQ, so the long drive to a corner is what earns the
		# quick machinery. Deliberately not CarLibrary.reward_tier, which is a curated slot in
		# the reward ladder rather than a measure of pace — a tier-2 car can be quicker than a
		# tier-3 one, and ordering the map by it put a fast car on HQ's doorstep.
		"power_to_weight": _power_to_weight(),
	}
	var f := FileAccess.open(OUT_PATH, FileAccess.WRITE)
	f.store_string(JSON.stringify(payload, "  "))
	f.close()
	var thin := 0
	for rid in matrix:
		if (matrix[rid] as Array).size() <= 1:
			thin += 1
	print("wrote %s: %d rallies x %d cars (%d rallies admit <= 1 car)"
		% [OUT_PATH, matrix.size(), CarLibrary.all().size(), thin])
	get_tree().quit()


# Registry has no id-list helper (only index_of/by_id/names), so build it here.
func _car_ids() -> Array:
	var out: Array = []
	for spec in CarLibrary.all():
		out.append(String(spec.get("id", "")))
	return out


func _power_to_weight() -> Dictionary:
	var out := {}
	for spec in CarLibrary.all():
		var meta := UpgradeLibrary.effective_meta({}, spec)
		out[String(spec.get("id", ""))] = CarLibrary.power_to_weight_hp_tonne(meta)
	return out


func _prizes() -> Dictionary:
	var out := {}
	for rally in RallyLibrary.all():
		out[String(rally["id"])] = RallyLibrary.prize_car_id(rally)
	return out
