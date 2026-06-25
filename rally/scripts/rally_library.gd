class_name RallyLibrary
extends RefCounted
# The finite, curated list of rallies — authored CONTENT (like CarLibrary), not
# player state. A rally is a fixed set of 3 seeded TrackGenerator tracks plus a
# car restriction and a difficulty tier; player completion lives in the save
# profile (todo/save-persistence.md), keyed by the stable `id` here.
#
# This file is also the home of the pure functions the rest of the game needs:
#   * is_eligible(rally, car_meta)            — can this car enter?
#   * derive_target_ms(track_result)          — per-event target time from a track
#   * generate_opponent_field(rally, targets) — the deterministic opponent field
#   * completed_count / showdown_unlocked      — progress + end-game gate
#   * incomplete_rallies_enterable_by(...)     — the anti-soft-lock query
#
# Determinism is the whole point: TrackGenerator.generate is deterministic for a
# given (seed, turn_count, width), and the opponent field is reseeded from the
# rally id, so re-attempting a rally chases the SAME fixed leaderboard (damage
# sticks; opponents never re-roll).

# Default event width when an EventDef omits one. Mirrors GameConfig.track_width
# (game_config.gd) — the authored baseline track width.
const DEFAULT_WIDTH := 6.0

# Placeholder target-time formula constants. The real length/corner-mix → seconds
# function and its difficulty weights are a calibration pass (gameplay.md / the
# rally-roster spec); these live here as authored defaults until that lands, at
# which point the weights move to GameConfig.
const REF_SPEED_MPS := 28.0      # ~100 km/h reference pace over the centerline
const CORNER_PENALTY_S := 1.1    # seconds added per non-straight piece

# Opponent-field shape (gameplay.md): 10–15 rivals, some DNF (a DNF in any event
# disqualifies the rally).
const FIELD_MIN := 10
const FIELD_MAX := 15
const DNF_CHANCE := 0.18         # per-opponent, per-event

# Rival pace band, as multiples of the event target time: each clean rival's
# event time is uniform in [target × RIVAL_PACE_MIN, target × (RIVAL_PACE_MIN +
# RIVAL_PACE_SPREAD)]. The floor sits above the target so even the quickest
# rival runs slower than the target pace, keeping the field beatable; raise the
# floor to make rivals easier, lower it to make them tougher.
const RIVAL_PACE_MIN := 1.35
const RIVAL_PACE_SPREAD := 1.0


# Each entry: a RallyDef. `restriction` is an empty Dictionary for open-class
# (every car eligible); otherwise every present field must match the car's
# CarLibrary metadata. `events` is exactly 3 EventDefs (the showdown's are
# longer). Exactly one entry has `showdown = true`.
const RALLIES: Array[Dictionary] = [
	{
		"id": "shakedown", "name": "Shakedown", "difficulty": 1, "showdown": false,
		"restriction": {},  # open-class anti-soft-lock floor
		"events": [
			{"seed": 1001, "turn_count": 10},
			{"seed": 1002, "turn_count": 12},
			{"seed": 1003, "turn_count": 11},
		],
	},
	{
		"id": "coastal_sprint", "name": "Coastal Sprint", "difficulty": 2, "showdown": false,
		"restriction": {},  # open-class
		"events": [
			{"seed": 2001, "turn_count": 14},
			{"seed": 2002, "turn_count": 13},
			{"seed": 2003, "turn_count": 15},
		],
	},
	{
		"id": "rwd_masters", "name": "RWD Masters", "difficulty": 2, "showdown": false,
		"restriction": {"drive_mode": CarLibrary.RWD},
		"events": [
			{"seed": 3001, "turn_count": 13},
			{"seed": 3002, "turn_count": 14},
			{"seed": 3003, "turn_count": 13},
		],
	},
	{
		"id": "rising_sun", "name": "Rising Sun Rally", "difficulty": 3, "showdown": false,
		"restriction": {"country": "JP"},
		"events": [
			{"seed": 4001, "turn_count": 16},
			{"seed": 4002, "turn_count": 15},
			{"seed": 4003, "turn_count": 17},
		],
	},
	{
		"id": "grand_tour", "name": "Grand Tour", "difficulty": 3, "showdown": false,
		"restriction": {},  # open-class at the top reachable tier
		"events": [
			{"seed": 5001, "turn_count": 18},
			{"seed": 5002, "turn_count": 17},
			{"seed": 5003, "turn_count": 19},
		],
	},
	{
		"id": "the_showdown", "name": "The Showdown", "difficulty": 4, "showdown": true,
		"restriction": {},  # open so the immortal starter can always finish the game
		"events": [
			{"seed": 9001, "turn_count": 22},
			{"seed": 9002, "turn_count": 24},
			{"seed": 9003, "turn_count": 22},
		],
	},
]


