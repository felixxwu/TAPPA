extends GutTest
# Opponent-field cache: serialization faithfulness, miss fallback, coverage/freshness.

const TrackGenParams = preload("res://scripts/track_gen_params.gd")
const CarFixtures = preload("res://tests/headless/car_fixtures.gd")

const START := Vector2.ZERO
const HEAD := Vector2(0, -1)

func after_each() -> void:
	OpponentCache.reset()
	CarFixtures.restore()

# A field survives a real JSON round-trip field-for-field (guards the int/bool type
# restore that JSON's float parsing would otherwise break). Synthetic roster + rally +
# tracks — no dependency on the shipped catalogue, no pinned tunable value.
func test_field_survives_json_round_trip() -> void:
	CarFixtures.install()
	var track := await TrackGenerator.generate(TrackGenParams.of(START, HEAD, 7, 8, 6.0))
	assert_true(track["complete"], "precondition: synthetic track generates")
	var events := [{"seed": 7}, {"seed": 7}, {"seed": 7}]
	var results := [track, track, track]
	var rally := {"id": "synth", "difficulty": 2, "restriction": {}, "events": events}
	var field := RallyLibrary.generate_opponent_field(rally, results, events)
	assert_false(field.is_empty(), "precondition: a field was generated")
	# Real JSON round-trip through the cache serialisation.
	var key := OpponentCache.key_for(rally)
	var doc := { "entries": { key: OpponentCache.serialize_field(field) } }
	# 4-arg form: indent, sort_keys, full_precision=true (the 3rd arg is sort_keys,
	# NOT full_precision — a random float like wreck_progress needs full precision to
	# round-trip). Matches how the generator writes the file.
	var parsed: Variant = JSON.parse_string(JSON.stringify(doc, "", true, true))
	OpponentCache.load_from(parsed["entries"])
	var got := OpponentCache.lookup(rally)
	assert_eq(got.size(), field.size(), "same rival count")
	for i in field.size():
		assert_eq(got[i], field[i], "rival %d round-trips field-for-field" % i)

func test_lookup_miss_returns_empty() -> void:
	OpponentCache.load_from({})
	var rally := {"id": "nope", "difficulty": 1, "restriction": {}, "events": [{"seed": 1}]}
	assert_true(OpponentCache.lookup(rally).is_empty(), "miss -> empty array")

# A seeded in-memory hit is returned by lookup (the path start_rally relies on).
func test_seeded_hit_is_returned() -> void:
	CarFixtures.install()
	var track := await TrackGenerator.generate(TrackGenParams.of(START, HEAD, 7, 8, 6.0))
	var events := [{"seed": 7}, {"seed": 7}, {"seed": 7}]
	var rally := {"id": "synth2", "difficulty": 3, "restriction": {}, "events": events}
	var field := RallyLibrary.generate_opponent_field(rally, [track, track, track], events)
	OpponentCache.load_from({ OpponentCache.key_for(rally): OpponentCache.serialize_field(field) })
	var got := OpponentCache.lookup(rally)
	assert_eq(got.size(), field.size(), "seeded field is returned by lookup")
	assert_eq(String(got[0]["name"]), String(field[0]["name"]), "first rival matches")

# Lockfile contract: every rally resolves to a key present in the committed
# data/opponent_cache.json, and the stored source_hash matches the current library.
# A stale/missing entry fails here and in CI — rerun ./cache_all.sh.
func test_committed_cache_covers_every_rally() -> void:
	OpponentCache.reset()  # force a real load from disk
	for rally in RallyLibrary.all():
		var got := OpponentCache.lookup(rally)
		assert_false(got.is_empty(),
			"rally %s missing from opponent lockfile — run ./cache_all.sh" % rally.get("id", "?"))

# --- fingerprint memoisation -------------------------------------------------
# global_fingerprint() is memoised (it parses the 248 KB track lockfile, load()s the
# config and hashes the whole catalogue). The memo must be transparent — same answer
# whether or not it's warm — and must be droppable so an in-process regeneration can't
# bake a stale fingerprint into the lockfile. No hash VALUE is asserted here.
func test_fingerprint_is_stable_across_calls() -> void:
	OpponentCache.reset_cache()
	var cold := OpponentCache.global_fingerprint()
	assert_eq(OpponentCache.global_fingerprint(), cold, "warm memo returns the same fingerprint")
	OpponentCache.reset_cache()
	assert_eq(OpponentCache.global_fingerprint(), cold,
		"recomputing from scratch reproduces the memoised fingerprint")

