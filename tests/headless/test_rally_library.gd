extends GutTest
# The rally roster (RallyLibrary): the authored rally list and the pure
# functions over it — eligibility, target times, the deterministic opponent
# field, progress/star gating, and the anti-soft-lock query. Mirrors
# test_car_library.gd. See todo/rally-roster.md.


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
	UpgradeFixtures.restore()


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


func test_a_region_may_hold_any_number_of_specials() -> void:
	# The old "at most one showdown per region, exactly one where rallies exist" invariant
	# is RETIRED. Specials are gated on the GLOBAL star total (special_gate_open), so they
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


func test_every_authored_star_gate_names_a_real_special() -> void:
	# The gates are plain id strings with no validation, so renaming or deleting a special
	# would silently make the gated part permanently unwinnable (rally_gate_met would just
	# return false forever, with no error). Pins no chosen id or threshold — it asserts the
	# CONTRACT that every authored gate resolves.
	for item in UpgradeLibrary.all():
		var gate := UpgradeLibrary.unlocked_by_rally(String(item["id"]))
		if gate == "":
			continue
		var rally := RallyLibrary.by_id(gate)
		assert_false(rally.is_empty(),
			"%s is gated on '%s', which must be a real rally" % [item["id"], gate])
		assert_true(RallyLibrary.is_special(rally),
			"%s is gated on '%s', which must be a SPECIAL event" % [item["id"], gate])
	# Each special gates at most ONE part: UpgradeLibrary.unlocked_by returns the first match,
	# so a second part on the same rally would be silently dropped from the map's teaser line.
	var seen_gates := {}
	for item in UpgradeLibrary.all():
		var g := UpgradeLibrary.unlocked_by_rally(String(item["id"]))
		if g == "":
			continue
		assert_false(seen_gates.has(g), "rally '%s' gates only one part" % g)
		seen_gates[g] = true
	var swap_rally := RallyLibrary.by_id(RallyLibrary.ENGINE_SWAP_UNLOCK_RALLY)
	assert_false(swap_rally.is_empty(), "the engine-swap capability names a real rally")
	assert_true(RallyLibrary.is_special(swap_rally),
		"the engine-swap capability is gated on a SPECIAL event")


func test_max_total_stars_counts_only_ordinary_rallies() -> void:
	# The meter's denominator and the ladder's reachability check both read this, so it must
	# exclude specials (which award none) — otherwise the top rung could look reachable when
	# it isn't.
	var ordinary := 0
	for rally in RallyLibrary.all():
		if not RallyLibrary.is_special(rally):
			ordinary += 1
	assert_eq(RallyLibrary.max_total_stars(), ordinary * RallyLibrary.MAX_STARS_PER_RALLY,
		"the ceiling is every ordinary rally won outright")


func test_every_specials_star_requirement_is_reachable() -> void:
	# A rung above the roster's maximum possible star total would be permanently locked.
	var max_stars := RallyLibrary.max_total_stars()
	for rally in RallyLibrary.all():
		if RallyLibrary.is_special(rally):
			assert_lte(int(rally.get("requires_stars", 0)), max_stars,
				"special %s demands a reachable star total" % rally.get("id", "?"))


func test_map_pins_are_well_formed_and_never_stack() -> void:
	# Well-formedness only — never specific coordinates, which are authored data a
	# designer nudges freely. A pin outside [0,1]^2 lands off the map plane, and two
	# pins on top of each other are unpickable, so both are structural bugs a corner
	# re-site can introduce silently.
	const MIN_SEPARATION := 0.03
	var seen: Array[Vector2] = []
	for rally in RallyLibrary.all():
		var pos: Vector2 = rally.get("map_pos", Vector2(-1, -1))
		var rid := String(rally.get("id", "?"))
		assert_between(pos.x, 0.0, 1.0, "rally %s map_pos.x is in [0, 1]" % rid)
		assert_between(pos.y, 0.0, 1.0, "rally %s map_pos.y is in [0, 1]" % rid)
		for other in seen:
			assert_gt(pos.distance_to(other), MIN_SEPARATION,
				"rally %s pin is not stacked on another pin" % rid)
		seen.append(pos)


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
	CarFixtures.restore()
	for rally in RallyLibrary.all():
		var found := ""
		for spec in CarLibrary.all():
			var meta := UpgradeLibrary.effective_meta({}, spec)
			var maxed := UpgradeLibrary.max_potential_meta({}, spec)
			# "Can enter" includes ducking under a pw_max ceiling by detuning, which the
			# player is always free to do (qualifying_detune returns 1.0 when already in).
			if RallyLibrary.is_eligible(rally, meta, maxed) or RallyLibrary.qualifying_detune(rally, meta) > 0.0:
				found = String(spec.get("id", ""))
				break
		assert_ne(found, "", "some car in the roster can enter rally '%s'" % rally.get("id", "?"))


func test_no_shipped_rally_has_an_over_wide_power_band() -> void:
	# SHIPPED-CONTENT guarantee, in the same spirit as the "every rally is enterable"
	# test above: a p/w band whose floor is less than HALF its ceiling lets wildly
	# mismatched cars into the same event, so the field stops being a class and the
	# rally loses its identity. This asserts the RATIO invariant only — never a
	# particular floor or ceiling, both of which a designer may retune freely, and
	# never which rallies carry a band at all (an open-class finale authors none).
	CarFixtures.restore()
	for rally in RallyLibrary.all():
		var restriction: Dictionary = rally.get("restriction", {})
		if not (restriction.has("pw_min") and restriction.has("pw_max")):
			continue  # ceiling-only / floor-only / open class: no band to be too wide
		var lo := float(restriction["pw_min"])
		var hi := float(restriction["pw_max"])
		assert_gte(lo, hi * 0.5,
			"rally '%s' p/w band %s-%s is too wide (floor must be >= half the ceiling)"
				% [rally.get("id", "?"), lo, hi])