# --- Lookups -----------------------------------------------------------------

static func index_of(id: String) -> int:
	for i in RALLIES.size():
		if RALLIES[i]["id"] == id:
			return i
	return -1


static func by_id(id: String) -> Dictionary:
	var i := index_of(id)
	return RALLIES[i] if i >= 0 else {}


# Width an event runs at — its override, else the authored default.
static func event_width(event: Dictionary) -> float:
	return float(event.get("width", DEFAULT_WIDTH))


# --- Eligibility -------------------------------------------------------------

# Whether `car_meta` (a CarLibrary entry dict, resolved by the owned car's stable
# model_id — never array index) satisfies a rally's restriction. Open-class
# (empty restriction) always matches.
static func is_eligible(rally: Dictionary, car_meta: Dictionary) -> bool:
	var r: Dictionary = rally.get("restriction", {})
	if r.is_empty():
		return true
	if r.has("drive_mode") and int(car_meta.get("drive_mode", -1)) != int(r["drive_mode"]):
		return false
	if r.has("country") and String(car_meta.get("country", "")) != String(r["country"]):
		return false
	if r.has("car_type") and String(car_meta.get("car_type", "")) != String(r["car_type"]):
		return false
	if r.has("engine_min_l") and float(car_meta.get("engine_displacement_l", 0.0)) < float(r["engine_min_l"]):
		return false
	if r.has("engine_max_l") and float(car_meta.get("engine_displacement_l", 0.0)) > float(r["engine_max_l"]):
		return false
	var pw := CarLibrary.power_to_weight(car_meta)
	if r.has("pw_min") and pw < float(r["pw_min"]):
		return false
	if r.has("pw_max") and pw > float(r["pw_max"]):
		return false
	return true


# --- Target time (derived from the seeded track, not stored) -----------------

# Per-event target time in milliseconds, derived from a TrackGenerator result
# (its `centerline` length + the corner mix in `pieces`). An event may override
# this with `target_ms_override`. Deterministic for a given track.
static func derive_target_ms(track_result: Dictionary, event: Dictionary = {}) -> int:
	if event.has("target_ms_override"):
		return int(event["target_ms_override"])
	var centerline := track_result.get("centerline") as Curve2D
	var length: float = centerline.get_baked_length() if centerline != null else 0.0
	var corner_count := 0
	for piece in track_result.get("pieces", []):
		if String(piece.get("corner", "")) != "Straight":
			corner_count += 1
	var target_s := length / REF_SPEED_MPS + corner_count * CORNER_PENALTY_S
	return int(round(target_s * 1000.0))


# --- Opponent field (recomputed from the rally seed, never saved) ------------

# The fixed opponent field for a rally, given each event's target time (ms).
# Reseeded from the rally id so the leaderboard is identical across re-attempts.
# Returns an Array of opponents:
#   { name: String, event_times_ms: Array[int], dnf: bool, combined_ms: int }
# A DNF in any event disqualifies the opponent (combined_ms = -1, doesn't rank).
static func generate_opponent_field(rally: Dictionary, event_target_ms: Array) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = _rally_seed(rally)
	var count := rng.randi_range(FIELD_MIN, FIELD_MAX)
	var field: Array = []
	for i in count:
		var times: Array = []
		var dnf := false
		for target in event_target_ms:
			if rng.randf() < DNF_CHANCE:
				dnf = true
				times.append(-1)
			else:
				# Slower than target pace by a random margin within the band.
				times.append(int(round(target * (RIVAL_PACE_MIN + rng.randf() * RIVAL_PACE_SPREAD))))
		var combined := -1
		if not dnf:
			combined = 0
			for t in times:
				combined += int(t)
		field.append({
			"name": "Rival %d" % (i + 1),
			"event_times_ms": times,
			"dnf": dnf,
			"combined_ms": combined,
		})
	return field


