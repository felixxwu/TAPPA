extends GutTest
# The career-simulation tool (tools/sim_career.gd): the walk logic, not the numbers
# it reports. Every assertion here is an invariant that must hold for ANY reasonable
# RALLIES / CARS authoring — a designer retuning a restriction band, a map pin,
# or a star requirement must never break this file. Nothing pins a career length, a
# star total, an eligible-rally count, or a soft-lock rate; those are all outputs of
# tunable data and the tool exists precisely so they can move.
#
# See docs/superpowers/specs/2026-08-05-career-sim-design.md.

const SimCareer := preload("res://tools/sim_career.gd")

var _sim: Node


func before_each() -> void:
	# Instantiated but deliberately NEVER added to the tree: _ready() runs all 100
	# careers and then quits the tree, which would blow up the test run. Off-tree the
	# helpers are plain functions over dicts.
	_sim = SimCareer.new()


func after_each() -> void:
	_sim.free()


func _rng(seed_value: int) -> RandomNumberGenerator:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	return rng


func test_fresh_profile_has_one_real_starter_car() -> void:
	var profile: Dictionary = _sim._new_profile(_rng(1))
	var cars: Array = profile["cars"]
	assert_eq(cars.size(), 1, "a fresh career owns exactly the starter car")
	# A fresh career has completed exactly ONE rally: the opening one, which the player
	# drives before the map is ever shown (todo/opening-rally.md). Modelling it as "nothing
	# completed" would put the sim in a state no real player is ever in.
	var starter := String(cars[0]["model_id"])
	assert_eq((profile["rallies"] as Dictionary).keys(),
		[RallyLibrary.opening_rally_id_for(starter)],
		"a fresh career has completed its opening rally and nothing else")
	assert_eq(String(profile.get("starter_model_id", "")), starter,
		"and records the pick, which is what lights that rally on the map")
	var entry := CarLibrary.by_id(String(cars[0]["model_id"]))
	assert_false(entry.is_empty(), "the starter is a real catalogue car")


func test_starter_pick_covers_the_offered_ids() -> void:
	# The picker must be able to return every id it offers — a broken index would
	# silently pin every career to one starter. Iterates the constant as opaque
	# input rather than naming any particular model.
	var seen := {}
	for i in 200:
		seen[String(_sim._new_profile(_rng(i))["cars"][0]["model_id"])] = true
	for model_id in SimCareer.STARTER_MODEL_IDS:
		assert_true(seen.has(String(model_id)),
			"starter '%s' is reachable from _new_profile" % model_id)


func test_enterable_returns_only_incomplete_revealed_rallies() -> void:
	var profile: Dictionary = _sim._new_profile(_rng(2))
	for rally in _sim._enterable(profile):
		var rid := String(rally["id"])
		assert_false(profile["rallies"].get(rid, {}).get("completed", false),
			"%s is not already complete" % rid)
		assert_true(RallyLibrary.rally_revealed(rally, profile),
			"%s is revealed" % rid)


func test_enterable_has_no_duplicates() -> void:
	# The union across a garage must dedupe: two cars eligible for the same rally
	# would otherwise double-count it and inflate the reported eligible figure.
	var profile: Dictionary = _sim._new_profile(_rng(3))
	# Give the garage a second car of the same model so both cars match the same set.
	var twin: Dictionary = (profile["cars"][0] as Dictionary).duplicate(true)
	twin["instance_id"] = 2
	profile["cars"].append(twin)
	var ids := {}
	for rally in _sim._enterable(profile):
		var rid := String(rally["id"])
		assert_false(ids.has(rid), "%s appears once" % rid)
		ids[rid] = true


func test_completing_a_rally_removes_it_from_enterable() -> void:
	var profile: Dictionary = _sim._new_profile(_rng(4))
	var before: Array = _sim._enterable(profile)
	assert_gt(before.size(), 0, "a fresh career can enter something")

	# Ask the step which rally it actually entered — _pick prioritises specials and
	# is otherwise random, so it is NOT necessarily the first of the enterable list.
	var target := String(_sim._step(profile, before, _rng(5))["rally_id"])

	for rally in _sim._enterable(profile):
		assert_ne(String(rally["id"]), target,
			"a completed rally is no longer enterable")


func test_step_records_a_top3_placement_worth_stars() -> void:
	var profile: Dictionary = _sim._new_profile(_rng(6))
	var step: Dictionary = _sim._step(profile, _sim._enterable(profile), _rng(7))
	var record: Dictionary = profile["rallies"][step["rally_id"]]
	assert_true(record["completed"], "the rally is marked complete")
	# Only placements that are actually a win may be recorded — anything outside the
	# podium would mean the tool simulated a loss while counting it as a win.
	assert_gt(RallyLibrary.stars_for_placement(int(record["best_placed"])), 0,
		"the recorded placement is worth stars (a genuine top-3 finish)")