func test_power_to_weight_restriction_filters() -> void:
	# The p/w gate is a BAND: pw_min..pw_max (both in hp/tonne; is_eligible converts each
	# car's kW/kg to hp/tonne before comparing). A car must sit INSIDE the band — under the
	# floor is ineligible, over the ceiling is capped out, in-band is eligible. Either edge
	# may be omitted (ceiling-only or floor-only). Use synthetic cars spanning low / mid /
	# high p/w and derive the band edges from those figures, so the test leans on the
	# eligibility LOGIC — never on authored catalogue values (which are free to change).
	# power_to_weight() reads peak_torque + redline straight off the entry, so no real
	# engine id is needed.
	var low := {"mass": 1200.0, "peak_torque": 200.0, "redline": 6000.0, "drive_mode": CarLibrary.RWD}
	var mid := {"mass": 1200.0, "peak_torque": 400.0, "redline": 6000.0, "drive_mode": CarLibrary.RWD}
	var high := {"mass": 1000.0, "peak_torque": 600.0, "redline": 8000.0, "drive_mode": CarLibrary.RWD}
	var pw_low := CarLibrary.power_to_weight(low) * RallyLibrary.KW_KG_TO_HP_TONNE
	var pw_mid := CarLibrary.power_to_weight(mid) * RallyLibrary.KW_KG_TO_HP_TONNE
	var pw_high := CarLibrary.power_to_weight(high) * RallyLibrary.KW_KG_TO_HP_TONNE
	# A band around the mid car: only the mid car sits inside it.
	var band := {"restriction": {"pw_min": (pw_low + pw_mid) * 0.5, "pw_max": (pw_mid + pw_high) * 0.5}}
	assert_true(RallyLibrary.is_eligible(band, mid), "the in-band car is eligible")
	assert_false(RallyLibrary.is_eligible(band, low), "the under-floor car is ineligible")
	assert_false(RallyLibrary.is_eligible(band, high), "the over-ceiling car is capped out")
	# Ceiling-only (no pw_min): no floor, so a weak car still clears it.
	var ceiling_only := {"restriction": {"pw_max": pw_high * 1.1}}
	assert_true(RallyLibrary.is_eligible(ceiling_only, low), "no pw_min: a weak car clears a ceiling-only gate")
	# Floor-only (no pw_max): no ceiling, so a strong car still clears it but a weak one fails.
	var floor_only := {"restriction": {"pw_min": (pw_low + pw_mid) * 0.5}}
	assert_true(RallyLibrary.is_eligible(floor_only, high), "no pw_max: a strong car clears a floor-only gate")
	assert_false(RallyLibrary.is_eligible(floor_only, low), "a car under the floor fails a floor-only gate")


func test_pw_gate_rounds_before_comparing_like_the_display_does() -> void:
	# Regression: the player-facing hp/tonne readouts (detune slider, close-button cap,
	# ineligibility message) all round to the nearest whole number via "%.0f"/roundi, so a
	# car whose RAW power-to-weight sits just a hair under a whole-number requirement can
	# still display as meeting it exactly (e.g. raw 99.6 shows "100 hp/t"). The eligibility
	# gate must compare the SAME rounded figure the player sees, not the raw float, or a car
	# that visually meets the requirement gets blocked anyway. Build a synthetic car whose
	# raw hp/tonne lands just under a whole number, then set the rally's pw_min to exactly
	# that rounded whole number.
	var car := {"mass": 1200.0, "peak_torque": 400.0, "redline": 6000.0, "drive_mode": CarLibrary.RWD}
	var raw_pw := CarLibrary.power_to_weight(car) * RallyLibrary.KW_KG_TO_HP_TONNE
	var rounded_pw := CarLibrary.power_to_weight_hp_tonne(car)
	assert_ne(raw_pw, float(rounded_pw), "the synthetic car's raw p/w must not already be a whole number")
	var rally := {"restriction": {"pw_min": float(rounded_pw)}}
	assert_true(RallyLibrary.is_eligible(rally, car),
		"a car whose displayed (rounded) p/w meets the floor must be eligible, even if the raw float sits a hair under it")


func test_pw_floor_is_judged_at_the_supplied_floor_meta() -> void:
	# The pw_min floor accepts a separate floor_meta so an owned car currently DETUNED or
	# ballasted below the floor is still eligible when its MAX potential clears it (the
	# player will tune up to enter — mirroring how an over-cap car detunes down to duck the
	# ceiling). Synthetic metas: a weak "current" meta and a strong "max potential" one.
	var weak := {"mass": 1200.0, "peak_torque": 150.0, "redline": 6000.0, "drive_mode": CarLibrary.RWD}
	var strong := {"mass": 1200.0, "peak_torque": 450.0, "redline": 6000.0, "drive_mode": CarLibrary.RWD}
	var pw_weak := CarLibrary.power_to_weight(weak) * RallyLibrary.KW_KG_TO_HP_TONNE
	var pw_strong := CarLibrary.power_to_weight(strong) * RallyLibrary.KW_KG_TO_HP_TONNE
	var rally := {"restriction": {"pw_min": (pw_weak + pw_strong) * 0.5}}
	# Point check (no floor_meta): the current-weak meta is under the floor -> ineligible.
	assert_false(RallyLibrary.is_eligible(rally, weak),
		"a point check judges the floor at the current (weak) meta -> ineligible")
	# With a max-potential floor_meta above the floor: eligible (the car can tune up to it).
	assert_true(RallyLibrary.is_eligible(rally, weak, strong),
		"eligible when the floor is judged at the car's max potential")
	# A car whose MAX potential is still under the floor stays ineligible.
	assert_false(RallyLibrary.is_eligible(rally, weak, weak),
		"still too weak even at max potential -> ineligible")


