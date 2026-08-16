extends GutTest

# AiDifficulty — the rule that moves the rival field harder or easier from results.
#
# Pure logic over a profile dict: no save, no scene, no session. Everything here is a
# RELATION (a win undoes easing, a streak commits a step, the caps hold), never a tuned
# value — a designer retuning ai_adapt_* in the inspector must not break this file.

var _profile: Dictionary = {}

func before_each() -> void:
	Config.reset()
	_profile = {
		AiDifficulty.KEY_STEPS: 0,
		AiDifficulty.KEY_WIN_STREAK: 0,
		AiDifficulty.KEY_LOSS_STREAK: 0,
	}

func after_each() -> void:
	Config.reset()


# Fold `n` identical results in, so a test reads as "after three losses…" rather than as
# three copies of the same call.
func _run(won: bool, n: int = 1) -> void:
	for _i in n:
		var out := AiDifficulty.apply_stage_result(_profile, won)
		for k in out:
			_profile[k] = out[k]

func _steps() -> int:
	return AiDifficulty.steps_of(_profile)

func _per_step() -> int:
	return Config.data.ai_adapt_stages_per_step


# --- The matched baseline is an exact no-op ----------------------------------

func test_a_matched_field_asks_for_the_players_own_rating() -> void:
	# The property the whole design leans on: at 0 steps the target IS the player's rating,
	# so a fresh career — and any profile migrated from before this existed — draws exactly
	# the field it drew before. There is no cold-start branch because none is needed.
	assert_eq(AiDifficulty.target_rating(500, _profile), 500,
		"no offset means the field is matched, byte for byte")


func test_the_master_switch_restores_the_matched_field() -> void:
	_profile[AiDifficulty.KEY_STEPS] = 4
	Config.data.ai_adapt_enabled = false
	assert_eq(AiDifficulty.target_rating(500, _profile), 500,
		"disabled, an existing offset stops being applied")
	_run(false, 20)
	assert_eq(_steps(), 4, "and no result moves it while disabled")


func test_an_unmatched_draw_is_left_alone() -> void:
	# 0 means "draw unmatched" to generate_opponent_field (the test/no-car path). Offsetting
	# it would turn a deliberate non-match into a small positive rating and quietly start
	# matching against nothing.
	_profile[AiDifficulty.KEY_STEPS] = 3
	assert_eq(AiDifficulty.target_rating(0, _profile), 0, "an unmatched draw stays unmatched")


# --- Direction ----------------------------------------------------------------

func test_a_run_of_losses_makes_the_field_easier() -> void:
	_run(false, _per_step())
	assert_lt(_steps(), 0, "sustained losses push the field below the player")
	assert_lt(AiDifficulty.target_rating(500, _profile), 500,
		"which asks the matcher for slower machinery")


func test_a_run_of_wins_makes_the_field_harder() -> void:
	_run(true, _per_step())
	assert_gt(_steps(), 0, "sustained wins push the field above the player")
	assert_gt(AiDifficulty.target_rating(500, _profile), 500,
		"which asks the matcher for quicker machinery")


func test_one_result_short_of_the_streak_commits_nothing() -> void:
	_run(true, _per_step() - 1)
	assert_eq(_steps(), 0, "moving PAST matched takes the full streak, not a near miss")


# --- The asymmetry: back to matched fast, past it slowly ---------------------

func test_a_single_win_gives_back_a_step_of_easing() -> void:
	# The point of the asymmetry: a player who was struggling and then wins should not have
	# to win three times before the game stops helping them.
	_run(false, _per_step())
	var eased := _steps()
	assert_lt(eased, 0, "setup: the field was eased")
	_run(true)
	assert_eq(_steps(), eased + 1, "one win takes back one step immediately")


func test_a_single_loss_gives_back_a_step_of_hardening() -> void:
	_run(true, _per_step())
	var hardened := _steps()
	assert_gt(hardened, 0, "setup: the field was hardened")
	_run(false)
	assert_eq(_steps(), hardened - 1, "one loss takes back one step immediately")


