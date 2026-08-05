extends GutTest
# The career-simulation tool (tools/sim_career.gd): the walk logic, not the numbers
# it reports. Every assertion here is an invariant that must hold for ANY reasonable
# RALLIES / CARS authoring — a designer retuning a restriction band, a reveal_after,
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
	assert_eq(profile["rallies"], {}, "a fresh career has completed nothing")
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


func test_car_supply_follows_the_configured_reward_model() -> void:
	# Two reward models, selected by STAR_COST_PER_CAR, with different invariants:
	#
	#   cost == 0 (the CURRENT game) — an ordinary top-3 always draws exactly one car and
	#             a special draws none. That asymmetry is what makes "cars owned"
	#             interesting, so it stays asserted whenever the tool models today's rules.
	#
	#   cost  > 0 (the PROPOSED economy, todo/star-economy.md) — cars are bought from a
	#             star balance in a menu, so they are no longer tied to finishing a rally
	#             at all. What must hold instead: the balance never goes negative, and
	#             every car added is paid for in full.
	#
	# Asserted for whichever model is configured rather than pinning one, so flipping the
	# constant to explore a price does not turn this file red.
	var saw_ordinary := false
	var saw_special := false
	for seed_value in 40:
		var profile: Dictionary = _sim._new_profile(_rng(seed_value))
		for _i in 12:
			var enterable: Array = _sim._enterable(profile)
			if enterable.is_empty():
				break
			var before: int = (profile["cars"] as Array).size()
			var spent_before := int(profile.get("stars_spent", 0))
			var step: Dictionary = _sim._step(profile, enterable, _rng(seed_value * 100 + _i))
			var after: int = (profile["cars"] as Array).size()

			if step["special"]:
				saw_special = true
			else:
				saw_ordinary = true

			if SimCareer.STAR_COST_PER_CAR <= 0:
				if step["special"]:
					assert_eq(after, before, "a special grants no car")
				else:
					assert_eq(after, before + 1, "an ordinary win grants exactly one car")
				continue

			# Economy model.
			var bought := int(step["bought"])
			var free_cars := int(step["free_cars"])
			assert_eq(after, before + bought, "cars added equals cars bought")
			assert_true(free_cars <= bought, "free cars are a subset of cars acquired")
			# Paid cars are charged in full; rescued ones are charged nothing.
			assert_eq(int(profile["stars_spent"]) - spent_before,
				(bought - free_cars) * SimCareer.STAR_COST_PER_CAR,
				"paid cars charged in full, rescues charged nothing")
			assert_eq(int(step["paid"]), (bought - free_cars) * SimCareer.STAR_COST_PER_CAR,
				"the reported debit matches the paid car count")
			assert_true(int(step["balance"]) >= 0, "the star balance never goes negative")
			if free_cars > 0:
				# A rescue only ever fires when the player could NOT afford a car, and grants
				# exactly one. Anything else means the broke guard leaked and the rescue is
				# farmable (todo/star-economy.md, change 1).
				assert_eq(free_cars, 1, "a rescue grants exactly one car")
				assert_true(int(step["balance"]) < SimCareer.STAR_COST_PER_CAR,
					"a rescue only fires when the car was unaffordable")
			else:
				# Greedy purchasing must leave nothing affordable behind.
				assert_true(int(step["balance"]) < SimCareer.STAR_COST_PER_CAR,
					"no affordable purchase was left unmade")
		if saw_ordinary and saw_special:
			break
	assert_true(saw_ordinary, "the walk exercised an ordinary rally")
	assert_true(saw_special, "the walk exercised a special event")


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


func test_specials_do_not_advance_the_reveal_count() -> void:
	# _completed_count (which drives reveal_after) skips specials, so a special must
	# leave it untouched. This is what makes a special a progression-neutral detour.
	var profile: Dictionary = _sim._new_profile(_rng(10))
	for _i in 20:
		var enterable: Array = _sim._enterable(profile)
		if enterable.is_empty():
			break
		var before := RallyLibrary._completed_count(profile)
		var step: Dictionary = _sim._step(profile, enterable, _rng(_i + 500))
		var after := RallyLibrary._completed_count(profile)
		if step["special"]:
			assert_eq(after, before, "a special does not advance the reveal count")
		else:
			assert_eq(after, before + 1, "an ordinary win advances the reveal count by one")


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