func test_installed_upgrades_change_rally_eligibility() -> void:
	# An upgrade shifts a car's effective power-to-weight, so fitting one can qualify
	# or disqualify it for a rally's pw band — the HQ passes the car's effective_meta
	# (baseline + installed upgrades) to is_eligible, not the raw roster entry. Use a
	# synthetic car and derive each band from the ACTUAL before/after p/w so the test
	# leans on the mechanism (upgrades flow through effective_meta into eligibility),
	# not on the MX-5's authored stats or a kit's tuned magnitude.
	UpgradeFixtures.install()
	var car := {"mass": 1100.0, "peak_torque": 200.0, "redline": 6500.0,
		"tire_compound": 1.0, "drive_mode": CarLibrary.RWD}
	var bare := UpgradeLibrary.effective_meta({"installed_upgrades": []}, car)
	var powered := UpgradeLibrary.effective_meta({"installed_upgrades": ["fx_turbo_big"]}, car)
	var maxed := UpgradeLibrary.effective_meta({"installed_upgrades": ["fx_turbo_big", "fx_lightweight"]}, car)
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
	RallyFixtures.install()
	var ev: Dictionary = RallyLibrary.by_id("fx_open")["events"][0]
	var a := await TrackGenerator.generate(_params(Vector2.ZERO, Vector2(0, 1), int(ev["seed"]),
		int(ev["turn_count"]), RallyLibrary.event_width(ev), 8.0))
	var b := await TrackGenerator.generate(_params(Vector2.ZERO, Vector2(0, 1), int(ev["seed"]),
		int(ev["turn_count"]), RallyLibrary.event_width(ev), 8.0))
	assert_almost_eq((a["centerline"] as Curve2D).get_baked_length(),
		(b["centerline"] as Curve2D).get_baked_length(), 0.001, "same seed -> same track length")
	assert_eq(a["pieces"].size(), b["pieces"].size(), "same seed -> same piece count")



func test_stage_key_changes_only_for_the_touched_event() -> void:
	# stage_key hashes the whole authored event dict, so a wet event gets its own
	# global leaderboard while an untouched sibling event keeps its board (see
	# features/weather.md -> "Caches and leaderboards"). Synthetic rally; no real
	# rally id or event is depended on.
	var dry_rally := {"id": "synthetic_stage_key", "events": [
		{"seed": 1, "turn_count": 8},
		{"seed": 2, "turn_count": 9},
	]}
	var wet_rally := {"id": "synthetic_stage_key", "events": [
		{"seed": 1, "turn_count": 8, "weather": "rain"},
		{"seed": 2, "turn_count": 9},
	]}
	assert_ne(RallyLibrary.stage_key(dry_rally, 0), RallyLibrary.stage_key(wet_rally, 0),
		"authoring weather onto event 0 changes its stage key")
	assert_eq(RallyLibrary.stage_key(dry_rally, 1), RallyLibrary.stage_key(wet_rally, 1),
		"an untouched sibling event keeps its stage key")


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
	RallyFixtures.install()
	var rally := RallyLibrary.by_id("fx_open")
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
	RallyFixtures.install()
	var rally := RallyLibrary.by_id("fx_open")
	var track := _track_with_pieces()
	var events: Array = (rally["events"] as Array).slice(0, 3)
	var a := RallyLibrary.generate_opponent_field(rally, [track, track, track], events)
	var b := RallyLibrary.generate_opponent_field(rally, [track, track, track], events)
	assert_eq(a, b, "same rally seed -> identical opponent field")


func test_opponent_names_are_drawn_from_the_pool_uniquely() -> void:
	# Every rival is named from the fixed pool, no two rivals in a field share a name,
	# and (since the field is generated once and reused across events) each rival's
	# name is inherently held across all 3 events. Determinism of the field is covered
	# by test_opponent_field_is_deterministic; here we assert the naming contract.
	RallyFixtures.install()
	var rally := RallyLibrary.by_id("fx_open")
	var track := _track_with_pieces()
	var events: Array = (rally["events"] as Array).slice(0, 3)
	var field := RallyLibrary.generate_opponent_field(rally, [track, track, track], events)
	assert_gt(field.size(), 0, "a field is fielded")
	var seen := {}
	for opp in field:
		var nm := String(opp.get("name", ""))
		assert_true(RallyLibrary.RIVAL_NAMES.has(nm), "%s is drawn from the name pool" % nm)
		assert_false(seen.has(nm), "no two rivals share the name %s" % nm)
		seen[nm] = true


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
		# Rivals now run engine swaps (features/rally-roster.md), so the displayed name
		# is the shared EngineSwap convention — layout-prefixed when the fitted engine isn't
		# the car's stock one, the plain name when it is. Asserted against display_name
		# rather than a literal so it can't drift from what the garage shows.
		assert_eq(String(opp.get("car_name", "")),
			EngineSwap.display_name(meta, {"swapped_engine": String(opp.get("engine_id", ""))}),
			"car name is the engine-aware display name for the fielded build")


