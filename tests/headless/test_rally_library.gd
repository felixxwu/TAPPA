extends GutTest
# The rally roster (RallyLibrary): the authored rally list and the pure
# functions over it — eligibility, target times, the deterministic opponent
# field, progress/showdown gating, and the anti-soft-lock query. Mirrors
# test_car_library.gd. See todo/rally-roster.md.


const _TGP = preload("res://scripts/track_gen_params.gd")


func _params(start_pos: Vector2, start_heading: Vector2, seed_value: int, turn_count: int, width: float, clearance := 0.0, reserve := 0.0, straightness := 0.0, runoff := 0.0) -> _TGP:
	return _TGP.of(start_pos, start_heading, seed_value, turn_count, width, clearance, reserve, straightness, runoff)


func before_each() -> void:
	CarFixtures.install()


func after_each() -> void:
	CarFixtures.restore()


# --- Roster validity (anti-soft-lock) ---------------------------------------

func test_roster_is_well_formed() -> void:
	var ids := {}
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


func test_every_rally_has_a_known_region() -> void:
	for rally in RallyLibrary.all():
		var region_id := String(rally.get("region", ""))
		assert_ne(region_id, "", "rally %s has no region" % rally.get("id", "?"))
		assert_ne(RegionLibrary.index_of(region_id), -1,
			"rally %s region %s is not in RegionLibrary" % [rally.get("id", "?"), region_id])


func test_exactly_one_showdown_per_region() -> void:
	for region in RegionLibrary.all():
		var region_id := String(region["id"])
		var showdowns := 0
		for rally in RallyLibrary.all():
			if String(rally.get("region", "")) == region_id and bool(rally.get("showdown", false)):
				showdowns += 1
		assert_eq(showdowns, 1, "region %s must have exactly one showdown" % region_id)


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


func test_event_cliffiness_defaults_to_flat() -> void:
	# An event that omits cliffiness defaults to 0.0 (flat, no cliffs); authored
	# values pass through clamped to [0, 1].
	assert_eq(RallyLibrary.event_cliffiness({}), 0.0, "missing cliffiness -> 0.0 (flat)")
	assert_almost_eq(RallyLibrary.event_cliffiness({"cliffiness": 0.4}), 0.4, 0.0001, "authored value passes through")
	assert_eq(RallyLibrary.event_cliffiness({"cliffiness": 2.0}), 1.0, "clamps above 1")
	assert_eq(RallyLibrary.event_cliffiness({"cliffiness": -1.0}), 0.0, "clamps below 0")


func test_starter_always_has_an_enterable_rally() -> void:
	# SHIPPED-CONTENT guarantee: this must run against the REAL catalogue, not the
	# fixtures installed by before_each — restore first so CarLibrary sees the real
	# roster. (after_each's restore still runs afterward; it's idempotent.)
	CarFixtures.restore()
	# Anti-soft-lock floor: now that progression is gated on power-to-weight (not an
	# open-class pool at every tier), the guarantee is that the weakest car in the
	# real roster can always enter at least one NON-showdown rally, and the showdown
	# stays open-class so it can finish the game even if it never earns another car.
	# Derive the weakest car by p/w rather than pinning a specific catalogue id.
	var starter: Dictionary = {}
	var starter_pw := INF
	for spec in CarLibrary.all():
		var pw := CarLibrary.power_to_weight(spec)
		if pw < starter_pw:
			starter_pw = pw
			starter = spec
	assert_false(starter.is_empty(), "the roster has at least one car")
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


# --- Eligibility -------------------------------------------------------------

func test_open_class_matches_every_car() -> void:
	# An open-class rally (empty restriction) accepts every car in the roster. Iterating
	# CARS as opaque input is fine; the empty-restriction rally is synthetic so the test
	# never leans on a specific authored open-class entry existing.
	var open_class := {"restriction": {}}
	for spec in CarLibrary.all():
		assert_true(RallyLibrary.is_eligible(open_class, spec),
			"open-class accepts %s" % spec["name"])


func test_drive_mode_restriction_filters() -> void:
	# is_eligible honours a drive_mode restriction regardless of the roster. Synthetic
	# cars so the test never leans on which catalogue car happens to be RWD/AWD.
	var rwd_only := {"restriction": {"drive_mode": CarLibrary.RWD}}
	assert_true(RallyLibrary.is_eligible(rwd_only, {"drive_mode": CarLibrary.RWD}), "RWD car eligible")
	assert_false(RallyLibrary.is_eligible(rwd_only, {"drive_mode": CarLibrary.AWD}), "AWD car excluded")


