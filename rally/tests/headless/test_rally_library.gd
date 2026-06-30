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


func test_starter_always_has_an_enterable_rally() -> void:
	# Anti-soft-lock floor: now that progression is gated on power-to-weight (not an
	# open-class pool at every tier), the guarantee is that the immortal starter —
	# the lowest-power car, mx5 — can always enter at least one NON-showdown rally,
	# and the showdown stays open-class so it can finish the game even if it never
	# earns another car.
	var starter := CarLibrary.by_id("mx5")
	var enterable_non_showdown := 0
	var showdown_seen := false
	for rally in RallyLibrary.RALLIES:
		if rally["showdown"]:
			showdown_seen = true
			assert_true(rally["restriction"].is_empty(), "the showdown is open-class")
			assert_true(RallyLibrary.is_eligible(rally, starter), "the starter can enter the showdown")
			continue
		if RallyLibrary.is_eligible(rally, starter):
			enterable_non_showdown += 1
	assert_gt(enterable_non_showdown, 0, "the starter has at least one non-showdown rally to race")
	assert_true(showdown_seen, "there is a showdown rally")


func test_rallies_are_gated_by_power_to_weight() -> void:
	# Progression is PRIMARILY gated on power-to-weight: every non-showdown rally
	# carries a p/w cap, the easiest rallies are gated only from above (a ceiling, no
	# floor), and the harder rallies tighten to a band that also sets a floor.
	var cap_only := 0  # gated below only (pw_max, no pw_min)
	var banded := 0    # a range (both pw_min and pw_max)
	for rally in RallyLibrary.RALLIES:
		if rally["showdown"]:
			continue
		var r: Dictionary = rally["restriction"]
		assert_true(r.has("pw_max"), "%s caps power-to-weight from above" % rally["id"])
		if int(rally["difficulty"]) <= 1:
			assert_false(r.has("pw_min"), "tier-1 %s is gated below only (no p/w floor)" % rally["id"])
		if int(rally["difficulty"]) >= 3:
			assert_true(r.has("pw_min"), "tier-3+ %s gates on a band (has a p/w floor)" % rally["id"])
		if r.has("pw_min"):
			banded += 1
		else:
			cap_only += 1
	assert_gt(cap_only, 0, "some early rallies are gated below (a p/w ceiling only)")
	assert_gt(banded, 0, "some later rallies gate on a p/w range")


# --- Eligibility -------------------------------------------------------------

func test_open_class_matches_every_car() -> void:
	# The showdown is the open-class rally (empty restriction) — it accepts every car.
	var showdown := RallyLibrary.by_id("the_showdown")
	for spec in CarLibrary.CARS:
		assert_true(RallyLibrary.is_eligible(showdown, spec),
			"open-class accepts %s" % spec["name"])


func test_drive_mode_restriction_filters() -> void:
	# is_eligible honours a drive_mode restriction regardless of the roster: the MX-5
	# is RWD (eligible); the RS3 is AWD (not).
	var rwd_only := {"restriction": {"drive_mode": CarLibrary.RWD}}
	assert_true(RallyLibrary.is_eligible(rwd_only, CarLibrary.by_id("mx5")), "RWD MX-5 eligible")
	assert_false(RallyLibrary.is_eligible(rwd_only, CarLibrary.by_id("rs3")), "AWD RS3 excluded")


func test_country_restriction_filters() -> void:
	var jp_only := {"restriction": {"country": "JP"}}
	assert_true(RallyLibrary.is_eligible(jp_only, CarLibrary.by_id("mx5")), "JP MX-5 eligible")
	assert_false(RallyLibrary.is_eligible(jp_only, CarLibrary.by_id("mustang")), "US Mustang excluded")


