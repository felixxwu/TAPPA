extends Node
# Career Monte Carlo: simulates many whole careers as PURE COMPUTATION — no track
# generation, no physics, no main.tscn — by driving the REAL progression predicates
# (RallyLibrary.rally_revealed / is_eligible / incomplete_rallies_enterable_by,
# RewardSystem.draw_car) over a synthetic profile dict. Reports, per rally index,
# how many cars the player owns and how many unfinished rallies they can enter,
# averaged across runs; and how often a career SOFT-LOCKS (rallies left, but no
# owned car in band for any of them).
#
# Like report_eligibility.gd this is a reporting tool, NOT a pass/fail gate: it
# surfaces authoring signals (a starved `restriction` band, a reveal_after that
# outruns the car ladder) for a human to judge.
#
# Run via ./sim_career.sh (wraps
# `$GODOT --headless --path . res://tools/sim_career.tscn`).
#
# Design: docs/superpowers/specs/2026-08-05-career-sim-design.md
#
# READ THE RESULTS WITH THESE CAVEATS:
#   * Averages at index i cover only runs STILL ALIVE at i, so later rows are
#     survivorship-biased. The "alive" column is there to make that legible.
#   * Cars are STOCK — no upgrades, no engine swaps. Real players raise power-to-
#     weight and unlock higher bands, so eligible counts here are a LOWER bound and
#     the stuck rate an UPPER bound. Conservative in the useful direction.
#   * Placement is a coin flip, not a simulated race. This answers "given the player
#     keeps winning, does the career sustain itself" — not "can the player win".

# How many waves a rally may sit lit-but-unenterable before the report calls it out. Two is
# anticipation (you can see where you are going and need a better car); beyond that the pin
# reads as broken rather than aspirational.
const TEASE_LAG_WARN := 3

const RUNS := 100
const BASE_SEED := 20260805

# Star price of a car (todo/star-economy.md). Set to 0 to model the OLD game instead: a
# free car on every ordinary top-3 finish. Any value > 0 models the economy — no automatic
# car drop, and stars are spent to buy one.
#
# The sim's own knob, deliberately a constant: the GAME reads its price from GameConfig so a
# designer can retune it, but the tool is not the game and wants a fixed, reproducible value.
#
# Specials gate on COMPLETED ORDINARY RALLIES now, not stars, so spending can never revoke a
# special the player already qualified for — RallyLibrary.rally_revealed handles that for
# real and this tool inherits it for free.

# Uniform random pick among these for the starter car. Read from CarLibrary rather than
# re-listed here — this was a second hardcoded copy of the starter roster, so the sim could
# silently drift from what the game actually offers.
const STARTER_MODEL_IDS := CarLibrary.STARTER_MODEL_IDS


# Does this synthetic profile already hold a car of this model? Mirrors Save.owns_model, so
# a prize rally cannot mint a duplicate here either.
static func _owns_model(profile: Dictionary, model_id: String) -> bool:
	for car in profile.get("cars", []):
		if String((car as Dictionary).get("model_id", "")) == model_id:
			return true
	return false

# "Win with 2 or 3 stars" = a coin flip between 1st (3 stars) and 2nd (2 stars).
# Both are top-3, so both count as a win and both trigger the ordinary-rally car draw.
const PLACEMENTS := [1, 2]

# Terminal states.
const DONE_COMPLETE := "complete"   # nothing left to enter because nothing is incomplete
const DONE_STUCK := "stuck"         # rallies remain, but no owned car is in band
const DONE_CAPPED := "capped"       # iteration guard tripped — a bug, not a result


func _ready() -> void:
	var total_rallies := RallyLibrary.all().size()
	print("=== Career simulation: %d runs over %d rallies ===" % [RUNS, total_rallies])
	print("stock cars only | special-first | placement 1st/2nd coin flip")
	print("")

	var runs: Array = []
	var t0 := Time.get_ticks_msec()
	for i in RUNS:
		var rng := RandomNumberGenerator.new()
		rng.seed = BASE_SEED + i
		runs.append(_run_career(rng, total_rallies))
	var elapsed := Time.get_ticks_msec() - t0

	_report(runs, total_rallies)
	print("")
	print("simulated %d careers in %d ms (%.1f ms per career)" % [
		RUNS, elapsed, float(elapsed) / float(RUNS)])

	# Quit explicitly, as every other tool here does. Without this the scene stays
	# alive after the report and the PerfLog autoload prints [perf] lines forever,
	# which reads as a hang long after the work is actually done.
	get_tree().quit(0)