func test_country_restriction_filters() -> void:
	var jp_only := {"restriction": {"country": "JP"}}
	assert_true(RallyLibrary.is_eligible(jp_only, {"country": "JP"}), "JP car eligible")
	assert_false(RallyLibrary.is_eligible(jp_only, {"country": "US"}), "US car excluded")


func test_power_to_weight_restriction_filters() -> void:
	# The p/w gate is a CEILING only (pw_max) — there is no hard floor, so a weak car is
	# always eligible and only the over-powered car is excluded. Bands are in hp/tonne
	# (is_eligible converts each car's kW/kg to hp/tonne before comparing). Use synthetic
	# cars spanning low / mid / high p/w and derive the cap from the mid car's own figure,
	# so the test leans on the eligibility LOGIC — never on authored catalogue values
	# (which are free to change). power_to_weight() reads peak_torque + redline straight
	# off the entry, so no real engine id is needed.
	var low := {"mass": 1200.0, "peak_torque": 200.0, "redline": 6000.0, "drive_mode": CarLibrary.RWD}
	var mid := {"mass": 1200.0, "peak_torque": 400.0, "redline": 6000.0, "drive_mode": CarLibrary.RWD}
	var high := {"mass": 1000.0, "peak_torque": 600.0, "redline": 8000.0, "drive_mode": CarLibrary.RWD}
	var pw_mid := CarLibrary.power_to_weight(mid) * RallyLibrary.KW_KG_TO_HP_TONNE
	# A ceiling gate lets the weakest car in (no floor) but caps the strong.
	var cap := {"restriction": {"pw_max": pw_mid * 0.95}}
	assert_true(RallyLibrary.is_eligible(cap, low), "the low-power car clears a ceiling gate")
	assert_false(RallyLibrary.is_eligible(cap, mid), "a stronger car is capped out")
	# Even far below the ceiling, a car stays eligible — the floor is gone.
	var high_cap := {"restriction": {"pw_max": pw_mid * 10.0}}
	assert_true(RallyLibrary.is_eligible(high_cap, low), "no hard floor: a weak car is still eligible")
	assert_true(RallyLibrary.is_eligible(high_cap, high), "and a strong car under the ceiling too")


func test_underpower_warning_fires_below_the_ceiling_fraction() -> void:
	# There's no hard floor, but a car well under the class ceiling gets a non-blocking
	# start-line warning: underpower_warning returns non-empty iff the car's p/w is below
	# PW_WARN_FRACTION of pw_max. Derive the ceiling from a synthetic car's own figure so
	# the test exercises the fraction LOGIC, not authored values.
	var car := {"mass": 1200.0, "peak_torque": 400.0, "redline": 6000.0, "drive_mode": CarLibrary.RWD}
	var pw := CarLibrary.power_to_weight(car) * RallyLibrary.KW_KG_TO_HP_TONNE
	var frac: float = RallyLibrary.PW_WARN_FRACTION
	# Ceiling low enough that the car sits comfortably above the warn line -> no warning.
	var strong := {"restriction": {"pw_max": pw / frac * 0.9}}
	assert_eq(RallyLibrary.underpower_warning(strong, car), "",
		"a car above the warn fraction of the ceiling isn't warned")
	# Ceiling high enough that the car falls below the warn line -> warning.
	var weak := {"restriction": {"pw_max": pw / frac * 1.1}}
	assert_ne(RallyLibrary.underpower_warning(weak, car), "",
		"a car below the warn fraction of the ceiling is warned")
	# An open-class rally (no ceiling) never warns.
	assert_eq(RallyLibrary.underpower_warning({"restriction": {}}, car), "",
		"open class has no ceiling, so no underpower warning")


