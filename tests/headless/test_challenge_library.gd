extends GutTest
# ChallengeLibrary: pure period-key/seed/roll logic for the Daily/Weekly/Monthly
# Rally Challenge (docs/superpowers/specs/2026-07-31-rally-challenge-design.md
# §1). No scene, no Save, no autoload state — everything here is a static call
# against a wall-clock unix_time.
#
# Per CLAUDE.md's testing rules: never pin a specific tunable VALUE (a ceiling
# band entry, a turn-count range bound) — only assert stability (same input ->
# same output) and variation (different key -> a different roll) plus the
# structural contracts the spec fixes (key format, epoch suffix, per-stage seed
# offset, documented stage counts).

const DAY := 86400


func _t(year: int, month: int, day: int, hour := 0, minute := 0, second := 0) -> int:
	return int(Time.get_unix_time_from_datetime_dict(
		{"year": year, "month": month, "day": day, "hour": hour, "minute": minute, "second": second}))


# --- current_period: determinism -----------------------------------------------

func test_current_period_is_deterministic_for_each_kind() -> void:
	var t := _t(2026, 7, 31, 12, 0, 0)
	for kind in [ChallengeLibrary.DAILY, ChallengeLibrary.WEEKLY, ChallengeLibrary.MONTHLY]:
		var a := ChallengeLibrary.current_period(kind, t)
		var b := ChallengeLibrary.current_period(kind, t)
		assert_eq(a, b, "%s: same (kind, unix_time) yields an identical period dict" % kind)


func test_daily_period_rolls_a_new_key_a_day_later() -> void:
	var t := _t(2026, 7, 31, 12, 0, 0)
	var a := ChallengeLibrary.current_period(ChallengeLibrary.DAILY, t)
	var b := ChallengeLibrary.current_period(ChallengeLibrary.DAILY, t + DAY)
	assert_ne(a["key"], b["key"], "a day later rolls a new daily key")


func test_weekly_period_rolls_a_new_key_a_week_later() -> void:
	var t := _t(2026, 7, 31, 12, 0, 0)
	var a := ChallengeLibrary.current_period(ChallengeLibrary.WEEKLY, t)
	var b := ChallengeLibrary.current_period(ChallengeLibrary.WEEKLY, t + 7 * DAY)
	assert_ne(a["key"], b["key"], "a week later rolls a new weekly key")


func test_monthly_period_rolls_a_new_key_a_month_later() -> void:
	var t := _t(2026, 7, 15, 12, 0, 0)
	var a := ChallengeLibrary.current_period(ChallengeLibrary.MONTHLY, t)
	var b := ChallengeLibrary.current_period(ChallengeLibrary.MONTHLY, _t(2026, 8, 15, 12, 0, 0))
	assert_ne(a["key"], b["key"], "a month later rolls a new monthly key")


func test_daily_boundary_crossing_rolls_daily_but_not_necessarily_weekly_or_monthly() -> void:
	# 2026-07-31 is a Friday: 23:59:59 that day vs 00:00:01 the next day (Saturday,
	# still the same ISO week and month) crosses a daily boundary only.
	var before := _t(2026, 7, 31, 23, 59, 59)
	var after := _t(2026, 8, 1, 0, 0, 1)

	var daily_before := ChallengeLibrary.current_period(ChallengeLibrary.DAILY, before)
	var daily_after := ChallengeLibrary.current_period(ChallengeLibrary.DAILY, after)
	assert_ne(daily_before["key"], daily_after["key"], "midnight crosses a daily boundary")

	var weekly_before := ChallengeLibrary.current_period(ChallengeLibrary.WEEKLY, before)
	var weekly_after := ChallengeLibrary.current_period(ChallengeLibrary.WEEKLY, after)
	assert_eq(weekly_before["key"], weekly_after["key"],
		"Friday night into Saturday morning stays inside the same ISO week")

	# Monthly rolls over on this same midnight (Jul 31 -> Aug 1), so use a
	# separate boundary crossing that stays within the month to prove the point.
	var mid_month_before := _t(2026, 7, 15, 23, 59, 59)
	var mid_month_after := _t(2026, 7, 16, 0, 0, 1)
	var monthly_before := ChallengeLibrary.current_period(ChallengeLibrary.MONTHLY, mid_month_before)
	var monthly_after := ChallengeLibrary.current_period(ChallengeLibrary.MONTHLY, mid_month_after)
	assert_eq(monthly_before["key"], monthly_after["key"],
		"a daily boundary crossing mid-month leaves the month unchanged")


func test_current_period_dict_is_fully_deterministic_across_fields() -> void:
	var t := _t(2026, 7, 31, 12, 0, 0)
	var a := ChallengeLibrary.current_period(ChallengeLibrary.WEEKLY, t)
	var b := ChallengeLibrary.current_period(ChallengeLibrary.WEEKLY, t)
	assert_eq(a["stage_count"], b["stage_count"])
	assert_eq(a["starts_at"], b["starts_at"])
	assert_eq(a["ends_at"], b["ends_at"])


# --- Key format -----------------------------------------------------------------

func test_key_carries_the_kind_prefix_and_epoch_suffix() -> void:
	var t := _t(2026, 7, 31, 12, 0, 0)
	var epoch_suffix := ":e%d" % ChallengeLibrary.CHALLENGE_EPOCH
	for kind in [ChallengeLibrary.DAILY, ChallengeLibrary.WEEKLY, ChallengeLibrary.MONTHLY]:
		var key := String(ChallengeLibrary.current_period(kind, t)["key"])
		assert_true(key.begins_with(kind + ":"), "%s key begins with its kind prefix" % kind)
		assert_true(key.ends_with(epoch_suffix), "%s key ends with the literal epoch suffix" % kind)