func test_power_to_weight_restriction_filters() -> void:
	# A p/w band admits only cars whose power-to-weight sits inside [pw_min, pw_max].
	var band := {"restriction": {"pw_min": 0.22, "pw_max": 0.30}}
	assert_false(RallyLibrary.is_eligible(band, CarLibrary.by_id("mx5")), "low-p/w MX-5 below the floor")
	assert_true(RallyLibrary.is_eligible(band, CarLibrary.by_id("porsche911")), "mid-p/w 911 inside the band")
	assert_false(RallyLibrary.is_eligible(band, CarLibrary.by_id("aventador")), "high-p/w Aventador above the cap")
	# A ceiling-only gate (pw_max, no floor) lets the weakest car in but caps the strong.
	var cap := {"restriction": {"pw_max": 0.20}}
	assert_true(RallyLibrary.is_eligible(cap, CarLibrary.by_id("mx5")), "the low-power starter clears a ceiling gate")
	assert_false(RallyLibrary.is_eligible(cap, CarLibrary.by_id("porsche911")), "a stronger car is capped out")


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


func test_tarmac_fraction_tightens_target_time() -> void:
	# Same track, varying only the tarmac fraction: more tarmac = quicker target,
	# because tarmac is priced at the faster TARMAC_SPEED_MPS / corner penalty.
	var ev: Dictionary = RallyLibrary.by_id("coastal_sprint")["events"][0]
	var track := TrackGenerator.generate(Vector2.ZERO, Vector2(0, 1), int(ev["seed"]),
		int(ev["turn_count"]), RallyLibrary.event_width(ev), 8.0)
	var all_gravel := RallyLibrary.derive_target_ms(track, {"surface_mix": 0.0})
	var half := RallyLibrary.derive_target_ms(track, {"surface_mix": 0.5})
	var all_tarmac := RallyLibrary.derive_target_ms(track, {"surface_mix": 1.0})
	assert_lt(all_tarmac, all_gravel, "all-tarmac target is quicker than all-gravel")
	assert_between(half, all_tarmac, all_gravel, "half-tarmac target sits between the two")
	# Tarmac should be a lot quicker, not a rounding-error nudge.
	assert_lt(all_tarmac, int(all_gravel * 0.9), "all-tarmac is at least 10% quicker")


# --- Turn splits (the in-stage "vs P1" pace popup) ---------------------------

func test_turn_splits_are_monotonic_and_total_matches_target() -> void:
	var ev: Dictionary = RallyLibrary.by_id("coastal_sprint")["events"][0]
	var track := TrackGenerator.generate(Vector2.ZERO, Vector2(0, 1), int(ev["seed"]),
		int(ev["turn_count"]), RallyLibrary.event_width(ev), 8.0)
	var splits := RallyLibrary.derive_turn_splits(track, ev)
	assert_eq(splits.size(), track["pieces"].size(), "one split per placed turn")
	var prev_off := -1.0
	var prev_ms := -1
	for s in splits:
		assert_gt(float(s["end_offset_m"]), prev_off, "arc offset rises each turn")
		assert_gt(int(s["cum_ms"]), prev_ms, "cumulative time rises each turn")
		prev_off = float(s["end_offset_m"])
		prev_ms = int(s["cum_ms"])
	# The final turn's cumulative time is the whole-track target (same pricing).
	var last_ms := int(splits[splits.size() - 1]["cum_ms"])
	assert_almost_eq(float(last_ms), float(RallyLibrary.derive_target_ms(track, ev)), 2.0,
		"last split equals the derived target time")


func test_turn_splits_empty_without_pieces() -> void:
	assert_eq(RallyLibrary.derive_turn_splits({}), [], "no track -> no splits")
	assert_eq(RallyLibrary.derive_turn_splits({"pieces": []}), [], "no pieces -> no splits")


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
	# An AWD car (RS3) can't enter rwd_masters (RWD-only), and the showdown is locked,
	# but it does qualify for a rally inside its power band (coastal_sprint).
	var rs3 := CarLibrary.by_id("rs3")
	var enterable := RallyLibrary.incomplete_rallies_enterable_by(rs3, profile)
	var ids := {}
	for r in enterable:
		ids[r["id"]] = true
	assert_false(ids.has("rwd_masters"), "AWD car excluded from RWD-only rally")
	assert_false(ids.has("the_showdown"), "showdown excluded while locked")
	assert_true(ids.has("coastal_sprint"), "a rally inside the car's power band is enterable")
