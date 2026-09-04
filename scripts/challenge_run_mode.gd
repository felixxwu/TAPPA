class_name ChallengeRunMode
extends RunMode
# Docs: features/rally-challenge.md — update in the same change as this file.
# Tests: tests/headless/test_challenge_session.gd, tests/headless/test_challenge_run_end.gd, tests/headless/test_challenge_library.gd — extend in the same change.
#
# The Daily/Weekly/Monthly Rally Challenge as a `RunMode` — caller ONE of
# `RunSession` (todo/roguelike-pivot.md decision 15: the challenge survives the
# roguelike pivot). Everything here was `ChallengeSession`'s challenge-specific
# half before the session was generalised; the stage loop, the persisted run slot,
# the field repair and the car lock all moved to RunSession and are now shared with
# the region run.
#
# What makes a challenge different from a region run:
#   * its stages are ROLLED from the period key (ChallengeLibrary.stages_for), not
#     drawn from authored content;
#   * it has NO target time and therefore NO fail state — a challenge is scored by
#     cumulative time against a cloud board, so a slow stage costs placing, not the
#     run (stage_target_ms / stage_failed both stay at RunMode's inert defaults);
#   * it pays ONE placement-gated lump sum at the end rather than per stage;
#   * it EXPIRES: a stored run whose period has rolled over is stale, never resumed.

var kind := ""
var period_key := ""
var _stage_count := 0


func _init(kind_str := "", period_key_str := "", stage_count_val := 0) -> void:
	kind = kind_str
	period_key = period_key_str
	_stage_count = stage_count_val


# The mode for whichever period of `kind_str` is live at `unix_time`, or null when
# `kind_str` names no period (an unknown kind string).
static func for_kind(kind_str: String, unix_time: int) -> ChallengeRunMode:
	var period := ChallengeLibrary.current_period(kind_str, unix_time)
	if period.is_empty():
		return null
	return ChallengeRunMode.new(kind_str, String(period["key"]), int(period["stage_count"]))


# Rebuild from a persisted run slot. The stage count is re-read from the LIVE period
# rather than trusted from disk, exactly as ChallengeSession.resume always did.
static func from_record(rec: Dictionary, unix_time: int) -> ChallengeRunMode:
	var kind_str := String(rec.get("kind", ""))
	var period := ChallengeLibrary.current_period(kind_str, unix_time)
	return ChallengeRunMode.new(kind_str, String(rec.get("period_key", "")),
		int(period.get("stage_count", 0)))


func mode_id() -> String:
	return RunMode.CHALLENGE


func stage_count() -> int:
	return _stage_count


func stages() -> Array:
	return ChallengeLibrary.stages_for(period_key, _stage_count)


func display_name() -> String:
	return "%s Challenge" % kind.capitalize()


func to_record() -> Dictionary:
	# period_key/kind sit at the TOP LEVEL of the run slot (not nested), because that
	# is the shape ChallengeSession persisted before the generalisation and the shape
	# resumable_run / the cloud board reader still key off.
	return {"period_key": period_key, "kind": kind}


# A stored challenge run is resumable only while ITS period is still the live one —
# spec §3: once the period rolls over "the run is discarded locally, no further
# posts". This is the only stale state any run kind has.
func is_resumable(unix_time: int) -> bool:
	var current := ChallengeLibrary.current_period(kind, unix_time)
	return not current.is_empty() and String(current.get("key", "")) == period_key


# Record this run's terminal outcome against its period, so it can't be re-run.
# Also PRUNES every stored period that is no longer live: the map would otherwise
# gain an entry every day forever. Only the three current period keys can survive,
# so it holds at most three records.
func record_outcome(result: Dictionary, unix_time: int) -> void:
	var results: Dictionary = Save.profile.get("challenge_results", {})
	results[period_key] = {
		"kind": kind, "dnf": bool(result.get("dnf", false)),
		"cumulative_ms": int(result.get("cumulative_ms", 0)),
	}
	var live := {}
	for k in [ChallengeLibrary.DAILY, ChallengeLibrary.WEEKLY, ChallengeLibrary.MONTHLY]:
		var period := ChallengeLibrary.current_period(k, unix_time)
		if not period.is_empty():
			live[String(period["key"])] = true
	var pruned := {}
	for key in results:
		if live.has(key):
			pruned[key] = results[key]
	Save.set_challenge_results(pruned)


# --- Terminal per-period outcome (one attempt per period) ------------------------

# The finished outcome for `period_key_str` in `profile`, or {} if that period has not
# been played to an end. Pure read.
static func period_outcome(profile: Dictionary, period_key_str: String) -> Dictionary:
	var results: Dictionary = profile.get("challenge_results", {})
	return results.get(period_key_str, {})


# True when `kind_str`'s CURRENT period has already been finished — completed or
# DNF'd (a DNF is only reachable on a run persisted by an older build — nothing DNFs a
# challenge now). Both are terminal: a challenge is one attempt per period, so neither can
# be started again until the period rolls.
static func is_period_finished(kind_str: String, profile: Dictionary, unix_time: int) -> bool:
	var period := ChallengeLibrary.current_period(kind_str, unix_time)
	if period.is_empty():
		return false
	return not period_outcome(profile, String(period["key"])).is_empty()


# --- Eligibility (pure, no Save dependency — testable with a synthetic profile) ---

# classify_car verdicts. READY doubles as the classify_cars bucket key.
const READY := "ready"
const EXCLUDED := "excluded"