# --- One career ---------------------------------------------------------------

# Walk a whole career: repeatedly enter the best available rally until nothing is
# enterable. Returns {"steps": Array, "outcome": String, "profile": Dictionary}.
func _run_career(rng: RandomNumberGenerator, total_rallies: int) -> Dictionary:
	var profile := _new_profile(rng)
	var steps: Array = []
	var cap := total_rallies * 2  # non-termination guard; tripping it is a bug
	var outcome := DONE_CAPPED

	while steps.size() < cap:
		var enterable := _enterable(profile)
		if enterable.is_empty():
			outcome = DONE_COMPLETE if _all_complete(profile) else DONE_STUCK
			break
		steps.append(_step(profile, enterable, rng))

	return {"steps": steps, "outcome": outcome, "profile": profile}


# A fresh profile: empty rally record, one randomly-chosen starter car. Built
# directly rather than through Save._default_profile() (a non-static method on an
# autoload) — the predicates only ever read "cars" and "rallies".
func _new_profile(rng: RandomNumberGenerator) -> Dictionary:
	var model_id := String(STARTER_MODEL_IDS[rng.randi() % STARTER_MODEL_IDS.size()])
	var profile := {"cars": [_make_car(1, model_id)], "rallies": {},
		"stars_earned": 0, "stars_spent": 0}
	_seed_opening_rally(profile, model_id)
	return profile


# Put the player where the GAME puts them on turn one: their starter's opening rally
# already completed (todo/opening-rally.md). They are dropped into it straight from the
# picker and it completes whatever the result, so a career that begins at HQ with nothing
# done is a state no real player is ever in — and modelling it that way would report the
# opening rally as something to be REACHED rather than as where they start, which is the
# difference between "the map has a dead end" and "the map is fine".
func _seed_opening_rally(profile: Dictionary, starter_model_id: String) -> void:
	var opening := RallyLibrary.opening_rally_id_for(starter_model_id)
	if opening == "":
		return
	# best_placed 1 matches the rest of this tool's optimism: it models the LAYOUT, asking
	# what a player who keeps winning can reach, so a pessimistic placement here would
	# confuse a pacing question with a difficulty one.
	profile["rallies"][opening] = {"completed": true, "best_placed": 1}
	# Recorded on the profile too, because that is what the GAME reads to light the opening
	# rally's circle before it is completed (RallyLibrary.lit_sources) — without it this
	# tool's map would differ from the one the player sees.
	profile["starter_model_id"] = starter_model_id


# An owned car carrying just the fields effective_meta / max_potential_meta read, plus `hp`.
#
# `hp` MATTERS even though this tool models no damage: the eligibility walk skips
# damaged cars, and health reads `hp` with a default of 0 — so a car
# without the key reads as WRECKED, which would make every synthetic garage look stranded
# and hand out free rescue cars forever. Seeded from the catalogue max exactly as
# Save.grant_car does.
func _make_car(instance_id: int, model_id: String) -> Dictionary:
	var entry := CarLibrary.by_id(model_id)
	return {
		"instance_id": instance_id,
		"model_id": model_id,
		"hp": float(entry.get("max_hp", 1000.0)) if not entry.is_empty() else 1000.0,
		"installed_upgrades": [],
		"disabled_upgrades": [],
		"tuning": {},
	}