func test_opponents_are_fielded_in_band() -> void:
	# Rivals are drawn only from the rally's eligible (in-band) pool — the band floor IS
	# the power floor now, so no rival can be underpowered. Build a band that admits only
	# part of the roster (floor below the weakest car, ceiling at the median so the strong
	# half is excluded — guaranteeing a non-empty pool AND a real exclusion, not the
	# admits-none fallback), then assert every fielded rival is eligible for the rally.
	# Synthetic roster (fixtures).
	var pws: Array = []
	for entry in CarLibrary.all():
		pws.append(CarLibrary.power_to_weight(UpgradeLibrary.effective_meta({}, entry)) * CarLibrary.KW_KG_TO_HP_TONNE)
	pws.sort()
	var median: float = pws[pws.size() / 2]
	var rally := {"id": "synthetic_band", "difficulty": 2,
		"restriction": {"pw_min": pws[0] - 1.0, "pw_max": median},
		"events": [{"seed": 1}, {"seed": 2}, {"seed": 3}]}
	var track := _track_with_pieces()
	var field := RallyLibrary.generate_opponent_field(rally, [track, track, track], rally["events"])
	assert_gt(field.size(), 0, "a field is fielded")
	for opp in field:
		# Judged on the build the rival ACTUALLY runs: an engine swap moves displacement,
		# mass and power-to-weight, so checking the stock meta would be checking a car that
		# isn't on the grid.
		var meta := UpgradeLibrary.effective_meta(
			{"swapped_engine": String(opp.get("engine_id", ""))},
			CarLibrary.by_id(String(opp.get("car_id", ""))))
		assert_true(RallyLibrary.is_eligible(rally, meta),
			"%s is fielded in-band (eligible for the rally)" % opp["name"])


# --- Opponent engine swaps (features/rally-roster.md) ------------------------

# Every rival runs a DISTINCT car+engine build. This is the whole point of the feature:
# the old draw picked each rival independently from the eligible pool (with replacement),
# so nine rivals routinely included several identical stock cars. Asserted as the
# no-duplicates invariant, with the degenerate case (pool smaller than the field) bounded
# rather than exempted — no build may appear more often than cycling the pool requires.
func test_every_rival_runs_a_distinct_car_and_engine_build() -> void:
	CarFixtures.install()
	# CarFixtures ships 2 engines, so its 4 cars only make 8 combos — one short of a
	# 9-rival field, which would leave the all-distinct case untested. Widen the engine
	# set with clones (same shape, distinct ids and torques) so the pool comfortably
	# exceeds the field. Still fully synthetic: no shipped catalogue entry is involved.
	var engines := CarFixtures.engines()
	for i in 3:
		var clone: Dictionary = engines[0].duplicate(true)
		clone["id"] = "fx_clone_%d" % i
		clone["name"] = "Fixture Clone %d" % i
		clone["peak_torque"] = float(clone["peak_torque"]) * (1.1 + 0.1 * float(i))
		engines.append(clone)
	EngineLibrary.override_for_test(engines)
	var rally := {"id": "synthetic_open", "difficulty": 2, "restriction": {},
		"events": [{"seed": 1}, {"seed": 2}, {"seed": 3}]}
	var track := _track_with_pieces()
	var field := RallyLibrary.generate_opponent_field(rally, [track, track, track], rally["events"])
	assert_gt(field.size(), 0, "a field is fielded")
	var pool_size: int = RallyLibrary._eligible_combos(rally).size()
	assert_gt(pool_size, 0, "the rally admits at least one build")
	var max_repeats: int = ceili(float(field.size()) / float(pool_size))
	var counts := {}
	for opp in field:
		var key := "%s|%s" % [String(opp.get("car_id", "")), String(opp.get("engine_id", ""))]
		counts[key] = int(counts.get(key, 0)) + 1
		assert_lte(int(counts[key]), max_repeats,
			"build %s appears at most ceil(field/pool) = %d times" % [key, max_repeats])
	if pool_size >= field.size():
		assert_eq(counts.size(), field.size(), "a pool this big gives every rival its own build")
	CarFixtures.restore()


# Every fielded build satisfies the rally's restriction once the fitted engine is resolved.
# This is the guard that stops a swap smuggling an over-powered build onto the grid: the
# restriction bounds power-to-weight, displacement and cylinder count, and effective_meta
# re-points the engine, so eligibility must hold for the SWAPPED meta, not the stock one.
func test_every_fielded_build_is_eligible_with_its_fitted_engine() -> void:
	CarFixtures.install()
	# A ceiling that admits only part of the combo pool, derived from the fixtures' own
	# spread so no authored number is pinned.
	var pws: Array = []
	for entry in CarLibrary.all():
		for eng in EngineLibrary.all():
			var meta := UpgradeLibrary.effective_meta({"swapped_engine": String(eng.get("id", ""))}, entry)
			pws.append(CarLibrary.power_to_weight_hp_tonne(meta))
	pws.sort()
	var rally := {"id": "synthetic_capped", "difficulty": 2,
		"restriction": {"pw_max": pws[pws.size() / 2]},
		"events": [{"seed": 1}, {"seed": 2}, {"seed": 3}]}
	var track := _track_with_pieces()
	var field := RallyLibrary.generate_opponent_field(rally, [track, track, track], rally["events"])
	assert_gt(field.size(), 0, "a field is fielded")
	for opp in field:
		var meta := UpgradeLibrary.effective_meta(
			{"swapped_engine": String(opp.get("engine_id", ""))},
			CarLibrary.by_id(String(opp.get("car_id", ""))))
		assert_true(RallyLibrary.is_eligible(rally, meta),
			"%s's fielded build satisfies the restriction" % opp["name"])
	CarFixtures.restore()


