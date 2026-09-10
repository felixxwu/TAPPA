extends GutTest
# The rally roster (RallyLibrary): the authored rally list and the pure
# functions over it — eligibility, turn splits, progress/star gating, and the
# anti-soft-lock query. Mirrors test_car_library.gd. See todo/rally-roster.md.
#
# The rival field (generate_opponent_field and everything serving it — combos,
# pace, wrecks, standings, stage_key) is deleted along with the rival field it
# generated (todo/roguelike-pivot.md decision 5).


const _TGP = preload("res://scripts/track_gen_params.gd")


func _params(start_pos: Vector2, start_heading: Vector2, seed_value: int, turn_count: int, width: float, clearance := 0.0, reserve := 0.0, straightness := 0.0, runoff := 0.0) -> _TGP:
	return _TGP.of(start_pos, start_heading, seed_value, turn_count, width, clearance, reserve, straightness, runoff)


func before_each() -> void:
	CarFixtures.install()


func after_each() -> void:
	CarFixtures.restore()
	# Safe to call unconditionally: reset() restores the shipped catalogue, so the
	# KEEP-CONTRACT cases (which never install these) are unaffected, while the
	# converted cases that install RallyFixtures/UpgradeFixtures at their top are
	# cleaned up here even if an assertion fails mid-function.
	RallyFixtures.restore()


# --- Roster validity (anti-soft-lock) ---------------------------------------

func test_roster_is_well_formed() -> void:
	assert_gt(RallyLibrary.RALLIES.size(), 0, "RallyLibrary.RALLIES is non-empty (else this test asserts nothing)")
	var ids := {}
	for rally in RallyLibrary.RALLIES:
		assert_false(ids.has(rally["id"]), "rally id '%s' is unique" % rally["id"])
		ids[rally["id"]] = true
		# Stage COUNT is authored data a designer changes freely (the deleted test_menu_flow.gd
		# derives it rather than pinning it), so assert only that a rally HAS stages —
		# which also stops the per-event loop below being vacuous.
		assert_gt(rally["events"].size(), 0, "%s has at least one event" % rally["id"])
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
	assert_gt(RallyLibrary.all().size(), 0, "RallyLibrary.all() is non-empty (else this test asserts nothing)")
	for rally in RallyLibrary.all():
		var region_id := String(rally.get("region", ""))
		assert_ne(region_id, "", "rally %s has no region" % rally.get("id", "?"))
		assert_ne(RegionLibrary.index_of(region_id), -1,
			"rally %s region %s is not in RegionLibrary" % [rally.get("id", "?"), region_id])


func test_a_region_may_hold_any_number_of_specials() -> void:
	# The old "at most one showdown per region, exactly one where rallies exist" invariant
	# is RETIRED. Specials are gated on the GLOBAL ordinary-completion count, so they
	# have no relationship to a region's contents — a corner may hold none, one, or several,
	# and an empty corner (the snow corner ships pin-less) is now the ordinary case rather
	# than an exemption. What must still hold is that every special names a real region.
	var specials := 0
	for rally in RallyLibrary.all():
		if not RallyLibrary.is_special(rally):
			continue
		specials += 1
		assert_ne(RegionLibrary.index_of(String(rally.get("region", ""))), -1,
			"special %s sits in a real region" % rally.get("id", "?"))
	assert_gt(specials, 0, "the roster authors at least one special event")


func test_every_special_is_open_class() -> void:
	# A special must never gate on a part it (or a higher rung) unlocks, or the ladder can
	# deadlock. Open-class is the simplest guarantee of that, and it also keeps the
	# low-power starter able to finish the game.
	for rally in RallyLibrary.all():
		if RallyLibrary.is_special(rally):
			assert_true((rally.get("restriction", {}) as Dictionary).is_empty(),
				"special %s is open-class" % rally.get("id", "?"))


# NOTE: a contract test lived here asserting every authored part gate names a real SPECIAL
# rally, and that each special gates at most one part. Both the gates and the parts are
# deleted with the persistent parts model (todo/roguelike-pivot.md), so there is nothing
# left to resolve. Region unlock in the pivot is linear and carries no per-part gating.


# test_map_pins_are_well_formed_and_never_stack,
# test_suggest_map_pos_returns_a_legal_free_pin_for_every_authored_region and
# test_map_pos_is_free_rejects_a_pin_on_top_of_an_authored_one are DELETED with the
# pin-placement machinery they exercised (MIN_PIN_SEPARATION / suggest_map_pos /
# map_pos_is_free / map_pos_of — see rally_library.gd's "Map exploration: DELETED" note).
# The RALLIES rows keep their authored map_pos values as inert data; nothing reads them,
# so there is no structural property left to guard.


