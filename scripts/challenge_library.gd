class_name ChallengeLibrary
extends RefCounted
# Daily/Weekly/Monthly Rally Challenge — period definition, seed derivation, and
# the procedural per-stage TrackGenParams + p/w ceiling roll. A pure static
# module (like RallyLibrary/UpgradeLibrary), no autoload/state: every client
# computes the same period key -> seed -> stages/ceiling from nothing but the
# wall clock, with no server round-trip. See
# docs/superpowers/specs/2026-07-31-rally-challenge-design.md.

const DAILY := "daily"
const WEEKLY := "weekly"
const MONTHLY := "monthly"

# Bumped whenever a release changes what feeds the challenge seed roll (turn-gen
# parameters, the ceiling-band list, stage counts). The epoch lives INSIDE the
# period key (not only inside the seed hash) so bumping it mints a brand-new,
# empty period+epoch subcollection rather than corrupting the currently-running
# one — see spec §1 for why folding it only into the hash was rejected.
const CHALLENGE_EPOCH := 1

const STAGE_COUNTS := {DAILY: 1, WEEKLY: 4, MONTHLY: 10}

# The p/w ceiling band a period's roll picks from (hp/tonne). Placeholder — a
# balance-pass GameConfig tunable, same treatment as RewardSystem's drop
# weights. Never assert a SPECIFIC value from this list in a test, only that
# the roll is stable and changes with the key (per CLAUDE.md's testing rules).
const CEILING_BAND_HP_TONNE := [120.0, 150.0, 180.0, 220.0]

# Turn-count ranges the per-stage roll picks from. Daily is one long stage
# (~40 turns); weekly/monthly stages are ordinary rally-event length. Placeholder
# tunables, same "don't pin a specific value" rule as the ceiling band above.
const DAILY_TURN_COUNT_RANGE := [35, 45]
const STAGE_TURN_COUNT_RANGE := [15, 30]


# {key, stage_count, starts_at, ends_at} for `kind` (DAILY/WEEKLY/MONTHLY) at
# `unix_time`. Pure function of the UTC date + kind + CHALLENGE_EPOCH — no
# server round-trip, no stored state; any client reading the same wall clock
# computes the identical period. `starts_at`/`ends_at` are UTC unix seconds
# bounding the period (end exclusive).
static func current_period(kind: String, unix_time: int) -> Dictionary:
	var d := Time.get_datetime_dict_from_unix_time(unix_time)
	match kind:
		DAILY:
			return _daily_period(d)
		WEEKLY:
			return _weekly_period(d)
		MONTHLY:
			return _monthly_period(d)
		_:
			return {}


static func _daily_period(d: Dictionary) -> Dictionary:
	var starts_at := int(Time.get_unix_time_from_datetime_dict(
		{"year": d["year"], "month": d["month"], "day": d["day"], "hour": 0, "minute": 0, "second": 0}))
	var date_str := "%04d-%02d-%02d" % [d["year"], d["month"], d["day"]]
	return {
		"key": "%s:%s:e%d" % [DAILY, date_str, CHALLENGE_EPOCH],
		"stage_count": STAGE_COUNTS[DAILY],
		"starts_at": starts_at, "ends_at": starts_at + 86400,
	}


static func _weekly_period(d: Dictionary) -> Dictionary:
	var iso := _iso_week(int(d["year"]), int(d["month"]), int(d["day"]))
	var monday_unix := _iso_week_monday_unix(int(iso["year"]), int(iso["week"]))
	return {
		"key": "%s:%04d-W%02d:e%d" % [WEEKLY, iso["year"], iso["week"], CHALLENGE_EPOCH],
		"stage_count": STAGE_COUNTS[WEEKLY],
		"starts_at": monday_unix, "ends_at": monday_unix + 7 * 86400,
	}


static func _monthly_period(d: Dictionary) -> Dictionary:
	var starts_at := int(Time.get_unix_time_from_datetime_dict(
		{"year": d["year"], "month": d["month"], "day": 1, "hour": 0, "minute": 0, "second": 0}))
	var next_month := int(d["month"]) + 1
	var next_year := int(d["year"])
	if next_month > 12:
		next_month = 1
		next_year += 1
	var ends_at := int(Time.get_unix_time_from_datetime_dict(
		{"year": next_year, "month": next_month, "day": 1, "hour": 0, "minute": 0, "second": 0}))
	return {
		"key": "%s:%04d-%02d:e%d" % [MONTHLY, d["year"], d["month"], CHALLENGE_EPOCH],
		"stage_count": STAGE_COUNTS[MONTHLY],
		"starts_at": starts_at, "ends_at": ends_at,
	}


# --- ISO 8601 week helpers ----------------------------------------------------