# The fitted engine actually reaches the lap-time model. Retuning ONE engine's torque must
# move rival times — asserted as a relationship between two rosters, so no specific time,
# torque or car is pinned. Without the swap being fed into optimum_ms this passes only by
# coincidence; with the engine ignored it fails outright.
func test_a_retuned_engine_changes_rival_times() -> void:
	var rally := {"id": "synthetic_open", "difficulty": 2, "restriction": {},
		"events": [{"seed": 1}, {"seed": 2}, {"seed": 3}]}
	var track := _track_with_pieces()

	CarFixtures.install()
	var before := RallyLibrary.generate_opponent_field(rally, [track, track, track], rally["events"])

	# Same roster, one engine given markedly more torque.
	var engines := CarFixtures.engines()
	engines[0]["peak_torque"] = float(engines[0]["peak_torque"]) * 2.0
	CarLibrary.override_for_test(CarFixtures.cars())
	EngineLibrary.override_for_test(engines)
	var after := RallyLibrary.generate_opponent_field(rally, [track, track, track], rally["events"])

	assert_eq(before.size(), after.size(), "the field size is unchanged by a retune")
	var moved := false
	for i in before.size():
		if before[i]["event_times_ms"] != after[i]["event_times_ms"]:
			moved = true
			break
	assert_true(moved, "retuning an engine's torque changes at least one rival's times")
	CarFixtures.restore()


# Modest swaps are favoured over wild ones. Two halves, because the bias has to be both
# CORRECT (the weight falls as the power delta grows) and CONNECTED (the draw actually
# uses it) — a right weight function wired to nothing would pass the first alone.
#
# Pure half: monotonic and strictly positive, asserted as a relationship so no authored
# spread value is pinned. Positivity matters — a zero weight would make an admitted combo
# unreachable, turning the bias into a filter.
func test_swap_weight_falls_as_the_power_delta_grows() -> void:
	var last := INF
	for step in 6:
		var d := float(step) * RallyLibrary.OPPONENT_SWAP_PW_SPREAD * 0.5
		var w := RallyLibrary.swap_weight(d)
		assert_gt(w, 0.0, "every admitted combo stays reachable (delta %.1f)" % d)
		assert_lt(w, last + 0.0000001, "weight does not rise as the delta grows (delta %.1f)" % d)
		last = w
	assert_eq(RallyLibrary.swap_weight(0.0), RallyLibrary.swap_weight(-0.0),
		"the weight depends on the MAGNITUDE, so a power drop is treated like a rise")
	assert_gt(RallyLibrary.swap_weight(0.0),
		RallyLibrary.swap_weight(RallyLibrary.OPPONENT_SWAP_PW_SPREAD * 4.0),
		"a stock-power build is favoured over a wildly different one")


# Connected half: over many seeded draws, the builds actually fielded sit closer to stock
# power than the pool's own average. Compares the draw against its OWN input, so it holds
# for any roster and any spread — and it fails outright if the draw ignores the weights.
func test_the_draw_prefers_modest_swaps_over_wild_ones() -> void:
	# A synthetic pool: deltas spread evenly, so an unbiased draw would average the middle.
	var pool: Array = []
	for i in 12:
		pool.append({"car": {}, "engine_id": "e%d" % i, "meta": {},
			"pw_delta": float(i) * RallyLibrary.OPPONENT_SWAP_PW_SPREAD * 0.5})
	var pool_mean := 0.0
	for c in pool:
		pool_mean += float(c["pw_delta"])
	pool_mean /= float(pool.size())

	# Draw ONE build many times over different seeds and average what came out.
	var drawn_mean := 0.0
	var trials := 300
	for seed_i in trials:
		var rng := RandomNumberGenerator.new()
		rng.seed = seed_i
		drawn_mean += float(RallyLibrary._draw_distinct_combos(rng, pool, 1)[0]["pw_delta"])
	drawn_mean /= float(trials)

	assert_lt(drawn_mean, pool_mean,
		"drawn builds average closer to stock power (%.1f) than the pool does (%.1f)"
			% [drawn_mean, pool_mean])


