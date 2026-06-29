extends GutTest
# The rally roster (RallyLibrary): the authored rally list and the pure
# functions over it — eligibility, target times, the deterministic opponent
# field, progress/showdown gating, and the anti-soft-lock query. Mirrors
# test_car_library.gd. See todo/rally-roster.md.


# --- Roster validity (anti-soft-lock) ---------------------------------------

func test_roster_is_well_formed() -> void:
	var ids := {}
	var showdowns := 0
	for rally in RallyLibrary.RALLIES:
		assert_false(ids.has(rally["id"]), "rally id '%s' is unique" % rally["id"])
		ids[rally["id"]] = true
		assert_eq(rally["events"].size(), 3, "%s has exactly 3 events" % rally["id"])
		assert_gt(rally["difficulty"], 0, "%s has a positive difficulty tier" % rally["id"])
		for ev in rally["events"]:
			assert_gt(int(ev["turn_count"]), 0, "%s event has a positive turn_count" % rally["id"])
			var f := RallyLibrary.event_forestiness(ev)
			assert_between(f, 0.0, 1.0, "%s event forestiness is in [0, 1]" % rally["id"])
			var t := RallyLibrary.event_tarmac_fraction(ev)
			assert_between(t, 0.0, 1.0, "%s event tarmac fraction is in [0, 1]" % rally["id"])
			var s := RallyLibrary.event_straightness(ev)
			assert_between(s, 0.0, 1.0, "%s event straightness is in [0, 1]" % rally["id"])
		if rally["showdown"]:
			showdowns += 1
	assert_eq(showdowns, 1, "exactly one showdown rally")


func test_event_forestiness_defaults_to_fully_wooded() -> void:
	# An event that omits forestiness defaults to 1.0 (trees everywhere); authored
	# values pass through clamped to [0, 1].
	assert_eq(RallyLibrary.event_forestiness({}), 1.0, "missing forestiness -> 1.0")
	assert_almost_eq(RallyLibrary.event_forestiness({"forestiness": 0.3}), 0.3, 0.0001, "authored value passes through")
	assert_eq(RallyLibrary.event_forestiness({"forestiness": 2.0}), 1.0, "clamps above 1")
	assert_eq(RallyLibrary.event_forestiness({"forestiness": -1.0}), 0.0, "clamps below 0")


func test_event_tarmac_fraction_defaults_to_all_gravel() -> void:
	# An event that omits surface_mix is all gravel (0.0); authored values pass
	# through clamped to [0, 1].
	assert_eq(RallyLibrary.event_tarmac_fraction({}), 0.0, "missing surface_mix -> 0.0 (all gravel)")
	assert_almost_eq(RallyLibrary.event_tarmac_fraction({"surface_mix": 0.7}), 0.7, 0.0001, "authored value passes through")
	assert_eq(RallyLibrary.event_tarmac_fraction({"surface_mix": 2.0}), 1.0, "clamps above 1")
	assert_eq(RallyLibrary.event_tarmac_fraction({"surface_mix": -1.0}), 0.0, "clamps below 0")


func test_event_straightness_defaults_to_unbiased() -> void:
	# An event that omits straightness defaults to 0.0 (no bias); authored values
	# pass through clamped to [0, 1].
	assert_eq(RallyLibrary.event_straightness({}), 0.0, "missing straightness -> 0.0 (unbiased)")
	assert_almost_eq(RallyLibrary.event_straightness({"straightness": 0.6}), 0.6, 0.0001, "authored value passes through")
	assert_eq(RallyLibrary.event_straightness({"straightness": 2.0}), 1.0, "clamps above 1")
	assert_eq(RallyLibrary.event_straightness({"straightness": -1.0}), 0.0, "clamps below 0")