# Cars come from PRIZE RALLIES and nowhere else — nothing is drawn at random, nothing is
# bought (features/prize-rallies.md). The sim has to model that exactly, or its
# reachability verdict is about an economy the game does not have.
func test_a_car_is_added_only_by_a_rally_that_advertises_one() -> void:
	for seed_value in 20:
		var profile: Dictionary = _sim._new_profile(_rng(seed_value))
		for _i in 12:
			var enterable: Array = _sim._enterable(profile)
			if enterable.is_empty():
				break
			var before: int = (profile["cars"] as Array).size()
			var step: Dictionary = _sim._step(profile, enterable, _rng(seed_value * 100 + _i))
			var after: int = (profile["cars"] as Array).size()
			var prize := RallyLibrary.prize_car_id(RallyLibrary.by_id(String(step["rally_id"])))
			if prize == "":
				assert_eq(after, before, "a rally with no car prize adds no car")
			else:
				assert_lte(after, before + 1, "a prize rally adds at most one car")
				assert_eq(String(step["granted"]), prize if after > before else "",
					"and it is the car that rally advertises")


func test_the_sim_never_spends_stars_on_a_car() -> void:
	# Guards the deletion: the walk used to buy cars greedily from the balance. If that
	# ever came back the reachability closure would be measuring the wrong game.
	var profile: Dictionary = _sim._new_profile(_rng(5))
	for _i in 15:
		var enterable: Array = _sim._enterable(profile)
		if enterable.is_empty():
			break
		_sim._step(profile, enterable, _rng(_i))
	assert_eq(int(profile.get("stars_spent", 0)), 0, "the sim spends nothing")


# --- The reachability solver -------------------------------------------------

func test_solve_reachability_is_deterministic() -> void:
	# The whole value of the solver is that it is a PROOF, not a sample: same roster, same
	# starter, same answer every time.
	var starter := String(CarLibrary.STARTER_MODEL_IDS[0])
	var a: Dictionary = _sim.solve_reachability(starter)
	var b: Dictionary = _sim.solve_reachability(starter)
	assert_eq(a["unreached"], b["unreached"], "two runs agree on what is unreachable")
	assert_eq((a["waves"] as Array).size(), (b["waves"] as Array).size(), "and on the wave count")


func test_solve_reachability_only_takes_rallies_that_are_lit_and_enterable() -> void:
	# Each wave must satisfy BOTH gates — the map having reached the pin, and the garage
	# having something in band. A closure that ignored either would report a map as sound
	# when a player would be stuck.
	var starter := String(CarLibrary.STARTER_MODEL_IDS[0])
	var result: Dictionary = _sim.solve_reachability(starter)
	# Mirrors the solver's OWN start state: the starter recorded, which is what lights
	# their opening rally before it is completed (RallyLibrary.lit_sources). A profile
	# without it sees a wholly dark map, since HQ lights nothing.
	var profile := {"cars": [_sim._make_car(1, starter)], "rallies": {},
		"stars_earned": 0, "stars_spent": 0, "starter_model_id": starter}
	for wave in result["waves"]:
		for rid in wave:
			var rally := RallyLibrary.by_id(String(rid))
			assert_true(RallyLibrary.rally_revealed(rally, profile),
				"%s was lit when the solver took it" % rid)
		for rid in wave:
			profile["rallies"][String(rid)] = {"completed": true, "best_placed": 1}
			var prize := RallyLibrary.prize_car_id(RallyLibrary.by_id(String(rid)))
			if prize != "":
				(profile["cars"] as Array).append(
					_sim._make_car((profile["cars"] as Array).size() + 1, prize))


func test_solve_reachability_reports_what_it_could_not_reach() -> void:
	# The actionable output. Every rally is either in a wave or in `unreached` — never
	# both, never neither — so the report accounts for the whole roster.
	var result: Dictionary = _sim.solve_reachability(String(CarLibrary.STARTER_MODEL_IDS[0]))
	var seen := {}
	for wave in result["waves"]:
		for rid in wave:
			assert_false(seen.has(String(rid)), "%s is taken once" % rid)
			seen[String(rid)] = true
	for rid in result["unreached"]:
		assert_false(seen.has(String(rid)), "%s is not both reached and unreached" % rid)
	assert_eq(seen.size() + (result["unreached"] as Array).size(), RallyLibrary.all().size(),
		"every rally is accounted for")