func test_installed_upgrades_change_rally_eligibility() -> void:
	# An upgrade shifts a car's effective power-to-weight, so fitting one can qualify
	# or disqualify it for a rally's pw band — the HQ passes the car's effective_meta
	# (baseline + installed upgrades) to is_eligible, not the raw roster entry. Use a
	# synthetic car and derive each band from the ACTUAL before/after p/w so the test
	# leans on the mechanism (upgrades flow through effective_meta into eligibility),
	# not on the MX-5's authored stats or a kit's tuned magnitude.
	var car := {"mass": 1100.0, "peak_torque": 200.0, "redline": 6500.0,
		"tire_compound": 1.0, "drive_mode": CarLibrary.RWD}
	var bare := UpgradeLibrary.effective_meta({"installed_upgrades": []}, car)
	var powered := UpgradeLibrary.effective_meta({"installed_upgrades": ["turbo_large"]}, car)
	var maxed := UpgradeLibrary.effective_meta({"installed_upgrades": ["turbo_large", "weight_reduction"]}, car)
	var pw_bare := CarLibrary.power_to_weight(bare) * RallyLibrary.KW_KG_TO_HP_TONNE
	var pw_powered := CarLibrary.power_to_weight(powered) * RallyLibrary.KW_KG_TO_HP_TONNE
	var pw_maxed := CarLibrary.power_to_weight(maxed) * RallyLibrary.KW_KG_TO_HP_TONNE
	assert_gt(pw_powered, pw_bare, "an engine kit raises effective p/w")
	assert_gt(pw_maxed, pw_powered, "adding weight reduction raises it further")
	# A ceiling between bare and maxed: the bare car clears it, the fully-built one is capped out.
	var cap_gate := {"restriction": {"pw_max": (pw_bare + pw_maxed) * 0.5}}
	assert_true(RallyLibrary.is_eligible(cap_gate, bare), "bare car clears the ceiling gate")
	assert_false(RallyLibrary.is_eligible(cap_gate, maxed), "engine kit + weight reduction push it over the cap")


func test_qualifying_detune_ducks_an_over_powered_car_under_the_cap() -> void:
	# An over-powered car can enter a pw_max-capped rally by agreeing to a detune:
	# qualifying_detune returns the whole-percent engine tune that scales its p/w
	# under the cap. Synthetic car; the cap is derived from the car's own figure, so
	# the test exercises the LOGIC (linear torque scaling + the is_eligible
	# verification), never an authored value.
	var car := {"mass": 1000.0, "peak_torque": 500.0, "redline": 7000.0, "drive_mode": CarLibrary.RWD}
	var pw := CarLibrary.power_to_weight(car) * RallyLibrary.KW_KG_TO_HP_TONNE
	var rally := {"restriction": {"pw_max": pw * 0.8}}
	assert_false(RallyLibrary.is_eligible(rally, car), "the car is over the cap at full tune")
	var frac := RallyLibrary.qualifying_detune(rally, car)
	assert_between(frac, 0.01, 0.99, "an over-cap car needs a real down-tune (not 0, not full power)")
	assert_almost_eq(frac * 100.0, roundf(frac * 100.0), 0.0001,
		"the tune is a whole slider percent, so it round-trips through the detune slider")
	# It is the LARGEST such percent: within one slider step of the exact cap ratio.
	assert_gt(frac, 0.8 - 0.011, "the proposed tune sits within one percent step of the cap ratio")
	# And the detuned car really is eligible (the helper verifies through is_eligible).
	var detuned := car.duplicate()
	detuned["peak_torque"] = float(car["peak_torque"]) * frac
	assert_true(RallyLibrary.is_eligible(rally, detuned), "the proposed detune makes the car eligible")


func test_qualifying_detune_full_power_and_unfixable_cases() -> void:
	var car := {"mass": 1000.0, "peak_torque": 500.0, "redline": 7000.0, "drive_mode": CarLibrary.RWD}
	var pw := CarLibrary.power_to_weight(car) * RallyLibrary.KW_KG_TO_HP_TONNE
	# Already eligible at full tune -> 1.0 (an absolute slider setting: full power).
	assert_eq(RallyLibrary.qualifying_detune({"restriction": {"pw_max": pw * 1.1}}, car), 1.0,
		"a car already under the cap needs no detune")
	# A non-power restriction failing too -> no detune can fix it.
	var wrong_drive := {"restriction": {"drive_mode": CarLibrary.AWD, "pw_max": pw * 0.8}}
	assert_eq(RallyLibrary.qualifying_detune(wrong_drive, car), -1.0,
		"detuning can't fix a drive-mode mismatch")
	# The contract everywhere: the result is either -1.0 or a tune that verifies
	# eligible — even against a tight cap where the whole-percent rounding can land off.
	var narrow := {"restriction": {"pw_max": pw * 0.8}}
	var frac := RallyLibrary.qualifying_detune(narrow, car)
	if frac > 0.0:
		var detuned := car.duplicate()
		detuned["peak_torque"] = float(car["peak_torque"]) * frac
		assert_true(RallyLibrary.is_eligible(narrow, detuned),
			"a returned tune always verifies eligible against the whole restriction")


