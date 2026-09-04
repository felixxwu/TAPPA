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
		# Stage COUNT is authored data a designer changes freely (test_menu_flow.gd
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


func test_map_pins_are_well_formed_and_never_stack() -> void:
	# Well-formedness only — never specific coordinates, which are authored data a
	# designer nudges freely. A pin outside [0,1]^2 lands off the map plane, and two
	# pins on top of each other are unpickable, so both are structural bugs a corner
	# re-site can introduce silently.
	assert_gt(RallyLibrary.all().size(), 0, "RallyLibrary.all() is non-empty (else this test asserts nothing)")
	# The bound is RallyLibrary's, not a copy: authoring code (suggest_map_pos /
	# map_pos_is_free) and this guard must enforce ONE number or an author can be handed a
	# "legal" pin this test then rejects.
	var min_separation: float = RallyLibrary.MIN_PIN_SEPARATION
	var seen: Array[Vector2] = []
	for rally in RallyLibrary.all():
		var pos: Vector2 = rally.get("map_pos", Vector2(-1, -1))
		var rid := String(rally.get("id", "?"))
		assert_between(pos.x, 0.0, 1.0, "rally %s map_pos.x is in [0, 1]" % rid)
		assert_between(pos.y, 0.0, 1.0, "rally %s map_pos.y is in [0, 1]" % rid)
		for other in seen:
			# The message HANDS BACK THE FIX rather than just naming the rule: a stacked pin
			# is almost always a pasted placeholder, and the author's next question is "so
			# what coordinate may I use?". suggest_map_pos re-derives a free one in the same
			# region from the live roster, so the answer cannot go stale the way a listed
			# coordinate in a comment would.
			assert_gt(pos.distance_to(other), min_separation,
				"rally %s pin is stacked on another pin (min separation %.3f). Use map_pos: %s — from RallyLibrary.suggest_map_pos(\"%s\")" % [
					rid, min_separation,
					RallyLibrary.suggest_map_pos(String(rally.get("region", ""))),
					String(rally.get("region", ""))])
		seen.append(pos)


# suggest_map_pos is the seam that makes a legal `map_pos` COMPUTABLE instead of prose, so
# what it returns must satisfy the very rules the guards above enforce — otherwise pasting
# its answer would swap one red test for another.
#
# Pins no coordinate and no region: it asks the helper for a pin for every region the
# CURRENT roster actually uses, and checks the structural properties. A designer may move
# any pin, add a region or retune map_reveal_radius and this still holds.
func test_suggest_map_pos_returns_a_legal_free_pin_for_every_authored_region() -> void:
	var regions: Array = []
	for rally in RallyLibrary.all():
		var r := String(rally.get("region", ""))
		if r != "" and not regions.has(r):
			regions.append(r)
	assert_gt(regions.size(), 0, "the roster authors at least one region (else this asserts nothing)")
	var min_separation: float = RallyLibrary.MIN_PIN_SEPARATION
	for region_id in regions:
		var pos: Vector2 = RallyLibrary.suggest_map_pos(region_id)
		assert_between(pos.x, 0.0, 1.0, "suggestion for '%s' is on the map in x" % region_id)
		assert_between(pos.y, 0.0, 1.0, "suggestion for '%s' is on the map in y" % region_id)
		var nearest := INF
		for rally in RallyLibrary.all():
			nearest = minf(nearest, pos.distance_to(RallyLibrary.map_pos_of(rally)))
		assert_gt(nearest, min_separation,
			"suggestion for '%s' clears every existing pin by more than the separation bound" % region_id)
		# Reachability: it must fall inside SOME authored rally's reveal circle, or a rally
		# pinned there would be stranded outside the explorable map.
		var reachable := false
		for rally in RallyLibrary.all():
			if pos.distance_to(RallyLibrary.map_pos_of(rally)) <= RallyLibrary.reveal_radius_of(rally):
				reachable = true
				break
		assert_true(reachable, "suggestion for '%s' is inside an existing rally's reveal circle" % region_id)
		# And the predicate form agrees with the generator — they are one rule.
		assert_true(RallyLibrary.map_pos_is_free(pos),
			"suggestion for '%s' passes map_pos_is_free" % region_id)


