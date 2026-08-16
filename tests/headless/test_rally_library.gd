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


# THE shipped-content invariant of map exploration: every rally must be REACHABLE by
# exploring outward from HQ. A pin stranded beyond every circle is content the player can
# never see, and it fails silently — the rally simply never appears — so it needs a guard.
#
# Pins no number: it re-derives the closure from whatever is authored, so a designer may
# move any pin freely as long as the map stays connected.
func test_every_shipped_rally_is_reachable_by_exploring_from_hq() -> void:
	var depth := RallyLibrary.reveal_depths()
	assert_gt(RallyLibrary.all().size(), 0, "RallyLibrary.all() is non-empty (else this asserts nothing)")
	var stranded: Array = []
	for rally in RallyLibrary.all():
		if not depth.has(String(rally["id"])):
			stranded.append(String(rally["id"]))
	assert_eq(stranded, [], "no rally is stranded outside every reveal circle")


# THE playability guarantee, restated for the opening-rally flow (todo/opening-rally.md):
# whichever starter the player picks, they are dropped straight into THAT CAR'S OWN rally,
# so that rally must exist, must be lit, and must admit the car it awards.
#
# The last clause is the one that can really break. A prize rally's restriction band is
# authored for the field it fields, and nothing else forces it to admit the very car it
# hands over — so a band drifting off its own prize would strand every player who picked
# that starter on turn one, with no rally to drive and no way to earn a different car.
# Nothing else in the suite notices: the map stays connected and every rally stays
# reachable in principle.
#
# Pins no rally, no car and no band: it walks the real starter list through the real
# lookup and the real eligibility rule, so re-siting a pin or retuning a band re-derives
# the answer rather than breaking an assertion.
func test_every_starter_car_opens_in_a_rally_that_admits_it() -> void:
	# A SHIPPED-CONTENT contract, so it needs the shipped catalogue: before_each installs
	# the synthetic car fixtures, under which the real starter models do not exist.
	# after_each re-installs them for the next test.
	CarFixtures.restore()
	var starters: Array = CarLibrary.STARTER_MODEL_IDS
	assert_gt(starters.size(), 0, "the starter picker offers something")
	for model_id in starters:
		var entry := CarLibrary.by_id(String(model_id))
		assert_false(entry.is_empty(), "starter %s is a real catalogue car" % model_id)
		var opening_id := RallyLibrary.opening_rally_id_for(String(model_id))
		assert_ne(opening_id, "", "starter %s has an opening rally" % model_id)
		var opening := RallyLibrary.by_id(opening_id)
		assert_false(opening.is_empty(), "starter %s's opening rally is a real rally" % model_id)
		assert_eq(RallyLibrary.prize_car_id(opening), String(model_id),
			"starter %s's opening rally is the one that awards it" % model_id)
		# The profile a player has the instant they confirm the picker: the choice recorded,
		# nothing completed.
		var fresh := {"rallies": {}, "starter_model_id": String(model_id)}
		assert_true(RallyLibrary.rally_revealed(opening, fresh),
			"starter %s's opening rally is lit from the start" % model_id)
		# A stock, freshly-granted car: no upgrades, no tuning — exactly what the picker hands over.
		var car := {"model_id": String(model_id), "instance_id": 1,
			"installed_upgrades": [], "disabled_upgrades": [], "tuning": {}}
		var meta := UpgradeLibrary.effective_meta(car, entry)
		# Entry is purely CATEGORICAL, so the stock car either fits the class or it doesn't —
		# there is no tuning-up or detuning allowance left to model.
		assert_true(RallyLibrary.is_eligible(opening, meta),
			"starter %s can enter its own opening rally" % model_id)


# No two starters share an opening rally. They are derived from `prize_car`, so a roster
# pointing two starters at one event would silently give one of them no start of its own —
# and the flow would drop both players into the same rally, which is the specific thing
# the opening is meant to differentiate (it decides where on the map the career begins).
func test_each_starter_has_its_own_opening_rally() -> void:
	CarFixtures.restore()
	var seen: Dictionary = {}
	for model_id in CarLibrary.STARTER_MODEL_IDS:
		var opening_id := RallyLibrary.opening_rally_id_for(String(model_id))
		assert_false(seen.has(opening_id),
			"opening rally %s is not shared with starter %s" % [opening_id, seen.get(opening_id, "")])
		seen[opening_id] = String(model_id)


# A model no rally awards has no opening rally, and neither does the empty id. The
# lookup's miss is a normal answer (the flow falls back to the garage), not an error, so
# it has to be a stable one.
func test_opening_rally_lookup_misses_cleanly() -> void:
	assert_eq(RallyLibrary.opening_rally_id_for(""), "", "no starter model, no opening rally")
	assert_eq(RallyLibrary.opening_rally_id_for("not_a_real_car_id"), "",
		"a model no rally awards has no opening rally")


# --- Prizes ------------------------------------------------------------------