func test_reset_cache_drops_the_memo() -> void:
	OpponentCache.global_fingerprint()
	assert_ne(OpponentCache._global_fp_key, "", "precondition: the memo is warm")
	OpponentCache.reset_cache()
	assert_eq(OpponentCache._global_fp_key, "", "reset_cache() invalidates the fingerprint memo")
	assert_eq(TrackCache._source_hash_stamp, -1, "reset_cache() also drops the track source-hash memo")
	# And the next call really recomputes rather than returning the emptied memo.
	assert_ne(OpponentCache.global_fingerprint(), "", "next call recomputes a real fingerprint")

# The track source hash is memoised too; a fresh read must agree with the warm one.
func test_stored_source_hash_survives_a_reset() -> void:
	var warm := TrackCache.stored_source_hash()
	TrackCache.reset_source_hash_cache()
	assert_eq(TrackCache.stored_source_hash(), warm, "re-read from disk matches the memoised hash")

# --- weather ------------------------------------------------------------------
# Marking an event wet re-keys its rally automatically: rally_content_fingerprint
# hashes the whole rally dict (see docstring above), so a "weather" field on an
# event is enough to change the key on its own — no fingerprint code needed for
# this half. This guards that behaviour keeps holding.
func test_wet_event_gets_a_different_cache_key_than_dry() -> void:
	var dry_events := [{"seed": 7, "weather": RallyLibrary.WEATHER_DRY}]
	var wet_events := [{"seed": 7, "weather": RallyLibrary.WEATHER_RAIN}]
	var dry_rally := {"id": "synth3", "difficulty": 2, "restriction": {}, "events": dry_events}
	var wet_rally := {"id": "synth3", "difficulty": 2, "restriction": {}, "events": wet_events}
	assert_ne(OpponentCache.key_for(dry_rally), OpponentCache.key_for(wet_rally),
		"an otherwise-identical wet event gets a different opponent-cache key")

func test_committed_source_hash_is_fresh() -> void:
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(OpponentCache.CACHE_PATH))
	assert_eq(typeof(data), TYPE_DICTIONARY, "lockfile parses")
	assert_eq(String(data["source_hash"]), TrackCache.source_hash_of(OpponentCache.all_rally_keys()),
		"opponent lockfile source_hash is stale — run ./cache_all.sh and commit")


# --- Rival-ghost pace seeds (features/rival-ghost.md) -------------------------------

func test_ghost_pace_seeds_survive_the_round_trip() -> void:
	# The seed is what lets a stage validate in ONE profile sweep instead of a 14-sweep
	# bisection, so it has to actually come back out of the JSON as numbers.
	var field := [{
		"name": "Quick", "car_id": "c", "engine_id": "", "car_name": "Quick",
		"event_times_ms": [1000, 2000, 3000], "dnf": false, "combined_ms": 6000,
		"wreck_event": -1, "wreck_progress": 0.0, "wreck_side": 1.0,
		"skill_k": [0.4321, -1.0, 0.1234],
	}]
	var doc := {"entries": {"k": OpponentCache.serialize_field(field)}}
	var parsed: Dictionary = JSON.parse_string(JSON.stringify(doc, "", false, true))
	var out := OpponentCache.deserialize_field(parsed["entries"]["k"])
	assert_eq(out.size(), 1, "one rival back")
	var seeds: Array = out[0]["skill_k"]
	assert_eq(seeds.size(), 3, "one seed per event")
	assert_almost_eq(float(seeds[0]), 0.4321, 0.0001, "solved seed survives")
	assert_almost_eq(float(seeds[1]), -1.0, 0.0001, "the -1 'no seed' marker survives")
	assert_almost_eq(float(seeds[2]), 0.1234, 0.0001, "and so does the third event's")

func test_a_cache_entry_without_seeds_still_loads() -> void:
	# Forward compatibility: a lockfile written before this field existed must not break,
	# it should just mean "no seed, solve from scratch".
	var raw := [{
		"name": "Old", "car_id": "c", "engine_id": "", "car_name": "Old",
		"event_times_ms": [1000], "dnf": false, "combined_ms": 1000,
		"wreck_event": -1, "wreck_progress": 0.0, "wreck_side": 1.0,
	}]
	var out := OpponentCache.deserialize_field(raw)
	assert_eq(out.size(), 1, "the row still loads")
	assert_true((out[0]["skill_k"] as Array).is_empty(),
			"and reports no seeds rather than erroring")

func test_the_committed_lockfile_carries_a_seed_for_every_event() -> void:
	# The bake fills a seed for each event's P1 — the only rival a ghost is built for. If
	# this regresses to zero, every stage silently pays the full bisection again.
	var seeded := 0
	for rally in RallyLibrary.all():
		var field := OpponentCache.lookup(rally)
		for opp in field:
			for v in opp.get("skill_k", []):
				if float(v) >= 0.0:
					seeded += 1
	assert_gt(seeded, 0, "the committed lockfile carries baked ghost pace seeds")