# --- Determinism -------------------------------------------------------------

func test_track_generation_is_deterministic() -> void:
	var ev: Dictionary = RallyLibrary.by_id("coastal_sprint")["events"][0]
	var a := await TrackGenerator.generate(_params(Vector2.ZERO, Vector2(0, 1), int(ev["seed"]),
		int(ev["turn_count"]), RallyLibrary.event_width(ev), 8.0))
	var b := await TrackGenerator.generate(_params(Vector2.ZERO, Vector2(0, 1), int(ev["seed"]),
		int(ev["turn_count"]), RallyLibrary.event_width(ev), 8.0))
	assert_almost_eq((a["centerline"] as Curve2D).get_baked_length(),
		(b["centerline"] as Curve2D).get_baked_length(), 0.001, "same seed -> same track length")
	assert_eq(a["pieces"].size(), b["pieces"].size(), "same seed -> same piece count")



# --- Turn splits (the in-stage "vs P1" pace popup) ---------------------------

func test_turn_splits_are_monotonic_and_total_matches_target() -> void:
	var track := _track_with_pieces()
	var car := CarLibrary.by_id("fx_light_rwd")
	var splits := RallyLibrary.derive_turn_splits(track, car, {})
	assert_eq(splits.size(), track["pieces"].size(), "one split per placed turn")
	var prev_off := -1.0
	var prev_ms := -1
	for s in splits:
		assert_gt(float(s["end_offset_m"]), prev_off, "arc offset rises each turn")
		assert_gte(int(s["cum_ms"]), prev_ms, "cumulative time rises each turn")
		prev_off = float(s["end_offset_m"])
		prev_ms = int(s["cum_ms"])
	# Final split must equal the physics-optimum time for this car (Task 4 invariant).
	var last_ms := int(splits[splits.size() - 1]["cum_ms"])
	assert_almost_eq(last_ms, LapTimeModel.optimum_ms(track, car, {}), 2,
		"last split cum_ms equals LapTimeModel.optimum_ms")


func test_turn_splits_empty_without_pieces() -> void:
	var car := CarLibrary.by_id("fx_light_rwd")
	assert_eq(RallyLibrary.derive_turn_splits({}, car), [], "no track -> no splits")
	assert_eq(RallyLibrary.derive_turn_splits({"pieces": []}, car), [], "no pieces -> no splits")


func test_turn_splits_honour_target_override() -> void:
	var track := _track_with_pieces()
	var car := CarLibrary.by_id("fx_light_rwd")
	var natural := RallyLibrary.derive_turn_splits(track, car)
	var overridden := RallyLibrary.derive_turn_splits(track, car, {"target_ms_override": 42000})
	# The final cumulative time lands exactly on the override.
	assert_eq(int(overridden[overridden.size() - 1]["cum_ms"]), 42000,
		"override rescales the total to the hand-set value")
	# The per-turn fractions (what the popup uses) are preserved by the rescale.
	var n_total := float(natural[natural.size() - 1]["cum_ms"])
	var o_total := float(overridden[overridden.size() - 1]["cum_ms"])
	for i in natural.size():
		assert_almost_eq(float(overridden[i]["cum_ms"]) / o_total,
			float(natural[i]["cum_ms"]) / n_total, 0.001,
			"turn %d keeps its share of the total under the override" % i)


# --- Synthetic track helper (cheap, no world generation) --------------------

# A Curve2D with a handful of collinear points plus a pieces array whose
# entry_pos values lie exactly on the curve. Sufficient to exercise the
# optimum_profile / derive_turn_splits path without generating a full world.
func _track_with_pieces() -> Dictionary:
	var c := Curve2D.new()
	c.add_point(Vector2(0, 0))
	c.add_point(Vector2(0, 100))
	c.add_point(Vector2(0, 200))
	c.add_point(Vector2(0, 300))
	c.add_point(Vector2(0, 400))
	c.add_point(Vector2(0, 500))
	# Three pieces whose entry_pos points sit on the curve.
	var pieces: Array = [
		{"entry_pos": Vector2(0, 0)},
		{"entry_pos": Vector2(0, 150)},
		{"entry_pos": Vector2(0, 350)},
	]
	return {"centerline": c, "pieces": pieces}