func test_a_rallys_car_prize_is_a_real_catalogue_car() -> void:
	# Contract over the shipped roster: a prize naming a car that does not exist would hand
	# the player nothing, silently. Never asserts WHICH car any rally awards — that is
	# tunable content a designer re-pairs freely.
	CarFixtures.restore()
	for rally in RallyLibrary.all():
		var car_id := RallyLibrary.prize_car_id(rally)
		if car_id == "":
			continue
		assert_false(CarLibrary.by_id(car_id).is_empty(),
			"%s awards a real car (%s)" % [rally.get("id", "?"), car_id])


# A prize rally must ADMIT THE CAR IT AWARDS, and that car must be the fastest thing the
# band admits — so it turns up in the field as the one to beat, and beating it is what
# wins it. This is the whole advertisement now that the field is drawn normally: the grid
# used to be a one-make row of the prize car, which said it plainly but threw away the
# variety the combo pool exists for (RallyLibrary._eligible_cars).
#
# Both halves are easy to break silently by retuning a band, and neither shows up in
# play as an error — the field just quietly fills with cars that are not the prize, or
# out-guns it so the player beats a car they were not shown. Several shipped rallies
# HAD drifted this way (the 911's and the XJS's bands started above their own cars, the
# Acty's demanded a hatch when the Acty is a kei), hidden for as long as the one-make
# grid bypassed the restriction entirely.
#
# Pins no band and no car: it reads each rally's own prize and asks the real eligibility
# rule about it, so a designer moving a ceiling re-derives the answer. What it will not
# let them do is move a ceiling BELOW the prize, which is the design rule itself.
func test_a_rally_admits_the_car_it_awards() -> void:
	CarFixtures.restore()
	var checked := 0
	for rally in RallyLibrary.all():
		var car_id := RallyLibrary.prize_car_id(rally)
		if car_id == "":
			continue
		var prize := CarLibrary.by_id(car_id)
		if prize.is_empty():
			continue  # covered by test_a_rallys_car_prize_is_a_real_catalogue_car
		checked += 1
		var prize_meta := UpgradeLibrary.effective_meta({}, prize)
		assert_true(RallyLibrary.is_eligible(rally, prize_meta),
			"%s admits the %s it awards" % [rally.get("id", "?"), car_id])
	assert_gt(checked, 0, "some rally awards a car (else this asserts nothing)")


func test_no_two_rallies_award_the_same_car() -> void:
	# A car won twice is a wasted prize rally: the second win hands over a duplicate of
	# something the player already has, and one catalogue car is then unreachable.
	var seen := {}
	for rally in RallyLibrary.all():
		var car_id := RallyLibrary.prize_car_id(rally)
		if car_id == "":
			continue
		assert_false(seen.has(car_id),
			"%s is awarded by only one rally (also on %s)" % [car_id, seen.get(car_id, "")])
		seen[car_id] = String(rally.get("id", "?"))


# EVERY car has to be winnable, starters included. The picker hands over ONE of the three
# starters, so without a rally for the other two, most of the starter roster is content no
# player can ever own — cars are not bought or drawn any more, so a rally is the only route.
#
# Winning the starter you already picked costs nothing and mints nothing: rally_session
# guards on Save.owns_model, so that finish simply pays stars like any other.
#
# Derived from the catalogue, so adding a car fails this until it is given an event.
func test_every_car_is_winnable_somewhere() -> void:
	CarFixtures.restore()
	var awarded := {}
	for rally in RallyLibrary.all():
		var car_id := RallyLibrary.prize_car_id(rally)
		if car_id != "":
			awarded[car_id] = true
	var orphans: Array = []
	for spec in CarLibrary.all():
		if not awarded.has(String(spec.get("id", ""))):
			orphans.append(String(spec.get("id", "")))
	assert_eq(orphans, [], "every car in the catalogue is won at some rally")


func test_a_part_prize_is_derived_from_the_upgrade_catalogue() -> void:
	# The part half of a prize is NOT authored on the rally — it comes from the upgrade's
	# own unlocked_by_rally gate, so the two can never name different parts. Synthetic
	# catalogue: this is the wiring, not the shipped pairing.
	UpgradeFixtures.restore()
	for item in UpgradeLibrary.all():
		var gate := UpgradeLibrary.unlocked_by_rally(String(item["id"]))
		if gate == "":
			continue
		var rally := RallyLibrary.by_id(gate)
		if rally.is_empty():
			continue
		assert_eq(RallyLibrary.prize_part_id(rally), String(item["id"]),
			"%s's prize is the part its own gate names" % gate)
		assert_true(RallyLibrary.has_prize(rally), "%s counts as a prize rally" % gate)