func test_event_is_wet_reads_the_weather_tables_classification() -> void:
	# The event-layer wetness seam. It must be the WEATHER TABLE's answer, not a local
	# string test — that is the whole reason it exists (a `== WEATHER_RAIN` rule silently
	# skipped storms three times running).
	#
	# Pins no design call: the expected value for each id comes from WeatherLibrary.is_wet,
	# so re-classifying a condition, or adding one, cannot break this. What it pins is the
	# DELEGATION, plus the tolerance an authored typo relies on.
	for entry in WeatherLibrary.all():
		var id := String(entry.get("id", ""))
		assert_eq(RallyLibrary.event_is_wet({"weather": id}), WeatherLibrary.is_wet(id),
			"event_is_wet defers to the weather table for '%s'" % id)
	assert_false(RallyLibrary.event_is_wet({}), "an event with no authored weather is dry")
	assert_false(RallyLibrary.event_is_wet({"weather": "no_such_condition"}),
		"an unrecognised string resolves to dry, so it is not wet")


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


func test_event_weather_defaults_to_dry() -> void:
	# An event that omits weather, or authors an unrecognised string (a typo),
	# resolves to WEATHER_DRY so a stage never crashes on a bad value.
	assert_eq(RallyLibrary.event_weather({}), RallyLibrary.WEATHER_DRY, "missing weather -> dry")
	assert_eq(RallyLibrary.event_weather({"weather": "sunny"}), RallyLibrary.WEATHER_DRY, "unrecognised string -> dry")
	# Per-condition ids resolve to themselves, driven from WeatherLibrary.all() as
	# opaque input rather than naming which ids exist (that's authored content, not
	# a logic contract) — every non-dry condition round-trips through event_weather.
	for entry in WeatherLibrary.all():
		var wid := String(entry.get("id", ""))
		if wid == "" or wid == RallyLibrary.WEATHER_DRY:
			continue
		assert_eq(RallyLibrary.event_weather({"weather": wid}), wid,
			"authored '%s' resolves to itself" % wid)


func test_every_multi_stage_rally_mixes_weather() -> void:
	# AUTHORING CONTRACT: no rally runs a single condition end to end — every
	# multi-stage rally changes weather at least once across its stages, so a
	# rally is a varied outing rather than three helpings of the same one. This
	# pins no PARTICULAR condition anywhere (a designer can retune any stage to
	# any id); it only requires that the stages don't all agree.
	for rally in RallyLibrary.RALLIES:
		var events: Array = rally.get("events", [])
		if events.size() < 2:
			continue  # a one-stage rally has nothing to mix
		var seen := {}
		for event in events:
			seen[RallyLibrary.event_weather(event)] = true
		assert_gt(seen.size(), 1,
			"rally '%s' runs '%s' for all %d stages" % [
				rally.get("id", "?"), ",".join(PackedStringArray(seen.keys())), events.size()])


func test_starter_always_has_an_enterable_rally() -> void:
	# SHIPPED-CONTENT guarantee: this must run against the REAL catalogue, not the
	# fixtures installed by before_each — restore first so CarLibrary sees the real
	# roster. (after_each's restore still runs afterward; it's idempotent.)
	CarFixtures.restore()
	# Anti-soft-lock floor: now that progression is gated on power-to-weight (not an
	# open-class pool at every tier), the guarantee is that the weakest car in the
	# real roster can always enter at least one ORDINARY rally, and a special
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
	var enterable_ordinary := 0
	var special_seen := false
	for rally in RallyLibrary.RALLIES:
		if RallyLibrary.is_special(rally):
			special_seen = true
			assert_true(rally["restriction"].is_empty(), "a special is open-class")
			assert_true(RallyLibrary.is_eligible(rally, starter), "the starter can enter a special")
			continue
		if RallyLibrary.is_eligible(rally, starter):
			enterable_ordinary += 1
	assert_gt(enterable_ordinary, 0, "the starter has at least one ordinary rally to race")
	assert_true(special_seen, "there is a special event")


# --- Eligibility -------------------------------------------------------------

func test_open_class_matches_every_car() -> void:
	# An open-class rally (empty restriction) accepts every car in the roster. Iterating
	# CARS as opaque input is fine; the empty-restriction rally is synthetic so the test
	# never leans on a specific authored open-class entry existing.
	assert_gt(CarLibrary.all().size(), 0, "CarLibrary.all() is non-empty (else this test asserts nothing)")
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