# One rally: pick it (specials first), finish top-3, record it, and on an ORDINARY
# rally take the car reward. Mutates `profile`. Returns a per-step record.
func _step(profile: Dictionary, enterable: Array, rng: RandomNumberGenerator) -> Dictionary:
	var cars: Array = profile["cars"]
	var before := cars.size()

	var rally := _pick(enterable, rng)
	var is_special := RallyLibrary.is_special(rally)
	var placed := int(PLACEMENTS[rng.randi() % PLACEMENTS.size()])

	# Mirrors Save.complete_rally: `completed` already means a top-3 finish, `best_placed`
	# only ever improves, and the star LEDGER is credited the DELTA against what this rally
	# was previously worth. This sim never replays a rally, so the delta always equals the
	# placement rating — modelled properly anyway so the tool stays faithful if that changes.
	var rec: Dictionary = profile["rallies"].get(rally["id"], {})
	var was_worth := RallyLibrary.stars_for_placement(int(rec.get("best_placed", 0)))
	var best := int(rec.get("best_placed", 0))
	if best <= 0 or placed < best:
		best = placed
	profile["rallies"][rally["id"]] = {"completed": true, "best_placed": best}
	var gained := RallyLibrary.stars_for_placement(best) - was_worth
	if gained > 0:
		profile["stars_earned"] = int(profile.get("stars_earned", 0)) + gained

	# Stranded = nothing enterable right now. NOTE the _all_complete guard: on the final
	# rally of a career _enterable is empty because there is nothing LEFT, not because the
	# player is locked out. Without it every run reports a phantom strand on its last step.
	#
	# Under the ECONOMY this is checked after every rally including specials, because the
	# purchase menu is reachable from the map at any time — it is not tied to the kind of
	# rally just finished. Under the legacy free-car model only an ordinary rally draws, so
	# only an ordinary rally can rescue.
	var stranded := not _all_complete(profile) and _enterable(profile).is_empty()

	# THE reward: a rally hands over the CAR it advertises, on a first win only
	# (features/prize-rallies.md). Nothing is drawn at random and nothing is bought — the
	# purchase economy this tool used to model (a greedy spend-down plus a stranded-and-broke
	# free-car rescue) is gone, so the garage grows only where the roster says it should.
	#
	# That makes the walk DETERMINISTIC in what it owns: given the same rallies completed,
	# the same cars are held. Which is what lets solve_reachability below be an exhaustive
	# proof rather than a sampled estimate.
	var granted := ""
	var prize := RallyLibrary.prize_car_id(rally)
	if prize != "" and not _owns_model(profile, prize):
		granted = prize
		cars.append(_make_car(cars.size() + 1, prize))

	return {
		"rally_id": String(rally["id"]),
		"special": is_special,
		"placed": placed,
		"granted": granted,
		# Snapshot AFTER the reward, so "cars owned" is the player's state walking
		# away from this rally, and "eligible" is what they can do next.
		"cars": cars.size(),
		"eligible": _enterable(profile).size(),
		# Revealed-but-incomplete IGNORING the garage — i.e. what reveal gating alone
		# has opened. The gap between this and `eligible` is what restriction bands are
		# actually filtering out, which separates the two gates that govern breadth.
		"revealed": _revealed_incomplete(profile).size(),
		# Stranded = nothing enterable and something still incomplete. With cars no longer
		# purchasable there is no rescue to soften it: a strand is a CONTENT bug — the map
		# has led the player to a frontier they cannot drive — and the whole point of this
		# tool is to find one before a player does.
		"stranded": stranded,
		"stars": int(profile.get("stars_earned", 0)),
		"balance": _stars_available(profile),
		"gained_car": cars.size() > before,
	}


# Strict special-first: specials are the reward moment, so a player takes one the
# moment its star gate opens. Uniform among the specials if any, else among the rest.
func _pick(enterable: Array, rng: RandomNumberGenerator) -> Dictionary:
	var specials: Array = []
	for rally in enterable:
		if RallyLibrary.is_special(rally):
			specials.append(rally)
	var pool: Array = specials if not specials.is_empty() else enterable
	return pool[rng.randi() % pool.size()]


# --- Queries ------------------------------------------------------------------

# Every still-incomplete rally that ANY owned car can currently enter, deduped.
# incomplete_rallies_enterable_by already folds in "incomplete AND revealed AND
# in-band (or detunable into band)" for ONE car, so the union across the garage is
# all this has to add — the same thing the HQ map shows the player.
func _enterable(profile: Dictionary) -> Array:
	var seen: Dictionary = {}
	var out: Array = []
	for car in profile["cars"]:
		var pair := _meta_pair(car)
		for rally in RallyLibrary.incomplete_rallies_enterable_by(pair[0], profile, pair[1]):
			var rid := String(rally["id"])
			if seen.has(rid):
				continue
			seen[rid] = true
			out.append(rally)
	return out