func test_map_pos_is_free_rejects_a_pin_on_top_of_an_authored_one() -> void:
	# The predicate's contract, not any particular coordinate: an existing pin's own
	# position is never free, and neither is the HQ centre (the illegal placeholder that
	# used to sit in the rally template).
	assert_gt(RallyLibrary.all().size(), 0, "RallyLibrary.all() is non-empty (else this asserts nothing)")
	var taken := RallyLibrary.map_pos_of(RallyLibrary.all()[0])
	assert_false(RallyLibrary.map_pos_is_free(taken), "an authored pin's own position is not free")
	assert_false(RallyLibrary.map_pos_is_free(RallyLibrary.HQ_MAP_POS), "the HQ centre is not free")
	assert_false(RallyLibrary.map_pos_is_free(Vector2(-0.5, 0.5)), "a position off the map is not free")


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
# RallyLibrary.reveal_depths(), which seeds its reachability waves from
# `prize_car_id(rally) != "" and CarLibrary.STARTER_MODEL_IDS.has(...)` -- with every
# `prize_car` field deleted (see the "Opening rally / prize tests DELETED" note above),
# reveal_depths() now returns {} against the shipped roster, so both would fail on a
# condition this task's required deletion causes, not a real regression in either
# invariant. Restoring them is the overworld-map wave's job once reveal_depths gets a
# non-prize seed.


# --- Progress / stars & the special ladder -----------------------------------------------------

func test_podium_count_tracks_profile() -> void:
	var profile := {"rallies": {
		"shakedown": {"completed": true},
		"coastal_sprint": {"completed": false},
	}}
	assert_eq(RallyLibrary.podium_count(profile), 1, "only podiumed rallies count")


# test_every_finish_scores_and_the_podium_scores_more and
# test_the_scoring_curve_is_flat_within_each_tier DELETED: both tested
# RallyLibrary.stars_for_placement / PODIUM_PLACES / MAX_STARS_PER_RALLY, all deleted with
# the star ledger (todo/roguelike-pivot.md decision 21).


# --- Map exploration: the geometric reveal gate ------------------------------
# Synthetic rosters only: reveal now depends on a rally's authored map_pos, which is
# exactly the kind of tunable content a designer nudges freely.

# The player's OPENING RALLY, one just inside its lit circle, and one far out in the dark
# that only the near rally's own circle can reach.
#
# The opening rally is the map's only starting light: HQ lights nothing (see
# RallyLibrary.lit_sources), so a profile with no starter recorded sees a wholly dark map.
# Radii are expressed as fractions of the configured radius rather than as literals.
const START_CAR := "fx_start_car"


func _install_geometric_reveal_roster() -> void:
	var r: float = Config.data.map_reveal_radius
	var hq: Vector2 = RallyLibrary.HQ_MAP_POS
	var roster: Array[Dictionary] = [
		# The opening rally: awards the starter, so it is lit from the start, completed or
		# not, and its circle is what the player explores out of.
		{"id": "r_start", "name": "Opening", "region": "home", "special": false,
			"difficulty": 1, "restriction": {}, "map_pos": hq, "prize_car": START_CAR,
			"reveal_radius": r, "events": []},
		# Inside the opening rally's circle, and lights a wide circle of its own that
		# reaches r_far.
		{"id": "r_near", "name": "Near", "region": "home", "special": false,
			"difficulty": 1, "restriction": {}, "map_pos": hq + Vector2(r * 0.5, 0.0),
			"reveal_radius": r * 2.0, "events": []},
		# Outside the opening rally's circle, but inside r_near's once that is completed.
		{"id": "r_far", "name": "Far", "region": "greece", "special": false,
			"difficulty": 2, "restriction": {}, "map_pos": hq + Vector2(r * 2.0, 0.0),
			"events": []},
		# Beyond every circle on the roster — nothing here can ever light it.
		{"id": "r_unreachable", "name": "Unreachable", "region": "greece", "special": false,
			"difficulty": 2, "restriction": {}, "map_pos": hq + Vector2(r * 20.0, 0.0),
			"events": []},
	]
	RallyLibrary.override_for_test(roster)


func test_a_rally_inside_the_opening_rallys_circle_is_revealed_from_the_start() -> void:
	_install_geometric_reveal_roster()
	var fresh := {"rallies": {}, "starter_model_id": START_CAR}
	assert_true(RallyLibrary.rally_revealed(RallyLibrary.by_id("r_start"), fresh),
		"the opening rally is lit before the player has driven anything")
	assert_true(RallyLibrary.rally_revealed(RallyLibrary.by_id("r_near"), fresh),
		"a pin inside the opening rally's circle is lit from the start")
	assert_false(RallyLibrary.rally_revealed(RallyLibrary.by_id("r_far"), fresh),
		"a pin outside it starts dark")