func test_doors_restriction_filters() -> void:
	# `doors` is a BODY property, read flat off the car meta (no engine involved).
	var coupes_only := {"restriction": {"doors_max": 2}}
	assert_true(RallyLibrary.is_eligible(coupes_only, {"doors": 2}), "a 2-door is eligible")
	assert_false(RallyLibrary.is_eligible(coupes_only, {"doors": 4}), "a 4-door is excluded")
	var family_only := {"restriction": {"doors_min": 4}}
	assert_true(RallyLibrary.is_eligible(family_only, {"doors": 5}), "a 5-door clears the floor")
	assert_false(RallyLibrary.is_eligible(family_only, {"doors": 2}), "a 2-door is below the floor")


func test_displacement_restriction_resolves_through_the_fitted_engine() -> void:
	# engine_min_l / engine_max_l are judged against the CURRENT engine's displacement_l,
	# not a flat key on the car dict. before_each installed the synthetic fixture engines
	# (fx_i4 small / fx_v8 large), so the band edges below are derived from those, never
	# from a shipped engine. Pick a band strictly between the two fixture displacements.
	var small := float(EngineLibrary.by_id("fx_i4")["displacement_l"])
	var large := float(EngineLibrary.by_id("fx_v8")["displacement_l"])
	assert_lt(small, large, "the fixture roster has a small and a large engine")
	var mid := (small + large) * 0.5
	var big_bore := {"restriction": {"engine_min_l": mid}}
	assert_true(RallyLibrary.is_eligible(big_bore, {"engine": "fx_v8"}), "the large engine clears the floor")
	assert_false(RallyLibrary.is_eligible(big_bore, {"engine": "fx_i4"}), "the small engine is below the floor")
	var small_bore := {"restriction": {"engine_max_l": mid}}
	assert_true(RallyLibrary.is_eligible(small_bore, {"engine": "fx_i4"}), "the small engine is under the cap")
	assert_false(RallyLibrary.is_eligible(small_bore, {"engine": "fx_v8"}), "the large engine is over the cap")


func test_cylinder_restriction_derives_from_the_engine_layout() -> void:
	# Cylinder count is NOT an authored field — it's FIRING[layout].size(). A fixture i4
	# passes a 4-cylinder ceiling; the fixture V8 doesn't, and clears a V8-and-up floor.
	assert_eq(EngineLibrary.cylinders(EngineLibrary.by_id("fx_i4")), 4, "i4 layout derives 4 cylinders")
	assert_eq(EngineLibrary.cylinders(EngineLibrary.by_id("fx_v8")), 8, "v8 layout derives 8 cylinders")
	var four_pot_max := {"restriction": {"cylinders_max": 4}}
	assert_true(RallyLibrary.is_eligible(four_pot_max, {"engine": "fx_i4"}), "the i4 is under the cap")
	assert_false(RallyLibrary.is_eligible(four_pot_max, {"engine": "fx_v8"}), "the V8 is over the cap")
	var eight_pot_min := {"restriction": {"cylinders_min": 8}}
	assert_true(RallyLibrary.is_eligible(eight_pot_min, {"engine": "fx_v8"}), "the V8 clears the floor")
	assert_false(RallyLibrary.is_eligible(eight_pot_min, {"engine": "fx_i4"}), "the i4 is below the floor")


func test_cylinders_is_zero_for_an_unknown_layout() -> void:
	assert_eq(EngineLibrary.cylinders({}), 0, "an empty engine dict has no cylinder data")
	assert_eq(EngineLibrary.cylinders({"layout": "not_a_layout"}), 0, "an unknown layout has no cylinder data")


func test_an_unresolvable_engine_fails_an_engine_derived_restriction() -> void:
	# The old bug: engine data was read off a key nothing ever wrote, so an engine_max_l
	# gate silently accepted EVERY car. When the engine can't be resolved the car must be
	# REJECTED, not waved through — for both edges of both engine-derived fields.
	for restriction in [{"engine_max_l": 99.0}, {"engine_min_l": 0.0},
			{"cylinders_max": 99}, {"cylinders_min": 0}]:
		var rally := {"restriction": restriction}
		assert_false(RallyLibrary.is_eligible(rally, {"engine": "no_such_engine"}),
			"an unknown engine id is rejected by %s" % [restriction])
		assert_false(RallyLibrary.is_eligible(rally, {}),
			"a meta with no engine at all is rejected by %s" % [restriction])
	# ...but a restriction that names NO engine-derived field never consults the engine,
	# so an engine-less synthetic meta still passes it.
	assert_true(RallyLibrary.is_eligible({"restriction": {"doors_max": 2}}, {"doors": 2}),
		"a non-engine restriction doesn't require a resolvable engine")


