extends GutTest
# The rally roster (RallyLibrary): the authored rally list and the pure
# functions over it — eligibility, target times, the deterministic opponent
# field, progress/showdown gating, and the anti-soft-lock query. Mirrors
# test_car_library.gd. See todo/rally-roster.md.

const RallyLibrary = preload("res://scripts/rally_library.gd")
const CarLibrary = preload("res://scripts/car_library.gd")
const TrackGenerator = preload("res://scripts/track_generator.gd")


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
		if rally["showdown"]:
			showdowns += 1
	assert_eq(showdowns, 1, "exactly one showdown rally")


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
				assert_between(t, targets[i], targets[i] * 2, "event time in [target, 2x target]")
				sum += t
			assert_eq(int(opp["combined_ms"]), sum, "combined time is the sum of event times")


func test_opponent_field_is_deterministic() -> void:
	var rally := RallyLibrary.by_id("rwd_masters")
	var targets := [50000, 55000, 52000]
	var a := RallyLibrary.generate_opponent_field(rally, targets)
	var b := RallyLibrary.generate_opponent_field(rally, targets)
	assert_eq(a, b, "same rally seed -> identical opponent field")


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