func test_a_car_unlock_rally_draws_its_field_like_any_other() -> void:
	# A car-unlock rally used to field a ONE-MAKE grid — every rival in the car on offer,
	# with the rally's own restriction ignored for the field. That advertised the prize
	# plainly but made the grid a row of identical cars, so it is gone: the prize is
	# advertised through the BAND instead (its ceiling sits just above its own car — see
	# test_a_car_prize_tops_the_band_of_the_rally_that_awards_it), and the field is drawn
	# from everything the restriction admits, exactly like an ordinary rally.
	#
	# Synthetic prize car and an open restriction — this is the wiring, not the shipped
	# pairing.
	var prize_id := String(CarFixtures.cars()[1]["id"])
	var rally := {
		"id": "fx_prize", "name": "Prize", "region": "home", "special": false,
		"difficulty": 1, "prize_car": prize_id, "restriction": {}, "events": [],
	}
	assert_gt(RallyLibrary._eligible_cars(rally).size(), 1,
		"a prize rally's field is drawn from every car the restriction admits")
	assert_gt(RallyLibrary._eligible_combos(rally).size(), 1,
		"and keeps its engine-swap variety")


# The restriction now GOVERNS the field on a prize rally too — it no longer has a special
# exemption. A band admitting nothing but one car is what makes a one-make grid, and that
# is a property of the band, not of carrying a prize.
func test_a_prize_rallys_restriction_governs_its_field() -> void:
	var prize_id := String(CarFixtures.cars()[1]["id"])
	var rally := {
		"id": "fx_prize_narrow", "name": "Prize Narrow", "region": "home", "special": false,
		"difficulty": 1, "prize_car": prize_id,
		# A class no catalogue car satisfies. Previously the prize short-circuit returned the
		# prize car regardless; now the ordinary empty-pool fallback answers.
		"restriction": {"country": "__nowhere__"}, "events": [],
	}
	var pool := RallyLibrary._eligible_cars(rally)
	assert_eq(pool.size(), CarLibrary.all().size(),
		"a restriction admitting nothing degrades to the whole roster, prize or not")


func test_a_rally_without_a_car_prize_still_draws_a_mixed_field() -> void:
	# The one-make path must not leak into ordinary rallies, whose whole point is a varied
	# grid drawn from everything the restriction admits.
	var rally := {
		"id": "fx_mixed", "name": "Mixed", "region": "home", "special": false,
		"difficulty": 1, "restriction": {}, "events": [],
	}
	assert_gt(RallyLibrary._eligible_cars(rally).size(), 1,
		"an open-class rally admits more than one car")
	assert_gt(RallyLibrary._eligible_combos(rally).size(), 1,
		"and more than one car+engine combo")


func test_a_rally_with_no_prize_reports_none() -> void:
	# The common case: an ordinary rally pays stars and lights the map, nothing more.
	var plain := {"id": "no_prize_here", "name": "Plain", "region": "home", "special": false,
		"restriction": {}, "events": []}
	assert_eq(RallyLibrary.prize_car_id(plain), "", "no car")
	assert_eq(RallyLibrary.prize_part_id(plain), "", "no part")
	assert_false(RallyLibrary.has_prize(plain), "and so no prize")


# The opening beat, for EVERY starter: the rally they begin in must light SOMETHING (else
# finishing it leaves them on a dark map with nowhere to go and the game cannot continue)
# but not the whole map (else there is nothing left to explore). Both ends matter; neither
# pins how many.
#
# Walked per starter because the starting light is now per starter — the player's own
# opening rally, not a shared circle around HQ, which lights nothing at all.
func test_every_starters_opening_rally_leads_somewhere_but_not_everywhere() -> void:
	CarFixtures.restore()
	for model_id in CarLibrary.STARTER_MODEL_IDS:
		var opening_id := RallyLibrary.opening_rally_id_for(String(model_id))
		# The profile the moment their opening rally is done — the state they first see the
		# map in.
		var started := {"rallies": {opening_id: {"completed": true}},
			"starter_model_id": String(model_id)}
		var open_now := 0
		for rally in RallyLibrary.all():
			if RallyLibrary.rally_revealed(rally, started):
				open_now += 1
		# Its own pin is always lit, so "somewhere to go" means MORE than one.
		assert_gt(open_now, 1,
			"%s has somewhere to drive after its opening rally" % model_id)
		assert_lt(open_now, RallyLibrary.all().size(),
			"and the map is not fully lit from the start" % [])