# No hop may drop a rival identity key. This is the guardrail for the class of bug that put
# rivals on their cars' stock engines: `engine_id` reached the opponent field but not the
# start-line leader rows, and nothing failed — the grid just silently staged the wrong build.
#
# Driven off RIVAL_IDENTITY_KEYS rather than a hand-written list, so adding a per-rival
# attribute makes THIS test fail until every hop carries it. That is the point: the omission
# becomes loud instead of silent.
func test_no_hop_drops_a_rival_identity_key() -> void:
	CarFixtures.install()
	var track := _track_with_pieces()
	var rally := {"id": "synth_identity", "difficulty": 2, "restriction": {},
		"events": [{"seed": 7}, {"seed": 7}, {"seed": 7}]}
	var field := RallyLibrary.generate_opponent_field(rally, [track, track, track], rally["events"])
	assert_gt(field.size(), 0, "a field is fielded")

	# Hop 1: the generator's own entries.
	for opp in field:
		for key in RallyLibrary.RIVAL_IDENTITY_KEYS:
			assert_true(opp.has(key), "a generated rival carries %s" % key)

	# Hop 2: the standings rows the podium fields cars from.
	for row in RallyLibrary.build_standings(field, 1000, false):
		if bool(row.get("is_player", false)):
			continue
		for key in RallyLibrary.RIVAL_IDENTITY_KEYS:
			assert_true(row.has(key), "a standings row carries %s" % key)

	# Hop 3: the wreck record the run scene stages from. Force a wreck rather than hoping
	# the seeded roll produced one, so the assertion can't go vacuous.
	var wrecked := field.duplicate(true)
	wrecked[0]["wreck_event"] = 0
	var wreck := RallyLibrary.event_wreck(wrecked, 0)
	assert_false(wreck.is_empty(), "the forced wreck is found")
	for key in RallyLibrary.RIVAL_IDENTITY_KEYS:
		assert_true(wreck.has(key), "the wreck record carries %s" % key)
	CarFixtures.restore()


# EVERY value in a generated rival entry must survive a JSON round-trip unchanged. The
# opponent cache's entire contract is that a cached field equals a freshly generated one
# (data/opponent_cache.json is committed and consulted instead of re-simulating), and JSON
# is the transport — so a value that doesn't round-trip means cache and live silently
# disagree. Floats are the only risk: `wreck_progress` used to be a raw double, which
# prints to ~14 significant digits and parses back to a DIFFERENT double.
#
# Asserted over the whole entry rather than on wreck_progress alone, so any FUTURE float
# added to a rival is covered without anyone remembering to extend this test.
func test_every_rival_value_survives_a_json_round_trip() -> void:
	CarFixtures.install()
	var track := _track_with_pieces()
	var rally := {"id": "synth_json", "difficulty": 2, "restriction": {},
		"events": [{"seed": 7}, {"seed": 7}, {"seed": 7}]}
	var field := RallyLibrary.generate_opponent_field(rally, [track, track, track], rally["events"])
	assert_gt(field.size(), 0, "a field is fielded")
	var raw: Variant = JSON.parse_string(JSON.stringify(field, "", true, true))
	assert_not_null(raw, "the field serialises to valid JSON")
	for i in field.size():
		for key in field[i]:
			var before = field[i][key]
			var after = raw[i].get(key)
			if before is float:
				# Compared EXACTLY, not with a tolerance: the point is bit-identical
				# transport, and a tolerance would hide the very drift this guards.
				assert_eq(float(after), float(before),
					"rival %d's %s round-trips exactly" % [i, key])
			elif before is int:
				assert_eq(int(after), int(before), "rival %d's %s round-trips" % [i, key])
			elif before is String:
				assert_eq(String(after), String(before), "rival %d's %s round-trips" % [i, key])
	CarFixtures.restore()


# A restriction narrow enough to admit fewer builds than the field still fields a full
# grid, spread as evenly as the pool allows (the cycle-to-top-up rule) rather than
# collapsing to random repeats or fielding a short grid.
func test_a_narrow_pool_still_fields_a_full_grid() -> void:
	CarFixtures.install()
	var pool := [{"car": CarLibrary.all()[0], "engine_id": "a", "meta": {}},
		{"car": CarLibrary.all()[0], "engine_id": "b", "meta": {}}]
	var rng := RandomNumberGenerator.new()
	rng.seed = 12345
	var drawn := RallyLibrary._draw_distinct_combos(rng, pool, 9)
	assert_eq(drawn.size(), 9, "the grid is filled even from a two-build pool")
	var counts := {}
	for c in drawn:
		var k := String(c["engine_id"])
		counts[k] = int(counts.get(k, 0)) + 1
	assert_eq(counts.size(), 2, "both available builds are used")
	for k in counts:
		assert_between(int(counts[k]), 4, 5, "cycling spreads repeats evenly (%s)" % k)
	CarFixtures.restore()


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
	RallyFixtures.install()
	var rally := RallyLibrary.by_id("fx_open")
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
	# well beyond the ±noise window. The expected spread is DERIVED from the pace band
	# the generator actually uses for this rally's difficulty (slow end / fast end);
	# DNF attrition and per-event noise trim the surviving extremes, so we only require
	# a fraction of the full band spread rather than the band ratio itself.
	var band: Vector2 = RallyLibrary._pace_band(int(rally.get("difficulty", 1)))
	var band_ratio := band.y / band.x
	assert_gt(float(mean_paces[mean_paces.size() - 1]) / float(mean_paces[0]),
		1.0 + 0.3 * (band_ratio - 1.0),
		"field spans a ranked ladder, not a mid-pack cluster")


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


# --- Progress / stars & the special ladder -----------------------------------------------------

func test_completed_count_tracks_profile() -> void:
	var profile := {"rallies": {
		"shakedown": {"completed": true},
		"coastal_sprint": {"completed": false},
	}}
	assert_eq(RallyLibrary.completed_count(profile), 1, "only completed rallies count")