func test_an_engine_swap_flips_engine_derived_eligibility() -> void:
	# THE point of resolving through the engine: UpgradeLibrary.effective_meta re-points
	# meta["engine"] at the fitted engine, so swapping one in changes which rallies the
	# car can enter. Same car body, two engines, one displacement band.
	var stock: Dictionary = CarLibrary.by_id("fx_light_rwd")
	assert_false(stock.is_empty(), "the fixture car resolves")
	var small := float(EngineLibrary.by_id("fx_i4")["displacement_l"])
	var large := float(EngineLibrary.by_id("fx_v8")["displacement_l"])
	var mid := (small + large) * 0.5
	var big_bore := {"restriction": {"engine_min_l": mid}}
	var v8_only := {"restriction": {"cylinders_min": 8}}
	var as_stock := UpgradeLibrary.effective_meta({}, stock)
	assert_false(RallyLibrary.is_eligible(big_bore, as_stock), "stock-engined car misses the displacement floor")
	assert_false(RallyLibrary.is_eligible(v8_only, as_stock), "stock-engined car misses the cylinder floor")
	var swapped := UpgradeLibrary.effective_meta({"swapped_engine": "fx_v8"}, stock)
	assert_true(RallyLibrary.is_eligible(big_bore, swapped), "the swapped-in big engine clears the displacement floor")
	assert_true(RallyLibrary.is_eligible(v8_only, swapped), "the swapped-in big engine clears the cylinder floor")
	# The body property is untouched by the swap.
	assert_eq(int(swapped.get("doors", -1)), int(stock.get("doors", -2)), "a swap doesn't change the door count")


func test_every_shipped_rally_has_at_least_one_car_that_can_enter_it() -> void:
	# SHIPPED-CONTENT guarantee (like the starter-floor test): an "unenterable rally" is a
	# LOGIC failure, not a tuning choice, so this asserts existence only — never which car,
	# never how many. Restore the fixtures so both catalogues are the real ones.
	assert_gt(RallyLibrary.all().size(), 0, "RallyLibrary.all() is non-empty (else this test asserts nothing)")
	CarFixtures.restore()
	for rally in RallyLibrary.all():
		var found := ""
		for spec in CarLibrary.all():
			var meta := UpgradeLibrary.effective_meta({}, spec)
			if RallyLibrary.is_eligible(rally, meta):
				found = String(spec.get("id", ""))
				break
		assert_ne(found, "", "some car in the roster can enter rally '%s'" % rally.get("id", "?"))


# --- Determinism -------------------------------------------------------------

func test_track_generation_is_deterministic() -> void:
	RallyFixtures.install()
	var ev: Dictionary = RallyLibrary.by_id("fx_open")["events"][0]
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


# test_a_gated_parts_prerequisite_is_reached_no_later_than_the_part_itself and
# test_engine_swapping_is_the_first_special_the_map_reaches DELETED: both read
# RallyLibrary.reveal_depths(), which seeded its reachability waves from
# `prize_car_id(rally) != "" and CarLibrary.STARTER_MODEL_IDS.has(...)` -- with every
# `prize_car` field deleted, reveal_depths() returned {} against the shipped roster, so
# both would have failed on a condition that deletion caused, not a real regression in
# either invariant. reveal_depths() itself is now deleted with the HQ map (see the
# "Map exploration: DELETED" note below); neither invariant has a map to walk any more.


# --- Progress / stars & the special ladder -----------------------------------------------------
# test_podium_count_tracks_profile is DELETED with RallyLibrary.podium_count() (deleted
# with the rally-podium bookkeeping — see the "podium_count() is DELETED" note in
# rally_library.gd). The profile's per-rally "completed" flag remains save-side state;
# nothing in the live rally surface derives a count from it any more.


# test_every_finish_scores_and_the_podium_scores_more and
# test_the_scoring_curve_is_flat_within_each_tier DELETED: both tested
# RallyLibrary.stars_for_placement / PODIUM_PLACES / MAX_STARS_PER_RALLY, all deleted with
# the star ledger (todo/roguelike-pivot.md decision 21).