# --- Physics-based turn splits (Task 4) -------------------------------------

func test_turn_splits_final_equals_optimum_ms() -> void:
	var track := _track_with_pieces()
	var car := CarLibrary.by_id("fx_light_rwd")
	var splits := RallyLibrary.derive_turn_splits(track, car, {})
	assert_false(splits.is_empty(), "splits are non-empty")
	assert_almost_eq(int(splits[splits.size() - 1]["cum_ms"]),
		LapTimeModel.optimum_ms(track, car, {}), 2, "last split == optimum_ms")


func test_turn_splits_monotonic() -> void:
	var track := _track_with_pieces()
	var splits := RallyLibrary.derive_turn_splits(track, CarLibrary.by_id("fx_light_rwd"), {})
	for i in range(1, splits.size()):
		assert_gte(int(splits[i]["cum_ms"]), int(splits[i - 1]["cum_ms"]), "cum_ms monotonic")


func test_turn_splits_override_rescales_to_total() -> void:
	var track := _track_with_pieces()
	var splits := RallyLibrary.derive_turn_splits(track, CarLibrary.by_id("fx_light_rwd"), {"target_ms_override": 60000})
	assert_almost_eq(int(splits[splits.size() - 1]["cum_ms"]), 60000, 2, "rescaled to override total")


# --- Opponent field ----------------------------------------------------------

func test_opponent_field_shape_and_bounds() -> void:
	var rally := RallyLibrary.by_id("coastal_sprint")
	var track := _track_with_pieces()
	var events: Array = (rally["events"] as Array).slice(0, 3)
	var event_results := [track, track, track]
	var field := RallyLibrary.generate_opponent_field(rally, event_results, events)
	assert_between(field.size(), RallyLibrary.FIELD_MIN, RallyLibrary.FIELD_MAX,
		"field has 10-15 opponents")
	for opp in field:
		if opp["dnf"]:
			assert_eq(int(opp["combined_ms"]), -1, "a DNF opponent does not rank")
		else:
			var sum := 0
			for i in event_results.size():
				var t: int = opp["event_times_ms"][i]
				var best_car := RallyLibrary._best_eligible_car(rally)
				# Fastest a rival can go: the tier's fast end minus the ±noise, clamped so
				# they never beat the physics optimum. Every rival's event time is >= that.
				var band := RallyLibrary._pace_band(int(rally.get("difficulty", 1)))
				var min_factor: float = maxf(band.x * (1.0 - RallyLibrary.PACE_EVENT_NOISE), RallyLibrary.PACE_MIN_FLOOR)
				var floor_ms := int(LapTimeModel.optimum_ms(event_results[i], best_car, events[i]) * min_factor)
				assert_gte(t, floor_ms - 1, "event time >= best eligible car floor * fastest possible pace")
				sum += t
			assert_eq(int(opp["combined_ms"]), sum, "combined time is the sum of event times")


func test_opponent_field_is_deterministic() -> void:
	var rally := RallyLibrary.by_id("rwd_masters")
	var track := _track_with_pieces()
	var events: Array = (rally["events"] as Array).slice(0, 3)
	var a := RallyLibrary.generate_opponent_field(rally, [track, track, track], events)
	var b := RallyLibrary.generate_opponent_field(rally, [track, track, track], events)
	assert_eq(a, b, "same rally seed -> identical opponent field")


func test_opponents_drive_eligible_cars() -> void:
	# Every rival is assigned an identified car; in a restricted rally the car must
	# satisfy the restriction. Drive it with a synthetic RWD-only rally so the test
	# leans on the assignment LOGIC, not on which authored rally happens to be RWD.
	var rally := {"id": "synthetic_rwd", "difficulty": 2, "restriction": {"drive_mode": CarLibrary.RWD},
		"events": [{"seed": 1}, {"seed": 2}, {"seed": 3}]}
	var track := _track_with_pieces()
	var events: Array = rally["events"]
	var field := RallyLibrary.generate_opponent_field(rally, [track, track, track], events)
	for opp in field:
		var car_id := String(opp.get("car_id", ""))
		assert_ne(car_id, "", "%s drives an identified car" % opp["name"])
		var meta := CarLibrary.by_id(car_id)
		assert_false(meta.is_empty(), "the rival car id resolves to a CarLibrary entry")
		assert_eq(int(meta.get("drive_mode", -1)), CarLibrary.RWD, "RWD-only rally fields only RWD rivals")
		assert_eq(String(opp.get("car_name", "")), String(meta.get("name", "")), "car name matches the id")