# Owned cars eligible for `kind_str` at `unix_time`: cars whose CURRENT build rates
# at/under the period's rolled rating ceiling. There is no detune escape — an
# over-ceiling build is plainly ineligible and the player picks or builds another car
# (the rating design doc's D5). Recomputed live, never cached at grant time.
static func eligible_cars(kind_str: String, profile: Dictionary, unix_time: int) -> Array:
	return classify_cars(kind_str, profile, unix_time)["eligible"]


# The period's rating ceiling AS THE PLAYER SEES IT — rounded to a whole number, which
# is how every challenge label prints it. Eligibility is judged against THIS, never the
# raw float: CarPerformance.rating is itself an int, so comparing it to an unrounded
# ceiling would reject a car whose displayed rating exactly equals the displayed cap.
static func displayed_ceiling(kind_str: String, unix_time: int) -> int:
	return roundi(ChallengeLibrary.current_ceiling(kind_str, unix_time))


# The ONE place the challenge eligibility rule lives. Classifies every owned car in
# `profile` against `kind_str`'s current period and returns
#   {"ceiling": int, "eligible": Array, "ready": Array}
# `ready` and `eligible` hold the same cars (in the profile's own car order) — the two
# keys are kept distinct because the UI reads `eligible` as "what can enter" and `ready`
# as "what to name on the screen". The UI reads these lists rather than re-deriving the
# comparison, so the "compare against the DISPLAYED ceiling" rule can't drift.
static func classify_cars(kind_str: String, profile: Dictionary, unix_time: int) -> Dictionary:
	var out := {"ceiling": 0, "eligible": [], "ready": []}
	var period := ChallengeLibrary.current_period(kind_str, unix_time)
	if period.is_empty():
		return out
	var raw_ceiling := ChallengeLibrary.ceiling_for(String(period["key"]))
	out["ceiling"] = roundi(raw_ceiling)
	for car in profile.get(Save.KEY_CARS, []):
		var entry := CarLibrary.for_owned(car)
		if entry.is_empty():
			continue
		if String(classify_car(raw_ceiling, car, entry)["state"]) == EXCLUDED:
			continue
		out["ready"].append(car)
		out["eligible"].append(car)
	return out


# classify_cars' per-car verdict, and the ONE implementation of the challenge
# eligibility comparison: {"state": READY|EXCLUDED}.
#
# A plain rating comparison. Over the ceiling means simply ineligible — there is no
# detune escape and no auto-disabling of parts (design doc D5); the player picks or
# builds another car.
#
# `raw_ceiling` is the period's rolled rating as ChallengeLibrary returns it; it is
# ROUNDED here before anything is compared against it (see displayed_ceiling), so the
# whole challenge path judges a car against the same number the screen prints.
static func classify_car(raw_ceiling: float, owned: Dictionary, entry: Dictionary) -> Dictionary:
	# merged_meta, not effective_meta: the rating must see tyres and aero, which
	# effective_meta deliberately withholds (they never fed power-to-weight).
	var meta := CarPerformance.merged_meta(owned, entry)
	if CarPerformance.rating(meta) <= roundi(raw_ceiling):
		return {"state": READY}
	return {"state": EXCLUDED}


# --- Completion reward (placement-gated, §6) -----------------------------------

# The single source of truth for "how much of the board counts as PLACING" — the reward
# RULE below (`rank > ceili(float(total) * CHALLENGE_TOP_FRACTION)`) and the win-condition
# label the challenge entry screen shows both read it, so the rule and its label cannot
# silently disagree. It lives here as a const rather than in game_config.tres because it is
# a REWARD RULE, not a look or feel tunable: moving it changes who gets paid.
const CHALLENGE_TOP_FRACTION := 0.5


# Finishing every stage (no DNF) is eligible for one placement-gated reward:
# top ceil(total_entries/2) of that period's board, checked AGAINST THE BOARD
# AS IT STANDS AT THIS MOMENT (an early finisher is compared to a smaller
# field — accepted as a deliberate generous quirk, not a bug, per spec §6).
# Requires a cloud rank to exist at all — skipped entirely if signed out /
# no username / the final checkpoint never posted (all read the same way:
# Cloud.challenge_leaderboard.fetch_final_rank returning not-ok).
#
# THE MONEY SEAM IS NOW WIRED (todo/roguelike-pivot.md decision 21). This used to pay
# STARS, and then — between the star deletion and the economy landing — nothing at all.
# A placing run now banks `GameConfig.challenge_completion_money`, a flat lump sum
# rather than the per-stage/fast-bonus pair a region run earns: a challenge has no
# target time to be fast against, and its whole reward IS the placement, so a curve
# keyed to stage count would just re-price the same single event. The granted amount is
# returned as "money" so the caller's reward card can name it.
static func try_grant_completion_reward(result: Dictionary) -> Dictionary:
	if not bool(result.get("completed", false)):
		return {}  # DNF gets nothing from this path (§6)
	if Cloud == null or Cloud.challenge_leaderboard == null:
		return {}
	var kind_str := String(result.get("kind", ""))
	var stage_count_val: int = int(ChallengeLibrary.STAGE_COUNTS.get(kind_str, 0))
	var rank_info := await Cloud.challenge_leaderboard.fetch_final_rank(
		String(result.get("period_key", "")), stage_count_val)
	if not bool(rank_info.get("ok", false)):
		return {}  # no cloud rank available — same graceful skip as a signed-out finish
	var rank := int(rank_info["rank"])
	var total := int(rank_info["total_entries"])
	if rank > ceili(float(total) * CHALLENGE_TOP_FRACTION):
		return {"placed": false, "rank": rank, "total_entries": total}
	var money := maxi(0, int(round(Config.data.challenge_completion_money)))
	if money > 0:
		Save.add_money(money)
	return {"placed": true, "rank": rank, "total_entries": total,
		"item_id": "", "money": money}