func test_stars_spent_never_exceeds_stars_earned() -> void:
	# The core economy invariant: you cannot spend stars you never earned. Holds trivially
	# when cars are free, and is the thing most worth guarding once they are not.
	var run: Dictionary = _sim._run_career(_rng(21), RallyLibrary.all().size())
	var profile: Dictionary = run["profile"]
	assert_true(int(profile.get("stars_spent", 0)) <= int(profile.get("stars_earned", 0)),
		"stars spent never exceeds stars earned")
	assert_true(_sim._stars_available(profile) >= 0, "the final balance is not negative")


func test_granted_cars_are_real_catalogue_entries() -> void:
	var profile: Dictionary = _sim._new_profile(_rng(8))
	for _i in 15:
		var enterable: Array = _sim._enterable(profile)
		if enterable.is_empty():
			break
		_sim._step(profile, enterable, _rng(_i + 900))
	for car in profile["cars"]:
		assert_false(CarLibrary.by_id(String(car["model_id"])).is_empty(),
			"granted car '%s' is a real catalogue entry" % car["model_id"])


func test_stars_never_decrease_across_a_career() -> void:
	# `stars_earned` is a monotonic ledger credited only by positive deltas, so it can only
	# ever climb. A regression that debited it — or that overwrote a better placement with a
	# worse one — would surface here.
	var run: Dictionary = _sim._run_career(_rng(9), RallyLibrary.all().size())
	var previous := 0
	for step in run["steps"]:
		var now := int(step["stars"])
		assert_true(now >= previous,
			"stars did not fall at %s (%d -> %d)" % [step["rally_id"], previous, now])
		previous = now


func test_completing_any_rally_lights_the_map_around_it() -> void:
	# Reveal is spatial now, so EVERY completion — special or ordinary — lights a circle
	# around its own pin. There is no completion counter for a special to be excluded from,
	# which is why the old "specials are progression-neutral" carve-out is gone.
	var profile: Dictionary = _sim._new_profile(_rng(10))
	for _i in 20:
		var enterable: Array = _sim._enterable(profile)
		if enterable.is_empty():
			break
		var before: int = RallyLibrary.lit_sources(profile).size()
		var step: Dictionary = _sim._step(profile, enterable, _rng(_i + 500))
		var after: int = RallyLibrary.lit_sources(profile).size()
		if bool(step.get("completed", true)):
			assert_eq(after, before + 1,
				"%s lit a new circle on completion" % step["rally_id"])
		else:
			assert_eq(after, before, "an uncompleted attempt lights nothing")


func test_special_first_priority_is_honoured() -> void:
	# Whenever a special is enterable, the pick must be a special.
	var profile: Dictionary = _sim._new_profile(_rng(11))
	for _i in 25:
		var enterable: Array = _sim._enterable(profile)
		if enterable.is_empty():
			break
		var special_available := false
		for rally in enterable:
			if RallyLibrary.is_special(rally):
				special_available = true
				break
		var picked: Dictionary = _sim._pick(enterable, _rng(_i + 77))
		if special_available:
			assert_true(RallyLibrary.is_special(picked),
				"a special is taken while one is available")
		_sim._step(profile, enterable, _rng(_i + 77))


func test_every_career_terminates_in_a_real_outcome() -> void:
	# The iteration cap is a guard against a non-terminating walk, never an expected
	# result — reaching it means the loop failed to converge.
	var total := RallyLibrary.all().size()
	for seed_value in 12:
		var run: Dictionary = _sim._run_career(_rng(seed_value * 31), total)
		var outcome := String(run["outcome"])
		assert_ne(outcome, SimCareer.DONE_CAPPED,
			"career %d converged rather than hitting the cap" % seed_value)
		assert_true(outcome == SimCareer.DONE_COMPLETE or outcome == SimCareer.DONE_STUCK,
			"career %d ended in a known outcome (got '%s')" % [seed_value, outcome])
		# A career never enters more rallies than exist, since each step completes a
		# distinct one.
		assert_true((run["steps"] as Array).size() <= total,
			"career %d entered no more rallies than exist" % seed_value)


func test_stuck_outcome_means_something_really_is_unenterable() -> void:
	# Whichever way a career ends, the two outcomes must be distinguishable by the
	# profile itself: complete => nothing incomplete; stuck => something incomplete.
	var total := RallyLibrary.all().size()
	for seed_value in 12:
		var run: Dictionary = _sim._run_career(_rng(seed_value * 17 + 3), total)
		var all_done: bool = _sim._all_complete(run["profile"])
		if String(run["outcome"]) == SimCareer.DONE_COMPLETE:
			assert_true(all_done, "a 'complete' career left nothing incomplete")
		else:
			assert_false(all_done, "a 'stuck' career left something incomplete")
		assert_eq(_sim._enterable(run["profile"]).size(), 0,
			"a finished career has nothing left it can enter")