func test_total_stars_scores_best_placement_and_ignores_specials() -> void:
	# 1st = 3 stars, 2nd = 2, 3rd = 1, anything else 0 — and a special's own result never
	# counts, so a special can't help unlock the next rung.
	var ordinary := ""
	var special := ""
	for rally in RallyLibrary.all():
		if RallyLibrary.is_special(rally) and special == "":
			special = String(rally["id"])
		elif not RallyLibrary.is_special(rally) and ordinary == "":
			ordinary = String(rally["id"])
	var profile := {"rallies": {ordinary: {"completed": true, "best_placed": 1}}}
	assert_eq(RallyLibrary.total_stars(profile), RallyLibrary.MAX_STARS_PER_RALLY,
		"a 1st place is worth the full star count")
	profile["rallies"][ordinary] = {"completed": true, "best_placed": 3}
	assert_eq(RallyLibrary.total_stars(profile), 1, "a 3rd place is worth one star")
	profile["rallies"][ordinary] = {"completed": true, "best_placed": 7}
	assert_eq(RallyLibrary.total_stars(profile), 0, "finishing off the podium scores nothing")
	profile["rallies"][special] = {"completed": true, "best_placed": 1}
	assert_eq(RallyLibrary.total_stars(profile), 0, "a special's own result awards no stars")


func test_a_special_gate_opens_on_the_star_total() -> void:
	# Logic only: the gate compares the star total against the authored requirement, so it
	# is closed below and open at/above it. No specific threshold is pinned.
	var special := {}
	for rally in RallyLibrary.all():
		if RallyLibrary.is_special(rally):
			special = rally
			break
	var need := int(special.get("requires_stars", 0))
	assert_false(RallyLibrary.special_gate_open(special, _profile_with_stars(need - 1)),
		"closed one star short")
	assert_true(RallyLibrary.special_gate_open(special, _profile_with_stars(need)),
		"open once the requirement is met")
	assert_eq(RallyLibrary.stars_needed(special, _profile_with_stars(need)), 0,
		"nothing left to earn once it is open")
	assert_gt(RallyLibrary.stars_needed(special, _profile_with_stars(0)), 0,
		"an unmet gate reports how many stars are still needed")


func test_an_ordinary_rally_ignores_the_star_gate() -> void:
	for rally in RallyLibrary.all():
		if not RallyLibrary.is_special(rally):
			assert_true(RallyLibrary.special_gate_open(rally, {"rallies": {}}),
				"an ordinary rally is never star-gated")
			assert_eq(RallyLibrary.stars_needed(rally, {"rallies": {}}), 0,
				"and needs no stars")
			return


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


# A profile carrying exactly `stars` stars, built by 3-starring ordinary rallies (and
# topping up with a lesser placement when the target isn't a multiple of 3).
func _profile_with_stars(stars: int) -> Dictionary:
	var profile := {"rallies": {}}
	var left := maxi(stars, 0)
	for rally in RallyLibrary.all():
		if RallyLibrary.is_special(rally) or left <= 0:
			continue
		var take: int = mini(left, RallyLibrary.MAX_STARS_PER_RALLY)
		profile["rallies"][String(rally["id"])] = {
			"completed": true, "best_placed": RallyLibrary.MAX_STARS_PER_RALLY + 1 - take}
		left -= take
	return profile


# --- reveal_after (the GLOBAL wave gate) -------------------------------------

# A minimal two-corner roster: one wave-0 rally in each region plus a gated rally in
# "greece" that needs 2 completions. Synthetic, so no authored reveal_after is pinned.
func _install_two_region_reveal_roster() -> void:
	var roster: Array[Dictionary] = [
		{"id": "r_home_a", "name": "Home A", "region": "home", "special": false,
			"difficulty": 1, "restriction": {}, "reveal_after": 0, "events": []},
		{"id": "r_home_b", "name": "Home B", "region": "home", "special": false,
			"difficulty": 1, "restriction": {}, "reveal_after": 0, "events": []},
		{"id": "r_greece_gated", "name": "Greece Gated", "region": "greece", "special": false,
			"difficulty": 2, "restriction": {}, "reveal_after": 2, "events": []},
	]
	RallyLibrary.override_for_test(roster)


func test_reveal_count_is_global_so_other_regions_count_toward_the_gate() -> void:
	# The world map pins every corner at once, so reveal_after counts completed
	# ordinary rallies ACROSS THE WHOLE ROSTER — a win in one corner opens a rally in
	# another. (after_each restores RallyLibrary.)
	_install_two_region_reveal_roster()
	var gated := RallyLibrary.by_id("r_greece_gated")
	var profile := {"rallies": {}}
	assert_false(RallyLibrary.rally_revealed(gated, profile), "hidden with nothing completed")
	profile["rallies"]["r_home_a"] = {"completed": true}
	assert_false(RallyLibrary.rally_revealed(gated, profile), "one completion is short of the gate")
	# Both completions are in a DIFFERENT region than the gated rally — they still count.
	profile["rallies"]["r_home_b"] = {"completed": true}
	assert_true(RallyLibrary.rally_revealed(gated, profile),
		"completions in another region count toward the gate")


func test_a_completed_special_does_not_count_toward_the_reveal_gate() -> void:
	# A special is gated separately, on stars — it must not also pay into the wave count.
	var roster: Array[Dictionary] = [
		{"id": "r_gated", "name": "Gated", "region": "home", "special": false,
			"difficulty": 2, "restriction": {}, "reveal_after": 1, "events": []},
		{"id": "r_special", "name": "Special", "region": "home", "special": true,
			"requires_stars": 0, "difficulty": 4, "restriction": {}, "events": []},
	]
	RallyLibrary.override_for_test(roster)
	var profile := {"rallies": {"r_special": {"completed": true}}}
	assert_false(RallyLibrary.rally_revealed(RallyLibrary.by_id("r_gated"), profile),
		"a completed special doesn't advance the wave count")