func test_earlier_events_favour_straighter_turns() -> void:
	# The earlier (lower-tier, non-showdown) part of the game generates easier, less
	# twisty tracks: the average event straightness must fall as difficulty rises.
	var sum_by_tier := {}
	var n_by_tier := {}
	for rally in RallyLibrary.RALLIES:
		if rally["showdown"]:
			continue
		var tier: int = rally["difficulty"]
		for ev in rally["events"]:
			sum_by_tier[tier] = sum_by_tier.get(tier, 0.0) + RallyLibrary.event_straightness(ev)
			n_by_tier[tier] = n_by_tier.get(tier, 0) + 1
	var tiers := sum_by_tier.keys()
	tiers.sort()
	var prev_avg := 2.0  # above any possible average so tier 1 always passes
	for tier in tiers:
		var avg: float = sum_by_tier[tier] / float(n_by_tier[tier])
		assert_lt(avg, prev_avg, "tier %d is not straighter (easier) than the tier below it" % tier)
		prev_avg = avg
	# The very first tier is meaningfully biased toward straight (an easy intro).
	assert_gt(sum_by_tier[1] / float(n_by_tier[1]), 0.5, "tier 1 events strongly favour straight turns")


func test_roster_has_full_one_surface_events() -> void:
	# "A fair few" events should be fully one surface (0% or 100% tarmac) so the
	# roster isn't all mixed stages.
	var full := 0
	for rally in RallyLibrary.RALLIES:
		for ev in rally["events"]:
			var t := RallyLibrary.event_tarmac_fraction(ev)
			if t <= 0.0 or t >= 1.0:
				full += 1
	assert_gt(full, 5, "several events are fully one surface (all gravel or all tarmac)")


func test_open_class_floor_at_each_reachable_tier() -> void:
	# Every difficulty tier reachable by the (immortal) starter — i.e. every tier
	# with a non-showdown rally — must offer at least one open-class rally.
	var tiers_seen := {}
	var open_at_tier := {}
	for rally in RallyLibrary.RALLIES:
		if rally["showdown"]:
			continue
		var t: int = rally["difficulty"]
		tiers_seen[t] = true
		if rally["restriction"].is_empty():
			open_at_tier[t] = true
	for t in tiers_seen:
		assert_true(open_at_tier.has(t), "tier %d has an open-class rally" % t)


# --- Eligibility -------------------------------------------------------------

func test_open_class_matches_every_car() -> void:
	var shakedown := RallyLibrary.by_id("shakedown")
	for spec in CarLibrary.CARS:
		assert_true(RallyLibrary.is_eligible(shakedown, spec),
			"open-class accepts %s" % spec["name"])


func test_drive_mode_restriction_filters() -> void:
	var rwd_rally := RallyLibrary.by_id("rwd_masters")
	# The MX-5 is RWD (eligible); the RS3 is AWD (not).
	assert_true(RallyLibrary.is_eligible(rwd_rally, CarLibrary.by_id("mx5")), "RWD MX-5 eligible")
	assert_false(RallyLibrary.is_eligible(rwd_rally, CarLibrary.by_id("rs3")), "AWD RS3 excluded")


func test_country_restriction_filters() -> void:
	var jp_rally := RallyLibrary.by_id("rising_sun")
	assert_true(RallyLibrary.is_eligible(jp_rally, CarLibrary.by_id("mx5")), "JP MX-5 eligible")
	assert_false(RallyLibrary.is_eligible(jp_rally, CarLibrary.by_id("mustang")), "US Mustang excluded")


# --- Determinism -------------------------------------------------------------

func test_track_generation_is_deterministic() -> void:
	var ev: Dictionary = RallyLibrary.by_id("coastal_sprint")["events"][0]
	var a := TrackGenerator.generate(Vector2.ZERO, Vector2(0, 1), int(ev["seed"]),
		int(ev["turn_count"]), RallyLibrary.event_width(ev), 8.0)
	var b := TrackGenerator.generate(Vector2.ZERO, Vector2(0, 1), int(ev["seed"]),
		int(ev["turn_count"]), RallyLibrary.event_width(ev), 8.0)
	assert_almost_eq((a["centerline"] as Curve2D).get_baked_length(),
		(b["centerline"] as Curve2D).get_baked_length(), 0.001, "same seed -> same track length")
	assert_eq(a["pieces"].size(), b["pieces"].size(), "same seed -> same piece count")