func test_wrecks_occur_somewhere_in_the_roster() -> void:
	# The wreck mechanism actually crashes rivals out across a spread of seeds (it's not
	# so rare it never fires). Uses the whole authored roster as a bag of seeds rather
	# than pinning any one rally's outcome.
	var any_wreck := false
	for rally in RallyLibrary.RALLIES:
		var track := _track_with_pieces()
		var events := [{"seed": 1}, {"seed": 2}, {"seed": 3}]
		var rally_with_events: Dictionary = rally.duplicate()
		rally_with_events["events"] = events
		for opp in RallyLibrary.generate_opponent_field(rally_with_events, [track, track, track], events):
			if opp["dnf"]:
				any_wreck = true
	assert_true(any_wreck, "some opponents wreck (DNF) across the roster")


func test_at_most_one_wreck_per_event() -> void:
	# The core wreck invariant, independent of the wreck CHANCE: no more than one rival
	# ever wrecks in a single event, so the run scene shows at most one roadside wreck
	# per stage. Swept over the whole roster (many seeds) so it holds broadly.
	var track := _track_with_pieces()
	for rally in RallyLibrary.RALLIES:
		var events := [{"seed": 11}, {"seed": 22}, {"seed": 33}]
		var rally_with_events: Dictionary = rally.duplicate()
		rally_with_events["events"] = events
		var field := RallyLibrary.generate_opponent_field(
			rally_with_events, [track, track, track], events)
		for k in events.size():
			var wrecked_in_k := 0
			for opp in field:
				if int(opp["wreck_event"]) == k:
					wrecked_in_k += 1
			assert_lte(wrecked_in_k, 1,
				"%s event %d wrecks at most one rival" % [rally["id"], k])


func test_a_wrecked_rival_dnfs_from_its_wreck_event_on() -> void:
	# A rival who wrecks in event k has no time for k or any later event, DNFs the rally
	# (combined -1, doesn't rank), and carries a valid roadside placement to stage.
	var track := _track_with_pieces()
	var events := [{"seed": 5}, {"seed": 6}, {"seed": 7}]
	# Sweep the roster to find a field that actually contains a wreck (deterministic).
	var field: Array = []
	for rally in RallyLibrary.RALLIES:
		var rally_with_events: Dictionary = rally.duplicate()
		rally_with_events["events"] = events
		var f := RallyLibrary.generate_opponent_field(
			rally_with_events, [track, track, track], events)
		var has_wreck := false
		for opp in f:
			if int(opp["wreck_event"]) >= 0:
				has_wreck = true
				break
		if has_wreck:
			field = f
			break
	assert_false(field.is_empty(), "found a field containing a wreck")
	for opp in field:
		var we := int(opp["wreck_event"])
		if we < 0:
			continue
		assert_true(bool(opp["dnf"]), "a wrecked rival DNFs")
		assert_eq(int(opp["combined_ms"]), -1, "a wrecked rival does not rank")
		for k in range(we, events.size()):
			assert_eq(int(opp["event_times_ms"][k]), -1,
				"no time from the wreck event onward")
		assert_between(float(opp["wreck_progress"]), 0.0, 1.0, "placement progress in [0,1]")
		assert_true(absf(float(opp["wreck_side"])) == 1.0, "placement side is ±1")