func test_weekly_key_uses_iso_week_format() -> void:
	var t := _t(2026, 7, 31, 12, 0, 0)
	var key := String(ChallengeLibrary.current_period(ChallengeLibrary.WEEKLY, t)["key"])
	var regex := RegEx.new()
	regex.compile("^weekly:\\d{4}-W\\d{2}:e\\d+$")
	assert_true(regex.search(key) != null, "weekly key matches YYYY-Www shape: got %s" % key)
	# Sanity anchor: 2026-07-31 (a Friday) is hand-verified to fall in ISO
	# week 2026-W31 (Python: date(2026,7,31).isocalendar() == (2026, 31, 5)).
	assert_string_contains(key, "2026-W31")


func test_daily_key_uses_date_format() -> void:
	var t := _t(2026, 7, 31, 12, 0, 0)
	var key := String(ChallengeLibrary.current_period(ChallengeLibrary.DAILY, t)["key"])
	var regex := RegEx.new()
	regex.compile("^daily:\\d{4}-\\d{2}-\\d{2}:e\\d+$")
	assert_true(regex.search(key) != null, "daily key matches YYYY-MM-DD shape: got %s" % key)


func test_monthly_key_uses_year_month_format() -> void:
	var t := _t(2026, 7, 31, 12, 0, 0)
	var key := String(ChallengeLibrary.current_period(ChallengeLibrary.MONTHLY, t)["key"])
	var regex := RegEx.new()
	regex.compile("^monthly:\\d{4}-\\d{2}:e\\d+$")
	assert_true(regex.search(key) != null, "monthly key matches YYYY-MM shape: got %s" % key)


# --- ceiling_for ------------------------------------------------------------

func test_ceiling_for_is_deterministic_and_from_the_band() -> void:
	var t := _t(2026, 7, 31, 12, 0, 0)
	var key := String(ChallengeLibrary.current_period(ChallengeLibrary.WEEKLY, t)["key"])
	var a := ChallengeLibrary.ceiling_for(key)
	var b := ChallengeLibrary.ceiling_for(key)
	assert_eq(a, b, "same key -> same ceiling roll across repeated calls")
	assert_true(ChallengeLibrary.CEILING_BAND_HP_TONNE.has(a),
		"the rolled ceiling is a member of the authored band, not a specific value")


func test_ceiling_for_varies_across_distinct_keys() -> void:
	var t := _t(2026, 1, 1, 12, 0, 0)
	var values := {}
	for i in 30:
		var key := String(ChallengeLibrary.current_period(ChallengeLibrary.DAILY, t + i * DAY)["key"])
		values[ChallengeLibrary.ceiling_for(key)] = true
	assert_gt(values.size(), 1,
		"30 distinct daily keys should not all roll the exact same ceiling")


# --- stages_for -------------------------------------------------------------

func test_stages_for_returns_the_requested_count() -> void:
	var t := _t(2026, 7, 31, 12, 0, 0)
	var key := String(ChallengeLibrary.current_period(ChallengeLibrary.WEEKLY, t)["key"])
	var stages := ChallengeLibrary.stages_for(key, 4)
	assert_eq(stages.size(), 4)


func test_stages_for_is_deterministic() -> void:
	var t := _t(2026, 7, 31, 12, 0, 0)
	var key := String(ChallengeLibrary.current_period(ChallengeLibrary.MONTHLY, t)["key"])
	var a := ChallengeLibrary.stages_for(key, 10)
	var b := ChallengeLibrary.stages_for(key, 10)
	assert_eq(a, b, "same (key, count) -> byte-identical stage list")


func test_stage_seeds_increment_from_the_base_seed() -> void:
	var t := _t(2026, 7, 31, 12, 0, 0)
	var key := String(ChallengeLibrary.current_period(ChallengeLibrary.MONTHLY, t)["key"])
	var stages := ChallengeLibrary.stages_for(key, 10)
	var base_seed := int(stages[0]["seed"])
	for i in stages.size():
		assert_eq(int(stages[i]["seed"]), base_seed + i,
			"stage %d's seed is base_seed + %d" % [i, i])


func test_every_stage_has_every_trackgenparams_field_with_a_sane_type() -> void:
	var t := _t(2026, 7, 31, 12, 0, 0)
	var key := String(ChallengeLibrary.current_period(ChallengeLibrary.WEEKLY, t)["key"])
	var stages := ChallengeLibrary.stages_for(key, 4)
	var int_fields := ["seed", "turn_count"]
	var float_fields := ["forestiness", "surface_mix", "straightness", "cliffiness",
		"water_level", "terrain_layer1_amplitude"]
	for stage in stages:
		for field in int_fields:
			assert_true(stage.has(field), "missing field %s" % field)
			assert_true(typeof(stage[field]) == TYPE_INT or typeof(stage[field]) == TYPE_FLOAT,
				"%s should be numeric" % field)
		for field in float_fields:
			assert_true(stage.has(field), "missing field %s" % field)
			assert_true(typeof(stage[field]) == TYPE_INT or typeof(stage[field]) == TYPE_FLOAT,
				"%s should be numeric" % field)
		assert_true(int(stage["turn_count"]) > 0, "turn_count is a sane positive count")


func test_stages_for_differs_across_distinct_keys() -> void:
	var t := _t(2026, 7, 31, 12, 0, 0)
	var key_a := String(ChallengeLibrary.current_period(ChallengeLibrary.DAILY, t)["key"])
	var key_b := String(ChallengeLibrary.current_period(ChallengeLibrary.DAILY, t + DAY)["key"])
	var stages_a := ChallengeLibrary.stages_for(key_a, 1)
	var stages_b := ChallengeLibrary.stages_for(key_b, 1)
	assert_ne(stages_a, stages_b, "different period keys roll different stages")