func test_map_pins_are_well_formed_and_never_stack() -> void:
	# Well-formedness only — never specific coordinates, which are authored data a
	# designer nudges freely. A pin outside [0,1]^2 lands off the map plane, and two
	# pins on top of each other are unpickable, so both are structural bugs a corner
	# re-site can introduce silently.
	assert_gt(RallyLibrary.all().size(), 0, "RallyLibrary.all() is non-empty (else this test asserts nothing)")
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
				# Fastest a rival can go: the tier's fast end minus the ±noise, clamped so
				# they never beat the physics optimum, measured against the rival's OWN car
				# (each entry names the build it runs).
				var band := RallyLibrary._pace_band(int(rally.get("difficulty", 1)))
				var min_factor: float = maxf(band.x * (1.0 - RallyLibrary.PACE_EVENT_NOISE), RallyLibrary.PACE_MIN_FLOOR)
				# The rival's OWN build — car, fitted engine AND build level. A built
				# rival's optimum is lower than its stock car's, so measuring the band
				# against the stock meta would read a legitimate time as impossible.
				var own_meta := _rival_meta(opp)
				var floor_ms := int(LapTimeModel.optimum_ms(event_results[i], own_meta, events[i]) * min_factor)
				assert_gte(t, floor_ms - 1, "event time >= its own car's floor * fastest possible pace")
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
		# A BUILD is car + engine + fitted parts: rivals now also carry a build level
		# (RallyLibrary._build_levels), so two rivals in the same car and engine at
		# different build levels are different builds, not a duplicate.
		var key := "%s|%s|%s" % [String(opp.get("car_id", "")), String(opp.get("engine_id", "")),
			",".join(PackedStringArray(opp.get("upgrades", [])))]
		counts[key] = int(counts.get(key, 0)) + 1
		assert_lte(int(counts[key]), max_repeats,
			"build %s appears at most ceil(field/pool) = %d times" % [key, max_repeats])
	if pool_size >= field.size():
		assert_eq(counts.size(), field.size(), "a pool this big gives every rival its own build")
	CarFixtures.restore()