func test_event_wreck_reports_the_crashed_rival_or_nothing() -> void:
	# event_wreck() surfaces the rival who wrecked that event with the ACTUAL car they
	# drove, and returns {} for an event with no wreck. Built from a synthetic field so
	# it leans on the read logic, not on any authored rally's roll.
	var field := [
		{"name": "A", "car_id": "carA", "car_name": "Car A", "wreck_event": -1,
			"wreck_progress": 0.0, "wreck_side": 1.0},
		{"name": "B", "car_id": "carB", "car_name": "Car B", "wreck_event": 1,
			"wreck_progress": 0.4, "wreck_side": -1.0},
	]
	var none := RallyLibrary.event_wreck(field, 0)
	assert_true(none.is_empty(), "no rival wrecked event 0 -> {}")
	var hit := RallyLibrary.event_wreck(field, 1)
	assert_eq(String(hit.get("car_id", "")), "carB", "the crashed rival's actual car")
	assert_eq(String(hit.get("name", "")), "B", "the crashed rival's name")
	assert_almost_eq(float(hit.get("progress", 0.0)), 0.4, 0.001, "carries the placement")
	assert_eq(float(hit.get("side", 0.0)), -1.0, "carries the verge side")


func test_opponent_faster_car_posts_faster_time():
	# A more powerful car has a lower physics floor on the same track. Synthetic fast /
	# slow cars (identical but for power) so the test leans on the physics, not on the
	# authored stats or relative ranking of two catalogue cars.
	var track := _track_with_pieces()
	var slow := {"mass": 1200.0, "peak_torque": 200.0, "redline": 6000.0, "tire_compound": 1.0}
	var fast := {"mass": 1200.0, "peak_torque": 500.0, "redline": 7500.0, "tire_compound": 1.0}
	var fast_floor := LapTimeModel.optimum_ms(track, fast, {})
	var slow_floor := LapTimeModel.optimum_ms(track, slow, {})
	assert_lt(fast_floor, slow_floor, "fast car has a lower floor on the same track")


func test_opponent_field_deterministic_for_seed():
	var track := _track_with_pieces()
	var rally := {"id": "r1", "events": [{"seed": 1}], "restriction": {}}
	var a := RallyLibrary.generate_opponent_field(rally, [track], rally["events"])
	var b := RallyLibrary.generate_opponent_field(rally, [track], rally["events"])
	assert_eq(a.size(), b.size())
	assert_eq(int(a[0]["event_times_ms"][0]), int(b[0]["event_times_ms"][0]), "stable per seed")


func test_opponent_field_is_a_ranked_ladder() -> void:
	# Persistent per-rival skill: each rival's pace (time ÷ their OWN car's physics
	# floor) is consistent across all 3 events — a fast rival stays fast — and the
	# field's paces span a wide ladder rather than every rival averaging to mid-pack.
	# We measure pace factor (not combined time) so car-floor variety doesn't mask
	# the skill spread the fix controls.
	var rally := RallyLibrary.by_id("coastal_sprint")
	var track := _track_with_pieces()
	var events: Array = (rally["events"] as Array).slice(0, 3)
	var field := RallyLibrary.generate_opponent_field(rally, [track, track, track], events)
	var mean_paces: Array = []
	for opp in field:
		if opp["dnf"]:
			continue
		var car := CarLibrary.by_id(String(opp["car_id"]))
		var factors: Array = []
		for i in events.size():
			var floor_ms := LapTimeModel.optimum_ms(track, car, events[i])
			factors.append(float(opp["event_times_ms"][i]) / float(floor_ms))
		# Persistence: a rival's per-event paces cluster within the ±noise window
		# (ratio <= 1 + 2*noise, plus a rounding cushion) — NOT re-rolled each event.
		assert_lt(float(factors.max()) / float(factors.min()), 1.0 + 2.2 * RallyLibrary.PACE_EVENT_NOISE,
			"%s holds a consistent pace across events" % opp["name"])
		var sum := 0.0
		for f in factors:
			sum += f
		mean_paces.append(sum / factors.size())
	assert_gt(mean_paces.size(), 2, "enough clean rivals to rank")
	mean_paces.sort()
	# The field spans a real ladder: fastest vs slowest surviving rival's pace differ
	# well beyond the ±5% per-event noise (band is [1.37, 2.42] for this tier — a
	# ~1.77x ratio before noise and DNF attrition trim the surviving extremes).
	assert_gt(float(mean_paces[mean_paces.size() - 1]) / float(mean_paces[0]), 1.25,
		"field spans a ranked ladder, not a mid-pack cluster")