# COMPLETION AND THE STARTER ARE THE ONLY THINGS THAT REVEAL A RALLY. A profile that names no
# starter has no opening rally, so nothing it has done lights anything, and the map must not
# quietly re-light itself for them.
#
# This test used to read "HQ is no longer a light source ... therefore no light at all", because
# `map_hq_reveal_radius` shipped at 0.0. It no longer does: the overworld stands the player at the
# garage to pick their first car, and with HQ unlit the fog veil darkens the screen and the
# frontier push shoves the car while they choose. So HQ now lights a small circle — deliberately
# too small to touch any shipped pin, which `test_the_hq_circle_alone_reveals_no_rally` pins
# against the real roster.
#
# HQ is therefore neutralised HERE rather than asserted about, because this test is about the
# starter/completion rule and the fixture roster puts a pin at the middle: leaving the tunable
# live would make this fail on a fact it does not care about. Restored immediately, and before any
# assertion, so a failure cannot leak the override into another test.
func test_a_profile_with_no_starter_sees_a_wholly_dark_map() -> void:
	_install_geometric_reveal_roster()
	var was := Config.data.map_hq_reveal_radius
	Config.data.map_hq_reveal_radius = 0.0
	var no_starter := {"rallies": {}}
	var lit: Array[String] = []
	for rally in RallyLibrary.all():
		if RallyLibrary.rally_revealed(rally, no_starter):
			lit.append(String(rally.get("id", "?")))
	Config.data.map_hq_reveal_radius = was
	assert_eq(lit, [] as Array[String],
		"with no completion and no starter, nothing is revealed by progress alone")


func test_completing_a_rally_lights_the_map_around_that_rally() -> void:
	# The whole mechanic: progress is SPATIAL. Completing r_near lights a circle around
	# r_near's own pin, which is what reveals r_far — a rally that no amount of completing
	# anything else would have opened.
	_install_geometric_reveal_roster()
	var profile := {"rallies": {"r_start": {"completed": true}}, "starter_model_id": START_CAR}
	assert_false(RallyLibrary.rally_revealed(RallyLibrary.by_id("r_far"), profile),
		"completing a rally elsewhere does not light the far corner")
	profile["rallies"]["r_near"] = {"completed": true}
	assert_true(RallyLibrary.rally_revealed(RallyLibrary.by_id("r_far"), profile),
		"completing the neighbouring rally lights it")


func test_an_incomplete_rally_lights_nothing() -> void:
	# Only COMPLETED rallies light the map — merely reaching one must not open its
	# neighbours, or the frontier would run away from the player.
	_install_geometric_reveal_roster()
	var profile := {"rallies": {"r_near": {"completed": false, "best_placed": 0}},
		"starter_model_id": START_CAR}
	assert_false(RallyLibrary.rally_revealed(RallyLibrary.by_id("r_far"), profile),
		"an entered-but-unfinished rally lights nothing")


func test_a_rally_beyond_every_circle_stays_dark() -> void:
	# Guards the test above from passing vacuously: the predicate must be capable of
	# saying no even with the whole roster completed.
	_install_geometric_reveal_roster()
	# Every rally completed EXCEPT r_unreachable itself — a completed rally lights a circle
	# centred on its own pin, so marking it done would trivially reveal it.
	var profile := {"rallies": {}}
	for rally in RallyLibrary.all():
		if String(rally["id"]) == "r_unreachable":
			continue
		profile["rallies"][String(rally["id"])] = {"completed": true}
	assert_false(RallyLibrary.rally_revealed(RallyLibrary.by_id("r_unreachable"), profile),
		"a pin outside every circle is unreachable however much is completed")