# ISO week number + ISO week-numbering year for a Gregorian y/m/d (UTC midnight).
# Godot's datetime dict carries no weekday field, so weekday is derived from
# days-since-epoch (1970-01-01 was a Thursday = ISO weekday 4).
static func _iso_week(year: int, month: int, day: int) -> Dictionary:
	var unix := int(Time.get_unix_time_from_datetime_dict(
		{"year": year, "month": month, "day": day, "hour": 0, "minute": 0, "second": 0}))
	var days_since_epoch := int(unix / 86400)
	var iso_weekday := ((days_since_epoch + 3) % 7) + 1  # Mon=1..Sun=7
	# The Thursday of this ISO week determines the ISO week-numbering year (the
	# ISO 8601 rule: a week belongs to the year that owns its Thursday).
	var thursday_unix := unix + (4 - iso_weekday) * 86400
	var thursday := Time.get_datetime_dict_from_unix_time(thursday_unix)
	var jan1_unix := int(Time.get_unix_time_from_datetime_dict(
		{"year": thursday["year"], "month": 1, "day": 1, "hour": 0, "minute": 0, "second": 0}))
	var week := int((thursday_unix - jan1_unix) / (7 * 86400)) + 1
	return {"year": int(thursday["year"]), "week": week}


# Unix timestamp (UTC midnight) of the Monday starting ISO week `week` of
# `iso_year`. Jan 4th always falls in ISO week 1 (the ISO 8601 anchor rule).
static func _iso_week_monday_unix(iso_year: int, week: int) -> int:
	var jan4_unix := int(Time.get_unix_time_from_datetime_dict(
		{"year": iso_year, "month": 1, "day": 4, "hour": 0, "minute": 0, "second": 0}))
	var jan4_days_since_epoch := int(jan4_unix / 86400)
	var jan4_iso_weekday := ((jan4_days_since_epoch + 3) % 7) + 1
	var week1_monday_unix := jan4_unix - (jan4_iso_weekday - 1) * 86400
	return week1_monday_unix + (week - 1) * 7 * 86400


# --- Seed derivation & rolls ---------------------------------------------------

# Integer seed derived from the (epoch-suffixed) period key via the same
# SHA-256-prefix technique RallyLibrary.stage_key uses for its wire format —
# parsed as a hex int here since this seed feeds a RandomNumberGenerator, not a
# wire-format string. Only ever used as RNG input, NEVER as a lookup key or
# Firestore path — the plain period_key is used verbatim for that (spec §1).
static func _seed_from_key(period_key: String) -> int:
	return period_key.sha256_text().substr(0, 8).hex_to_int()


# This period's rolled p/w ceiling (hp/tonne) — picked deterministically from
# CEILING_BAND_HP_TONNE by the period's seed. Same seed -> same ceiling, for
# every player and for the whole period.
static func ceiling_for(period_key: String) -> float:
	var rng := RandomNumberGenerator.new()
	rng.seed = _seed_from_key(period_key)
	return CEILING_BAND_HP_TONNE[rng.randi_range(0, CEILING_BAND_HP_TONNE.size() - 1)]


# This period's procedurally-authored stages: an Array of TrackGenParams-shaped
# event dicts (the same fields RallyLibrary.RALLIES entries author by hand),
# picked deterministically by the period's seed. Stage i's own "seed" field is
# base_seed + i (spec §1); every other field is rolled from the SAME rng
# stream, advanced stage by stage in order, so two clients computing this from
# the same period_key always get byte-identical stages.
static func stages_for(period_key: String, stage_count: int) -> Array:
	var base_seed := _seed_from_key(period_key)
	var rng := RandomNumberGenerator.new()
	rng.seed = base_seed
	var is_daily := period_key.begins_with(DAILY + ":")
	var turn_range: Array = DAILY_TURN_COUNT_RANGE if is_daily else STAGE_TURN_COUNT_RANGE
	var stages: Array = []
	for i in stage_count:
		# water_level and terrain_layer1_amplitude are rolled TOGETHER, not
		# independently. Authored RallyLibrary.RALLIES events only ever pair
		# water_level -5.0 (close to the terrain baseline) with amplitude >= 16.0,
		# and -12.0 with a wider 11-25 band — combinations hand-verified to route
		# cleanly before they ship. A challenge seed gets no such verification (it
		# is rolled fresh every period and never enters the track lockfile), so it
		# draws the amplitude from the SAME band real content uses for whichever
		# water level came up, rather than risking a pairing no shipped stage has
		# ever exercised. Both values only reach generation via
		# DrivingContext.apply_stage_config -> RallySession.apply_event_config.
		var water_level := -12.0 if rng.randf() < 0.5 else -5.0
		var amplitude := rng.randf_range(16.0, 19.0) if water_level == -5.0 \
			else rng.randf_range(11.0, 25.0)
		stages.append({
			"seed": base_seed + i,
			"turn_count": rng.randi_range(turn_range[0], turn_range[1]),
			"forestiness": rng.randf_range(0.2, 0.8),
			"surface_mix": rng.randf_range(0.0, 1.0),
			"straightness": rng.randf_range(0.0, 1.0),
			"cliffiness": rng.randf_range(0.3, 0.7),
			"water_level": water_level,
			"terrain_layer1_amplitude": amplitude,
		})
	return stages