func test_higher_tier_fields_faster_rivals() -> void:
	# The pace band scales with hidden difficulty: a tier-4 field runs faster overall
	# than a tier-1 field on the same track (top of the field creeps toward the floor).
	var track := _track_with_pieces()
	var events := [{"seed": 1}, {"seed": 2}, {"seed": 3}]
	var results := [track, track, track]
	var easy := {"id": "easy_r", "difficulty": 1, "restriction": {}, "events": events}
	var hard := {"id": "hard_r", "difficulty": 4, "restriction": {}, "events": events}
	var easy_field := RallyLibrary.generate_opponent_field(easy, results, events)
	var hard_field := RallyLibrary.generate_opponent_field(hard, results, events)
	var best := func(f: Array) -> int:
		var b := -1
		for opp in f:
			if not opp["dnf"] and (b < 0 or int(opp["combined_ms"]) < b):
				b = int(opp["combined_ms"])
		return b
	assert_lt(best.call(hard_field), best.call(easy_field),
		"tier-4 winner is faster than the tier-1 winner on the same track")


func test_opponent_times_apply_stock_turbo_boost() -> void:
	# A rival's pace floor must reflect the car's STOCK forced induction: the same
	# car/engine posts faster rival times WITH a turbo than without. Build the roster
	# inline (one car, one engine) so the only difference between the two fields is the
	# engine's turbo_boost_gain — everything else (rally seed -> skill/noise draws) is
	# identical, so any per-event time delta is the boost alone.
	var track := _track_with_pieces()
	var rally := {"id": "turbo_probe", "difficulty": 2, "restriction": {},
		"events": [{"seed": 1}, {"seed": 2}, {"seed": 3}]}
	var results := [track, track, track]
	var make_engine := func(boost: float) -> Array[Dictionary]:
		var eng: Array[Dictionary] = [{
			"id": "probe_eng", "name": "Probe", "layout": "i4", "mass": 120.0,
			"redline_rpm": 6000.0, "peak_torque": 200.0, "peak_torque_rpm": 4000.0,
			"engine_inertia": 0.15, "gear_ratios": [3.5, 2.0, 1.4, 1.0, 0.8],
			"final_drive": 4.0, "shift_time": 0.30,
			"turbo_enabled": boost > 0.0, "turbo_boost_gain": boost,
		}]
		return eng
	var car: Array[Dictionary] = [{
		"name": "Probe", "id": "probe_car", "car_type": "coupe", "mass": 1200.0,
		"engine": "probe_eng", "tire_compound": 1.1, "drive_mode": CarFixtures.RWD,
		"weight_front": 0.5, "max_hp": 900.0, "reward_tier": 2,
	}]
	var run := func(boost: float) -> Array:
		EngineLibrary.override_for_test(make_engine.call(boost))
		CarLibrary.override_for_test(car)
		return RallyLibrary.generate_opponent_field(rally, results, rally["events"])
	var boosted: Array = run.call(0.5)
	var natural: Array = run.call(0.0)
	assert_eq(boosted.size(), natural.size(), "same seed -> same field size")
	var compared := 0
	for i in boosted.size():
		if boosted[i]["dnf"]:
			continue
		for k in results.size():
			assert_lt(int(boosted[i]["event_times_ms"][k]), int(natural[i]["event_times_ms"][k]),
				"turbo car posts a faster rival time than the same car with no boost")
			compared += 1
	assert_gt(compared, 0, "at least one non-DNF rival/event compared")


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
	var standings := RallyLibrary.build_standings(field, 200, false, "You", "MX-5")
	assert_eq(String(standings[0]["car_name"]), "Porsche 911", "the opponent's car is carried into the standings")
	assert_true(standings[1]["is_player"], "the player ranks 2nd")
	assert_eq(String(standings[1]["car_name"]), "MX-5", "the player's car is carried into the standings")


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
	# The query integrates is_eligible + the showdown lock over the real roster. Assert
	# the invariants that hold for ANY roster rather than pinning specific authored
	# rallies: every returned rally is eligible for the car, none are already complete,
	# and the showdown never appears while it is still locked. A synthetic AWD car with
	# a mid p/w keeps the input off the catalogue.
	var profile := {"rallies": {}}
	var car := {"mass": 1500.0, "peak_torque": 400.0, "redline": 6500.0,
		"tire_compound": 1.0, "drive_mode": CarLibrary.AWD, "country": "DE"}
	var enterable := RallyLibrary.incomplete_rallies_enterable_by(car, profile)
	for r in enterable:
		assert_true(RallyLibrary.is_eligible(r, car), "%s is eligible for the car" % r["id"])
		assert_false(bool(r.get("showdown", false)), "the locked showdown is not offered")