func test_target_time_is_positive_and_seed_stable() -> void:
	var ev: Dictionary = RallyLibrary.by_id("coastal_sprint")["events"][0]
	var track := TrackGenerator.generate(Vector2.ZERO, Vector2(0, 1), int(ev["seed"]),
		int(ev["turn_count"]), RallyLibrary.event_width(ev), 8.0)
	var t1 := RallyLibrary.derive_target_ms(track, ev)
	assert_gt(t1, 0, "derived target time is positive")
	# Override wins when present.
	assert_eq(RallyLibrary.derive_target_ms(track, {"target_ms_override": 42000}), 42000,
		"target_ms_override is honoured")


# --- Opponent field ----------------------------------------------------------

func test_opponent_field_shape_and_bounds() -> void:
	var rally := RallyLibrary.by_id("coastal_sprint")
	var targets := [60000, 60000, 60000]
	var field := RallyLibrary.generate_opponent_field(rally, targets)
	assert_between(field.size(), RallyLibrary.FIELD_MIN, RallyLibrary.FIELD_MAX,
		"field has 10-15 opponents")
	for opp in field:
		if opp["dnf"]:
			assert_eq(int(opp["combined_ms"]), -1, "a DNF opponent does not rank")
		else:
			var sum := 0
			for i in targets.size():
				var t: int = opp["event_times_ms"][i]
				var lo := int(floor(targets[i] * RallyLibrary.RIVAL_PACE_MIN))
				var hi := int(ceil(targets[i] * (RallyLibrary.RIVAL_PACE_MIN + RallyLibrary.RIVAL_PACE_SPREAD)))
				assert_between(t, lo, hi, "event time within the rival pace band (slower than target)")
				sum += t
			assert_eq(int(opp["combined_ms"]), sum, "combined time is the sum of event times")


func test_opponent_field_is_deterministic() -> void:
	var rally := RallyLibrary.by_id("rwd_masters")
	var targets := [50000, 55000, 52000]
	var a := RallyLibrary.generate_opponent_field(rally, targets)
	var b := RallyLibrary.generate_opponent_field(rally, targets)
	assert_eq(a, b, "same rally seed -> identical opponent field")


func test_opponents_drive_eligible_cars() -> void:
	# Every rival is assigned an identified car; in a restricted rally the car must
	# satisfy the restriction (RWD Masters fields only RWD rivals).
	var rally := RallyLibrary.by_id("rwd_masters")
	var field := RallyLibrary.generate_opponent_field(rally, [60000, 60000, 60000])
	for opp in field:
		var car_id := String(opp.get("car_id", ""))
		assert_ne(car_id, "", "%s drives an identified car" % opp["name"])
		var meta := CarLibrary.by_id(car_id)
		assert_false(meta.is_empty(), "the rival car id resolves to a CarLibrary entry")
		assert_eq(int(meta.get("drive_mode", -1)), CarLibrary.RWD, "RWD-only rally fields only RWD rivals")
		assert_eq(String(opp.get("car_name", "")), String(meta.get("name", "")), "car name matches the id")


func test_dnfs_occur_somewhere_in_the_roster() -> void:
	var any_dnf := false
	for rally in RallyLibrary.RALLIES:
		for opp in RallyLibrary.generate_opponent_field(rally, [60000, 60000, 60000]):
			if opp["dnf"]:
				any_dnf = true
	assert_true(any_dnf, "some opponents DNF across the roster")


func test_placement_and_top3() -> void:
	var field := [
		{"dnf": false, "combined_ms": 100},
		{"dnf": false, "combined_ms": 200},
		{"dnf": true, "combined_ms": -1},  # disqualified, must not count
		{"dnf": false, "combined_ms": 300},
	]
	assert_eq(RallyLibrary.placement(field, 150), 2, "beats one, behind one -> P2")
	assert_true(RallyLibrary.is_top3(field, 150), "P2 is top-3")
	assert_eq(RallyLibrary.placement(field, 999), 4, "slower than all 3 non-DNF -> P4")
	assert_false(RallyLibrary.is_top3(field, 999), "P4 is not top-3")


