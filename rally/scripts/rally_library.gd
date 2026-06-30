class_name RallyLibrary
extends RefCounted
# The finite, curated list of rallies — authored CONTENT (like CarLibrary), not
# player state. A rally is a fixed set of 3 seeded TrackGenerator tracks plus a
# car restriction and a difficulty tier; player completion lives in the save
# profile (todo/save-persistence.md), keyed by the stable `id` here.
#
# This file is also the home of the pure functions the rest of the game needs:
#   * is_eligible(rally, car_meta)            — can this car enter?
#   * generate_opponent_field(rally, event_results, events) — the deterministic opponent field
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

# Opponent-field shape (gameplay.md): 10–15 rivals, some DNF (a DNF in any event
# disqualifies the rally).
const FIELD_MIN := 10
const FIELD_MAX := 15
const DNF_CHANCE := 0.18         # per-opponent, per-event

# Rival pace band, as multiples of each rival's OWN physics floor (optimum_ms for
# THEIR car on the event track): each clean rival's event time is uniform in
# [floor × RIVAL_PACE_MIN, floor × (RIVAL_PACE_MIN + RIVAL_PACE_SPREAD)].
# Raise RIVAL_PACE_MIN to make rivals easier (their times inflate further above
# their floor); lower it to make them tougher. At 1.0 the quickest possible rival
# drives a flawless lap (exactly their car's physics floor). RIVAL_PACE_SPREAD
# controls how spread out the field is.
const RIVAL_PACE_MIN := 1.3
const RIVAL_PACE_SPREAD := 1.0