# The (live, max-potential) meta pair eligibility is judged on — the ceiling is
# checked against live stats and the floor against max potential. Mirrors the HQ's
# own entry plan (hq.gd _entry_plan).
#
# CACHED BY MODEL ID, which is sound ONLY because this tool models stock cars: no
# upgrades, no swaps, no tuning, so every car of a model has identical meta and a
# car's meta never changes over its life. Without the cache this is the tool's hot
# spot by a wide margin — _enterable recomputes it per owned car per call, and
# max_potential_meta deep-copies (`owned_car.duplicate(true)`), so a full run costs
# millions of deep copies. If this tool ever grows upgrade/swap modelling, this
# cache MUST become per-instance-and-state or it will silently report stale bands.
var _meta_cache: Dictionary = {}

func _meta_pair(car: Dictionary) -> Array:
	var model_id := String(car.get("model_id", ""))
	if _meta_cache.has(model_id):
		return _meta_cache[model_id]
	var entry := CarLibrary.by_id(model_id)
	var pair := [
		UpgradeLibrary.effective_meta(car, entry),
		UpgradeLibrary.max_potential_meta(car, entry),
	]
	_meta_cache[model_id] = pair
	return pair


# Every still-incomplete rally whose REVEAL gate is open, regardless of whether any
# owned car can enter it. This is the pool reveal gating alone has released; compare
# against _enterable to see how much work the restriction bands are doing.
func _revealed_incomplete(profile: Dictionary) -> Array:
	var rallies: Dictionary = profile.get("rallies", {})
	var out: Array = []
	for rally in RallyLibrary.all():
		if rallies.get(rally["id"], {}).get("completed", false):
			continue
		if RallyLibrary.rally_revealed(rally, profile):
			out.append(rally)
	return out


# Spendable balance, mirroring Save.stars_available(): the persisted `stars_earned`
# ledger less `stars_spent`. Both live on the profile now — there is no derived total to
# recompute (RallyLibrary.total_stars is gone; see todo/star-economy.md).
func _stars_available(profile: Dictionary) -> int:
	return maxi(0, int(profile.get("stars_earned", 0)) - int(profile.get("stars_spent", 0)))


func _all_complete(profile: Dictionary) -> bool:
	var rallies: Dictionary = profile.get("rallies", {})
	for rally in RallyLibrary.all():
		if not rallies.get(rally["id"], {}).get("completed", false):
			return false
	return true


# --- Reporting ----------------------------------------------------------------

# --- The reachability solver -------------------------------------------------
# THE dead-end check, and the reason this tool stopped being a sampled walk.
#
# Reveal is geometric and cars are won at named rallies, so progression is now a
# DETERMINISTIC graph: from (HQ lit, one starter car), the set of rallies you can reach is
# fixed. Nothing is random and nothing is lost — wrecks are recoverable
# (features/damage.md) — so the closure computed here is exactly what a player can achieve,
# not an estimate of it.
#
# The walk: repeatedly take EVERY rally that is both lit and enterable, complete it, add its
# prize, re-light; stop at a fixed point. If the closure covers the whole roster the map is
# sound for that starter. If it does not, the rallies left over are the dead end, and the
# ones adjacent to the frontier are where to look.
#
# Run per STARTER, because the opening rallies are class-restricted: a map that works for
# the FWD hatch and strands the RWD roadster is still broken, and only a per-starter walk
# sees it.
func solve_reachability(starter_model_id: String) -> Dictionary:
	var profile := {"cars": [_make_car(1, starter_model_id)], "rallies": {},
		"stars_earned": 0, "stars_spent": 0}
	_seed_opening_rally(profile, starter_model_id)
	# The opening rally is wave 1: the player has driven it before the map is ever shown, so
	# it is progress they have MADE rather than progress the closure has to find. Reported
	# as a wave rather than silently pre-completed so the walk still accounts for the whole
	# roster — every rally is either in a wave or in `unreached`.
	var waves: Array = []
	var opening := RallyLibrary.opening_rally_id_for(starter_model_id)
	if opening != "":
		waves.append([opening])
	while true:
		var takeable: Array = []
		for rally in _enterable(profile):
			takeable.append(String(rally["id"]))
		if takeable.is_empty():
			break
		takeable.sort()  # deterministic order, so two runs of this tool agree
		waves.append(takeable)
		for rid in takeable:
			var rally := RallyLibrary.by_id(rid)
			profile["rallies"][rid] = {"completed": true, "best_placed": 1}
			var prize := RallyLibrary.prize_car_id(rally)
			if prize != "" and not _owns_model(profile, prize):
				(profile["cars"] as Array).append(
					_make_car((profile["cars"] as Array).size() + 1, prize))
	var unreached: Array = []
	for rally in RallyLibrary.all():
		if not profile["rallies"].has(String(rally["id"])):
			unreached.append(String(rally["id"]))
	return {"starter": starter_model_id, "waves": waves, "unreached": unreached,
		"cars": (profile["cars"] as Array).size(),
		"teases": _lit_but_unenterable(starter_model_id, waves)}