# The map table draws its reveal graph (hq._build_reveal_links) only over ground the player
# has LIT. An edge running out into the fog would hand them the shape of a roster they have
# not explored yet — which is the one thing the dark is there to withhold.
func test_the_reveal_graph_links_only_pairs_that_are_both_revealed() -> void:
	_install_geometric_reveal_roster()
	var fresh := {"rallies": {}, "starter_model_id": START_CAR}
	assert_true(_graph_links(RallyLibrary.reveal_link_pairs(fresh), "r_start", "r_near"),
		"two revealed neighbours are linked")
	assert_false(_graph_links(RallyLibrary.reveal_link_pairs(fresh), "r_near", "r_far"),
		"a neighbour still in the fog is not, close enough to be lit by it or not")
	for pair in RallyLibrary.reveal_link_pairs(fresh):
		for rid in pair:
			assert_true(RallyLibrary.rally_revealed(RallyLibrary.by_id(String(rid)), fresh),
				"%s is out of the fog, so the edge it ends at may be drawn" % rid)
	# r_near and r_far ARE adjacent — completing r_near is what lights r_far — so the edge
	# appears the moment the fog leaves it. Without this the assertion above could pass
	# vacuously on a pair the graph would never have drawn at any distance.
	var explored := {"rallies": {"r_near": {"completed": true}},
		"starter_model_id": START_CAR}
	assert_true(_graph_links(RallyLibrary.reveal_link_pairs(explored), "r_near", "r_far"),
		"lighting the far pin draws the link that was there all along")


# Whether the reveal graph holds an edge between two rallies, in either order (the pairs are
# unordered — see RallyLibrary.reveal_link_pairs).
func _graph_links(pairs: Array, a: String, b: String) -> bool:
	for pair in pairs:
		if (pair[0] == a and pair[1] == b) or (pair[0] == b and pair[1] == a):
			return true
	return false


func test_distance_beyond_frontier_is_zero_once_revealed_and_shrinks_as_you_approach() -> void:
	_install_geometric_reveal_roster()
	var fresh := {"rallies": {}, "starter_model_id": START_CAR}
	assert_eq(RallyLibrary.distance_beyond_frontier(RallyLibrary.by_id("r_near"), fresh), 0.0,
		"a revealed rally is zero distance beyond the frontier")
	var far_before := RallyLibrary.distance_beyond_frontier(RallyLibrary.by_id("r_far"), fresh)
	assert_gt(far_before, 0.0, "a dark rally reports a positive gap")
	var profile := {"rallies": {"r_near": {"completed": true}}, "starter_model_id": START_CAR}
	assert_lt(RallyLibrary.distance_beyond_frontier(RallyLibrary.by_id("r_far"), profile),
		far_before, "lighting the map toward it closes the gap")


func test_spending_stars_cannot_close_a_reveal_gate() -> void:
	# Reveal must never read anything the player can SPEND, or buying something would take
	# back a rally they had already opened. Geometric reveal can't regress by construction,
	# and this pins that: drain the ledger to zero and every open rally stays open.
	var profile := {"rallies": {}}
	for rally in RallyLibrary.all():
		profile["rallies"][String(rally["id"])] = {"completed": true, "best_placed": 1}
	var open_before: Array = []
	for rally in RallyLibrary.all():
		if RallyLibrary.rally_revealed(rally, profile):
			open_before.append(String(rally["id"]))
	assert_gt(open_before.size(), 0, "some rallies are open to begin with")
	profile["stars_earned"] = 50
	profile["stars_spent"] = 50  # balance now zero
	for rid in open_before:
		assert_true(RallyLibrary.rally_revealed(RallyLibrary.by_id(rid), profile),
			"%s stays open after the balance is spent to zero" % rid)


func test_all_specials_completed_needs_every_rung() -> void:
	var profile := {"rallies": {}}
	assert_false(RallyLibrary.all_specials_completed(profile), "nothing won yet")
	var ids: Array = []
	for rally in RallyLibrary.all():
		if RallyLibrary.is_special(rally):
			ids.append(String(rally["id"]))
	for i in ids.size():
		profile["rallies"][ids[i]] = {"completed": true}
		var done: bool = RallyLibrary.all_specials_completed(profile)
		assert_eq(done, i == ids.size() - 1,
			"only the LAST special completed finishes the game")


