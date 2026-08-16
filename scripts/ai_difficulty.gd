extends RefCounted
class_name AiDifficulty

# How hard the rival field is pitched, relative to the player.
#
# The lever is the opponents' MACHINERY, not their driving: the field is already drawn
# matched to the player's CarPerformance rating, so making it harder means handing the
# matcher a rating ABOVE the player's and letting rivals turn up in quicker cars.
#
# That is why this file computes a rating and not a pace multiplier. A rival in a faster
# car has a genuinely lower optimum, so its time can be quicker in absolute terms while
# still sitting at a sane multiple of ITS OWN optimum — which keeps RivalPace inside its
# skill bracket and keeps the windscreen ghost able to show what the standings claim.
# Scaling pace instead would have required rivals to beat their own physics optimum, which
# the ghost cannot represent (it tops out ~2.4% quicker; see the design doc).
#
# The offset is driven purely by RESULTS. There is deliberately no record of how the
# player's times compare to the model: winning or losing already says whether they are
# faster than the field they were given, so the offset converges by feedback alone, and a
# second mechanism measuring the model's own error would only inherit that error.
#
# See docs/superpowers/specs/2026-08-16-adaptive-difficulty-design.md and
# features/adaptive-difficulty.md.

# Profile keys. Kept here rather than in SaveManager because this file owns their meaning;
# the save just stores them.
const KEY_STEPS := "difficulty_steps"     # signed: + harder, - easier, 0 = matched
const KEY_WIN_STREAK := "win_streak"
const KEY_LOSS_STREAK := "loss_streak"


# The rating the opponent field should be matched to, given the player's own.
#
# At 0 steps this returns `player_rating` unchanged, so a fresh career — and any profile
# migrated from before this existed — draws exactly the field it drew before. The no-op
# falls out of the design rather than being arranged, which is why there is no warm-up
# period or cold-start branch anywhere in this system.
static func target_rating(player_rating: int, profile: Dictionary) -> int:
	if player_rating <= 0:
		return player_rating   # unmatched draw; nothing to offset
	var cfg: GameConfig = Config.data
	if not cfg.ai_adapt_enabled:
		return player_rating
	var steps := steps_of(profile)
	if steps == 0:
		return player_rating
	return int(round(float(player_rating) * (1.0 + float(steps) * cfg.ai_adapt_step_fraction)))


static func steps_of(profile: Dictionary) -> int:
	return int(profile.get(KEY_STEPS, 0))


# Fold one stage result into the offset, returning the profile fields to write.
#
# ASYMMETRIC ON PURPOSE. A result in the direction that undoes the current offset takes
# effect IMMEDIATELY — one win cancels a step of easing — while pushing PAST baseline takes
# `ai_adapt_stages_per_step` in a row. So the system returns to neutral quickly and only
# commits to a real handicap when the evidence is sustained; a player who wins now and then
# never accumulates hardening.
#
# The opposite streak is cleared on every result, so alternating finishes cannot creep in
# either direction.
static func apply_stage_result(profile: Dictionary, won: bool) -> Dictionary:
	var cfg: GameConfig = Config.data
	var steps := steps_of(profile)
	var wins := int(profile.get(KEY_WIN_STREAK, 0))
	var losses := int(profile.get(KEY_LOSS_STREAK, 0))
	if not cfg.ai_adapt_enabled:
		return {KEY_STEPS: steps, KEY_WIN_STREAK: wins, KEY_LOSS_STREAK: losses}
	var per_step: int = maxi(cfg.ai_adapt_stages_per_step, 1)
	if won:
		losses = 0
		if steps < 0:
			steps += 1          # give back a step of easing at once
			wins = 0
		else:
			wins += 1
			if wins >= per_step:
				steps = mini(steps + 1, cfg.ai_adapt_max_hard_steps)
				wins = 0
	else:
		wins = 0
		if steps > 0:
			steps -= 1          # give back a step of hardening at once
			losses = 0
		else:
			losses += 1
			if losses >= per_step:
				steps = maxi(steps - 1, -cfg.ai_adapt_max_ease_steps)
				losses = 0
	return {KEY_STEPS: steps, KEY_WIN_STREAK: wins, KEY_LOSS_STREAK: losses}


# One line per stage for the dev log, showing where the difficulty is HEADING rather than
# only where it is: the result, how far the streak has got toward committing a step, and
# whether this stage actually moved the offset.
#
# Without the streak fraction the log would look inert for two stages out of every three —
# the offset only changes on the third — and it would be impossible to tell "nothing is
# happening" from "a step is one result away".
static func describe_result(before: Dictionary, after: Dictionary, won: bool) -> String:
	var per_step: int = maxi(Config.data.ai_adapt_stages_per_step, 1)
	var was := int(before.get(KEY_STEPS, 0))
	var now := int(after.get(KEY_STEPS, 0))
	var streak: int = int(after.get(KEY_WIN_STREAK, 0)) if won else int(after.get(KEY_LOSS_STREAK, 0))
	var moved := ""
	if now != was:
		# Distinguish GIVING BACK an offset from COMMITTING to one. Both move the same
		# direction, but "the game has stopped helping you" and "the game is now pushing
		# harder than a matched field" are different events, and a log that called them both
		# HARDER would hide the one you actually want to notice.
		var recovering := absi(now) < absi(was)
		var word := "back to matched" if recovering \
			else ("HARDER" if now > was else "EASIER")
		moved = "  ->  %s (%s => %s)" % [word, _sign(was), _sign(now)]
	elif streak > 0:
		moved = "  (%d/%d to a step %s)" % [streak, per_step, "harder" if won else "easier"]
	return "%s | %s%s" % ["WON " if won else "LOST", describe(after), moved]


# 0 prints as "0", not "+0" — a signed zero reads as a direction that was not taken.
static func _sign(n: int) -> String:
	return "0" if n == 0 else "%+d" % n


# One line for the dev field log. The system is SILENT to the player (design D1), so this
# is the only place the offset is ever visible — without it a field drawn 20% above the
# player's rating would look like a matching bug.
static func describe(profile: Dictionary) -> String:
	var steps := steps_of(profile)
	if steps == 0:
		return "matched"
	return "%s %+d step%s" % ["harder" if steps > 0 else "easier", steps,
		"" if absi(steps) == 1 else "s"]