# The rallies this starter watched sit LIT AND LOCKED, and for how many waves.
#
# "Reachable eventually" is not the same as "playable when you can see it", and only the
# first was ever measured — which is how a real defect got through: `shakedown` sat one pin
# from the Focus's opening rally, lit from wave 2, and could not be entered until wave 5,
# because its `car_type: roadster` clause meant the Focus player first had to cross the map
# and win the Viper. The solver called that 32/32 and was right; the player is looking at
# an adjacent pin they cannot touch.
#
# Returns [{id, lit, taken, lag}] for every rally whose lag exceeds nothing — the caller
# decides what counts as too long, since a wave or two of anticipation is the design
# working, and five is a locked door.
func _lit_but_unenterable(starter_model_id: String, waves: Array) -> Array:
	var taken := {}
	for n in waves.size():
		for rid in waves[n]:
			taken[String(rid)] = n + 1
	# Re-walk, this time asking only what the MAP has lit — no eligibility — so the two
	# answers can be compared wave by wave.
	var profile := {"cars": [], "rallies": {}, "starter_model_id": starter_model_id}
	var lit_at := {}
	for n in waves.size():
		for rally in RallyLibrary.all():
			var rid := String(rally["id"])
			if not lit_at.has(rid) and RallyLibrary.rally_revealed(rally, profile):
				lit_at[rid] = n + 1
		for rid in waves[n]:
			profile["rallies"][String(rid)] = {"completed": true, "best_placed": 1}
	var out: Array = []
	for rid in taken:
		var lag: int = int(taken[rid]) - int(lit_at.get(rid, taken[rid]))
		if lag > 0:
			out.append({"id": rid, "lit": int(lit_at.get(rid, 0)),
				"taken": int(taken[rid]), "lag": lag})
	out.sort_custom(func(a, b): return int(a["lag"]) > int(b["lag"]))
	return out


# Print the solver's verdict for every starter the game offers.
func _print_reachability() -> void:
	print("")
	print("--- Reachability from HQ (exhaustive, per starter) ---")
	var total := RallyLibrary.all().size()
	for model_id in CarLibrary.STARTER_MODEL_IDS:
		if CarLibrary.by_id(String(model_id)).is_empty():
			continue
		var r := solve_reachability(String(model_id))
		var reached := total - (r["unreached"] as Array).size()
		print("%-12s %2d/%d rallies over %d wave(s), %d car(s) won" % [
			model_id, reached, total, (r["waves"] as Array).size(), int(r["cars"]) - 1])
		if not (r["unreached"] as Array).is_empty():
			print("   !! UNREACHABLE: %s" % ", ".join(PackedStringArray(r["unreached"])))
		# A pin the player can SEE but not enter, for waves on end, is the failure mode
		# "everything is reachable" cannot express — see _lit_but_unenterable.
		for t in r["teases"]:
			if int(t["lag"]) < TEASE_LAG_WARN:
				continue
			print("   ~~ %s lit at wave %d, enterable only at %d (%d waves locked)" % [
				t["id"], t["lit"], t["taken"], t["lag"]])
	print("")
	print("An unreachable rally is content no player can ever see. Fix it by widening a")
	print("restriction band, re-pairing a prize car, or moving a pin (tools/fit_map_pins.py).")
	print("A ~~ line is a pin lit long before it can be entered — usually a class clause on")
	print("a rally whose neighbours cannot supply that class.")