# --- Map exploration: DELETED with the HQ map ---------------------------------
# The geometric reveal suite is gone with the machinery it pinned (rally_revealed /
# lit_sources / reveal_link_pairs / distance_beyond_frontier / HQ_MAP_POS /
# map_reveal_radius — see rally_library.gd's "Map exploration: DELETED" note): the
# diegetic HQ map and overworld are deleted, so there is no reveal gate to exercise.
# Deleted tests: the opening-circle/completion-lighting/dark-map cases,
# test_the_reveal_graph_links_only_pairs_that_are_both_revealed (+ _graph_links),
# test_distance_beyond_frontier_*, test_spending_stars_cannot_close_a_reveal_gate,
# test_the_hq_circle_alone_reveals_no_rally and the garage-placement determinism test.


# NOTE: a test lived here pinning "only the LAST special completed finishes the game".
# There is no game-finishing beat any more -- decision 45 accepts no endgame, so
# all_specials_completed is deleted rather than left hanging on a condition that no longer
# means anything.


func test_incomplete_enterable_query_respects_eligibility() -> void:
	# The query integrates is_eligible with the completion record. Runs on a SYNTHETIC roster
	# rather than the shipped one: what a given car can enter depends on authored
	# restrictions, which a designer retunes freely. (The map-reveal gate this query also
	# applied is DELETED with the diegetic HQ map — with no map there is nothing to be
	# locked behind, so eligibility alone answers "can I enter".)
	#
	# Two rallies, both incomplete: one in the car's class, one not. A correct query
	# returns exactly the first.
	RallyLibrary.override_for_test([
		{"id": "q_open", "name": "Open", "region": "home", "special": false, "difficulty": 1,
			"restriction": {"drive_mode": CarLibrary.AWD}, "events": []},
		{"id": "q_out_of_class", "name": "Out Of Class", "region": "home", "special": false,
			"difficulty": 1,
			"restriction": {"drive_mode": CarLibrary.FWD}, "events": []},
	] as Array[Dictionary])
	var profile := {"rallies": {}}
	# The car carries an ENGINE (a before_each fixture, not a shipped entry) and a door
	# count, because engine-derived restrictions (displacement / cylinders) and doors_*
	# resolve through those fields and REJECT a car that cannot supply them.
	var car := {"mass": 1500.0, "peak_torque": 400.0, "redline": 6500.0,
		"tire_compound": 1.0, "drive_mode": CarLibrary.AWD, "country": "DE",
		"engine": "fx_i4", "doors": 2}
	var ids: Array = []
	for r in RallyLibrary.incomplete_rallies_enterable_by(car, profile):
		ids.append(String(r["id"]))
	assert_eq(ids, ["q_open"],
		"only the rally that is in-class is offered")


func test_a_completed_rally_is_never_offered_as_enterable() -> void:
	# The query is the anti-soft-lock "what can I still do" answer, so anything already
	# finished must drop out of it.
	RallyLibrary.override_for_test([
		{"id": "q_done", "name": "Done", "region": "home", "special": false, "difficulty": 1,
			"restriction": {}, "events": []},
	] as Array[Dictionary])
	var car := {"mass": 1500.0, "peak_torque": 400.0, "redline": 6500.0,
		"tire_compound": 1.0, "drive_mode": CarLibrary.AWD, "country": "DE",
		"engine": "fx_i4", "doors": 2}
	assert_eq(RallyLibrary.incomplete_rallies_enterable_by(car, {"rallies": {}}).size(), 1,
		"offered while incomplete")
	assert_eq(RallyLibrary.incomplete_rallies_enterable_by(
		car, {"rallies": {"q_done": {"completed": true}}}).size(), 0,
		"dropped once completed")


# --- Shipped content: every stage actually grows trees -------------------------