func test_alternating_results_never_accumulate() -> void:
	# The guard against creep: a player trading wins and losses is exactly matched, and
	# must stay there however long they do it.
	for _i in 12:
		_run(true)
		_run(false)
	assert_eq(_steps(), 0, "win/lose/win/lose leaves the field matched")


func test_the_opposite_streak_resets_on_every_result() -> void:
	_run(true, _per_step() - 1)   # one win short of hardening
	_run(false)                   # ...then a loss
	_run(true, _per_step() - 1)   # and back to one short again
	assert_eq(_steps(), 0, "the interrupted win streak did not carry over")


# --- Caps ---------------------------------------------------------------------

func test_the_offset_stops_at_its_caps_in_both_directions() -> void:
	_run(true, _per_step() * (Config.data.ai_adapt_max_hard_steps + 4))
	assert_eq(_steps(), Config.data.ai_adapt_max_hard_steps, "hardening stops at its cap")
	_run(false, _per_step() * (Config.data.ai_adapt_max_hard_steps
		+ Config.data.ai_adapt_max_ease_steps + 8))
	assert_eq(_steps(), -Config.data.ai_adapt_max_ease_steps, "easing stops at its own cap")


func test_the_two_caps_are_independent() -> void:
	# They are separate knobs because the car roster is not symmetric around the player:
	# there is far more of it below a mid-pack car than above a quick one.
	Config.data.ai_adapt_max_hard_steps = 1
	Config.data.ai_adapt_max_ease_steps = 4
	_run(true, _per_step() * 6)
	assert_eq(_steps(), 1, "the hard cap binds on its own")
	_run(false, _per_step() * 12)
	assert_eq(_steps(), -4, "and the ease cap binds independently")


# --- Reporting ----------------------------------------------------------------

func test_the_dev_description_names_the_direction() -> void:
	# The system is SILENT to the player, so the field log is the only place the offset is
	# ever visible — without it a field drawn well off the player's rating reads as a bug.
	assert_string_contains(AiDifficulty.describe(_profile), "matched")
	_run(true, _per_step())
	assert_string_contains(AiDifficulty.describe(_profile), "harder")
	_run(false, _per_step() * 3)
	assert_string_contains(AiDifficulty.describe(_profile), "easier")


# --- The per-stage log ---------------------------------------------------------
#
# The system is silent to the player, so this log is the only way to see it working.
# It has to show where the difficulty is HEADING, not just where it is.

func _result_line(won: bool) -> String:
	var before := _profile.duplicate(true)
	_run(won)
	return AiDifficulty.describe_result(before, _profile, won)


func test_the_log_shows_progress_toward_a_step() -> void:
	# Two stages in three change nothing. Without the streak fraction those look identical
	# to a system that has stopped responding, which is the main thing this log is for.
	var line := _result_line(false)
	assert_string_contains(line, "LOST")
	assert_string_contains(line, "/%d" % Config.data.ai_adapt_stages_per_step)


func test_the_log_calls_out_a_committed_step() -> void:
	var line := ""
	for _i in Config.data.ai_adapt_stages_per_step:
		line = _result_line(false)
	assert_string_contains(line, "EASIER")


func test_the_log_distinguishes_giving_back_from_committing() -> void:
	# Both move the same direction, but "the game has stopped helping you" and "the game is
	# now pushing harder than a matched field" are different events. A log that called them
	# both HARDER would hide the one worth noticing.
	for _i in Config.data.ai_adapt_stages_per_step:
		_run(false)
	assert_lt(_steps(), 0, "setup: the field was eased")
	var recovery := _result_line(true)
	assert_string_contains(recovery, "back to matched")
	assert_false(recovery.contains("HARDER"),
		"returning to matched is not the same event as pushing past it")