# Player's 1-based placement on combined time among the non-DNF field (the
# player counts as one entrant). A faster combined time places ahead.
static func placement(field: Array, player_combined_ms: int) -> int:
	var ahead := 0
	for opp in field:
		if not opp.get("dnf", false) and int(opp["combined_ms"]) < player_combined_ms:
			ahead += 1
	return ahead + 1


static func is_top3(field: Array, player_combined_ms: int) -> bool:
	return placement(field, player_combined_ms) <= 3


# A fully ranked standings table for the results screen (todo/menus.md overlay 7):
# the opponent field plus the player, sorted fastest-combined-first with the DNF
# entries (wrecked / disqualified) sinking to the bottom. Each entry:
#   { name:String, combined_ms:int, dnf:bool, is_player:bool, placed:int }
# `placed` is the 1-based finishing position among the classified (non-DNF)
# entries; DNF entries get placed = -1. Consistent with placement() — a non-DNF
# player's `placed` equals placement(field, player_combined_ms).
static func build_standings(field: Array, player_combined_ms: int, player_dnf: bool, player_name := "You") -> Array:
	var entries: Array = []
	for opp in field:
		entries.append({
			"name": String(opp.get("name", "Rival")),
			"combined_ms": int(opp.get("combined_ms", -1)),
			"dnf": bool(opp.get("dnf", false)),
			"is_player": false,
		})
	entries.append({
		"name": player_name,
		"combined_ms": player_combined_ms,
		"dnf": player_dnf,
		"is_player": true,
	})
	# Classified entries sort by combined time ascending; DNFs always trail them.
	entries.sort_custom(func(a, b):
		if bool(a["dnf"]) != bool(b["dnf"]):
			return not bool(a["dnf"])
		if bool(a["dnf"]):
			return false
		return int(a["combined_ms"]) < int(b["combined_ms"]))
	var pos := 0
	for e in entries:
		if bool(e["dnf"]):
			e["placed"] = -1
		else:
			pos += 1
			e["placed"] = pos
	return entries


# Deterministic integer seed for a rally's opponent field: folds the stable id
# with the first event seed so two rallies never share a field by accident.
static func _rally_seed(rally: Dictionary) -> int:
	var base := int(String(rally.get("id", "")).hash())
	var events: Array = rally.get("events", [])
	if not events.is_empty():
		base = base ^ int(events[0].get("seed", 0))
	return base


# --- Progress / showdown / anti-soft-lock ------------------------------------

# Count of completed rallies in a save profile — the single progression metric
# (caps reward tier + gates the showdown).
static func completed_count(profile: Dictionary) -> int:
	var rallies: Dictionary = profile.get("rallies", {})
	var n := 0
	for rally_id in rallies:
		if rallies[rally_id].get("completed", false):
			n += 1
	return n


# The showdown is enterable only when every non-showdown rally is completed.
static func showdown_unlocked(profile: Dictionary) -> bool:
	var rallies: Dictionary = profile.get("rallies", {})
	for rally in RALLIES:
		if rally["showdown"]:
			continue
		if not rallies.get(rally["id"], {}).get("completed", false):
			return false
	return true


# Anti-soft-lock query for the reward system: the still-incomplete rallies a
# given car can currently enter (eligible, and the showdown only if unlocked).
static func incomplete_rallies_enterable_by(car_meta: Dictionary, profile: Dictionary) -> Array:
	var rallies: Dictionary = profile.get("rallies", {})
	var out: Array = []
	var sd_unlocked := showdown_unlocked(profile)
	for rally in RALLIES:
		if rallies.get(rally["id"], {}).get("completed", false):
			continue
		if rally["showdown"] and not sd_unlocked:
			continue
		if is_eligible(rally, car_meta):
			out.append(rally)
	return out