func _report(runs: Array, total_rallies: int) -> void:
	_print_reachability()
	_print_reveal_curve()
	print("")
	_print_per_rally_table(runs)
	print("")
	_print_summary(runs, total_rallies)


# The authored reveal schedule, straight off RallyLibrary — how much of the ordinary
# roster `reveal_after` has released at each completion count, independent of any
# simulated career. This is the ceiling on choice: no garage can make more rallies
# available than reveal gating has opened. Read alongside the `revealed` vs `eligible`
# columns below to see which of the two gates is actually binding.
func _print_reveal_curve() -> void:
	var ordinary: Array = []
	for rally in RallyLibrary.all():
		if not RallyLibrary.is_special(rally):
			ordinary.append(rally)

	# Bucket the authored thresholds so the shape of the schedule is visible.
	var buckets: Dictionary = {}
	for rally in ordinary:
		var need := int(rally.get("reveal_after", 0))
		buckets[need] = int(buckets.get(need, 0)) + 1
	var needs: Array = buckets.keys()
	needs.sort()

	print("--- Authored reveal schedule (%d ordinary rallies, %d specials) ---" % [
		ordinary.size(), RallyLibrary.all().size() - ordinary.size()])
	var parts: Array = []
	for need in needs:
		parts.append("reveal_after=%d: %d" % [int(need), int(buckets[need])])
	print("  " + ", ".join(parts))

	var highest := int(needs[needs.size() - 1]) if not needs.is_empty() else 0
	print("  cumulative revealed by completion count:")
	var line := "   "
	for n in range(0, highest + 2):
		var count := 0
		for rally in ordinary:
			if int(rally.get("reveal_after", 0)) <= n:
				count += 1
		line += " %d:%d" % [n, count]
	print(line)
	print("  => the whole ordinary roster is revealed by %d completions, of %d to play" % [
		highest, ordinary.size()])

	# Per-rally listing in authored order — the working view for retuning the schedule,
	# since the buckets alone don't say WHICH rally sits on which rung.
	print("  ordinary rallies in authored order (id, reveal_after, difficulty):")
	for rally in ordinary:
		print("    %-24s reveal_after=%-3d d%d" % [
			String(rally["id"]), int(rally.get("reveal_after", 0)),
			int(rally.get("difficulty", 0))])


# Per rally INDEX (1st rally of a career, 2nd, ...) averaged across every run that
# reached that index. "alive" is the sample size behind each row — the further down
# you read, the more survivorship-biased the means.
func _print_per_rally_table(runs: Array) -> void:
	var longest := 0
	for run in runs:
		longest = max(longest, (run["steps"] as Array).size())

	print("--- Per rally completed (mean across runs alive at that index) ---")
	print("%4s  %5s  %9s  %9s  %9s  %9s  %s" % [
		"idx", "alive", "cars", "revealed", "eligible", "stars", "special share"])

	for idx in longest:
		var alive := 0
		var cars := 0.0
		var revealed := 0.0
		var eligible := 0.0
		var stars := 0.0
		var specials := 0
		for run in runs:
			var steps: Array = run["steps"]
			if idx >= steps.size():
				continue
			var s: Dictionary = steps[idx]
			alive += 1
			cars += float(s["cars"])
			revealed += float(s["revealed"])
			eligible += float(s["eligible"])
			stars += float(s["stars"])
			if s["special"]:
				specials += 1
		if alive == 0:
			continue
		print("%4d  %5d  %9.2f  %9.2f  %9.2f  %9.2f  %12.0f%%" % [
			idx + 1, alive, cars / alive, revealed / alive, eligible / alive,
			stars / alive, 100.0 * float(specials) / float(alive)])