func test_every_shipped_stage_authors_a_forestiness_that_grows_something() -> void:
	# The forest gate keeps a cell where a SINGLE-OCTAVE Perlin field exceeds
	# 1 - forestiness, and that field never approaches its nominal extremes — so a
	# forestiness that reads like "sparse forest" can silently mean NO TREES AT ALL.
	# The Alps shipped that way: several stages were authored at 0.15-0.30 and generated
	# bare. It fails SILENTLY (an empty stage, no error), which is exactly the shape of
	# bug that needs a shipped-content guard rather than a unit test.
	#
	# Nothing here pins an authored value or a coverage figure: the assertion is only
	# "whatever this stage asks for, at least some ground passes the gate", which must
	# hold for ANY reasonable authoring and re-derives if the noise or the values change.
	var cfg: GameConfig = Config.data
	var bare: Array[String] = []
	for rally in RallyLibrary.all():
		for event in rally.get("events", []):
			var forestiness := RallyLibrary.event_forestiness(event)
			if forestiness >= 1.0:
				continue  # unfiltered: the gate is skipped entirely
			var seed_value := int(event.get("seed", cfg.track_seed))
			var noise := TreeScatter.make_forest_noise(seed_value, cfg.forest_wavelength_m)
			var threshold := 1.0 - clampf(forestiness, 0.0, 1.0)
			# Walk a coarse lattice over a stage-sized area. Enough samples that a stage
			# keeping even a fraction of a percent of its ground still registers.
			var kept := 0
			for ix in 60:
				for iy in 60:
					var p := Vector2(float(ix) * 40.0 - 1200.0, float(iy) * 40.0 - 1200.0)
					if TreeScatter.forest_density(noise, p) > threshold:
						kept += 1
			if kept == 0:
				bare.append("%s (forestiness %.2f)" % [rally.get("id", "?"), forestiness])
	assert_eq(bare, [] as Array,
		"every stage's forestiness passes some ground through the forest gate; bare: %s"
			% ", ".join(bare))


# "What a SPECIAL must award" section DELETED (todo/roguelike-pivot.md decisions 21 & 28):
# test_every_special_awards_a_car_a_part_or_a_capability and
# test_ordinary_rallies_exist_that_award_nothing both asserted through
# RallyLibrary.has_prize / prize_part_id / prize_capability_id, all deleted -- the
# "a special must award a car, a part or a capability" invariant they encoded has no
# replacement yet in the new economy (per-stage money payout, not a per-rally prize), so
# there is nothing left to assert until that design lands.


# test_the_engine_swap_unlock_rally_resolves is DELETED: ENGINE_SWAP_UNLOCK_RALLY went
# when the Engine Swap became a mid-run boost (BoostLibrary "engine_swap") with no meta
# unlock and no gating rally — there is no constant left to resolve. The roster entry it
# named ("front_runners") stays as an ordinary special, and the roster tests above already
# guard that every special names a real region.


# test_the_hq_circle_alone_reveals_no_rally, the garage-placement DELETED notes and
# test_the_garage_position_is_deterministic_for_a_profile are DELETED with the reveal
# machinery they read (lit_sources / map_hq_reveal_radius / hq_map_pos) — the diegetic HQ
# map and overworld are gone, so there is no circle, no garage pad and no fog left to pin.


# ---------------------------------------------------------------------------------------
# The authoring templates carry a PASTEABLE map_pos literal. Keep the two copies in step.
#
# Why this exists: readiness round 009 replaced the template's literal with "paste the
# result of RallyLibrary.suggest_map_pos(...)". That advice is gone with the function
# (deleted with the pin-placement machinery), so the literal is all an author has — and a
# baked literal rots silently when someone pastes it and makes it an authored pin itself.
# test_the_template_map_pos_is_still_a_legal_free_pin (which recomputed a replacement via
# suggest_map_pos) is DELETED with that machinery; the two templates agreeing is still
# guarded below.
func _template_map_pos_from(path: String) -> Vector2:
	var text := FileAccess.get_file_as_string(path)
	assert_false(text.is_empty(), "template file %s is readable" % path)
	# The literal appears bare in the REGIONS comment and BACKSLASH-ESCAPED inside the guard's
	# string literal, so tolerate an optional backslash before each quote.
	var re := RegEx.create_from_string('\\\\?"map_pos\\\\?": Vector2\\(([-0-9.]+), ?([-0-9.]+)\\)')
	var m := re.search(text)
	assert_not_null(m, "%s still carries a pasteable map_pos literal in its template" % path)
	if m == null:
		return Vector2.ZERO
	return Vector2(float(m.get_string(1)), float(m.get_string(2)))


func test_both_authoring_templates_offer_the_same_map_pos() -> void:
	# Two copy-pasteable rows exist: the REGIONS header comment and the reachability guard's
	# failure message. Round 010 found them disagreeing (one updated, one not), which is how
	# an author ends up pasting a coordinate the other half of the codebase calls illegal.
	assert_eq(_template_map_pos_from("res://scripts/region_library.gd"),
		_template_map_pos_from("res://tests/headless/test_region_assets.gd"),
		"the REGIONS template and _unreachable_region_fix must hand back the SAME pin")