# Every fielded build satisfies the rally's restriction once the fitted engine is resolved.
# This is the guard that stops a swap smuggling an out-of-class build onto the grid: the
# restriction bounds displacement and cylinder count, and effective_meta re-points the
# engine, so eligibility must hold for the SWAPPED meta, not the stock one.
func test_every_fielded_build_is_eligible_with_its_fitted_engine() -> void:
	CarFixtures.install()
	# A CATEGORICAL restriction that admits only part of the combo pool. Cylinder count is
	# engine-derived, so it is exactly the case that only holds if the SWAPPED engine is
	# resolved — the stock meta would answer differently for half the pool. Derived from
	# the fixtures' own engine spread rather than pinning an authored number: the cap sits
	# below the widest fixture engine.
	var cyls: Array = []
	for eng in EngineLibrary.all():
		cyls.append(EngineLibrary.cylinders(eng))
	cyls.sort()
	var rally := {"id": "synthetic_capped", "difficulty": 2,
		"restriction": {"cylinders_max": int(cyls[0])},
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


# A gated part's PREREQUISITE must be reachable no later than the part that needs it:
# reveal is geometric now, so "opens first" means "is reached in an earlier wave". A
# prerequisite further out than its dependent is a chain the player can meet out of order.
#
# Reads reveal_depths (the reachability ORDER), not distance from HQ — the two disagree,
# because reveal spreads along a corridor of pins rather than as one circle.
#
# A NECESSARY condition, not a sufficient one: real reachability also depends on which cars
# the player holds by then, which the career reachability solver covers. Nothing here pins
# a wave number; it only compares two authored pins against each other.
func test_a_gated_parts_prerequisite_is_reached_no_later_than_the_part_itself() -> void:
	var reach := RallyLibrary.reveal_depths()

	var checked := 0
	for item in UpgradeLibrary.all():
		var item_id := String(item["id"])
		var gate := UpgradeLibrary.unlocked_by_rally(item_id)
		var prereq := UpgradeLibrary.requires_upgrade_id(item_id)
		if gate == "" or prereq == "":
			continue
		var prereq_gate := UpgradeLibrary.unlocked_by_rally(prereq)
		if prereq_gate == "":
			continue  # the prerequisite is ungated, so it is always available first
		assert_true(reach.has(gate) and reach.has(prereq_gate),
			"both gates are rallies the map can actually reach (%s / %s)" % [gate, prereq_gate])
		assert_lte(int(reach[prereq_gate]), int(reach[gate]),
			"%s's prerequisite %s is reached no later than it is" % [item_id, prereq])
		checked += 1
	assert_gt(checked, 0, "the roster actually has a gated chain to check")


func test_engine_swapping_is_the_first_special_the_map_reaches() -> void:
	# Design intent, not a tuned number: engine swapping is what makes the garage
	# interesting, so its special must be the first one exploration reaches. Compares
	# authored pins against each other through reveal_depths; no wave number is pinned.
	var depth := RallyLibrary.reveal_depths()
	var swap_depth := -1
	var earliest := 1 << 30
	for rally in RallyLibrary.all():
		if not RallyLibrary.is_special(rally):
			continue
		var rid := String(rally["id"])
		assert_true(depth.has(rid), "special %s is reachable at all" % rid)
		earliest = mini(earliest, int(depth[rid]))
		if rid == RallyLibrary.ENGINE_SWAP_UNLOCK_RALLY:
			swap_depth = int(depth[rid])
	assert_ne(swap_depth, -1, "the engine-swap rally is a real special")
	assert_eq(swap_depth, earliest,
		"engine swapping is on the first special the map reaches — it opens first")


# EVERY value in a generated rival entry must survive a JSON round-trip unchanged: a
# field is persisted with the run's standings, and JSON is the transport — so a value
# that doesn't round-trip means the reloaded field silently disagrees with the one that
# was raced. Floats are the only risk: `wreck_progress` used to be a raw double, which
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
	assert_gt(RallyLibrary.RALLIES.size(), 0, "RallyLibrary.RALLIES is non-empty (else this test asserts nothing)")
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
		# Skip a rival whose BUILD LEVEL fits forced induction: an installed turbo /
		# supercharger REPLACES the stock engine's boost (UpgradeLibrary.effective_meta),
		# so for that rival the two rosters are the same car and the times must match. The
		# stock-boost claim is only about rivals not carrying an induction part.
		if _fits_induction(boosted[i]):
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


func test_every_finish_scores_and_the_podium_scores_more() -> void:
	# The ONE definition of what a placement is worth. Stars themselves are a persisted
	# ledger on the profile now (Save.stars_earned — see test_save_manager.gd); this only
	# guards the scoring curve, which the ledger and the HQ star row both read.
	#
	# Three tiers: what must hold for any tuning of the three amounts is that finishing pays
	# something, the podium pays more, the win pays most, and not finishing pays nothing.
	var win: int = RallyLibrary.stars_for_placement(1)
	var podium: int = RallyLibrary.stars_for_placement(2)
	var also_ran: int = RallyLibrary.stars_for_placement(RallyLibrary.PODIUM_PLACES + 1)
	assert_gt(also_ran, 0, "merely finishing is worth something")
	assert_gt(podium, also_ran, "a podium finish is worth more than finishing")
	assert_gt(win, podium, "winning outright is worth more than the rest of the podium")
	assert_eq(win, RallyLibrary.MAX_STARS_PER_RALLY,
		"the win pays the most a rally can pay — the denominator the star rows draw")
	assert_eq(RallyLibrary.stars_for_placement(0), 0, "never placed scores nothing")
	assert_eq(RallyLibrary.stars_for_placement(-1), 0, "nor does a negative placement")


func test_the_scoring_curve_is_flat_within_each_tier() -> void:
	# The win is its own tier; below it the curve is flat. Every non-winning podium place pays
	# the same as every other, and so does every finish behind the podium — there is no 2nd/3rd
	# gradient and no decay with how far down the field a finish lands.
	for placed in range(2, RallyLibrary.PODIUM_PLACES + 1):
		assert_eq(RallyLibrary.stars_for_placement(placed),
			RallyLibrary.stars_for_placement(2),
			"podium place %d pays the same as 2nd" % placed)
	for placed in [RallyLibrary.PODIUM_PLACES + 1, RallyLibrary.PODIUM_PLACES + 5, 50]:
		assert_eq(RallyLibrary.stars_for_placement(placed),
			RallyLibrary.stars_for_placement(RallyLibrary.PODIUM_PLACES + 1),
			"placing %d pays the same as any other non-podium finish" % placed)


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


# HQ is no longer a light source, so a profile that names no starter has no opening rally
# and therefore no light at all. This is the state every pre-opening-rally save is in, and
# the map must not quietly re-light itself around the middle for them.
func test_a_profile_with_no_starter_sees_a_wholly_dark_map() -> void:
	_install_geometric_reveal_roster()
	var no_starter := {"rallies": {}}
	for rally in RallyLibrary.all():
		assert_false(RallyLibrary.rally_revealed(rally, no_starter),
			"%s is dark when nothing has been completed and no starter is recorded"
				% rally.get("id", "?"))


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




# --- Rating-matched rival draw ----------------------------------------------
# The power band that used to gate ENTRY now shapes the FIELD instead: rivals are drawn
# weighted toward the player's CarPerformance rating (rating_match_weight), so bringing a
# quick car means racing quick cars. Both tests below are relational — they compare two
# draws against each other, never a rating value, a spread, or a catalogue entry.

# A widened synthetic engine set, so the combo pool spans a real spread of ratings and
# "matched toward the fast end" is distinguishable from "matched toward the slow end".
# Fully synthetic: no shipped catalogue entry is involved.
func _install_spread_roster() -> void:
	CarFixtures.install()
	var engines := CarFixtures.engines()
	for i in 4:
		var clone: Dictionary = engines[0].duplicate(true)
		clone["id"] = "fx_spread_%d" % i
		clone["name"] = "Fixture Spread %d" % i
		clone["peak_torque"] = float(clone["peak_torque"]) * (1.0 + 0.6 * float(i + 1))
		engines.append(clone)
	EngineLibrary.override_for_test(engines)
	CarPerformance.reset()


# The rating the field itself claims for each rival — the number the draw matched on.
# Re-deriving it from car_id + engine_id would miss the rival's BUILD LEVEL and read a
# fully-built rival as a stock one.
func _mean_field_rating(field: Array) -> float:
	var total := 0.0
	for opp in field:
		total += float(int(opp.get("rating", 0)))
	return total / float(field.size())


func test_the_field_is_drawn_toward_the_players_rating() -> void:
	_install_spread_roster()
	var rally := {"id": "synthetic_matched", "difficulty": 2, "restriction": {},
		"events": [{"seed": 1}, {"seed": 2}, {"seed": 3}]}
	var track := _track_with_pieces()
	# The pool's own extremes, so the two targets are real ratings the draw can reach
	# rather than invented numbers.
	var ratings: Array = []
	for combo in RallyLibrary._eligible_combos(rally):
		ratings.append(int(combo["rating"]))
	ratings.sort()
	assert_gt(int(ratings[-1]), int(ratings[0]),
		"the synthetic pool spans a spread of ratings (else this test asserts nothing)")
	var slow := RallyLibrary.generate_opponent_field(
		rally, [track, track, track], rally["events"], int(ratings[0]))
	var fast := RallyLibrary.generate_opponent_field(
		rally, [track, track, track], rally["events"], int(ratings[-1]))
	assert_gt(fast.size(), 0, "a field is fielded")
	assert_lt(_mean_field_rating(slow), _mean_field_rating(fast),
		"a slow player draws a slower grid than a fast player does, from the same rally")
	CarFixtures.restore()
	EngineLibrary.reset()
	CarPerformance.reset()


func test_a_zero_player_rating_leaves_the_draw_unmatched() -> void:
	# 0 is the "no rating supplied" sentinel — every caller that doesn't know the player's
	# car (a test, a tool, a free-roam handoff) passes it, and the draw must then behave
	# EXACTLY as it did before matching existed: weighted by swap plausibility alone.
	# Asserted as identity against the defaulted call, so the sentinel can never quietly
	# become "match against a rating of zero" (which would bias every such field slow).
	_install_spread_roster()
	var rally := {"id": "synthetic_unmatched", "difficulty": 2, "restriction": {},
		"events": [{"seed": 4}, {"seed": 5}, {"seed": 6}]}
	var track := _track_with_pieces()
	var defaulted := RallyLibrary.generate_opponent_field(rally, [track, track, track], rally["events"])
	var zeroed := RallyLibrary.generate_opponent_field(rally, [track, track, track], rally["events"], 0)
	assert_gt(defaulted.size(), 0, "a field is fielded")
	assert_eq(zeroed, defaulted, "player_rating = 0 draws exactly the unmatched field")
	# And matching really is doing something on this pool — otherwise the assertion above
	# would pass even if the sentinel were ignored entirely.
	var ratings: Array = []
	for combo in RallyLibrary._eligible_combos(rally):
		ratings.append(int(combo["rating"]))
	ratings.sort()
	var matched := RallyLibrary.generate_opponent_field(
		rally, [track, track, track], rally["events"], int(ratings[0]))
	assert_ne(matched, defaulted, "a supplied rating changes the draw (else the sentinel is vacuous)")
	CarFixtures.restore()
	EngineLibrary.reset()
	CarPerformance.reset()


# SHIPPED-CONTENT guard, in the same spirit as "every rally is enterable": now that entry
# is purely categorical, a roster that authored no restrictions at all would still pass
# every eligibility test while quietly deleting the game's classes — every rally would
# admit every car and the map would stop asking the player to own anything in particular.
# Asserts existence only: never how many carry a restriction, never which, never what it
# says. Specials are exempt by design (a showdown is open to whatever you have brought).
func test_the_career_roster_is_not_entirely_open_class() -> void:
	CarFixtures.restore()
	RallyFixtures.restore()
	var career := 0
	var restricted := 0
	for rally in RallyLibrary.all():
		if RallyLibrary.is_special(rally):
			continue
		career += 1
		if not (rally.get("restriction", {}) as Dictionary).is_empty():
			restricted += 1
	assert_gt(career, 0, "the roster has non-special rallies (else this test asserts nothing)")
	assert_gt(restricted, 0, "some non-special rally restricts entry to a class of car")


# --- Rival build levels (features/rally-roster.md, adaptive difficulty §5) ----

# Every build level is a build a car could actually carry: at most one part per slot, no
# consumables, and no nitrous (CarPerformance excludes nitrous from the rating, so a rival
# running it would be quicker than the rating the field was matched on claims). Asserted
# over the FIXTURE catalogue — the rule is about the shape of a level, not about which
# parts the shipped game happens to author.
func test_build_levels_are_valid_builds() -> void:
	UpgradeFixtures.install()
	var levels: Array = RallyLibrary._build_levels()
	assert_gt(levels.size(), 1, "there is more than the stock level (else this asserts nothing)")
	var seen: Array = []
	for level in levels:
		assert_false(seen.has(level), "build level %s appears once" % [level])
		seen.append(level)
		var slots := {}
		for item_id in level:
			var item := UpgradeLibrary.by_id(String(item_id))
			assert_false(item.is_empty(), "%s is a real catalogue part" % item_id)
			assert_false(bool(item.get("consumable", false)), "%s is not a consumable" % item_id)
			var slot := String(item.get("slot", ""))
			assert_ne(slot, "", "%s occupies a slot" % item_id)
			assert_ne(slot, "nitrous", "%s is not a nitrous part" % item_id)
			assert_false(slots.has(slot), "level fits at most one part in slot %s" % slot)
			slots[slot] = item_id
	assert_true(levels.has([]), "the stock build is still one of the levels")
	UpgradeFixtures.restore()


# The point of build levels: they raise the top of what the pool can field ABOVE the
# best stock car+engine pairing, which is where a dominating player sits and where the
# difficulty lever previously had no room. Asserted as pool-against-pool, so no rating
# value, part or catalogue entry is pinned.
func test_build_levels_raise_the_pools_top_rating() -> void:
	_install_spread_roster()
	UpgradeFixtures.install()
	var rally := {"id": "synthetic_levels", "difficulty": 2, "restriction": {}, "events": []}
	var stock_top := 0
	var pool_top := 0
	var pool_floor := 1 << 30
	for combo in RallyLibrary._eligible_combos(rally):
		var r := int(combo["rating"])
		pool_top = maxi(pool_top, r)
		pool_floor = mini(pool_floor, r)
		if (combo.get("upgrades", []) as Array).is_empty():
			stock_top = maxi(stock_top, r)
	assert_gt(stock_top, 0, "the pool holds stock combos (else this test asserts nothing)")
	assert_gt(pool_top, stock_top, "a built rival out-rates the best stock car+engine pairing")
	assert_lt(pool_floor, stock_top, "the pool still reaches below the stock ceiling")
	UpgradeFixtures.restore()
	CarFixtures.restore()
	EngineLibrary.reset()
	CarPerformance.reset()


# The difficulty lever end to end: the SAME rally drawn against a harder target fields
# better machinery than against an easier one. Relationship-only — the two means are
# compared against each other, never against a number.
func test_a_harder_target_draws_a_faster_field_than_an_easier_one() -> void:
	_install_spread_roster()
	UpgradeFixtures.install()
	var rally := {"id": "synthetic_adapt", "difficulty": 2, "restriction": {},
		"events": [{"seed": 11}, {"seed": 12}, {"seed": 13}]}
	var track := _track_with_pieces()
	var ratings: Array = []
	for combo in RallyLibrary._eligible_combos(rally):
		ratings.append(int(combo["rating"]))
	ratings.sort()
	var mid: int = int(ratings[ratings.size() / 2])
	# Targets INSIDE the pool's range at both ends, so this measures the draw and not the
	# residual trim (which only engages outside the range).
	var easier := RallyLibrary.generate_opponent_field(
		rally, [track, track, track], rally["events"], int(ratings[0]))
	var harder := RallyLibrary.generate_opponent_field(
		rally, [track, track, track], rally["events"], int(ratings[-1]))
	assert_gt(int(ratings[-1]), mid, "the pool spans a spread (else this test asserts nothing)")
	assert_lt(_mean_field_rating(easier), _mean_field_rating(harder),
		"an easier target fields worse machinery than a harder one")
	UpgradeFixtures.restore()
	CarFixtures.restore()
	EngineLibrary.reset()
	CarPerformance.reset()


# The residual (adaptive difficulty §6): when the target is beyond anything the pool can
# field, the shortfall is taken up by pace, so the field is still harder than one drawn at
# the pool's own ceiling. Without the trim the two fields would post identical times — the
# draw has nothing better left to pick.
func test_the_residual_trim_covers_a_target_the_pool_cannot_reach() -> void:
	_install_spread_roster()
	var rally := {"id": "synthetic_residual", "difficulty": 2, "restriction": {},
		"events": [{"seed": 21}, {"seed": 22}, {"seed": 23}]}
	var track := _track_with_pieces()
	var pool: Array = RallyLibrary._eligible_combos(rally)
	var top := 0
	var bottom := 1 << 30
	for combo in pool:
		top = maxi(top, int(combo["rating"]))
		bottom = mini(bottom, int(combo["rating"]))
	assert_eq(RallyLibrary._residual_pace_trim(pool, top), 1.0,
		"a target the pool can reach needs no trim")
	assert_lt(RallyLibrary._residual_pace_trim(pool, top * 2), 1.0,
		"a target above the pool's ceiling trims rival times down")
	assert_gt(RallyLibrary._residual_pace_trim(pool, maxi(bottom / 2, 1)), 1.0,
		"a target below the pool's floor trims rival times up")
	var at_ceiling := RallyLibrary.generate_opponent_field(
		rally, [track, track, track], rally["events"], top)
	var beyond := RallyLibrary.generate_opponent_field(
		rally, [track, track, track], rally["events"], int(round(top * 1.2)))
	assert_gt(at_ceiling.size(), 0, "a field is fielded")
	var compared_rivals := 0
	for i in at_ceiling.size():
		if bool(at_ceiling[i]["dnf"]):
			continue   # a DNF has no time to compare
		assert_lt(int(beyond[i]["combined_ms"]), int(at_ceiling[i]["combined_ms"]),
			"rival %d is quicker once the shortfall is taken up by pace" % i)
		compared_rivals += 1
	assert_gt(compared_rivals, 0, "at least one classified rival was compared")
	CarFixtures.restore()
	EngineLibrary.reset()
	CarPerformance.reset()


# The trim's hard bound: however absurd the target, no rival's time may go under what
# RivalPace can solve for that rival's own car, or the windscreen ghost stops being able
# to show the standings. Checked against each rival's OWN optimum, computed from the build
# the field says they ran.
func test_the_residual_trim_never_outruns_the_ghost() -> void:
	_install_spread_roster()
	var rally := {"id": "synthetic_absurd", "difficulty": 2, "restriction": {},
		"events": [{"seed": 31}, {"seed": 32}, {"seed": 33}]}
	var track := _track_with_pieces()
	var top := 0
	for combo in RallyLibrary._eligible_combos(rally):
		top = maxi(top, int(combo["rating"]))
	var field := RallyLibrary.generate_opponent_field(
		rally, [track, track, track], rally["events"], top * 50)
	assert_gt(field.size(), 0, "a field is fielded")
	for opp in field:
		var optimum := LapTimeModel.optimum_ms(track, _rival_meta(opp), {})
		assert_gt(optimum, 0, "the rival's car has a solvable optimum")
		for t in opp["event_times_ms"]:
			if int(t) < 0:
				continue   # crashed out: no time this event
			# +1 ms of slack: the drawn time is an int round of the scaled float.
			assert_gte(int(t) + 1, int(RallyLibrary.GHOST_SOLVABLE_PACE * float(optimum)),
				"%s never runs quicker than the ghost can be solved for" % opp["name"])
	CarFixtures.restore()
	EngineLibrary.reset()
	CarPerformance.reset()


# THE NO-OP PROPERTY. A target inside the pool's range — which every unadapted, matched
# field is — must leave the pace path exactly as it was before the residual trim existed:
# no trim applied, and every rival still inside the authored pace band above its own
# optimum. Expressed against the band CONSTANTS rather than a measured time, so retuning
# the band cannot break it.
func test_a_reachable_target_leaves_rival_pace_untouched() -> void:
	_install_spread_roster()
	var rally := {"id": "synthetic_noop", "difficulty": 2, "restriction": {},
		"events": [{"seed": 41}, {"seed": 42}, {"seed": 43}]}
	var track := _track_with_pieces()
	var pool: Array = RallyLibrary._eligible_combos(rally)
	var ratings: Array = []
	for combo in pool:
		ratings.append(int(combo["rating"]))
	ratings.sort()
	for r in [int(ratings[0]), int(ratings[ratings.size() / 2]), int(ratings[-1])]:
		assert_eq(RallyLibrary._residual_pace_trim(pool, r), 1.0,
			"a target of %d, which the pool holds, applies no trim" % r)
	var fastest_possible := RallyLibrary.PACE_FAST_BASE * (1.0 - RallyLibrary.PACE_EVENT_NOISE)
	var field := RallyLibrary.generate_opponent_field(
		rally, [track, track, track], rally["events"], int(ratings[ratings.size() / 2]))
	assert_gt(field.size(), 0, "a field is fielded")
	for opp in field:
		var optimum := LapTimeModel.optimum_ms(track, _rival_meta(opp), {})
		for t in opp["event_times_ms"]:
			if int(t) < 0:
				continue   # crashed out: no time this event
			assert_gte(int(t) + 1, int(fastest_possible * float(optimum)),
				"%s stays inside the authored pace band, i.e. nothing trimmed it" % opp["name"])
	CarFixtures.restore()
	EngineLibrary.reset()
	CarPerformance.reset()


# The meta a rival actually raced: their car, their fitted engine AND their build level.
# The same builder the field generator rated the combo with (CarPerformance.merged_meta),
# so tyres and downforce are included.
func _rival_meta(opp: Dictionary) -> Dictionary:
	var owned := {
		"swapped_engine": String(opp.get("engine_id", "")),
		"installed_upgrades": (opp.get("upgrades", []) as Array).duplicate(),
		"disabled_upgrades": [],
	}
	return CarPerformance.merged_meta(owned, CarLibrary.by_id(String(opp.get("car_id", ""))))


# Whether this rival's build level fits a forced-induction part, which overrides whatever
# boost its engine came with.
func _fits_induction(opp: Dictionary) -> bool:
	for item_id in opp.get("upgrades", []):
		var effect: Dictionary = UpgradeLibrary.by_id(String(item_id)).get("effect", {})
		if effect.has("install_turbo") or effect.has("install_supercharger"):
			return true
	return false