func _print_summary(runs: Array, total_rallies: int) -> void:
	var complete := 0
	var stuck := 0
	var capped := 0
	var len_sum := 0
	var len_min := 1 << 30
	var len_max := 0
	var stars_sum := 0
	var cars_sum := 0
	var unfinished_tally: Dictionary = {}

	for run in runs:
		var steps: Array = run["steps"]
		var n := steps.size()
		len_sum += n
		len_min = min(len_min, n)
		len_max = max(len_max, n)
		stars_sum += int(run["profile"].get("stars_earned", 0))
		cars_sum += (run["profile"]["cars"] as Array).size()
		match String(run["outcome"]):
			DONE_COMPLETE: complete += 1
			DONE_STUCK:
				stuck += 1
				_tally_unfinished(run["profile"], unfinished_tally)
			_: capped += 1

	var n_runs := float(runs.size())
	print("--- Summary over %d runs ---" % runs.size())
	print("career length : mean %.1f rallies (min %d, max %d) of %d total" % [
		float(len_sum) / n_runs, len_min, len_max, total_rallies])
	print("final cars    : mean %.2f" % (float(cars_sum) / n_runs))

	# Roster COVERAGE — distinct models, not car count. Duplicates are what a capped star
	# pool buys once _pick_prefer_unowned runs out of new models, so "cars owned" alone
	# overstates how much of the catalogue a player actually sees.
	var distinct_sum := 0
	var leftover_sum := 0
	for run in runs:
		var models := {}
		for car in run["profile"]["cars"]:
			models[String(car["model_id"])] = true
		distinct_sum += models.size()
		leftover_sum += _stars_available(run["profile"])
	print("distinct models: mean %.2f of %d in the catalogue (%.0f%% seen)" % [
		float(distinct_sum) / n_runs, CarLibrary.CARS.size(),
		100.0 * (float(distinct_sum) / n_runs) / float(CarLibrary.CARS.size())])
	print("stars unspent : mean %.1f left over at career end" % (float(leftover_sum) / n_runs))
	print("final stars   : mean %.1f earned over the career" % (float(stars_sum) / n_runs))
	print("completed all : %d (%.0f%%)" % [complete, 100.0 * float(complete) / n_runs])
	print("SOFT-LOCKED   : %d (%.0f%%)" % [stuck, 100.0 * float(stuck) / n_runs])

	# Any strand at all is a CONTENT bug now. There is no purchase and no rescue to soften
	# it: if the map leads to a frontier the garage cannot drive, the player simply stops.
	var strand_runs := 0
	for run in runs:
		for step in run["steps"]:
			if bool(step["stranded"]):
				strand_runs += 1
				break
	if strand_runs > 0:
		print("!! %d run(s) hit a frontier with no enterable rally — a ROSTER bug" % strand_runs)

	if capped > 0:
		print("!! %d run(s) hit the iteration cap — that is a BUG in this tool, not a result"
			% capped)

	if stuck == 0:
		return
	# The actionable signal: which rallies the stuck careers could never enter.
	# A rally near the top of this list has a `restriction` band the car ladder
	# does not reliably feed.
	print("")
	print("--- Most often left incomplete in soft-locked runs ---")
	var ids: Array = unfinished_tally.keys()
	ids.sort_custom(func(a, b): return int(unfinished_tally[a]) > int(unfinished_tally[b]))
	for i in min(12, ids.size()):
		var rid := String(ids[i])
		var rally := RallyLibrary.by_id(rid)
		print("%5d/%d  %s (%s%s)" % [
			int(unfinished_tally[rid]), stuck, rid,
			"special" if RallyLibrary.is_special(rally) else "difficulty %d" % int(
				rally.get("difficulty", 0)),
			", %.3f beyond the frontier" % RallyLibrary.distance_beyond_frontier(rally, {})])


func _tally_unfinished(profile: Dictionary, tally: Dictionary) -> void:
	var rallies: Dictionary = profile.get("rallies", {})
	for rally in RallyLibrary.all():
		var rid := String(rally["id"])
		if not rallies.get(rid, {}).get("completed", false):
			tally[rid] = int(tally.get(rid, 0)) + 1