func test_incomplete_enterable_query_respects_eligibility_and_reveal() -> void:
	# The query integrates is_eligible with the map-reveal gate. Runs on a SYNTHETIC roster
	# rather than the shipped one: what a given car can enter depends on authored
	# restrictions and authored pin positions, both of which a designer retunes freely.
	#
	# Three rallies, all incomplete: one lit and enterable, one lit but of a class the car
	# is not in, one enterable-but-DARK. A correct query returns exactly the first.
	var hq: Vector2 = RallyLibrary.HQ_MAP_POS
	var far: Vector2 = hq + Vector2(Config.data.map_reveal_radius * 5.0, 0.0)
	RallyLibrary.override_for_test([
		# The opening rally, so it is the roster's one starting light — nothing else is lit
		# until something is completed (HQ lights nothing).
		{"id": "q_open", "name": "Open", "region": "home", "special": false, "difficulty": 1,
			"prize_car": START_CAR,
			"map_pos": hq, "restriction": {"drive_mode": CarLibrary.AWD}, "events": []},
		{"id": "q_out_of_class", "name": "Out Of Class", "region": "home", "special": false,
			"difficulty": 1, "map_pos": hq,
			"restriction": {"drive_mode": CarLibrary.FWD}, "events": []},
		{"id": "q_dark", "name": "Dark", "region": "home", "special": false, "difficulty": 1,
			"map_pos": far, "restriction": {"drive_mode": CarLibrary.AWD}, "events": []},
	] as Array[Dictionary])
	var profile := {"rallies": {}, "starter_model_id": START_CAR}
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
		"only the rally that is BOTH lit and in-class is offered")