# Each entry: a RallyDef. `restriction` is an empty Dictionary for open-class
# (every car eligible); otherwise every present field must match the car's
# CarLibrary metadata. Progression is PRIMARILY gated on power-to-weight: the
# earliest rallies are gated only from above (a `pw_max` ceiling, so the low-power
# starter qualifies), and the harder rallies tighten to a band (`pw_min` +
# `pw_max`) so an over-powered car can't walk them either. A rally may layer a
# secondary theme on top of its p/w band (e.g. RWD Masters also wants `drive_mode`
# RWD). `difficulty` is a HIDDEN tier (never shown to the player) that drives the
# reward tier (clamped by progress) and sort order — the p/w gate is the visible
# requirement. `events` is exactly 3 EventDefs (the showdown's are longer). Exactly
# one entry has `showdown = true` and stays open-class so the immortal starter can
# always finish the game.
const RALLIES: Array[Dictionary] = [
	{
		"id": "shakedown", "name": "Shakedown", "difficulty": 1, "showdown": false,
		"map_pos": Vector2(0.18, 0.72),  # normalised pin position on the world map (hq.gd)
		"restriction": {"pw_max": 0.20},  # gated below: a low p/w ceiling — the starter's home
		"events": [
			{"seed": 1001, "turn_count": 10, "forestiness": 0.7, "surface_mix": 0.0, "straightness": 0.85},
			{"seed": 1002, "turn_count": 12, "forestiness": 0.4, "surface_mix": 0.0, "straightness": 0.8},
			{"seed": 1003, "turn_count": 11, "forestiness": 0.85, "surface_mix": 0.3, "straightness": 0.8},
		],
	},
	{
		"id": "coastal_sprint", "name": "Coastal Sprint", "difficulty": 2, "showdown": false,
		"map_pos": Vector2(0.34, 0.5),
		"restriction": {"pw_max": 0.25},  # gated below: a slightly higher p/w ceiling
		"events": [
			{"seed": 2001, "turn_count": 14, "forestiness": 0.3, "surface_mix": 1.0, "straightness": 0.55},
			{"seed": 2002, "turn_count": 13, "forestiness": 0.6, "surface_mix": 0.7, "straightness": 0.5},
			{"seed": 2003, "turn_count": 15, "forestiness": 0.45, "surface_mix": 1.0, "straightness": 0.55},
		],
	},
	{
		"id": "rwd_masters", "name": "RWD Masters", "difficulty": 2, "showdown": false,
		"map_pos": Vector2(0.52, 0.64),
		# p/w band (primary gate) + an RWD theme: a mid-power rear-driven field.
		"restriction": {"drive_mode": CarLibrary.RWD, "pw_min": 0.22, "pw_max": 0.30},
		"events": [
			{"seed": 3001, "turn_count": 13, "forestiness": 0.5, "surface_mix": 0.5, "straightness": 0.5},
			{"seed": 3002, "turn_count": 14, "forestiness": 0.8, "surface_mix": 1.0, "straightness": 0.45},
			{"seed": 3003, "turn_count": 13, "forestiness": 0.35, "surface_mix": 0.0, "straightness": 0.5},
		],
	},
	{
		"id": "rising_sun", "name": "Rising Sun Rally", "difficulty": 3, "showdown": false,
		"map_pos": Vector2(0.82, 0.34),
		# JP-only AND a mid-upper p/w band — both must hold (is_eligible ANDs all fields).
		"restriction": {"country": "JP", "pw_min": 0.23, "pw_max": 0.32},
		"events": [
			{"seed": 4001, "turn_count": 16, "forestiness": 0.6, "surface_mix": 0.6, "straightness": 0.25},
			{"seed": 4002, "turn_count": 15, "forestiness": 0.4, "surface_mix": 0.0, "straightness": 0.2},
			{"seed": 4003, "turn_count": 17, "forestiness": 0.75, "surface_mix": 1.0, "straightness": 0.25},
		],
	},
	{
		"id": "grand_tour", "name": "Grand Tour", "difficulty": 3, "showdown": false,
		"map_pos": Vector2(0.66, 0.28),
		"restriction": {"pw_min": 0.28, "pw_max": 0.40},  # the top non-showdown p/w band
		"events": [
			{"seed": 5001, "turn_count": 18, "forestiness": 0.55, "surface_mix": 1.0, "straightness": 0.15},
			{"seed": 5002, "turn_count": 17, "forestiness": 0.3, "surface_mix": 0.4, "straightness": 0.15},
			{"seed": 5003, "turn_count": 19, "forestiness": 0.7, "surface_mix": 0.0, "straightness": 0.1},
		],
	},
	{
		"id": "the_showdown", "name": "The Showdown", "difficulty": 4, "showdown": true,
		"map_pos": Vector2(0.5, 0.12),
		"restriction": {},  # open so the immortal starter can always finish the game
		"events": [
			{"seed": 9001, "turn_count": 22, "forestiness": 0.8, "surface_mix": 0.5},
			{"seed": 9002, "turn_count": 24, "forestiness": 0.5, "surface_mix": 0.8},
			{"seed": 9003, "turn_count": 22, "forestiness": 0.65, "surface_mix": 0.3},
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


# How forested this event is, in [0, 1]: the fraction of the area covered by trees.
# Trees only spawn where a 300 m-wavelength noise field exceeds (1 - forestiness), so
# higher = denser forest, 0 = bare, 1 = trees everywhere (the default for an event that
# omits it). Bushes ignore this. See TreeScatter / features/trees.md.
static func event_forestiness(event: Dictionary) -> float:
	return clampf(float(event.get("forestiness", 1.0)), 0.0, 1.0)


# Fraction of this event's track surfaced as tarmac, in [0, 1] (the rest gravel).
# The track switches surface exactly once along its length (TrackSurface); 0 = all
# gravel, 1 = all tarmac. The default (0) keeps an event that omits it all gravel.
static func event_tarmac_fraction(event: Dictionary) -> float:
	return clampf(float(event.get("surface_mix", 0.0)), 0.0, 1.0)


# Bias toward straighter (easier) turns when generating this event's track, in
# [0, 1]: 0 = no bias (corners chosen freely), 1 = strongly favour gentle corners
# and long straights. Earlier, lower-tier events run higher so their stages are
# gentler; the default (0) leaves generation unbiased. Fed to TrackGenerator.generate
# (it changes the track SHAPE, so the same value is used when deriving target times).
static func event_straightness(event: Dictionary) -> float:
	return clampf(float(event.get("straightness", 0.0)), 0.0, 1.0)


# --- Eligibility -------------------------------------------------------------

# Whether `car_meta` (a CarLibrary entry dict, resolved by the owned car's stable
# model_id — never array index) satisfies a rally's restriction. Open-class
# (empty restriction) always matches. For an OWNED car, callers pass the car's
# effective stats (UpgradeLibrary.effective_meta) so an installed engine kit or
# weight reduction can qualify / disqualify it via the pw_min / pw_max band; the
# raw CARS entry is only the right input for an unmodified roster car (rivals).
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


# The eligible car with the highest power-to-weight for a rally. Falls back to the
# best car in the whole roster when `rally` is empty (legacy/test callers).
static func _best_eligible_car(rally: Dictionary) -> Dictionary:
	var pool: Array = _eligible_cars(rally) if not rally.is_empty() else CarLibrary.CARS
	var best: Dictionary = {}
	var best_pw := -1.0
	for car in pool:
		var pw := CarLibrary.power_to_weight(car)
		if pw > best_pw:
			best_pw = pw
			best = car
	return best


# --- In-stage turn splits (for the live "vs P1" pace popup) ------------------

# Per-turn cumulative split table off a SPECIFIC car's optimum velocity profile —
# used by the run scene's "vs P1" pace popup (so the popup tracks P1's real car).
# For each placed piece returns the arc length at the END of that turn and the
# cumulative time (ms) to there, read off LapTimeModel.optimum_profile(car). The
# final entry's cum_ms equals optimum_ms(track, car, event). An event's
# target_ms_override rescales the cumulative times to land on it, preserving the
# per-turn profile (the popup only uses fractions, so the rescale cancels there).
# Returns Array of { "end_offset_m": float, "cum_ms": int }; empty if no pieces.
static func derive_turn_splits(track_result: Dictionary, car_meta: Dictionary, event: Dictionary = {}) -> Array:
	var centerline := track_result.get("centerline") as Curve2D
	var pieces: Array = track_result.get("pieces", [])
	if centerline == null or pieces.is_empty():
		return []
	var prof := LapTimeModel.optimum_profile(track_result, car_meta, event)
	var s: PackedFloat32Array = prof["s"]
	var t: PackedFloat32Array = prof["t"]
	if s.size() < 2:
		return []
	var baked := centerline.get_baked_length()
	var splits: Array = []
	for i in pieces.size():
		var end_off := baked
		if i + 1 < pieces.size():
			var next_entry: Vector2 = pieces[i + 1].get("entry_pos", Vector2.ZERO)
			end_off = centerline.get_closest_offset(next_entry)
		var secs := _time_at_offset(s, t, end_off)
		splits.append({"end_offset_m": end_off, "cum_ms": int(round(secs * 1000.0))})
	if event.has("target_ms_override"):
		var natural_total := float(splits[splits.size() - 1]["cum_ms"])
		if natural_total > 0.0:
			var override_total := float(int(event["target_ms_override"]))
			for sp in splits:
				sp["cum_ms"] = int(round(float(sp["cum_ms"]) / natural_total * override_total))
	return splits


# Linear-interpolate the cumulative time (s) at an arc offset within the profile's
# monotonic s[] / t[] arrays.
static func _time_at_offset(s: PackedFloat32Array, t: PackedFloat32Array, off: float) -> float:
	var n := s.size()
	if off <= s[0]:
		return t[0]
	if off >= s[n - 1]:
		return t[n - 1]
	for i in range(1, n):
		if s[i] >= off:
			var span := s[i] - s[i - 1]
			var f := (off - s[i - 1]) / span if span > 0.0 else 0.0
			return lerpf(t[i - 1], t[i], f)
	return t[n - 1]


# --- Opponent field (recomputed from the rally seed, never saved) ------------

# The fixed opponent field for a rally, given each event's track result and event
# dict. Reseeded from the rally id so the leaderboard is identical across re-attempts.
# Returns an Array of opponents:
#   { name: String, car_id: String, car_name: String,
#     event_times_ms: Array[int], dnf: bool, combined_ms: int }
# Each rival is assigned a car from the rally's eligible roster (so e.g. an
# RWD-only rally fields RWD rivals), drawn from the same seeded RNG so the line-up
# is stable across re-attempts. Each rival's event time is derived from their OWN
# car's physics floor (optimum_ms) scaled by a per-rival factor in the pace band,
# so a faster car fields a faster time. A DNF in any event disqualifies the opponent
# (combined_ms = -1, doesn't rank).
static func generate_opponent_field(rally: Dictionary, event_results: Array, events: Array) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = _rally_seed(rally)
	var car_pool := _eligible_cars(rally)
	var count := rng.randi_range(FIELD_MIN, FIELD_MAX)
	var field: Array = []
	for i in count:
		var car: Dictionary = car_pool[rng.randi_range(0, car_pool.size() - 1)]
		var times: Array = []
		var dnf := false
		for k in event_results.size():
			if rng.randf() < DNF_CHANCE:
				dnf = true
				times.append(-1)
			else:
				var ev: Dictionary = events[k] if k < events.size() else {}
				var floor_ms := LapTimeModel.optimum_ms(event_results[k], car, ev)
				var factor := RIVAL_PACE_MIN + rng.randf() * RIVAL_PACE_SPREAD
				times.append(int(round(floor_ms * factor)))
		var combined := -1
		if not dnf:
			combined = 0
			for tm in times:
				combined += int(tm)
		field.append({
			"name": "Rival %d" % (i + 1),
			"car_id": String(car.get("id", "")),
			"car_name": String(car.get("name", "")),
			"event_times_ms": times,
			"dnf": dnf,
			"combined_ms": combined,
		})
	return field


# The CarLibrary entries a rally's restriction admits — the pool its rivals are
# drawn from. Falls back to the whole roster if a restriction somehow admits no
# car (it never should; open-class admits everything).
static func _eligible_cars(rally: Dictionary) -> Array:
	var pool: Array = []
	for entry in CarLibrary.CARS:
		if is_eligible(rally, entry):
			pool.append(entry)
	return pool if not pool.is_empty() else CarLibrary.CARS


# CarLibrary.CARS indices a rally's restriction admits — the pool an index-based
# spawner (the start-line queue props, start_line.gd) draws its cars from, so the
# cars bookending the player are always eligible for the rally. Falls back to every
# index if a restriction somehow admits none (it never should; open-class admits all).
static func eligible_car_indices(rally: Dictionary) -> Array:
	var pool: Array = []
	for i in CarLibrary.CARS.size():
		if is_eligible(rally, CarLibrary.CARS[i]):
			pool.append(i)
	if pool.is_empty():
		for i in CarLibrary.CARS.size():
			pool.append(i)
	return pool


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
#   { name:String, car_name:String, car_id:String, combined_ms:int, dnf:bool, is_player:bool, placed:int }
# `car_name` is the car that entrant drove (the leaderboard shows it); empty when
# unknown. `car_id` is that car's stable CarLibrary id (so the podium can spawn the
# top-3 cars' 3D models); empty when unknown. `placed` is the 1-based finishing position among the classified
# (non-DNF) entries; DNF entries get placed = -1. Consistent with placement() — a
# non-DNF player's `placed` equals placement(field, player_combined_ms).
static func build_standings(field: Array, player_combined_ms: int, player_dnf: bool, player_name := "You", player_car_name := "", player_car_id := "") -> Array:
	var entries: Array = []
	for opp in field:
		entries.append({
			"name": String(opp.get("name", "Rival")),
			"car_name": String(opp.get("car_name", "")),
			"car_id": String(opp.get("car_id", "")),
			"combined_ms": int(opp.get("combined_ms", -1)),
			"dnf": bool(opp.get("dnf", false)),
			"is_player": false,
		})
	entries.append({
		"name": player_name,
		"car_name": player_car_name,
		"car_id": player_car_id,
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