func test_build_standings_ranks_field_and_sinks_dnfs() -> void:
	var field := [
		{"name": "A", "dnf": false, "combined_ms": 100},
		{"name": "B", "dnf": true, "combined_ms": -1},
		{"name": "C", "dnf": false, "combined_ms": 300},
	]
	# Player runs 200ms clean: ranks 2nd (behind A, ahead of C); B (DNF) trails all.
	var standings := RallyLibrary.build_standings(field, 200, false)
	assert_eq(standings.size(), 4, "field + player")
	assert_eq(String(standings[0]["name"]), "A", "fastest classified is first")
	assert_eq(standings[0]["placed"], 1, "first place is P1")
	assert_true(standings[1]["is_player"], "the player slots into 2nd on time")
	assert_eq(standings[1]["placed"], 2, "player placed equals placement()")
	assert_eq(standings[2]["placed"], 3, "the slower opponent is P3")
	assert_eq(standings[3]["placed"], -1, "the DNF trails the field and does not place")
	assert_eq(RallyLibrary.placement(field, 200), standings[1]["placed"],
		"build_standings agrees with placement() for the player")


func test_build_standings_carries_the_car_each_entrant_drove() -> void:
	var field := [{"name": "A", "car_name": "Porsche 911", "dnf": false, "combined_ms": 100}]
	# Player runs 200ms (behind A), driving the MX-5.
	var standings := RallyLibrary.build_standings(field, 200, false, "You", "Mazda MX-5")
	assert_eq(String(standings[0]["car_name"]), "Porsche 911", "the opponent's car is carried into the standings")
	assert_true(standings[1]["is_player"], "the player ranks 2nd")
	assert_eq(String(standings[1]["car_name"]), "Mazda MX-5", "the player's car is carried into the standings")


func test_build_standings_handles_a_wrecked_player() -> void:
	var field := [{"name": "A", "dnf": false, "combined_ms": 100}]
	var standings := RallyLibrary.build_standings(field, -1, true)
	assert_true(standings[0]["is_player"] == false, "the classified opponent ranks above a wrecked player")
	assert_true(standings[1]["is_player"], "the wrecked player sinks to the bottom")
	assert_eq(standings[1]["placed"], -1, "a wrecked player does not place")


# --- Progress / showdown -----------------------------------------------------

func test_completed_count_tracks_profile() -> void:
	var profile := {"rallies": {
		"shakedown": {"completed": true},
		"coastal_sprint": {"completed": false},
	}}
	assert_eq(RallyLibrary.completed_count(profile), 1, "only completed rallies count")


func test_showdown_unlocks_only_when_all_others_complete() -> void:
	var profile := {"rallies": {}}
	assert_false(RallyLibrary.showdown_unlocked(profile), "locked with nothing completed")
	# Complete every non-showdown rally.
	for rally in RallyLibrary.RALLIES:
		if not rally["showdown"]:
			profile["rallies"][rally["id"]] = {"completed": true}
	assert_true(RallyLibrary.showdown_unlocked(profile), "unlocks once all non-showdown rallies done")


func test_incomplete_enterable_query_respects_eligibility_and_lock() -> void:
	var profile := {"rallies": {}}
	# An AWD car (RS3) can't enter rwd_masters, and the showdown is locked.
	var rs3 := CarLibrary.by_id("rs3")
	var enterable := RallyLibrary.incomplete_rallies_enterable_by(rs3, profile)
	var ids := {}
	for r in enterable:
		ids[r["id"]] = true
	assert_false(ids.has("rwd_masters"), "AWD car excluded from RWD-only rally")
	assert_false(ids.has("the_showdown"), "showdown excluded while locked")
	assert_true(ids.has("shakedown"), "open-class rally is enterable")
