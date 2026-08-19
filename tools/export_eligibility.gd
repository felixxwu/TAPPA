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
# valid for the whole anneal — it only needs regenerating when a restriction, a car or
# an engine changes.
#
# "Can enter" is now exactly RallyLibrary.is_eligible: entry is purely CATEGORICAL
# (car_type / country / doors / cylinders / displacement / drive_mode), so there is no
# tuning or detuning allowance to model — the fitter and the game agree by construction.
#
# Run via ./export_eligibility.sh.

const OUT_PATH := "res://data/eligibility.json"

# Fingerprint over exactly what the ELIGIBILITY matrix depends on, mirroring
# TrackCache's source_hash pattern (scripts/track_cache.gd) so a drift between
# rally_library.gd's restriction bands / the car+engine catalogues and the
# committed data/eligibility.json fails loudly instead of silently. Deliberately
# NOT a hash of everything the exporter reads:
#   - Rally restriction dicts (RallyLibrary.is_eligible's whole input) — any
#     edit here changes who can enter, which is exactly what this guards.
#   - Per-car CATEGORICAL fields ineligibility_reason actually branches on
#     (drive_mode, country, car_type, doors, and the fitted engine id) — not
#     mass/torque/grip/etc, which are tunables that must NOT churn this hash
#     (see CLAUDE.md: never let a retune invalidate a matrix that doesn't
#     depend on it).
#   - Per-engine fields ineligibility_reason resolves through the engine
#     (displacement_l, cylinder count) — again not torque/redline/tunables.
#   - The full car and rally id sets, so adding/removing an entry (like the
#     six snow rallies that went missing) is caught even if no band changed.
# power_to_weight is intentionally excluded: it's a pace metric the fitter
# uses for pin placement, not an eligibility input, and it DOES depend on
# tunables (mass, torque) that must stay free to retune without invalidating
# this guard.
static func compute_source_hash() -> String:
	var parts := PackedStringArray()
	for rally in RallyLibrary.all():
		var r: Dictionary = rally.get("restriction", {})
		parts.append("rally:%s=%s" % [String(rally["id"]), JSON.stringify(r, "", true)])
	for spec in CarLibrary.all():
		var meta := UpgradeLibrary.effective_meta({}, spec)
		parts.append("car:%s=%s|%s|%s|%s|%s" % [String(spec.get("id", "")),
			str(meta.get("drive_mode", -1)), String(meta.get("country", "")),
			String(meta.get("car_type", "")), str(meta.get("doors", 0)),
			String(meta.get("engine", ""))])
	for eng in EngineLibrary.all():
		parts.append("engine:%s=%s|%s" % [String(eng.get("id", "")),
			str(eng.get("displacement_l", 0.0)), str(EngineLibrary.cylinders(eng))])
	parts.sort()
	return "|".join(parts).sha256_text()


func _ready() -> void:
	var matrix := {}
	for rally in RallyLibrary.all():
		var admitted: Array = []
		for spec in CarLibrary.all():
			var car := {"model_id": String(spec.get("id", "")), "instance_id": 1,
				"installed_upgrades": [], "disabled_upgrades": [], "tuning": {}}
			var meta := UpgradeLibrary.effective_meta(car, spec)
			if RallyLibrary.is_eligible(rally, meta):
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
		# car_id -> stock power-to-weight in hp/tonne. NOT an eligibility currency any more
		# (entry is categorical) — this is purely the fitter's pin-placement metric, and it
		# must stay exactly this metric: tools/fit_map_pins.py places pins from it, so
		# swapping in (say) CarPerformance.rating would silently re-derive the revealed-rally
		# frontier for every existing save. Leave it alone.
		# The fitter ranks car prizes by this to
		# push FASTER cars further from HQ, so the long drive to a corner is what earns the
		# quick machinery. Deliberately not CarLibrary.reward_tier, which is a curated slot in
		# the reward ladder rather than a measure of pace — a tier-2 car can be quicker than a
		# tier-3 one, and ordering the map by it put a fast car on HQ's doorstep.
		"power_to_weight": _power_to_weight(),
		# Freshness guard, mirroring data/track_cache.json's source_hash — see
		# compute_source_hash() above for exactly what's hashed and why.
		"source_hash": compute_source_hash(),
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