func test_a_wave_zero_rally_is_revealed_from_the_start() -> void:
	_install_two_region_reveal_roster()
	assert_true(RallyLibrary.rally_revealed(RallyLibrary.by_id("r_home_a"), {"rallies": {}}),
		"reveal_after 0 is visible immediately")


func test_incomplete_enterable_query_respects_eligibility_and_lock() -> void:
	# The query integrates is_eligible + the star gate over the real roster. Assert the
	# invariants that hold for ANY roster rather than pinning specific authored rallies:
	# every returned rally is eligible for the car, none are already complete, and a
	# star-locked special never appears. A synthetic AWD car with
	# a mid p/w keeps the input off the catalogue.
	var profile := {"rallies": {}}
	# The car carries an ENGINE (a before_each fixture, not a shipped entry) and a
	# door count, because engine-derived restrictions (displacement / cylinders) and
	# doors_* resolve through those fields and REJECT a car that can't supply them.
	# Without them this car qualifies for nothing, the loop below never runs, and the
	# test silently asserts nothing while still reporting green.
	var car := {"mass": 1500.0, "peak_torque": 400.0, "redline": 6500.0,
		"tire_compound": 1.0, "drive_mode": CarLibrary.AWD, "country": "DE",
		"engine": "fx_i4", "doors": 2}
	var enterable := RallyLibrary.incomplete_rallies_enterable_by(car, profile)
	# Guards the above: an empty result would make every assertion below vacuous.
	assert_gt(enterable.size(), 0, "a mid-range car with a fresh profile can enter something")
	for r in enterable:
		# "Enterable" means eligible OUTRIGHT or reachable by ducking under the ceiling
		# with a detune — the same definition the HQ's _entry_plan and the shipped-roster
		# test above use, so all three agree on what the player can actually start.
		assert_true(
			RallyLibrary.is_eligible(r, car) or RallyLibrary.qualifying_detune(r, car) > 0.0,
			"%s is enterable by the car (outright or detuned)" % r["id"])
		# A fresh profile has zero stars, so every special whose rung is above zero is
		# still locked and must not be offered.
		if RallyLibrary.is_special(r):
			assert_eq(int(r.get("requires_stars", 0)), 0,
				"a star-locked special is not offered: %s" % r["id"])


# --- stage_key (global leaderboards) -----------------------------------------
# Synthetic RallyDefs only, per project rules: a designer retuning a shipped
# rally must not be able to break this test.

func _synthetic_rally(event: Dictionary) -> Dictionary:
	return {"id": "synthetic_rally", "events": [event, event, event]}


func test_stage_key_is_deterministic() -> void:
	var rally := _synthetic_rally({"seed": 1, "turn_count": 10, "straightness": 0.5})
	var a := RallyLibrary.stage_key(rally, 1)
	var b := RallyLibrary.stage_key(rally, 1)
	assert_eq(a, b, "same rally + event_index always yields the same key")


func test_stage_key_changes_with_turn_count() -> void:
	var rally_a := _synthetic_rally({"seed": 1, "turn_count": 10, "straightness": 0.5})
	var rally_b := _synthetic_rally({"seed": 1, "turn_count": 11, "straightness": 0.5})
	assert_ne(RallyLibrary.stage_key(rally_a, 0), RallyLibrary.stage_key(rally_b, 0),
		"a changed turn_count changes the key")


func test_stage_key_changes_with_straightness() -> void:
	# straightness is authored per-event and changes the generated track shape, so
	# the key must react to it too, not just seed/turn_count/width (the wrong
	# formulation this test guards against).
	var rally_a := _synthetic_rally({"seed": 1, "turn_count": 10, "straightness": 0.2})
	var rally_b := _synthetic_rally({"seed": 1, "turn_count": 10, "straightness": 0.8})
	assert_ne(RallyLibrary.stage_key(rally_a, 0), RallyLibrary.stage_key(rally_b, 0),
		"a changed straightness changes the key")


func test_stage_key_differs_by_event_index() -> void:
	# Same rally, different events within it (a designer's per-event data, not the
	# same event repeated) must produce distinct keys.
	var rally := {"id": "synthetic_rally", "events": [
		{"seed": 1, "turn_count": 10},
		{"seed": 2, "turn_count": 12},
	]}
	assert_ne(RallyLibrary.stage_key(rally, 0), RallyLibrary.stage_key(rally, 1),
		"different events in the same rally get different keys")


func test_stage_key_includes_board_epoch_suffix() -> void:
	# BOARD_EPOCH is a const (bumped by hand alongside CACHE_VERSION), so a test
	# cannot bump it at runtime to prove "changing it changes the key" without
	# reaching into engine internals. Instead assert the key is actually suffixed
	# with TrackCache.BOARD_EPOCH's current value, confirming stage_key reads it
	# (rather than a hardcoded literal) — the suffix format is what a bumped epoch
	# would change.
	var rally := _synthetic_rally({"seed": 1, "turn_count": 10})
	var key := RallyLibrary.stage_key(rally, 0)
	assert_true(key.ends_with("__e%d" % TrackCache.BOARD_EPOCH),
		"the key is suffixed with the current BOARD_EPOCH")


func test_stage_key_is_document_id_safe() -> void:
	var rally := _synthetic_rally({"seed": 1, "turn_count": 10, "straightness": 0.5})
	var key := RallyLibrary.stage_key(rally, 2)
	assert_false(key.contains("/"), "no '/' in a Firestore document id")
	assert_lt(key.length(), 1500, "well under Firestore's 1500-byte id limit")