func test_a_completed_rally_is_never_offered_as_enterable() -> void:
	# The query is the anti-soft-lock "what can I still do" answer, so anything already
	# finished must drop out of it even though completing it left its pin lit.
	var hq: Vector2 = RallyLibrary.HQ_MAP_POS
	RallyLibrary.override_for_test([
		{"id": "q_done", "name": "Done", "region": "home", "special": false, "difficulty": 1,
			"map_pos": hq, "restriction": {}, "prize_car": START_CAR, "events": []},
	] as Array[Dictionary])
	var car := {"mass": 1500.0, "peak_torque": 400.0, "redline": 6500.0,
		"tire_compound": 1.0, "drive_mode": CarLibrary.AWD, "country": "DE",
		"engine": "fx_i4", "doors": 2}
	var fresh := {"rallies": {}, "starter_model_id": START_CAR}
	assert_eq(RallyLibrary.incomplete_rallies_enterable_by(car, fresh).size(), 1,
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


# THE CAPABILITY'S NAMED OWNER MUST RESOLVE. `ENGINE_SWAP_UNLOCK_RALLY` is an id authored on the
# library rather than a reference the roster carries, so a rally rename cannot break it loudly — and
# if it stops resolving, `engine_swaps_unlocked` can never become true and engine swapping is
# unreachable for the rest of the game. An anti-soft-lock check, not a content assertion: it names no
# rally itself, it only insists the constant points at one.
# Trimmed (todo/roguelike-pivot.md decisions 21 & 28): used to also assert the rally reads as
# awarding the engine-swap CAPABILITY (RallyLibrary.prize_capability_id /
# CAPABILITY_ENGINE_SWAP / has_prize) and that it is the only rally that does. Those three are
# all deleted with the prize-rally system; ENGINE_SWAP_UNLOCK_RALLY and the resolution check
# below are untouched — the constant still directly gates
# RallyLibrary.engine_swaps_unlocked, independent of the deleted prize machinery.
func test_the_engine_swap_unlock_rally_resolves() -> void:
	CarFixtures.restore()
	var owner := RallyLibrary.by_id(RallyLibrary.ENGINE_SWAP_UNLOCK_RALLY)
	assert_false(owner.is_empty(),
		"ENGINE_SWAP_UNLOCK_RALLY ('%s') is a real rally on the roster"
			% RallyLibrary.ENGINE_SWAP_UNLOCK_RALLY)


# HQ'S OWN CIRCLE MUST NOT REVEAL A RALLY. `map_hq_reveal_radius` ships non-zero so the garage
# forecourt is lit — the overworld stands the player there to pick their first car, and an unlit
# car gets the fog veil across the screen and the frontier push shoving it while they choose.
#
# But HQ's circle feeds the SAME `lit_sources` that gates entry, so too large a radius hands the
# player the pins nearest the middle for nothing. That is exactly why this shipped at 0.0 while
# the HQ table was the only hub, and it is the regression this test exists to prevent: the value
# is now a compromise between "the garage is lit" and "nothing is unlocked unearned", and the
# second half has no other guard.
#
# Pins the RELATIONSHIP, never the radius: raise the tunable past the nearest pin, or move a pin
# in under the circle, and this fails. Uses the shipped roster deliberately — it is the shipped
# pin layout that has to satisfy it (a catalogue-contract test, like the roster invariants above).
func test_the_hq_circle_alone_reveals_no_rally() -> void:
	var was := Config.data.map_hq_reveal_radius
	assert_gt(was, 0.0,
		"HQ lights something, else the overworld's starter pick happens in the dark")

	# A profile that has completed nothing and has no starter: HQ's circle is the ONLY source.
	var fresh: Dictionary = {Save.KEY_RALLIES: {}}
	var sources := RallyLibrary.lit_sources(fresh)
	assert_eq(sources.size(), 1,
		"a fresh profile with no starter is lit by HQ and nothing else")

	var revealed: Array[String] = []
	for rally in RallyLibrary.all():
		if RallyLibrary.rally_revealed(rally, fresh):
			revealed.append(String(rally.get("id", "")))
	assert_eq(revealed, [] as Array[String],
		"HQ's circle lights the garage but reveals NO rally — anything here is unlocked unearned")

	# And the complement, so the assertion above cannot pass by the circle being degenerate:
	# a big enough radius DOES reveal something, proving the test can see reveals at all.
	Config.data.map_hq_reveal_radius = 0.5
	var wide := 0
	for rally in RallyLibrary.all():
		if RallyLibrary.rally_revealed(rally, fresh):
			wide += 1
	Config.data.map_hq_reveal_radius = was
	assert_gt(wide, 0,
		"a deliberately huge HQ radius does reveal rallies — so the check above is not vacuous")


# test_the_garage_stands_beside_the_first_car_rally DELETED: it asserted the garage
# repositions beside the player's OPENING rally (RallyLibrary.opening_rally_id_for), which
# is now always "" against the shipped roster (see the "Opening rally / prize tests
# DELETED" note above) -- hq_map_pos always resolves to the centre fallback, so
# `assert_gt(moved, 0, ...)` would fail on every starter, not on a real positioning bug.
# test_the_garage_position_is_deterministic_for_a_profile below is unaffected (it only
# checks that the SAME profile yields the SAME position, whatever that position is).



# DETERMINISM. The position feeds the road network and the garage pad, both of which are folded
# into the chunk cache's invalidation key — so the same profile must always resolve to the same
# spot, or a relaunch silently re-bakes the whole map.
func test_the_garage_position_is_deterministic_for_a_profile() -> void:
	for model_id in CarLibrary.STARTER_MODEL_IDS:
		var profile: Dictionary = {Save.KEY_RALLIES: {}, "starter_model_id": model_id}
		assert_eq(RallyLibrary.hq_map_pos(profile), RallyLibrary.hq_map_pos(profile),
			"same profile, same garage — the cache key depends on it")


# ---------------------------------------------------------------------------------------
# The authoring templates carry a PASTEABLE map_pos literal. Keep it legal, and keep the
# two copies in step.
#
# Why this exists: readiness round 009 replaced the template's literal with "paste the
# result of RallyLibrary.suggest_map_pos(...)". That is correct advice and useless to an
# author who cannot run the project — round 010's probe authored no rally at all. So the
# literal is back as the default and the function is the escalation path. A baked literal
# rots, though: someone authors a pin next to it, or pastes it and makes it an authored pin
# itself. These two tests are what stop it rotting SILENTLY — they fail with the
# replacement value already computed.
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


func test_the_template_map_pos_is_still_a_legal_free_pin() -> void:
	var pin := _template_map_pos_from("res://scripts/region_library.gd")
	var replacement: Vector2 = RallyLibrary.suggest_map_pos("")
	for r in RallyLibrary.all():
		var authored: Vector2 = r.get("map_pos", Vector2.ZERO)
		assert_gt(pin.distance_to(authored), RallyLibrary.MIN_PIN_SEPARATION,
			("the template's pasteable map_pos %s is no longer free — rally '%s' now sits at "
			+ "%s. Replace the literal in BOTH scripts/region_library.gd's REGIONS template "
			+ "AND tests/headless/test_region_assets.gd's _unreachable_region_fix with %s "
			+ "(a currently-free pin). If it went stale because someone PASTED it, that is "
			+ "the expected lifecycle: rotate it to the new value.")
			% [pin, r.get("id", "?"), authored, replacement])


func test_both_authoring_templates_offer_the_same_map_pos() -> void:
	# Two copy-pasteable rows exist: the REGIONS header comment and the reachability guard's
	# failure message. Round 010 found them disagreeing (one updated, one not), which is how
	# an author ends up pasting a coordinate the other half of the codebase calls illegal.
	assert_eq(_template_map_pos_from("res://scripts/region_library.gd"),
		_template_map_pos_from("res://tests/headless/test_region_assets.gd"),
		"the REGIONS template and _unreachable_region_fix must hand back the SAME pin")
